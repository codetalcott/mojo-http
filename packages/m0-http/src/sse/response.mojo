"""The HTTP response that opens an SSE stream.

Every SSE endpoint needs the same response shape, and the headers that matter
are the easy ones to forget: without `Cache-Control: no-cache` an intermediary
may buffer or replay the stream, and nginx buffers it by default regardless.
"""

from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.strings import next_list_member, trim_ows

from ..reply import vary


comptime SSE_CONTENT_TYPE = "text/event-stream"

comptime SSE_OPEN_COMMENT = ": open\n\n"
"""Default first bytes on the wire.

An SSE comment: it flushes intermediary buffers so the client sees the stream
open promptly, without producing an event the application has to handle.
"""


def sse_response(initial: String = SSE_OPEN_COMMENT, zstd: Bool = False) -> HTTPResponse:
    """Build the 200 response that opens an SSE stream.

    Sets `Content-Type: text/event-stream`, `Cache-Control: no-cache`, and
    `X-Accel-Buffering: no` (which defeats nginx's proxy buffering), and marks
    the response `sse_streaming` so the event loop keeps the connection open
    and starts draining it.

    `initial` is written immediately; the default is a comment frame. Pass a
    real frame to deliver a snapshot as the first thing the client sees.

    The event loop strips `Content-Length` from streaming responses, so the
    constructor setting one is harmless.

    `zstd=True` asks the event loop to compress the stream: one zstd
    context for its life, a block flushed at every write, `initial` and
    the heartbeats included, under `Content-Encoding: zstd` with
    `Accept-Encoding` in `Vary`. It does not negotiate: pass
    `accepts_zstd(req)`. Where the loop cannot open libzstd the stream goes
    out uncompressed and the header comes off
    (docs/notes/compressing-a-stream.md).
    """
    var resp = HTTPResponse(
        body_bytes=initial.as_bytes(),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, SSE_CONTENT_TYPE),
            Header("cache-control", "no-cache"),
            Header("x-accel-buffering", "no"),
        ),
        status_code=200,
        status_text="OK",
    )
    resp.sse_streaming = True
    if zstd:
        resp.zstd_stream = True
        resp.headers["content-encoding"] = "zstd"
        return vary(resp^, "Accept-Encoding")
    return resp^


def accepts_zstd(req: HTTPRequest) -> Bool:
    """Whether `req` takes a zstd-coded response, by its `Accept-Encoding`
    (`zstd_acceptable`): the argument `sse_response(zstd=...)` wants.

    A request without the field takes none. RFC 9110 lets a server pick any
    coding then; a stream is compressed only for a client that asked, so a
    plain `curl` reads it as written.
    """
    var value = req.headers.get("accept-encoding")
    if not value:
        return False
    return zstd_acceptable(value.value())


def zstd_acceptable(accept_encoding: String) -> Bool:
    """Whether an `Accept-Encoding` value takes zstd (RFC 9110 §12.5.3).

    A `zstd` member decides by its weight, above zero or not; with none, a
    `*` member does. Codings compare without regard to case (§8.4.1), a
    member whose weight is not a qvalue is taken as refusing, and an empty
    member is skipped. Walked over the bytes, which a request may carry
    outside UTF-8 (SPEC G14), never sliced as a string.
    """
    var x = accept_encoding.as_bytes()
    var zstd = -1
    var star = -1
    var start = 0
    while start <= len(x):
        var m = next_list_member(x, start)
        start = m[2]
        if m[0] == m[1]:
            continue
        var semi = m[0]
        while semi < m[1] and x[semi] != 0x3B:  # ';'
            semi += 1
        var c = trim_ows(x, m[0], semi)
        var w = 1 if _weight_above_zero(x, semi, m[1]) else 0
        if _names(x, c[0], c[1], "zstd"):
            zstd = w
        elif c[1] - c[0] == 1 and x[c[0]] == 0x2A:  # '*'
            star = w
    if zstd >= 0:
        return zstd == 1
    return star == 1


def _names(x: Span[UInt8, _], a: Int, b: Int, name: StaticString) -> Bool:
    """Whether `x[a:b]` is `name`, a lowercase token, in any case."""
    var n = name.as_bytes()
    if b - a != len(n):
        return False
    for i in range(len(n)):
        var ch = x[a + i]
        if ch >= 0x41 and ch <= 0x5A:
            ch += 0x20
        if ch != n[i]:
            return False
    return True


def _weight_above_zero(x: Span[UInt8, _], a: Int, b: Int) -> Bool:
    """A member's weight, from its parameters `x[a:b]` (each after a `;`):
    above zero or not. No `q` parameter is a weight of 1."""
    var i = a
    while i < b:
        var j = i + 1
        while j < b and x[j] != 0x3B:  # ';'
            j += 1
        var p = trim_ows(x, i + 1, j)
        if (
            p[1] - p[0] >= 2
            and (x[p[0]] == 0x71 or x[p[0]] == 0x51)  # 'q' or 'Q'
            and x[p[0] + 1] == 0x3D  # '='
        ):
            return _qvalue_above_zero(x, p[0] + 2, p[1])
        i = j
    return True


def _qvalue_above_zero(x: Span[UInt8, _], a: Int, b: Int) -> Bool:
    """`x[a:b]` read as RFC 9110 §12.4.2's qvalue,
    `( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )`: True above zero,
    False for zero and for anything that is not a qvalue."""
    var n = b - a
    if n < 1 or n > 5:
        return False
    var lead = x[a]
    if lead != 0x30 and lead != 0x31:  # '0', '1'
        return False
    if n == 1:
        return lead == 0x31
    if x[a + 1] != 0x2E:  # '.'
        return False
    var above = lead == 0x31
    for k in range(a + 2, b):
        var d = x[k]
        if d < 0x30 or d > 0x39:
            return False
        if lead == 0x31 and d != 0x30:
            return False
        if d != 0x30:
            above = True
    return above
