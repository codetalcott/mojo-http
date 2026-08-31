#!/usr/bin/env python3
"""Stdlib WS client for smoke-fasthtml: FastHTML's `app.ws` handler takes
its arguments from a JSON message, so this sends `{"msg": "hello"}` and
expects the handler's `ws-echo:hello` frame back."""

import base64
import os
import socket
import struct
import sys
import traceback

PORT = int(os.environ.get("M0_PORT", "8097"))


# Which phase is running, for the crash handler below. A traceback names the
# CALL that raised -- `read_frame`, which both phases share -- and never the PHASE being proven.
# apps/asgi_bare/ws_probe.py carries the original of this comment and the
# 2026-08-30 failure that motivated it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("fasthtml ws_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def send_frame(sock, opcode, payload):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    hdr = struct.pack(">BB", 0x80 | opcode, 0x80 | len(payload))
    sock.sendall(hdr + mask + masked)


def read_frame(sock):
    hdr = sock.recv(2)
    b0, b1 = hdr[0], hdr[1]
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", sock.recv(2))[0]
    buf = b""
    while len(buf) < ln:
        buf += sock.recv(ln - len(buf))
    return b0 & 0x0F, buf


def main():
    phase("the opening handshake")
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
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
        chunk = s.recv(4096)
        if not chunk:
            print("fasthtml ws_probe FAIL: no handshake")
            sys.exit(1)
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        print("fasthtml ws_probe FAIL: expected 101, got %r" % head[:40])
        sys.exit(1)
    phase("the echo round trip")
    send_frame(s, 0x1, b'{"msg":"hello"}')
    op, payload = read_frame(s)
    while op == 0x9:  # heartbeat ping
        send_frame(s, 0xA, payload)
        op, payload = read_frame(s)
    if op != 0x1 or b"ws-echo:hello" not in payload:
        print("fasthtml ws_probe FAIL: op=%d payload=%r" % (op, payload))
        sys.exit(1)
    s.close()
    print("fasthtml ws_probe OK")


if __name__ == "__main__":
    main()
