"""Raw pthreads from Mojo, with the argument-block idiom the probes proved.

Mojo 1.0's standard library ships atomics but no thread or mutex type, and
the runtime's own task pool is the wrong shape for "N loops that each block
in kevent/epoll_wait for the life of the process". What a threaded server
needs is exactly what `scripts/py_thread_probe.mojo` used: `pthread_create`
through `external_call`, a start routine whose address is taken from a
`def`, and a per-thread argument block of Int64 slots in malloc'd memory
reached through one `void*` — no Mojo collections cross the boundary.

This module is that idiom, packaged. It knows nothing about Python: the
attach/detach discipline lives in `m0_wsgi.threaded`, which is the only
place that may import `std.python`. Everything here is importable under
`mojo run` (pthread symbols come from libc) and tested without an
interpreter in `test_threads.mojo`.

**Synchronization model.** A block's result slots are written only by the
thread that owns the block and read only after `pthread_join`, which is
the happens-before edge. Anything two threads share goes through an
`Atomic` whose address rides in a slot — never through a `List`.

Allocations are process-lifetime, like the event-loop backends': a thread
set is created once at startup and its blocks must outlive every thread.
"""

from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns, sleep

from lightbug_http.c.pipe import create_shutdown_pipe, ShutdownHandle


comptime BLK_INDEX = 0
"""The thread's index in its set."""
comptime BLK_LISTEN_FD = 1
"""This thread's own dup of the listening socket."""
comptime BLK_SHUTDOWN_FD = 2
"""Read end of this thread's shutdown pipe."""
comptime BLK_BUS_FD = 3
"""This thread's bus channel, or -1."""
comptime BLK_USER = 4
"""Address of whatever the spawner wants the thread to find."""
comptime BLK_STATUS = 5
"""Written by the thread: `STATUS_NEVER_RAN` until it starts, then its result."""
comptime BLK_LANE = 6
"""Which submit lane a pool thread serves (`--mount`); 0 when there is one."""
comptime BLK_TURN_ADDR = 8
"""Address of a pool's turn counters -- the hand-off barrier around its
threads' re-attach (`m0_wsgi.blocking_pool`) -- or 0. Slot 7 is `BLK_POOL`,
private to that module."""
comptime BLK_QOS = 9
"""1 if the thread should request its role's Darwin QoS class at start.

Set by whoever spawns the thread (`BlockingPool.start`, `AsgiExecutor.start`)
from `--qos`; read once by the body before it serves. A slot rather than a
field on the options struct so `m0-http`'s pools need not know the type
that carries the flag."""

comptime BLK_INTS = 16
"""Slots per block; 128 bytes, two cache lines."""

comptime STATUS_NEVER_RAN = -3
comptime STATUS_RAISED = -1
comptime STATUS_OK = 0


def _slot(addr: Int) -> Pointer[Int, MutUntrackedOrigin]:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)


comptime _OpaqueMut = Pointer[NoneType, MutUntrackedOrigin]
"""The buffer type `read(2)` is declared with — matching the stdlib's own
emitted declaration exactly, as `pipe.mojo`'s `_write` must: a second
`external_call["read"]` with a different signature is a conflicting
declaration in any build that links both."""


struct ThreadBlock(Copyable, Movable):
    """A view over one thread's argument block (`BLK_INTS` Int64 slots)."""

    var addr: Int

    def __init__(out self, addr: Int):
        self.addr = addr

    def get(self, slot: Int) -> Int:
        return _slot(self.addr + slot * 8)[]

    def set(self, slot: Int, value: Int):
        _slot(self.addr + slot * 8)[] = value


