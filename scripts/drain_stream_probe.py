#!/usr/bin/env python3
"""A chunked stream open at SIGTERM ends cleanly: a terminator or EOF,
never a chunk the client cannot parse.

The graceful drain says goodbye to every stream before it closes it: an SSE
close comment, or a WebSocket Close. It did so without the heartbeat's
guards (review record LF12). A stream an application writes through the
chunk channel goes out chunked, and the comment went into it raw, so the
client's chunked parser read `: close` where a chunk size belongs; a stream
with a frame half sent had the farewell land inside the frame; a WebSocket
that had sent its Close got a second one. One predicate now says whether a
slot may take a frame its application did not write, for the heartbeat and
the farewell alike, and a chunked stream gets none: it ends with EOF.

This drives the first of those on the wire: `/stream-forever` on the bare
ASGI app, an event every 50 ms, read through a strict chunked parser, then
SIGTERM to the server, then the parser to EOF.

usage: drain_stream_probe.py PORT PID
"""
import os
import signal
import socket
import sys
import time

from probelib import fail, phase, stamp

PORT = int(sys.argv[1])
PID = int(sys.argv[2])
# Long enough for the drain's 5 s budget and the exit behind it.
DEADLINE = 15.0

stamp("drain_stream_probe: FAIL")


class Reader:
    """Bytes off the socket, with EOF reported rather than raised."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.eof = False

    def fill(self):
        if self.eof:
            return False
        left = self.deadline - time.monotonic()
        if left <= 0:
            fail("the stream was still open %ds after SIGTERM" % DEADLINE)
        self.sock.settimeout(left)
        try:
            got = self.sock.recv(65536)
        except socket.timeout:
            fail("the stream was still open %ds after SIGTERM" % DEADLINE)
        except ConnectionResetError:
            got = b""
        if not got:
            self.eof = True
            return False
        self.buf += got
        return True

    def line(self):
        """One CRLF-terminated line, or None at EOF."""
        while b"\r\n" not in self.buf:
            if not self.fill():
                return None
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def take(self, n):
        """`n` bytes, or None at EOF."""
        while len(self.buf) < n:
            if not self.fill():
                return None
        out, self.buf = self.buf[:n], self.buf[n:]
        return out


HEX = set(b"0123456789abcdefABCDEF")


def next_chunk(r):
    """The next chunk's payload; b"" for the terminator; None at EOF.

    EOF part way through a size line is a truncation, and acceptable, only
    while what arrived could still begin a chunk size: the farewell comment
    has no CRLF, so it reached the client as exactly such a tail."""
    size_line = r.line()
    if size_line is None:
        if r.buf and not set(r.buf) <= HEX:
            fail("a chunk size the client cannot parse, then EOF: %r" % r.buf[:80])
        return None
    size_text = size_line.split(b";", 1)[0].strip()
    try:
        size = int(size_text, 16)
    except ValueError:
        fail("a chunk size the client cannot parse: %r" % size_line[:80])
    if size == 0:
        trailer = r.line()
        if trailer not in (None, b""):
            fail("the terminator is followed by %r" % trailer[:80])
        return b""
    data = r.take(size)
    if data is None:
        return None
    end = r.take(2)
    if end is not None and end != b"\r\n":
        fail("a chunk of %d bytes is followed by %r, not CRLF" % (size, end))
    return data


phase("a chunked stream opens")
s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
s.sendall(b"GET /stream-forever HTTP/1.1\r\nHost: x\r\n\r\n")
r = Reader(s)
r.deadline = time.monotonic() + 10
head = []
while True:
    line = r.line()
    if line is None:
        fail("the server closed before the stream's head ended")
    if line == b"":
        break
    head.append(line.lower())
if not head or not head[0].startswith(b"http/1.1 200"):
    fail("the stream was not answered 200: %r" % head[:1])
if b"transfer-encoding: chunked" not in head:
    fail("the stream is not chunked, so this proves nothing: %r" % head)
for _ in range(3):
    if not next_chunk(r):
        fail("the stream ended before SIGTERM")

phase("SIGTERM with the stream open")
os.kill(PID, signal.SIGTERM)

phase("the rest of the stream, to its end")
r.deadline = time.monotonic() + DEADLINE
chunks = 0
while True:
    data = next_chunk(r)
    if data is None or data == b"":
        break
    chunks += 1
s.close()
print("drain_stream_probe: the stream ended cleanly at SIGTERM (%d chunks after it)"
      % chunks)
