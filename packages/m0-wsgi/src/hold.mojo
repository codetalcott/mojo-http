"""Detect a hold instruction in a WSGI response, and shape what follows.

A WSGI application cannot stream — the bridge drains its iterable before a
byte leaves the process — and it certainly cannot switch a connection to
another protocol: its response is buffered and re-encoded by the server. But
the server it runs inside holds SSE connections and speaks WebSocket
natively. This module is the seam between the two: the application returns an
ordinary buffered response carrying two instruction headers, and the handler
converts that response into a held connection after the fact.

    M0-Hold: stream        the connection becomes an SSE stream
    M0-Hold: websocket     the connection becomes a WebSocket
    M0-Channel: <name>     which channel it joins, either way

The pattern is Pushpin's GRIP, collapsed into one process: the application
decides *whether* this connection may be held and *which* channel it joins
(it can run auth, sessions, anything — it is a normal request to it), and the
server owns the connection from then on. The header names are M0-prefixed
because this is GRIP-shaped, not GRIP-compatible.

The two modes differ in what happens to the application's response. A
`stream` hold keeps it: the body becomes the head of the SSE stream, and
`take_hold` rewrites the headers in place. A `websocket` hold discards it —
the reply on the wire has to be `101 Switching Protocols` with a computed
`Sec-WebSocket-Accept`, which Django cannot produce and which carries no
body at all. `take_hold` therefore only *reports* a websocket hold; the
handler answers it with `websocket_upgrade(req)`. That asymmetry is the whole
reason a WSGI app can gate a WebSocket without being able to speak one:
Django approves the connection, Mojo performs the handshake.

The inbound direction is `ws_message_request`. A WebSocket message is not an
HTTP request, so to reach a synchronous view it has to be given the shape of
one — Pushpin's WebSocket-over-HTTP does exactly this, and so does this
module: one `POST` per message, the payload as the body, the channel and slot
as headers.

One channel per connection. `SSERegistry` stores exactly one filter URL per
slot, and `Headers` is last-write-wins for a repeated name — a second
`M0-Channel` header would silently replace the first anyway, so the contract
makes the limit explicit instead.

The instruction headers are stripped in every branch, including the degraded
ones: they are addressed to this server, and leaking them to a client would
advertise an internal control surface.
"""

from lightbug_http import HTTPRequest, HTTPResponse
from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI


comptime HOLD_HEADER = "m0-hold"
"""Response header naming the hold mode. `stream` and `websocket` are understood."""

comptime CHANNEL_HEADER = "m0-channel"
"""Response header naming the channel the connection subscribes to."""

comptime SLOT_HEADER = "m0-slot"
"""Request header naming the connection a synthetic WebSocket message came from."""

comptime OPCODE_HEADER = "m0-opcode"
"""Request header carrying a synthetic WebSocket message's RFC 6455 opcode."""

comptime HOLD_NONE = 0
"""No hold: serve the application's response as the ordinary response it is."""

comptime HOLD_STREAM = 1
"""SSE hold: the response was rewritten into the head of an event stream."""

comptime HOLD_WEBSOCKET = 2
"""WebSocket hold: the caller must answer with a `websocket_upgrade` 101."""

comptime STREAM_OPEN_COMMENT = ": open\n\n"
"""Substituted when a held response has an empty body.

An SSE comment: it flushes intermediary buffers so the client sees the stream
open promptly, without producing an event the application has to handle.
Mirrors `m0_http`'s `sse_response` default — restated here so this package's
import set stays `lightbug_http` + `std.python` only.
"""


struct HoldResult(Movable):
    """What `take_hold` decided.

    `mode` is the full answer; `held` is the same thing as a Bool, kept
    because a handler that only ever offers one mode reads better for it.
    `channel` is meaningful only when a hold was taken.
    """

    var held: Bool
    var mode: Int
    var channel: String

    def __init__(out self, mode: Int, var channel: String):
        self.held = mode != HOLD_NONE
        self.mode = mode
        self.channel = channel^


