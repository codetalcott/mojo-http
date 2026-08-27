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
from std.python import Python, PythonObject
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
    AsgiExecutor, JOIN_TIMEOUT_NS, detect_protocol, discovery_specs, resolve_blocking_threads,
    zero_config_topology, use_asgi_executor, wsgi_lanes, asgi_mount_names,
    effective_cpus, Report, probe_free_threading, EXIT_NOT_FREE_THREADED,
    M0SERVE_VERSION, prepend_to_path, DEFAULT_PORT, EXIT_USAGE, EXIT_STARTUP, PROTOCOL_ASGI,
)


def _realtime_without_wsgi(opts: ServeOptions, is_asgi: Bool) -> Bool:
    """Whether `--realtime` has no application that could ever take a hold.

    `M0-Hold` is a response-header protocol for buffered WSGI responses, so
    the flag needs a WSGI application somewhere. Unmounted that is the whole
    question. **Mounted it is per mount**: a server whose WSGI mounts take
    holds while its ASGI mounts stream through their own executor is exactly
    the mixed application this pair was refused for, and the loop tells the
    two apart by lane. Only a mounted server with no WSGI mount at all is
    asking for nothing.
    """
    if len(opts.mount_prefixes) == 0:
        return is_asgi
    return len(opts.asgi_mounts) == len(opts.mount_prefixes)


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


def _specs_tried(specs: List[String]) -> String:
    """The discovery candidates as one comma-separated list, for errors."""
    var joined = String("")
    for i in range(len(specs)):
        if i > 0:
            joined += ", "
        joined += specs[i]
    return joined^


def _listen_or_fail(opts: ServeOptions) raises -> NoTLSListener[NetworkType.tcp4]:
    """Bind, or say why not and exit `EXIT_STARTUP`.

    Five attempts a second apart: a restart racing the previous process's
    5 s drain still succeeds, and a port still busy after that belongs to
    another server — which is the message a developer needs, not the
    listener's retry chatter. `SO_REUSEPORT` is off (the `ListenConfig`
    default since 0.14.0), so a second `m0serve` on a busy port fails here
    instead of binding beside the first and taking a share of its
    connections. `quiet=True`: the startup line printed after the
    application loads is the ready signal, so "ready" means ready — the
    banner used to print before the load, and a failed import read as
    "Ready" followed by exit 1. `smoke-serve` pins both.
    """
    try:
        return ListenConfig(max_bind_retries=5, quiet=True).listen(
            opts.address()
        )
    except:
        _fail(
            "address already in use: " + opts.address()
            + " -- is another server running? (pick another --port, or"
            + " stop it)",
            EXIT_STARTUP,
        )
        raise Error("unreachable: _fail exits the process")


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
            # A candidate that exists and RAISES on import is the answer,
            # not a miss to be papered over by the next convention: the
            # shim attaches the traceback to exactly that case, and the
            # discovery list would only hide it.
            if String(e).find("Traceback (most recent call last)") >= 0:
                raise Error(String(e))
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
    # The bus is created UNCONDITIONALLY now, --realtime or not, one
    # worker or many: an ASGI application's pub/sub (`state["m0"]`) rides
    # it, the decision must be made here -- pre-fork and pre-Python, while
    # protocol detection can only happen after the fork -- and a
    # single-worker app publishing to its own subscribers still needs its
    # own loop's channel (there is no separate local-delivery path to keep
    # in sync, by design). The cost when nothing uses it is one socketpair
    # per worker plus three env vars.
    var bus = BroadcastBus(channels if channels > 0 else 1)
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


comptime _DOCTOR_PROBE = """
import sys, platform


def where():
    return (sys.executable or '', sys.prefix or '', platform.machine() or '',
            platform.python_implementation() or '')
"""


