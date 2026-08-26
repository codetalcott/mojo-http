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


def not_found(environ, start_response):
    start_response("404 Not Found", list(TEXT))
    return [b"not found"]


ROUTES = {
    "/": root,
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
    "/stuck": stuck,
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
