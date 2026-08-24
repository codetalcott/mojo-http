#!/usr/bin/env python3
"""Raw RFC 6455 client for smoke-asgi's WebSocket phase — stdlib only.

The same hand-rolled wire format as apps/ws_echo/ws_probe.py, against the
ASGI echo at /ws: handshake (Sec-WebSocket-Accept verified), masked text
echo (the app prefixes "echo:"), binary echo, then "bye" → the app's
websocket.close(1000) → close frame → TCP FIN — proving the executor's
accept/perform split, both frame directions, and the close-after-drain.
"""

import base64
import hashlib
import os
import socket
import struct
import sys

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8088"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def fail(msg):
    print("asgi ws_probe FAIL:", msg)
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


def read_data_frame(sock):
    # Skip server pings (heartbeats) transparently, answering with pongs.
    while True:
        op, payload = read_frame(sock)
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        return op, payload


def send_frame(sock, opcode, payload):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    ln = len(payload)
    if ln < 126:
        hdr = struct.pack(">BB", 0x80 | opcode, 0x80 | ln)
    elif ln < 65536:
        hdr = struct.pack(">BBH", 0x80 | opcode, 0x80 | 126, ln)
    else:
        hdr = struct.pack(">BBQ", 0x80 | opcode, 0x80 | 127, ln)
    sock.sendall(hdr + mask + masked)


def main():
    sock = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (HOST, PORT, key)
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            fail("no handshake response")
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        fail("expected 101, got %r" % head.split(b"\r\n", 1)[0])
    want = base64.b64encode(
        hashlib.sha1((key + GUID).encode()).digest()
    ).decode()
    if ("sec-websocket-accept: %s" % want).encode() not in head.lower().replace(
        want.lower().encode(), want.encode()
    ):
        # Case-insensitive header name, exact accept value.
        accept_line = [
            l for l in head.split(b"\r\n") if l.lower().startswith(b"sec-websocket-accept:")
        ]
        if not accept_line or accept_line[0].split(b":", 1)[1].strip() != want.encode():
            fail("bad Sec-WebSocket-Accept")

    send_frame(sock, 0x1, b"hello")
    op, payload = read_data_frame(sock)
    if op != 0x1 or payload != b"echo:hello":
        fail("text echo wrong: op=%d payload=%r" % (op, payload))

    send_frame(sock, 0x2, bytes([0, 1, 255, 128]))
    op, payload = read_data_frame(sock)
    if op != 0x2 or payload != bytes([0, 1, 255, 128]):
        fail("binary echo wrong: op=%d payload=%r" % (op, payload))

    send_frame(sock, 0x1, b"bye")
    op, payload = read_data_frame(sock)
    if op != 0x8:
        fail("expected close frame after bye, got op=%d %r" % (op, payload))
    if len(payload) >= 2 and struct.unpack(">H", payload[:2])[0] != 1000:
        fail("close code != 1000: %r" % payload[:2])
    # Close handshake reply, then the server should FIN.
    send_frame(sock, 0x8, payload[:2])
    sock.settimeout(5)
    try:
        rest = sock.recv(1024)
    except socket.timeout:
        fail("no FIN after close handshake")
    if rest not in (b"",):
        # Tolerate a duplicate close echo before FIN.
        try:
            rest = sock.recv(1024)
        except socket.timeout:
            fail("no FIN after close echo")
        if rest != b"":
            fail("unexpected bytes after close: %r" % rest)
    sock.close()

    # Second connection: vanish abruptly after the 101, no close
    # handshake — the disconnect tag must cancel the app task and the
    # server must stay healthy (the smoke checks health right after).
    sock = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (HOST, PORT, key)
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            fail("no handshake response on the abrupt connection")
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        fail("abrupt connection expected 101")
    sock.close()
    print("asgi ws_probe OK")


if __name__ == "__main__":
    main()
