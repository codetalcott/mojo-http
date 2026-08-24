"""The threaded execution mode: N event loops on N threads, one interpreter.

`M0_THREADS=N` (or `m0serve --threads N`) runs N serving threads in ONE
process instead of N forked workers — on free-threaded CPython only. Each
thread runs its own `run_event_loop` with its own handler, and therefore its
own `WSGIApp`, `PyBridge` and shim namespace: the bridge's per-process
singleton (the shim's `_body`, which keeps the last response alive while
Mojo reads it) becomes per-thread without changing a line of the bridge,
and the shared-dict namespace lookups the thread probe measured at 0.7x
never happen across threads. The event loop is
untouched: every per-slot structure is already a local of `run_event_loop`,
so a second thread calling it gets a second, disjoint loop for free.

What the mode buys: one process and one RSS instead of N copies, the app
imported once, no bus needed for in-process fan-out — and the whole class of
fork-after-init hazards gone: no fork-before-first-Python-call, no
`exit_worker()`, no `_scproxy` abort in a forked child. What it does NOT
buy is per-request balancing: a keep-alive connection stays pinned to the
loop that accepted it, exactly as under prefork, so the keep-alive p99 shape
is unchanged (that is the thread-pool stage recorded in ROADMAP.md).

**The discipline, which is the whole file:**

- The main thread initializes the interpreter and imports the application
  BEFORE spawning (`require_free_threading`, then the caller's pre-import),
  so the lazily-created interpreter handle exists and Django's `setup()`
  runs single-threaded. It then detaches with `PyEval_SaveThread` and
  touches no Python until every thread has been joined.
- Every serving thread attaches once with `PyGILState_Ensure` for its
  lifetime (CPython's free-threading guide: foreign threads still need an
  attached thread state even with the GIL gone), builds its handler INSIDE
  that region, and destroys it there too — `PythonObject` destructors need
  the thread state — before releasing.
- A thread must not block while attached: an attached thread that sleeps in
  a syscall stalls every other thread's stop-the-world pauses. The loop's
  only blocking point is `backend.wait()`, and `DetachingBackend` wraps it
  in `PyEval_SaveThread` / `PyEval_RestoreThread` — the
  `Py_BEGIN_ALLOW_THREADS` pattern, nested inside the Ensure region. Two
  cheap calls per loop *pass*, not per request.
- A GIL-enabled interpreter refuses to start. A thread pool under the GIL
  is strictly worse than prefork, and running it silently would mislead
  every benchmark; Granian's policy, adopted. Exit 78 (`EX_CONFIG`).

Shutdown: the process-wide signal pipe (`install_shutdown_signals`, once,
on main) wakes the coordinator — the main thread, blocked in `read(2)`
while detached, which is safe — and it pokes one shutdown pipe per thread
(`ShutdownFanout`): the loop never drains its pipe, so N loops cannot share
one. Each loop drains as it always has, the thread releases its state, and
main joins them all, reattaches, and reports.

Per-process: the interpreter and `sys.modules`; signal dispositions and the
shutdown slot; `SharedAtomics` (still just memory); the listener socket
(one description, N dups — the loop closes its listener on shutdown, and a
dup makes that a per-thread close; on Linux those N dups land in N epoll
instances under `EPOLLET`, and the canary's phase D shows every one of them
waking, so `EPOLLEXCLUSIVE` is not needed to spread accepts). Per-thread:
the event loop and every slot array, the kqueue/epoll fd, the
`ProvisionPool`, `ServerMetrics` (so `/__metrics` is per-thread), the
handler with everything it owns, the shutdown pipe, the Python thread
state.
"""

from std.python import Python, PythonObject
from std.sys.info import CompilationTarget

from lightbug_http import HTTPService
from lightbug_http.c.process import process_exit
from lightbug_http.event_loop import run_event_loop
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.offload import OffloadPool
from lightbug_http.server_config import ServerConfig

from .blocking_pool import BlockingPool
from .thread_handler import ThreadContext, ThreadHandler

