#!/usr/bin/env python3
"""Raw RFC 6455 chat client for smoke-chat — stdlib only.

Single-worker mode (default): two sockets, one speaks, both must hear it —
the sender included (its own message coming back is the delivery
confirmation).

Multi-worker mode (CHAT_EXPECT_WORKERS=2): one socket is placed on EACH
worker by freezing the worker that wins the first one (the X-Worker
header on each 101 says who owns each socket — sequential opens can all be
won by whichever worker is hottest, the same accept-race bias the counter
smoke hit on 2-core CI runners), then ONE message sent on a worker-A
socket must arrive on every socket, including worker B's — those cross the
BroadcastBus.
"""

import os
import signal
import socket
import struct
import sys
import traceback
import base64
import hashlib

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
EXPECT_WORKERS = int(os.environ.get("CHAT_EXPECT_WORKERS", "1"))


# Which phase is running, for the crash handler below. Every phase here
# reaches the socket through `recv_exact`/`read_text`, so a traceback out of
# one says which CALL raised and never which PHASE was being proven -- and
# this probe's phases mean different things (a handshake that never
# completed, versus a message that never crossed the bus). Two
# investigations of the 2026-08-30 CI failure were lost to that distinction;
# apps/asgi_bare/ws_probe.py carries the original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("chat_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("chat_probe FAIL:", msg)
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
    hdr = recv_exact(sock, 2)
    b0, b1 = hdr[0], hdr[1]
    if b1 & 0x80:
        fail("server frame is masked")
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(sock, 8))[0]
    return b0 & 0x0F, recv_exact(sock, ln)


def send_frame(sock, opcode, payload, fin=True):
    b0 = (0x80 if fin else 0) | opcode
    mask = os.urandom(4)
    n = len(payload)
    header = bytes([b0])
    if n <= 125:
        header += bytes([0x80 | n])
    elif n <= 0xFFFF:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    sock.sendall(header + mask + masked)


def read_text(sock, timeout=6.0):
    """Next text frame's payload; heartbeat pings get pongs and are skipped."""
    sock.settimeout(timeout)
    for _ in range(20):
        op, payload = read_frame(sock)
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        if op == 0x1:
            return payload
        fail("unexpected frame op=%d while waiting for text" % op)
    fail("only pings arriving; the chat message never came")


def connect_ws():
    """Open one chat socket; returns (socket, owning worker id)."""
    sock = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws HTTP/1.1\r\nHost: %s:%d\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
            % (HOST, PORT, key)
        ).encode()
    )
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            fail("connection closed during handshake")
        resp += chunk
    head = resp.split(b"\r\n\r\n")[0].decode("latin-1")
    lines = head.split("\r\n")
    if " 101 " not in lines[0] + " ":
        fail("expected 101, got: " + lines[0])
    accept = worker = None
    for line in lines[1:]:
        low = line.lower()
        if low.startswith("sec-websocket-accept:"):
            accept = line.split(":", 1)[1].strip()
        if low.startswith("x-worker:"):
            worker = line.split(":", 1)[1].strip()
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if accept != expected:
        fail("bad accept key")
    if worker is None:
        fail("no X-Worker header on the upgrade response")
    return sock, worker


def close_all(socks):
    for s in socks:
        try:
            send_frame(s, 0x8, struct.pack(">H", 1000))
            s.close()
        except OSError:
            pass


if EXPECT_WORKERS <= 1:
    phase("two sockets on one worker, and a message reaching both")
    a = connect_ws()
    b = connect_ws()
    send_frame(a[0], 0x1, b"hello room")
    for name, (sock, _) in (("sender", a), ("other", b)):
        got = read_text(sock)
        if got != b"hello room":
            fail("%s socket heard %r, wanted b'hello room'" % (name, got))
    close_all([a[0], b[0]])
    print("chat_probe OK (single worker)")
    sys.exit(0)

# --- Multi-worker: one socket per worker, then one message reaches both ------
# Which worker wins an accept is the kernel's choice and it is not a fair
# one: a macOS runner once handed a single worker every one of 24 opens,
# failing this precondition with nothing wrong in the server. Opening in
# bursts made it worse, not better — the accept path drains the backlog
# until EAGAIN, so the first worker to wake takes the whole burst.
#
# So stop racing. Open one socket, SIGSTOP the worker that got it (X-Worker
# is that worker's pid), and open the second: a stopped process cannot
# accept, so it provably lands on the other worker. Resume immediately —
# the frozen worker's own socket is idle meanwhile, and the assertions
# below are unchanged.
phase("landing one socket on each worker (the second under SIGSTOP)")
sock_a, w_a = connect_ws()
os.kill(int(w_a), signal.SIGSTOP)
try:
    sock_b, w_b = connect_ws()
finally:
    os.kill(int(w_a), signal.SIGCONT)

conns = [(sock_a, w_a), (sock_b, w_b)]
workers = set(w for _, w in conns)
if len(workers) < 2:
    close_all([s for s, _ in conns])
    fail("both sockets landed on worker %s even though it was SIGSTOPped" % w_a)

phase("one message reaching both workers over the bus")
sender_sock, sender_worker = conns[0]
msg = b"hello from " + sender_worker.encode()
send_frame(sender_sock, 0x1, msg)

cross_checked = 0
for sock, worker in conns:
    got = read_text(sock)
    if got != msg:
        fail(
            "socket on worker %s heard %r, wanted %r"
            % (worker, got, msg)
        )
    if worker != sender_worker:
        cross_checked += 1

close_all([s for s, _ in conns])
print(
    "chat_probe OK (%d sockets across %d workers, %d heard it over the bus)"
    % (len(conns), len(workers), cross_checked)
)
