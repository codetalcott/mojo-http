"""The replay journal behind a held stream's `Last-Event-ID` (SPEC I33).

What `ReplayJournal` promises `WSGIHandler._resume`: a client the journal
covers is handed every frame of its channel it missed, in order, and
nothing of any other channel's; one it cannot cover, or cannot fit, is
handed nothing from history and told so by the caller. The floor is one
number for every channel, so eviction anywhere ages every client.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.sse.format import NO_EVENT_ID, format_sse_event_bytes
from src.sse.registry import SSERegistry, MAX_PENDING_BYTES
from src.sse.replay import ReplayJournal


def _frame(event_id: Int, data: String) -> List[UInt8]:
    return format_sse_event_bytes(event_id, "message", data)


def _text(bytes: List[UInt8]) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(bytes)))


def test_replays_the_channels_missed_frames_in_order_and_no_others() raises:
    var journal = ReplayJournal(64)
    journal.record("news", 1, _frame(1, "one"))
    journal.record("other", 2, _frame(2, "not-mine"))
    journal.record("news", 3, _frame(3, "three"))
    journal.record("news", 4, _frame(4, "four"))
    var registry = SSERegistry(4)
    registry.subscribe(0, "news", 1)
    assert_true(journal.catch_up(registry, 0, "news", 1))
    var out = _text(registry.drain(0))
    assert_true(out.find("data: three") >= 0, out)
    assert_true(out.find("data: four") > out.find("data: three"), out)
    assert_false(out.find("data: one") >= 0, "the frame the client has was re-sent")
    assert_false(out.find("not-mine") >= 0, "another channel's frame was replayed")
    # Replay advanced the slot, so the live feed carries on from 4.
    assert_equal(registry.last_event_ids[0], 4)
    assert_equal(journal.entries(), 4)
    assert_equal(journal.head, 4)


def test_a_client_that_missed_nothing_gets_nothing() raises:
    var journal = ReplayJournal(64)
    journal.record("news", 1, _frame(1, "one"))
    var registry = SSERegistry(4)
    registry.subscribe(0, "news", 1)
    assert_true(journal.catch_up(registry, 0, "news", 1))
    assert_false(registry.has_pending(0))


def test_unnumbered_frames_are_not_journaled() raises:
    var journal = ReplayJournal(64)
    journal.record("news", NO_EVENT_ID, _frame(NO_EVENT_ID, "heartbeat-ish"))
    assert_equal(journal.entries(), 0)
    assert_equal(journal.head, 0)
    assert_equal(journal.floor, 0)


def test_eviction_moves_the_floor_so_an_older_client_is_a_gap() raises:
    var journal = ReplayJournal(2)
    journal.record("news", 1, _frame(1, "one"))
    journal.record("news", 2, _frame(2, "two"))
    journal.record("news", 3, _frame(3, "three"))
    assert_equal(journal.entries(), 2)
    assert_equal(journal.floor, 1)
    assert_false(journal.covers(0))
    assert_true(journal.covers(1))
    var registry = SSERegistry(4)
    registry.subscribe(0, "news", 0)
    assert_false(journal.catch_up(registry, 0, "news", 0))
    assert_false(registry.has_pending(0), "a gapped client was served in part")
    # Subscribed still, at the id it presented.
    assert_true(registry.is_slot_streaming(0))
    assert_equal(registry.last_event_ids[0], 0)


def test_eviction_on_a_busy_channel_ages_a_quiet_channels_client() raises:
    """The floor is one number: a quiet channel's client older than it is
    told to fetch rather than tracked per channel (the docstring's
    reason: a channel per visitor would grow such a list for ever)."""
    var journal = ReplayJournal(2)
    journal.record("quiet", 1, _frame(1, "q"))
    journal.record("busy", 2, _frame(2, "b"))
    journal.record("busy", 3, _frame(3, "b"))
    # Frame 1 is evicted, but a client that has it is still covered: 2
    # and 3 are in the journal.
    assert_true(journal.covers(1))
    journal.record("busy", 4, _frame(4, "b"))
    # Now 2 is gone too. Only `busy` lost a frame, and only a per-channel
    # mark could say so; the one floor says the quiet client may have.
    assert_equal(journal.floor, 2)
    assert_false(journal.covers(1))
    var registry = SSERegistry(4)
    registry.subscribe(0, "quiet", 1)
    assert_false(journal.catch_up(registry, 0, "quiet", 1))


def test_no_journal_keeps_nothing_and_every_missed_frame_is_a_gap() raises:
    var journal = ReplayJournal(0)
    journal.record("news", 1, _frame(1, "one"))
    assert_equal(journal.entries(), 0)
    assert_equal(journal.floor, 1)
    assert_false(journal.covers(0))
    assert_true(journal.covers(1), "a client that missed nothing is still covered")


def test_the_first_frame_seen_sets_the_floor_below_it() raises:
    """A loop that joins a running cluster sees, say, 10 first: 1..9 are
    history it never had. A first-generation loop sees 1 and keeps 0."""
    var journal = ReplayJournal(64)
    journal.record("news", 10, _frame(10, "ten"))
    assert_equal(journal.floor, 9)
    assert_false(journal.covers(8))
    assert_true(journal.covers(9))
    var fresh = ReplayJournal(64)
    fresh.record("news", 1, _frame(1, "one"))
    assert_equal(fresh.floor, 0)


def test_start_after_is_the_respawned_workers_floor() raises:
    var journal = ReplayJournal(64)
    journal.start_after(50)
    assert_equal(journal.head, 50)
    assert_false(journal.covers(49))
    assert_true(journal.covers(50))
    # A frame at or below the floor is not owed to anyone it can serve.
    journal.record("news", 50, _frame(50, "fifty"))
    assert_equal(journal.entries(), 0)
    journal.record("news", 51, _frame(51, "fifty-one"))
    assert_equal(journal.entries(), 1)


def test_a_peer_frame_arriving_behind_a_newer_one_is_kept_in_id_order() raises:
    var journal = ReplayJournal(64)
    journal.record("news", 1, _frame(1, "one"))
    journal.record("news", 3, _frame(3, "three"))
    journal.record("news", 2, _frame(2, "two"))
    assert_equal(journal.ids[0], 1)
    assert_equal(journal.ids[1], 2)
    assert_equal(journal.ids[2], 3)
    var registry = SSERegistry(4)
    registry.subscribe(0, "news", 1)
    assert_true(journal.catch_up(registry, 0, "news", 1))
    var out = _text(registry.drain(0))
    assert_true(out.find("data: two") < out.find("data: three"), out)
    assert_equal(registry.last_event_ids[0], 3)


def test_a_catch_up_that_does_not_fit_the_outbox_is_taken_back() raises:
    var journal = ReplayJournal(64)
    var big = String("x") * (MAX_PENDING_BYTES // 2)
    journal.record("news", 1, _frame(1, big))
    journal.record("news", 2, _frame(2, big))
    journal.record("news", 3, _frame(3, big))
    var registry = SSERegistry(4)
    registry.subscribe(0, "news", 0)
    assert_false(journal.catch_up(registry, 0, "news", 0))
    assert_false(registry.has_pending(0), "a partial catch-up was left queued")
    assert_true(registry.is_slot_streaming(0))
    assert_equal(registry.last_event_ids[0], 0)


def test_catch_up_touches_only_the_slot_it_is_given() raises:
    var journal = ReplayJournal(64)
    journal.record("news", 1, _frame(1, "one"))
    journal.record("news", 2, _frame(2, "two"))
    var registry = SSERegistry(4)
    registry.subscribe(0, "news", 0)
    registry.subscribe(1, "news", 2)
    assert_true(journal.catch_up(registry, 0, "news", 0))
    assert_true(registry.has_pending(0))
    assert_false(registry.has_pending(1), "history was re-broadcast")


def test_the_smokes_gap_arm_in_miniature() raises:
    """Four frames of depth, ten published, a client holding 5: 6 is gone."""
    var journal = ReplayJournal(4)
    journal.record("replay", 1, _frame(1, "before"))
    journal.record("replay", 2, _frame(2, "m1"))
    journal.record("replay", 3, _frame(3, "m2"))
    journal.record("elsewhere", 4, _frame(4, "x"))
    journal.record("replay", 5, _frame(5, "live"))
    for i in range(6, 11):
        journal.record("elsewhere", i, _frame(i, "filler"))
    assert_equal(journal.entries(), 4)
    assert_equal(journal.floor, 6)
    assert_false(journal.covers(5))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
