"""The HTTP response that opens an SSE stream.

Every SSE endpoint needs the same response shape, and the headers that matter
are the easy ones to forget: without `Cache-Control: no-cache` an intermediary
may buffer or replay the stream, and nginx buffers it by default regardless.
"""

from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPResponse


comptime SSE_CONTENT_TYPE = "text/event-stream"

comptime SSE_OPEN_COMMENT = ": open\n\n"
"""Default first bytes on the wire.

An SSE comment: it flushes intermediary buffers so the client sees the stream
open promptly, without producing an event the application has to handle.
"""


def sse_response(initial: String = SSE_OPEN_COMMENT) -> HTTPResponse:
    """Build the 200 response that opens an SSE stream.

    Sets `Content-Type: text/event-stream`, `Cache-Control: no-cache`, and
    `X-Accel-Buffering: no` (which defeats nginx's proxy buffering), and marks
    the response `sse_streaming` so the event loop keeps the connection open
    and starts draining it.

    `initial` is written immediately; the default is a comment frame. Pass a
    real frame to deliver a snapshot as the first thing the client sees.

    The event loop strips `Content-Length` from streaming responses, so the
    constructor setting one is harmless.
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
    return resp^
