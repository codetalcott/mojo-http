"""A bare PEP 3333 application. No framework, no third-party imports.

This is the conformance target for `poe smoke-wsgi`. A framework in the middle
is a second suspect: when a Django route misbehaves it takes a bisect to say
whether the server or the framework did it. Here there is nothing between the
assertion and `m0-wsgi`, so a failure is the server's by construction.

It also reaches PEP 3333 surface that no Django-based test can. Django never
calls the `write()` callable, never invokes `start_response` twice, and never
returns a multi-chunk iterable, so a suite built on Django cannot cover any of
them at any level of effort. Each route below exists because it pins one
paragraph of the spec.

Every response sets Content-Type except `/no-content-type`, which is
deliberately non-conforming and is what proves `M0_WSGI_VALIDATE` is engaged.
"""

import os
import sys
import time
from http.client import HTTPConnection
from urllib.parse import parse_qs, urlsplit

TEXT = [("Content-Type", "text/plain; charset=utf-8")]

# Bumped by CloseCounting.close(). PEP 3333 requires the server to call
# close() on the returned iterable if it has one; Django's request_finished
# cleanup hangs off exactly this, so a server that skips it breaks framework
# teardown without breaking any single response.
_closed = 0


class CloseCounting:
    """An iterable that records having been closed."""

    def __init__(self, chunks):
        self._chunks = list(chunks)

    def __iter__(self):
        return iter(self._chunks)

    def close(self):
        global _closed
        _closed += 1


def _q(environ, name, default=""):
    return parse_qs(environ.get("QUERY_STRING", "")).get(name, [default])[0]


# --- routes -----------------------------------------------------------------


def root(environ, start_response):
    start_response("200 OK", list(TEXT))
    return [b"bare wsgi app"]


def method(environ, start_response):
    """REQUEST_METHOD, for the keep-alive isolation check."""
    start_response("200 OK", list(TEXT))
    return [environ["REQUEST_METHOD"].encode()]


def environ_dump(environ, start_response):
    """Every environ key, `KEY=repr(value)` per line.

    Pins three separate things: QUERY_STRING must still be percent-encoded
    (PEP 3333 wants the raw bytes, and Django re-decodes it itself), the CGI
    transform must put Content-Type and Content-Length in bare form while
    every other header keeps the HTTP_ prefix, and PATH_INFO must be decoded
    and start with '/'.
    """
    start_response("200 OK", list(TEXT))
    lines = ["%s=%r" % (k, v) for k, v in sorted(environ.items())]
    return ["\n".join(lines).encode("utf-8")]


def write_only(environ, start_response):
    """The legacy `write()` callable, used exclusively.

    PEP 3333: "the write callable is provided to support existing frameworks"
    and anything passed to it must reach the client. A server that returns a
    no-op here answers 200 with an empty body and nothing anywhere reports an
    error -- which is precisely why it needs a test rather than a review.
    """
    write = start_response("200 OK", list(TEXT))
    write(b"written-body")
    return []


def write_mixed(environ, start_response):
    """write() output must precede the iterable's, in order."""
    write = start_response("200 OK", list(TEXT))
    write(b"first")
    write(b"second")
    return [b"third"]


def chunks(environ, start_response):
    """A multi-chunk iterable. The server joins; nothing may be dropped."""
    start_response("200 OK", list(TEXT))
    return [b"one-", b"two-", b"three"]


def closing(environ, start_response):
    """Returns an iterable with a close(); /close/count reports the tally."""
    start_response("200 OK", list(TEXT))
    return CloseCounting([b"closing"])


def close_count(environ, start_response):
    start_response("200 OK", list(TEXT))
    return [str(_closed).encode()]


def no_content_type(environ, start_response):
    """Deliberately non-conforming: a body with no Content-Type.

    An ordinary 200 unvalidated, an AssertionError under wsgiref.validate.
    That difference is the only way the smoke test can tell the validator is
    installed rather than skipped by a misspelled variable name.
    """
    start_response("200 OK", [])
    return [b"canary"]


