#!/usr/bin/env python3
"""Raw RFC 6455 client for smoke-ws — stdlib only, deliberately no websocket lib.

Speaking the wire format by hand is the point: the smoke then proves the
server against the protocol itself, not against a client library's
tolerances. Covers: handshake (Sec-WebSocket-Accept verified), masked text
echo, fragmented message reassembly, client ping -> pong, server heartbeat
pings (when WS_EXPECT_PINGS=1), and the close handshake down to the TCP FIN.
"""

import base64
import hashlib
import os
import socket
import struct
import sys
import time

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def fail(msg):
    print("ws_probe FAIL:", msg)
    sys.exit(1)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            fail("connection closed wanting %d bytes (got %d)" % (n, len(buf)))
        buf += chunk
    return buf


def read_frame(sock):
    hdr = recv_exact(sock, 2)
    b0, b1 = hdr[0], hdr[1]
    if b1 & 0x80:
        fail("server frame is masked (servers MUST NOT mask)")
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


def read_skipping_pings(sock):
    """Next non-ping frame; server heartbeat pings get their pong and are skipped.

    Bounded: at the smoke's 400ms cadence, 10 consecutive pings means ~4s
    passed without the frame we're waiting for — the answer is missing, and
    an unbounded skip-loop would turn that into a hang instead of a failure.
    """
    for _ in range(10):
        op, payload = read_frame(sock)
        if op != 0x9:
            return op, payload
        send_frame(sock, 0xA, payload)
    fail("only heartbeat pings arriving; the awaited frame never came")


sock = socket.create_connection((HOST, PORT), timeout=10)

# --- Opening handshake, accept key verified against our own computation ------
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
head, leftover = resp.split(b"\r\n\r\n", 1)
lines = head.decode("latin-1").split("\r\n")
if " 101 " not in lines[0] + " ":
    fail("expected 101, got: " + lines[0])
accept = None
for line in lines[1:]:
    if line.lower().startswith("sec-websocket-accept:"):
        accept = line.split(":", 1)[1].strip()
expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
if accept != expected:
    fail("bad accept key: %r != %r" % (accept, expected))
if leftover:
    fail("unexpected bytes before any frame was sent: %r" % leftover)

# --- Echo round trip (masked text out, unmasked text back) -------------------
send_frame(sock, 0x1, b"hello mojo")
op, payload = read_skipping_pings(sock)
if op != 0x1 or payload != b"hello mojo":
    fail("echo mismatch: op=%d payload=%r" % (op, payload))

# --- Fragmented message must come back reassembled ---------------------------
send_frame(sock, 0x1, b"frag", fin=False)
send_frame(sock, 0x0, b"ment", fin=True)
op, payload = read_skipping_pings(sock)
if payload != b"fragment":
    fail("fragmented echo mismatch: %r" % payload)

# --- Client ping earns a pong with the same payload --------------------------
send_frame(sock, 0x9, b"marco")
op, payload = read_skipping_pings(sock)
if op != 0xA or payload != b"marco":
    fail("pong mismatch: op=%d payload=%r" % (op, payload))

# --- Server heartbeat pings on an idle socket --------------------------------
if os.environ.get("WS_EXPECT_PINGS"):
    pings = 0
    sock.settimeout(3.0)
    deadline = time.time() + 2.0
    while time.time() < deadline:
        try:
            op, payload = read_frame(sock)
        except socket.timeout:
            break
        if op == 0x9:
            pings += 1
            send_frame(sock, 0xA, payload)
    # Cadence is 400ms over a ~2s window: fewer than 2 means the one-shot
    # heartbeat timer never re-armed; an absurd count is the level-triggered
    # timer storm (same failure shapes the SSE smoke pins).
    if pings < 2:
        fail("expected >=2 heartbeat pings, saw %d" % pings)
    if pings > 40:
        fail("ping storm: %d pings in ~2s at 400ms cadence" % pings)
    sock.settimeout(10)

# --- Close handshake: echo with our code, then a real TCP close --------------
send_frame(sock, 0x8, struct.pack(">H", 1000))
op, payload = read_skipping_pings(sock)
if op != 0x8:
    fail("expected close echo, got op=%d" % op)
if len(payload) < 2 or struct.unpack(">H", payload[:2])[0] != 1000:
    fail("close code not echoed: %r" % payload)
try:
    rest = sock.recv(1024)
except socket.timeout:
    fail("server did not close TCP after the close handshake")
if rest != b"":
    fail("expected TCP close after close frame, got %r" % rest)

print("ws_probe OK")