from m0_http import (
    ThreadSet, ThreadBlock, ShutdownFanout, dup_fd, read_one_byte_blocking,
    BLK_INDEX, BLK_LISTEN_FD, BLK_SHUTDOWN_FD, BLK_BUS_FD, BLK_USER,
    BLK_STATUS, STATUS_OK, STATUS_RAISED,
)


comptime EXIT_NOT_FREE_THREADED = 78
"""The sysexits `EX_CONFIG` code: the interpreter cannot run this mode."""

comptime BLK_SERVER = 6
"""Block slot holding the `ThreadedServer`'s address (config and address)."""

comptime _PROBE_SOURCE = """
import sys, sysconfig


def info():
    build_ft = sysconfig.get_config_var('Py_GIL_DISABLED') or 0
    gil_on = getattr(sys, '_is_gil_enabled', lambda: True)()
    return ('%d.%d.%d' % sys.version_info[:3],
            '1' if build_ft else '0',
            'True' if gil_on else 'False')
"""


struct FreeThreadingReport(Copyable, Movable):
    """What the interpreter says about itself."""

    var version: String
    var free_threaded_build: Bool
    var gil_enabled: Bool

    def __init__(out self, var version: String, free_threaded_build: Bool, gil_enabled: Bool):
        self.version = version^
        self.free_threaded_build = free_threaded_build
        self.gil_enabled = gil_enabled


def probe_free_threading() raises -> FreeThreadingReport:
    """Ask the interpreter whether the GIL is enabled.

    This is a Python call — on a fresh process, the first one, which is
    what initializes the interpreter on the calling thread. Call it on main.
    `sys._is_gil_enabled` is 3.13+; an older interpreter has no way to be
    free-threaded and reports the GIL enabled.
    """
    var builtins = Python.import_module("builtins")
    var ns = Python.dict()
    builtins.exec(PythonObject(_PROBE_SOURCE), ns)
    var info = ns["info"]()
    return FreeThreadingReport(
        String(py=info[0]),
        String(py=info[1]) == "1",
        String(py=info[2]) == "True",
    )


def refusal_message(threads: Int, report: FreeThreadingReport) -> String:
    """The one sentence a GIL-enabled interpreter gets. Names the fix."""
    var why = String(
        "this is not a free-threaded build"
        if not report.free_threaded_build
        else "the GIL is enabled (PYTHON_GIL=1?)"
    )
    return String(
        "m0-wsgi: M0_THREADS=" + String(threads)
        + " requires free-threaded CPython (3.13t+ with the GIL disabled);"
        + " running " + report.version + " and " + why
        + ". Use M0_WORKERS for prefork on this interpreter."
    )


def require_free_threading(threads: Int) raises:
    """Refuse to start a threaded mode the interpreter cannot run.

    No-op for `threads <= 1`. Otherwise probes the interpreter — the
    process's first Python call, on the calling thread — and on a
    GIL-enabled one prints `refusal_message` and exits
    `EXIT_NOT_FREE_THREADED`. Never warns-and-runs, never falls back.
    """
    if threads <= 1:
        return
    var report = probe_free_threading()
    if report.gil_enabled:
        print(refusal_message(threads, report), flush=True)
        process_exit(EXIT_NOT_FREE_THREADED)


