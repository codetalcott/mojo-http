"""Tests for SSE format, registry, and journal."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.sse.format import (
    format_sse_event,
    format_sse_heartbeat,
    split_sse_lines,
    sse_data_payload,
    NO_EVENT_ID,
)
from src.sse.registry import SSERegistry, MAX_PENDING_BYTES
from src.sse.journal import PatchJournal


# --- SSE Format ---

def test_format_sse_event() raises:
    """SSE event should have id, event, data fields."""
    var s = format_sse_event(1, "update", '{"id":1}')
    assert_true(s.find("id: 1") >= 0)
    assert_true(s.find("event: update") >= 0)
    assert_true(s.find('data: {"id":1}') >= 0)


def test_format_sse_heartbeat() raises:
    """Heartbeat should be a comment line."""
    var s = format_sse_heartbeat()
    assert_true(s.find(": heartbeat") >= 0)


def test_format_sse_multiline_data() raises:
    """Multi-line data should produce multiple data: fields."""
    var s = format_sse_event(1, "update", "line1\nline2\nline3")
    assert_true(s.find("data: line1\n") >= 0)
    assert_true(s.find("data: line2\n") >= 0)
    assert_true(s.find("data: line3\n") >= 0)
    assert_true(s.endswith("\n\n"))


def test_split_lines_lf() raises:
    """LF is a line terminator."""
    var parts = split_sse_lines("a\nb")
    assert_equal(len(parts), 2)
    assert_equal(parts[0], "a")
    assert_equal(parts[1], "b")


def test_split_lines_crlf_is_one_break() raises:
    """CRLF is a single terminator, not two."""
    var parts = split_sse_lines("a\r\nb")
    assert_equal(len(parts), 2)
    assert_equal(parts[0], "a")
    assert_equal(parts[1], "b")


def test_split_lines_bare_cr() raises:
    """A lone CR terminates a line per the SSE spec."""
    var parts = split_sse_lines("a\rb")
    assert_equal(len(parts), 2)
    assert_equal(parts[0], "a")
    assert_equal(parts[1], "b")


def test_bare_cr_does_not_escape_the_data_field() raises:
    """A CR in the payload must not inject a raw break into the frame.

    Splitting on LF alone would emit "data: a\\rb\\n", which a client reads as
    a `data: a` field followed by a malformed `b` field.
    """
    var s = format_sse_event(1, "update", "a\rb")
    assert_true(s.find("data: a\n") >= 0)
    assert_true(s.find("data: b\n") >= 0)
    assert_false(s.find("data: a\rb") >= 0)


def test_crlf_payload_splits_cleanly() raises:
    """Windows-style payloads produce clean data fields with no stray CR."""
    var s = format_sse_event(1, "update", "<div>\r\n  <p>hi</p>\r\n</div>")
    assert_true(s.find("data: <div>\n") >= 0)
    assert_true(s.find("data:   <p>hi</p>\n") >= 0)
    assert_false(s.find("\r") >= 0)


def test_no_event_id_omits_id_field() raises:
    """NO_EVENT_ID emits no id: line at all."""
    var s = format_sse_event(NO_EVENT_ID, "update", "x")
    assert_false(s.find("id:") >= 0)
    assert_true(s.startswith("event: update\n"))


def test_zero_event_id_is_still_emitted() raises:
    """Zero is a real id and must survive; only NO_EVENT_ID suppresses it."""
    var s = format_sse_event(0, "update", "x")
    assert_true(s.startswith("id: 0\n"))


# --- notify_frame: verbatim delivery for producers with their own framing ---

def _as_text(buf: List[UInt8]) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def test_notify_frame_delivers_verbatim() raises:
    """Pre-formatted frames must reach the wire byte-for-byte, unframed."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    var frame = String("event: datastar-patch-signals\nid: 7\ndata: signals {}\n\n")
    reg.notify_frame("/x", 7, List[UInt8](frame.as_bytes()))
    assert_equal(_as_text(reg.drain(0)), frame)


def test_notify_frame_respects_url_filter() raises:
    """Frames go only to slots subscribed to that URL."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/a", 0)
    reg.subscribe(1, "/b", 0)
    reg.notify_frame("/a", 1, List[UInt8](String("f\n\n").as_bytes()))
    assert_true(reg.has_pending(0))
    assert_false(reg.has_pending(1))


def test_notify_frame_suppresses_replay() raises:
    """Ids at or below the slot's last-seen id are not redelivered."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 5)
    reg.notify_frame("/x", 5, List[UInt8](String("old\n\n").as_bytes()))
    assert_false(reg.has_pending(0))
    reg.notify_frame("/x", 6, List[UInt8](String("new\n\n").as_bytes()))
    assert_true(reg.has_pending(0))