def start_twice(environ, start_response):
    """Two start_response calls, no exc_info. PEP 3333 forbids it."""
    start_response("200 OK", list(TEXT))
    start_response("201 Created", list(TEXT))
    return [b"should not be delivered"]


def exc_info_replace(environ, start_response):
    """A second start_response WITH exc_info, before anything is sent.

    PEP 3333 says the server must then replace the stored status and headers,
    and may only re-raise if the headers have already gone out. This server
    buffers the whole response, so nothing has gone out and replacing is the
    correct branch: the client must see 503, not 200.
    """
    start_response("200 OK", list(TEXT))
    try:
        raise RuntimeError("intentional")
    except RuntimeError:
        start_response("503 Service Unavailable", list(TEXT), sys.exc_info())
    return [b"replaced"]


def status(environ, start_response):
    """Arbitrary status passthrough: /status?code=418."""
    code = _q(environ, "code", "200")
    start_response("%s Custom Reason" % code, list(TEXT))
    return [b"status " + code.encode()]


def input_read(environ, start_response):
    """read() the whole body. Reports length so a truncation is visible."""
    n = int(environ.get("CONTENT_LENGTH") or 0)
    body = environ["wsgi.input"].read(n)
    start_response("200 OK", list(TEXT))
    return [b"len=%d sum=%d" % (len(body), sum(body))]


def input_readline(environ, start_response):
    """readline() until exhausted."""
    stream = environ["wsgi.input"]
    lines = []
    while True:
        line = stream.readline()
        if not line:
            break
        lines.append(line.rstrip(b"\r\n"))
    start_response("200 OK", list(TEXT))
    return [b"|".join(lines)]


def input_iter(environ, start_response):
    """Iterating wsgi.input, which PEP 3333 requires to be supported."""
    total = b"".join(list(environ["wsgi.input"]))
    start_response("200 OK", list(TEXT))
    return [b"iter=%d" % len(total)]


def input_overread(environ, start_response):
    """Reading past EOF must yield b'', not block and not raise."""
    stream = environ["wsgi.input"]
    stream.read(int(environ.get("CONTENT_LENGTH") or 0))
    extra = stream.read(64)
    start_response("200 OK", list(TEXT))
    return [b"extra=%r" % (extra,)]


def subview(environ, start_response):
    start_response("200 OK", list(TEXT))
    return [b"subview"]


def pid(environ, start_response):
    """This process's pid, so a smoke can tell workers apart."""
    body = str(os.getpid()).encode()
    start_response("200 OK", [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))])
    return [body]


def proxies(environ, start_response):
    """`urllib.request.getproxies()`: the platform-runtime call a forked worker cannot make.

    On macOS this consults the system proxy configuration through
    `_scproxy`, which calls into CoreFoundation, and Objective-C aborts a
    process that forked without exec'ing (`M0_WORKERS>1`): the worker is
    killed and the supervisor respawns it, so the client sees a dropped
    connection. Under `--spawn-workers` the same view answers, because the
    worker is a fresh image. On Linux it reads environment variables and
    answers everywhere. `smoke-spawn-workers` is the gate, both arms.
    """
    import urllib.request

    body = repr(sorted(urllib.request.getproxies())).encode()
    start_response("200 OK", [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))])
    return [body]


def reentrant(environ, start_response):
    """A request made from inside a request, back to this same server.

    One worker runs views synchronously on the event loop, so this deadlocks
    unless M0_WORKERS>=2 lets a second process accept the sub-request. Django's
    equivalent test calls urlopen with no timeout and hangs forever when that
    is misconfigured; the timeout here turns the same mistake into a failure
    with a message, which is the difference between a red test and a CI job
    that runs until the runner kills it.

    **`HTTPConnection`, never `urlopen`, and that is not a style choice.** On
    macOS `urlopen` consults the system proxy configuration through `_scproxy`,
    which calls into CoreFoundation; Objective-C refuses to run in a process
    forked without exec and aborts it outright, so under `M0_WORKERS>=2` the
    worker dies with SIGKILL and the supervisor respawns it. Measured, on this
    route, with this server. `HTTPConnection` performs no proxy lookup and
    touches no system framework. The same trap is waiting for any application
    that calls `urlopen` from a view -- see docs/WSGI_CONFORMANCE.md.
    """
    parts = urlsplit(_q(environ, "url"))
    try:
        conn = HTTPConnection(parts.hostname, parts.port or 80, timeout=10)
        try:
            conn.request("GET", "/subview")
            inner = conn.getresponse().read()
        finally:
            conn.close()
    except Exception as exc:  # surfaced as a body, not a hang
        start_response("504 Gateway Timeout", list(TEXT))
        return [b"reentrant failed: " + repr(exc).encode()]
    start_response("200 OK", list(TEXT))
    return [b"reentrant: " + inner]