def take_hold(mut resp: HTTPResponse) -> HoldResult:
    """Consume any hold instruction in `resp`, whatever its mode.

    No instruction headers: the response is untouched and the mode is
    `HOLD_NONE`. Instruction headers present but unusable — an unknown mode,
    a status other than 200, or a missing or empty channel — the headers are
    stripped and the response is served as the ordinary buffered response it
    already is, which is also what the same application code does when it
    runs under a server that has never heard of these headers.

    On `HOLD_STREAM`: both headers are stripped, the response becomes
    `text/event-stream` with `Cache-Control: no-cache` and
    `X-Accel-Buffering: no` (nginx buffers streams by default), the
    application's body is kept verbatim as the head of the stream (an empty
    body becomes `: open\\n\\n`), and `sse_streaming` is set so the event loop
    keeps the connection open and starts draining it.

    On `HOLD_WEBSOCKET`: both headers are stripped and **nothing else is
    touched**. The response cannot become the reply — a WebSocket handshake
    answers `101` with a `Sec-WebSocket-Accept` derived from the request's
    key — so the caller discards it and returns `websocket_upgrade(req)`
    instead. What the application decided still stands: it approved the
    connection and named the channel.

    Either way the caller subscribes the slot; this function does not know
    about registries.

    `Content-Length` is left alone on purpose: the event loop strips it from
    every streaming response at encode time, and from every 101.
    """
    if HOLD_HEADER not in resp.headers:
        return HoldResult(HOLD_NONE, String(""))

    var is_stream = resp.headers.value_equals_ignore_case(HOLD_HEADER, "stream")
    var is_websocket = resp.headers.value_equals_ignore_case(
        HOLD_HEADER, "websocket"
    )
    var channel = String("")
    var channel_opt = resp.headers.get(CHANNEL_HEADER)
    if channel_opt:
        channel = channel_opt.value()

    resp.headers.pop(HOLD_HEADER)
    resp.headers.pop(CHANNEL_HEADER)

    if resp.status_code != 200 or channel.byte_length() == 0:
        return HoldResult(HOLD_NONE, String(""))

    if is_websocket:
        return HoldResult(HOLD_WEBSOCKET, channel^)
    if not is_stream:
        return HoldResult(HOLD_NONE, String(""))

    resp.headers["content-type"] = "text/event-stream"
    resp.headers["cache-control"] = "no-cache"
    resp.headers["x-accel-buffering"] = "no"
    if len(resp.body_raw) == 0:
        resp.body_raw = Bytes(String(STREAM_OPEN_COMMENT).as_bytes())
    resp.sse_streaming = True
    return HoldResult(HOLD_STREAM, channel^)


def take_stream_hold(mut resp: HTTPResponse) -> HoldResult:
    """`take_hold` for a handler that only offers SSE.

    Identical to `take_hold` except that a `websocket` instruction degrades
    instead of being reported: the headers are still stripped, and the
    application's response is served as-is. A handler that cannot perform an
    upgrade must not leave a client waiting for one.
    """
    var result = take_hold(resp)
    if result.mode == HOLD_STREAM:
        return result^
    return HoldResult(HOLD_NONE, String(""))


def request_last_event_id(req: HTTPRequest) -> Int:
    """The `Last-Event-ID` a reconnecting SSE client sent, as a number.

    0 — "I have seen nothing" — for an absent, empty, or non-numeric header,
    which is also the right answer for a client connecting the first time.
    The header is a free-form string in the SSE spec; this server's ids are
    the shared counter's, so anything that is not a plain non-negative
    integer cannot name one of them and is treated as absent rather than
    guessed at.

    Passed straight to `SSERegistry.subscribe`, whose delivery filter is
    `event_id > last_event_id`: a client reconnecting at 12 is not re-sent
    event 12. Note that suppression is all this buys on a raw `SSERegistry` —
    replaying events 13..N needs a journal, which `DatastarStream` has and
    the plain registry does not.
    """
    var raw = req.headers.get("last-event-id")
    if not raw:
        return 0
    var text = raw.value().strip()
    var n = text.byte_length()
    # 18 digits is the widest that cannot overflow Int64; a longer one is a
    # client inventing ids, not resuming ours.
    if n == 0 or n > 18:
        return 0
    var bytes = text.as_bytes()
    var value = 0
    for i in range(n):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return 0
        value = value * 10 + (c - ord("0"))
    return value


def ws_message_request(
    path: String,
    channel: String,
    slot: Int,
    opcode: Int,
    payload: Span[Byte, _],
) raises -> HTTPRequest:
    """One inbound WebSocket message, shaped as a request a WSGI app can serve.

    `POST <path>` with the message as the raw body and three headers naming
    what HTTP has no room for:

        M0-Channel: <name>     the channel this socket joined
        M0-Slot: <n>           which connection it is, for a targeted reply
        M0-Opcode: <n>         1 for text, 2 for binary (RFC 6455 §5.2)

    The content type follows the opcode — `text/plain; charset=utf-8` for a
    text message, `application/octet-stream` otherwise — so a Django view
    reads `request.body` and gets the payload back byte-for-byte. Neither
    type triggers form parsing, which would consume the body and hand back a
    `QueryDict` instead.

    `slot_id` is deliberately left at its default of -1. This is a synthetic
    request, not a connection: a hold instruction in its response would
    subscribe nothing, and the caller must not treat it as one. The socket
    the message came from is already held, and `M0-Slot` names it.
    """
    var content_type = String("application/octet-stream")
    if opcode == 1:
        content_type = String("text/plain; charset=utf-8")
    var headers = Headers(
        Header(HeaderKey.CONTENT_TYPE, content_type),
        Header(CHANNEL_HEADER, channel),
        Header(SLOT_HEADER, String(slot)),
        Header(OPCODE_HEADER, String(opcode)),
    )
    return HTTPRequest(
        URI.parse(path),
        headers=headers^,
        method=String("POST"),
        body=Bytes(payload),
    )