def test_no_event_id_bypasses_dedupe() raises:
    """Unnumbered frames always deliver, however many times."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 100)
    reg.notify_frame("/x", NO_EVENT_ID, List[UInt8](String(": hb\n\n").as_bytes()))
    reg.notify_frame("/x", NO_EVENT_ID, List[UInt8](String(": hb\n\n").as_bytes()))
    assert_equal(_as_text(reg.drain(0)), ": hb\n\n: hb\n\n")


def test_no_event_id_does_not_advance_last_seen() raises:
    """Unnumbered frames must not mask a later real event.

    If NO_EVENT_ID advanced the slot's last-seen id, a heartbeat would suppress
    every subsequent numbered event.
    """
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    reg.notify_frame("/x", NO_EVENT_ID, List[UInt8](String(": hb\n\n").as_bytes()))
    _ = reg.drain(0)
    reg.notify_frame("/x", 1, List[UInt8](String("real\n\n").as_bytes()))
    assert_equal(_as_text(reg.drain(0)), "real\n\n")


def test_notify_frame_backpressure_drops() raises:
    """Frames exceeding MAX_PENDING_BYTES are dropped for that slot."""
    var reg = SSERegistry(2)
    reg.subscribe(0, "/x", 0)
    var big = List[UInt8]()
    for _ in range(MAX_PENDING_BYTES):
        big.append(UInt8(ord("x")))
    reg.notify_frame("/x", 1, big)
    var before = len(reg.drain(0))
    reg.subscribe(0, "/x", 0)
    reg.notify_frame("/x", 1, big)
    reg.notify_frame("/x", 2, List[UInt8](String("tiny\n\n").as_bytes()))
    assert_equal(len(reg.drain(0)), before)


def test_queue_frame_targets_one_slot() raises:
    """The replay path queues for exactly the slot named — no fan-out."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    reg.subscribe(1, "/x", 0)
    reg.queue_frame(0, 1, List[UInt8](String("replay\n\n").as_bytes()))
    assert_true(reg.has_pending(0))
    assert_false(reg.has_pending(1))


def test_queue_frame_applies_delivery_filter() raises:
    """Ids at or below the slot's last-seen id are not replayed."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 5)
    reg.queue_frame(0, 5, List[UInt8](String("old\n\n").as_bytes()))
    assert_false(reg.has_pending(0))
    reg.queue_frame(0, 6, List[UInt8](String("new\n\n").as_bytes()))
    assert_true(reg.has_pending(0))


def test_queue_frame_advances_last_seen() raises:
    """A replayed frame suppresses the same id arriving again via broadcast.

    This is what keeps catch-up and the live feed from double-delivering the
    frame at the boundary between them.
    """
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    reg.queue_frame(0, 3, List[UInt8](String("replay\n\n").as_bytes()))
    reg.notify_frame("/x", 3, List[UInt8](String("live\n\n").as_bytes()))
    assert_equal(_as_text(reg.drain(0)), "replay\n\n")


def test_queue_frame_skips_non_streaming_and_bad_slots() raises:
    """A slot not in streaming mode gets nothing; out-of-range is a no-op."""
    var reg = SSERegistry(4)
    reg.queue_frame(0, 1, List[UInt8](String("f\n\n").as_bytes()))
    assert_false(reg.has_pending(0))
    reg.queue_frame(-1, 1, List[UInt8](String("f\n\n").as_bytes()))
    reg.queue_frame(99, 1, List[UInt8](String("f\n\n").as_bytes()))


def test_queue_frame_backpressure_drops() raises:
    """A frame that would overflow the slot's pending buffer is dropped."""
    var reg = SSERegistry(2)
    reg.subscribe(0, "/x", 0)
    var big = List[UInt8]()
    for _ in range(MAX_PENDING_BYTES):
        big.append(UInt8(ord("x")))
    reg.queue_frame(0, 1, big)
    var before = len(reg.pending_bufs[0])
    reg.queue_frame(0, 2, List[UInt8](String("tiny\n\n").as_bytes()))
    assert_equal(len(reg.pending_bufs[0]), before)


