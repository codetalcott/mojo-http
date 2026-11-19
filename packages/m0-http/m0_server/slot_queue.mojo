"""FIFO queues over a loop's slots, each slot in at most one of them.

A loop that runs out of slots takes one back from a connection a deadline
is already counting down (SPEC C23, `loop/accept.mojo`'s `_reclaim_slot`),
the one nearest its end first, and finding it must not cost a walk over
every slot while new connections wait. So the slots that may be taken
queue in the order they became takeable: between requests, from the moment
a response ends, and with a head still arriving, from the moment its first
byte did. The front of each queue is the longest waiting.

The links are intrusive, one `prev`/`next` pair per slot shared by every
queue, which is what makes each operation O(1): a slot moves to the back
of a queue by being unlinked from wherever it is and linked at the tail.
The queues do not know what makes a slot takeable; a slot whose state has
moved on stays where it was until the caller meets it at a front and
removes it (`loop/accept.mojo`), so only the transitions INTO a queue and
the slot's close touch them.

`push_back` and `remove` run twice on every kept-alive request (its head
starts, its response ends), and their `@always_inline` is load-bearing: a
`mut self` of 256 B or less is copied in and stored back at a call
boundary (docs/notes/mut-arguments-and-raw-addresses.md), and this struct's
five lists are 120 B. Called, the two moves cost the health path 1.5% of
its throughput under `wrk` (232.5k against 229.4k requests a second, five
runs each); inlined into the loop's own functions, which hold the state by
reference, they cost nothing measurable (231.9k against 231.5k).

Imports nothing, so it is tested alone (`test_slot_queue.mojo`).
"""

comptime NO_SLOT = -1
"""What `front` answers for an empty queue, and a link to nothing."""


struct SlotQueues(Movable):
    """Intrusive FIFO queues over `slots` slot indices."""

    var prev: List[Int]
    var next: List[Int]
    var queue_of: List[Int]
    """The queue each slot is in, `NO_SLOT` for none."""
    var heads: List[Int]
    var tails: List[Int]

    def __init__(out self, slots: Int, queues: Int):
        self.prev = List[Int](capacity=slots)
        self.next = List[Int](capacity=slots)
        self.queue_of = List[Int](capacity=slots)
        for _ in range(slots):
            self.prev.append(NO_SLOT)
            self.next.append(NO_SLOT)
            self.queue_of.append(NO_SLOT)
        self.heads = List[Int](capacity=queues)
        self.tails = List[Int](capacity=queues)
        for _ in range(queues):
            self.heads.append(NO_SLOT)
            self.tails.append(NO_SLOT)

    @always_inline
    def push_back(mut self, queue: Int, slot: Int):
        """Put `slot` at the back of `queue`, leaving whatever queue it was in,
        that one included: a slot that becomes takeable again waits from now."""
        if slot < 0 or slot >= len(self.queue_of) or queue < 0 or queue >= len(self.heads):
            return
        self.remove(slot)
        var tail = self.tails[queue]
        self.prev[slot] = tail
        self.next[slot] = NO_SLOT
        if tail == NO_SLOT:
            self.heads[queue] = slot
        else:
            self.next[tail] = slot
        self.tails[queue] = slot
        self.queue_of[slot] = queue

    @always_inline
    def remove(mut self, slot: Int):
        """Take `slot` out of its queue; nothing when it is in none."""
        if slot < 0 or slot >= len(self.queue_of):
            return
        var queue = self.queue_of[slot]
        if queue == NO_SLOT:
            return
        var before = self.prev[slot]
        var after = self.next[slot]
        if before == NO_SLOT:
            self.heads[queue] = after
        else:
            self.next[before] = after
        if after == NO_SLOT:
            self.tails[queue] = before
        else:
            self.prev[after] = before
        self.prev[slot] = NO_SLOT
        self.next[slot] = NO_SLOT
        self.queue_of[slot] = NO_SLOT

    def front(self, queue: Int) -> Int:
        """The slot that has waited longest in `queue`, `NO_SLOT` when it is empty."""
        if queue < 0 or queue >= len(self.heads):
            return NO_SLOT
        return self.heads[queue]

    def queue(self, slot: Int) -> Int:
        """The queue `slot` is in, `NO_SLOT` for none."""
        if slot < 0 or slot >= len(self.queue_of):
            return NO_SLOT
        return self.queue_of[slot]

    def count(self, queue: Int) -> Int:
        """How many slots `queue` holds, by walking it: for tests, never the
        accept path."""
        var n = 0
        var s = self.front(queue)
        while s != NO_SLOT:
            n += 1
            s = self.next[s]
        return n