def slow(environ, start_response):
    time.sleep(1.5)
    start_response("200 OK", list(TEXT))
    return [b"slow done"]


def busy(environ, start_response):
    """Spin for `ms` milliseconds of CPU with the GIL held.

    The shape that convoys a pool of threads on a GIL build -- a view that
    never releases the GIL until it returns -- which `probe-pool-fairness`
    drives at sixteen connections against four pool threads. `/slow` cannot
    stand in for it: `time.sleep` releases the GIL, and a sleeping thread
    contends with nobody.
    """
    qs = parse_qs(environ.get("QUERY_STRING", ""))
    ms = float(qs.get("ms", ["0.3"])[0])
    end = time.perf_counter() + ms / 1000.0
    n = 0
    while time.perf_counter() < end:
        n += 1
    start_response("200 OK", list(TEXT))
    return [b"busy %d" % n]


def stuck(environ, start_response):
    """A view that never comes back, to prove shutdown does not wait for it.

    120 s is "never" at the scale of a drain deadline. `smoke-blocking-threads`
    holds two of these on pool threads, sends SIGTERM, and asserts the process
    exits within its budget saying what it left behind. The real-world shape
    is an SSE generator served under WSGI, which is buffered and so never ends.
    """
    time.sleep(120)
    start_response("200 OK", list(TEXT))
    return [b"stuck done"]


# --- streamed bodies ---------------------------------------------------------
# A generator with no Content-Length is streamed by a pool thread, chunk by
# chunk, as the application produces it; a list (`/chunks` above) is joined
# and sized. Each route below pins one edge of that contract.


def _stream_pieces(environ):
    n = int(_q(environ, "n", "3"))
    size = int(_q(environ, "size", "0"))
    delay = float(_q(environ, "delay", "0.1"))
    return n, size, delay


def stream(environ, start_response):
    """`n` pieces, `delay` seconds apart. `?size=` bytes each (default: a
    short labelled line), so 16 concurrent 1 MB bodies can be asserted
    byte-exact and a three-line body can be watched arriving over time."""
    n, size, delay = _stream_pieces(environ)
    start_response("200 OK", list(TEXT))

    def gen():
        for i in range(n):
            if size:
                yield (b"%d" % (i % 10)) * size
            else:
                yield b"piece %d\n" % i
            if delay and i + 1 < n:
                time.sleep(delay)

    return gen()


def stream_forever(environ, start_response):
    """An SSE-shaped generator that never ends: one event per `delay`
    seconds. The thread producing it returns to the pool only when the
    client goes away — which is what the smoke asserts."""
    delay = float(_q(environ, "delay", "0.05"))
    start_response("200 OK", [("Content-Type", "text/event-stream")])

    def gen():
        i = 0
        while True:
            yield b"data: tick %d\n\n" % i
            i += 1
            time.sleep(delay)

    return gen()


def stream_raises(environ, start_response):
    """Two pieces, then an exception: the head is on the wire, so the only
    honest answer is a truncated body — the connection closes WITHOUT the
    chunked terminator."""
    start_response("200 OK", list(TEXT))

    def gen():
        yield b"first\n"
        yield b"second\n"
        raise RuntimeError("the generator raised after two pieces")

    return gen()


