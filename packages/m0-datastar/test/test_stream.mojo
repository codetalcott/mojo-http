"""Tests for the Datastar server glue: DatastarStream and read_signals."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.broadcast import BroadcastBus, drain_bus_channel
from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI
from lightbug_http.io.bytes import Bytes

from m0_http.multiworker import SharedAtomics

from src.stream import DatastarStream
from src.signals import read_signals, EMPTY_SIGNALS


def _text(buf: List[UInt8]) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(buf)))


def _get(path: String) raises -> HTTPRequest:
    var req = HTTPRequest(URI.parse("http://localhost:8080" + path), method="GET")
    req.slot_id = 0
    return req^


def _reconnect(path: String, last_id: String) raises -> HTTPRequest:
    """A reconnecting client: same GET, plus the Last-Event-ID it saw last."""
    var req = _get(path)
    req.headers["last-event-id"] = last_id
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
    """`event:` must precede `id:`, per the Datastar SDK spec.

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
    """`open()` marks the response sse_streaming with the right headers."""
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
    """`redirect()` forwards its id like every other builder."""
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
    """`has_subscribers` lets a handler skip an expensive render."""
    var s = DatastarStream(4)
    assert_false(s.has_subscribers("/e"))
    _ = s.open(_get("/e"), "/e")
    assert_true(s.has_subscribers("/e"))
    assert_equal(s.subscriber_count("/e"), 1)


# --- Replay ------------------------------------------------------------------

def test_reconnect_replays_missed_frames() raises:
    """A Last-Event-ID reconnection is caught up from the journal.

    The client presents id 1, so it must receive events 2 and 3 — and not 1.
    """
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", '{"a":1}')
    _ = s.patch_signals("/e", '{"b":2}')
    _ = s.patch_signals("/e", '{"c":3}')
    _ = s.drain(0)
    s.closed(0)
    _ = s.open(_reconnect("/e", "1"), "/e")
    var out = _text(s.drain(0))
    assert_false(out.find('{"a":1}') >= 0)
    assert_true(out.find('{"b":2}') >= 0)
    assert_true(out.find('{"c":3}') >= 0)


def test_no_header_means_no_replay() raises:
    """A first-time consumer starts from the live feed, not from history."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", '{"old":1}')
    _ = s.drain(0)
    s.closed(0)
    _ = s.open(_get("/e"), "/e")
    assert_equal(len(s.drain(0)), 0)


def test_replayed_frame_is_not_redelivered_live() raises:
    """Catch-up advances the slot's last-seen id past what it replayed."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", '{"a":1}')
    _ = s.drain(0)
    s.closed(0)
    _ = s.open(_reconnect("/e", "0"), "/e")
    var replayed = _text(s.drain(0))
    assert_true(replayed.find('{"a":1}') >= 0)
    _ = s.patch_signals("/e", '{"b":2}')
    var live = _text(s.drain(0))
    assert_false(live.find('{"a":1}') >= 0)
    assert_true(live.find('{"b":2}') >= 0)


def test_replay_is_url_scoped() raises:
    """The journal replays only frames for the URL being opened."""
    var s = DatastarStream(4)
    var a = _get("/a")
    var b = HTTPRequest(URI.parse("http://localhost:8080/b"), method="GET")
    b.slot_id = 1
    _ = s.open(a, "/a")
    _ = s.open(b, "/b")
    _ = s.patch_signals("/a", '{"a":1}')
    _ = s.patch_signals("/b", '{"b":1}')
    _ = s.drain(0)
    _ = s.drain(1)
    s.closed(0)
    _ = s.open(_reconnect("/a", "0"), "/a")
    var out = _text(s.drain(0))
    assert_true(out.find('{"a":1}') >= 0)
    assert_false(out.find('{"b":1}') >= 0)


def test_id_ahead_of_counter_is_clamped() raises:
    """An id from an unknown incarnation must not mute the live feed.

    Without the clamp, a process that does not restore a journal would
    subscribe the client at an id above everything it will ever send.
    """
    var s = DatastarStream(4)
    _ = s.open(_reconnect("/e", "999"), "/e")
    _ = s.patch_signals("/e", '{"live":1}')
    assert_true(_text(s.drain(0)).find('{"live":1}') >= 0)