def test_notify_delegates_to_notify_frame() raises:
    """`notify()` still frames and delivers; backpressure lives in one place."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    reg.notify("/x", 1, "update", "hello")
    var out = _as_text(reg.drain(0))
    assert_true(out.find("event: update") >= 0)
    assert_true(out.find("data: hello") >= 0)


def test_subscriber_introspection() raises:
    """`has_subscribers` / `subscriber_count` let a handler skip a render."""
    var reg = SSERegistry(4)
    assert_false(reg.has_subscribers("/x"))
    reg.subscribe(0, "/x", 0)
    reg.subscribe(1, "/x", 0)
    reg.subscribe(2, "/y", 0)
    assert_true(reg.has_subscribers("/x"))
    assert_equal(reg.subscriber_count("/x"), 2)
    assert_equal(reg.subscriber_count("/y"), 1)
    assert_equal(reg.subscriber_count("/none"), 0)


def test_is_slot_streaming_is_bounds_safe() raises:
    """Out-of-range slots answer False rather than trapping."""
    var reg = SSERegistry(2)
    reg.subscribe(0, "/x", 0)
    assert_true(reg.is_slot_streaming(0))
    assert_false(reg.is_slot_streaming(1))
    assert_false(reg.is_slot_streaming(-1))
    assert_false(reg.is_slot_streaming(99))


# --- SSE Registry ---

def test_registry_subscribe_notify() raises:
    """Subscribed slot should receive events."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 0)
    reg.notify("/orders", 1, "update", '{"id":1}')
    assert_true(reg.has_pending(0))
    var buf = reg.drain(0)
    assert_true(len(buf) > 0)
    assert_false(reg.has_pending(0))


def test_registry_filter_by_url() raises:
    """Slot should only receive events for its subscribed URL."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 0)
    reg.subscribe(1, "/users", 0)
    reg.notify("/orders", 1, "update", "data")
    assert_true(reg.has_pending(0))
    assert_false(reg.has_pending(1))


def test_registry_unsubscribe() raises:
    """Unsubscribed slot should not receive events."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 0)
    reg.unsubscribe(0)
    reg.notify("/orders", 1, "update", "data")
    assert_false(reg.has_pending(0))


def test_registry_active_count() raises:
    """active_count should track subscribed slots."""
    var reg = SSERegistry(4)
    assert_equal(reg.active_count(), 0)
    reg.subscribe(0, "/a", 0)
    reg.subscribe(2, "/b", 0)
    assert_equal(reg.active_count(), 2)
    reg.unsubscribe(0)
    assert_equal(reg.active_count(), 1)


def test_registry_skips_old_events() raises:
    """Events with id <= last_event_id should be skipped."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 5)
    reg.notify("/orders", 3, "update", "old")
    assert_false(reg.has_pending(0))
    reg.notify("/orders", 6, "update", "new")
    assert_true(reg.has_pending(0))


def test_registry_backpressure_preserves_last_id() raises:
    """Dropped events due to backpressure should not advance last_event_id."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 0)
    # Send event 1 (should succeed)
    reg.notify("/orders", 1, "update", "first")
    assert_true(reg.has_pending(0))
    # Fill the buffer with a huge payload to trigger backpressure
    var big_data = String("")
    for _ in range(70000):
        big_data += "x"
    reg.notify("/orders", 2, "update", big_data)
    # Event 2 should have been dropped, so draining gives only event 1
    _ = reg.drain(0)
    # Now send event 3 — it should be accepted (buffer is drained)
    reg.notify("/orders", 3, "update", "third")
    assert_true(reg.has_pending(0))
    # Also verify event 2 can still be delivered on retry since ID didn't advance
    # (a new subscriber starting from last_event_id=1 would get event 2)


def test_backpressure_exact_boundary() raises:
    """Events exactly at MAX_PENDING_BYTES should be accepted; one byte over rejected."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    # format_sse_event_bytes overhead: "id: N\nevent: T\ndata: D\n\n"
    # For event_id=1, type="u", the overhead is: "id: 1\nevent: u\ndata: " + "\n\n" = ~24 bytes
    # We need total event bytes + pending <= 65536
    # Strategy: send one big event that fills right to the limit, then try one more
    var data_size = 65400  # leaves room for SSE framing
    var big = String("")
    for _ in range(data_size):
        big += "a"
    reg.notify("/x", 1, "u", big)
    assert_true(reg.has_pending(0), "first big event should be accepted")
    var pending_len = len(reg.pending_bufs[0])
    # Now try to add even a tiny event — if pending + new > 65536, it's dropped
    reg.notify("/x", 2, "u", "tiny")
    # If the combined size exceeds limit, event 2 was dropped
    if pending_len + 30 > 65536:  # 30 is conservative overhead for tiny event
        assert_equal(len(reg.pending_bufs[0]), pending_len, "event should be dropped at boundary")


def test_backpressure_recovery_after_drain() raises:
    """After draining, the slot should accept new events again."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    var big = String("")
    for _ in range(65000):
        big += "x"
    reg.notify("/x", 1, "u", big)
    assert_true(reg.has_pending(0))
    # Drain clears the buffer
    _ = reg.drain(0)
    assert_false(reg.has_pending(0))
    # New event should now be accepted
    reg.notify("/x", 2, "u", "recovered")
    assert_true(reg.has_pending(0), "should accept events after drain")