def stream_empty(environ, start_response):
    """A generator that yields nothing but empty chunks: no non-empty chunk
    ever exists, so PEP 3333's headers-after-first-chunk rule sends this
    down the buffered path as an empty 200 with a Content-Length."""
    start_response("200 OK", list(TEXT))

    def gen():
        yield b""
        yield b""

    return gen()


def stream_write_inside(environ, start_response):
    """write() called from INSIDE the generator, between its yields. PEP 3333
    allows it, and the bytes must reach the wire in production order."""
    write = start_response("200 OK", list(TEXT))
    write(b"w0-")

    def gen():
        yield b"y0-"
        write(b"w1-")
        yield b"y1-"
        write(b"w2-")

    return gen()


def stream_cl(environ, start_response):
    """A generator WITH an application Content-Length: buffered, as the
    length the application declared is honoured, not chunked."""
    body = [b"sized-", b"stream"]
    start_response("200 OK", list(TEXT) + [("Content-Length", str(sum(map(len, body))))])
    return (piece for piece in body)


def stream_hold(environ, start_response):
    """A generator with an M0-Hold header: the hold's contract wins — the
    body LEADS the held stream, so it is joined, never streamed."""
    start_response(
        "200 OK",
        [("Content-Type", "text/event-stream"), ("M0-Hold", "stream"),
         ("M0-Channel", "held")],
    )
    return (piece for piece in [b": one\n\n", b": two\n\n"])


def header_injection(environ, start_response):
    """Application headers carrying CR/LF and NUL, beside a clean one.

    Response splitting. `write_latin1_to` emits `name: value\r\n` with no
    inspection, so an application that builds a header out of user input could
    end the header block and append headers -- or a whole body -- of its own.
    `has_control_bytes` in m0-wsgi's `response.mojo` DROPS such a header rather
    than raising, because by then the application has run and its body is real.

    `X-Clean` is the load-bearing half of the route: without it the smoke
    cannot tell "dropped the dangerous header" from "dropped every header".

    Deliberately non-conforming, like `/no-content-type`: `wsgiref.validate`
    rejects a control character in a header value, so this route is exercised
    only in the unvalidated pass.
    """
    start_response(
        "200 OK",
        list(TEXT)
        + [
            ("X-Injected", "safe\r\nX-Evil: yes"),
            ("X-Nul", "safe\x00tail"),
            ("X-Clean", "ordinary"),
        ],
    )
    return [b"injected"]


def not_found(environ, start_response):
    start_response("404 Not Found", list(TEXT))
    return [b"not found"]


ROUTES = {
    "/": root,
    "/pid": pid,
    "/proxies": proxies,
    "/method": method,
    "/environ": environ_dump,
    "/write": write_only,
    "/write/mixed": write_mixed,
    "/chunks": chunks,
    "/close": closing,
    "/close/count": close_count,
    "/no-content-type": no_content_type,
    "/start-twice": start_twice,
    "/exc-info": exc_info_replace,
    "/status": status,
    "/input/read": input_read,
    "/input/readline": input_readline,
    "/input/iter": input_iter,
    "/input/overread": input_overread,
    "/subview": subview,
    "/reentrant": reentrant,
    "/slow": slow,
    "/busy": busy,
    "/stuck": stuck,
    "/stream": stream,
    "/stream-forever": stream_forever,
    "/stream-raises": stream_raises,
    "/stream-empty": stream_empty,
    "/stream-write-inside": stream_write_inside,
    "/stream-cl": stream_cl,
    "/stream-hold": stream_hold,
    "/inject": header_injection,
}


def _dispatch(environ, start_response):
    return ROUTES.get(environ.get("PATH_INFO", ""), not_found)(
        environ, start_response
    )


application = _dispatch

# Same opt-in as the Django example: wrap in the stdlib's PEP 3333 checker.
# This is the primary target for it -- the routes above are chosen to exercise
# the spec, where Django's traffic only ever exercises the conventional slice.
if os.environ.get("M0_WSGI_VALIDATE"):
    from wsgiref.validate import validator

    application = validator(_dispatch)
