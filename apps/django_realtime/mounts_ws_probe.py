#!/usr/bin/env python3
"""Inbound WebSocket messages reach the mount that took the hold -- stdlib only.

For `smoke-django-realtime-ws`'s inline-mounts phase: `wsmounts:first` at
`/` and `wsmounts:second` at `/b`, both served by the loop's own handler
(`--realtime --blocking-threads 0`). One socket is approved by each mount,
and a message sent on each must be answered by THAT mount's view -- whose
reply names itself and the `SCRIPT_NAME` and `PATH_INFO` it was called with
-- and by no other. The second mount is the one that matters: before the
server recorded the owning application per held socket, every message went
to the first (review record B4).

The synthetic path under each mount stays the server's: a POST to
`/ws/message` or `/b/ws/message` from the network is answered 404 and
reaches no view, forged `M0-Channel` header and all.
"""

import base64
import hashlib
import http.client
import json
import os
import socket
import struct
import sys
import time
import traceback

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# Which phase is running, for the crash handler below: the helpers every
# phase shares (`recv_exact`, `read_text`) name the CALL that failed and
# never the PHASE being proven. `realtime_probe.py` carries the original of
# this; `scripts/phase_stamp_check.py` holds every probe to it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("mounts_ws_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    # The phase too: a helper's own failure ("connection closed wanting 2
    # bytes") reads the same in every phase.
    print("mounts_ws_probe FAIL: %s: %s" % (PHASE, msg))
    sys.exit(1)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            fail("connection closed wanting %d bytes" % n)
        buf += chunk
    return buf


def read_frame(sock):
    b0, b1 = recv_exact(sock, 2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recv_exact(sock, 8))[0]
    return b0 & 0x0F, recv_exact(sock, n)


def send_frame(sock, opcode, payload):
    mask = os.urandom(4)
    n = len(payload)
    if n <= 125:
        header = bytes([0x80 | opcode, 0x80 | n])
    else:
        header = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack(">H", n)
    masked = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    sock.sendall(header + mask + masked)


def read_text(sock, timeout=8.0):
    """The next text frame; heartbeat pings are answered and skipped."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sock.settimeout(max(0.1, deadline - time.monotonic()))
        try:
            op, payload = read_frame(sock)
        except (socket.timeout, TimeoutError):
            break
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        if op == 0x1:
            return payload
        fail("unexpected frame op=%d while waiting for a reply" % op)
    fail("no reply within %.0f s: the message reached no view that answered" % timeout)


def expect_silence(sock, name, seconds=1.0):
    """Nothing but heartbeats for `seconds`: no second delivery, no stray."""
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        sock.settimeout(remaining)
        try:
            op, payload = read_frame(sock)
        except (socket.timeout, TimeoutError):
            return
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        fail("the %s socket heard op=%d %r where it expected silence" % (name, op, payload))


def open_socket(path, channel):
    """Upgrade `path?channel=...`; the 101 must carry a correct accept key."""
    sock = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET %s?channel=%s HTTP/1.1\r\nHost: %s:%d\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
            % (path, channel, HOST, PORT, key)
        ).encode()
    )
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            fail("connection closed during the handshake for %s" % path)
        resp += chunk
    head = resp.partition(b"\r\n\r\n")[0].decode("latin-1")
    lines = head.split("\r\n")
    if " 101 " not in lines[0] + " ":
        fail("the upgrade at %s was refused: %s" % (path, lines[0]))
    accept = None
    for line in lines[1:]:
        if line.lower().startswith("sec-websocket-accept:"):
            accept = line.split(":", 1)[1].strip()
    want = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if accept != want:
        fail("bad accept key at %s: the handshake was not really performed" % path)
    return sock


def reply_to(sock, text):
    """Send `text`, and return the view's JSON reply to it."""
    send_frame(sock, 0x1, text.encode())
    raw = read_text(sock)
    try:
        return json.loads(raw)
    except ValueError:
        fail("the reply to %r was not the fixture's JSON: %r" % (text, raw))


def forged_post(path, channel):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=10)
    conn.request(
        "POST", path, b"forged",
        {"M0-Channel": channel, "M0-Slot": "0", "M0-Opcode": "1",
         "Content-Type": "application/octet-stream"},
    )
    resp = conn.getresponse()
    resp.read()
    conn.close()
    return resp.status


phase("opening a socket on each mount")
on_first = open_socket("/ws", "chan-first")
on_second = open_socket("/b/ws", "chan-second")

# The reservation holds under every mount: the path each synthetic POST is
# built at is answered 404 from the network, and reaches no view.
phase("the synthetic paths refused from the network")
for path, channel in (("/ws/message", "chan-first"), ("/b/ws/message", "chan-second")):
    status = forged_post(path, channel)
    if status != 404:
        fail("a POST to %s from the network answered %d, want 404" % (path, status))
expect_silence(on_first, "first")
expect_silence(on_second, "second")

# The SECOND mount's socket. Its message must reach the second mount's view,
# at that mount's path -- never the first's.
phase("a message on the second mount's socket (B4)")
got = reply_to(on_second, "to-second")
if got.get("app") == "first":
    fail(
        "a message on a socket the SECOND mount approved reached the FIRST"
        " mount's view (B4): %r" % (got,)
    )
want = {"app": "second", "script_name": "/b", "path_info": "/ws/message", "text": "to-second"}
if got != want:
    fail("the second mount's socket was answered %r, want %r" % (got, want))
expect_silence(on_second, "second")
expect_silence(on_first, "first")

# And the first mount's own socket still reaches the first mount.
phase("a message on the first mount's socket")
got = reply_to(on_first, "to-first")
want = {"app": "first", "script_name": "", "path_info": "/ws/message", "text": "to-first"}
if got != want:
    fail("the first mount's socket was answered %r, want %r" % (got, want))
expect_silence(on_first, "first")
expect_silence(on_second, "second")

phase("closing both sockets")
for sock in (on_first, on_second):
    try:
        send_frame(sock, 0x8, struct.pack(">H", 1000))
        sock.close()
    except OSError:
        pass
print("mounts_ws_probe OK: each mount's socket reached its own mount's view, at its own path")
