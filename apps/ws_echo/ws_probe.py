#!/usr/bin/env python3
"""Raw RFC 6455 client for smoke-ws — stdlib only, deliberately no websocket lib.

Speaking the wire format by hand is the point: the smoke then proves the
server against the protocol itself, not against a client library's
tolerances. Covers: handshake (Sec-WebSocket-Accept verified), masked text
echo, fragmented message reassembly, client ping -> pong, server heartbeat
pings (when WS_EXPECT_PINGS=1), the close handshake down to the TCP FIN, and
a burst of pings answered whole and in order while the send buffer toward
the client is full (SPEC I31).
"""

import base64
import hashlib
import os
import socket
import struct
import sys
import threading
import time
import traceback

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def fail(msg):
    print("ws_probe FAIL:", msg)
    sys.exit(1)


# Which phase is running, for the crash handler below. Six phases share
# `recv_exact`/`read_frame`, so a traceback out of one says which CALL
# raised and never which PHASE was being proven -- the distinction two
# investigations of the 2026-08-30 CI failure lost.
# apps/asgi_bare/ws_probe.py carries the original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("ws_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


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


# --- Opening handshake, accept key verified against our own computation ------
# The connect is inside the phase: a refused connection is a finding about
# the handshake, not about "startup".
phase("the opening handshake")
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
phase("the text echo round trip")
send_frame(sock, 0x1, b"hello mojo")
op, payload = read_skipping_pings(sock)
if op != 0x1 or payload != b"hello mojo":
    fail("echo mismatch: op=%d payload=%r" % (op, payload))

# --- Fragmented message must come back reassembled ---------------------------
phase("the fragmented message, which must come back reassembled")
send_frame(sock, 0x1, b"frag", fin=False)
send_frame(sock, 0x0, b"ment", fin=True)
op, payload = read_skipping_pings(sock)
if payload != b"fragment":
    fail("fragmented echo mismatch: %r" % payload)

# --- Client ping earns a pong with the same payload --------------------------
phase("the client ping, which must earn a pong")
send_frame(sock, 0x9, b"marco")
op, payload = read_skipping_pings(sock)
if op != 0xA or payload != b"marco":
    fail("pong mismatch: op=%d payload=%r" % (op, payload))

# --- Server heartbeat pings on an idle socket --------------------------------
phase("the server heartbeat pings on an idle socket")
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
phase("the close handshake, down to the TCP FIN")
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

# --- Pings answered while the send buffer toward the client is full ----------
# SPEC I31 (R6). The loop answers control frames itself, one send per read:
# the pongs for every ping a 4 KB read held, or a close echo. That send's
# count was thrown away, so a reply the kernel took only PART of lost its
# tail and the next frame's header landed inside a pong's payload -- every
# frame after it misframed (measured on macOS: a 125-byte pong cut at byte
# 115, followed by 0x8A 0x7D). A reply the kernel refused whole was dropped,
# against RFC 6455 §5.5.2's MUST. So a burst of pings goes out unread
# until the server's buffer is full, and then every pong must come back,
# whole and in order: a cut one misframes the rest, a dropped one is a gap.
# Its own connection, after the main one has closed, so the heartbeats this
# takes seconds of are not waiting on a socket nobody reads.
phase("pings answered while the send buffer toward the client is full")

FLOOD_PINGS = 40000  # 5 MB of pongs, past a send buffer grown to 4 MB
flood = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
# A small window, so the server's buffer fills and stays full.
flood.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
flood.settimeout(10)
flood.connect((HOST, PORT))
fkey = base64.b64encode(os.urandom(16)).decode()
flood.sendall(
    (
        "GET /ws HTTP/1.1\r\nHost: %s:%d\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
        % (HOST, PORT, fkey)
    ).encode()
)
fbuf = b""
while b"\r\n\r\n" not in fbuf:
    chunk = flood.recv(4096)
    if not chunk:
        fail("the flood connection closed during its handshake")
    fbuf += chunk
fhead, fbuf = fbuf.split(b"\r\n\r\n", 1)
if b" 101 " not in fhead.split(b"\r\n")[0] + b" ":
    fail("flood handshake: expected 101, got %r" % fhead.split(b"\r\n")[0])


