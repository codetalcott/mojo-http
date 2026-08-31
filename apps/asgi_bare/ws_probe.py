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
import threading
import time
import traceback

# /ws/flood's shape, kept in step with apps/asgi_bare/bareapp/asgi.py.
FLOOD_FRAMES = 400
FLOOD_SIZE = 4096

# How many app-initiated closes the close-order phase runs at once. The
# server used to close its side the instant its own Close frame drained, so
# the peer's reply reached a socket that was already gone and TCP answered
# with an RST. Concurrency is what widens that window, because the loop's
# pass gets longer: on the broken server 17 of 20 reset, and 100 of 100. On
# a fixed one none do at any width, so 64 is decisive without being slow --
# and `poe stress-asgi` drives this probe every round, so it has to be both.
CLOSE_CONNS = 64

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8088"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# Which phase is running, for the crash handler below. The 2026-08-30 CI
# failure was an unhandled ConnectionResetError, and its traceback named a
# line in `recv_exact` -- a helper four phases share -- so the log said
# which CALL reset and not which PHASE was being proven. That is the
# difference between "the flood connection was reset while the client
# stalled" and "something, somewhere, reset".
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    # A reset rather than a clean FIN means the server closed a socket with
    # bytes still queued on it, which the kernel turns into an RST
    # (CLAUDE.md, the chunked-trailer rule). Reported as a finding with its
    # phase, because a bare traceback costs the next investigator the
    # reproduction -- and this probe is driven N times a round by
    # `poe stress-asgi`, where the round number alone is not enough.
    traceback.print_exception(kind, exc, tb)
    print("asgi ws_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("asgi ws_probe FAIL:", msg)
    sys.exit(1)


def recv_exact(sock, n, eof_ok=False):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            if eof_ok:
                # The caller counts what arrived and diagnoses the shortfall
                # itself; an abrupt close IS the finding there.
                raise EOFError()
            fail("connection closed wanting %d bytes (got %d)" % (n, len(buf)))
        buf += chunk
    return buf


def read_frame(sock, eof_ok=False):
    hdr = recv_exact(sock, 2, eof_ok)
    b0, b1 = hdr[0], hdr[1]
    if b1 & 0x80:
        fail("server frame is masked (servers MUST NOT mask)")
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(sock, 2, eof_ok))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(sock, 8, eof_ok))[0]
    return b0 & 0x0F, recv_exact(sock, ln, eof_ok)


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


class Buffered:
    """A socket with a pushback buffer.

    The handshake read can overrun into the first frames -- an application
    that sends immediately has its bytes coalesced with its own 101 by the
    kernel -- and those bytes have to be parsed, not discarded. Asserting
    they never arrive is not an option either: whether they do is a timing
    accident, so a probe that insists on it fails for the wrong reason."""

    def __init__(self, sock, initial=b""):
        self.sock = sock
        self.buf = initial

    def recv(self, n):
        if self.buf:
            out, self.buf = self.buf[:n], self.buf[n:]
            return out
        return self.sock.recv(n)

    def sendall(self, data):
        self.sock.sendall(data)

    def settimeout(self, t):
        self.sock.settimeout(t)

    def close(self):
        self.sock.close()


def handshake(path, what):
    """Open a connection and complete the RFC 6455 handshake for `path`.

    The accept value is verified in `main`'s first connection, which is
    where that property belongs; this is for the later phases, which are
    about what happens AFTER the upgrade."""
    sock = socket.create_connection((HOST, PORT), timeout=30)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET %s HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (path, HOST, PORT, key)
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            fail("no handshake response on %s" % what)
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        fail("%s expected 101, got %r" % (what, head.split(b"\r\n", 1)[0]))
    return Buffered(sock, head.split(b"\r\n\r\n", 1)[1])


