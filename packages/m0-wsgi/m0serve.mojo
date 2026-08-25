"""`m0serve` — serve any WSGI application from one built binary.

    uv run poe build-serve                                        # -> bin/m0serve
    bin/m0serve myproject.wsgi:application --app-dir /path/to/project \\
        --host 0.0.0.0 --port 8000 --workers 4 --static /static/=/path/to/static

The uvicorn-shaped entry point. `MODULE[:ATTR]` names the callable (ATTR
defaults to `application`), `--app-dir` is prepended to `sys.path` so the
module can be imported, and every `M0_*` environment variable keeps its
meaning with the matching flag winning over it. `--help` lists the rest.

**Why this file lives at the package root, outside `src/`.** It is a
compiled entry file, the same shape as `packages/m0-core/ffi_exports.mojo`
and for the same reasons: `mojo precompile src` never sees it, so it cannot
land inside `m0_wsgi.mojoc`, and it imports `m0_wsgi` through that `.mojoc`
rather than through `src.*` — an entry file outside any package resolves
`src` by the first `-I` root, which is exactly the fragility every package's
`test_resolution.mojo` exists to catch. `build-apps`'s `apps/*/server.mojo`
glob never sees it either, which is why `poe build-serve` is its own task.

**The order of `main()` is the load-bearing part.** Bind the listener first,
so every worker inherits one shared socket and connections land on workers
that are free to take them (gunicorn's model; per-worker `SO_REUSEPORT` binds
do not distribute on macOS and hash blind on Linux). Fork second, BEFORE any
Python: Mojo initializes the interpreter lazily on first use, forking a live
CPython is unsafe, and so each worker's own `WSGIApp` construction after
`fork_all()` returns must stay the process's first Python call. Everything
that can be validated without an interpreter — the flags, the directories —
is validated before the bind, so a typo fails in milliseconds with a message
that names it rather than as an `ImportError` five frames deep.

`func` runs the application synchronously on the event loop, so a process
serves one request at a time and a slow view stalls its whole process;
concurrency is `--workers`. A forked worker must end with `exit_worker()`,
never by returning from `main` — the runtime's teardown reaches into
libdispatch, which is unusable in a process forked without exec.

**`--reload` forces a supervisor**, even at one worker and even under
`--threads N`, because something has to outlive the process it restarts.
That composes with both modes for one reason: the supervisor never touches
Python. It watches files with `listdir` and `stat`, which is libc and
therefore allowed in a process forked without exec, and the fork still
precedes the first Python call because the supervisor never makes one. What
reloads is the *worker* — a fresh interpreter importing the changed module.
The Mojo binary is never re-exec'd, so a changed `.mojo` still needs a
rebuild and a restart.
"""

from std.os import getenv, setenv
from std.os.path import isdir, isfile
from std.python import Python
from std.sys.arg import argv
from std.sys.info import CompilationTarget

from lightbug_http import Server
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.event_loop import run_event_loop
from lightbug_http.offload import OffloadPool
from lightbug_http.connection import ListenConfig, NoTLSListener
from lightbug_http.address import NetworkType
from lightbug_http.c.process import process_exit
from lightbug_http.server_config import ServerConfig

from m0_http import (
    StaticFiles, WorkerSupervisor, install_shutdown_signals, exit_worker,
    threads_conflict,
)
from m0_http.config import AppConfig
from m0_http.multiworker import SharedAtomics
from m0_wsgi import (
    WSGIApp, WSGIHandler, ServeOptions, parse_args, parse_app_spec, usage,
    ThreadedServer, require_free_threading, BlockingPool, DetachingBackend,
    AsgiExecutor, detect_protocol, discovery_specs, resolve_blocking_threads,
    zero_config_topology, use_asgi_executor, effective_cpus,
    M0SERVE_VERSION, DEFAULT_PORT, EXIT_USAGE, EXIT_STARTUP, PROTOCOL_ASGI,
)


def _fail(message: String, code: Int):
    """Report and exit with `code`.

    `process_exit` is `_exit(2)`: no atexit, no unwinding — which is what a
    forked worker needs (the runtime's teardown is unusable after fork) and
    harmless everywhere else, because every message is flushed first. (The
    stdlib's `exit` was tried and the status did not reach the shell.)
    """
    print("m0serve: " + message, flush=True)
    process_exit(code)


