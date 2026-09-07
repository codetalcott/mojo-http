"""The ring behind the `--blocking-threads` handoff, without the pool.

Single-threaded: order, bounds, wraparound, the disabled ring. Two-threaded:
two producers on their own threads and this thread as the consumer, every
value arriving exactly once and each producer's in its own order — the
property the pool's slot ownership rests on. What is NOT covered here is
the parked-flag protocol around the ring; that is `test_offload.mojo`'s
`_wakes_` tests and, under load, `poe smoke-blocking-threads`.
"""

from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.ring import Ring

from src.threads import (
    ThreadSet, ThreadBlock, BLK_INDEX, BLK_USER, BLK_STATUS, STATUS_OK,
)


def test_values_come_out_in_the_order_they_went_in() raises:
    var ring = Ring(8)
    for i in range(5):
        assert_true(ring.push(i * 10))
    var out = 0
    for i in range(5):
        assert_true(ring.pop(out))
        assert_equal(out, i * 10)
    assert_false(ring.pop(out))


def test_capacity_rounds_up_and_a_full_ring_refuses() raises:
    var ring = Ring(5)
    assert_equal(ring.capacity(), 8)
    for i in range(8):
        assert_true(ring.push(i))
    assert_false(ring.push(99))
    var out = 0
    assert_true(ring.pop(out))
    assert_equal(out, 0)
    # One cell freed: one push fits, the next does not.
    assert_true(ring.push(99))
    assert_false(ring.push(100))


def test_wraps_around_many_times() raises:
    """A four-cell ring carrying a thousand pairs: the sequence numbers
    keep counting past the capacity and the mask keeps landing them."""
    var ring = Ring(4)
    var out = 0
    for i in range(1000):
        assert_true(ring.push(i))
        assert_true(ring.push(i + 100000))
        assert_true(ring.pop(out))
        assert_equal(out, i)
        assert_true(ring.pop(out))
        assert_equal(out, i + 100000)
    assert_true(ring.is_empty())


def test_is_empty_tracks_the_head() raises:
    var ring = Ring(4)
    assert_true(ring.is_empty())
    assert_true(ring.push(1))
    assert_false(ring.is_empty())
    var out = 0
    assert_true(ring.pop(out))
    assert_true(ring.is_empty())


def test_peek_reads_the_head_without_taking_it() raises:
    """The loop's age check looks at the oldest job and leaves it: the
    same value comes back until a pop takes it, and an empty ring peeks
    nothing."""
    var ring = Ring(4)
    var seen = 0
    assert_false(ring.peek(seen))
    assert_true(ring.push(7))
    assert_true(ring.push(8))
    assert_true(ring.peek(seen))
    assert_equal(seen, 7)
    assert_true(ring.peek(seen))
    assert_equal(seen, 7)
    var out = 0
    assert_true(ring.pop(out))
    assert_equal(out, 7)
    assert_true(ring.peek(seen))
    assert_equal(seen, 8)
    assert_true(ring.pop(out))
    assert_false(ring.peek(seen))
    var dead = Ring()
    assert_false(dead.peek(seen))


def test_a_disabled_ring_refuses_everything() raises:
    """`Ring()` is what a lane gets with rings off: both sides read it as
    "datagrams", and nothing here can be pushed, popped or found."""
    var ring = Ring()
    assert_false(ring.enabled())
    assert_equal(ring.capacity(), 0)
    assert_false(ring.push(1))
    var out = 0
    assert_false(ring.pop(out))
    assert_true(ring.is_empty())


def test_a_view_from_two_integers_is_the_same_ring() raises:
    var ring = Ring(4)
    var view = Ring(unsafe_base=ring.base, mask=ring.mask)
    assert_true(ring.push(7))
    var out = 0
    assert_true(view.pop(out))
    assert_equal(out, 7)
    assert_true(ring.is_empty())


comptime _PER_PRODUCER = 20000
comptime _BLK_MASK = 6
"""Spare block slot carrying the ring's mask beside its base in BLK_USER."""


def _producer_body(arg: Int) -> Int:
    var block = ThreadBlock(arg)
    var ring = Ring(unsafe_base=block.get(BLK_USER), mask=block.get(_BLK_MASK))
    var index = block.get(BLK_INDEX)
    for i in range(_PER_PRODUCER):
        # Tagged by producer, so the consumer can check each one's order.
        while not ring.push(index * 1_000_000 + i):
            _ = external_call["sched_yield", c_int]()
    block.set(BLK_STATUS, STATUS_OK)
    return 0


def test_two_producers_one_consumer_every_value_exactly_once() raises:
    var ring = Ring(64)
    var threads = ThreadSet(2)
    for i in range(2):
        threads.block(i).set(BLK_USER, ring.base)
        threads.block(i).set(_BLK_MASK, ring.mask)
    var body = _producer_body
    var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
    for i in range(2):
        threads.spawn(i, body_addr)

    var seen0 = 0
    var seen1 = 0
    var got = 0
    var out = 0
    var idle = 0
    while got < 2 * _PER_PRODUCER:
        if ring.pop(out):
            var who = out // 1_000_000
            var i = out % 1_000_000
            if who == 0:
                assert_equal(i, seen0)
                seen0 += 1
            else:
                assert_equal(who, 1)
                assert_equal(i, seen1)
                seen1 += 1
            got += 1
            idle = 0
        else:
            idle += 1
            if idle > 200_000_000:
                raise Error("consumer starved: producers stopped publishing")
    threads.join_all()
    assert_true(threads.all_ok())
    assert_equal(seen0, _PER_PRODUCER)
    assert_equal(seen1, _PER_PRODUCER)
    assert_true(ring.is_empty())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