def _doctor_dirs(mut report: Report, opts: ServeOptions):
    """The three directory checks, in `main`'s order and with its exit code."""
    if not isdir(opts.app_dir):
        report.fail_check(
            String("app-dir"),
            "app dir does not exist: " + opts.app_dir,
            "create it, or pass --app-dir with the directory holding "
            + opts.module,
            EXIT_STARTUP,
        )
    else:
        report.pass_check(String("app-dir"), opts.app_dir + " exists")
    for i in range(len(opts.static_dirs)):
        if not isdir(opts.static_dirs[i]):
            report.fail_check(
                String("static-dir"),
                "static dir does not exist: " + opts.static_dirs[i],
                "create it, or drop --static " + opts.static_prefixes[i],
                EXIT_STARTUP,
            )
    for i in range(len(opts.reload_dirs)):
        if not isdir(opts.reload_dirs[i]):
            report.fail_check(
                String("reload-dir"),
                "reload dir does not exist: " + opts.reload_dirs[i],
                "create it, or drop --reload-dir " + opts.reload_dirs[i],
                EXIT_STARTUP,
            )


def _doctor_conflicts(mut report: Report, opts: ServeOptions):
    """The refusals `main` makes before it binds — all EXIT_USAGE."""
    var conflict = threads_conflict(opts.workers, opts.threads)
    if conflict:
        report.fail_check(
            String("threads-vs-workers"),
            conflict.value(),
            String("give one of --workers or --threads, not both"),
            EXIT_USAGE,
        )
    else:
        report.pass_check(
            String("threads-vs-workers"),
            String("topology flags are consistent"),
        )
    if opts.protocol == PROTOCOL_ASGI and opts.realtime:
        report.fail_check(
            String("protocol-vs-realtime"),
            String(_REALTIME_ASGI_CONFLICT),
            String("drop --realtime; an ASGI app streams natively"),
            EXIT_USAGE,
        )


