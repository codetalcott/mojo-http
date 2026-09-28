"""WSGI and ASGI `(status, headers, body)` → `HTTPResponse`.

**This is the response half of the bridge, and it was unmeasured until
2026-08-24.** `scripts/probes/bench_bridge_parts.mojo` split the request side five
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
from lightbug_http.header import KH_CONTENT_LENGTH
from lightbug_http.http import is_bodiless_status
from m0_http.reply import reason_phrase

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


def build_response(
    bridge: PyBridge, status: String, headers: PythonObject, body: PythonObject,
    streaming: Bool = False,
    is_head: Bool = False,
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

    `is_head` says the request was a HEAD, whose answer keeps the
    application's own `Content-Length`: it describes the body a GET
    would carry (RFC 9110 §9.3.2), not the empty one this response has.
    """
    var code_and_text = split_status(status)
    return _assemble(
        bridge, code_and_text[0], code_and_text[1], headers, False, body,
        streaming, is_head,
    )


def build_asgi_response(
    bridge: PyBridge, status: Int, headers: PythonObject, body: PythonObject,
    streaming: Bool = False,
    is_head: Bool = False,
) raises -> HTTPResponse:
    """Assemble an `HTTPResponse` from an ASGI application's untouched head.

    `status` is the `int` of `http.response.start` and `headers` the
    application's own list of `(bytes, bytes)` pairs: the executor's `done`
    and `stream_start` events carry them exactly as the app produced them,
    so no `'%d %s'` is formatted and no name or value is decoded to `str`
    on the Python side — the reason phrase comes from `m0_http`'s
    `reason_phrase`, the table every server path shares, and the
    bytes are read where they are. `streaming` is the executor's
    `stream_start` head and `is_head` a HEAD's answer, with the same
    contracts as `build_response`'s.
    """
    return _assemble(
        bridge, status, reason_phrase(status), headers, True, body, streaming,
        is_head,
    )


def _assemble(
    bridge: PyBridge,
    code: Int,
    text: String,
    headers: PythonObject,
    bytes_pairs: Bool,
    body: PythonObject,
    streaming: Bool,
    is_head: Bool,
) raises -> HTTPResponse:
    var out_headers = Headers()
    var cookies = ResponseCookieJar()
    bridge.read_head(headers, bytes_pairs, out_headers, cookies)

    # The framing is the server's, never the application's: a buffered
    # body gets the measured Content-Length, a streamed one gets the event
    # loop's chunked framing (or close-delimiting on HTTP/1.0), and an
    # application's own `Transfer-Encoding` would frame a body the client
    # cannot then parse. The rest of the head is the application's as sent:
    # both constructions pass `invent_entity_headers=False`, because the
    # constructor's octet-stream default turned a redirect, a 204 and
    # FastHTML's 404 page into downloads (SPEC K12).
    out_headers.pop(HeaderKey.TRANSFER_ENCODING)
    if streaming:
        out_headers.pop(HeaderKey.CONTENT_LENGTH)
        var head = HTTPResponse(
            owned_body=List[UInt8](),
            headers=out_headers^,
            cookies=cookies^,
            status_code=code,
            status_text=text,
            invent_entity_headers=False,
        )
        head.sse_streaming = True
        return head^

    var body_bytes = bridge.body_bytes(body)
    if is_bodiless_status(code):
        # No content, and no length the server invents: a 304 keeps the
        # application's (RFC 9110 §8.6), and the loop's framing rule drops
        # a 1xx's or 204's, and any body (SPEC A21).
        pass
    elif is_head:
        # The application's Content-Length describes the body a GET would
        # send (RFC 9110 §9.3.2): keep it -- a FileResponse's HEAD went out
        # as `content-length: 0`. With none, measure the body the
        # application produced anyway (a WSGI app answering HEAD like GET,
        # which `smoke-blocking-threads` pins); with no body either, invent
        # none.
        if out_headers.known_index(KH_CONTENT_LENGTH) < 0 and len(body_bytes) > 0:
            out_headers.set_int(HeaderKey.CONTENT_LENGTH, len(body_bytes))
    else:
        # A real body: its measured length is authoritative, whatever the
        # application guessed -- a wrong one would misframe the connection.
        out_headers.set_int(HeaderKey.CONTENT_LENGTH, len(body_bytes))

    return HTTPResponse(
        owned_body=body_bytes^,
        headers=out_headers^,
        cookies=cookies^,
        status_code=code,
        status_text=text,
        invent_entity_headers=False,
    )