struct ThreadSet(Movable):
    """`count` argument blocks and thread ids, spawned and joined as a set.

    Usage, in the spawning thread:

        var threads = ThreadSet(n)
        for i in range(n):
            threads.block(i).set(BLK_USER, spec_addr)
            threads.spawn(i, body_addr)
        threads.join_all()
        threads.status(i)      # what thread i reported

    `body_addr` is the address of a `def body(arg: Int) -> Int`, taken as
    `Pointer(to=body).unsafe_bitcast[Int]()[]`; `arg` is the block address.
    """

    var count: Int
    var _blocks: Int
    var _tids: Int

    def __init__(out self, count: Int):
        self.count = count
        self._blocks = external_call["malloc", Int, Int](count * BLK_INTS * 8)
        self._tids = external_call["malloc", Int, Int](count * 8)
        # malloc does not zero. `join_all` treats a zero tid as "never
        # spawned"; an unzeroed slot would be joined as a garbage thread id.
        for i in range(count):
            _slot(self._tids + i * 8)[] = 0
        for i in range(count):
            for s in range(BLK_INTS):
                _slot(self._blocks + (i * BLK_INTS + s) * 8)[] = 0
            _slot(self._blocks + (i * BLK_INTS + BLK_STATUS) * 8)[] = STATUS_NEVER_RAN
            _slot(self._blocks + (i * BLK_INTS + BLK_INDEX) * 8)[] = i

    def __init__(out self, *, deinit move: Self):
        self.count = move.count
        self._blocks = move._blocks
        self._tids = move._tids

    def block(self, i: Int) -> ThreadBlock:
        return ThreadBlock(self._blocks + i * BLK_INTS * 8)

    def spawn(mut self, i: Int, body_addr: Int) raises:
        """Start thread `i` running `body_addr(block(i).addr)`."""
        var rc = external_call["pthread_create", c_int, Int, Int, Int, Int](
            self._tids + i * 8, 0, body_addr, self.block(i).addr
        )
        if rc != c_int(0):
            raise Error("pthread_create failed for thread ", i, ": ", Int(rc))

    def join_all(mut self) raises:
        """Wait for every spawned thread. Blocks; detach from any interpreter first."""
        for i in range(self.count):
            var tid = _slot(self._tids + i * 8)[]
            if tid == 0:
                continue
            var rc = external_call["pthread_join", c_int, Int, Int](tid, 0)
            if rc != c_int(0):
                raise Error("pthread_join failed for thread ", i, ": ", Int(rc))

    def join_within(mut self, timeout_ns: Int) raises -> Int:
        """Join every thread that ends within `timeout_ns`; return how many did not.

        `pthread_join` has no timeout, so the wait is on each thread's status
        slot instead. A body writes `BLK_STATUS` as its very last act — after
        releasing its interpreter state, immediately before returning — so a
        slot still at `STATUS_NEVER_RAN` means the thread is still inside its
        body, and one that has changed belongs to a thread that is exiting and
        joins promptly. Stragglers are left running and unjoined: the caller
        is leaving the process without them, which is the only thing that can
        be done about a thread blocked inside application code. Nothing in
        this process can unwind Python on another thread, and a join that
        waits for it is a SIGTERM that does nothing until `docker stop` gives
        up and sends SIGKILL — which is what it did.
        """
        var deadline = perf_counter_ns() + timeout_ns
        var stragglers = 0
        for i in range(self.count):
            var tid = _slot(self._tids + i * 8)[]
            if tid == 0:
                continue
            while self.status(i) == STATUS_NEVER_RAN and perf_counter_ns() < deadline:
                sleep(0.02)
            if self.status(i) == STATUS_NEVER_RAN:
                stragglers += 1
                continue
            var rc = external_call["pthread_join", c_int, Int, Int](tid, 0)
            if rc != c_int(0):
                raise Error("pthread_join failed for thread ", i, ": ", Int(rc))
        return stragglers

    def status(self, i: Int) -> Int:
        return self.block(i).get(BLK_STATUS)

    def all_ok(self) -> Bool:
        for i in range(self.count):
            if self.status(i) != STATUS_OK:
                return False
        return True


def dup_fd(fd: Int) raises -> Int:
    """`dup(2)`: a second descriptor on the same open file description.

    Each serving thread registers its own dup of the listener with its own
    kqueue/epoll, and closes its own on shutdown — so one thread's close is
    not every thread's. O_NONBLOCK lives on the description, so the dup is
    non-blocking if the original was.
    """
    var rc = external_call["dup", c_int, c_int](c_int(fd))
    if rc < c_int(0):
        raise Error("dup() failed, errno: ", get_errno())
    return Int(rc)


