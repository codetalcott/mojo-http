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

from std.os.path import isdir
from std.sys.arg import argv

from lightbug_http import Server
from lightbug_http.connection import ListenConfig
from lightbug_http.c.process import process_exit

from m0_http import (
    StaticFiles, WorkerSupervisor, install_shutdown_signals, exit_worker,
)
from m0_http.config import AppConfig
from m0_wsgi import (
    WSGIApp, WSGIHandler, ServeOptions, parse_args, usage,
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

    # Bind before forking; every worker accepts from this one socket.
    var listener = ListenConfig().listen(opts.address())

    # Fork before touching Python — see the module docstring. The parent
    # stays inside fork_all() supervising; only workers return here.
    var multiprocess = opts.workers > 1
    if multiprocess:
        var supervisor = WorkerSupervisor(opts.workers)
        supervisor.fork_all()

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

    var mounts = List[StaticFiles]()
    for i in range(len(opts.static_prefixes)):
        mounts.append(
            StaticFiles(
                opts.static_dirs[i], opts.static_prefixes[i],
                cache_control=opts.static_cache_control,
            )
        )
    var handler = WSGIHandler(app^, mounts^)

    print(
        "m0serve: " + opts.spec() + " on http://" + opts.address()
        + " (workers=" + String(opts.workers) + ")",
        flush=True,
    )
    var server = Server(opts.server_config(AppConfig(default_port=DEFAULT_PORT)))
    # After fork_all — each worker arms its own pipe.
    var shutdown_fd = install_shutdown_signals()
    server.serve_nonblocking(listener, handler, shutdown_read_fd=shutdown_fd)
    if multiprocess:
        exit_worker()