def main():
    phase("the echo connection's handshake")
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

    phase("the text and binary echoes")
    send_frame(sock, 0x1, b"hello")
    op, payload = read_data_frame(sock)
    if op != 0x1 or payload != b"echo:hello":
        fail("text echo wrong: op=%d payload=%r" % (op, payload))

    send_frame(sock, 0x2, bytes([0, 1, 255, 128]))
    op, payload = read_data_frame(sock)
    if op != 0x2 or payload != bytes([0, 1, 255, 128]):
        fail("binary echo wrong: op=%d payload=%r" % (op, payload))

    phase("the app-initiated close handshake")
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

    # --- backpressure: a flooding app against a client that stalls -------
    # 400 x 4 KB with no pause, from a client that reads nothing for two
    # seconds. Ungated, `websocket.send` filled the loop's 64 KB per-slot
    # outbox and every frame past it was REFUSED -- 430,693 of 1,638,400
    # bytes delivered under a clean close frame, a message stream with
    # holes the peer had no protocol-level way to detect. The send window
    # makes the application wait instead, so the count here is exact.
    phase("the flood connection (a stalled client against a flooding app)")
    sock = handshake("/ws/flood", "the flood connection")
    time.sleep(2.0)          # stall: the outbox is the only place to go
    got = frames = 0
    closed = False
    while True:
        try:
            op, payload = read_frame(sock, eof_ok=True)
        except EOFError:
            # The server hung up mid-stream: what the loud-refusal guard
            # does when the outbox overflows. Counted and diagnosed below.
            break
        if op == 0x8:
            closed = True
            break
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        if op != 0x2:
            fail("flood: unexpected opcode 0x%x" % op)
        if payload != b"x" * FLOOD_SIZE:
            fail("flood: frame %d is %d bytes, not %d -- the payload was "
                 "corrupted, not merely dropped" % (frames, len(payload),
                                                    FLOOD_SIZE))
        frames += 1
        got += len(payload)
    if frames != FLOOD_FRAMES or got != FLOOD_FRAMES * FLOOD_SIZE:
        fail(
            "flood: %d of %d frames (%d of %d bytes) arrived -- the send "
            "window is not applying backpressure, so the loop's outbox "
            "refused what it could not hold"
            % (frames, FLOOD_FRAMES, got, FLOOD_FRAMES * FLOOD_SIZE)
        )
    if not closed:
        fail("flood: the app's close(1000) never arrived")
    sock.close()

    # --- close order: a Close reply must not be met with an RST ---------
    # RFC 6455 §5.5.1 has the endpoint that sends Close FIRST wait to
    # RECEIVE one before closing the connection. Closing straight after the
    # send instead means the peer's reply lands on a socket that is already
    # gone, and the RST that answers it flushes the peer's receive queue --
    # taking our FIN with it and, on a client far enough behind, the Close
    # frame itself. Measured against the `websockets` library at this width
    # before the fix: 33 of 200 saw `no close frame received or sent`
    # instead of the application's own code 1000, so this is not merely a
    # strict probe being strict.
    #
    # Concurrent because that is what widens the window: one connection at
    # a time, a fast loop closes before the reply is even sent, and the bug
    # hides. It hid for two investigations.
    phase("the close order under %d concurrent closes" % CLOSE_CONNS)
    outcomes = []
    outcomes_lock = threading.Lock()
    gate = threading.Barrier(CLOSE_CONNS)

    def close_once():
        result = "?"
        try:
            conn = handshake("/ws", "a close-order connection")
            gate.wait()
            send_frame(conn, 0x1, b"bye")
            op, body = read_data_frame(conn)
            if op != 0x8:
                result = "op=0x%x, not a close frame" % op
            else:
                send_frame(conn, 0x8, body[:2])
                conn.settimeout(10)
                result = "FIN" if conn.recv(1024) == b"" else "trailing bytes"
            conn.close()
        except ConnectionResetError:
            # The finding: our close reply was answered with a reset.
            result = "RST"
        except Exception as exc:
            result = type(exc).__name__
        with outcomes_lock:
            outcomes.append(result)

    workers = [threading.Thread(target=close_once) for _ in range(CLOSE_CONNS)]
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    clean = outcomes.count("FIN")
    if clean != CLOSE_CONNS:
        summary = ", ".join(
            "%dx %s" % (outcomes.count(o), o) for o in sorted(set(outcomes))
        )
        fail(
            "close order: %d of %d closes ended in a clean FIN (%s) -- the "
            "server is closing before the peer's Close reply, and the RST "
            "that answers the reply discards the close frame with it"
            % (clean, CLOSE_CONNS, summary)
        )

    phase("the abrupt disconnect")
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
