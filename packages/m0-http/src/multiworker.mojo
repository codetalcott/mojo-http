"""Multi-worker fork supervisor with crash respawn and signal propagation.

Forks N child processes. Children return to the caller to run the
normal server startup path. The parent supervises: respawns crashed
children, propagates SIGTERM/SIGINT to all children.

Propagation runs two ways, and both are needed. A signal sent to the process
group — Ctrl-C in a terminal — reaches every worker directly. A signal sent to
the supervisor alone — what `docker stop` does, since only PID 1 is signalled —
reaches nobody but the parent, and used to leave the workers orphaned and still
holding the port. `_on_supervisor_signal` closes that gap.

Usage:
    var supervisor = WorkerSupervisor(num_workers)
    supervisor.fork_all()
    # Only children reach here — run normal server startup
"""

from std.atomic import Atomic
from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns
from lightbug_http.c.process import (
    fork, process_exit, getpid, waitpid_blocking,
    kill_process, was_signaled, term_signal, exit_code,
    install_signal_handler, SIGTERM, SIGINT,
)

from .global_slot import (
    publish_child_pids, child_pid_count, child_pid_at, MAX_TRACKED_CHILDREN,
)


# mmap constants — the only two flags this module needs. MAP_ANONYMOUS is the
# one that differs by platform (Linux 0x20, macOS 0x1000).
comptime _PROT_READ_WRITE = 0x1 | 0x2
comptime _MAP_SHARED = 0x01
comptime _MAP_ANON = 0x1000 if CompilationTarget.is_macos() else 0x20