def read_one_byte_blocking(fd: Int) -> Int:
    """Block until one byte (or EOF) arrives on `fd`; returns bytes read.

    The coordinator's wait: the main thread, detached from the interpreter,
    sleeps here until the signal pipe says stop. EINTR is retried — a caught
    signal is exactly what this fd reports, and the byte follows it.
    """
    # An explicit allocation, not a `List(capacity=...)`: that constructor
    # reserves but a write through its pointer before any append is a write
    # the list does not own, and it corrupted the heap under a real build.
    var buf = external_call["malloc", Int, Int](8)
    var ptr = _OpaqueMut(unsafe_from_address=buf)
    var n: Int
    while True:
        n = external_call["read", Int, Int, _OpaqueMut, Int](fd, ptr, 1)
        if n >= 0:
            break
        var err = get_errno()
        if err != err.EINTR:
            n = 0
            break
    external_call["free", NoneType, Int](buf)
    return n


struct ShutdownFanout(Movable):
    """One shutdown pipe per thread, and one call that pokes all of them.

    The event loop never drains its shutdown pipe — it sees the byte, sets
    `should_shutdown`, and breaks — so N loops cannot share one pipe
    reliably. Each gets its own; the coordinator, woken by the process-wide
    signal pipe, calls `notify_all()`.
    """

    var _read_fds: List[Int]
    var _write_fds: List[Int]

    def __init__(out self, count: Int) raises:
        self._read_fds = List[Int]()
        self._write_fds = List[Int]()
        for _ in range(count):
            var pair = create_shutdown_pipe()
            self._read_fds.append(pair[0])
            self._write_fds.append(pair[1].fd)

    def __init__(out self, *, deinit move: Self):
        self._read_fds = move._read_fds^
        self._write_fds = move._write_fds^

    def count(self) -> Int:
        return len(self._read_fds)

    def read_fd(self, i: Int) -> Int:
        """Pass as `shutdown_read_fd` to thread `i`'s event loop."""
        if i < 0 or i >= len(self._read_fds):
            return -1
        return self._read_fds[i]

    def notify_all(self):
        """Write one byte to every pipe — repeat-safe, async-signal-safe."""
        for i in range(len(self._write_fds)):
            ShutdownHandle(self._write_fds[i]).notify()


# --- Darwin QoS ---------------------------------------------------------------
#
# Apple Silicon has performance and efficiency cores, and which one a thread
# lands on is the scheduler's choice, steered by the thread's QoS class: an
# E-core serves this server's hello-world at roughly a quarter of a P-core's
# rate (docs/BENCHMARKS.md), so under contention the placement IS the
# throughput. Darwin has no affinity API; `pthread_set_qos_class_self_np` is
# the whole lever. Values from <sys/qos.h>, confirmed by a C probe on macOS
# 26: USER_INTERACTIVE 0x21, USER_INITIATED 0x19, DEFAULT 0x15, UTILITY
# 0x11, BACKGROUND 0x09.

comptime QOS_CLASS_USER_INTERACTIVE = 33
"""For a thread whose latency is the product: the event loop."""

comptime QOS_CLASS_USER_INITIATED = 25
"""For a thread doing work the loop is waiting on: pool and executor threads."""


def request_qos_class(qos_class: Int) -> Bool:
    """Ask Darwin to schedule the CALLING thread at `qos_class`.

    Returns whether the request was accepted. Always False off macOS, where
    it is a no-op rather than an error: the flag that reaches here is
    accepted on every platform and ignored where it means nothing, like
    `--reload` on a read-only filesystem.
    """
    comptime if CompilationTarget.is_macos():
        var rc = external_call[
            "pthread_set_qos_class_self_np", c_int, c_int, c_int
        ](c_int(qos_class), c_int(0))
        return rc == c_int(0)
    else:
        return False
