"""`SlotQueues`: the FIFO queues a full loop takes a slot back from (SPEC C23).

The loop's use of them is `test_slot_lifecycle.mojo`'s; these hold the
structure to its own promises -- first in, first at the front; a slot in at
most one queue, moved to the back of whichever it joins; a removal from
anywhere in a queue that leaves the rest linked in order; and indices out of
range ignored rather than trusted.
"""

from std.testing import TestSuite, assert_equal

from lightbug_http.slot_queue import NO_SLOT, SlotQueues


def _order(q: SlotQueues, queue: Int) -> List[Int]:
    """The slots in `queue`, front to back, by following the links forward
    -- and checked backward, so a broken `prev` link fails too."""
    var forward = List[Int]()
    var s = q.front(queue)
    var last = NO_SLOT
    while s != NO_SLOT:
        forward.append(s)
        last = s
        s = q.next[s]
    var back = List[Int]()
    s = last
    while s != NO_SLOT:
        back.append(s)
        s = q.prev[s]
    var n = len(forward)
    for i in range(n):
        if back[n - 1 - i] != forward[i]:
            return [-99]
    return forward^


def test_a_queue_is_first_in_first_at_the_front() raises:
    var q = SlotQueues(8, 2)
    assert_equal(q.front(0), NO_SLOT)
    assert_equal(q.count(0), 0)
    for s in [5, 2, 7]:
        q.push_back(0, s)
    assert_equal(_order(q, 0), [5, 2, 7])
    assert_equal(q.front(0), 5)
    assert_equal(q.queue(2), 0)
    assert_equal(q.queue(3), NO_SLOT)
    assert_equal(q.count(0), 3)
    assert_equal(q.front(1), NO_SLOT)


def test_a_slot_that_joins_again_waits_from_the_back() raises:
    """Joining a queue the slot is already in moves it to the back: a
    connection idle again after its next request has been idle for no time."""
    var q = SlotQueues(8, 2)
    for s in [1, 2, 3]:
        q.push_back(0, s)
    q.push_back(0, 1)
    assert_equal(_order(q, 0), [2, 3, 1])
    q.push_back(0, 1)
    assert_equal(_order(q, 0), [2, 3, 1], "the back moved off the back")


def test_a_slot_is_in_one_queue_at_a_time() raises:
    """Joining another queue leaves the first: a head that starts on a
    kept-alive connection is no longer between requests."""
    var q = SlotQueues(8, 2)
    for s in [1, 2, 3]:
        q.push_back(0, s)
    q.push_back(1, 2)
    assert_equal(_order(q, 0), [1, 3])
    assert_equal(_order(q, 1), [2])
    assert_equal(q.queue(2), 1)
    q.push_back(0, 2)
    assert_equal(_order(q, 0), [1, 3, 2])
    assert_equal(_order(q, 1), List[Int]())


def test_a_removal_from_anywhere_keeps_the_rest_in_order() raises:
    var q = SlotQueues(8, 1)
    for s in [0, 1, 2, 3, 4]:
        q.push_back(0, s)
    q.remove(2)
    assert_equal(_order(q, 0), [0, 1, 3, 4], "the middle")
    q.remove(0)
    assert_equal(_order(q, 0), [1, 3, 4], "the front")
    q.remove(4)
    assert_equal(_order(q, 0), [1, 3], "the back")
    q.remove(4)
    assert_equal(_order(q, 0), [1, 3], "a slot in no queue")
    q.remove(1)
    q.remove(3)
    assert_equal(q.front(0), NO_SLOT)
    assert_equal(q.count(0), 0)
    q.push_back(0, 3)
    assert_equal(_order(q, 0), [3], "an emptied queue takes a slot again")
    assert_equal(q.queue(1), NO_SLOT)


def test_an_index_out_of_range_is_ignored() raises:
    var q = SlotQueues(4, 2)
    q.push_back(0, 4)
    q.push_back(0, -1)
    q.push_back(2, 1)
    q.push_back(-1, 1)
    assert_equal(q.front(0), NO_SLOT)
    assert_equal(q.front(2), NO_SLOT)
    assert_equal(q.queue(9), NO_SLOT)
    q.remove(9)
    q.remove(-3)
    q.push_back(1, 3)
    assert_equal(_order(q, 1), [3])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