struct DetachingBackend[B: EventLoopBackend & Movable & Deinitable](EventLoopBackend, Movable):
    """An event-loop backend whose `wait` releases the thread state.

    Everything forwards to the wrapped backend; only `wait` differs, and it
    is the only place the loop blocks. Detaching around it is what keeps a
    parked thread from stalling the others' stop-the-world pauses.
    """

    var inner: Self.B

    def __init__(out self, var inner: Self.B):
        self.inner = inner^

    def __init__(out self, *, deinit move: Self):
        self.inner = move.inner^

    def wait(mut self, timeout_ms: Int) raises -> Int:
        ref cpy = Python().cpython()
        var ts = cpy.PyEval_SaveThread()
        var n: Int
        try:
            n = self.inner.wait(timeout_ms)
        except e:
            cpy.PyEval_RestoreThread(ts)
            raise e^
        cpy.PyEval_RestoreThread(ts)
        return n

    def event_ident(self, i: Int) -> UInt:
        return self.inner.event_ident(i)

    def event_filter(self, i: Int) -> Int16:
        return self.inner.event_filter(i)

    def event_flags(self, i: Int) -> UInt16:
        return self.inner.event_flags(i)

    def event_data(self, i: Int) -> Int:
        return self.inner.event_data(i)

    def add_read_listen(mut self, fd: Int) raises:
        self.inner.add_read_listen(fd)

    def add_read(mut self, fd: Int) raises:
        self.inner.add_read(fd)

    def try_add_read(mut self, fd: Int):
        self.inner.try_add_read(fd)

    def add_write_oneshot(mut self, fd: Int) raises:
        self.inner.add_write_oneshot(fd)

    def try_add_write_oneshot(mut self, fd: Int):
        self.inner.try_add_write_oneshot(fd)

    def try_delete_read(mut self, fd: Int):
        self.inner.try_delete_read(fd)

    def try_delete_write(mut self, fd: Int):
        self.inner.try_delete_write(fd)

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        self.inner.try_add_timer(ident, timeout_ms)

    def try_delete_timer(mut self, ident: UInt):
        self.inner.try_delete_timer(ident)


struct ThreadedServer(Movable):
    """Run N event loops on N threads against one listener.

        var server = ThreadedServer(config, address, listener.socket.fd.value)
        var failed = server.serve[MyHandler](threads, spec_addr, shutdown_fd)

    `MyHandler.make(ctx)` (the `ThreadHandler` trait) is called ON each
    serving thread, attached, with `ctx.user` = `spec_addr`; it constructs
    the thread's own `WSGIApp` (the module is already imported, so that is
    a `sys.modules` hit and a fresh shim namespace). `serve` returns once
    the signal pipe has fired and every thread has been joined, with the
    count of threads that did not end cleanly.
    """

    var config: ServerConfig
    var address: String
    var listen_fd: Int
    var bus_read_fds: List[Int]
    """Per-thread bus channels for in-process fan-out; empty = no bus."""

    var blocking_threads: Int
    """Handler threads EACH loop spawns (`--blocking-threads`); 0 = off.

    Per loop rather than per process: a job names a slot, and a slot means
    nothing outside the loop whose provision pool it indexes. `--threads 4
    --blocking-threads 4` is therefore four pools of four, not one of four.
    """

    def __init__(out self, var config: ServerConfig, var address: String, listen_fd: Int):
        self.config = config^
        self.address = address^
        self.listen_fd = listen_fd
        self.bus_read_fds = List[Int]()
        self.blocking_threads = 0

    def __init__(out self, *, deinit move: Self):
        self.config = move.config^
        self.address = move.address^
        self.listen_fd = move.listen_fd
        self.bus_read_fds = move.bus_read_fds^
        self.blocking_threads = move.blocking_threads

    def serve[
        T: ThreadHandler
    ](mut self, threads: Int, user: Int, signal_read_fd: Int) raises -> Int:
        """Spawn, wait for the stop signal, fan it out, join. See the struct."""
        if signal_read_fd < 0:
            raise Error(
                "ThreadedServer.serve needs the signal pipe from"
                " install_shutdown_signals(); nothing else can stop the threads"
            )
        var fanout = ShutdownFanout(threads)
        var set = ThreadSet(threads)
        var self_ptr = Pointer(to=self)
        var self_addr = Pointer(to=self_ptr).unsafe_bitcast[Int]()[]
        for i in range(threads):
            var block = set.block(i)
            block.set(BLK_LISTEN_FD, dup_fd(self.listen_fd))
            block.set(BLK_SHUTDOWN_FD, fanout.read_fd(i))
            block.set(
                BLK_BUS_FD,
                self.bus_read_fds[i] if i < len(self.bus_read_fds) else -1,
            )
            block.set(BLK_USER, user)
            block.set(BLK_SERVER, self_addr)

        # Main detaches; from here until join, no Python on this thread.
        ref cpy = Python().cpython()
        var main_ts = cpy.PyEval_SaveThread()

        var body = _thread_body[T]
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        for i in range(threads):
            set.spawn(i, body_addr)
        print(
            "threaded: " + String(threads) + " loops on " + self.address,
            flush=True,
        )

        # The coordinator: sleep until the signal handler writes its byte.
        _ = read_one_byte_blocking(signal_read_fd)
        fanout.notify_all()
        set.join_all()
        cpy.PyEval_RestoreThread(main_ts)

        var failed = 0
        for i in range(threads):
            if set.status(i) == STATUS_OK:
                print("thread[" + String(i) + "] exited cleanly", flush=True)
            else:
                failed += 1
                print("thread[" + String(i) + "] did not exit cleanly", flush=True)
        return failed


