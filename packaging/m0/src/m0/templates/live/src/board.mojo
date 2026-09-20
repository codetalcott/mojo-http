"""What the workers and the producer thread share: one page of atomic words.

The host creates the page BEFORE it forks, sized by `board_slots`, and
hands its address to every worker and to the producer as `ctx.page`. It is
the only memory here that crosses a process boundary: under `M0_WORKERS=2`
a kick lands on whichever worker answered the click, and the producer runs
in worker 0. Anything `malloc`'d is private to the process that made it.
"""

from m0_http.multiworker import shared_fetch_add, shared_load, shared_store

comptime B_KICKS = 0
"""Kicks ever posted; any worker adds, the producer reads the difference."""
comptime B_STEPS = 1
comptime B_REFUSED = 2
"""Frames the bus refused. A refused publish is otherwise indistinguishable
from no step at all, so it is counted and `/stats` shows it."""
comptime B_PAUSED = 3
comptime B_VIEWERS_BASE = 4
"""One word per worker from here: that worker's open streams."""


def board_slots(workers: Int) -> Int:
    return B_VIEWERS_BASE + workers


struct Board(ImplicitlyCopyable, Movable):
    """The page's base address, and the layout above as methods."""

    var base: Int

    def __init__(out self, base: Int):
        self.base = base

    def load(self, slot: Int) -> Int:
        return shared_load(self.base + slot * 8)

    def store(self, slot: Int, value: Int):
        shared_store(self.base + slot * 8, value)

    def add(self, slot: Int, delta: Int):
        _ = shared_fetch_add(self.base + slot * 8, delta)

    def set_viewers(self, worker: Int, n: Int):
        self.store(B_VIEWERS_BASE + worker, n)

    def viewers(self, workers: Int) -> Int:
        var total = 0
        for w in range(workers):
            total += self.load(B_VIEWERS_BASE + w)
        return total
