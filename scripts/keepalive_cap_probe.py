#!/usr/bin/env python3
"""The keep-alive request cap must not destroy the response it fires on.

`ServerConfig.max_keepalive_requests` (100) closes a connection once it has
been reused that many times. A STREAM and a WebSocket UPGRADE are not reuse:
each owns the connection until it ends, and `_finish_response` says so by
clearing `should_close` for both. The cap check sitting after those two
branches was guarded by `not should_close` -- which is exactly the state they
had just established -- so the two shapes that had opted out were the two it
caught. `_after_send` then closed the slot as soon as the HEAD drained, before
any body frame arrived over the executor's chunk channel.

Measured on the broken build, both on the 100th request of a connection:

  * `/stream?size=262144` answered `200` with `Content-Length` set and
    **zero** body bytes;
  * `/ws` answered `101 Switching Protocols` and then sent **no frame**.

Both are silent: the status line is correct, the server logs nothing, and the
client sees a clean empty response or a WebSocket that never speaks.

Run against `apps/asgi_bare` under `m0serve` (the asyncio executor is where
the chunk channel lives). Phase 3 is the boundary self-test: without it a
build whose cap never fires would pass phases 1 and 2 having tested nothing.

Usage: keepalive_cap_probe.py PORT
"""
import base64
import os
import socket
import struct
import sys
import traceback

# The phase stamp. Every phase here shares `Conn`'s socket helpers, so a
# raise inside `read_head` or `read_exactly` names the CALL and never the
# claim being proven -- and the two claims fail in visibly similar ways
# (an empty body, an absent frame), which is exactly when being told the
# phase matters. See scripts/phase_stamp_check.py.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("keepalive_cap_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped

CAP = 100  # ServerConfig.max_keepalive_requests
STREAM_BYTES = 256 * 1024
HOST = "127.0.0.1"


def fail(msg):
    print("keepalive-cap: " + msg)
    sys.exit(1)


class Conn:
    """A keep-alive connection with a buffered reader over one socket.

    Reads go through ONE buffer: a naive probe that mixes `makefile()` for
    the head with `recv()` for the body loses whatever the reader already
    buffered, which silently reads as "the server sent nothing".
    """

    def __init__(self, port, timeout=20):
        self.sock = socket.create_connection((HOST, port), timeout=timeout)
        self.buf = b""

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            return False
        self.buf += chunk
        return True

    def read_exactly(self, n):
        while len(self.buf) < n:
            if not self._fill():
                break
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read_head(self):
        """Return (status_line, {header: value}) or (None, {}) at EOF."""
        while b"\r\n\r\n" not in self.buf:
            if not self._fill():
                return None, {}
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        self.buf = rest
        lines = head.split(b"\r\n")
        headers = {}
        for line in lines[1:]:
            k, _, v = line.decode("latin-1").partition(":")
            headers[k.strip().lower()] = v.strip()
        return lines[0].decode("latin-1"), headers

    def request(self, path, extra=""):
        self.sock.sendall(
            ("GET %s HTTP/1.1\r\nHost: localhost\r\n%s\r\n" % (path, extra)).encode()
        )

    def body(self, headers):
        """Read the body a head announced. Chunked or Content-Length."""
        if headers.get("transfer-encoding", "").lower() == "chunked":
            out = b""
            while True:
                while b"\r\n" not in self.buf:
                    if not self._fill():
                        return out
                line, _, rest = self.buf.partition(b"\r\n")
                self.buf = rest
                size = int(line.split(b";")[0], 16)
                if size == 0:
                    self.read_exactly(2)
                    return out
                out += self.read_exactly(size)
                self.read_exactly(2)
            return out
        n = int(headers.get("content-length", 0))
        return self.read_exactly(n)


def reuse(conn, n):
    """Spend `n` keep-alive requests so the next one lands on the cap."""
    for i in range(n):
        conn.request("/")
        status, headers = conn.read_head()
        if status is None or "200" not in status:
            fail("warm-up request %d of %d: %r" % (i + 1, n, status))
        conn.body(headers)
        if headers.get("connection", "").lower() == "close":
            fail(
                "warm-up request %d asked to close before the cap at %d -- "
                "the probe never reached the boundary it exists to test"
                % (i + 1, CAP)
            )


def ws_handshake(conn, path="/ws"):
    key = base64.b64encode(os.urandom(16)).decode()
    conn.request(
        path,
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n" % key,
    )
    return conn.read_head()