def test_malformed_last_event_id_replays_all() raises:
    """An id we cannot parse carries no position — replay from the start."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", '{"a":1}')
    _ = s.drain(0)
    s.closed(0)
    _ = s.open(_reconnect("/e", "not-a-number"), "/e")
    assert_true(_text(s.drain(0)).find('{"a":1}') >= 0)


def test_restore_seeds_the_journal_and_counter() raises:
    """Boot-time restore makes a prior process's frames replayable.

    This is the restart half: a fresh stream fed persisted rows must serve a
    reconnection exactly as the old process would have, and continue numbering
    where it left off.
    """
    var s = DatastarStream(4)
    s.restore("/e", 1, List[UInt8](String("event: one\n\n").as_bytes()))
    s.restore("/e", 2, List[UInt8](String("event: two\n\n").as_bytes()))
    _ = s.open(_reconnect("/e", "1"), "/e")
    var out = _text(s.drain(0))
    assert_false(out.find("event: one") >= 0)
    assert_true(out.find("event: two") >= 0)
    assert_equal(s.patch_signals("/e", "{}"), 3)


def test_journal_evicts_beyond_cap() raises:
    """The journal keeps the newest `journal_entries` frames, no more."""
    var s = DatastarStream(4, journal_entries=2)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", '{"a":1}')
    _ = s.patch_signals("/e", '{"b":2}')
    _ = s.patch_signals("/e", '{"c":3}')
    _ = s.drain(0)
    s.closed(0)
    _ = s.open(_reconnect("/e", "0"), "/e")
    var out = _text(s.drain(0))
    assert_false(out.find('{"a":1}') >= 0)
    assert_true(out.find('{"b":2}') >= 0)
    assert_true(out.find('{"c":3}') >= 0)


def test_zero_journal_disables_replay() raises:
    """`journal_entries=0` records nothing; reconnections just resume live."""
    var s = DatastarStream(4, journal_entries=0)
    _ = s.open(_get("/e"), "/e")
    _ = s.patch_signals("/e", '{"a":1}')
    _ = s.drain(0)
    s.closed(0)
    _ = s.open(_reconnect("/e", "0"), "/e")
    assert_equal(len(s.drain(0)), 0)


# --- A stream of states: the newest frame at open, never a replay ------------

def _frame(name: String, id: Int) -> List[UInt8]:
    return List[UInt8](
        String("event: datastar-patch-signals\nid: ", id, "\ndata: signals {\"", name, "\":1}\n\n").as_bytes()
    )


def test_state_stream_sends_the_newest_frame_at_open() raises:
    """A subscriber arriving mid-stream gets the newest state, and only it.

    Frames reach this stream the way a producer thread's do: over the bus,
    through `deliver_peer`, with nobody subscribed. A new client — no
    `Last-Event-ID` — is sent frame 3 at open, not 1 and 2, and not
    nothing. The control is the default stream fed the same frames, which
    sends nothing at open: that blank is what `send_latest` exists to fill.

    covers: I24
    """
    var s = DatastarStream(4, journal_entries=0, send_latest=True)
    var plain = DatastarStream(4, journal_entries=0)
    for i in range(1, 4):
        s.deliver_peer("/e", i, _frame(String("s", i), i))
        plain.deliver_peer("/e", i, _frame(String("s", i), i))
    _ = s.open(_get("/e"), "/e")
    var out = _text(s.drain(0))
    assert_true(out.find('"s3"') >= 0)
    assert_false(out.find('"s1"') >= 0)
    assert_false(out.find('"s2"') >= 0)
    assert_equal(out.count("event: "), 1)

    _ = plain.open(_get("/e"), "/e")
    assert_equal(len(plain.drain(0)), 0)

    # Then the live feed, from the next frame on.
    s.deliver_peer("/e", 4, _frame("s4", 4))
    assert_true(_text(s.drain(0)).find('"s4"') >= 0)


def test_state_stream_ignores_the_presented_id() raises:
    """A reconnect gets the newest state whatever id it presents.

    Behind (1), level with the newest (3), and from an earlier incarnation
    far ahead (5000): each is sent frame 3 exactly once and nothing older.
    The last is the case that matters — a producer's ids restart with its
    process, and comparing would park the tab until the new ids passed the
    old ones.

    covers: I24
    """
    var s = DatastarStream(4, journal_entries=16, send_latest=True)
    for i in range(1, 4):
        s.deliver_peer("/e", i, _frame(String("s", i), i))
    for presented in [String("1"), String("3"), String("5000"), String("junk")]:
        _ = s.open(_reconnect("/e", presented), "/e")
        var out = _text(s.drain(0))
        assert_true(out.find('"s3"') >= 0)
        assert_equal(out.count("event: "), 1)
        s.closed(0)


def test_state_stream_keeps_the_newest_by_id() raises:
    """A frame older than the one kept neither replaces it nor goes out.

    Across workers the bus is best-effort about order, so frame 2 can land
    after frame 3. The kept state stays 3, and a live subscriber who has 3
    is not sent 2. Local broadcasts are kept too, and per url.

    covers: I24
    """
    var s = DatastarStream(4, journal_entries=0, send_latest=True)
    s.deliver_peer("/e", 3, _frame("s3", 3))
    s.deliver_peer("/e", 2, _frame("s2", 2))
    _ = s.open(_get("/e"), "/e")
    var out = _text(s.drain(0))
    assert_true(out.find('"s3"') >= 0)
    assert_false(out.find('"s2"') >= 0)
    s.deliver_peer("/e", 1, _frame("s1", 1))
    assert_equal(len(s.drain(0)), 0)

    var eid = s.patch_signals("/other", '{"o":1}')
    var r = _get("/other")
    r.slot_id = 1
    _ = s.open(r, "/other")
    var other = _text(s.drain(1))
    assert_true(other.find('{"o":1}') >= 0)
    assert_true(other.find(String("id: ", eid)) >= 0)
    assert_false(other.find('"s3"') >= 0)


def test_state_stream_never_replays_the_journal() raises:
    """With a journal kept for `frame_for`, open still sends one frame."""
    var s = DatastarStream(4, journal_entries=16, send_latest=True)
    _ = s.patch_signals("/e", '{"a":1}')
    _ = s.patch_signals("/e", '{"b":2}')
    _ = s.open(_reconnect("/e", "0"), "/e")
    var out = _text(s.drain(0))
    assert_false(out.find('{"a":1}') >= 0)
    assert_true(out.find('{"b":2}') >= 0)
    assert_equal(out.count("event: "), 1)
    # The journal still recorded both, for `frame_for`.
    assert_true(_text(s.frame_for(1)).find('{"a":1}') >= 0)


def test_frame_for_returns_journaled_bytes() raises:
    """`frame_for` hands back exactly what went out — the persistence hook."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    var eid = s.send_frame("/e", "event: custom\ndata: hi\n\n")
    assert_equal(_text(s.frame_for(eid)), "event: custom\ndata: hi\n\n")
    assert_equal(len(s.frame_for(999)), 0)


