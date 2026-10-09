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
from std.time import perf_counter_ns, sleep
from std.os import getenv, setenv
from lightbug_http.accept_share import (
    AcceptShare, close_reaped_handoffs, mark_reaped,
)
from lightbug_http.c.fcntl import clear_cloexec
from lightbug_http.c.process import (
    fork, process_exit, getpid, waitpid_blocking, waitpid_nonblocking,
    kill_process, was_signaled, term_signal, exit_code,
    install_signal_handler, SIGTERM, SIGINT, SIGKILL,
    exec_process, shared_file_fd, map_shared_fd,
)

from .config import parse_env_int
from .global_slot import (
    publish_child_pids, child_pid_count, child_pid_at, child_pids_owner,
    record_supervisor_stop, clear_supervisor_stop, supervisor_stopping,
    supervisor_stop_signal,
)
from .reload import MtimeScanner


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
    var fd: Int
    """The file backing the page, or -1 for the anonymous form.

    Anonymous shared memory survives `fork()` and nothing else; a page that
    must reach a worker that `exec`s (`--spawn-workers`) is file-backed
    (`shm_open`, unlinked at once) and travels as this fd number, which the
    worker maps with `from_fd`. The address differs per process, so the
    exported `M0_SHARED_ID_ADDR` is re-derived there.
    """

    def __init__(out self, count: Int) raises:
        """Allocate `count` shared Int64 atomic slots, all starting at 0."""
        var bytes_needed = count * 8
        var length = ((bytes_needed + 4095) // 4096) * 4096
        self.fd = -1
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
            self._slot(i)[] = Atomic[Int64](0)

    def __init__(out self, count: Int, *, file_backed: Bool) raises:
        """The exec-surviving form: a file-backed page, kept open as `self.fd`."""
        var length = ((count * 8 + 4095) // 4096) * 4096
        if not file_backed:
            self = Self(count)
            return
        var fd = shared_file_fd(length)
        self._base = map_shared_fd(fd, length)
        self._count = count
        self.fd = fd
        for i in range(count):
            self._slot(i)[] = Atomic[Int64](0)

    def __init__(out self, *, from_fd: Int, count: Int) raises:
        """Map a page a parent created with `file_backed=True`; slots are NOT reset."""
        var length = ((count * 8 + 4095) // 4096) * 4096
        self._base = map_shared_fd(from_fd, length)
        self._count = count
        self.fd = from_fd

    def count(self) -> Int:
        return self._count

    def _slot(self, i: Int) -> Pointer[Atomic[Int64], MutUntrackedOrigin]:
        return Pointer[Atomic[Int64], MutUntrackedOrigin](
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
    """`fetch_add` on a shared atomic slot named by its raw address.

    The address form is how a `SharedAtomics` slot travels through structs
    that must not depend on this module's types (an `Int` field instead of a
    parametrized pointer). `addr` must come from `SharedAtomics.addr`; 0 is
    answered with 0 so an unwired consumer fails soft.
    """
    if addr == 0:
        return 0
    var slot = Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    return Int(slot[].fetch_add(Int64(delta)))


def shared_load(addr: Int) -> Int:
    """`load` on a shared atomic slot named by its raw address (0 → 0)."""
    if addr == 0:
        return 0
    var slot = Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    return Int(slot[].load())


def shared_store(addr: Int, value: Int):
    """`store` on a shared atomic slot named by its raw address (0 → no-op)."""
    if addr == 0:
        return
    var slot = Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    slot[].store(Int64(value))


def _on_supervisor_signal(sig: c_int):
    """Signal handler for the supervising parent: pass the signal on.

    Async-signal-safe: reads immortal words, and calls `getpid(2)` and
    `kill(2)`, which POSIX lists as safe. Everything else — reaping,
    deciding not to respawn — happens back in `_supervise`, which needs no
    change at all, because a worker that drained and exited 0 already
    retires cleanly there.

    A PID of 0 means a vacant index, and is skipped: `kill(0, sig)` signals the
    caller's whole process group, which from inside the parent would mean
    signalling itself.

    It records the stop FIRST, and by which signal (one word store, also
    safe): a worker that dies of anything but a clean exit while it drains
    is then not respawned (`_try_respawn`), no worker is forked after it
    (`fork_all`), and a child forked before it whose PID it could not yet
    read is sent the same signal once published (`_publish_children`). A
    respawned worker is sent no signal, so the supervisor would serve it
    forever and `docker stop` would end in SIGKILL -- found when a
    sabotaged Mojo host worker crashed on exit.

    It is armed before the first fork, so each child inherits it until
    `_forget_supervisor_signals` restores the default, and with it its
    parent's list of siblings. It passes a signal on only in the process
    that published the list it reads: in a child it records the stop,
    which `_forget_supervisor_signals` then acts on, and signals no one.
    """
    record_supervisor_stop(Int(sig))
    if child_pids_owner() != getpid():
        return
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
    """Restore default SIGTERM/SIGINT in a freshly forked child, or leave if told to stop.

    Every worker is forked *after* the parent armed itself (`fork_all`), so
    it inherits the parent's handler, its list of sibling PIDs and any stop
    the parent has recorded. Every child clears the inheritance before it
    returns from `fork_all`; the app then installs the worker handler with
    `install_shutdown_signals`.

    A stop recorded before the reset below ends the child here, with 0: the
    inherited handler ran in it (and swallowed the signal, passing nothing
    on), or the parent was told to stop as it forked it. Either way the
    worker was told to stop before it had anything to drain. After the
    reset a SIGTERM takes the default action, so no stop is lost.
    """
    _ = install_signal_handler(SIGTERM, 0)
    _ = install_signal_handler(SIGINT, 0)
    var told = supervisor_stopping()
    publish_child_pids(List[Int]())
    clear_supervisor_stop()
    if told:
        process_exit(0)


comptime _FORK_GAP_ENV = "M0_TEST_FORK_GAP_MS"
"""A pause between one fork and the next: a gate's instrument, not a setting.

`smoke-shutdown` sets it so the supervisor is still forking when it is
signalled, the window B21 once hit by chance; see `_fork_gap_ns`."""


def _fork_gap_ns() -> Int:
    """`M0_TEST_FORK_GAP_MS` in nanoseconds; 0 when unset, not a count, or not above 0.

    Holds the supervisor between its forks, where a worker already forked
    is serving and the rest are not yet forked -- the one window in which a
    signal to the supervisor used to take the default action (B21). The
    gate that sets it signals the supervisor once the first worker answers,
    so the signal lands inside the pause on every run instead of once in a
    hundred.
    """
    return _test_gap_ns(_FORK_GAP_ENV)


comptime _ARM_GAP_ENV = "M0_TEST_ARM_GAP_MS"
"""A pause in every worker but the first, before it arms: a gate's instrument.

`smoke-shutdown` sets it so a worker is still unarmed while worker 0
answers, the window its phase once signalled into by chance; see
`_arm_gap_ns`."""


def _arm_gap_ns() -> Int:
    """`M0_TEST_ARM_GAP_MS` in nanoseconds; 0 when unset, not a count, or not above 0.

    Holds each worker after the first between `_forget_supervisor_signals`
    and its return to the caller, which is what arms its own handler: the
    worker is there at SIGTERM's default action, so a stop that reaches it
    kills it where a drain was meant. Worker 0 already answers, which is
    all a readiness probe sees. CI's `smoke-shutdown` signalled into this
    window once (train 22), and a worker killed there went unreported;
    the gate that sets it waits for every worker's `armed` line before it
    signals, and the pause makes that wait load-bearing on every run.
    """
    return _test_gap_ns(_ARM_GAP_ENV)


comptime _MAX_RESPAWNS_ENV = "M0_TEST_MAX_RESPAWNS"
"""A respawn budget in place of `num_workers * 10`: a gate's instrument, not a setting.

`accept_spread.py --reaped` sets it to 0 so the supervisor gives up on the
first worker that dies, the one the probe has left connections queued to
(review record RB); see `_test_max_respawns`."""


def _test_max_respawns() -> Int:
    """`M0_TEST_MAX_RESPAWNS` as a count; -1 when unset or not a count of 0 or more.

    Replaces `num_workers * 10`, the window unchanged. A probe that must
    decide which death is the one the supervisor gives up on could
    otherwise reach it only through the rapid-crash breaker's fifth death
    inside a second of its fork, and the connections it leaves queued to
    that worker must be handed over inside the same second.
    """
    var raw = getenv(_MAX_RESPAWNS_ENV, "")
    if raw.byte_length() == 0:
        return -1
    return parse_env_int(raw).or_else(-1)


def _test_gap_ns(name: String) -> Int:
    """The variable `name`, in milliseconds, as nanoseconds; 0 unless a count above 0."""
    var raw = getenv(name, "")
    if raw.byte_length() == 0:
        return 0
    var ms = parse_env_int(raw).or_else(0)
    return ms * 1_000_000 if ms > 0 else 0


def _pause_unless_stopped(ns: Int):
    """Sleep `ns` in short slices, returning as soon as a stop is recorded."""
    var until = perf_counter_ns() + ns
    while perf_counter_ns() < until and not supervisor_stopping():
        sleep(0.01)


# _try_respawn outcomes. A plain Bool cannot express the case that matters:
# after the respawn fork() there are *two* processes inside _try_respawn, and
# the child must unwind all the way out of fork_all while the parent keeps
# supervising.
comptime _RESPAWN_FAILED = 0
comptime _RESPAWN_PARENT = 1
comptime _RESPAWN_CHILD = 2
comptime _EXIT_SHUTDOWN = 3
"""A reaped exit that ended supervision: a propagated SIGTERM or SIGINT."""

comptime EX_CONFIG = 78
"""The sysexits "configuration error" code: a worker exiting with it REFUSED its
configuration (a mode the interpreter cannot run, say) and would refuse it
again on every respawn. The supervisor does not respawn one, and exits 78
itself once the workers are gone, so the refusal reaches whatever launched
the server as the refusal it is rather than as ten crashes and an exit 1."""

comptime _RELOAD_DRAIN_NS = 5_000_000_000
"""How long a reload waits for workers to drain before it uses SIGKILL."""

comptime _REAPED_DRAIN_NS = 250_000_000
"""How long the supervisor waits, once, for a hand-off counted to a worker
it gave up on to reach that worker's channel (`close_reaped_handoffs`)."""

comptime _SLOT_PROBE_PID = 0x6D30_5F32  # "m0_2"
"""What `_arm_signal_propagation` writes into the child-PID block and reads back."""

comptime RESPAWN_WINDOW_NS = 3_600_000_000_000
"""The window the respawn budget is counted over: an hour (SPEC E36).

The budget ends a crash loop the rapid-crash breaker cannot see: a worker
that starts, serves for more than a second and crashes again, because a
request that kills it keeps arriving or a leak kills it every few minutes.
Replaced forever, that loop hides; given up on, the supervisor exits 1 once
the workers are gone, which a platform restarts and reports.

What tells a loop from bad luck is how OFTEN a server crashes, not how many
times it has, so the budget is a rate: at most `max_respawns` respawns in
any window of this length. Counted over the whole life, it ran out on rare
crashes too -- at one a day on four workers, after about forty days -- and
the server then served on fewer workers, with no error, until none was left.

An hour at `num_workers * 10` changes nothing for a loop whose whole budget
fits inside it, which is every loop faster than one crash per worker every
six minutes: the supervisor gives up exactly when it did before. A server
that crashes more rarely than that is replaced for as long as it runs, and
each crash is still logged."""


struct WorkerSupervisor:
    """Supervises forked worker processes with crash respawn."""
    var child_pids: List[Int]
    """PID of the worker holding each index, -1 while an index is vacant.

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
    """The respawn budget: at most this many respawns in any
    `respawn_window_ns`. `num_workers * 10`; a test sets it lower."""
    var respawn_window_ns: Int
    """The window `max_respawns` is counted over: `RESPAWN_WINDOW_NS`, an
    hour; a test sets it short so the proof runs in seconds."""
    var respawn_count: Int
    """Every respawn in the supervisor's life: reported, never a budget."""
    var _respawn_times: List[Int]
    """When each respawn inside the window was forked, oldest first."""
    var rapid_crash_count: Int
    var last_fork_ns: Int
    var _last_freed_index: Int
    var _scanner: Optional[MtimeScanner]
    """The change detector under `--reload`; `None` means no reloading.

    Its presence is what switches `_supervise` from parking in `waitpid` to
    polling, because a supervisor that must also watch files cannot afford
    to be parked.
    """
    var reload_interval_ms: Int
    var reloads: Int
    """How many reloads have happened; reported, and read by the smoke."""
    var _config_refused: Bool
    """Whether a worker exited `EX_CONFIG`. Never respawned; propagated."""
    var _accept_page: Int
    """The accept-share page's address in this process when the workers
    share accepts (SPEC E16), else 0: where `_remove_pid` marks each worker
    it reaps as gone (`share_accepts`)."""
    var _accept_channels: List[Int]
    """Each worker's accept-share channel, the read end, in this process:
    what `_give_up` drains for a worker it gave up on."""
    var _spawn_path: String
    """Under `--spawn-workers`, the binary every worker execs; empty means fork."""
    var _spawn_args: List[String]
    """The argv the spawned worker re-runs, `argv[0]` included."""
    var _failed_stopping: Bool
    """Whether a worker failed -- crashed, or died of a signal other than the
    one forwarded -- after the supervisor was told to stop. Not respawned;
    the supervisor exits 1 once the rest are gone."""
    var _gave_up: Bool
    """Whether the respawn budget ran out with a worker still dead.

    A supervisor that stops respawning has lost capacity it was asked for,
    and a worker that crashed on every attempt usually could not start at
    all — a bad module path, an import error. Exiting 0 there reported
    success to whatever launched the server; the exit code now says
    otherwise.
    """

    def __init__(out self, num_workers: Int):
        self.child_pids = List[Int]()
        self.worker_index = -1
        self.num_workers = num_workers
        self.max_respawns = num_workers * 10
        var budget = _test_max_respawns()
        if budget >= 0:
            self.max_respawns = budget
        self.respawn_window_ns = RESPAWN_WINDOW_NS
        self.respawn_count = 0
        self._respawn_times = List[Int]()
        self.rapid_crash_count = 0
        self.last_fork_ns = 0
        self._last_freed_index = -1
        self._scanner = None
        self.reload_interval_ms = 300
        self.reloads = 0
        self._accept_page = 0
        self._accept_channels = List[Int]()
        self._spawn_path = String("")
        self._spawn_args = List[String]()
        self._gave_up = False
        self._failed_stopping = False
        self._config_refused = False

    def share_accepts(mut self, share: AcceptShare, page: Int):
        """Mark each worker this supervisor reaps as gone on the accept-share
        page at `page`, its address in this process (SPEC E16, review RP).

        Call before `fork_all`, with the channels and the page made before
        the fork (`m0_http.prefork`). Nothing when `share` has no channels:
        one worker, or `M0_ACCEPT_SHARE=0`.

        A worker that dies writes nothing more to its line, and its
        siblings' `pick` read what it last wrote -- parked with no load, if
        it was killed waiting -- and handed it connections that nothing
        would read when no replacement followed. The supervisor is the one
        process that learns of the death, so it writes the mark
        (`mark_reaped`) as it reaps, on every path, in `_remove_pid`.
        """
        if share.workers() > 1 and page != 0:
            self._accept_page = page
            self._accept_channels = share.read_fds.copy()

    def enable_spawn(mut self, var path: String, var args: List[String]):
        """Make every worker an exec'd process rather than a forked one.

        Call before `fork_all`. The child is still forked — from a parent that
        has touched no platform runtime, which is what makes the fork safe —
        but it `execv`s `path` with `args` at once, with `M0_WORKER_INDEX`
        and `M0_WORKER_SPAWNED=1` in its environment, and the caller's
        `main` runs again from the top in a fresh image. The environment
        survives the exec, and of the open descriptors only those
        `spawn_inherited_env` names, every other one being close-on-exec
        (SPEC G16); mappings and threads do not.

        What it buys: a worker that may use Objective-C, CoreFoundation,
        libdispatch or anything else that refuses to run in a forked child
        (Core ML, `urlopen`'s proxy lookup on macOS). What it costs: a
        second process start per worker — the binary loads again and the
        interpreter initialises from scratch. The supervisor's own job is
        unchanged: the same pids, the same respawn, the same signals.
        """
        self._spawn_path = path^
        self._spawn_args = args^

    def spawning(self) -> Bool:
        return self._spawn_path.byte_length() > 0

    def _exec_if_spawning(self, index: Int):
        """In a freshly forked child under spawn mode: never returns.

        `exec_process` returns only on failure, and a worker whose image
        cannot load would fail the same way on every respawn — so the exit
        is `EX_CONFIG`, which the supervisor reads as a refusal and stops
        respawning (E10), rather than a crash it would retry ten times.
        """
        if not self.spawning():
            return
        _ = setenv("M0_WORKER_INDEX", String(index), True)
        _ = setenv("M0_WORKER_SPAWNED", String("1"), True)
        # Close-on-exec everywhere else (SPEC G16), so the application's own
        # children inherit none of it: the listener, the page, the bus and
        # the accept-share channels survive THIS exec only, and only in this
        # forked child. The supervisor's copies stay closed for every other
        # exec, and the new image closes each again as it adopts it.
        for fd in spawn_inherited_fds():
            _ = clear_cloexec(fd)
        var errno = exec_process(self._spawn_path, self._spawn_args)
        print(
            "[worker " + String(index) + "] exec of " + self._spawn_path
            + " failed, errno " + errno,
            flush=True,
        )
        process_exit(EX_CONFIG)

    def _become_worker(mut self, index: Int, note: String):
        """In a freshly forked child: hold worker index `index`, shed the supervisor's signals, announce it.

        The prologue of every fork -- `fork_all`, `_reload`, `_try_respawn`
        -- in its one order: the index first, since it names the pre-fork
        resources (bus channel, shared slots) this process owns; then
        `_forget_supervisor_signals`, which ends the child here, with 0, if
        a stop was recorded; then `note`, the site's own "starting" line,
        which gates parse (`accept_spread.py` reads the index and pid from
        it, `smoke-reload` counts `starting (reload 1)`). The caller then
        calls `_exec_if_spawning`; `fork_all` holds a worker unarmed between
        the two.
        """
        self.worker_index = index
        _forget_supervisor_signals()
        print(note, flush=True)

    def enable_reload(mut self, var dirs: List[String], var suffix: String):
        """Watch `dirs` for changed `suffix` files and restart workers on one.

        Call before `fork_all`. Only the supervising parent ever scans: it
        has forked without `exec`, so it stays inside libc — `listdir` and
        `stat` — and never touches Python or any other platform runtime.

        What reloads is the *worker*, not this binary. A changed `.py` is
        picked up by the fresh interpreter a re-forked worker builds; a
        changed `.mojo` needs a rebuild and a restart, and nothing here
        pretends otherwise.
        """
        self._scanner = MtimeScanner(dirs^, suffix^)

    def fork_all(mut self) raises:
        """Fork all workers. Children return. Parent enters supervise loop and exits.

        Every child — initial or respawned — returns from this call to run the
        caller's normal server startup path. The parent never returns: it
        supervises until all children are gone, then exits the process.

        The parent arms the handler that passes a signal on BEFORE its first
        fork, and publishes each child's PID as soon as it has it. Armed
        after the last fork, a SIGTERM aimed at the supervisor alone while
        it was still forking took the default action: the supervisor died
        where it stood, and every worker already forked was left serving,
        holding the port. The window was real because a worker answers once
        its loop starts, which can be before the next worker is forked; CI's
        `smoke-shutdown` hit it once in about a hundred runs (B21). A stop
        that arrives while it forks ends the forking: the workers already
        forked are signalled and supervised to the end, and no more are.
        """
        self._arm_signal_propagation()
        var gap_ns = _fork_gap_ns()
        var arm_gap_ns = _arm_gap_ns()
        for i in range(self.num_workers):
            if i > 0 and gap_ns > 0:
                _pause_unless_stopped(gap_ns)
            if supervisor_stopping():
                break
            self.last_fork_ns = perf_counter_ns()
            var pid = fork()
            if pid == 0:
                # Child: record which index this process holds and return
                self._become_worker(
                    i, "[worker {}] pid={} starting".format(i, getpid())
                )
                if i > 0 and arm_gap_ns > 0:
                    # Unarmed, at SIGTERM's default action, on purpose.
                    sleep(Float64(arm_gap_ns) / 1_000_000_000.0)
                self._exec_if_spawning(i)
                return
            self.child_pids.append(pid)
            self._publish_children()

        # Parent process: supervise children
        if len(self.child_pids) < self.num_workers:
            print(
                "[parent] pid={} told to stop after forking {} of {} workers;"
                " forking no more".format(
                    getpid(), len(self.child_pids), self.num_workers
                )
            )
        else:
            print("[parent] pid={} supervising {} workers".format(getpid(), self.num_workers))
        var reloading = Bool(self._scanner)
        if reloading:
            # Prime the baseline here, in the parent, AFTER the fork: the
            # first pass records rather than reports, and a supervisor that
            # reloaded once at startup would only be announcing that it had
            # started.
            _ = self._scanner.value().changed()
            print(
                "[parent] watching {} ({} files) for changes every {}ms".format(
                    self._scanner.value().describe(),
                    self._scanner.value().watching(),
                    self.reload_interval_ms,
                )
            )
        var respawned: Bool
        if reloading:
            respawned = self._supervise_polling()
        else:
            respawned = self._supervise()
        if respawned:
            # Respawned child: unwind to the caller's server startup path,
            # exactly as an initially-forked child does above.
            return
        if self._config_refused:
            process_exit(EX_CONFIG)
        process_exit(1 if self._gave_up or self._failed_stopping else 0)

    def _supervise(mut self) raises -> Bool:
        """Parent supervision loop: respawn crashes, propagate signals.

        Returns True only in a respawned child, which must return to
        `fork_all`'s caller rather than keep supervising. Returns False in the
        parent once supervision is over. Each reaped child is accounted for
        by `_account_for_exit`, as in `_supervise_polling`.
        """
        # The workers forked, which is fewer than asked when a stop ended
        # the forking (`fork_all`).
        var remaining = self._alive_count()
        while remaining > 0:
            var result = waitpid_blocking(-1)
            var child_pid = result[0]
            var status = result[1]
            var outcome = self._account_for_exit(child_pid, status)
            if outcome == _RESPAWN_CHILD:
                return True
            if outcome == _RESPAWN_PARENT:
                continue
            if outcome == _EXIT_SHUTDOWN:
                return False
            remaining -= 1
        return False

    def _supervise_polling(mut self) raises -> Bool:
        """`--reload`'s supervision loop: reap without blocking, then scan.

        Same contract as `_supervise` — True only in a child that must
        unwind to `fork_all`'s caller — and the same exit accounting, minus
        the ability to park in `wait`. A pass is: drain whatever has exited,
        sleep the interval, scan. `waitpid_nonblocking` answering -1 means
        no children remain, which for a poller is an ordinary end.
        """
        var remaining = self._alive_count()
        while remaining > 0:
            while True:
                var result = waitpid_nonblocking()
                if result[0] == -1:
                    return False  # ECHILD: nothing left to supervise
                if result[0] == 0:
                    break  # children alive, none has exited
                var outcome = self._account_for_exit(result[0], result[1])
                if outcome == _RESPAWN_CHILD:
                    return True
                if outcome == _RESPAWN_PARENT:
                    continue
                if outcome == _EXIT_SHUTDOWN:
                    return False
                remaining -= 1
            if remaining == 0:
                break
            sleep(Float64(self.reload_interval_ms) / 1000.0)
            if self._scanner.value().changed():
                self.reloads += 1
                print(
                    "[parent] change under {} - reload {}".format(
                        self._scanner.value().describe(), self.reloads
                    )
                )
                if self._reload():
                    return True
        return False

    def _account_for_exit(mut self, child_pid: Int, status: Int) raises -> Int:
        """What both supervision loops do with one reaped child, as a value.

        `_RESPAWN_CHILD` in a freshly forked replacement, `_RESPAWN_PARENT`
        when the parent respawned one, `_EXIT_SHUTDOWN` when supervision is
        over -- a SIGTERM/SIGINT now propagated, or a refusal that has ended
        the siblings -- and `_RESPAWN_FAILED` when the index is simply gone.
        """
        self._remove_pid(child_pid)
        if was_signaled(status):
            var sig = term_signal(status)
            if sig == SIGTERM or sig == SIGINT:
                # A stop, reaching a worker before it armed: propagate
                # to the rest, and judge each as it goes.
                self._judge_stopped(child_pid, status)
                print("[parent] propagating signal {} to remaining workers".format(sig))
                self._kill_all(sig)
                self._reap_the_rest()
                return _EXIT_SHUTDOWN
            print("[parent] worker pid={} killed by signal {}".format(child_pid, sig))
            # Other signal (e.g., SIGKILL) — treat as crash, try respawn
            return self._try_respawn()
        var code = exit_code(status)
        if code == EX_CONFIG:
            # A refusal, not a crash: the same configuration would be
            # refused by every respawn, so the siblings are ended too and
            # the exit is 78 (fork_all). Left serving, they were a server
            # missing the worker that refused -- the Mojo host's producer
            # runs on worker 0 alone, and a producer whose `make` raised
            # left worker 1 answering requests with no producer anywhere,
            # indefinitely.
            print("[parent] worker pid={} refused its configuration (exit_code=78); not respawning".format(child_pid))
            self._config_refused = True
            if self._alive_count() > 0:
                print("[parent] stopping the remaining workers: a refused configuration is not served by the rest")
                self._kill_all(SIGTERM)
                self._reap_the_rest()
            return _EXIT_SHUTDOWN
        if code != 0:
            print("[parent] worker pid={} crashed (exit_code={})".format(child_pid, code))
            return self._try_respawn()
        print("[parent] worker pid={} exited cleanly".format(child_pid))
        return _RESPAWN_FAILED

    def _reap_the_rest(mut self) raises:
        """Reap every worker still running once supervision is ending, judging each.

        The paths that end supervision -- a worker killed by SIGTERM or
        SIGINT, which passes the signal on, and a refused configuration,
        which ends the siblings -- used to reap the rest blind, printing
        nothing. A sibling that then crashed in its drain, or was killed by
        another signal, went unreported and the supervisor exited 0, against
        D10; and a sibling's clean exit was not reported either, which is
        how `smoke-shutdown` read a supervisor that had drained worker 0
        as one where no worker reported a clean exit (S1).
        """
        while self._alive_count() > 0:
            var result = waitpid_blocking(-1)
            self._remove_pid(result[0])
            self._judge_stopped(result[0], result[1])

    def _judge_stopped(mut self, child_pid: Int, status: Int):
        """Report one worker reaped while supervision ends, and judge its exit.

        A clean exit is the drain done. A worker killed BY the SIGTERM or
        SIGINT it was sent is a stop too, not a failure: a worker that has
        armed its own handler catches both, so dying of one means it had not
        armed yet (or could not: a degraded install keeps the default on
        purpose, `install_shutdown_signals`), and every entry point arms
        before it starts its loop, so it had no request in flight to cut.
        The default action is the stop it was asked for. Anything else --
        a non-zero exit, another signal -- is a failed drain, and the
        supervisor exits 1 once the rest are gone (D10); an exit 78 is a
        refusal, and the exit is 78 (E10).
        """
        if was_signaled(status):
            var sig = term_signal(status)
            if sig == SIGTERM or sig == SIGINT:
                print(
                    "[parent] worker pid={} killed by signal {} before it armed"
                    " its handler: a stop, not a failure".format(child_pid, sig)
                )
                return
            print(
                "[parent] worker pid={} killed by signal {} while stopping:"
                " a failed drain".format(child_pid, sig)
            )
            self._failed_stopping = True
            return
        var code = exit_code(status)
        if code == 0:
            print("[parent] worker pid={} exited cleanly".format(child_pid))
        elif code == EX_CONFIG:
            print("[parent] worker pid={} refused its configuration (exit_code=78)".format(child_pid))
            self._config_refused = True
        else:
            print(
                "[parent] worker pid={} crashed (exit_code={}) while stopping:"
                " a failed drain".format(child_pid, code)
            )
            self._failed_stopping = True

    def _reload(mut self) raises -> Bool:
        """Stop every worker, then fork replacements into the same indices.

        Returns True in a replacement, which must unwind to `fork_all`'s
        caller exactly as a respawn does.

        SIGTERM first, because that is the signal the workers already know:
        it reaches `install_shutdown_signals`' handler, the event loop
        drains its connections and returns, and the worker leaves through
        `exit_worker()`. Nothing new is needed on the worker side at all —
        a reload is a graceful shutdown that happens to be followed by a
        fork. Stragglers past the deadline get SIGKILL; an editor saving a
        file should not be able to wedge the server.

        These exits are a reload, not a retirement: they are reaped here
        rather than through `_account_for_exit`, so they neither decrement
        `remaining` nor spend respawn budget.
        """
        self._kill_all(SIGTERM)
        var deadline_ns = perf_counter_ns() + _RELOAD_DRAIN_NS
        var alive = self._alive_count()
        while alive > 0 and perf_counter_ns() < deadline_ns:
            var result = waitpid_nonblocking()
            if result[0] == -1:
                alive = 0
                break
            if result[0] == 0:
                sleep(0.01)
                continue
            self._remove_pid(result[0])
            alive = self._alive_count()
        if alive > 0:
            print("[parent] {} worker(s) did not drain in time, killing".format(alive))
            self._kill_all(SIGKILL)
            while self._alive_count() > 0:
                var forced = waitpid_blocking(-1)
                self._remove_pid(forced[0])

        for i in range(len(self.child_pids)):
            if self.child_pids[i] > 0:
                continue
            self.last_fork_ns = perf_counter_ns()
            var pid = fork()
            if pid == 0:
                # The replacement takes over the index its predecessor held,
                # and with it that index's bus channel and shared slots.
                self._become_worker(
                    i,
                    "[worker {}] pid={} starting (reload {})".format(
                        i, getpid(), self.reloads
                    ),
                )
                self._exec_if_spawning(i)
                return True
            self.child_pids[i] = pid
        self._publish_children()
        # Rebaseline AFTER the fork: a worker's own startup can write files
        # (`__pycache__` is skipped, but a project may write others), and
        # counting those as a change would reload forever.
        _ = self._scanner.value().changed()
        print("[parent] reload {} complete".format(self.reloads))
        return False

    def _alive_count(self) -> Int:
        var n = 0
        for i in range(len(self.child_pids)):
            if self.child_pids[i] > 0:
                n += 1
        return n

    def _try_respawn(mut self) raises -> Int:
        """Attempt to respawn a worker.

        Returns `_RESPAWN_PARENT` in the parent on success, `_RESPAWN_CHILD` in
        the freshly forked child (which must unwind out to `fork_all`'s
        caller), and `_RESPAWN_FAILED` when the respawn budget is spent:
        `max_respawns` respawns already inside the last `respawn_window_ns`
        (`RESPAWN_WINDOW_NS`). The index is then left vacant for good, and
        the exit is 1.

        Only crashes come here. A reload's replacements are forked by
        `_reload` itself and spend nothing.
        """
        if supervisor_stopping():
            print("[parent] stopping: a worker that failed during the drain is not respawned")
            self._failed_stopping = True
            return _RESPAWN_FAILED
        var since = perf_counter_ns() - self.respawn_window_ns
        while len(self._respawn_times) > 0 and self._respawn_times[0] <= since:
            _ = self._respawn_times.pop(0)
        if len(self._respawn_times) >= self.max_respawns:
            print(
                "[parent] max respawns ({}) within {} s reached, not respawning".format(
                    self.max_respawns, Float64(self.respawn_window_ns) / 1e9
                )
            )
            return self._give_up()

        # Rapid crash detection: if child died within 1 second of last fork
        var now = perf_counter_ns()
        var elapsed_ns = now - self.last_fork_ns
        if elapsed_ns < 1_000_000_000:  # 1 second
            self.rapid_crash_count += 1
            if self.rapid_crash_count >= 5:
                print("[parent] 5 rapid crashes detected, stopping respawn")
                return self._give_up()
        else:
            self.rapid_crash_count = 0

        self.respawn_count += 1
        self.last_fork_ns = perf_counter_ns()
        self._respawn_times.append(self.last_fork_ns)
        var respawn_index = self._last_freed_index
        var new_pid = fork()
        if new_pid == 0:
            # The replacement takes over the dead worker's index — and with
            # it the dead worker's bus channel and shared slots.
            self._become_worker(
                respawn_index,
                "[worker respawn {}] pid={} starting".format(respawn_index, getpid()),
            )
            self._exec_if_spawning(respawn_index)
            return _RESPAWN_CHILD
        if respawn_index >= 0 and respawn_index < len(self.child_pids):
            self.child_pids[respawn_index] = new_pid
            self._publish_children()
        print("[parent] respawned worker {} as pid={}".format(respawn_index, new_pid))
        return _RESPAWN_PARENT

    def _give_up(mut self) -> Int:
        """Leave the index just reaped vacant for good: `_RESPAWN_FAILED`.

        The exit becomes 1 (`_gave_up`), and every connection handed to that
        worker and not yet received is closed (review record RB).
        `_remove_pid` has marked the index gone, so no sibling sends there
        again; what was sent before waits in the channel, and with no
        replacement to read it, each client held an accepted connection that
        was never answered until the server stopped. Each is closed instead,
        and its client can retry (`close_reaped_handoffs`, which also waits
        out a send that raced the mark). Nothing more when accepts are not
        shared.
        """
        self._gave_up = True
        var index = self._last_freed_index
        if self._accept_page == 0 or index < 0:
            return _RESPAWN_FAILED
        if index >= len(self._accept_channels):
            return _RESPAWN_FAILED
        var closed = close_reaped_handoffs(
            self._accept_page, index, self._accept_channels[index],
            _REAPED_DRAIN_NS,
        )
        if closed > 0:
            print(
                "[parent] closed {} connection(s) handed to worker {} and"
                " never taken".format(closed, index)
            )
        return _RESPAWN_FAILED

    def _remove_pid(mut self, pid: Int):
        """Vacate a dead worker's index, remembering it for the respawn.

        The slot is set to -1 rather than removed: position is the worker
        index (see `child_pids`), so the list must never compact.

        Every reap passes here -- both supervision loops
        (`_account_for_exit`), `_reap_the_rest` and `_reload` -- so this is
        where the index is marked gone on the accept-share page
        (`share_accepts`), before anything decides whether to replace it.
        A replacement is forked after the mark and overwrites it in its
        `bind`.
        """
        for i in range(len(self.child_pids)):
            if self.child_pids[i] == pid:
                self.child_pids[i] = -1
                self._last_freed_index = i
                mark_reaped(self._accept_page, i)
                publish_child_pids(self.child_pids)
                return

    def _publish_children(self):
        """Publish the child PIDs, then pass on a stop the handler recorded first.

        The handler signals the PIDs published when it runs, so a stop that
        lands between a `fork` and the publish of its PID would never reach
        that child. The handler records the stop before it reads the list,
        so reading the stop after the publish closes the gap: either the
        stop is seen here, or the handler finds the PID. A worker signalled
        twice drains once.
        """
        publish_child_pids(self.child_pids)
        var sig = supervisor_stop_signal()
        if sig != 0:
            self._kill_all(sig)

    def _arm_signal_propagation(self):
        """Make a SIGTERM/SIGINT aimed at the parent alone reach the workers.

        Called before the first fork (`fork_all`). Publishes the child PIDs
        (none yet: `_publish_children` adds each as it is forked) where
        `_on_supervisor_signal` can read them, after verifying that the block
        round-trips, and only then installs the handler. A handler over a
        block that does not work would swallow SIGTERM and leave no way to
        stop the supervisor at all — strictly worse than the default
        behaviour, which is what declining leaves in place. See
        `src/global_slot.mojo` for when that can happen. The check writes a
        probe PID and reads it back, because an empty list reads back as the
        zero a dead block reads too; nothing is installed yet to act on it.
        """
        publish_child_pids([_SLOT_PROBE_PID])
        var live = child_pid_count() == 1 and child_pid_at(0) == _SLOT_PROBE_PID
        publish_child_pids(self.child_pids)
        if not live:
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


def int_list_env(name: String) -> List[Int]:
    """A comma-separated list of integers from the environment; bad parts skipped."""
    var out = List[Int]()
    var raw = getenv(name, "")
    if raw.byte_length() == 0:
        return out^
    for part in raw.split(","):
        var n = parse_env_int(part)
        if n:
            out.append(n.value())
    return out^


def spawn_inherited_env() -> List[String]:
    """The variables naming every descriptor a spawned worker adopts.

    `_exec_if_spawning` keeps exactly these across the spawn's exec, and the
    new image adopts exactly these (`prefork`, `m0serve`'s `_adopt_listener`),
    so what is kept and what is adopted are one list. A descriptor a future
    spawned worker must inherit goes here, or its adoption fails loudly: it
    is close-on-exec like everything else, and the exec closes it.
    """
    return [
        String("M0_LISTEN_FD"),
        String("M0_SHARED_ID_FD"),
        String("M0_BUS_READ_FDS"),
        String("M0_BUS_WRITE_FDS"),
        String("M0_ACCEPT_READ_FDS"),
        String("M0_ACCEPT_WRITE_FDS"),
    ]


def spawn_inherited_fds() -> List[Int]:
    """Every descriptor `spawn_inherited_env` names, in this process."""
    var fds = List[Int]()
    for name in spawn_inherited_env():
        for fd in int_list_env(name):
            fds.append(fd)
    return fds^