def _run_doctor(mut opts: ServeOptions) -> Int:
    """`--doctor`: report the configuration, bind nothing, fork nothing.

    The order of `report.*` calls IS the order `main` performs the same
    checks, because `Report.exit_code` returns the first failure rather than
    the worst one — so a configuration that trips two refusals reports the
    one the server would actually hit first. Keeping the two in step is
    manual and therefore worth stating: if a check moves in `main`, it moves
    here.

    Never raises. A doctor that dies while diagnosing is the one failure
    mode it cannot have, so every fallible step is caught and becomes a
    failed check with the exit code that step would have produced.
    """
    var report = Report(String(M0SERVE_VERSION))
    report.add_fact(String("build"), String("version"), String(M0SERVE_VERSION))
    report.add_fact(
        String("build"),
        String("os"),
        String("macos") if CompilationTarget.is_macos() else String("linux"),
    )
    # Spelled as the wheel filenames spell it -- macosx_13_0_arm64,
    # manylinux_2_35_x86_64, manylinux_2_35_aarch64 -- so someone debugging
    # a `pip` refusal can compare this line to the file pip declined.
    var arch: String
    if CompilationTarget.is_x86():
        arch = String("x86_64")
    elif CompilationTarget.is_macos():
        arch = String("arm64")
    else:
        arch = String("aarch64")
    report.add_fact(String("build"), String("arch"), arch)

    # The interpreter, probed here for its FACTS but checked further down.
    # `probe_free_threading` is the process's first Python call, so this is
    # also where a binary that cannot resolve libpython reports why -- the
    # most common install failure, and otherwise visible only as a traceback
    # at serve time.
    #
    # Facts now, checks later, because `Report.exit_code` returns the FIRST
    # failure and must therefore agree with the order `main` fails in: dirs
    # and usage conflicts are decided before any Python runs. Recording the
    # interpreter check here instead made `--workers 2 --threads 2` report
    # 78 where the server exits 2.
    var py_ok = False
    var py_version = String("")
    var py_ft_build = False
    var py_gil = True
    var py_error = String("")
    try:
        var py = probe_free_threading()
        py_ok = True
        py_version = py.version
        py_ft_build = py.free_threaded_build
        py_gil = py.gil_enabled
        report.add_fact(String("python"), String("version"), py.version)
        report.add_bool(
            String("python"), String("free_threaded_build"),
            py.free_threaded_build,
        )
        report.add_bool(String("python"), String("gil_enabled"), py.gil_enabled)
        try:
            var builtins = Python.import_module("builtins")
            var ns = Python.dict()
            builtins.exec(PythonObject(_DOCTOR_PROBE), ns)
            var where = ns["where"]()
            report.add_fact(
                String("python"), String("executable"), String(py=where[0])
            )
            report.add_fact(
                String("python"), String("prefix"), String(py=where[1])
            )
            report.add_fact(
                String("python"), String("machine"), String(py=where[2])
            )
            report.add_fact(
                String("python"), String("implementation"), String(py=where[3])
            )
        except:
            pass  # the version facts above are the load-bearing ones
    except e:
        py_error = String(e)

    _doctor_dirs(report, opts)
    _doctor_conflicts(report, opts)

    # Python enters here, in `main`'s order: after every check that needs no
    # interpreter at all.
    var threads_ok = True
    if py_ok:
        report.pass_check(
            String("interpreter"), "CPython " + py_version + " resolved"
        )
        # 78 only when a threaded mode was actually asked for -- that is
        # `require_free_threading`'s own rule, and the doctor must not
        # invent a refusal the server would not make.
        if opts.threads > 1:
            if py_gil:
                threads_ok = False
                report.fail_check(
                    String("free-threading"),
                    "--threads " + String(opts.threads)
                    + " requires free-threaded CPython with the GIL disabled;"
                    + (
                        " this is not a free-threaded build"
                        if not py_ft_build
                        else " the GIL is enabled (PYTHON_GIL=1?)"
                    ),
                    String(
                        "use --workers N instead, or run on 3.14t with"
                        " PYTHON_GIL=0"
                    ),
                    EXIT_NOT_FREE_THREADED,
                )
            else:
                report.pass_check(
                    String("free-threading"),
                    String("interpreter is free-threaded and the GIL is off"),
                )
    else:
        threads_ok = False
        report.fail_check(
            String("interpreter"),
            "could not initialize CPython: " + py_error,
            String(
                "run m0serve from a virtualenv whose python3 is on PATH, or"
                " set MOJO_PYTHON_LIBRARY to the libpython to load"
            ),
            EXIT_STARTUP,
        )

    # The application. Skipped -- not failed -- when there is nothing to
    # load: `m0serve --doctor` with no MODULE is the "is this environment
    # sane" call, and reporting a missing app as a defect would make the
    # useful invocation always exit non-zero.
    var have_app = opts.module.byte_length() > 0 or len(opts.mount_prefixes) > 0
    var is_asgi = False
    var resolved = False
    if not have_app:
        report.add_bool(String("application"), String("requested"), False)
    elif not threads_ok:
        # The interpreter is unusable or refused; an import would only
        # produce a second, derivative failure.
        report.add_bool(String("application"), String("requested"), True)
        report.add_fact(
            String("application"), String("resolved"), String("skipped")
        )
    else:
        report.add_bool(String("application"), String("requested"), True)
        try:
            if opts.app_dir.byte_length() > 0 and isdir(opts.app_dir):
                prepend_to_path(opts.app_dir)
            if len(opts.mount_prefixes) > 0:
                is_asgi = _resolve_mounts(opts)
            else:
                is_asgi = _resolve_spec(opts)
            resolved = True
        except e:
            report.fail_check(
                String("application"),
                "could not load " + opts.served() + " from " + opts.app_dir
                + ": " + String(e),
                String(
                    "check --app-dir and the MODULE[:ATTR] spec; a bare"
                    " MODULE also tries MODULE.asgi, MODULE.wsgi, MODULE:app"
                    " and MODULE.main:app"
                ),
                EXIT_STARTUP,
            )
        if resolved:
            report.add_fact(
                String("application"), String("spec"), opts.served()
            )
            report.add_fact(
                String("application"),
                String("protocol"),
                String("asgi") if is_asgi else String("wsgi"),
            )
            report.add_bool(
                String("application"),
                String("protocol_forced"),
                opts.protocol != String("auto"),
            )
            if len(opts.mount_prefixes) > 0:
                var mounts = String("[")
                for i in range(len(opts.mount_prefixes)):
                    if i > 0:
                        mounts += ","
                    var prefix = opts.mount_prefixes[i]
                    var mount_asgi = False
                    for k in range(len(opts.asgi_mounts)):
                        if opts.asgi_mounts[k] == i:
                            mount_asgi = True
                            break
                    mounts += '{"prefix":"' + (
                        prefix if prefix.byte_length() > 0 else String("/")
                    ) + '","spec":"' + opts.mount_modules[i] + ":"
                    mounts += opts.mount_attributes[i] + '","protocol":"'
                    mounts += (
                        String("asgi") if mount_asgi else String("wsgi")
                    ) + '"}'
                mounts += "]"
                report.add_raw(
                    String("application"), String("mounts"), mounts
                )
            report.pass_check(
                String("application"),
                opts.served() + " imports and classifies as "
                + (String("asgi") if is_asgi else String("wsgi")),
            )
            # The two refusals that need the detected protocol -- the same
            # pair main makes right after its own resolve, at EXIT_STARTUP.
            if opts.realtime and _realtime_without_wsgi(opts, is_asgi):
                report.fail_check(
                    String("realtime-vs-asgi"),
                    String(_REALTIME_ASGI_CONFLICT),
                    String("drop --realtime; an ASGI app streams natively"),
                    EXIT_STARTUP,
                )

    # Topology, resolved the way the server resolves it -- which needs the
    # protocol, hence its place after the import. Without a resolved app the
    # requested values are reported and `resolved` says so.
    var cpus = effective_cpus()
    report.add_int(String("topology"), String("cpus"), cpus)
    report.add_int(String("topology"), String("workers"), opts.workers)
    report.add_int(String("topology"), String("threads"), opts.threads)
    if resolved:
        var auto_pool = zero_config_topology(opts)
        var blocking = resolve_blocking_threads(opts, is_asgi, cpus)
        var executor = use_asgi_executor(opts, is_asgi)
        report.add_int(
            String("topology"), String("blocking_threads"), blocking
        )
        report.add_fact(
            String("topology"),
            String("blocking_threads_source"),
            String("default") if auto_pool else String("configured"),
        )
        report.add_bool(String("topology"), String("asgi_executor"), executor)
        var mode: String
        if opts.threads > 1:
            mode = String("threads")
        elif opts.workers > 1:
            mode = String("prefork")
        else:
            mode = String("single")
        report.add_fact(String("topology"), String("mode"), mode)
    else:
        report.add_int(
            String("topology"),
            String("blocking_threads"),
            opts.blocking_threads,
        )
        report.add_bool(String("topology"), String("resolved"), False)

    report.add_fact(String("server"), String("host"), opts.host)
    report.add_int(String("server"), String("port"), opts.port)
    report.add_fact(String("server"), String("app_dir"), opts.app_dir)
    report.add_bool(String("server"), String("access_log"), opts.access_log)
    report.add_bool(String("server"), String("metrics"), opts.metrics)
    report.add_bool(String("server"), String("realtime"), opts.realtime)
    report.add_bool(String("server"), String("reload"), opts.reload)
    report.add_fact(
        String("server"), String("health_path"), opts.health_path
    )
    report.add_int(String("server"), String("max_body"), opts.max_body)
    var statics = String("[")
    for i in range(len(opts.static_prefixes)):
        if i > 0:
            statics += ","
        statics += '{"prefix":"' + opts.static_prefixes[i] + '","dir":"'
        statics += opts.static_dirs[i] + '"}'
    statics += "]"
    report.add_raw(String("server"), String("static"), statics)

    print(report.render(), flush=True)
    return report.exit_code()


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
    # Before the directory checks below, because those `_fail` on the first
    # problem and the doctor's job is to report all of them at once.
    if opts.show_doctor:
        process_exit(_run_doctor(opts))
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

    # The forced half of the ASGI/realtime refusal is checkable without an
    # interpreter; the auto-detected half fails after the app loads, with
    # the same message.
    if opts.protocol == PROTOCOL_ASGI and opts.realtime:
        print(usage(), flush=True)
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_USAGE)

    # Bind before forking; every worker accepts from this one socket.
    var listener = _listen_or_fail(opts)

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
            prepend_to_path(opts.app_dir)
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

    if opts.realtime and _realtime_without_wsgi(opts, is_asgi):
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_STARTUP)

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
    # Registries size up wherever the chunk channel will exist: for the
    # executor's ASGI streams, and for the WSGI iterables a handler pool
    # streams through the same channel.
    opts.asgi_streaming = executor_mode or opts.blocking_threads > 0

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
        "🔥 m0serve: " + opts.served() + " on http://" + opts.address()
        + " (protocol=" + ("asgi" if is_asgi else "wsgi")
        + " workers=" + String(opts.workers) + ")"
        + (
            (" asgi-loop@" + asgi_mount_names(opts))
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
            wsgi_lanes=wsgi_lanes(opts),
            peer_bus_fd=bus.read_fd(worker),
            # Under `--realtime` a pool thread's hold reaches THIS worker's
            # loop through this worker's own channel — `m0pub` writes every
            # channel, a hold must write exactly one: slot numbers are
            # this loop's.
            hold_notify_fd=(
                bus.write_fds[worker]
                if (opts.realtime and worker >= 0 and worker < len(bus.write_fds))
                else -1
            ),
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
    peer_bus_fd: Int = -1,
    hold_notify_fd: Int = -1,
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

    `peer_bus_fd` is this worker's BroadcastBus channel (M0_WORKERS>1),
    registered beside the chunk channel: GRIP-named frames on it are
    forwarded to the executors for `state["m0"]` subscribers. `--realtime`
    composes with the pool (`hold_notify_fd`: a pool thread's hold reaches
    this loop's registries as a reserved frame on this loop's own bus
    channel) and is still refused with the executor and with `--mount`.
    """
    var pool = OffloadPool(config.max_connections)
    if hold_notify_fd >= 0:
        pool.set_hold_notify(hold_notify_fd)
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
        pool.enable_base_stream_ack()
        if len(asgi_lanes) == 0:
            handler.set_asgi_notify(pool.submit_write_fd(-1))
        for k in range(len(asgi_lanes)):
            var lane = asgi_lanes[k]
            pool.enable_stream_ack(lane)
            handler.set_lane_notify(lane, pool.submit_write_fd(lane))
        exec_thread.start(pool.addr(), opts_addr, asgi_lanes.copy())
    if pool_threads.count > 0 and not pool.chunk_active():
        # Pool threads stream WSGI iterables through the same chunk channel
        # the executor uses — a second producer on one FIFO — so a
        # pure-WSGI pool server creates it too. NOT the executor's ack
        # pair: `stream_active()` keeps meaning "an executor exists", which
        # is what keeps an M0-Hold on this loop from being mistaken for a
        # channel stream.
        pool.enable_stream_channel()
    if pool_threads.count > 0:
        # Where an inbound WebSocket message goes when a pool thread's view
        # held the socket: that mount's own submit lane, so the frame is
        # served by a thread that has that urlconf and no other. Read before
        # the lanes are moved into `start`.
        if opts.realtime:
            if len(wsgi_lanes) == 0:
                handler.set_ws_pool_notify(-1, pool.submit_write_fd(-1))
            for wl in range(len(wsgi_lanes)):
                handler.set_ws_pool_notify(
                    wsgi_lanes[wl], pool.submit_write_fd(wsgi_lanes[wl])
                )
        pool_threads.start[WSGIHandler](pool.addr(), opts_addr, wsgi_lanes^)
    var stream_bus_fd = pool.stream_chunk_read if pool.chunk_active() else -1

    comptime if CompilationTarget.is_macos():
        from lightbug_http.c.kqueue_backend import KqueueBackend
        var backend = DetachingBackend[KqueueBackend](KqueueBackend())
        run_event_loop(
            listener.socket.fd, handler, backend, config, opts.address(), True,
            shutdown_fd, stream_bus_fd, pool.addr(),
            peer_bus_fd=peer_bus_fd,
        )
    else:
        from lightbug_http.c.epoll_backend import EpollBackend
        var backend = DetachingBackend[EpollBackend](EpollBackend())
        run_event_loop(
            listener.socket.fd, handler, backend, config, opts.address(), True,
            shutdown_fd, stream_bus_fd, pool.addr(),
            peer_bus_fd=peer_bus_fd,
        )

    # Detached across it, for the reason the pool body details: a thread
    # finishing its last job (or the executor draining its tasks) has to
    # attach, and it cannot while this thread holds a state and blocks in
    # `pthread_join`.
    ref cpy = Python().cpython()
    var join_ts = cpy.PyEval_SaveThread()
    var failed = 0
    var stuck = 0
    if run_executor:
        failed += exec_thread.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += exec_thread.stragglers
    if pool_threads.count > 0:
        failed += pool_threads.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += pool_threads.stragglers
    if stuck > 0:
        # A thread still inside the application after the drain AND the join
        # budget is not coming back: a response that never ends (an SSE
        # generator served buffered under WSGI; docs/REAL_APP_VALIDATION.md)
        # holds it for the life of the process. Nothing here can unwind
        # Python on another thread, so leave the way a forked worker does --
        # `_exit`, no teardown -- with every connection the loop could answer
        # already answered. The alternative was a SIGTERM that did nothing
        # until `docker stop` gave up and sent SIGKILL, which is what it did.
        print(
            "m0serve: " + String(stuck) + " handler thread(s) still inside the"
            " application " + String(JOIN_TIMEOUT_NS // 1_000_000_000)
            + " s after the drain; exiting without them",
            flush=True,
        )
        process_exit(0)
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
        prepend_to_path(opts.app_dir)
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
    if opts.realtime and _realtime_without_wsgi(opts, is_asgi):
        _fail(_REALTIME_ASGI_CONFLICT, EXIT_STARTUP)
    var auto_pool = zero_config_topology(opts)
    opts.blocking_threads = resolve_blocking_threads(
        opts, is_asgi, effective_cpus()
    )
    var executor_mode = use_asgi_executor(opts, is_asgi)
    # Each serving thread's own loop handler is only the fallback in
    # executor mode; the one lifespan per loop belongs to that loop's
    # executor. Registries size up for the chunk outboxes — the executor's
    # ASGI streams and the pool's streamed WSGI iterables alike.
    opts.handler_lifespan = not executor_mode
    opts.asgi_streaming = executor_mode or opts.blocking_threads > 0

    var shutdown_fd = install_shutdown_signals()
    var opts_ptr = Pointer(to=opts)
    var opts_addr = Pointer(to=opts_ptr).unsafe_bitcast[Int]()[]
    print(
        "🔥 m0serve: " + opts.served() + " on http://" + opts.address()
        + " (protocol=" + ("asgi" if is_asgi else "wsgi")
        + " threads=" + String(opts.threads) + ")"
        + (
            (" asgi-loop@" + asgi_mount_names(opts))
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
    var server = ThreadedServer(
        opts.server_config(AppConfig(default_port=DEFAULT_PORT)),
        opts.address(),
        listener.socket.fd.value,
    )
    server.blocking_threads = opts.blocking_threads
    server.asgi_executor = executor_mode
    for i in range(bus.size()):
        server.bus_read_fds.append(bus.read_fd(i))
        server.bus_write_fds.append(bus.write_fds[i])
    var failed = server.serve[WSGIHandler](opts.threads, opts_addr, shutdown_fd)
    # `listener` must outlive `serve`; this use is what keeps it alive.
    _ = listener.socket.fd.value
    if failed > 0:
        process_exit(EXIT_STARTUP)