def _discover_core_lib() -> String:
    """Where `libm0core` is, for `m0pub`'s `ctypes` lookup. Empty = not found.

    Only consulted under `--realtime`, and only when `M0_CORE_LIB` is not
    already set. The library holds `m0_shared_fetch_add`, which is how a
    Python publisher takes a globally unique event id from the shared slot —
    Python has no atomic read-modify-write over a raw address, and a racy one
    would hand two workers the same id. Without it publishing still works;
    frames go out unnumbered, which costs duplicate suppression on reconnect.

    Two candidates, most specific first: beside the binary (how a built
    `bin/m0serve` ships), then `poe build-ffi`'s output relative to the
    working directory (how the repo runs). `m0pub` has the same fallbacks,
    so an unset variable is not a failure — exporting it just means the
    lookup cannot be defeated by the working directory.
    """
    var ext = String(".dylib") if CompilationTarget.is_macos() else String(".so")
    var candidates = List[String]()
    var exe = String(argv()[0])
    var slash = exe.rfind("/")
    if slash >= 0:
        candidates.append(
            String(StringSlice(exe)[byte = :slash]) + "/libm0core" + ext
        )
    candidates.append(String("packages/m0-core/libm0core") + ext)
    for i in range(len(candidates)):
        if isfile(candidates[i]):
            return candidates[i]
    return String("")


comptime _REALTIME_ASGI_CONFLICT = (
    "--realtime requires a WSGI application: the M0-Hold contract is a"
    " response-header protocol for buffered WSGI responses, and an ASGI"
    " application streams through its own send() instead. Serve it without"
    " --realtime."
)

comptime _REALTIME_MOUNT_CONFLICT = (
    "--realtime cannot be combined with --mount: M0-Hold subscribes the"
    " connection to registries the loop's handler owns, and an inbound"
    " WebSocket message is delivered back into ONE application's urlconf."
    " Which mount should receive it has no defensible answer, so it is"
    " refused rather than guessed. Serve the realtime application on its"
    " own."
)


def _specs_tried(specs: List[String]) -> String:
    """The discovery candidates as one comma-separated list, for errors."""
    var joined = String("")
    for i in range(len(specs)):
        if i > 0:
            joined += ", "
        joined += specs[i]
    return joined^


def _resolve_spec(mut opts: ServeOptions) raises -> Bool:
    """Import, resolve discovery, and detect the protocol — no lifespan.

    An explicit `MODULE:ATTR` detects exactly what it names. A bare
    `MODULE` tries the `discovery_specs` conventions in order — Django's
    `asgi.py`/`wsgi.py` and the `main:app` shape — and the first one that
    imports and classifies wins; `opts` is updated to the winner so the
    banner and the per-thread handlers name what is actually being served.
    On a total miss, the primary spec's own error leads and every
    candidate tried is listed.

    Detection is deliberately separate from `WSGIApp` construction: the
    executor mode's decision needs the protocol BEFORE any bridge exists,
    so that exactly one lifespan runs per event loop (the executor's), not
    one per candidate tried. The caller must have put `--app-dir` on
    `sys.path`; the imports here are `sys.modules` hits for everything
    that follows.
    """
    if opts.attribute_explicit:
        return detect_protocol(opts.module, opts.attribute, opts.protocol)
    var specs = discovery_specs(opts.module)
    var first_error = String("")
    for i in range(len(specs)):
        var pair = parse_app_spec(specs[i])
        try:
            var is_asgi = detect_protocol(pair[0], pair[1], opts.protocol)
            opts.module = pair[0]
            opts.attribute = pair[1]
            return is_asgi
        except e:
            if i == 0:
                first_error = String(e)
    raise Error(first_error + " (tried " + _specs_tried(specs) + ")")


