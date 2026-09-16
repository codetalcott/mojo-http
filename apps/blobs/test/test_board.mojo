"""The drop box and the viewer counts on the shared page.

The multi-writer case is exercised by construction rather than by
threads: a claim with no store is exactly what a second writer between
its `fetch_add` and its `store` looks like to the reader.

Run with `uv run poe test-apps`.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from m0_http.multiworker import SharedAtomics, shared_fetch_add

from blobs.board import (
    B_APPLIED,
    B_DROP_BASE,
    B_DROP_HEAD,
    B_LOST,
    Board,
    DROP_SLOTS,
    DropReader,
    board_slots,
    pack_drop,
    packed_seq,
    packed_x,
    packed_y,
)
from blobs.world import MAX_BLOBS, SEED_BLOBS, STAGE, World, keep_out


def _board(workers: Int = 1) raises -> Board:
    var shm = SharedAtomics(board_slots(workers))
    return Board(shm.addr(0))


def test_a_drop_round_trips_its_packing() raises:
    var w = pack_drop(41, 33.3, 150.0)
    assert_equal(packed_seq(w), 41)
    assert_equal(packed_x(w), 33.3)
    assert_equal(packed_y(w), 150.0)
    assert_equal(packed_seq(0), -1)
    # Out of range is clamped to the stage, never wrapped into 16 bits.
    var far = pack_drop(0, -5.0, STAGE * 100.0)
    assert_equal(packed_x(far), 0.0)
    assert_equal(packed_y(far), STAGE)


def test_drops_arrive_in_order() raises:
    var board = _board()
    var world = World()
    var reader = DropReader()
    assert_equal(reader.take(board, world), 0)
    _ = board.post_drop(60.0, 70.0)
    _ = board.post_drop(80.0, 90.0)
    assert_equal(reader.take(board, world), 2)
    assert_equal(world.x[SEED_BLOBS], 60.0)
    assert_equal(world.y[SEED_BLOBS + 1], 90.0)
    assert_equal(board.load(B_APPLIED), 2)
    assert_equal(reader.take(board, world), 0)


def test_a_claim_not_yet_stored_is_waited_for() raises:
    """Head moved, word not written: the reader stops there and resumes."""
    var board = _board()
    var world = World()
    var reader = DropReader()
    _ = board.post_drop(60.0, 60.0)
    # A second writer's claim, with its store still to come.
    var seq = shared_fetch_add(board.addr(B_DROP_HEAD), 1)
    assert_equal(reader.take(board, world), 1)
    assert_equal(reader.take(board, world), 0)
    board.store(B_DROP_BASE + seq % DROP_SLOTS, pack_drop(seq, 100.0, 100.0))
    assert_equal(reader.take(board, world), 1)
    assert_equal(world.x[SEED_BLOBS + 1], 100.0)
    assert_equal(board.load(B_LOST), 0)


def test_a_burst_past_the_ring_loses_the_oldest() raises:
    """More drops than the ring holds between two steps: the newest survive."""
    var board = _board()
    var world = World()
    var reader = DropReader()
    # Whole grid units, which the tenths packing carries exactly, and all
    # inside the keep-out band, so the world stores them unclamped.
    for i in range(DROP_SLOTS + 5):
        _ = board.post_drop(Float64(30 + i), Float64(30))
    assert_equal(reader.take(board, world), DROP_SLOTS)
    assert_equal(board.load(B_LOST), 5)
    # The last drop applied is the last one posted.
    var last = (world.next + MAX_BLOBS - 1) % MAX_BLOBS
    assert_true(keep_out() < 30.0)
    assert_equal(world.x[last], Float64(30 + DROP_SLOTS + 4))


def test_viewers_sum_across_workers() raises:
    var board = _board(3)
    board.set_viewers(0, 2)
    board.set_viewers(2, 5)
    assert_equal(board.viewers(3), 7)
    assert_equal(board.viewers(1), 2)
    board.set_viewers(2, 0)
    assert_equal(board.viewers(3), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
