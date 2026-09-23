#!/usr/bin/env python3
"""What an ASGI application is told when its WebSocket client leaves, and an
inbound message the executor's channel cannot carry (SPEC L28, I26).

    python3 scripts/ws_close_probe.py --port 8088

Against apps/asgi_bare's `/ws/record`, which echoes and keeps the code its
`websocket.disconnect` carried, read back from `/ws-last-close`:

- a Close with 1001 is heard as 1001, one with no code as 1005, and a
  connection that ends without a Close as 1006 (RFC 6455 §7.1.5). The
  executor used to say 1006 for every one of them;
- a 70,000-byte message, larger than the executor channel's 65,546-byte
  datagram, is refused with a Close carrying 1009, and the application
  hears 1009. It used to be parked and retried for ever: no reply, no close,
  no log -- a 70 KB chat message went silent;
- a message at the cap (65,536 bytes) is still echoed whole;
- and the server answers afterwards.

Stdlib only; exits 0 when every case holds.
"""

import argparse
import base64
import hashlib
import os
import socket
import struct
import sys
import time
import traceback

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PORT = 8088

# Which case is running, for the crash handler: a reset or a timeout inside a
# helper four cases share says nothing without it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("ws_close_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("ws_close_probe FAIL: %s: %s" % (PHASE, msg))
    sys.exit(1)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed wanting %d bytes (got %d)" % (n, len(buf)))
        buf += chunk
    return buf


def read_frame(sock):
    b0, b1 = recv_exact(sock, 2)
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(sock, 8))[0]
    return b0 & 0x0F, recv_exact(sock, ln)


def read_data_or_close(sock):
    # Pings (the heartbeat) are answered and skipped.
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


def connect():
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws/record HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % key
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            fail("closed during the handshake")
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        fail("handshake answered %r" % head.split(b"\r\n", 1)[0])
    want = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest())
    if want not in head:
        fail("bad Sec-WebSocket-Accept")
    return sock


def http_get(path):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" % path).encode())
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    head, _, body = data.partition(b"\r\n\r\n")
    return head.split(b"\r\n", 1)[0], body.decode("latin-1")


def heard(want, within=5.0):
    """The code the application was told, polled: the disconnect reaches it
    asynchronously."""
    seen = None
    deadline = time.time() + within
    while time.time() < deadline:
        _, seen = http_get("/ws-last-close")
        if seen == str(want):
            return
        time.sleep(0.05)
    fail("the application heard %r, want %d" % (seen, want))


def close_with(payload):
    sock = connect()
    send_frame(sock, 0x1, b"hi")
    op, got = read_data_or_close(sock)
    if (op, got) != (0x1, b"hi"):
        fail("echo was %r" % ((op, got),))
    send_frame(sock, 0x8, payload)
    try:
        op, _ = read_data_or_close(sock)
        if op != 0x8:
            fail("the server answered a Close with opcode %d" % op)
    except (EOFError, OSError):
        pass
    sock.close()


def main():
    global PORT
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=PORT)
    PORT = ap.parse_args().port

    phase("Close 1001")
    close_with(struct.pack(">H", 1001) + b"going away")
    heard(1001)

    phase("Close with no code")
    close_with(b"")
    heard(1005)

    phase("no Close at all")
    sock = connect()
    send_frame(sock, 0x1, b"hi")
    read_data_or_close(sock)
    sock.shutdown(socket.SHUT_RDWR)
    sock.close()
    heard(1006)

    phase("a message at the channel's cap")
    sock = connect()
    at_cap = os.urandom(65536)
    send_frame(sock, 0x2, at_cap)
    op, got = read_data_or_close(sock)
    if op != 0x2 or got != at_cap:
        fail("the 65,536-byte message came back as opcode %d, %d bytes" % (op, len(got)))
    send_frame(sock, 0x8, struct.pack(">H", 1000))
    sock.close()
    heard(1000)

    phase("a message the channel cannot carry")
    sock = connect()
    sock.settimeout(5)
    send_frame(sock, 0x2, b"o" * 70000)
    try:
        op, got = read_data_or_close(sock)
    except socket.timeout:
        fail("no answer to a 70,000-byte message in 5 s: parked, not refused")
    if op != 0x8:
        fail("a 70,000-byte message was answered with opcode %d, not a Close" % op)
    code = struct.unpack(">H", got[:2])[0] if len(got) >= 2 else None
    if code != 1009:
        fail("the Close carried %r, want 1009" % code)
    sock.close()
    heard(1009)

    phase("the server afterwards")
    status, _ = http_get("/")
    if b" 200 " not in status:
        fail("GET / answered %r" % status)
    print("ws_close_probe OK: 1001, 1005, 1006, at-cap echo, 1009 refusal")


if __name__ == "__main__":
    main()
