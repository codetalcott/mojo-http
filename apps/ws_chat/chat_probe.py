#!/usr/bin/env python3
"""Raw RFC 6455 chat client for smoke-chat — stdlib only.

Single-worker mode (default): two sockets, one speaks, both must hear it —
the sender included (its own message coming back is the delivery
confirmation).

Multi-worker mode (CHAT_EXPECT_WORKERS=2): sockets are opened in
concurrent bursts until they provably span two workers (the X-Worker
header on each 101 says who owns each socket — sequential opens can all be
won by whichever worker is hottest, the same accept-race bias the counter
smoke hit on 2-core CI runners), then ONE message sent on a worker-A
socket must arrive on every socket, including worker B's — those cross the
BroadcastBus.
"""

import os
import socket
import struct
import sys
import threading
import time
import base64
import hashlib

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
EXPECT_WORKERS = int(os.environ.get("CHAT_EXPECT_WORKERS", "1"))


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


def open_burst(n):
    """n concurrent connects — simultaneous connections leave pending work
    for both workers' wakeups, where a sequential trickle can be won by
    whichever worker is hottest every time."""
    results = [None] * n

    def one(i):
        try:
            results[i] = connect_ws()
        except SystemExit:
            raise
        except Exception as e:  # noqa: BLE001 - collected and reported below
            results[i] = e

    threads = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return [r for r in results if isinstance(r, tuple)]


def agitate():
    """Overlapping plain-HTTP requests pull the hot worker off the listener
    so the other one wins some of the next burst."""

    def one():
        try:
            s = socket.create_connection((HOST, PORT), timeout=2)
            s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            s.recv(4096)
            s.close()
        except OSError:
            pass

    threads = [threading.Thread(target=one) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def close_all(socks):
    for s in socks:
        try:
            send_frame(s, 0x8, struct.pack(">H", 1000))
            s.close()
        except OSError:
            pass


if EXPECT_WORKERS <= 1:
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

# --- Multi-worker: spread first, then one message must reach everyone --------
conns = []
for _ in range(6):
    conns.extend(open_burst(4))
    if len(set(w for _, w in conns)) >= 2:
        break
    time.sleep(1)
    agitate()

workers = set(w for _, w in conns)
if len(workers) < 2:
    close_all([s for s, _ in conns])
    fail("sockets never spread across two workers (saw: %s)" % sorted(workers))

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
