#!/usr/bin/env python3
"""Stdlib WS client for smoke-fastapi.

FastAPI's `@app.websocket` handler takes plain text (FastHTML's `app.ws`
takes a JSON message, which is why that app has a probe of its own), so
this sends `hello` and expects `ws-echo:hello` back, then drives the
app-initiated close through FastAPI's `websocket.close(1000)`.

The bare ASGI probe proves the close ORDER against a hand-written app
(SPEC L15/L16, and its close phase runs 64 at once, which is what caught
the missing linger). This one asks the narrower question the row is for:
that a framework's own close API reaches the same seam.
"""

import base64
import os
import socket
import struct
import sys
import traceback

PORT = int(os.environ.get("M0_PORT", "8099"))

# Which phase is running, for the crash handler. A traceback names the CALL
# that raised -- `read_frame`, which every phase shares -- and never the
# PHASE being proven. apps/asgi_bare/ws_probe.py carries the original of
# this comment and the 2026-08-30 failure that motivated it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("fastapi ws_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("fastapi ws_probe FAIL:", msg)
    sys.exit(1)


def send_frame(sock, opcode, payload):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(struct.pack(">BB", 0x80 | opcode, 0x80 | len(payload)) + mask + masked)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            fail("connection closed wanting %d bytes (got %d)" % (n, len(buf)))
        buf += chunk
    return buf


def read_frame(sock):
    b0, b1 = recv_exact(sock, 2)
    if b1 & 0x80:
        fail("server frame is masked (servers MUST NOT mask)")
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(sock, 8))[0]
    return b0 & 0x0F, (recv_exact(sock, ln) if ln else b"")


def read_data_frame(sock):
    """A data or close frame, answering the loop's heartbeat pings on the way."""
    while True:
        op, payload = read_frame(sock)
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        return op, payload


def main():
    phase("the opening handshake")
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (PORT, key)
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            fail("no handshake response")
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        fail("expected 101, got %r" % head[:40])

    phase("the echo round trip")
    send_frame(sock, 0x1, b"hello")
    op, payload = read_data_frame(sock)
    if op != 0x1 or b"ws-echo:hello" not in payload:
        fail("echo wrong: op=%d payload=%r" % (op, payload))

    phase("the app-initiated close handshake")
    send_frame(sock, 0x1, b"bye")
    op, payload = read_data_frame(sock)
    if op != 0x8:
        fail("expected a close frame after bye, got op=%d %r" % (op, payload))
    if len(payload) >= 2 and struct.unpack(">H", payload[:2])[0] != 1000:
        fail("close code != 1000: %r" % payload[:2])
    # Reply, then the server must FIN rather than reset: it closed first, so
    # RFC 6455 5.5.1 has it wait for this frame before closing the socket.
    send_frame(sock, 0x8, payload[:2])
    sock.settimeout(5)
    try:
        rest = sock.recv(1024)
    except socket.timeout:
        fail("no FIN after the close handshake")
    except ConnectionResetError:
        fail("RST after the close handshake: the server closed with bytes queued")
    if rest != b"":
        fail("unexpected bytes after close: %r" % rest)
    sock.close()
    print("fastapi ws_probe OK")


if __name__ == "__main__":
    main()
