"""WSGI and ASGI `(status, headers, body)` → `HTTPResponse`.

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

The header READ lives on the bridge (`PyBridge.read_head`), not here:
it walks the application's list through the C API — borrowed
`PyList_GetItem`/`PyTuple_GetItem` pointers and each object's own
UTF-8 or `bytes` buffer — and CLAUDE.md keeps everything that touches
the interpreter in `bridge.mojo`. This file assembles: status, the
framing headers, the body. `build_response` is the WSGI shape (a
`"200 OK"` status and `(str, str)` pairs); `build_asgi_response` is the
executor's (the status as the `int` the application sent, the headers
as its own `(bytes, bytes)` list, no decode in between).
"""

from std.python import PythonObject

from lightbug_http import HTTPResponse, Headers, HeaderKey
from lightbug_http.cookie import ResponseCookieJar

from .bridge import PyBridge
from .environ import span_has_control_bytes


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
    this now. The bridge applies the byte-span form
    (`span_has_control_bytes`) to every header it reads.
    """
    return span_has_control_bytes(value.as_bytes())


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


def reason_for(code: Int) -> String:
    """The standard reason phrase for `code`, or the empty string.

    CPython 3.13's `http.client.responses`, entry for entry (62 codes; the
    generator is in the commit that added this). It replaces the shim's
    `'%d %s' % (status, _reasons.get(status, ''))` on the executor path, so
    an ASGI status crosses to Mojo as the `int` the application sent and
    the phrase never becomes a Python `str` at all. An unknown code gets
    an empty phrase, exactly as `responses.get(status, '')` gave it.
    """
    if code < 200:
        if code == 100:
            return "Continue"
        elif code == 101:
            return "Switching Protocols"
        elif code == 102:
            return "Processing"
        elif code == 103:
            return "Early Hints"
    elif code < 300:
        if code == 200:
            return "OK"
        elif code == 201:
            return "Created"
        elif code == 202:
            return "Accepted"
        elif code == 203:
            return "Non-Authoritative Information"
        elif code == 204:
            return "No Content"
        elif code == 205:
            return "Reset Content"
        elif code == 206:
            return "Partial Content"
        elif code == 207:
            return "Multi-Status"
        elif code == 208:
            return "Already Reported"
        elif code == 226:
            return "IM Used"
    elif code < 400:
        if code == 300:
            return "Multiple Choices"
        elif code == 301:
            return "Moved Permanently"
        elif code == 302:
            return "Found"
        elif code == 303:
            return "See Other"
        elif code == 304:
            return "Not Modified"
        elif code == 305:
            return "Use Proxy"
        elif code == 307:
            return "Temporary Redirect"
        elif code == 308:
            return "Permanent Redirect"
    elif code < 500:
        if code == 400:
            return "Bad Request"
        elif code == 401:
            return "Unauthorized"
        elif code == 402:
            return "Payment Required"
        elif code == 403:
            return "Forbidden"
        elif code == 404:
            return "Not Found"
        elif code == 405:
            return "Method Not Allowed"
        elif code == 406:
            return "Not Acceptable"
        elif code == 407:
            return "Proxy Authentication Required"
        elif code == 408:
            return "Request Timeout"
        elif code == 409:
            return "Conflict"
        elif code == 410:
            return "Gone"
        elif code == 411:
            return "Length Required"
        elif code == 412:
            return "Precondition Failed"
        elif code == 413:
            return "Content Too Large"
        elif code == 414:
            return "URI Too Long"
        elif code == 415:
            return "Unsupported Media Type"
        elif code == 416:
            return "Range Not Satisfiable"
        elif code == 417:
            return "Expectation Failed"
        elif code == 418:
            return "I'm a Teapot"
        elif code == 421:
            return "Misdirected Request"
        elif code == 422:
            return "Unprocessable Content"
        elif code == 423:
            return "Locked"
        elif code == 424:
            return "Failed Dependency"
        elif code == 425:
            return "Too Early"
        elif code == 426:
            return "Upgrade Required"
        elif code == 428:
            return "Precondition Required"
        elif code == 429:
            return "Too Many Requests"
        elif code == 431:
            return "Request Header Fields Too Large"
        elif code == 451:
            return "Unavailable For Legal Reasons"
    elif code < 600:
        if code == 500:
            return "Internal Server Error"
        elif code == 501:
            return "Not Implemented"
        elif code == 502:
            return "Bad Gateway"
        elif code == 503:
            return "Service Unavailable"
        elif code == 504:
            return "Gateway Timeout"
        elif code == 505:
            return "HTTP Version Not Supported"
        elif code == 506:
            return "Variant Also Negotiates"
        elif code == 507:
            return "Insufficient Storage"
        elif code == 508:
            return "Loop Detected"
        elif code == 510:
            return "Not Extended"
        elif code == 511:
            return "Network Authentication Required"
    return ""


def build_response(
    bridge: PyBridge, status: String, headers: PythonObject, body: PythonObject,
    streaming: Bool = False,
) raises -> HTTPResponse:
    """Assemble an `HTTPResponse` from what a WSGI application returned.

    `status` is the `"200 OK"` line `start_response` received and `headers`
    its `(str, str)` list — also the shape the buffered ASGI escape hatch
    returns, which is why it has no caller of its own.

    `streaming` builds the HEAD of a body that will follow as chunk-channel
    frames — a pool thread streaming a WSGI iterable. The head carries an
    EMPTY body and no `Content-Length`: `_finish_response` writes
    `body_raw` verbatim after the headers, before any `size CRLF` framing,
    so a first chunk placed here would go out unframed on a chunked
    stream. The first chunk is the first `s` frame.
    """
    var code_and_text = split_status(status)
    return _assemble(
        bridge, code_and_text[0], code_and_text[1], headers, False, body,
        streaming,
    )


def build_asgi_response(
    bridge: PyBridge, status: Int, headers: PythonObject, body: PythonObject,
    streaming: Bool = False,
) raises -> HTTPResponse:
    """Assemble an `HTTPResponse` from an ASGI application's untouched head.

    `status` is the `int` of `http.response.start` and `headers` the
    application's own list of `(bytes, bytes)` pairs: the executor's `done`
    and `stream_start` events carry them exactly as the app produced them,
    so no `'%d %s'` is formatted and no name or value is decoded to `str`
    on the Python side — the reason phrase comes from `reason_for`, the
    bytes are read where they are. `streaming` is the executor's
    `stream_start` head, with the same contract as `build_response`'s.
    """
    return _assemble(
        bridge, status, reason_for(status), headers, True, body, streaming
    )


def _assemble(
    bridge: PyBridge,
    code: Int,
    text: String,
    headers: PythonObject,
    bytes_pairs: Bool,
    body: PythonObject,
    streaming: Bool,
) raises -> HTTPResponse:
    var out_headers = Headers()
    var cookies = ResponseCookieJar()
    bridge.read_head(headers, bytes_pairs, out_headers, cookies)

    # The framing is the server's, never the application's: a buffered
    # body gets the measured Content-Length, a streamed one gets the event
    # loop's chunked framing (or close-delimiting on HTTP/1.0), and an
    # application's own `Transfer-Encoding` would frame a body the client
    # cannot then parse.
    out_headers.pop(HeaderKey.TRANSFER_ENCODING)
    if streaming:
        out_headers.pop(HeaderKey.CONTENT_LENGTH)
        var head = HTTPResponse(
            owned_body=List[UInt8](),
            headers=out_headers^,
            cookies=cookies^,
            status_code=code,
            status_text=text,
        )
        head.sse_streaming = True
        return head^

    var body_bytes = bridge.body_bytes(body)
    # Content-Length is authoritative here, not whatever the application
    # guessed: a buffered response's real length is known.
    out_headers.set_int(HeaderKey.CONTENT_LENGTH, len(body_bytes))

    return HTTPResponse(
        owned_body=body_bytes^,
        headers=out_headers^,
        cookies=cookies^,
        status_code=code,
        status_text=text,
    )
