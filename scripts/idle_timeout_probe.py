#!/usr/bin/env python3
"""The idle connection timeout, and the WebSocket close linger it bounds.

Two capabilities, one probe, because the second is built on the first.

**The idle timeout** (SPEC A4) closes a keep-alive connection that has been
answered and then goes quiet. It is NOT the header deadline: a slot's idle
deadline is stamped in `_finish_response`'s keep-alive branch, so a client
that connects and says nothing has no idle deadline at all and is governed
by `header_read_timeout` instead (`scripts/header_timeout_probe.py` covers
that one). This probe therefore sends a request and READS the answer before
going quiet, which is the state the sweep keys on.

**The WebSocket close linger** is what made this worth gating. RFC 6455
5.5.1: having sent Close, wait to RECEIVE one before closing the connection.
v0.15.1 implemented that -- and bounded the wait with this same idle sweep,
because a peer that never replies must not hold its slot forever. Two
seconds (`WS_CLOSE_LINGER_NS`), gated on `idle_timeout > 0`.

So a shipped correctness fix rests on a mechanism nothing asserted, and
writing this probe found that the bound did not hold: the drain reaches its
linger branch on EVERY pass while a slot lingers, not once, so each pass
pushed the deadline two seconds further out and the sweep never overtook it.
A peer that received Close and never answered held its slot for as long as it
was watched. Fixed by arming the deadline only when it is still zero; this
probe is the assertion that keeps it armed once.

Every phase asserts BOTH directions, which is what separates "the timeout
works" from "the server hangs up on everyone":

  - an idle keep-alive connection is closed, and no EARLIER than the timeout
  - a connection kept busy across the timeout is not closed
  - a WebSocket peer that never answers Close is reclaimed at the linger,
    and no earlier -- closing before a reply could arrive is the v0.15.1 bug
  - a WebSocket peer that does answer Close is closed at once

usage: idle_timeout_probe.py PORT IDLE_TIMEOUT_SECONDS
"""

import base64
import os
import socket
import struct
import sys
import time
import traceback

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
IDLE = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

# event_loop.mojo's WS_CLOSE_LINGER_NS, in seconds. Not configurable, and
# deliberately not read from anywhere: if it changes, this constant is a
# place someone has to look.
LINGER = 2.0
# The sweep runs once a second, so every deadline here is reached up to a
# second late. Doubled for a loaded CI runner.
SWEEP_SLACK = 2.0
# How far EARLY a close may land before it means the deadline is not being
# honoured at all. Generous: the point is to separate "at the deadline" from
# "immediately", not to measure the clock.
EARLY_SLACK = 0.5

# Which phase is running, for the crash handler below. Every phase here ends
# in a bare `recv` waiting out a deadline, so a traceback names the same line
# whichever assertion was being proven -- and these phases assert OPPOSITE
# things, which is the case a shared traceback is least able to tell apart.
# apps/asgi_bare/ws_probe.py carries the original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("idle_timeout_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped

failures = []


def fail(msg):
    failures.append("%s: %s" % (PHASE, msg))


def wait_for_close(sock, budget):
    """Seconds until a clean FIN, or None if still open after `budget`.

    Against a TOTAL deadline, not a per-recv timeout: a WebSocket gets a
    heartbeat ping every 15 s, and each one resets a per-recv timeout. It
    also means an early version of this probe read a ping as a close and
    reported a 15 s linger, which is why the two are separated here.
    """
    start = time.monotonic()
    while True:
        left = budget - (time.monotonic() - start)
        if left <= 0:
            return None
        sock.settimeout(left)
        try:
            data = sock.recv(4096)
        except socket.timeout:
            return None
        except ConnectionResetError:
            # A reset is not a close: it discards whatever the peer had not
            # read yet, which for a WebSocket is the Close frame itself.
            fail("the connection was RESET, not closed -- a peer far enough "
                 "behind loses the Close frame to it (RFC 6455 5.5.1)")
            return time.monotonic() - start
        if data == b"":
            return time.monotonic() - start


def get(sock, path="/"):
    sock.sendall(
        ("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode()
    )
    sock.settimeout(15)
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        head += chunk
    return head.split(b"\r\n", 1)[0]


def ws_handshake(path="/ws"):
    sock = socket.create_connection((HOST, PORT), timeout=15)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        ("GET %s HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
         "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
         "Sec-WebSocket-Version: 13\r\n\r\n" % (path, key)).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            fail("connection closed during the WebSocket handshake")
            return None
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0] + b" ":
        fail("expected 101, got %r" % head.split(b"\r\n", 1)[0])
        return None
    return sock


def send_frame(sock, opcode, payload):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked)


def read_frame(sock, timeout=15):
    sock.settimeout(timeout)
    head = b""
    while len(head) < 2:
        chunk = sock.recv(2 - len(head))
        if not chunk:
            return None, b""
        head += chunk
    ln = head[1] & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", sock.recv(2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", sock.recv(8))[0]
    body = b""
    while len(body) < ln:
        chunk = sock.recv(ln - len(body))
        if not chunk:
            return None, body
        body += chunk
    return head[0] & 0x0F, body