def _resolve_mounts(mut opts: ServeOptions) raises -> Bool:
    """Detect every mount's protocol; returns True when they are all ASGI.

    Each mount resolves independently — discovery included, so
    `--mount /=djangoproj` finds `djangoproj.wsgi` exactly as a positional
    spec would — and the winner is written back so the banner and every
    handler name what is actually served.

    Mixed WSGI/ASGI mounts are the point: each gets its native execution
    mode, so `opts.asgi_mounts` records which mounts are ASGI rather than
    reducing detection to one answer for the process. Any number of each:
    every ASGI mount gets its own executor, on its own submit lane, with
    its own drain-ack pair — the chunk channel is the one thing executors
    share, and its datagrams are slot-addressed.
    """
    var asgi_count = 0
    for i in range(len(opts.mount_prefixes)):
        var module = opts.mount_modules[i]
        var attribute = opts.mount_attributes[i]
        var is_asgi: Bool
        if opts.mount_explicit[i]:
            is_asgi = detect_protocol(module, attribute, opts.protocol)
        else:
            var specs = discovery_specs(module)
            var first_error = String("")
            var found = False
            is_asgi = False
            for k in range(len(specs)):
                var pair = parse_app_spec(specs[k])
                try:
                    is_asgi = detect_protocol(pair[0], pair[1], opts.protocol)
                    opts.mount_modules[i] = pair[0]
                    opts.mount_attributes[i] = pair[1]
                    found = True
                    break
                except e:
                    if k == 0:
                        first_error = String(e)
            if not found:
                raise Error(
                    first_error + " (tried " + _specs_tried(specs) + ")"
                )
        if is_asgi:
            asgi_count += 1
            opts.asgi_mounts.append(i)
    return asgi_count > 0


def _asgi_mount_names(opts: ServeOptions) -> String:
    """`/app,/api` — the mounts whose lanes executors read, for the banner."""
    var out = String("")
    for k in range(len(opts.asgi_mounts)):
        if k > 0:
            out += ","
        ref prefix = opts.mount_prefixes[opts.asgi_mounts[k]]
        out += "/" if prefix.byte_length() == 0 else prefix
    return out^


def _wsgi_lanes(opts: ServeOptions) -> List[Int]:
    """Every mount except the ASGI one — the lanes the pool threads serve."""
    var lanes = List[Int]()
    for i in range(len(opts.mount_prefixes)):
        var is_asgi_lane = False
        for k in range(len(opts.asgi_mounts)):
            if opts.asgi_mounts[k] == i:
                is_asgi_lane = True
                break
        if not is_asgi_lane:
            lanes.append(i)
    return lanes^


def _reload_dirs(opts: ServeOptions) -> List[String]:
    """What `--reload` watches: `--reload-dir` if given, else `--app-dir`.

    `--app-dir` is the right default because it is already the directory the
    application is imported from — the one place a `.py` edit can change
    what a worker serves.
    """
    if len(opts.reload_dirs) > 0:
        return opts.reload_dirs.copy()
    var dirs = List[String]()
    dirs.append(opts.app_dir)
    return dirs^


def _prepare_realtime(opts: ServeOptions, channels: Int) raises -> BroadcastBus:
    """Everything `--realtime` must create BEFORE the fork and before Python.

    Returns the bus (size 0, and therefore inert, when the mode is off).

    Three exports, and the ordering rule is the same for all of them: they
    must precede the fork so every worker's environment agrees, and they must
    precede any Python touch because CPython snapshots the C environ at
    interpreter init. Under `--threads` there is no fork, but the second half
    still binds — the interpreter comes up inside `require_free_threading`.

    `channels` is `--workers` under prefork and `--threads` under the threaded
    mode. The bus does not care which: a `SOCK_DGRAM` socketpair delivers the
    same whether the peer draining it is another process or another thread.
    """
    if not opts.realtime:
        return BroadcastBus(0)

    var bus = BroadcastBus(channels)
    var fds_csv = String("")
    for i in range(len(bus.write_fds)):
        if i > 0:
            fds_csv += ","
        fds_csv += String(bus.write_fds[i])
    _ = setenv("M0_BUS_WRITE_FDS", fds_csv, True)

    # One MAP_SHARED slot: the event id every publish takes a number from.
    # Shared memory across processes, and plain memory across threads.
    var shared = SharedAtomics(1)
    _ = setenv("M0_SHARED_ID_ADDR", String(shared.addr(0)), True)

    if getenv("M0_CORE_LIB", "").byte_length() == 0:
        var lib = _discover_core_lib()
        if lib.byte_length() > 0:
            _ = setenv("M0_CORE_LIB", lib, True)

    return bus^


