"""Tests for the stream-hold detection.

Deliberately no interpreter here, same charter as `test_environ`:
`take_stream_hold` operates on an already-built `HTTPResponse`, so every
branch is reachable with plain Mojo values.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http import Header, Headers, HTTPResponse

from src.hold import take_stream_hold


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
    """Only `stream` is understood; anything else serves normally."""
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