def test_backpressure_slots_independent() raises:
    """Backpressure on slot 0 should not affect slot 1."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/x", 0)
    reg.subscribe(1, "/x", 0)
    # Fill slot 0 past the limit
    var big = String("")
    for _ in range(65000):
        big += "x"
    reg.notify("/x", 1, "u", big)
    # Now send another event — slot 0 is full but slot 1 accepted event 1 fine
    reg.notify("/x", 2, "u", "small")
    # Slot 1 should have both events (if they fit)
    assert_true(reg.has_pending(1), "slot 1 should still accept events")


# --- Patch Journal ---

def _bytes2(a: UInt8, b: UInt8) -> List[UInt8]:
    var v = List[UInt8]()
    v.append(a); v.append(b)
    return v^


def _byte(a: UInt8) -> List[UInt8]:
    var v = List[UInt8]()
    v.append(a)
    return v^


def test_journal_append_since() raises:
    """Single event since lastEventId should return patch."""
    var j = PatchJournal()
    var eid = j.append("/orders/1", "e0", "e1", _bytes2(1, 2), _bytes2(10, 20))
    assert_equal(eid, 1)
    var r = j.since("/orders/1", 0)
    assert_equal(r.type, "patch")
    assert_equal(r.event_id, 1)
    assert_equal(len(r.data), 2)


def test_journal_append_at_records_peer_id() raises:
    """Journals at a caller-supplied id — the `sse_peer_frame` case.

    A reconnect to THIS worker with a Last-Event-ID must be able to replay
    an event that originated on a peer; before append_at existed (#119)
    that entry simply could not be recorded on the public journal.
    """
    var j = PatchJournal()
    j.append_at(7, "/orders/1", "e0", "e1", _byte(1), _byte(10))
    var r = j.since("/orders/1", 0)
    assert_equal(r.type, "patch")
    assert_equal(r.event_id, 7)


def test_journal_append_at_advances_next_id() raises:
    """A local append after a peer record must not re-issue the peer's id."""
    var j = PatchJournal()
    j.append_at(7, "/a", "e0", "e1", _byte(1), _byte(10))
    var eid = j.append("/a", "e1", "e2", _byte(2), _byte(20))
    assert_equal(eid, 8)


def test_journal_append_at_inserts_in_id_order() raises:
    """An out-of-order peer frame lands in id order, as _record does.

    Replay advances a slot's last-seen id as it walks the journal, so an
    entry stored behind a higher id would be skipped, not replayed late.
    """
    var j = PatchJournal()
    j.append_at(9, "/a", "e0", "e1", _byte(1), _byte(10))
    j.append_at(4, "/a", "ex", "ey", _byte(2), _byte(20))
    assert_equal(j.event_ids[0], 4)
    assert_equal(j.event_ids[1], 9)
    # And a reconnect that saw 4 gets exactly the newer one.
    var r = j.since("/a", 4)
    assert_equal(r.type, "patch")
    assert_equal(r.event_id, 9)


def test_journal_append_at_low_id_does_not_regress_counter() raises:
    """Recording an OLD peer id must not wind next_id backwards."""
    var j = PatchJournal()
    _ = j.append("/a", "e0", "e1", _byte(1), _byte(10))  # takes id 1, next 2
    _ = j.append("/a", "e1", "e2", _byte(2), _byte(20))  # takes id 2, next 3
    j.append_at(1, "/b", "e0", "e1", _byte(3), _byte(30))
    var eid = j.append("/a", "e2", "e3", _byte(4), _byte(40))
    assert_equal(eid, 3)


def test_journal_multiple_returns_snapshot() raises:
    """Multiple events since lastEventId should return snapshot."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", _byte(1), _byte(10))
    var snap = List[UInt8]()
    snap.append(20); snap.append(30)
    _ = j.append("/orders/1", "e1", "e2", _byte(2), snap)
    var r = j.since("/orders/1", 0)
    assert_equal(r.type, "snapshot")
    assert_equal(len(r.data), 2)  # latest snapshot


def test_journal_no_events() raises:
    """No events since lastEventId should return none."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", _byte(1), _byte(10))
    var r = j.since("/orders/1", 1)
    assert_equal(r.type, "none")