# --- Cross-worker fan-out ----------------------------------------------------
#
# Two DatastarStreams standing in for two workers, joined by one bus and one
# shared id slot — all in this process, which is exactly the same wiring the
# forked workers get (fds and mmap pages are inherited; nothing else differs).

def test_bus_broadcast_reaches_the_peer_worker() raises:
    var bus = BroadcastBus(2)
    var shm = SharedAtomics(1)
    var a = DatastarStream(4)
    var b = DatastarStream(4)
    a.enable_bus(bus, 0, shm.addr(0))
    b.enable_bus(bus, 1, shm.addr(0))
    _ = b.open(_get("/e"), "/e")

    _ = a.patch_signals("/e", '{"x":1}')
    # what the event loop does on bus readiness, inlined:
    var arrived = drain_bus_channel(bus.read_fd(1))
    assert_equal(len(arrived), 1)
    b.deliver_peer(arrived[0].url, arrived[0].event_id, arrived[0].frame)
    var out = _text(b.drain(0))
    assert_true(out.find('{"x":1}') >= 0)
    assert_true(out.find("id: 1\n") >= 0)


def test_shared_ids_never_collide_across_workers() raises:
    """Interleaved broadcasts on two workers must allocate distinct ids —
    colliding ids would make the redelivery filter drop real frames."""
    var bus = BroadcastBus(2)
    var shm = SharedAtomics(1)
    var a = DatastarStream(4)
    var b = DatastarStream(4)
    a.enable_bus(bus, 0, shm.addr(0))
    b.enable_bus(bus, 1, shm.addr(0))
    assert_equal(a.patch_signals("/e", "{}"), 1)
    assert_equal(b.patch_signals("/e", "{}"), 2)
    assert_equal(a.patch_signals("/e", "{}"), 3)