def flood_payload(i):
    head = b"%09d:" % i
    return head + b"p" * (125 - len(head))


def ping_burst(first, count):
    # A zero masking key masks nothing, so the frames are built without a
    # byte loop; the server unmasks with whatever key a frame carries.
    return b"".join(
        bytes([0x89, 0x80 | 125]) + b"\x00\x00\x00\x00" + flood_payload(i)
        for i in range(first, first + count)
    )


def send_behind(data):
    """Send `data` from a thread: the server stops reading while a reply is
    owed, so a burst this size blocks until the client reads."""

    def run():
        try:
            flood.sendall(data)
        # `err`, not `exc`: phase_stamp_check takes an OSError clause bound
        # to `exc` for the probe's crash handler, and this is a sender
        # thread's -- so named, it hid a removed excepthook from the check.
        except OSError as err:
            print("ws_probe: the ping burst could not all be sent: %r" % err)

    threading.Thread(target=run, daemon=True).start()


SILENCE = "silence"
fbeats = 0


def next_frame():
    """The server's next frame other than a heartbeat ping: (opcode,
    payload), None at EOF, or SILENCE."""
    global fbuf, fbeats
    while True:
        while len(fbuf) >= 2:
            b0, b1 = fbuf[0], fbuf[1]
            n = b1 & 0x7F
            if n > 125 or (b1 & 0x80) or (b0 & 0x70) or not (b0 & 0x80):
                fail("a frame header %02x %02x: the stream is misframed -- a "
                     "reply went out cut" % (b0, b1))
            if len(fbuf) < 2 + n:
                break
            op, payload = b0 & 0x0F, fbuf[2:2 + n]
            fbuf = fbuf[2 + n:]
            if op == 0x9:
                fbeats += 1  # the server's heartbeat; nothing to prove here
                continue
            return op, payload
        try:
            chunk = flood.recv(65536)
        except socket.timeout:
            return SILENCE
        if not chunk:
            return None
        fbuf += chunk


def take_pongs(first, count):
    """Every pong for pings first..first+count-1, whole and in order."""
    for i in range(first, first + count):
        got = next_frame()
        if got == SILENCE:
            fail("only %d of %d pings answered, then silence: the rest were "
                 "dropped while the send buffer was full" % (i - first, count))
        if got is None:
            fail("the connection closed after %d of %d pongs" % (i - first, count))
        op, payload = got
        if op != 0xA:
            fail("opcode %d where the pong for ping %d belonged" % (op, i))
        if payload != flood_payload(i):
            fail("pong %d is %r..., not ping %d's payload: a pong was cut or "
                 "dropped while the send buffer was full" % (i, payload[:20], i))


flood.settimeout(5)
# Unread for a second first: the server answers until its buffer is full,
# and the next reply does not fit.
send_behind(ping_burst(0, FLOOD_PINGS))
time.sleep(1.0)
take_pongs(0, FLOOD_PINGS)

# The socket is whole after the burst: an ordinary close handshake ends it.
# (A close echo that finds the buffer full is queued the same way, and the
# socket closes once it has gone out; this does not force that case -- the
# echo is the last reply, and whether the buffer is still full when it is
# sent is not the client's to arrange.)
flood.sendall(bytes([0x88, 0x80 | 2]) + b"\x00\x00\x00\x00" + struct.pack(">H", 1000))
got = next_frame()
if got is None or got == SILENCE or got[0] != 0x8:
    fail("no close echo after the burst (got %r)" % (got,))
if got[1] != struct.pack(">H", 1000):
    fail("the close echo carries %r, not the 1000 sent" % (got[1],))
got = next_frame()
if got is not None:
    fail("expected the TCP close after the close echo, got %r" % (got,))
if fbuf:
    fail("%d bytes after the close echo: %r" % (len(fbuf), fbuf[:20]))
flood.close()
print("ws_probe: %d pings answered whole and in order with the send buffer "
      "full (%d heartbeats between), then the close handshake"
      % (FLOOD_PINGS, fbeats))

print("ws_probe OK")