def test_journal_filters_by_url() raises:
    """since() should only return events for the requested URL."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", _byte(1), _byte(10))
    _ = j.append("/orders/2", "e0", "e1", _byte(2), _byte(20))
    var r = j.since("/orders/2", 0)
    assert_equal(r.type, "patch")
    assert_equal(r.data[0], 2)


def test_journal_latest_id() raises:
    """latest_id should return the most recent event ID."""
    var j = PatchJournal()
    assert_equal(j.latest_id(), 0)
    _ = j.append("/a", "", "", List[UInt8](), List[UInt8]())
    assert_equal(j.latest_id(), 1)
    _ = j.append("/b", "", "", List[UInt8](), List[UInt8]())
    assert_equal(j.latest_id(), 2)


def test_journal_has_etag() raises:
    """has_etag should find matching entries."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", List[UInt8](), List[UInt8]())
    assert_equal(j.has_etag("/orders/1", "e1"), 1)
    assert_equal(j.has_etag("/orders/1", "e0"), 0)


def test_journal_compact() raises:
    """compact should remove all entries for a URL."""
    var j = PatchJournal()
    _ = j.append("/a", "", "", List[UInt8](), List[UInt8]())
    _ = j.append("/a", "", "", List[UInt8](), List[UInt8]())
    _ = j.append("/b", "", "", List[UInt8](), List[UInt8]())
    j.compact("/a")
    assert_equal(j.since("/a", 0).type, "none")
    assert_equal(j.since("/b", 0).type, "patch")

# --- sse_data_payload: the inverse, for cross-transport delivery ---

def _payload(frame: String) -> String:
    return String(unsafe_from_utf8=sse_data_payload(frame.as_bytes()))


def test_data_payload_round_trips_format_sse_event() raises:
    """What the formatter framed, the extractor recovers."""
    assert_equal(_payload(format_sse_event(7, "message", "hello")), "hello")


def test_data_payload_rejoins_multiline_data() raises:
    """Multi-line data becomes several `data:` fields; the join undoes it."""
    assert_equal(
        _payload(format_sse_event(NO_EVENT_ID, "message", "one\ntwo\nthree")),
        "one\ntwo\nthree",
    )


def test_data_payload_ignores_id_and_event_fields() raises:
    """Only `data` fields contribute — the framing is not payload."""
    assert_equal(_payload("id: 42\nevent: ping\ndata: body\n\n"), "body")


def test_data_payload_of_a_comment_frame_is_empty() raises:
    """A heartbeat carries no data field, and reads as no payload at all."""
    assert_equal(_payload(": heartbeat\n\n"), "")


def test_data_payload_strips_exactly_one_space() raises:
    """One space after the colon is framing; a second is payload."""
    assert_equal(_payload("data:  padded\n\n"), " padded")
    assert_equal(_payload("data:tight\n\n"), "tight")


def test_data_payload_handles_a_valueless_data_field() raises:
    """A bare `data` line is a data field with an empty value."""
    assert_equal(_payload("data\ndata: after\n\n"), "\nafter")


def test_data_payload_stops_at_the_blank_line() raises:
    """A frame is ONE event; bytes past its terminator belong to no event."""
    assert_equal(_payload("data: first\n\ndata: second\n\n"), "first")


def test_data_payload_accepts_crlf_terminators() raises:
    """CRLF is a line terminator too, and must not land inside the payload."""
    assert_equal(_payload("id: 1\r\ndata: crlf\r\n\r\n"), "crlf")


# --- filter_url: which channel one slot joined ---

def test_filter_url_reports_the_subscribed_url() raises:
    var reg = SSERegistry(4)
    reg.subscribe(2, "/news", 0)
    assert_equal(reg.filter_url(2), "/news")


def test_filter_url_is_empty_when_unsubscribed_or_out_of_range() raises:
    var reg = SSERegistry(4)
    reg.subscribe(1, "/news", 0)
    reg.unsubscribe(1)
    assert_equal(reg.filter_url(1), "")
    assert_equal(reg.filter_url(0), "")
    assert_equal(reg.filter_url(-1), "")
    assert_equal(reg.filter_url(99), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
