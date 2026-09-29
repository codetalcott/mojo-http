"""Response constructors every Mojo app was writing for itself.

`apps/notes_api`, `apps/datastar_todo` and `apps/datastar_counter` each
carried their own `_json`, `_html`, `_no_content` and `_parse_id` — in the
`_html` and `_parse_id` cases byte-identical copies. These are those bodies,
lifted rather than invented, so the wire output is unchanged.

Two things are deliberately NOT here. Content negotiation stays in
`content_negotiation.mojo`, which is format-agnostic by design; and nothing
here consults a request's `Accept` — `vary_accept` only *marks* a response
whose representation was negotiated, leaving the policy to the app.
"""

from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse

from m0_core.json_escape import escape_json_string

from .router import _list_contains


def json(status: Int, text: String, body: String) -> HTTPResponse:
    """A JSON response. `body` is emitted verbatim — escape it yourself."""
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=status,
        status_text=text,
    )


def html(body: String) -> HTTPResponse:
    """A 200 text/html response."""
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, "text/html; charset=utf-8")
        ),
        status_code=200,
        status_text="OK",
    )


def empty(status: Int, text: String) -> HTTPResponse:
    """A bodiless response — 204, 205, 304."""
    return HTTPResponse(
        body_bytes=String("").as_bytes(),
        status_code=status,
        status_text=text,
    )


def no_content() -> HTTPResponse:
    """204 No Content."""
    return empty(204, String("No Content"))


def redirect(status: Int, location: String) -> HTTPResponse:
    """A redirect to `location`.

    `common_response.mojo` ships only `SeeOther` (303), and that one requires
    a content type it then puts on an empty body. The other four codes had no
    constructor at all, so an app redirecting permanently built the response
    and its `Location` by hand. `status` is not validated: 3xx is the caller's
    to choose, and a deliberate 201-with-Location is legitimate.

    A control byte in `location` -- any C0 control, CR, LF and NUL among
    them, or DEL -- is percent-encoded, as `url_for` encodes one. A target
    built from request data (`?next=%0D%0A...`, which `unquote` decodes to
    a real line break) would otherwise carry the break into the head, where
    the writer drops the whole header rather than let it split the
    response, and the redirect would go out with no `Location` at all. It
    cannot raise instead: views on the loop and the login's refusals call
    this from code that does not raise. Every other byte is written as
    given, so an ordinary target is unchanged.
    """
    return HTTPResponse(
        body_bytes=String("").as_bytes(),
        headers=Headers(Header(HeaderKey.LOCATION, _encode_controls(location))),
        status_code=status,
        status_text=reason_phrase(status),
    )


def _encode_controls(s: String) -> String:
    """`s` with each C0 control byte and DEL as `%XX`, every other byte as
    it was. A byte walk: `s` may hold request bytes that are not UTF-8, so
    it is never sliced on a codepoint boundary (SPEC G14)."""
    comptime HEX = "0123456789ABCDEF"
    var b = s.as_bytes()
    var n = len(b)
    var out = String()
    var run = 0
    for i in range(n):
        var ch = Int(b[i])
        if ch >= 0x20 and ch != 0x7F:
            continue
        out += StringSpan(unsafe_from_utf8=b[run:i])
        out += "%"
        out += HEX[byte=ch >> 4 : (ch >> 4) + 1]
        out += HEX[byte=ch & 15 : (ch & 15) + 1]
        run = i + 1
    if run == 0:
        return s
    out += StringSpan(unsafe_from_utf8=b[run:n])
    return out


def problem(
    status: Int, title: String, detail: String, instance: String
) -> HTTPResponse:
    """An RFC 9457 `application/problem+json` response."""
    # escape_json_string wraps its result in double quotes itself.
    var body = String(
        '{"type":"about:blank","title":', escape_json_string(title),
        ',"status":', status,
        ',"detail":', escape_json_string(detail),
        ',"instance":', escape_json_string(instance), "}",
    )
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, "application/problem+json")
        ),
        status_code=status,
        status_text=title,
    )


def vary(var resp: HTTPResponse, name: String) -> HTTPResponse:
    """Add `name` to the response's `Vary`, keeping what it already names.

    It used to be an overwrite — `resp.headers[VARY] = "Accept"` — which
    was invisible while nothing set `Vary` twice, and became a defect the
    moment one URL varied on two things: a fragment negotiated on `Accept`
    AND answered bare or wrapped by `HX-Request`. A response that names one
    of the two lets a shared cache replay the wrong representation on the
    other axis. A name already present (compared as HTTP compares field
    names, case-insensitively) is not repeated.
    """
    var existing = resp.headers.get(HeaderKey.VARY)
    if existing:
        var have = existing.value()
        # `*` stands alone (RFC 9110 §12.5.5): the response already varies
        # on everything, and `*, name` is a shape a sender must not emit.
        if _list_contains(have, "*"):
            return resp^
        if _list_contains[fold_case=True](have, name):
            return resp^
        # An empty field is the same as none.
        if have.strip().byte_length() == 0:
            resp.headers[HeaderKey.VARY] = name
            return resp^
        resp.headers[HeaderKey.VARY] = String(have, ", ", name)
        return resp^
    resp.headers[HeaderKey.VARY] = name
    return resp^


