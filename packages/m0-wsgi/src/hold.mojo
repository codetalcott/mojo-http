"""Detect a stream-hold instruction in a WSGI response.

A WSGI application cannot stream — the bridge drains its iterable before a
byte leaves the process — but the server it runs inside holds SSE connections
natively. This module is the seam between the two: the application returns an
ordinary buffered response carrying two instruction headers, and the handler
converts that response into an SSE hold after the fact.

    M0-Hold: stream
    M0-Channel: <name>

The pattern is Pushpin's GRIP, collapsed into one process: the application
decides *whether* this connection may subscribe and *which* channel it joins
(it can run auth, sessions, anything — it is a normal request to it), and the
server owns the connection from then on. The header names are M0-prefixed
because this is GRIP-shaped, not GRIP-compatible.

One channel per connection. `SSERegistry` stores exactly one filter URL per
slot, and `Headers` is last-write-wins for a repeated name — a second
`M0-Channel` header would silently replace the first anyway, so the contract
makes the limit explicit instead.

The instruction headers are stripped in every branch, including the degraded
ones: they are addressed to this server, and leaking them to a client would
advertise an internal control surface.
"""

from lightbug_http import HTTPResponse
from lightbug_http.io.bytes import Bytes


comptime HOLD_HEADER = "m0-hold"
"""Response header naming the hold mode. Only `stream` is understood."""

comptime CHANNEL_HEADER = "m0-channel"
"""Response header naming the channel the connection subscribes to."""

comptime STREAM_OPEN_COMMENT = ": open\n\n"
"""Substituted when a held response has an empty body.

An SSE comment: it flushes intermediary buffers so the client sees the stream
open promptly, without producing an event the application has to handle.
Mirrors `m0_http`'s `sse_response` default — restated here so this package's
import set stays `lightbug_http` + `std.python` only.
"""


struct HoldResult(Movable):
    """What `take_stream_hold` decided.

    `held` is the only field a handler must consult; `channel` is meaningful
    only when `held` is True.
    """

    var held: Bool
    var channel: String

    def __init__(out self, held: Bool, var channel: String):
        self.held = held
        self.channel = channel^


def take_stream_hold(mut resp: HTTPResponse) -> HoldResult:
    """Consume any hold instruction in `resp`, converting it to an SSE open.

    No instruction headers: the response is untouched. Instruction headers
    present but unusable — the mode is not `stream`, the status is not 200,
    or the channel is missing or empty — the headers are stripped and the
    response is served as the ordinary buffered response it already is, which
    is also what the same application code does when it runs under a server
    that has never heard of these headers.

    On a hold: both headers are stripped, the response becomes
    `text/event-stream` with `Cache-Control: no-cache` and
    `X-Accel-Buffering: no` (nginx buffers streams by default), the
    application's body is kept verbatim as the head of the stream (an empty
    body becomes `: open\\n\\n`), and `sse_streaming` is set so the event loop
    keeps the connection open and starts draining it. The caller subscribes
    the slot; this function does not know about registries.

    `Content-Length` is left alone on purpose: the event loop strips it from
    every streaming response at encode time.
    """
    if HOLD_HEADER not in resp.headers:
        return HoldResult(False, String(""))

    var is_stream = resp.headers.value_equals_ignore_case(HOLD_HEADER, "stream")
    var channel = String("")
    var channel_opt = resp.headers.get(CHANNEL_HEADER)
    if channel_opt:
        channel = channel_opt.value()

    resp.headers.pop(HOLD_HEADER)
    resp.headers.pop(CHANNEL_HEADER)

    if not is_stream or resp.status_code != 200 or channel.byte_length() == 0:
        return HoldResult(False, String(""))

    resp.headers["content-type"] = "text/event-stream"
    resp.headers["cache-control"] = "no-cache"
    resp.headers["x-accel-buffering"] = "no"
    if len(resp.body_raw) == 0:
        resp.body_raw = Bytes(String(STREAM_OPEN_COMMENT).as_bytes())
    resp.sse_streaming = True
    return HoldResult(True, channel^)
