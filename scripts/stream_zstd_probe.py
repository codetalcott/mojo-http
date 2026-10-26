"""The compressed Datastar stream, read the way a browser reads it
(`poe smoke-stream-zstd`, SPEC I45; docs/notes/compressing-a-stream.md).

Against the counter demo, which opens its stream with `compress=True`:

1. A client that offers zstd gets `Content-Encoding: zstd`, with
   `Accept-Encoding` in `Vary`, and one frame it decodes as it arrives:
   each POST /increment's event is decoded before the next POST goes, a
   heartbeat decodes inside the frame, and an event after it still does.
   That is the flush per write, proved by order rather than by a clock: a
   millisecond bar on a shared runner would only measure the runner.
2. A client that does not ask (no `Accept-Encoding`), and one that refuses
   (`zstd;q=0`), get the stream as written.
3. A buffered page from the same app carries no `Content-Encoding` (J8).

Raw sockets, so what is decoded is what was on the wire; Python 3.14's
`compression.zstd`, the interpreter CI pins.
"""

import argparse
import socket
import sys
import time

from probelib import fail, phase, stamp

try:
    from compression import zstd
except ImportError:
    sys.exit("stream_zstd_probe: needs Python 3.14's compression.zstd (CI pins 3.14)")

BOUND_S = 10

stamp("stream_zstd_probe FAIL")


def request(port, method, path, accept_encoding=None, extra=""):
    s = socket.create_connection(("127.0.0.1", port), timeout=BOUND_S)
    head = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n{extra}"
    if accept_encoding is not None:
        head += f"Accept-Encoding: {accept_encoding}\r\n"
    s.sendall((head + "\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            fail(f"{method} {path} closed before its head")
        buf += chunk
    raw_head, rest = buf.split(b"\r\n\r\n", 1)
    lines = raw_head.decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return s, lines[0], headers, rest


def post_increment(port):
    s, status, _, _ = request(port, "POST", "/increment", extra="Content-Length: 0\r\nConnection: close\r\n")
    s.close()
    if " 200" not in status and " 204" not in status:
        fail("POST /increment answered " + status)


class Stream:
    """What the client has decoded so far, read on demand."""

    def __init__(self, sock, first, coded):
        self.sock = sock
        self.decoder = zstd.ZstdDecompressor() if coded else None
        self.text = ""
        self.wire = 0
        self.feed(first)

    def feed(self, data):
        self.wire += len(data)
        if self.decoder is not None:
            try:
                data = self.decoder.decompress(data)
            except zstd.ZstdError as e:
                fail(f"the stream did not decode as zstd: {e}")
        self.text += data.decode("utf-8", "replace")

    def until(self, done, what):
        deadline = time.monotonic() + BOUND_S
        while not done(self.text):
            left = deadline - time.monotonic()
            if left <= 0:
                fail(f"{what}: not decoded within {BOUND_S} s; decoded so far ends {self.text[-200:]!r}")
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(65536)
            except TimeoutError:
                continue
            if not chunk:
                fail(f"{what}: the stream closed first")
            self.feed(chunk)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    port = ap.parse_args().port

    # 1. Offered zstd: one frame, decoded as it arrives.
    phase("the coded stream's head")
    s, status, h, rest = request(port, "GET", "/events", "gzip, deflate, br, zstd", "Accept: text/event-stream\r\n")
    if " 200" not in status:
        fail("GET /events answered " + status)
    if h.get("content-encoding") != "zstd":
        fail(f"a client offering zstd got Content-Encoding {h.get('content-encoding')!r}")
    if "accept-encoding" not in h.get("vary", "").lower():
        fail(f"a coded stream must vary on Accept-Encoding; Vary was {h.get('vary')!r}")
    if rest.startswith(b": open"):
        fail("the body after the head went out raw")
    st = Stream(s, rest, coded=True)
    st.until(lambda t: ": open" in t, "the stream's opening comment")
    for i in range(5):
        phase(f"increment {i + 1} on the coded stream")
        seen = st.text.count("event: ")
        post_increment(port)
        st.until(lambda t, seen=seen: t.count("event: ") > seen, f"the event for increment {i + 1}")
    phase("a heartbeat inside the frame")
    beats = st.text.count(": heartbeat")
    st.until(lambda t: t.count(": heartbeat") > beats, "a heartbeat inside the frame")
    phase("an event after the heartbeat")
    seen = st.text.count("event: ")
    post_increment(port)
    st.until(lambda t: t.count("event: ") > seen, "an event after the heartbeat")
    decoded = len(st.text.encode())
    s.close()

    # 2. Not asked, or refused: the stream as written.
    for offer in (None, "zstd;q=0, gzip"):
        phase(f"the plain stream for Accept-Encoding {offer!r}")
        s, status, h, rest = request(port, "GET", "/events", offer, "Accept: text/event-stream\r\n")
        if "content-encoding" in h:
            fail(f"Accept-Encoding {offer!r} got Content-Encoding {h['content-encoding']!r}")
        plain = Stream(s, rest, coded=False)
        plain.until(lambda t: ": open" in t, f"the plain stream for Accept-Encoding {offer!r}")
        s.close()

    # 3. J8: a buffered page is a proxy's to compress.
    phase("the buffered page")
    s, status, h, _ = request(port, "GET", "/", "zstd", "Connection: close\r\n")
    s.close()
    if "content-encoding" in h:
        fail(f"the buffered page went out with Content-Encoding {h['content-encoding']!r} (J8)")

    print(f"stream_zstd_probe OK: {decoded} bytes decoded from {st.wire} on the wire")


if __name__ == "__main__":
    main()
