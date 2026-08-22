"""Tests for hold detection and the WebSocket message seam.

Deliberately no interpreter here, same charter as `test_environ`: every
function under test operates on already-built `HTTPRequest`/`HTTPResponse`
values, so every branch is reachable with plain Mojo values. What is NOT
reachable here is what the handler does with the answer — performing the
101, subscribing the slot — which is `smoke-django-realtime-ws`'s job.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http import Header, Headers, HTTPRequest, HTTPResponse
from lightbug_http.uri import URI

from src.hold import (
    take_hold,
    take_stream_hold,
    request_last_event_id,
    ws_message_request,
    HOLD_NONE,
    HOLD_STREAM,
    HOLD_WEBSOCKET,
)


def _response(var headers: Headers, body: String = "", status_code: Int = 200) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=headers^,
        status_code=status_code,
        status_text=String("OK"),
    )


def test_no_hold_headers_is_untouched() raises:
    """An ordinary response passes through with nothing consumed."""
    var resp = _response(Headers(Header("content-type", "text/html")), body="hi")
    var hold = take_stream_hold(resp)
    assert_false(hold.held)
    assert_false(resp.sse_streaming)
    assert_equal(resp.headers["content-type"], "text/html")
    assert_equal(String(resp.get_body()), "hi")


def test_full_hold_converts_to_sse() raises:
    """Hold headers vanish, the flag is set, and the type becomes SSE."""
    var resp = _response(
        Headers(
            Header("content-type", "text/html"),
            Header("m0-hold", "stream"),
            Header("m0-channel", "news"),
        )
    )
    var hold = take_stream_hold(resp)
    assert_true(hold.held)
    assert_equal(hold.channel, "news")
    assert_true(resp.sse_streaming)
    assert_false("m0-hold" in resp.headers)
    assert_false("m0-channel" in resp.headers)
    assert_equal(resp.headers["content-type"], "text/event-stream")
    assert_equal(resp.headers["cache-control"], "no-cache")
    assert_equal(resp.headers["x-accel-buffering"], "no")


def test_empty_body_becomes_open_comment() raises:
    """An empty held body is substituted so the stream opens promptly."""
    var resp = _response(
        Headers(Header("m0-hold", "stream"), Header("m0-channel", "news"))
    )
    _ = take_stream_hold(resp)
    assert_equal(String(resp.get_body()), ": open\n\n")


def test_application_body_leads_the_stream() raises:
    """A non-empty body is the head of the stream, kept verbatim."""
    var resp = _response(
        Headers(Header("m0-hold", "stream"), Header("m0-channel", "news")),
        body=": connected\n\n",
    )
    var hold = take_stream_hold(resp)
    assert_true(hold.held)
    assert_equal(String(resp.get_body()), ": connected\n\n")


def test_hold_value_is_case_insensitive() raises:
    """`M0-Hold: Stream` holds; header values keep whatever case Django sent."""
    var resp = _response(
        Headers(Header("m0-hold", "Stream"), Header("m0-channel", "news"))
    )
    var hold = take_stream_hold(resp)
    assert_true(hold.held)


def test_missing_channel_degrades_to_plain_response() raises:
    """A hold without a channel serves normally — headers still stripped."""
    var resp = _response(
        Headers(Header("content-type", "text/html"), Header("m0-hold", "stream")),
        body="hi",
    )
    var hold = take_stream_hold(resp)
    assert_false(hold.held)
    assert_false(resp.sse_streaming)
    assert_false("m0-hold" in resp.headers)
    assert_equal(resp.headers["content-type"], "text/html")
    assert_equal(String(resp.get_body()), "hi")


def test_unknown_hold_mode_degrades() raises:
    """`stream` and `websocket` are the modes; anything else serves normally."""
    var resp = _response(
        Headers(Header("m0-hold", "response"), Header("m0-channel", "news"))
    )
    var hold = take_stream_hold(resp)
    assert_false(hold.held)
    assert_false(resp.sse_streaming)
    assert_false("m0-hold" in resp.headers)
    assert_false("m0-channel" in resp.headers)


def test_non_200_degrades() raises:
    """A 403 with hold headers is a refusal, not a subscription."""
    var resp = _response(
        Headers(Header("m0-hold", "stream"), Header("m0-channel", "news")),
        body="forbidden",
        status_code=403,
    )
    var hold = take_stream_hold(resp)
    assert_false(hold.held)
    assert_false(resp.sse_streaming)
    assert_false("m0-hold" in resp.headers)
    assert_equal(String(resp.get_body()), "forbidden")


# --- WebSocket holds ---------------------------------------------------------


def test_websocket_hold_is_reported_without_rewriting() raises:
    """A websocket hold names a channel and leaves the response alone.

    The caller discards it and answers `websocket_upgrade(req)` instead —
    only the decision (approved, this channel) survives.
    """
    var resp = _response(
        Headers(
            Header("content-type", "text/plain"),
            Header("m0-hold", "websocket"),
            Header("m0-channel", "room"),
        ),
        body="ignored",
    )
    var hold = take_hold(resp)
    assert_true(hold.held)
    assert_equal(hold.mode, HOLD_WEBSOCKET)
    assert_equal(hold.channel, "room")
    assert_false(resp.sse_streaming)
    assert_false("m0-hold" in resp.headers)
    assert_false("m0-channel" in resp.headers)
    assert_equal(resp.headers["content-type"], "text/plain")
    assert_equal(String(resp.get_body()), "ignored")


def test_websocket_hold_value_is_case_insensitive() raises:
    var resp = _response(
        Headers(Header("m0-hold", "WebSocket"), Header("m0-channel", "room"))
    )
    assert_equal(take_hold(resp).mode, HOLD_WEBSOCKET)


def test_websocket_hold_without_channel_degrades() raises:
    """No channel, nothing to join — and the headers still go."""
    var resp = _response(Headers(Header("m0-hold", "websocket")), body="hi")
    var hold = take_hold(resp)
    assert_false(hold.held)
    assert_equal(hold.mode, HOLD_NONE)
    assert_false("m0-hold" in resp.headers)
    assert_equal(String(resp.get_body()), "hi")


def test_websocket_hold_on_a_refusal_degrades() raises:
    """A 403 carrying the headers is a refusal: no upgrade, served as-is."""
    var resp = _response(
        Headers(Header("m0-hold", "websocket"), Header("m0-channel", "room")),
        body="forbidden",
        status_code=403,
    )
    var hold = take_hold(resp)
    assert_false(hold.held)
    assert_false("m0-hold" in resp.headers)
    assert_equal(String(resp.get_body()), "forbidden")


def test_take_hold_reports_stream_mode_too() raises:
    """One function, both modes — `mode` is the full answer."""
    var resp = _response(
        Headers(Header("m0-hold", "stream"), Header("m0-channel", "news"))
    )
    var hold = take_hold(resp)
    assert_equal(hold.mode, HOLD_STREAM)
    assert_true(resp.sse_streaming)


def test_stream_only_handler_degrades_a_websocket_hold() raises:
    """`take_stream_hold` must not leave a client waiting for an upgrade it
    cannot perform — but the instruction headers still never reach it."""
    var resp = _response(
        Headers(
            Header("content-type", "text/plain"),
            Header("m0-hold", "websocket"),
            Header("m0-channel", "room"),
        ),
        body="hi",
    )
    var hold = take_stream_hold(resp)
    assert_false(hold.held)
    assert_equal(hold.mode, HOLD_NONE)
    assert_false(resp.sse_streaming)
    assert_false("m0-hold" in resp.headers)
    assert_false("m0-channel" in resp.headers)
    assert_equal(String(resp.get_body()), "hi")


# --- Last-Event-ID -----------------------------------------------------------


def _request_with(var headers: Headers) raises -> HTTPRequest:
    return HTTPRequest(URI.parse(String("/events")), headers=headers^)


def test_last_event_id_absent_is_zero() raises:
    """A first connection has seen nothing, and says so by saying nothing."""
    assert_equal(request_last_event_id(_request_with(Headers())), 0)


def test_last_event_id_is_parsed() raises:
    assert_equal(
        request_last_event_id(_request_with(Headers(Header("last-event-id", "12")))),
        12,
    )


def test_last_event_id_tolerates_surrounding_space() raises:
    assert_equal(
        request_last_event_id(_request_with(Headers(Header("last-event-id", " 7 ")))),
        7,
    )


def test_last_event_id_zero_is_zero() raises:
    """`id: 0` is a legal id; it just happens to mean the same as absent."""
    assert_equal(
        request_last_event_id(_request_with(Headers(Header("last-event-id", "0")))),
        0,
    )


def test_last_event_id_non_numeric_is_zero() raises:
    """The spec allows any string; ours are numbers, so anything else names
    no event of ours and is treated as absent rather than guessed at."""
    for bad in ["abc", "", "12a", "-3", "1.5", "999999999999999999999"]:
        assert_equal(
            request_last_event_id(
                _request_with(Headers(Header("last-event-id", bad)))
            ),
            0,
        )


# --- Synthetic WebSocket message requests ------------------------------------


def test_ws_message_request_shape() raises:
    """A text message becomes a POST whose body is the payload verbatim."""
    var payload = String("hello room").as_bytes()
    var req = ws_message_request("/ws/message", "room", 4, 1, payload)
    assert_equal(req.method, "POST")
    assert_equal(req.uri.path, "/ws/message")
    assert_equal(String(req.get_body()), "hello room")
    assert_equal(req.headers["m0-channel"], "room")
    assert_equal(req.headers["m0-slot"], "4")
    assert_equal(req.headers["m0-opcode"], "1")
    assert_equal(req.headers["content-type"], "text/plain; charset=utf-8")
    assert_equal(req.headers["content-length"], "10")


def test_ws_message_request_binary_content_type() raises:
    """A binary message must not be typed as text; nothing decodes it."""
    var req = ws_message_request("/ws/message", "room", 0, 2, String("\x00\xff").as_bytes())
    assert_equal(req.headers["content-type"], "application/octet-stream")
    assert_equal(req.headers["m0-opcode"], "2")


def test_ws_message_request_is_not_a_connection() raises:
    """A synthetic request is not a connection, so `slot_id` stays -1: a
    hold instruction in the reply must subscribe nothing. The socket it came
    from is already held, and M0-Slot names it."""
    var req = ws_message_request("/ws/message", "room", 9, 1, String("x").as_bytes())
    assert_equal(req.slot_id, -1)
    assert_equal(req.headers["m0-slot"], "9")


def test_ws_message_request_accepts_an_empty_payload() raises:
    """An empty text frame is legal on the wire and must survive the trip."""
    var req = ws_message_request("/ws/message", "room", 1, 1, String("").as_bytes())
    assert_equal(String(req.get_body()), "")
    assert_equal(req.headers["content-length"], "0")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
