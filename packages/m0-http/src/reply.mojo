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
    """
    return HTTPResponse(
        body_bytes=String("").as_bytes(),
        headers=Headers(Header(HeaderKey.LOCATION, location)),
        status_code=status,
        status_text=_reason_for_redirect(status),
    )


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


def vary_accept(var resp: HTTPResponse) -> HTTPResponse:
    """Mark a response whose representation was chosen by the Accept header.

    Without `Vary: Accept`, a shared cache that stored the HTML answer would
    happily replay it to a JSON client. Every negotiated representation gets
    it — the 304 included, per RFC 9110 §15.4.5.
    """
    resp.headers[HeaderKey.VARY] = "Accept"
    return resp^


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
    return String(StringSlice(unsafe_from_utf8=Span(req.body_raw)))


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


def _reason_for_redirect(status: Int) -> String:
    if status == 301:
        return String("Moved Permanently")
    if status == 302:
        return String("Found")
    if status == 303:
        return String("See Other")
    if status == 307:
        return String("Temporary Redirect")
    if status == 308:
        return String("Permanent Redirect")
    return String("Redirect")
