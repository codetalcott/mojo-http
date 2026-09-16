"""What the loop and the producer thread share: one `SharedAtomics` page.

Three things cross between them, and each goes through this page rather
than through anything `malloc`'d:

- **Drops**, loop to producer. A click is validated on the loop and posted
  here; the producer takes it on its next step.
- **Viewer counts**, loop to producer. The producer pauses while nobody
  watches, and `subscriber_count()` is per process, so each worker stores
  its own count in its own word and the producer sums them.
- **Stats**, producer to loop: step count and time, frame size, refused
  publishes. `/stats` reads them, and the gate reads `/stats`.

A shared page because it is the channel that survives `fork()`.
`lightbug_http/ring.mojo` would carry a drop between threads just as well,
but its memory is `malloc`'d, and the Mojo host's normal case is a click
landing on worker 1 while the producer runs in worker 0. Phase 1 serves
from one process; the layout is already per worker so that the host only
has to size it.

The drop box is a ring of `DROP_SLOTS` words and a head counter. A writer
claims a sequence number with `fetch_add` and then stores the drop, packed
with that number, in the word the number selects. Claim-then-store is what
makes it safe for several writers, and it opens a window where the head
has moved and the word has not — so the reader checks the sequence packed
in the word against the one it expects: equal is a drop to apply, smaller
(or empty) is a claim not yet written, where it stops and tries again next
step, and larger is a word already overwritten by a later drop, counted as
lost. A burst larger than the ring between two steps loses its oldest
drops, which is the same eviction the world applies anyway.
"""

from m0_http.multiworker import shared_fetch_add, shared_load, shared_store

from blobs.world import STAGE, World

comptime DROP_SLOTS = 32
"""Drops the ring holds between two producer steps."""

comptime B_DROP_HEAD = 0
comptime B_DROP_BASE = 1
comptime B_STEPS = B_DROP_BASE + DROP_SLOTS
comptime B_LAST_ID = B_STEPS + 1
comptime B_STEP_NS = B_STEPS + 2
comptime B_STEP_NS_MAX = B_STEPS + 3
comptime B_FRAME_BYTES = B_STEPS + 4
comptime B_FRAME_MAX = B_STEPS + 5
comptime B_REFUSED = B_STEPS + 6
comptime B_APPLIED = B_STEPS + 7
comptime B_LOST = B_STEPS + 8
comptime B_PAUSED = B_STEPS + 9
comptime B_PERIOD_MS = B_STEPS + 10
comptime B_OVER_BUDGET = B_STEPS + 11
comptime B_OPEN_PATHS = B_STEPS + 12
"""Contours the kernel could not close, summed over every step: a fault."""
comptime B_HOLES = B_STEPS + 13
"""Holes the kernel dropped, summed over every step."""
comptime B_POLYGONS = B_STEPS + 14
"""Polygons the last step drew."""
comptime B_ACTIVE_NS = B_STEPS + 15
"""Configuration, written once by `main` before the producer starts."""
comptime B_IDLE_NS = B_STEPS + 16
comptime B_IDLE_AFTER_NS = B_STEPS + 17
comptime B_VIEWERS_BASE = B_STEPS + 18
"""One word per worker from here: that worker's subscriber count."""

comptime COORD_SCALE = Float64(10.0)
"""A drop travels as tenths of a grid unit, which fits 16 bits."""


def board_slots(workers: Int) -> Int:
    """How many `SharedAtomics` slots the board needs for `workers`."""
    return B_VIEWERS_BASE + workers


def pack_drop(seq: Int, gx: Float64, gy: Float64) -> Int:
    """`(seq + 1) << 32 | x << 16 | y`, so an empty word (0) is no drop."""
    var x = Int(gx * COORD_SCALE + 0.5)
    var y = Int(gy * COORD_SCALE + 0.5)
    var limit = Int(STAGE * COORD_SCALE)
    x = 0 if x < 0 else (limit if x > limit else x)
    y = 0 if y < 0 else (limit if y > limit else y)
    return ((seq + 1) << 32) | (x << 16) | y


def packed_seq(word: Int) -> Int:
    """The sequence a word was written under, or -1 for an empty word."""
    return (word >> 32) - 1


def packed_x(word: Int) -> Float64:
    return Float64((word >> 16) & 0xFFFF) / COORD_SCALE


def packed_y(word: Int) -> Float64:
    return Float64(word & 0xFFFF) / COORD_SCALE


struct Board(ImplicitlyCopyable, Movable):
    """The page's base address, and the layout above as methods."""

    var base: Int

    def __init__(out self, base: Int):
        self.base = base

    def addr(self, slot: Int) -> Int:
        return self.base + slot * 8

    def load(self, slot: Int) -> Int:
        return shared_load(self.addr(slot))

    def store(self, slot: Int, value: Int):
        shared_store(self.addr(slot), value)

    def add(self, slot: Int, delta: Int):
        _ = shared_fetch_add(self.addr(slot), delta)

    def post_drop(self, gx: Float64, gy: Float64) -> Int:
        """Claim a sequence number, then store the drop under it."""
        var seq = shared_fetch_add(self.addr(B_DROP_HEAD), 1)
        self.store(B_DROP_BASE + seq % DROP_SLOTS, pack_drop(seq, gx, gy))
        return seq

    def set_viewers(self, worker: Int, n: Int):
        self.store(B_VIEWERS_BASE + worker, n)

    def viewers(self, workers: Int) -> Int:
        var total = 0
        for w in range(workers):
            total += self.load(B_VIEWERS_BASE + w)
        return total


struct DropReader(Movable):
    """The producer's side of the drop box: the next sequence it expects."""

    var seen: Int

    def __init__(out self):
        self.seen = 0

    def take(mut self, board: Board, mut world: World) -> Int:
        """Apply every drop written since the last call; return how many."""
        var head = board.load(B_DROP_HEAD)
        if head - self.seen > DROP_SLOTS:
            # Overwritten before this step came round: the ring holds only
            # the newest DROP_SLOTS claims.
            board.add(B_LOST, head - DROP_SLOTS - self.seen)
            self.seen = head - DROP_SLOTS
        var applied = 0
        while self.seen < head:
            var word = board.load(B_DROP_BASE + self.seen % DROP_SLOTS)
            var seq = packed_seq(word)
            if seq < self.seen:
                break  # claimed, not yet stored: next step
            if seq == self.seen:
                world.drop(packed_x(word), packed_y(word))
                applied += 1
            else:
                board.add(B_LOST, 1)
            self.seen += 1
        if applied > 0:
            board.add(B_APPLIED, applied)
        return applied