def ws_send_text(conn, text):
    payload = text.encode()
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    header = b"\x81" + bytes([0x80 | len(payload)])
    conn.sock.sendall(header + mask + masked)


def ws_read_frame(conn):
    """Return (opcode, payload) for one unmasked server frame."""
    head = conn.read_exactly(2)
    if len(head) < 2:
        return None, b""
    opcode = head[0] & 0x0F
    length = head[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", conn.read_exactly(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", conn.read_exactly(8))[0]
    return opcode, conn.read_exactly(length)


def phase1_stream(port):
    """A streamed body on the cap request must arrive whole."""
    path = "/stream?size=%d&piece=4096" % STREAM_BYTES

    # Control first: the same request on a FRESH connection. If this fails
    # the build is broken in a way that has nothing to do with the cap, and
    # saying so is more useful than reporting the cap.
    phase("stream-control")
    c = Conn(port)
    c.request(path)
    status, headers = c.read_head()
    control = c.body(headers)
    c.close()
    if len(control) != STREAM_BYTES:
        fail(
            "control (request 1 of a connection): %d of %d bytes -- streaming "
            "is broken independently of the cap" % (len(control), STREAM_BYTES)
        )

    phase("stream-on-the-cap-request")
    c = Conn(port)
    reuse(c, CAP - 1)
    c.request(path)
    status, headers = c.read_head()
    if status is None:
        fail("stream on the cap request (%d): no response at all" % CAP)
    if "200" not in status:
        fail("stream on the cap request (%d): %r" % (CAP, status))
    body = c.body(headers)
    c.close()
    if len(body) != STREAM_BYTES:
        fail(
            "stream on the cap request (%d): %d of %d bytes. The head "
            "announced the body and the connection closed before the chunk "
            "channel delivered it." % (CAP, len(body), STREAM_BYTES)
        )
    if body != control:
        fail("stream on the cap request (%d): body differs from the control" % CAP)
    print("  stream on request %d: %d bytes, byte-identical to the control"
          % (CAP, len(body)))


def phase2_upgrade(port):
    """A WebSocket upgrade on the cap request must yield a live socket."""
    phase("upgrade-control")
    c = Conn(port)
    status, headers = ws_handshake(c)
    if status is None or "101" not in status:
        fail("control upgrade (request 1): %r -- upgrades are broken "
             "independently of the cap" % (status,))
    ws_send_text(c, "control")
    opcode, payload = ws_read_frame(c)
    c.close()
    if payload != b"echo:control":
        fail("control upgrade (request 1): echoed %r" % payload)

    phase("upgrade-on-the-cap-request")
    c = Conn(port)
    reuse(c, CAP - 1)
    status, headers = ws_handshake(c)
    if status is None:
        fail("upgrade on the cap request (%d): no response at all" % CAP)
    if "101" not in status:
        fail("upgrade on the cap request (%d): %r" % (CAP, status))
    ws_send_text(c, "hi")
    opcode, payload = ws_read_frame(c)
    c.close()
    if payload != b"echo:hi":
        fail(
            "upgrade on the cap request (%d): handshake said 101 but the "
            "socket delivered %r -- the slot closed once the handshake "
            "drained." % (CAP, payload)
        )
    print("  upgrade on request %d: 101 and a live echo" % CAP)


def phase3_boundary(port):
    """The cap must still fire for an ORDINARY response.

    Phases 1 and 2 assert that two shapes survive request %d. Both would
    also pass on a build whose cap never fires at all -- one raised limit and
    the gate silently tests nothing. This is the other half: a plain response
    on the cap request must still close the connection.
    """ % CAP
    phase("cap-boundary")
    c = Conn(port)
    reuse(c, CAP - 1)
    c.request("/")
    status, headers = c.read_head()
    body = c.body(headers)
    c.close()
    if "200" not in (status or ""):
        fail("boundary check: request %d answered %r" % (CAP, status))
    if body != b"hello from asgi_bare":
        fail("boundary check: request %d returned %r" % (CAP, body))
    if headers.get("connection", "").lower() != "close":
        fail(
            "boundary check: request %d did not carry `Connection: close`. "
            "The cap is not firing at %d, so phases 1 and 2 proved nothing."
            % (CAP, CAP)
        )
    print("  ordinary response on request %d: complete body, Connection: close"
          % CAP)


def main():
    port = int(sys.argv[1])
    phase1_stream(port)
    phase2_upgrade(port)
    phase3_boundary(port)
    print("keepalive-cap OK")


if __name__ == "__main__":
    main()