def vary_accept(var resp: HTTPResponse) -> HTTPResponse:
    """Mark a response whose representation was chosen by the Accept header.

    Without `Vary: Accept`, a shared cache that stored the HTML answer would
    happily replay it to a JSON client. Every negotiated representation gets
    it — the 304 included, per RFC 9110 §15.4.5.
    """
    return vary(resp^, "Accept")


def accept_header(req: HTTPRequest) raises -> String:
    """The `Accept` header, with absence meaning `*/*` per RFC 9110.

    What `*/*` then resolves to is the app's negotiation policy, not this
    function's business.
    """
    var accept = req.headers.get(HeaderKey.ACCEPT)
    if accept:
        return accept.value()
    return String("*/*")


def body_string(req: HTTPRequest) -> String:
    """The request body as a String, empty when there is none."""
    if len(req.body_raw) == 0:
        return String("")
    return String(StringSpan(unsafe_from_utf8=Span(req.body_raw)))


def param_int(s: String) -> Int:
    """Parse a decimal path parameter; -1 when it is not a plain number.

    -1 rather than raising, because every caller treats a bad id as a 404 and
    an exception would cost a `try` on the routing path.

    A parameter longer than 18 digits is also -1. The hand-written copies this
    replaces multiplied without bound, so `/notes/99999999999999999999`
    silently wrapped to some other note's id; 18 digits cannot overflow Int64,
    and nothing legitimate sends more.
    """
    var n = s.byte_length()
    if n == 0 or n > 18:
        return -1
    var result = 0
    var bytes = s.as_bytes()
    for i in range(n):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return -1
        result = result * 10 + (c - ord("0"))
    return result


def reason_phrase(status: Int) -> String:
    """The standard reason phrase for `status`, or the empty string --
    legal on the wire -- for a code with none.

    CPython 3.13's `http.client.responses`, entry for entry (62 codes; the
    generator is in the commit that added the table to `m0_wsgi.response`).
    The one table: `redirect`, `page_or_fragment` and the login's refusals
    name their statuses with it, and `m0serve` answers an ASGI
    application's integer status with it, so that phrase never becomes a
    Python `str` at all. `page_or_fragment`'s `status` used to travel with
    a default `text` of `"OK"` (a styled 422 went out as `422 OK`), and the
    redirect table answered any code it did not list `Redirect`.
    """
    if status < 200:
        if status == 100:
            return "Continue"
        elif status == 101:
            return "Switching Protocols"
        elif status == 102:
            return "Processing"
        elif status == 103:
            return "Early Hints"
    elif status < 300:
        if status == 200:
            return "OK"
        elif status == 201:
            return "Created"
        elif status == 202:
            return "Accepted"
        elif status == 203:
            return "Non-Authoritative Information"
        elif status == 204:
            return "No Content"
        elif status == 205:
            return "Reset Content"
        elif status == 206:
            return "Partial Content"
        elif status == 207:
            return "Multi-Status"
        elif status == 208:
            return "Already Reported"
        elif status == 226:
            return "IM Used"
    elif status < 400:
        if status == 300:
            return "Multiple Choices"
        elif status == 301:
            return "Moved Permanently"
        elif status == 302:
            return "Found"
        elif status == 303:
            return "See Other"
        elif status == 304:
            return "Not Modified"
        elif status == 305:
            return "Use Proxy"
        elif status == 307:
            return "Temporary Redirect"
        elif status == 308:
            return "Permanent Redirect"
    elif status < 500:
        if status == 400:
            return "Bad Request"
        elif status == 401:
            return "Unauthorized"
        elif status == 402:
            return "Payment Required"
        elif status == 403:
            return "Forbidden"
        elif status == 404:
            return "Not Found"
        elif status == 405:
            return "Method Not Allowed"
        elif status == 406:
            return "Not Acceptable"
        elif status == 407:
            return "Proxy Authentication Required"
        elif status == 408:
            return "Request Timeout"
        elif status == 409:
            return "Conflict"
        elif status == 410:
            return "Gone"
        elif status == 411:
            return "Length Required"
        elif status == 412:
            return "Precondition Failed"
        elif status == 413:
            return "Content Too Large"
        elif status == 414:
            return "URI Too Long"
        elif status == 415:
            return "Unsupported Media Type"
        elif status == 416:
            return "Range Not Satisfiable"
        elif status == 417:
            return "Expectation Failed"
        elif status == 418:
            return "I'm a Teapot"
        elif status == 421:
            return "Misdirected Request"
        elif status == 422:
            return "Unprocessable Content"
        elif status == 423:
            return "Locked"
        elif status == 424:
            return "Failed Dependency"
        elif status == 425:
            return "Too Early"
        elif status == 426:
            return "Upgrade Required"
        elif status == 428:
            return "Precondition Required"
        elif status == 429:
            return "Too Many Requests"
        elif status == 431:
            return "Request Header Fields Too Large"
        elif status == 451:
            return "Unavailable For Legal Reasons"
    elif status < 600:
        if status == 500:
            return "Internal Server Error"
        elif status == 501:
            return "Not Implemented"
        elif status == 502:
            return "Bad Gateway"
        elif status == 503:
            return "Service Unavailable"
        elif status == 504:
            return "Gateway Timeout"
        elif status == 505:
            return "HTTP Version Not Supported"
        elif status == 506:
            return "Variant Also Negotiates"
        elif status == 507:
            return "Insufficient Storage"
        elif status == 508:
            return "Loop Detected"
        elif status == 510:
            return "Not Extended"
        elif status == 511:
            return "Network Authentication Required"
    return ""
