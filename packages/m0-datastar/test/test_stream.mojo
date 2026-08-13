"""Tests for the Datastar server glue: DatastarStream and read_signals."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI
from lightbug_http.io.bytes import Bytes

from src.stream import DatastarStream
from src.signals import read_signals, EMPTY_SIGNALS


def _text(buf: List[UInt8]) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _get(path: String) raises -> HTTPRequest:
    var req = HTTPRequest(URI.parse("http://localhost:8080" + path), method="GET")
    req.slot_id = 0
    return req^


# --- The bug this whole module exists to fix ---------------------------------

def test_frames_are_not_double_framed() raises:
    """A Datastar frame must reach the wire exactly once, not nested in data:.

    Routing these through SSERegistry.notify() would wrap the complete frame in
    another frame's data: field, and the browser would see one event whose body
    is the literal text of the inner frame.
    """
    var s = DatastarStream(4)
    var req = _get("/events")
    _ = s.open(req, "/events")
    _ = s.patch_signals("/events", '{"count":1}')
    var out = _text(s.drain(0))
    assert_true(out.startswith("event: datastar-patch-signals\n"))
    assert_false(out.find("data: event:") >= 0)
    assert_false(out.find("data: data:") >= 0)
    assert_true(out.endswith("\n\n"))


def test_datastar_field_order_survives() raises:
    """event: must precede id:, per the Datastar SDK spec.

    m0_http's own framer emits id: first, so this is the check that the frame
    was queued verbatim rather than reframed.
    """
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", "{}")
    var out = _text(s.drain(0))
    var ev = out.find("event:")
    var idx = out.find("id:")
    assert_true(ev >= 0 and idx >= 0)
    assert_true(ev < idx)


# --- Lifecycle ---------------------------------------------------------------

def test_open_returns_a_streaming_response() raises:
    """open() marks the response sse_streaming with the right headers."""
    var s = DatastarStream(4)
    var resp = s.open(_get("/e"), "/e")
    assert_equal(resp.status_code, 200)
    assert_true(resp.sse_streaming)
    assert_equal(resp.headers["content-type"], "text/event-stream")
    assert_equal(resp.headers["cache-control"], "no-cache")


def test_open_without_a_slot_is_409() raises:
    """A request with no event-loop slot cannot be held open."""
    var s = DatastarStream(4)
    var req = HTTPRequest(URI.parse("http://localhost:8080/e"), method="GET")
    req.slot_id = -1
    var resp = s.open(req, "/e")
    assert_equal(resp.status_code, 409)
    assert_false(resp.sse_streaming)


def test_is_streaming_tracks_open_and_closed() raises:
    """The HTTPService hooks see the slot appear and disappear."""
    var s = DatastarStream(4)
    assert_false(s.is_streaming(0))
    _ = s.open(_get("/e"), "/e")
    assert_true(s.is_streaming(0))
    s.closed(0)
    assert_false(s.is_streaming(0))


def test_closed_slot_stops_receiving() raises:
    """A disconnected client is not queued for."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    s.closed(0)
    _ = s.patch_signals("/e", "{}")
    assert_equal(len(s.drain(0)), 0)


# --- Broadcast ---------------------------------------------------------------

def test_event_ids_increment_and_are_returned() raises:
    """Each broadcast assigns and returns the next id."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    assert_equal(s.patch_signals("/e", "{}"), 1)
    assert_equal(s.patch_elements("/e", "<p>x</p>"), 2)
    assert_equal(s.execute_script("/e", "void 0"), 3)
    assert_equal(s.redirect_to("/e", "/done"), 4)


def test_ids_appear_in_the_frames() raises:
    """The assigned id is the one written to the wire."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", "{}")
    assert_true(_text(s.drain(0)).find("id: 1\n") >= 0)


def test_patch_elements_carries_selector_and_mode() raises:
    """Non-default selector and mode reach the datalines."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_elements("/e", "<li>x</li>", selector="#list", mode="append")
    var out = _text(s.drain(0))
    assert_true(out.find("data: selector #list") >= 0)
    assert_true(out.find("data: mode append") >= 0)


def test_broadcast_is_url_scoped() raises:
    """Subscribers only get events for the URL they opened."""
    var s = DatastarStream(4)
    var a = _get("/a")
    var b = HTTPRequest(URI.parse("http://localhost:8080/b"), method="GET")
    b.slot_id = 1
    _ = s.open(a, "/a")
    _ = s.open(b, "/b")
    _ = s.patch_signals("/a", '{"x":1}')
    assert_true(len(s.drain(0)) > 0)
    assert_equal(len(s.drain(1)), 0)


def test_redirect_carries_an_event_id() raises:
    """redirect() forwards its id like every other builder."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.redirect_to("/e", "/next")
    var out = _text(s.drain(0))
    assert_true(out.find("id: 1\n") >= 0)
    assert_true(out.find("window.location") >= 0)


def test_send_frame_is_verbatim() raises:
    """The escape hatch writes exactly what it is given."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.send_frame("/e", "event: custom\ndata: hi\n\n")
    assert_equal(_text(s.drain(0)), "event: custom\ndata: hi\n\n")


def test_subscriber_introspection() raises:
    """has_subscribers lets a handler skip an expensive render."""
    var s = DatastarStream(4)
    assert_false(s.has_subscribers("/e"))
    _ = s.open(_get("/e"), "/e")
    assert_true(s.has_subscribers("/e"))
    assert_equal(s.subscriber_count("/e"), 1)


# --- read_signals ------------------------------------------------------------

def test_read_signals_from_get_query() raises:
    """GET carries signals in the datastar query parameter."""
    var req = HTTPRequest(
        URI.parse('http://localhost:8080/inc?datastar=%7B%22count%22%3A5%7D'),
        method="GET",
    )
    assert_equal(read_signals(req), '{"count":5}')


def test_read_signals_from_body() raises:
    """Non-GET carries signals in the body."""
    var req = HTTPRequest(
        URI.parse("http://localhost:8080/inc"),
        body=Bytes(String('{"count":7}').as_bytes()),
        method="POST",
    )
    assert_equal(read_signals(req), '{"count":7}')


def test_read_signals_defaults_to_empty_object() raises:
    """A request with no signals yields {} rather than an empty string."""
    assert_equal(read_signals(_get("/inc")), EMPTY_SIGNALS)
    var post = HTTPRequest(URI.parse("http://localhost:8080/inc"), method="POST")
    assert_equal(read_signals(post), EMPTY_SIGNALS)


def test_read_signals_preserves_plus_in_json() raises:
    """An encoded + must survive; the browser sends %2B, not a bare plus."""
    var req = HTTPRequest(
        URI.parse('http://localhost:8080/x?datastar=%7B%22s%22%3A%22a%2Bb%22%7D'),
        method="GET",
    )
    assert_equal(read_signals(req), '{"s":"a+b"}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