def main() raises:
    var args = List[String]()
    var raw = argv()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))

    var opts: ServeOptions
    try:
        opts = parse_args(args, ServeOptions.from_env())
    except e:
        print(usage(), flush=True)
        _fail(String(e), EXIT_USAGE)
        return
    if opts.show_help:
        print(usage(), flush=True)
        return
    if opts.show_version:
        print("m0serve " + M0SERVE_VERSION, flush=True)
        return

    # Everything checkable without an interpreter, checked before the bind.
    if not isdir(opts.app_dir):
        _fail("app dir does not exist: " + opts.app_dir, EXIT_STARTUP)
    for i in range(len(opts.static_dirs)):
        if not isdir(opts.static_dirs[i]):
            _fail("static dir does not exist: " + opts.static_dirs[i], EXIT_STARTUP)
    for i in range(len(opts.reload_dirs)):
        if not isdir(opts.reload_dirs[i]):
            _fail("reload dir does not exist: " + opts.reload_dirs[i], EXIT_STARTUP)

    var conflict = threads_conflict(opts.workers, opts.threads)
    if conflict:
        print(usage(), flush=True)
        _fail(conflict.value(), EXIT_USAGE)

    # `--blocking-threads` moves `func` onto a pool thread, but the streaming
    # hooks — `sse_drain_slot`, `sse_slot_disconnected`, `ws_message` — are
    # called on the LOOP's handler, which owns a different `SSERegistry` and a
    # different `WSHub`. A stream opened by a pool thread's handler would be
    # invisible to the loop that has to feed it. Refused rather than half-wired,
    # which is the same call `--threads` makes about a GIL-enabled interpreter.
    if opts.blocking_threads > 0 and opts.realtime:
        print(usage(), flush=True)
        _fail(
            "--blocking-threads and --realtime are mutually exclusive:"
            " the streaming hooks run on the event loop's handler, and a pool"
            " thread's handler has its own registries. Drop one.",
            EXIT_USAGE,
        )

    # The forced half of the ASGI/realtime refusal is checkable without an
    # interpreter; the auto-detected half fails after the app loads, with
    # the same message.
    if opts.protocol == PROTOCOL_ASGI and opts.realtime:
        print(usage(), flush=True)
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_USAGE)

    # Bind before forking; every worker accepts from this one socket.
    var listener = ListenConfig().listen(opts.address())

    # Then everything `--realtime` shares, still before the fork and still
    # before the first Python call. Inert without the flag.
    var channels = opts.threads if opts.threads > 1 else opts.workers
    var bus = _prepare_realtime(opts, channels)

    # Fork before touching Python — see the module docstring. The parent
    # stays inside fork_all() supervising; only workers return here.
    #
    # `--reload` forces a supervisor even for one worker and even under
    # `--threads`, because something has to outlive the process it
    # restarts. That is safe for exactly the reason the prefork rule is:
    # the supervisor never touches Python. It watches files with `listdir`
    # and `stat`, which are libc, and a process forked without `exec` may
    # use those. `--threads` and `--workers>1` are mutually exclusive, so
    # `opts.workers` is 1 under threads and the supervisor manages the one
    # multi-threaded child.
    var multiprocess = opts.workers > 1
    var supervised = multiprocess or opts.reload
    var worker = 0
    if opts.reload:
        # Set before the fork and before the first Python call, because the
        # interpreter reads it once at startup.
        #
        # Without it `--reload` can serve stale code, and the way it does is
        # not obvious. CPython validates a cached `.pyc` against the source's
        # mtime **in whole seconds** and its size; a rewrite that lands in
        # the same second at the same length therefore looks unchanged to the
        # import system even though the file on disk is different. The
        # reloader notices (it compares nanoseconds), re-forks, and the fresh
        # worker imports the *old* bytecode — a reload that visibly happened
        # and changed nothing. Writing no bytecode at all means there is
        # never a cache to go stale. The cost is slower imports on a
        # development-only flag.
        _ = setenv("PYTHONDONTWRITEBYTECODE", "1", True)
    if supervised:
        var supervisor = WorkerSupervisor(opts.workers)
        if opts.reload:
            supervisor.enable_reload(_reload_dirs(opts), String(".py"))
        supervisor.fork_all()
        worker = supervisor.worker_index

    if opts.threads > 1:
        # The listener is borrowed, not reduced to its fd: its last use would
        # otherwise be that read, and Mojo's destroy-at-last-use would close
        # the listening socket before the threads dup it — the dup then lands
        # on whatever descriptor number the kernel recycled, and four loops
        # watch a pipe. Prefork never hits this because `serve_nonblocking`
        # uses the listener itself, later.
        _serve_threaded(opts, listener, bus)
        if supervised:
            # Forked, so it must leave through `exit_worker()` — returning
            # from `main` runs a teardown that reaches into libdispatch.
            exit_worker()
        return

    # The first Python call in this process: put --app-dir on sys.path and
    # resolve the spec + protocol, WITHOUT building a bridge — the executor
    # decision below needs the protocol before any lifespan may run.
    var is_asgi: Bool
    try:
        if opts.app_dir.byte_length() > 0:
            Python.add_to_path(opts.app_dir)
        if len(opts.mount_prefixes) > 0:
            is_asgi = _resolve_mounts(opts)
        else:
            is_asgi = _resolve_spec(opts)
    except e:
        _fail(
            "could not load " + opts.served() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return

    if is_asgi and opts.realtime:
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_STARTUP)
    if len(opts.mount_prefixes) > 0 and opts.realtime:
        _fail(_REALTIME_MOUNT_CONFLICT, EXIT_STARTUP)

    # Zero-config: with no topology flag or M0_* topology variable at all,
    # the protocol picks the concurrency — a pool for WSGI, the asyncio
    # executor for ASGI. Detection had to run first, which is why this
    # sits after the resolve (and, under prefork, inside each worker;
    # every worker resolves the same app to the same answer).
    var auto_pool = zero_config_topology(opts)
    opts.blocking_threads = resolve_blocking_threads(
        opts, is_asgi, effective_cpus()
    )
    var executor_mode = use_asgi_executor(opts, is_asgi)
    # In executor mode the loop's own handler is the queue-overflow
    # fallback: its bridge gets a loop but no lifespan, so the executor's
    # app owns the one lifespan this process runs. Its registries do size
    # up, though — they are the outboxes ASGI response chunks ride.
    opts.handler_lifespan = not executor_mode
    opts.asgi_streaming = executor_mode

    var handler: WSGIHandler
    try:
        handler = WSGIHandler.build(
            opts,
            multiprocess=multiprocess,
            multithread=False,
            lifespan=not executor_mode,
        )
    except e:
        _fail(
            "could not load " + opts.served() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return

    print(
        "m0serve: " + opts.served() + " on http://" + opts.address()
        + " (protocol=" + ("asgi" if is_asgi else "wsgi")
        + " workers=" + String(opts.workers) + ")"
        + (
            (" asgi-loop@" + _asgi_mount_names(opts))
            if (executor_mode and len(opts.asgi_mounts) > 0)
            else (" asgi-loop" if executor_mode else "")
        )
        + (
            " blocking-threads=" + String(opts.blocking_threads)
            + (" (auto)" if auto_pool else "")
            if opts.blocking_threads > 0 else ""
        )
        + (" realtime" if opts.realtime else "")
        + (" reload" if opts.reload else ""),
        flush=True,
    )
    var server_config = opts.server_config(AppConfig(default_port=DEFAULT_PORT))
    # After fork_all — each worker arms its own pipe.
    var shutdown_fd = install_shutdown_signals()

    var mounted_mix = (
        len(opts.mount_prefixes) > 0 and len(opts.asgi_mounts) > 0
    )
    if executor_mode or opts.blocking_threads > 0 or mounted_mix:
        # Offloaded serving under prefork: this process gets one acceptor
        # loop and either the asyncio executor (ASGI) or a handler pool.
        # The threads are spawned AFTER `fork_all()` returned and after the
        # resolve above made this process's first Python call, so the
        # prefork rule is untouched — a forked child that then makes
        # threads is fine; a threaded parent that then forks is not.
        _serve_offloaded(
            opts, listener, handler, server_config, shutdown_fd,
            executor_mode,
            asgi_lanes=opts.asgi_mounts.copy(),
            wsgi_lanes=_wsgi_lanes(opts),
        )
        # The loop's own handler serves the inline fallback; in executor
        # mode its lifespan never ran, and shutdown just closes its loop.
        handler.shutdown()
        if supervised:
            exit_worker()
        return

    var server = Server(server_config^)
    # `bus.read_fd` answers -1 off the flag, which is what "no bus" means to
    # the loop. Passed unconditionally under `--realtime`, single worker
    # included: draining our own channel IS local delivery, because `m0pub`
    # writes every channel including the publisher's. There is no second
    # delivery path to keep in sync with this one.
    server.serve_nonblocking(
        listener, handler,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
    )
    handler.shutdown()
    if supervised:
        exit_worker()


def _serve_offloaded(
    opts: ServeOptions,
    listener: NoTLSListener[NetworkType.tcp4],
    mut handler: WSGIHandler,
    config: ServerConfig,
    shutdown_fd: Int,
    executor: Bool,
    var asgi_lanes: List[Int] = List[Int](),
    var wsgi_lanes: List[Int] = List[Int](),
) raises:
    """One acceptor loop feeding either a handler pool or the executor.

    `--blocking-threads N` (WSGI, or the ASGI escape hatch) puts N handler
    threads behind the loop; `executor` puts the one asyncio-executor
    thread there instead — both speak the same `OffloadPool`, so the loop
    is identical either way.

    `Server.serve_nonblocking` is bypassed for one reason — the backend has to
    be a `DetachingBackend`. A loop that sits in `kevent`/`epoll_wait` while
    attached to the interpreter holds a thread state the receiving threads
    need, and under a GIL-enabled CPython that is not a slowdown but a
    deadlock: nothing behind the queue would ever run. The wrapper is two
    calls per loop *pass*.

    With `--mount`, both run AT ONCE: `asgi_lanes` names the mounts that
    get an executor each and `wsgi_lanes` the mounts the pool threads
    serve, so sync applications and async ones share this loop, this
    listener and this shutdown while each keeps its native concurrency.
    That is the whole point of mounts, and it is only expressible because
    a lane is a submit channel rather than a mode for the process.

    Several executors share ONE chunk channel — datagrams are
    slot-addressed and the queue is globally FIFO, so the recycled-slot
    safety argument survives two writers — but each gets its own drain-ack
    pair (`enable_stream_ack`): credit belongs to the executor that owns
    the slot, and an ack routed anywhere else is a stream stalled forever.

    No bus channel is passed, because `--realtime` is refused with both of
    these modes and the bus exists only for `--realtime`.
    """
    var pool = OffloadPool(config.max_connections)
    var mounted = len(opts.mount_prefixes) > 0
    if mounted:
        # Lane i is mount i, so the loop's `submit(slot, path)` and the
        # handler's `app_for(path)` cannot disagree: both ask
        # `match_path_prefix` the same question about the same table.
        for i in range(len(opts.mount_prefixes)):
            pool.add_lane(opts.mount_prefixes[i])
    var pool_count = (
        opts.blocking_threads
        if (len(wsgi_lanes) > 0 or not executor) else 0
    )
    var pool_threads = BlockingPool(0 if (executor and not mounted) else pool_count)
    var exec_thread = AsgiExecutor(
        len(asgi_lanes) if len(asgi_lanes) > 0 else 1
    )
    var opts_ptr = Pointer(to=opts)
    var opts_addr = Pointer(to=opts_ptr).unsafe_bitcast[Int]()[]
    var run_executor = executor or len(asgi_lanes) > 0
    if run_executor:
        # The streaming channels exist before any executor thread does, so
        # their fds are plain fields by the time anything reads them; the
        # shared chunk pair's read end is this loop's bus fd, and the
        # handler learns where to send each lane's disconnect tags — on
        # that mount's own submit channel, since that is where its
        # executor is parked.
        pool.enable_stream_channel()
        if len(asgi_lanes) == 0:
            handler.set_asgi_notify(pool.submit_write_fd(-1))
        for k in range(len(asgi_lanes)):
            var lane = asgi_lanes[k]
            pool.enable_stream_ack(lane)
            handler.set_lane_notify(lane, pool.submit_write_fd(lane))
        exec_thread.start(pool.addr(), opts_addr, asgi_lanes.copy())
    if pool_threads.count > 0:
        pool_threads.start[WSGIHandler](pool.addr(), opts_addr, wsgi_lanes^)
    var stream_bus_fd = pool.stream_chunk_read if run_executor else -1

    comptime if CompilationTarget.is_macos():
        from lightbug_http.c.kqueue_backend import KqueueBackend
        var backend = DetachingBackend[KqueueBackend](KqueueBackend())
        run_event_loop(
            listener.socket.fd, handler, backend, config, opts.address(), True,
            shutdown_fd, stream_bus_fd, pool.addr(),
        )
    else:
        from lightbug_http.c.epoll_backend import EpollBackend
        var backend = DetachingBackend[EpollBackend](EpollBackend())
        run_event_loop(
            listener.socket.fd, handler, backend, config, opts.address(), True,
            shutdown_fd, stream_bus_fd, pool.addr(),
        )

    # Detached across it, for the reason the pool body details: a thread
    # finishing its last job (or the executor draining its tasks) has to
    # attach, and it cannot while this thread holds a state and blocks in
    # `pthread_join`.
    ref cpy = Python().cpython()
    var join_ts = cpy.PyEval_SaveThread()
    var failed = 0
    if run_executor:
        failed += exec_thread.stop_and_join(pool)
    if pool_threads.count > 0:
        failed += pool_threads.stop_and_join(pool)
    cpy.PyEval_RestoreThread(join_ts)
    if failed > 0:
        print(
            String(failed) + " offload thread(s) did not exit cleanly",
            flush=True,
        )
    # `pool` must outlive the join: a thread still finishing a job writes into
    # it. This use is what stops destroy-at-last-use freeing it above.
    _ = pool.capacity


def _serve_threaded(
    mut opts: ServeOptions,
    listener: NoTLSListener[NetworkType.tcp4],
    bus: BroadcastBus,
) raises:
    """`--threads N`: N event loops on N threads, one interpreter.

    The order here is the threaded mode's load-bearing part, the mirror
    image of the prefork rule above. The interpreter comes up on THIS
    thread (`require_free_threading` is the first Python call, and the
    place a GIL-enabled interpreter is refused), the application is
    imported once here so Django's `setup()` runs single-threaded, the
    signal pipe is armed once for the process — and only then does
    `ThreadedServer.serve` detach this thread and spawn the loops, each of
    which builds its own `WSGIHandler` from `opts` via `WSGIHandler.make`.
    No fork, so `main` returns normally.

    Under `--realtime` each thread also drains its own bus channel, exactly
    as a worker drains its own. `bus` was built on the main thread before
    any of this, so `M0_BUS_WRITE_FDS` is already in the environment the
    interpreter is about to snapshot, and `m0pub` reaches N threads with the
    same N `os.write`s it used to reach N processes — it never learns which
    it is talking to.
    """
    require_free_threading(opts.threads)
    if opts.app_dir.byte_length() > 0:
        Python.add_to_path(opts.app_dir)
    # Import once on main (so Django's setup() runs single-threaded) and
    # detect the protocol while at it — the imports below are sys.modules
    # hits for every serving thread.
    var is_asgi: Bool
    try:
        if len(opts.mount_prefixes) > 0:
            is_asgi = _resolve_mounts(opts)
        else:
            is_asgi = _resolve_spec(opts)
    except e:
        _fail(
            "could not load " + opts.served() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return
    if is_asgi and opts.realtime:
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_STARTUP)
    if len(opts.mount_prefixes) > 0 and opts.realtime:
        _fail(_REALTIME_MOUNT_CONFLICT, EXIT_STARTUP)
    var auto_pool = zero_config_topology(opts)
    opts.blocking_threads = resolve_blocking_threads(
        opts, is_asgi, effective_cpus()
    )
    var executor_mode = use_asgi_executor(opts, is_asgi)
    # Each serving thread's own loop handler is only the fallback in
    # executor mode; the one lifespan per loop belongs to that loop's
    # executor. Registries size up for the ASGI chunk outboxes.
    opts.handler_lifespan = not executor_mode
    opts.asgi_streaming = executor_mode

    var shutdown_fd = install_shutdown_signals()
    var opts_ptr = Pointer(to=opts)
    var opts_addr = Pointer(to=opts_ptr).unsafe_bitcast[Int]()[]
    print(
        "m0serve: " + opts.served() + " on http://" + opts.address()
        + " (protocol=" + ("asgi" if is_asgi else "wsgi")
        + " threads=" + String(opts.threads) + ")"
        + (" asgi-loop" if executor_mode else "")
        + (
            " blocking-threads=" + String(opts.blocking_threads)
            + (" (auto)" if auto_pool else "")
            if opts.blocking_threads > 0 else ""
        )
        + (" realtime" if opts.realtime else "")
        + (" reload" if opts.reload else ""),
        flush=True,
    )
    var server = ThreadedServer(
        opts.server_config(AppConfig(default_port=DEFAULT_PORT)),
        opts.address(),
        listener.socket.fd.value,
    )
    server.blocking_threads = opts.blocking_threads
    server.asgi_executor = executor_mode
    for i in range(bus.size()):
        server.bus_read_fds.append(bus.read_fd(i))
    var failed = server.serve[WSGIHandler](opts.threads, opts_addr, shutdown_fd)
    # `listener` must outlive `serve`; this use is what keeps it alive.
    _ = listener.socket.fd.value
    if failed > 0:
        process_exit(EXIT_STARTUP)