def read_data_frame(sock):
    """Skip the server's heartbeat pings, answering each as a client must."""
    while True:
        op, payload = read_frame(sock)
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        return op, payload


# --- 1. an idle keep-alive connection is closed, at the deadline -------------
phase("an idle keep-alive connection, which must be closed at the deadline")
sock = socket.create_connection((HOST, PORT), timeout=15)
status = get(sock)
if status is None or b"200" not in status:
    fail("the first request was not answered 200: %r" % status)
else:
    took = wait_for_close(sock, IDLE + SWEEP_SLACK + 3.0)
    if took is None:
        fail("still open %.1fs after being answered (idle timeout %.0fs) -- "
             "nothing closes a connection for idling, so a WebSocket peer "
             "that never answers Close holds its slot forever"
             % (IDLE + SWEEP_SLACK + 3.0, IDLE))
    elif took < IDLE - EARLY_SLACK:
        fail("closed after only %.2fs against a %.0fs idle timeout -- the "
             "deadline is not being honoured" % (took, IDLE))
    elif took > IDLE + SWEEP_SLACK:
        fail("closed after %.2fs, past the %.1fs the sweep allows"
             % (took, IDLE + SWEEP_SLACK))
    else:
        print("  idle keep-alive connection closed after %.2fs (timeout %.0fs)"
              % (took, IDLE))
sock.close()

# --- 2. ...and a busy one is not --------------------------------------------
# The control. Without it a server that closed every connection immediately
# would pass phase 1's upper bound and read as working.
phase("an active connection, which the idle deadline must NOT close")
sock = socket.create_connection((HOST, PORT), timeout=15)
if get(sock) is None:
    fail("the first request was not answered")
else:
    deadline = time.monotonic() + IDLE + SWEEP_SLACK + 1.0
    closed_at = None
    while time.monotonic() < deadline:
        time.sleep(min(1.0, IDLE / 2.0))
        status = get(sock)
        if status is None:
            closed_at = time.monotonic()
            break
        if b"200" not in status:
            fail("a keep-alive request was answered %r" % status)
            break
    if closed_at is not None:
        fail("closed while the client was still making requests every "
             "%.1fs -- the deadline governs idleness, not age"
             % min(1.0, IDLE / 2.0))
    else:
        print("  active connection survived %.1fs of use past a %.0fs timeout"
              % (IDLE + SWEEP_SLACK + 1.0, IDLE))
sock.close()

# --- 3. a WebSocket peer that never answers Close ---------------------------
# The assertion v0.15.1 needs and did not have. Both bounds are the point:
# closing EARLY is the RFC 6455 5.5.1 violation that release fixed, and never
# closing is the leak its own comments say the linger exists to avoid.
phase("a WebSocket peer that receives Close and never answers")
sock = ws_handshake()
if sock is not None:
    send_frame(sock, 0x1, b"bye")
    op, payload = read_data_frame(sock)
    if op != 0x8:
        fail("expected the app's Close frame after 'bye', got op=%s" % op)
    else:
        took = wait_for_close(sock, LINGER + SWEEP_SLACK + 8.0)
        if took is None:
            fail("still open %.1fs after this side sent Close, with no reply "
                 "from the peer -- the %.0fs linger is not bounded, so the "
                 "slot is held for the life of the process"
                 % (LINGER + SWEEP_SLACK + 8.0, LINGER))
        elif took < LINGER - EARLY_SLACK:
            fail("closed %.2fs after sending Close, inside the %.0fs linger "
                 "-- a peer's reply would reach a closed socket and TCP would "
                 "answer RST (RFC 6455 5.5.1)" % (took, LINGER))
        elif took > LINGER + SWEEP_SLACK:
            fail("closed after %.2fs, past the %.1fs the linger plus the "
                 "sweep allows" % (took, LINGER + SWEEP_SLACK))
        else:
            print("  silent WebSocket peer reclaimed after %.2fs "
                  "(linger %.0fs)" % (took, LINGER))
    sock.close()

# --- 4. ...and one that does answer is closed at once -----------------------
phase("a WebSocket peer that answers Close, which must close at once")
sock = ws_handshake()
if sock is not None:
    send_frame(sock, 0x1, b"bye")
    op, payload = read_data_frame(sock)
    if op != 0x8:
        fail("expected the app's Close frame after 'bye', got op=%s" % op)
    else:
        send_frame(sock, 0x8, payload[:2])
        took = wait_for_close(sock, LINGER + SWEEP_SLACK + 5.0)
        if took is None:
            fail("still open after the peer answered Close -- the linger is "
                 "being waited out rather than ended by the reply")
        elif took > LINGER:
            fail("closed %.2fs after the peer answered Close: the reply "
                 "should end the linger, not be waited out" % took)
        else:
            print("  answering WebSocket peer closed after %.2fs" % took)
    sock.close()

if failures:
    for f in failures:
        print("idle_timeout_probe: FAIL:", f)
    sys.exit(1)

print("idle_timeout_probe: idle connections are closed and busy ones are not; "
      "a WebSocket close waits for its reply and is bounded when none comes")
