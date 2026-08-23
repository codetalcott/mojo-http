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
"""

from std.os import getenv, setenv
from std.os.path import isdir, isfile
from std.python import Python
from std.sys.arg import argv
from std.sys.info import CompilationTarget

from lightbug_http import Server
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.connection import ListenConfig, NoTLSListener
from lightbug_http.address import NetworkType
from lightbug_http.c.process import process_exit

from m0_http import (
    StaticFiles, WorkerSupervisor, install_shutdown_signals, exit_worker,
    threads_conflict,
)
from m0_http.config import AppConfig
from m0_http.multiworker import SharedAtomics
from m0_wsgi import (
    WSGIApp, WSGIHandler, ServeOptions, parse_args, usage,
    ThreadedServer, require_free_threading,
    M0SERVE_VERSION, DEFAULT_PORT, EXIT_USAGE, EXIT_STARTUP,
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

    var conflict = threads_conflict(opts.workers, opts.threads)
    if conflict:
        print(usage(), flush=True)
        _fail(conflict.value(), EXIT_USAGE)

    # Bind before forking; every worker accepts from this one socket.
    var listener = ListenConfig().listen(opts.address())

    # Then everything `--realtime` shares, still before the fork and still
    # before the first Python call. Inert without the flag.
    var channels = opts.threads if opts.threads > 1 else opts.workers
    var bus = _prepare_realtime(opts, channels)

    if opts.threads > 1:
        # The listener is borrowed, not reduced to its fd: its last use would
        # otherwise be that read, and Mojo's destroy-at-last-use would close
        # the listening socket before the threads dup it — the dup then lands
        # on whatever descriptor number the kernel recycled, and four loops
        # watch a pipe. Prefork never hits this because `serve_nonblocking`
        # uses the listener itself, later.
        _serve_threaded(opts, listener, bus)
        return

    # Fork before touching Python — see the module docstring. The parent
    # stays inside fork_all() supervising; only workers return here.
    var multiprocess = opts.workers > 1
    var worker = 0
    if multiprocess:
        var supervisor = WorkerSupervisor(opts.workers)
        supervisor.fork_all()
        worker = supervisor.worker_index

    # The first Python call in this process.
    var app: WSGIApp
    try:
        app = WSGIApp(
            opts.module,
            server_name=opts.host,
            server_port=String(opts.port),
            attribute=opts.attribute,
            project_path=opts.app_dir,
            multiprocess=multiprocess,
        )
    except e:
        _fail(
            "could not load " + opts.spec() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return

    var handler = WSGIHandler.for_options(app^, opts)

    print(
        "m0serve: " + opts.spec() + " on http://" + opts.address()
        + " (workers=" + String(opts.workers) + ")"
        + (" realtime" if opts.realtime else ""),
        flush=True,
    )
    var server = Server(opts.server_config(AppConfig(default_port=DEFAULT_PORT)))
    # After fork_all — each worker arms its own pipe.
    var shutdown_fd = install_shutdown_signals()
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
    if multiprocess:
        exit_worker()


def _serve_threaded(
    opts: ServeOptions,
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
    try:
        _ = Python.import_module(opts.module)
    except e:
        _fail(
            "could not load " + opts.spec() + " from " + opts.app_dir + ": "
            + String(e),
            EXIT_STARTUP,
        )
        return

    var shutdown_fd = install_shutdown_signals()
    var opts_ptr = Pointer(to=opts)
    var opts_addr = Pointer(to=opts_ptr).unsafe_bitcast[Int]()[]
    print(
        "m0serve: " + opts.spec() + " on http://" + opts.address()
        + " (threads=" + String(opts.threads) + ")"
        + (" realtime" if opts.realtime else ""),
        flush=True,
    )
    var server = ThreadedServer(
        opts.server_config(AppConfig(default_port=DEFAULT_PORT)),
        opts.address(),
        listener.socket.fd.value,
    )
    for i in range(bus.size()):
        server.bus_read_fds.append(bus.read_fd(i))
    var failed = server.serve[WSGIHandler](opts.threads, opts_addr, shutdown_fd)
    # `listener` must outlive `serve`; this use is what keeps it alive.
    _ = listener.socket.fd.value
    if failed > 0:
        process_exit(EXIT_STARTUP)
