"""WSGI `(status, headers, body)` → `HTTPResponse`.

**This is the response half of the bridge, and it was unmeasured until
2026-08-24.** `scripts/bench_bridge_parts.mojo` split the request side five
times over while stopping short of this file, so a six-header Django-shaped
response cost **22.97 µs here against 2.18 µs for the entire request side** —
ten times the thing that had been optimised five times. See
docs/WSGI_PERFORMANCE.md; the bench now covers both directions.

The header half is where the interesting bug lives. `Headers` is a
`Dict[String, String]`, so writing `Set-Cookie` through it keeps only the last
one — and Django routinely sets two (`sessionid` and `csrftoken`) on the same
response. `ResponseCookieJar` emits one line per cookie, so every `Set-Cookie`
is routed there instead — as a **verbatim line** (`ResponseCookieJar.raw`),
never parsed into a `Cookie` and re-serialised. That round trip was lossy:
`Expiration` is a stub, `SameSite=Lax` failed a lowercase-only match, and a
value was cut at its first `=`. Serving three real Django projects, every
session and CSRF cookie reached the browser without `expires` or `SameSite`
(2026-08-26, docs/REAL_APP_VALIDATION.md). The application's line is the
header; PEP 3333 gives the server no licence to rewrite it. `smoke-django`
asserts the count and that the attributes survive the wire.
"""

from std.python import PythonObject

from lightbug_http import HTTPResponse, Headers, HeaderKey
from lightbug_http.header import name_is
from lightbug_http.cookie import ResponseCookieJar

from .bridge import PyBridge


def has_control_bytes(value: String) -> Bool:
    """Whether `value` carries a byte that would break header framing.

    CR and LF end a header line, so either one inside a value or a name
    lets the rest of that string be read as further headers — and, after a
    blank line, as a body the application never wrote. NUL is included
    because it terminates a C string and this repo hands header bytes to
    `sendfile`/`send` paths and to Python.

    The check exists because the alternative was trusting every
    application: `write_latin1_to` emits `name: value\\r\\n` with no
    inspection, so an app that reflected a query parameter into a header
    could split its own response. Django and Werkzeug reject these
    themselves, but a bare WSGI app has nothing between it and the socket,
    and the reason phrase is unvalidated even by the frameworks that do
    check header pairs. uvicorn and gunicorn both refuse them; so does
    this now.
    """
    for b in value.as_bytes():
        if b == 0x0D or b == 0x0A or b == 0x00:
            return True
    return False


def split_status(status: String) -> Tuple[Int, String]:
    """`"404 Not Found"` → `(404, "Not Found")`.

    A malformed status line yields `500 Internal Server Error` rather than
    raising: the application already ran, and a bad status is not worth
    discarding a real body over.

    A reason phrase carrying CR/LF/NUL is dropped to the empty string: it
    is written verbatim into the status line, so it is the one part of an
    application's response that frameworks generally do not validate and
    that would split the response just as a header value would. The code
    is kept — the client still gets the status the app chose.
    """
    var space = status.find(" ")
    if space < 0:
        try:
            return (Int(status.strip()), String(""))
        except:
            return (500, String("Internal Server Error"))
    try:
        var code = Int(String(status[byte=:space]).strip())
        var text = String(String(status[byte=space + 1 :]).strip())
        if has_control_bytes(text):
            return (code, String(""))
        return (code, text^)
    except:
        return (500, String("Internal Server Error"))


def build_response(
    bridge: PyBridge, status: String, headers: PythonObject, body: PythonObject
) raises -> HTTPResponse:
    """Assemble an `HTTPResponse` from what the WSGI application returned."""
    var code_and_text = split_status(status)

    var out_headers = Headers()
    var cookies = ResponseCookieJar()
    for pair in headers:
        var name = String(py=pair[0])
        var value = String(py=pair[1])
        # Response splitting: a CR or LF here would end the header line and
        # let the remainder be read as more headers, or as a body. Drop the
        # header rather than raise — the application has already run and its
        # body is real; one refused header is a better answer than a 500,
        # and a silently-split response is the worst of the three. Applies
        # to Set-Cookie too, whose value is transmitted verbatim below.
        if has_control_bytes(name) or has_control_bytes(value):
            continue
        # `name_is`, not `name.lower() == ...`. The lowercase copy this used
        # to allocate — once per header, purely to test one constant — was
        # measured at **3.2 µs per header**, 84% of everything this function
        # did for a six-header Django response. The parser on the REQUEST
        # side learned this already; `name_is`' own docstring names the
        # mistake, and header.mojo dispatches the identical Set-Cookie test
        # through it. This is the same fix, applied in the other direction.
        if name_is(name.as_bytes(), HeaderKey.SET_COOKIE):
            # Verbatim. The jar used to parse this into a `Cookie` and emit
            # its own serialisation, which dropped `expires` and `SameSite`
            # from every Django cookie and would cut a value at its first
            # `=` — see `ResponseCookieJar.raw`. Nothing here can improve on
            # the line the application wrote, and skipping the parse is also
            # the cheaper path on the measured response half of the bridge.
            cookies.add_raw(value)
        else:
            out_headers[name] = value

    var body_bytes = bridge.body_bytes(body)
    # Content-Length is authoritative here, not whatever the application
    # guessed: responses are fully buffered, so the real length is known.
    out_headers[HeaderKey.CONTENT_LENGTH] = String(len(body_bytes))
    # This server does not chunk-encode responses, so an application that asked
    # for it would produce a body the client cannot frame.
    out_headers.pop(HeaderKey.TRANSFER_ENCODING)

    return HTTPResponse(
        owned_body=body_bytes^,
        headers=out_headers^,
        cookies=cookies^,
        status_code=code_and_text[0],
        status_text=code_and_text[1],
    )
