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
response. `ResponseCookieJar` is keyed by `(name, domain, path)` and emits one
line per cookie, so every `Set-Cookie` is routed there instead. `smoke-django`
asserts the count.
"""

from std.python import PythonObject

from lightbug_http import HTTPResponse, Headers, HeaderKey
from lightbug_http.header import name_is
from lightbug_http.cookie import ResponseCookieJar

from .bridge import PyBridge


def split_status(status: String) -> Tuple[Int, String]:
    """`"404 Not Found"` → `(404, "Not Found")`.

    A malformed status line yields `500 Internal Server Error` rather than
    raising: the application already ran, and a bad status is not worth
    discarding a real body over.
    """
    var space = status.find(" ")
    if space < 0:
        try:
            return (Int(status.strip()), String(""))
        except:
            return (500, String("Internal Server Error"))
    try:
        var code = Int(String(status[byte=:space]).strip())
        return (code, String(String(status[byte=space + 1 :]).strip()))
    except:
        return (500, String("Internal Server Error"))


def build_response(
    bridge: PyBridge, status: String, headers: PythonObject, body: PythonObject
) raises -> HTTPResponse:
    """Assemble an `HTTPResponse` from what the WSGI application returned."""
    var code_and_text = split_status(status)

    var out_headers = Headers()
    var cookie_lines = List[String]()
    for pair in headers:
        var name = String(py=pair[0])
        var value = String(py=pair[1])
        # `name_is`, not `name.lower() == ...`. The lowercase copy this used
        # to allocate — once per header, purely to test one constant — was
        # measured at **3.2 µs per header**, 84% of everything this function
        # did for a six-header Django response. The parser on the REQUEST
        # side learned this already; `name_is`' own docstring names the
        # mistake, and header.mojo dispatches the identical Set-Cookie test
        # through it. This is the same fix, applied in the other direction.
        if name_is(name.as_bytes(), HeaderKey.SET_COOKIE):
            cookie_lines.append(value)
        else:
            out_headers[name] = value

    var cookies = ResponseCookieJar()
    try:
        cookies.from_headers(cookie_lines)
    except:
        # An unparseable Set-Cookie is the application's bug, not a reason to
        # drop its response on the floor. Serve the body without the cookie.
        pass

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
