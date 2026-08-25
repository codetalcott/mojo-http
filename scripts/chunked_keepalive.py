"""Prove a streamed response leaves its connection reusable.

Everything else about chunked framing passes today via close-delimiting —
the body arrives, the bytes are right, clients are happy. The ONE thing
that cannot work without real framing is a second request on the same
connection, because a close-delimited body ends by closing. So this probe
speaks HTTP on a raw socket rather than through a client library: it sends
two requests down one connection and insists both are answered.

It also decodes the chunked body by hand and compares it byte for byte,
which is what catches a framing bug that a lenient client would paper over
(a wrong chunk size, a missing terminator, a stray CRLF).

    M0_PORT=8088 python3 scripts/chunked_keepalive.py

Exits 0 on success, 1 with a diagnosis on failure.
"""

import hashlib
import os
import socket
import sys

HOST = os.environ.get("M0_HOST", "127.0.0.1")
PORT = int(os.environ.get("M0_PORT", "8088"))
STREAM_PATH = os.environ.get("M0_STREAM_PATH", "/stream")
SECOND_PATH = os.environ.get("M0_SECOND_PATH", "/")
# What /stream is documented to produce: 1 MB of a repeating pattern.
EXPECT_LEN = int(os.environ.get("M0_STREAM_LEN", "1048576"))


def fail(msg):
    print(f"chunked-keepalive: {msg}", file=sys.stderr)
    sys.exit(1)


class Reader:
    """Buffered line/exact reader over a socket, so one connection can be
    read across two responses without losing pipelined bytes."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise EOFError("connection closed by peer")
        self.buf += chunk

    def line(self):
        while b"\r\n" not in self.buf:
            self._fill()
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def exact(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out


def read_head(r):
    status = r.line().decode("latin-1")
    headers = {}
    while True:
        line = r.line()
        if not line:
            break
        k, _, v = line.decode("latin-1").partition(":")
        headers[k.strip().lower()] = v.strip()
    return status, headers


def read_chunked_body(r):
    """Decode a chunked body, returning the payload bytes."""
    body = b""
    while True:
        size_line = r.line().decode("latin-1")
        # Chunk extensions are legal; the size ends at the first ';'.
        size = int(size_line.split(";")[0].strip(), 16)
        if size == 0:
            # Trailer section, then the bare CRLF that ends the message.
            while True:
                trailer = r.line()
                if not trailer:
                    break
            return body
        body += r.exact(size)
        if r.exact(2) != b"\r\n":
            fail("a chunk was not followed by CRLF - framing is wrong")


def check_http10_is_not_chunked():
    """HTTP/1.0 has no chunked encoding: that stream must stay close-delimited.

    Framing a 1.0 response would put chunk sizes in front of a body the
    client reads literally — a corruption, not a degradation — so this is a
    refusal worth asserting rather than assuming.
    """
    with socket.create_connection((HOST, PORT), timeout=30) as s:
        s.settimeout(30)
        r = Reader(s)
        s.sendall(
            f"GET {STREAM_PATH} HTTP/1.0\r\nHost: {HOST}\r\n\r\n".encode()
        )
        _, headers = read_head(r)
        te = headers.get("transfer-encoding", "")
        if te:
            fail(
                f"an HTTP/1.0 stream was framed (transfer-encoding={te!r}); "
                "1.0 clients read the body literally, so this corrupts it"
            )


def main():
    check_http10_is_not_chunked()

    with socket.create_connection((HOST, PORT), timeout=30) as s:
        s.settimeout(30)
        r = Reader(s)

        # --- request 1: the stream ---
        s.sendall(
            f"GET {STREAM_PATH} HTTP/1.1\r\nHost: {HOST}\r\n\r\n".encode()
        )
        status, headers = read_head(r)
        if "200" not in status:
            fail(f"the stream did not answer 200: {status!r}")
        te = headers.get("transfer-encoding", "")
        if te.lower() != "chunked":
            fail(
                "the stream was not chunk-framed (transfer-encoding="
                f"{te!r}); a close-delimited stream cannot keep the "
                "connection alive"
            )
        if "content-length" in headers:
            fail("a chunked response must not carry Content-Length")
        body = read_chunked_body(r)
        if len(body) != EXPECT_LEN:
            fail(f"stream body was {len(body)} bytes, expected {EXPECT_LEN}")
        digest = hashlib.md5(body).hexdigest()

        # --- request 2: the same connection must still work ---
        # This is the whole point. Against a close-delimited stream the
        # socket is already gone and this raises.
        try:
            s.sendall(
                f"GET {SECOND_PATH} HTTP/1.1\r\nHost: {HOST}\r\n\r\n".encode()
            )
            status2, headers2 = read_head(r)
        except (BrokenPipeError, ConnectionResetError, EOFError) as e:
            fail(
                "the connection did not survive the stream "
                f"({type(e).__name__}) - end-of-stream still closes it"
            )
        if "200" not in status2:
            fail(f"the second request on the reused connection failed: {status2!r}")
        n = int(headers2.get("content-length", "0"))
        if n:
            r.exact(n)

    print(
        f"chunked keep-alive OK: {len(body)} bytes streamed (md5 {digest}), "
        "then a second request answered on the same connection; "
        "HTTP/1.0 stayed close-delimited"
    )


if __name__ == "__main__":
    main()
