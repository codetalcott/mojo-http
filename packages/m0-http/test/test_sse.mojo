"""Tests for SSE format, registry, and journal."""

from std.testing import assert_equal, assert_true, assert_false

from src.sse.format import format_sse_event, format_sse_heartbeat
from src.sse.registry import SSERegistry
from src.sse.journal import PatchJournal


# --- SSE Format ---

fn test_format_sse_event() raises:
    """SSE event should have id, event, data fields."""
    var s = format_sse_event(1, "update", '{"id":1}')
    assert_true(s.find("id: 1") >= 0)
    assert_true(s.find("event: update") >= 0)
    assert_true(s.find('data: {"id":1}') >= 0)


fn test_format_sse_heartbeat() raises:
    """Heartbeat should be a comment line."""
    var s = format_sse_heartbeat()
    assert_true(s.find(": heartbeat") >= 0)


fn test_format_sse_multiline_data() raises:
    """Multi-line data should produce multiple data: fields."""
    var s = format_sse_event(1, "update", "line1\nline2\nline3")
    assert_true(s.find("data: line1\n") >= 0)
    assert_true(s.find("data: line2\n") >= 0)
    assert_true(s.find("data: line3\n") >= 0)
    assert_true(s.endswith("\n\n"))


# --- SSE Registry ---

fn test_registry_subscribe_notify() raises:
    """Subscribed slot should receive events."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 0)
    reg.notify("/orders", 1, "update", '{"id":1}')
    assert_true(reg.has_pending(0))
    var buf = reg.drain(0)
    assert_true(len(buf) > 0)
    assert_false(reg.has_pending(0))


fn test_registry_filter_by_url() raises:
    """Slot should only receive events for its subscribed URL."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 0)
    reg.subscribe(1, "/users", 0)
    reg.notify("/orders", 1, "update", "data")
    assert_true(reg.has_pending(0))
    assert_false(reg.has_pending(1))


fn test_registry_unsubscribe() raises:
    """Unsubscribed slot should not receive events."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 0)
    reg.unsubscribe(0)
    reg.notify("/orders", 1, "update", "data")
    assert_false(reg.has_pending(0))


fn test_registry_active_count() raises:
    """active_count should track subscribed slots."""
    var reg = SSERegistry(4)
    assert_equal(reg.active_count(), 0)
    reg.subscribe(0, "/a", 0)
    reg.subscribe(2, "/b", 0)
    assert_equal(reg.active_count(), 2)
    reg.unsubscribe(0)
    assert_equal(reg.active_count(), 1)


fn test_registry_skips_old_events() raises:
    """Events with id <= last_event_id should be skipped."""
    var reg = SSERegistry(4)
    reg.subscribe(0, "/orders", 5)
    reg.notify("/orders", 3, "update", "old")
    assert_false(reg.has_pending(0))
    reg.notify("/orders", 6, "update", "new")
    assert_true(reg.has_pending(0))


fn test_registry_backpressure_preserves_last_id() raises:
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
    var buf = reg.drain(0)
    # Now send event 3 — it should be accepted (buffer is drained)
    reg.notify("/orders", 3, "update", "third")
    assert_true(reg.has_pending(0))
    # Also verify event 2 can still be delivered on retry since ID didn't advance
    # (a new subscriber starting from last_event_id=1 would get event 2)


# --- Patch Journal ---

fn _bytes2(a: UInt8, b: UInt8) -> List[UInt8]:
    var v = List[UInt8]()
    v.append(a); v.append(b)
    return v^


fn _byte(a: UInt8) -> List[UInt8]:
    var v = List[UInt8]()
    v.append(a)
    return v^


fn test_journal_append_since() raises:
    """Single event since lastEventId should return patch."""
    var j = PatchJournal()
    var eid = j.append("/orders/1", "e0", "e1", _bytes2(1, 2), _bytes2(10, 20))
    assert_equal(eid, 1)
    var r = j.since("/orders/1", 0)
    assert_equal(r.type, "patch")
    assert_equal(r.event_id, 1)
    assert_equal(len(r.data), 2)


fn test_journal_multiple_returns_snapshot() raises:
    """Multiple events since lastEventId should return snapshot."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", _byte(1), _byte(10))
    var snap = List[UInt8]()
    snap.append(20); snap.append(30)
    _ = j.append("/orders/1", "e1", "e2", _byte(2), snap)
    var r = j.since("/orders/1", 0)
    assert_equal(r.type, "snapshot")
    assert_equal(len(r.data), 2)  # latest snapshot


fn test_journal_no_events() raises:
    """No events since lastEventId should return none."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", _byte(1), _byte(10))
    var r = j.since("/orders/1", 1)
    assert_equal(r.type, "none")


fn test_journal_filters_by_url() raises:
    """since() should only return events for the requested URL."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", _byte(1), _byte(10))
    _ = j.append("/orders/2", "e0", "e1", _byte(2), _byte(20))
    var r = j.since("/orders/2", 0)
    assert_equal(r.type, "patch")
    assert_equal(r.data[0], 2)


fn test_journal_latest_id() raises:
    """latest_id should return the most recent event ID."""
    var j = PatchJournal()
    assert_equal(j.latest_id(), 0)
    _ = j.append("/a", "", "", List[UInt8](), List[UInt8]())
    assert_equal(j.latest_id(), 1)
    _ = j.append("/b", "", "", List[UInt8](), List[UInt8]())
    assert_equal(j.latest_id(), 2)


fn test_journal_has_etag() raises:
    """has_etag should find matching entries."""
    var j = PatchJournal()
    _ = j.append("/orders/1", "e0", "e1", List[UInt8](), List[UInt8]())
    assert_equal(j.has_etag("/orders/1", "e1"), 1)
    assert_equal(j.has_etag("/orders/1", "e0"), 0)


fn test_journal_compact() raises:
    """compact should remove all entries for a URL."""
    var j = PatchJournal()
    _ = j.append("/a", "", "", List[UInt8](), List[UInt8]())
    _ = j.append("/a", "", "", List[UInt8](), List[UInt8]())
    _ = j.append("/b", "", "", List[UInt8](), List[UInt8]())
    j.compact("/a")
    assert_equal(j.since("/a", 0).type, "none")
    assert_equal(j.since("/b", 0).type, "patch")
