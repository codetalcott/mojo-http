"""The comment that follows an event on an SSE stream (`poe smoke-sse-flush`,
SPEC I47; docs/notes/a-comment-after-an-event.md).

Against the counter demo, with its tick off and its heartbeat a minute
away, so the server writes to the stream only what this probe asks for.

`--interval MS`, the server's `M0_SSE_FLUSH_MS`: the stream's opening (its
head carries `: open`) and each POST /increment's event are followed by one
`: flush`, no sooner than half the interval after the request that caused
it went, and then by nothing for twice the interval and a second: one
comment per event, not a cadence.

`--interval 0`: the opening and the events, and nothing after either.

Timed from the moment the request is sent, which is before the event can
exist: a slow runner delivers a byte late, never early, so the lower bound
is the server's property and the upper one is generous. A flush written
with its event would arrive a millisecond after the request.
"""

import argparse
import socket
import time

from probelib import fail, phase, stamp

BOUND_S = 10
FLUSH = ": flush\n\n"
EVENT = "event: datastar-patch-signals"

stamp("sse_flush_probe FAIL")


class Stream:
    """An open SSE stream, its text so far and when its last read landed."""

    def __init__(self, port):
        s = socket.create_connection(("127.0.0.1", port), timeout=BOUND_S)
        s.sendall(b"GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n")
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                fail("GET /events closed before its head")
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0].decode("latin-1")
        if " 200" not in status:
            fail("GET /events answered " + status)
        if b"content-encoding" in head.lower():
            fail("a stream that asked for no coding came coded")
        self.sock = s
        self.text = rest.decode()
        self.landed = time.monotonic()

    def _read(self, deadline):
        """One read before `deadline`; False when none came."""
        left = deadline - time.monotonic()
        if left <= 0:
            return False
        self.sock.settimeout(left)
        try:
            chunk = self.sock.recv(65536)
        except TimeoutError:
            return False
        if not chunk:
            fail("the stream closed")
        self.text += chunk.decode()
        self.landed = time.monotonic()
        return True

    def until(self, done, what):
        """Read until `done(text)`; `landed` is then when it became true."""
        deadline = time.monotonic() + BOUND_S
        while not done(self.text):
            if not self._read(deadline) and time.monotonic() >= deadline:
                fail(f"{what}: not within {BOUND_S} s; the stream so far ends {self.text[-200:]!r}")

    def quiet_for(self, seconds, what):
        """Nothing at all may arrive for `seconds`."""
        before = len(self.text)
        deadline = time.monotonic() + seconds
        while self._read(deadline):
            pass
        if len(self.text) > before:
            fail(f"{what}: {self.text[before:]!r} arrived after it")


def post_increment(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=BOUND_S)
    s.sendall(b"POST /increment HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    status = s.recv(65536).split(b"\r\n", 1)[0].decode("latin-1")
    s.close()
    if " 200" not in status and " 204" not in status:
        fail("POST /increment answered " + status)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--interval", type=int, required=True, help="the server's M0_SSE_FLUSH_MS")
    ap.add_argument("--events", type=int, default=3)
    args = ap.parse_args()
    interval = args.interval / 1000
    quiet = 2 * interval + 1.0
    delays = []

    def followed(sent, flushes, what):
        """The one flush after what was sent at `sent`, and nothing after it."""
        if interval == 0:
            st.quiet_for(quiet, what)
            return
        st.until(lambda t: t.count(FLUSH) > flushes, f"the flush after {what}")
        delay = st.landed - sent
        if delay < interval / 2:
            fail(f"the flush after {what} came {delay * 1000:.0f} ms after it, sooner than half of {args.interval} ms")
        delays.append(delay)
        st.quiet_for(quiet, f"the flush after {what}")
        if st.text.count(FLUSH) != flushes + 1:
            fail(f"{what} was followed by {st.text.count(FLUSH) - flushes} flushes")

    phase("the stream's opening")
    sent = time.monotonic()
    st = Stream(args.port)
    st.until(lambda t: ": open" in t, "the stream's opening comment")
    followed(sent, 0, "the opening")

    for i in range(args.events):
        phase(f"increment {i + 1}")
        before = len(st.text)
        flushes = st.text.count(FLUSH)
        sent = time.monotonic()
        post_increment(args.port)
        st.until(lambda t, before=before: EVENT in t[before:], f"increment {i + 1}'s event")
        followed(sent, flushes, f"increment {i + 1}'s event")

    st.sock.close()
    if interval == 0:
        print(f"sse_flush_probe OK: no flush after the opening or {args.events} events")
    else:
        shown = ", ".join(f"{d * 1000:.0f}" for d in delays)
        print(f"sse_flush_probe OK: one flush after the opening and each of {args.events} events, {shown} ms after the request")


if __name__ == "__main__":
    main()
