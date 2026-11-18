#!/usr/bin/env python3
"""A streamed ASGI body keeps the length its head declared (SPEC L41).

The loop framed every stream chunked and dropped a declared
`Content-Length`, so Starlette's FileResponse lost its length for any file
larger than one chunk: no progress, no way to tell a whole download from a
cut one but the chunked terminator. A stream that goes past its declared
length is refused at the send that would pass it, as uvicorn refuses it.

    M0_PORT=... python3 scripts/asgi_sized_stream_probe.py
"""

import http.client
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probelib import fail, phase, stamp  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8000"))
PIECE = 100_000
WHOLE = b"A" * PIECE + b"B" * PIECE + b"C" * PIECE

stamp("asgi sized_stream_probe FAIL")


def main():
    phase("a sized stream keeps its length and is not chunked")
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    conn.request("GET", "/sized-stream")
    r = conn.getresponse()
    if r.getheader("content-length") != str(len(WHOLE)):
        fail("content-length was %r, want %d (transfer-encoding %r)" % (
            r.getheader("content-length"), len(WHOLE), r.getheader("transfer-encoding")))
    if r.getheader("transfer-encoding"):
        fail("a sized stream was sent %r" % r.getheader("transfer-encoding"))
    body = r.read()
    if body != WHOLE:
        fail("the body was %d bytes and %s" % (len(body), "wrong" if len(body) == len(WHOLE) else "short"))

    phase("its connection is kept for the next request")
    try:
        conn.request("GET", "/")
        r = conn.getresponse()
        again = r.read()
    except (OSError, http.client.HTTPException) as exc:
        fail("the connection did not survive a complete sized stream: %r" % (exc,))
    if r.status != 200 or b"hello from asgi_bare" not in again:
        fail("the request after a sized stream answered %d %r" % (r.status, again[:60]))
    conn.close()

    phase("an HTTP/1.0 client gets the length too")
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(b"GET /sized-stream HTTP/1.0\r\nHost: probe\r\n\r\n")
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    if b"content-length: %d" % len(WHOLE) not in head.lower() or body != WHOLE:
        fail("HTTP/1.0: head %r, body %d bytes" % (head[:160], len(body)))

    phase("a sized stream cut short is a truncated response, then a close")
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(b"GET /sized-stream?short HTTP/1.1\r\nHost: probe\r\n\r\n")
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    if b"content-length: %d" % len(WHOLE) not in head.lower():
        fail("the short stream's head was %r" % head[:160])
    if body != WHOLE[:PIECE]:
        fail("the short stream delivered %d bytes, want exactly %d and a close" % (len(body), PIECE))

    phase("a stream that sends past its declared length is refused at its send")
    # Three of them: each held its share of the executor's stream window
    # for good when the loop trimmed the excess, and two were all of it.
    for n in range(3):
        s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        s.sendall(b"GET /sized-overrun HTTP/1.1\r\nHost: probe\r\n\r\n")
        buf = b""
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except OSError as exc:
            fail("overrun %d: no close 5 s after a stream passed its length, "
                 "%d bytes read: %r" % (n + 1, len(buf), exc))
        s.close()
        head, _, body = buf.partition(b"\r\n\r\n")
        if b"content-length: 4" not in head.lower() or body != b"abcd":
            fail("overrun %d: head %r, body %r, want the 4 declared bytes" % (n + 1, head[:120], body[:40]))
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
        conn.request("GET", "/overrun-heard")
        said = conn.getresponse().read()
        conn.close()
        if b"longer than" not in said:
            fail("overrun %d: the application's send did not raise: %r" % (n + 1, said))
    phase("a sized stream is whole after them")
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    conn.request("GET", "/sized-stream")
    try:
        body = conn.getresponse().read()
    except OSError as exc:
        fail("a sized stream after three overruns did not finish: %r" % (exc,))
    conn.close()
    if body != WHOLE:
        fail("a sized stream after three overruns was %d bytes" % len(body))

    phase("the server answers afterwards")
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    conn.request("GET", "/")
    if conn.getresponse().status != 200:
        fail("GET / failed after the sized streams")
    conn.close()
    print("asgi sized_stream_probe OK: %d bytes with their length, kept alive; a short one closed; an overrun refused" % len(WHOLE))


if __name__ == "__main__":
    main()
