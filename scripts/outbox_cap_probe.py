#!/usr/bin/env python3
"""A message at or above the outbox cap ends the connection (SPEC I17).

`MAX_PENDING_BYTES` (64 KB, `src/sse/registry.mojo`) bounds ONE frame as well
as the whole queue, so a message at or above it can never be queued however
patient the sender is. The executor's credit gate cannot rescue it and does
not try -- `_ws_spend` clamps a request bigger than the window rather than
waiting for credit that can never exist -- so the frame reaches the outbox,
`queue_frame` refuses it, and the server's answer is to END the connection.

That answer is deliberate, and this is what it is worth: a dropped WebSocket
frame is a message the peer has no protocol-level way to notice it missed. The
broken shape is not a crash, it is a CLEAN conversation with a hole in it --
the marker after the oversized message arriving under a `close(1000)`, exactly
as if the server had sent everything. So the assertion is not "something went
wrong" but "the connection ended INSTEAD of lying", and the marker is what
tells those apart.

The under-cap message is the other half. A server that ended every connection
carrying a large message would pass a test that only looked for the ending.

Run against `apps/asgi_bare` under `m0serve`.

Usage: outbox_cap_probe.py PORT
"""
import base64
import os
import socket
import struct
import sys
import traceback

# The phase stamp: both phases share `recv_message`, so a raise inside it
# names the call and not the claim. See scripts/phase_stamp_check.py.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("outbox_cap_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped

# Kept in step with apps/asgi_bare/bareapp/asgi.py.
OVERSIZED_UNDER = 32 * 1024
OVERSIZED_OVER = 66 * 1024
OVERSIZED_MARKER = b"after-the-oversized-message"
HOST = "127.0.0.1"


def fail(msg):
    print("outbox-cap: " + msg)
    sys.exit(1)


class Sock:
    """One connection with a single buffered reader.

    Reading the handshake with `makefile()` and the frames with `recv()`
    loses whatever the reader buffered, which reads as "the server sent
    nothing" -- the same false negative this probe exists to distinguish
    from a real one.
    """

    def __init__(self, port, timeout=20):
        self.s = socket.create_connection((HOST, port), timeout=timeout)
        self.buf = b""
        self.eof = False

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass

    def _fill(self):
        try:
            chunk = self.s.recv(65536)
        except (ConnectionResetError, socket.timeout):
            self.eof = True
            return False
        if not chunk:
            self.eof = True
            return False
        self.buf += chunk
        return True

    def read_exactly(self, n):
        while len(self.buf) < n:
            if not self._fill():
                break
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def handshake(self, path):
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(
            ("GET %s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
             "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
             "Sec-WebSocket-Version: 13\r\n\r\n" % (path, key)).encode()
        )
        while b"\r\n\r\n" not in self.buf:
            if not self._fill():
                return None
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        self.buf = rest
        return head.split(b"\r\n")[0].decode("latin-1")

    def recv_message(self):
        """One frame: (opcode, payload). (None, b'') at EOF or close."""
        head = self.read_exactly(2)
        if len(head) < 2:
            return None, b""
        opcode = head[0] & 0x0F
        length = head[1] & 0x7F
        if length == 126:
            ext = self.read_exactly(2)
            if len(ext) < 2:
                return None, b""
            length = struct.unpack("!H", ext)[0]
        elif length == 127:
            ext = self.read_exactly(8)
            if len(ext) < 8:
                return None, b""
            length = struct.unpack("!Q", ext)[0]
        payload = self.read_exactly(length)
        if len(payload) < length:
            return None, payload
        return opcode, payload


def drain_messages(sock, limit=16):
    """Every frame the server sends until it stops. Returns (frames, closed)."""
    frames = []
    for _ in range(limit):
        opcode, payload = sock.recv_message()
        if opcode is None:
            return frames, True
        if opcode == 0x8:  # close
            return frames, True
        frames.append((opcode, payload))
    return frames, False


def main():
    port = int(sys.argv[1])

    phase("oversized-message-ends-the-connection")
    sock = Sock(port)
    status = sock.handshake("/ws/oversized")
    if status is None or "101" not in status:
        fail("handshake on /ws/oversized: %r" % (status,))
    frames, closed = drain_messages(sock)
    sock.close()

    payloads = [p for _, p in frames]
    under = [p for p in payloads if len(p) == OVERSIZED_UNDER]
    over = [p for p in payloads if len(p) >= OVERSIZED_OVER]
    marker = [p for p in payloads if p == OVERSIZED_MARKER]

    # The under-cap message must arrive whole. Without this the test would
    # pass on a server that ended the connection at the first large frame.
    if not under:
        fail(
            "the under-cap message (%d bytes) never arrived: got %r. The cap "
            "is ending connections it should be serving."
            % (OVERSIZED_UNDER, [len(p) for p in payloads])
        )

    if over:
        fail(
            "a message of %d bytes was delivered, but MAX_PENDING_BYTES caps "
            "ONE frame at 65536 -- either the cap moved or this probe's "
            "constants are stale" % len(over[0])
        )

    # The claim. A silent drop looks exactly like success from here except
    # for this: the conversation continues past the message that vanished.
    if marker:
        fail(
            "the oversized message was dropped SILENTLY: the marker after it "
            "arrived, so the peer sees a complete conversation with a message "
            "missing from the middle. The connection must end instead."
        )
    if not closed:
        fail("the connection neither delivered the message nor ended")
    print("  oversized message: not delivered, no marker, connection ended")
    print("  under-cap message: delivered whole (%d bytes)" % OVERSIZED_UNDER)

    # An ordinary socket on the same server must be unaffected -- the cap is
    # a per-message rule, not a reason to distrust the connection.
    phase("an-ordinary-socket-still-works")
    sock = Sock(port)
    status = sock.handshake("/ws")
    if status is None or "101" not in status:
        fail("handshake on /ws: %r" % (status,))
    payload = b"hello"
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.s.sendall(b"\x81" + bytes([0x80 | len(payload)]) + mask + masked)
    opcode, got = sock.recv_message()
    sock.close()
    if got != b"echo:hello":
        fail("an ordinary echo after the cap case returned %r" % got)
    print("  an ordinary socket on the same server: unaffected")

    print("outbox-cap OK")


if __name__ == "__main__":
    main()