def test_peer_frames_are_replayable() raises:
    """A frame that arrived over the bus must serve a later reconnection —
    replay has to work no matter which worker a client reconnects to."""
    var b = DatastarStream(4)
    b.deliver_peer("/e", 1, List[UInt8](String("event: one\nid: 1\n\n").as_bytes()))
    b.deliver_peer("/e", 2, List[UInt8](String("event: two\nid: 2\n\n").as_bytes()))
    _ = b.open(_reconnect("/e", "1"), "/e")
    var out = _text(b.drain(0))
    assert_false(out.find("event: one") >= 0)
    assert_true(out.find("event: two") >= 0)


def test_out_of_order_peer_frame_still_replays() raises:
    """The journal inserts by id, so a peer frame that arrived late does not
    get skipped when replay walks the journal in order."""
    var b = DatastarStream(4)
    b.deliver_peer("/e", 3, List[UInt8](String("event: three\n\n").as_bytes()))
    b.deliver_peer("/e", 2, List[UInt8](String("event: two\n\n").as_bytes()))
    _ = b.open(_reconnect("/e", "1"), "/e")
    var out = _text(b.drain(0))
    assert_true(out.find("event: two") >= 0)
    assert_true(out.find("event: three") >= 0)
    assert_true(out.find("event: two") < out.find("event: three"))


def test_unbussed_stream_publishes_nothing() raises:
    """A stream that never joined a bus must not try to write anywhere."""
    var bus = BroadcastBus(2)
    var a = DatastarStream(4)
    _ = a.open(_get("/e"), "/e")
    _ = a.patch_signals("/e", "{}")
    assert_equal(len(drain_bus_channel(bus.read_fd(0))), 0)
    assert_equal(len(drain_bus_channel(bus.read_fd(1))), 0)


def test_enable_bus_seeds_shared_counter_from_restored_journal() raises:
    """A worker that restored a persisted journal pushes its high-water mark
    into the shared counter, keeping post-restart ids monotonic."""
    var bus = BroadcastBus(2)
    var shm = SharedAtomics(1)
    var a = DatastarStream(4)
    a.restore("/e", 41, List[UInt8](String("event: old\n\n").as_bytes()))
    a.enable_bus(bus, 0, shm.addr(0))
    assert_equal(shm.load(0), 41)
    assert_equal(a.patch_signals("/e", "{}"), 42)


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



def test_read_signals_from_delete_query() raises:
    """DELETE carries signals in the query, as GET does; the rest in the body.

    The SDK's `ReadSignals` table says so, and so does the client: the
    1.0.4 bundle sends a body only when the method is neither GET nor
    DELETE. Read from the body, a DELETE's signals came back as `{}`.

    covers: I28
    """
    var gone = HTTPRequest(
        URI.parse("http://localhost:8080/todo/3?datastar=%7B%22x%22%3A1%7D"),
        method="DELETE",
    )
    assert_equal(read_signals(gone), '{"x":1}')
    var lower = HTTPRequest(
        URI.parse("http://localhost:8080/todo/3?datastar=%7B%7D"), method="delete"
    )
    assert_equal(read_signals(lower), "{}")
    # A DELETE's body is not where signals travel, even when one is sent.
    var bodied = HTTPRequest(
        URI.parse("http://localhost:8080/todo/3"),
        body=Bytes(String('{"x":2}').as_bytes()),
        method="DELETE",
    )
    assert_equal(read_signals(bodied), EMPTY_SIGNALS)
    for method in [String("PUT"), String("PATCH"), String("QUERY")]:
        var req = HTTPRequest(
            URI.parse("http://localhost:8080/x?datastar=%7B%7D"),
            body=Bytes(String('{"b":1}').as_bytes()),
            method=method,
        )
        assert_equal(read_signals(req), '{"b":1}')


def test_execute_script_passes_its_options_through() raises:
    """`DatastarStream.execute_script` takes the builder's options."""
    var s = DatastarStream(4)
    _ = s.open(_get("/e"), "/e")
    var attrs = List[String]()
    attrs.append('type="module"')
    _ = s.execute_script("/e", "go()", auto_remove=False, attributes=attrs)
    assert_true(_text(s.drain(0)).find('<script type="module">go()</script>') >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