struct SharedAtomics(Copyable, Movable):
    """A page of Int64 atomics shared across `fork()`.

    Create **before** `fork_all()`: the backing page is
    `mmap(MAP_SHARED | MAP_ANONYMOUS)`, so every worker addresses the same
    physical memory and the atomics coordinate across processes. This is what
    keeps SSE event ids globally unique under `M0_WORKERS>1` (`slot 0` by
    convention), and what lets an app keep a counter every worker agrees on.

    The value stored per struct is just the page address, so copies made when
    threading it through per-worker state all alias the same page. The page is
    process-lifetime; there is no unmap (mirrors the event-loop backends'
    process-lifetime allocations).
    """

    var _base: Int
    var _count: Int

    def __init__(out self, count: Int) raises:
        """Allocate `count` shared Int64 atomic slots, all starting at 0."""
        var bytes_needed = count * 8
        var length = ((bytes_needed + 4095) // 4096) * 4096
        var raw = external_call[
            "mmap", Int, Int, Int, c_int, c_int, c_int, Int
        ](
            0, length, c_int(_PROT_READ_WRITE),
            c_int(_MAP_SHARED | _MAP_ANON), c_int(-1), 0,
        )
        if raw == -1 or raw == 0:
            raise Error("mmap(MAP_SHARED|MAP_ANON) failed, errno: ", get_errno())
        self._base = raw
        self._count = count
        for i in range(count):
            self._slot(i)[] = Atomic[DType.int64](0)

    def __init__(out self, *, copy: Self):
        self._base = copy._base
        self._count = copy._count

    def __init__(out self, *, deinit move: Self):
        self._base = move._base
        self._count = move._count

    def _slot(self, i: Int) -> Pointer[Atomic[DType.int64], MutUntrackedOrigin]:
        return Pointer[Atomic[DType.int64], MutUntrackedOrigin](
            unsafe_from_address=self._base + i * 8
        )

    def addr(self, i: Int) -> Int:
        """Raw address of slot `i` — for consumers that hold it as an Int."""
        if i < 0 or i >= self._count:
            return 0
        return self._base + i * 8

    def fetch_add(self, i: Int, delta: Int) -> Int:
        """Atomically add `delta` to slot `i`; returns the PREVIOUS value."""
        return Int(self._slot(i)[].fetch_add(Int64(delta)))

    def load(self, i: Int) -> Int:
        return Int(self._slot(i)[].load())

    def store(self, i: Int, value: Int):
        self._slot(i)[].store(Int64(value))


def shared_fetch_add(addr: Int, delta: Int) -> Int:
    """fetch_add on a shared atomic slot named by its raw address.

    The address form is how a `SharedAtomics` slot travels through structs
    that must not depend on this module's types (an `Int` field instead of a
    parametrized pointer). `addr` must come from `SharedAtomics.addr`; 0 is
    answered with 0 so an unwired consumer fails soft.
    """
    if addr == 0:
        return 0
    var slot = Pointer[Atomic[DType.int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    return Int(slot[].fetch_add(Int64(delta)))


def shared_load(addr: Int) -> Int:
    """load on a shared atomic slot named by its raw address (0 → 0)."""
    if addr == 0:
        return 0
    var slot = Pointer[Atomic[DType.int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    return Int(slot[].load())


def shared_store(addr: Int, value: Int):
    """store on a shared atomic slot named by its raw address (0 → no-op)."""
    if addr == 0:
        return
    var slot = Pointer[Atomic[DType.int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    slot[].store(Int64(value))


def _on_supervisor_signal(sig: c_int):
    """Signal handler for the supervising parent: pass the signal on.

    Async-signal-safe: reads two immortal words per child and calls `kill(2)`,
    which POSIX lists as safe. Everything else — reaping, deciding not to
    respawn — happens back in `_supervise`, which needs no change at all,
    because a worker that drained and exited 0 already retires cleanly there.

    A PID of 0 means a vacant index, and is skipped: `kill(0, sig)` signals the
    caller's whole process group, which from inside the parent would mean
    signalling itself.
    """
    var count = child_pid_count()
    for i in range(count):
        var pid = child_pid_at(i)
        if pid > 0:
            _ = kill_process(pid, Int(sig))


def exit_worker():
    """End a forked worker's process without unwinding the Mojo runtime.

    Call this where a worker's serve loop returns — `if config.workers > 1`,
    after `serve_nonblocking`. **Returning from `main` in a forked child
    crashes.** The runtime's teardown reaches into libdispatch, and libdispatch
    is documented as unusable in a child that forked without exec'ing: the
    worker dies with a SIGTRAP and a backtrace, and the supervisor sees a crash
    and respawns it, so a graceful shutdown turns into a respawn loop.

    Nothing hit this until workers learned to shut down gracefully — before
    that a worker only ever ended by taking an uncaught signal, which never
    reaches teardown. `process_exit` is `_exit(2)`: no atexit handlers, and no
    flush of stdio buffers that were inherited from the parent, which is the
    same reason the supervisor already uses it.
    """
    process_exit(0)


def _forget_supervisor_signals():
    """Restore default SIGTERM/SIGINT in a freshly forked child.

    A respawned worker is forked *after* the parent armed itself, so it
    inherits both the parent's handler and its list of sibling PIDs — one
    SIGTERM and it would try to kill its own siblings. Every child clears the
    inheritance before it returns from `fork_all`; the app then installs the
    worker handler with `install_shutdown_signals`.
    """
    _ = install_signal_handler(SIGTERM, 0)
    _ = install_signal_handler(SIGINT, 0)
    publish_child_pids(List[Int]())


# _try_respawn outcomes. A plain Bool cannot express the case that matters:
# after the respawn fork() there are *two* processes inside _try_respawn, and
# the child must unwind all the way out of fork_all while the parent keeps
# supervising.
comptime _RESPAWN_FAILED = 0
comptime _RESPAWN_PARENT = 1
comptime _RESPAWN_CHILD = 2


struct WorkerSupervisor:
    """Supervises forked worker processes with crash respawn."""
    var child_pids: List[Int]
    """pid of the worker holding each index, -1 while an index is vacant.

    Position IS the worker index: it names per-worker resources created
    before the fork (a `BroadcastBus` channel, most importantly), so a pid
    must never migrate between positions and a respawned worker must take
    over the exact index its predecessor held.
    """
    var worker_index: Int
    """This process's worker index; -1 in the supervising parent.

    Set in every child — initially forked or respawned — before `fork_all`
    returns to the caller. It is how a worker knows which pre-fork resources
    (bus channel, shared slots) are its own.
    """
    var num_workers: Int
    var max_respawns: Int
    var respawn_count: Int
    var rapid_crash_count: Int
    var last_fork_ns: Int
    var _last_freed_index: Int

    def __init__(out self, num_workers: Int):
        self.child_pids = List[Int]()
        self.worker_index = -1
        self.num_workers = num_workers
        self.max_respawns = num_workers * 10
        self.respawn_count = 0
        self.rapid_crash_count = 0
        self.last_fork_ns = 0
        self._last_freed_index = -1

    def fork_all(mut self) raises:
        """Fork all workers. Children return. Parent enters supervise loop and exits.

        Every child — initial or respawned — returns from this call to run the
        caller's normal server startup path. The parent never returns: it
        supervises until all children are gone, then exits the process.
        """
        for i in range(self.num_workers):
            self.last_fork_ns = perf_counter_ns()
            var pid = fork()
            if pid == 0:
                # Child: record which index this process holds and return
                self.worker_index = i
                _forget_supervisor_signals()
                print("[worker {}] pid={} starting".format(i, getpid()))
                return
            self.child_pids.append(pid)

        # Parent process: supervise children
        self._arm_signal_propagation()
        print("[parent] pid={} supervising {} workers".format(getpid(), self.num_workers))
        if self._supervise():
            # Respawned child: unwind to the caller's server startup path,
            # exactly as an initially-forked child does above.
            return
        process_exit(0)

    def _supervise(mut self) raises -> Bool:
        """Parent supervision loop: respawn crashes, propagate signals.

        Returns True only in a respawned child, which must return to
        `fork_all`'s caller rather than keep supervising. Returns False in the
        parent once supervision is over.
        """
        var remaining = self.num_workers
        while remaining > 0:
            var result = waitpid_blocking(-1)
            var child_pid = result[0]
            var status = result[1]

            # Remove from tracked list
            self._remove_pid(child_pid)

            if was_signaled(status):
                var sig = term_signal(status)
                print("[parent] worker pid={} killed by signal {}".format(child_pid, sig))
                if sig == SIGTERM or sig == SIGINT:
                    # Propagate to all remaining children and shut down
                    print("[parent] propagating signal {} to remaining workers".format(sig))
                    self._kill_all(sig)
                    remaining -= 1
                    # Wait for remaining children to exit
                    while remaining > 0:
                        _ = waitpid_blocking(-1)
                        remaining -= 1
                    return False
                # Other signal (e.g., SIGKILL) — treat as crash, try respawn
                var outcome = self._try_respawn()
                if outcome == _RESPAWN_CHILD:
                    return True
                if outcome == _RESPAWN_PARENT:
                    continue
                remaining -= 1
            else:
                var code = exit_code(status)
                if code != 0:
                    print("[parent] worker pid={} crashed (exit_code={})".format(child_pid, code))
                    var outcome = self._try_respawn()
                    if outcome == _RESPAWN_CHILD:
                        return True
                    if outcome == _RESPAWN_PARENT:
                        continue
                else:
                    print("[parent] worker pid={} exited cleanly".format(child_pid))
                remaining -= 1
        return False

    def _try_respawn(mut self) raises -> Int:
        """Attempt to respawn a worker.

        Returns `_RESPAWN_PARENT` in the parent on success, `_RESPAWN_CHILD` in
        the freshly forked child (which must unwind out to `fork_all`'s
        caller), and `_RESPAWN_FAILED` when the respawn budget is spent.
        """
        if self.respawn_count >= self.max_respawns:
            print("[parent] max respawns ({}) reached, not respawning".format(self.max_respawns))
            return _RESPAWN_FAILED

        # Rapid crash detection: if child died within 1 second of last fork
        var now = perf_counter_ns()
        var elapsed_ns = now - self.last_fork_ns
        if elapsed_ns < 1_000_000_000:  # 1 second
            self.rapid_crash_count += 1
            if self.rapid_crash_count >= 5:
                print("[parent] 5 rapid crashes detected, stopping respawn")
                return _RESPAWN_FAILED
        else:
            self.rapid_crash_count = 0

        self.respawn_count += 1
        self.last_fork_ns = perf_counter_ns()
        var respawn_index = self._last_freed_index
        var new_pid = fork()
        if new_pid == 0:
            # The replacement takes over the dead worker's index — and with
            # it the dead worker's bus channel and shared slots.
            self.worker_index = respawn_index
            _forget_supervisor_signals()
            print("[worker respawn {}] pid={} starting".format(respawn_index, getpid()))
            return _RESPAWN_CHILD
        if respawn_index >= 0 and respawn_index < len(self.child_pids):
            self.child_pids[respawn_index] = new_pid
            publish_child_pids(self.child_pids)
        print("[parent] respawned worker {} as pid={}".format(respawn_index, new_pid))
        return _RESPAWN_PARENT

    def _remove_pid(mut self, pid: Int):
        """Vacate a dead worker's index, remembering it for the respawn.

        The slot is set to -1 rather than removed: position is the worker
        index (see `child_pids`), so the list must never compact.
        """
        for i in range(len(self.child_pids)):
            if self.child_pids[i] == pid:
                self.child_pids[i] = -1
                self._last_freed_index = i
                publish_child_pids(self.child_pids)
                return

    def _arm_signal_propagation(self):
        """Make a SIGTERM/SIGINT aimed at the parent alone reach the workers.

        Publishes the child PIDs where `_on_supervisor_signal` can read them,
        then verifies the publish round-tripped before installing anything. A
        handler over a slot that does not work would swallow SIGTERM and leave
        no way to stop the supervisor at all — strictly worse than the default
        behaviour, which is what declining leaves in place. See
        `src/global_slot.mojo` for when that can happen.
        """
        publish_child_pids(self.child_pids)
        var expected = len(self.child_pids)
        if expected > MAX_TRACKED_CHILDREN:
            expected = MAX_TRACKED_CHILDREN
        if child_pid_count() != expected:
            print("[parent] signal propagation unavailable; workers will not"
                  " be reaped if the supervisor alone is signalled")
            return
        var handler = _on_supervisor_signal
        var handler_address = Pointer(to=handler).unsafe_bitcast[Int]()[]
        _ = install_signal_handler(SIGTERM, handler_address)
        _ = install_signal_handler(SIGINT, handler_address)
        _ = handler

    def _kill_all(self, signal: Int):
        """Send a signal to all tracked child processes."""
        for i in range(len(self.child_pids)):
            if self.child_pids[i] > 0:
                _ = kill_process(self.child_pids[i], signal)
