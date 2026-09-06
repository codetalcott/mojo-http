"""A bounded multi-producer, multi-consumer queue of integers in plain memory.

Dmitry Vyukov's bounded MPMC queue. Every cell carries a sequence number
that says whose turn it is: a producer's when it equals the cell's
position, a consumer's when it is one past it. Producers contend on one
counter (`tail`), consumers on another (`head`), and a claimed cell is
published by its own sequence store — so a reader never sees a value that
has not been fully written, and no lock exists to be held across a park.

Why it is here at all: the `--blocking-threads` handoff used to BE a
socketpair syscall in each direction (`offload.mojo`), and on the loop
thread those two syscalls plus the extra `kevent` churn they caused were
~1.2 µs of a 7.2 µs request, with another 1.4 µs on the pool thread
(docs/notes/loop-thread-bound.md). The queue moves the jobs and the
completions into memory; the socketpairs stay as the WAKE — used only when
the receiving side has said it is parked — and for the datagrams that
carry a payload (an inbound WebSocket message, the poison pill, a stream
abort, an executor's batch).

Memory is `malloc`'d and kept for the process's life, like the pool's turn
counters: the addresses ride in thread blocks and a `Ring` is two integers,
so copies are cheap and none of them owns anything. Every atomic operation
is sequentially consistent (the stdlib's default), which is what the
parked-flag protocol in `offload.mojo` relies on — a store-then-load on
each side must not be reordered into a load-then-store, and acquire and
release alone do not promise that.
"""

from std.atomic import Atomic
from std.ffi import external_call


comptime _RING_HEADER = 256
"""Bytes before the cells: `head` at +0 and `tail` at +128, on cache lines
of their own so the two counters never false-share."""

comptime _RING_CELL = 16
"""Bytes per cell: the sequence word, then the value."""


def atomic_at(addr: Int) -> Pointer[Atomic[DType.int64], MutUntrackedOrigin]:
    """The `Int64` atomic living at a raw address."""
    return Pointer[Atomic[DType.int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )


def _value_at(addr: Int) -> Pointer[Int64, MutUntrackedOrigin]:
    return Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)


struct Ring(Copyable, Movable):
    """A bounded MPMC queue of `Int`; see the module docstring.

    Two integers: the block's address and the index mask. `base == 0` is a
    disabled ring, which refuses every push and answers every pop with
    nothing — the shape a lane gets when the ring handoff is switched off,
    so callers ask `enabled()` once and take the datagram path.
    """

    var base: Int
    var mask: Int

    def __init__(out self):
        """The disabled ring."""
        self.base = 0
        self.mask = 0

    def __init__(out self, capacity: Int):
        """A ring holding `capacity` values, rounded up to a power of two."""
        var cap = 2
        while cap < capacity:
            cap *= 2
        var bytes = _RING_HEADER + cap * _RING_CELL
        self.base = external_call["malloc", Int, Int](bytes)
        self.mask = cap - 1
        atomic_at(self.base)[] = Atomic[DType.int64](0)
        atomic_at(self.base + 128)[] = Atomic[DType.int64](0)
        for i in range(cap):
            atomic_at(self._seq_addr(i))[] = Atomic[DType.int64](Int64(i))
            _value_at(self._val_addr(i))[] = 0

    def __init__(out self, *, unsafe_base: Int, mask: Int):
        """A view of a ring another thread built, from its two integers."""
        self.base = unsafe_base
        self.mask = mask

    def _seq_addr(self, cell: Int) -> Int:
        return self.base + _RING_HEADER + cell * _RING_CELL

    def _val_addr(self, cell: Int) -> Int:
        return self.base + _RING_HEADER + cell * _RING_CELL + 8

    def enabled(self) -> Bool:
        return self.base != 0

    def capacity(self) -> Int:
        return self.mask + 1 if self.base != 0 else 0

    def push(self, value: Int) -> Bool:
        """Append `value`; False when the ring is full (or disabled)."""
        if self.base == 0:
            return False
        var tail = atomic_at(self.base + 128)
        var pos = tail[].load()
        while True:
            var cell = Int(pos) & self.mask
            var seq = atomic_at(self._seq_addr(cell))[].load()
            var dif = seq - pos
            if dif == 0:
                var expected = pos
                if tail[].compare_exchange(expected, pos + 1):
                    break
                pos = expected
            elif dif < 0:
                return False
            else:
                pos = tail[].load()
        var mine = Int(pos) & self.mask
        _value_at(self._val_addr(mine))[] = Int64(value)
        atomic_at(self._seq_addr(mine))[].store(pos + 1)
        return True

    def pop(self, mut out: Int) -> Bool:
        """Take the oldest value into `out`; False when nothing is published."""
        if self.base == 0:
            return False
        var head = atomic_at(self.base)
        var pos = head[].load()
        while True:
            var cell = Int(pos) & self.mask
            var seq = atomic_at(self._seq_addr(cell))[].load()
            var dif = seq - (pos + 1)
            if dif == 0:
                var expected = pos
                if head[].compare_exchange(expected, pos + 1):
                    break
                pos = expected
            elif dif < 0:
                return False
            else:
                pos = head[].load()
        var mine = Int(pos) & self.mask
        out = Int(_value_at(self._val_addr(mine))[])
        atomic_at(self._seq_addr(mine))[].store(pos + Int64(self.mask) + 1)
        return True

    def is_empty(self) -> Bool:
        """Whether a `pop` right now would find nothing.

        A value a producer has claimed a cell for but not yet published
        counts as absent — which is what the parked-flag protocol needs,
        because that producer will look at the parked flag only AFTER its
        publish, and the flag is set before this is asked.
        """
        if self.base == 0:
            return True
        var pos = atomic_at(self.base)[].load()
        var seq = atomic_at(self._seq_addr(Int(pos) & self.mask))[].load()
        return seq != pos + 1