def _serve_one[T: ThreadHandler](block: ThreadBlock) raises:
    """One thread's whole life, inside its attached region.

    Separate from `_thread_body` so the handler — and every `PythonObject`
    it owns — is destroyed when this scope ends, which is before the caller
    releases the thread state.
    """
    var server = Pointer[ThreadedServer, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_SERVER)
    )
    var ctx = ThreadContext(block.get(BLK_INDEX), block.get(BLK_USER))
    var handler = T.make(ctx)
    print("thread[" + String(ctx.index) + "] serving", flush=True)
    var listen = FileDescriptor(block.get(BLK_LISTEN_FD))

    # `--blocking-threads`: this loop's own queue and its own handler threads.
    # Built before the loop because the threads hold the pool's address for
    # their whole lives, and retired after it, so an in-flight job always has
    # somewhere to land.
    var blocking = server[].blocking_threads
    var pool = OffloadPool(server[].config.max_connections if blocking > 0 else 0)
    var pool_addr = pool.addr() if blocking > 0 else 0
    var pool_threads = BlockingPool(blocking)
    if blocking > 0:
        pool_threads.start[T](pool_addr, ctx.user)

    comptime if CompilationTarget.is_macos():
        from lightbug_http.c.kqueue_backend import KqueueBackend
        var backend = DetachingBackend[KqueueBackend](KqueueBackend())
        run_event_loop(
            listen, handler, backend, server[].config, server[].address, True,
            block.get(BLK_SHUTDOWN_FD), block.get(BLK_BUS_FD), pool_addr,
        )
    else:
        from lightbug_http.c.epoll_backend import EpollBackend
        var backend = DetachingBackend[EpollBackend](EpollBackend())
        run_event_loop(
            listen, handler, backend, server[].config, server[].address, True,
            block.get(BLK_SHUTDOWN_FD), block.get(BLK_BUS_FD), pool_addr,
        )

    if blocking > 0:
        # Detached across it: a pool thread finishing its last job needs to
        # attach, and it cannot while this thread holds a state and blocks.
        ref cpy = Python().cpython()
        var join_ts = cpy.PyEval_SaveThread()
        var failed = pool_threads.stop_and_join(pool)
        cpy.PyEval_RestoreThread(join_ts)
        if failed > 0:
            print(
                "thread[" + String(ctx.index) + "] " + String(failed)
                + " blocking thread(s) did not exit cleanly",
                flush=True,
            )
    # `pool` must outlive the join — a thread still finishing a job writes
    # into it. This use is what keeps destroy-at-last-use from freeing it
    # somewhere above.
    _ = pool.capacity

    # After the loop and the pool join, before the handler's destructors:
    # attached, idle, and still owning the app.
    handler.shutdown()


def _thread_body[T: ThreadHandler](arg: Int) -> Int:
    """pthread start routine: attach, serve, release, report."""
    var block = ThreadBlock(arg)
    ref cpy = Python().cpython()
    var gs = cpy.PyGILState_Ensure()
    var status = STATUS_RAISED
    try:
        _serve_one[T](block)
        status = STATUS_OK
    except e:
        print(
            "thread[" + String(block.get(BLK_INDEX)) + "] raised: " + String(e),
            flush=True,
        )
    cpy.PyGILState_Release(gs)
    block.set(BLK_STATUS, status)
    return 0
