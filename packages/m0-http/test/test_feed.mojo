"""`Feed`: a stream whose event ids are the application's.

Each test is one of the module's rules, with subscribers on raw slots as
the loop would place them; the frames are plain SSE text, since the feed
reads nothing in them.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.http import HTTPRequest
from lightbug_http.uri import URI

from src.feed import Feed, since_of, FEED_SLOT_BUDGET


def _text(buf: List[UInt8]) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(buf)))


def _open(path: String, slot: Int, last_id: String = "") raises -> HTTPRequest:
    var req = HTTPRequest(URI.parse("http://localhost:8080" + path), method="GET")
    req.slot_id = slot
    if last_id.byte_length() > 0:
        req.headers["last-event-id"] = last_id
    return req^


def _frame(id: Int, body: String) -> String:
    return "event: rows\nid: " + String(id) + "\ndata: " + body + "\n\n"


def _pad(n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += "x"
    return out^


def test_open_places_a_subscriber_where_it_says_it_stands() raises:
    """`Last-Event-ID` first, then `?since=`, else 0; and not a number is a 400.

    covers: N51
    """
    var f = Feed(4)
    var resp = f.open(_open("/events?since=7", 0), "notes")
    assert_equal(resp.status_code, 200)
    assert_true(resp.sse_streaming)
    assert_equal(f.at(0), 7)
    assert_equal(f.key(0), "notes")
    _ = f.open(_open("/events?since=7", 1, last_id="12"), "notes")
    assert_equal(f.at(1), 12)
    _ = f.open(_open("/events", 2), "notes")
    assert_equal(f.at(2), 0)
    assert_equal(f.subscribers("notes"), 3)
    assert_true(f.lagging())
    for bad in [String("-1"), String("01"), String("x"), String("1.5")]:
        var r = f.open(_open("/events?since=" + bad, 3), "notes")
        assert_equal(r.status_code, 400)
        assert_false(f.is_streaming(3))
    var r = f.open(_open("/events", -1), "notes")
    assert_equal(r.status_code, 409)
    assert_false(r.sse_streaming)


def test_behind_names_the_slots_below_the_head() raises:
    var f = Feed(4)
    _ = f.open(_open("/e?since=5", 0), "a")
    _ = f.open(_open("/e?since=9", 1), "a")
    _ = f.open(_open("/e?since=9", 2), "b")
    var behind = f.behind(9)
    assert_equal(len(behind), 1)
    assert_equal(behind[0], 0)
    assert_false(f.lagging())
    assert_equal(len(f.behind(12)), 3)
    f.closed(1)
    assert_equal(len(f.behind(12)), 2)
    # Above the head is not at the head: a client of another incarnation
    # is named too, for the application's resync.
    _ = f.open(_open("/e?since=500", 3), "a")
    var ahead = f.behind(9)
    assert_equal(len(ahead), 2)
    assert_true(f.send(3, 9, _frame(9, "resync")))
    assert_equal(f.at(3), 9)
    assert_equal(len(f.behind(9)), 1)


def test_send_moves_a_subscriber_to_the_deltas_head() raises:
    var f = Feed(4)
    _ = f.open(_open("/e?since=5", 0), "a")
    assert_true(f.send(0, 8, _frame(8, "rows 6 to 8")))
    assert_equal(f.at(0), 8)
    assert_equal(_text(f.drain(0)), _frame(8, "rows 6 to 8"))
    assert_equal(len(f.behind(8)), 0)
    assert_equal(f.sent, 1)
    # The application's word is where it stands, down as well as up.
    assert_true(f.send(0, 3, _frame(3, "resync")))
    assert_equal(f.at(0), 3)
    # Not streaming: nothing taken.
    assert_false(f.send(1, 9, "x"))


def test_a_delta_is_taken_whole_or_not_at_all() raises:
    """A slot with nothing pending takes a delta of any size; one with bytes
    pending takes a delta only if it fits beside them, else stays where it
    stands and is asked for again -- a merged delta, never a cut one.

    covers: N51
    """
    var f = Feed(4)
    _ = f.open(_open("/e?since=0", 0), "a")
    var big = _frame(10, _pad(FEED_SLOT_BUDGET * 2))
    assert_true(f.send(0, 10, big))
    assert_equal(f.at(0), 10)
    # Undrained, a second delta that does not fit beside it is refused.
    assert_false(f.send(0, 11, _frame(11, "more")))
    assert_equal(f.at(0), 10)
    assert_equal(f.refused, 1)
    assert_true(f.lagging())
    # Left out of `behind` while nothing has drained, and still lagging.
    assert_equal(len(f.behind(11)), 0)
    assert_true(f.lagging())
    # A small one beside the big one fits, though: the budget is for what
    # is pending plus the new delta.
    _ = f.drain(0)
    assert_equal(len(f.behind(11)), 1)
    assert_true(f.send(0, 11, _frame(11, "small")))
    assert_true(f.send(0, 12, _frame(12, "small too")))
    assert_equal(f.at(0), 12)
    var out = _text(f.drain(0))
    assert_true(out.find("id: 11") >= 0 and out.find("id: 12") >= 0)
    # Drained, the refused subscriber takes the merged delta from where it stood.
    _ = f.open(_open("/e?since=0", 1), "a")
    assert_true(f.send(1, 10, big))
    assert_false(f.send(1, 12, _frame(12, "x")))
    # Until something drains, `behind` leaves the refused slot out, so the
    # application renders nothing for it; `lagging` stays true.
    assert_equal(len(f.behind(12)), 0)
    assert_true(f.lagging())
    _ = f.drain(1)
    assert_equal(len(f.behind(12)), 1)
    assert_true(f.send(1, 12, _frame(12, "10 to 12, merged")))
    assert_equal(f.at(1), 12)
    assert_false(f.lagging() and len(f.behind(12)) > 0)


def test_skip_moves_a_subscriber_without_a_frame() raises:
    var f = Feed(4)
    _ = f.open(_open("/e?since=5", 0), "a")
    f.skip(0, 9)
    assert_equal(f.at(0), 9)
    assert_equal(len(f.drain(0)), 0)
    assert_equal(len(f.behind(9)), 0)
    f.skip(0, 4)
    assert_equal(f.at(0), 4)


def test_a_closed_slot_is_forgotten() raises:
    var f = Feed(4)
    _ = f.open(_open("/e?since=5", 0), "a")
    assert_true(f.is_streaming(0))
    f.closed(0)
    assert_false(f.is_streaming(0))
    assert_equal(f.subscribers("a"), 0)
    assert_false(f.send(0, 9, "x"))
    assert_equal(len(f.drain(0)), 0)


def test_open_clears_what_a_slot_held_before() raises:
    """A view that raised after `open` left a subscription nobody drained;
    the next client on that slot must not be sent its bytes."""
    var f = Feed(4)
    _ = f.open(_open("/e?since=0", 0), "a")
    assert_true(f.send(0, 3, _frame(3, "stale")))
    _ = f.open(_open("/e?since=9", 0), "a")
    assert_equal(len(f.drain(0)), 0)
    assert_equal(f.at(0), 9)


def test_since_of_reads_the_header_before_the_query() raises:
    assert_equal(since_of(_open("/e?since=3", 0, last_id="9")), 9)
    assert_equal(since_of(_open("/e?since=3", 0)), 3)
    assert_equal(since_of(_open("/e", 0)), 0)
    assert_equal(since_of(_open("/e?since=0", 0)), 0)
    assert_equal(since_of(_open("/e", 0, last_id="junk")), -1)
    assert_equal(since_of(_open("/e?since=007", 0)), -1)
    assert_equal(since_of(_open("/e?since=1234567890123456789", 0)), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
