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
so every worker inherits one shared socket (gunicorn's model; per-worker
`SO_REUSEPORT` binds would not do — they do not distribute on macOS and hash
blind on Linux). Which worker WINS an accept on it is the scheduler's, and
it is the same worker nearly every time on both platforms, so under
`--workers N` the winner passes each connection to the least-loaded sibling
over a channel created here before the fork (`lightbug_http/accept_share.mojo`,
SPEC E16; `M0_ACCEPT_SHARE=0` is the A/B knob). Fork second, BEFORE any
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

from lightbug_http import Server, HTTPRequest, HTTPResponse
from m0_http import PoolContext, PoolHandler
from m0_http import request_qos_class, QOS_CLASS_USER_INTERACTIVE
from m0_http import Mount, Views, reply
from m0_http import GrantKeys, verify_grant
from lightbug_http.http.date import unix_now
from lightbug_http.broadcast import BroadcastBus
from m0_postgres import PgLib
from lightbug_http.event_loop import run_event_loop
from lightbug_http.offload import OffloadPool
from lightbug_http.accept_share import AcceptShare, accept_sharing_wanted
from lightbug_http.connection import ListenConfig, NoTLSListener
from lightbug_http.address import NetworkType, TCPAddr, parse_address
from lightbug_http.socket import Socket
from lightbug_http.c.process import process_exit, executable_path
from lightbug_http.c.fcntl import set_cloexec
from lightbug_http.server_config import ServerConfig
from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.c.platform import PlatformBackend

from m0_http import (
    StaticFiles, WorkerSupervisor, install_shutdown_signals, exit_worker,
)
from m0_http.config import AppConfig
from m0_http.prefork import (
    bind_accept_share,
    prefork_accept_share,
    prefork_bus,
    prefork_page,
    shared_id_addr,
    spawned_worker_index,
)
from m0_wsgi import (
    WSGIHandler, ServeOptions, parse_args, usage,
    ThreadedServer, DetachingBackend,
    serve_inverted, resolve_app, resolve_blocking_threads,
    use_asgi_executor, mojo_lanes, asgi_mount_names,
    hold_lanes, is_compiled_mount, pool_is_default,
    effective_cpus, performance_cpus, pool_cpus, usable_cpus, apple_target, Report,
    probe_free_threading, FreeThreadingReport,
    use_loop_inversion, supervised, serves_offloaded, pool_thread_count,
    ServeCheck, CheckFacts, flag_checks, interpreter_checks, app_checks,
    first_refusal, refuse_first, add_checks, pg_listen_needs_libpq,
    OffloadThreads, wire_offload, join_offload,
    M0SERVE_VERSION, prepend_to_path, DEFAULT_PORT, EXIT_USAGE, EXIT_STARTUP,
    DEFAULT_CHANNEL, PgListener,
)



from m0serve_mount import MojoMount


comptime HOLD_STREAM = "/stream"
"""The hold mount's one route: `GET <prefix>/stream?g=<grant>`."""


struct GrantGate(Movable):
    """The hold mount's per-thread state: the keys it verifies against."""

    var keys: GrantKeys

    def __init__(out self, var keys: GrantKeys):
        self.keys = keys^

    def __init__(out self, *, deinit move: Self):
        self.keys = move.keys^


def hold_stream(
    req: HTTPRequest, params: List[String], st: GrantGate
) raises -> HTTPResponse:
    """The grant-verified hold: `GET <prefix>/stream?g=<grant>`.

    The application decided, in its own view with its own session, whether
    this browser may hold a stream and on which channel, and signed that
    decision into the URL (`m0serve.grant`); this verifies it -- signature
    in constant time, expiry against this host's clock, the session cookie
    the browser sends against the binding the issuer put in -- and takes
    the hold with the two headers a Django hold view returns, which the
    pool thread turns into the same `h` frame. No Python is asked. A refusal
    is a 401 whose body says `expired` (fetch a fresh URL) or `invalid`
    (stop), and names the reason.
    """
    var g = String("")
    try:
        ref q = req.uri.queries
        if "g" in q:
            g = q["g"]
    except:
        pass
    if g.byte_length() == 0:
        return reply.json(
            401, String("Unauthorized"),
            String('{"error":"invalid","reason":"no grant"}'),
        )
    var verdict = verify_grant(
        Span(g.as_bytes()), st.keys, unix_now(), req.cookies.get(st.keys.cookie)
    )
    if not verdict.ok:
        var kind = String("expired") if verdict.reason == "expired" else String("invalid")
        return reply.json(
            401, String("Unauthorized"),
            String('{"error":"', kind, '","reason":"', verdict.reason, '"}'),
        )
    return HTTPResponse(
        body_bytes=String(": open\n\n").as_bytes(),
        headers=Headers(
            Header("M0-Hold", "stream"),
            Header("M0-Channel", verdict.channel),
        ),
        status_code=200,
        status_text="OK",
    )


def hold_urls(at: Mount) raises -> Views[GrantGate]:
    var v = Views[GrantGate](at)
    v.add_read("GET", HOLD_STREAM, hold_stream)
    return v^


struct HoldMount(PoolHandler):
    """The handler behind `--mount PREFIX=hold`: a stream held against a grant.

    The one built-in mount a Python application uses without a Mojo build
    of its own: the application keeps every authorization decision in its
    own views and hands the browser a signed URL into this mount
    (`m0serve.grant.stream_url`), and the mount holds the stream on a
    pool thread that never attaches to the interpreter. Needs `--realtime`
    (what wires a pool thread's hold to the loop) and `M0_GRANT_KEY` (what
    the application signed with); `main` refuses to start without either.
    `smoke-hold-mount` is the gate; the design is
    docs/notes/grant-verified-holds.md.
    """

    var views: Views[GrantGate]
    var state: GrantGate

    def __init__(out self, var views: Views[GrantGate], var state: GrantGate):
        self.views = views^
        self.state = state^

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        # The keys are prepared once per thread, here: an HMAC state each,
        # so a verification costs the grant's bytes and nothing of the key's.
        return Self(hold_urls(Mount(ctx.prefix)), GrantGate(GrantKeys.from_env()))

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.views.dispatch(req, self.state)

    def shutdown(mut self):
        pass


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
            String(StringSpan(exe)[byte = :slash]) + "/libm0core" + ext
        )
    candidates.append(String("packages/m0-core/libm0core") + ext)
    for i in range(len(candidates)):
        if isfile(candidates[i]):
            return candidates[i]
    return String("")


def _check_facts(opts: ServeOptions) -> CheckFacts:
    """`flag_checks`' facts for this process, the libpq probe included.

    The library is opened where the list reaches it
    (`pg_listen_needs_libpq`) and before the bind, so an absent one is a
    refusal naming every path tried rather than a server that runs with no
    listener -- which it used to be: the thread logged one line and the
    process served forever, an absent library degrading into a listener
    that silently hears nothing. Pre-fork on purpose: the workers would each
    report it otherwise, and the supervisor -- the one process whose exit
    status anyone reads -- would report nothing. Here rather than in
    `m0_wsgi.checks` because this file links the Postgres bindings and the
    check list does not.
    """
    var facts = CheckFacts.gather()
    if pg_listen_needs_libpq(opts, facts):
        try:
            var probe = PgLib.open()
            facts.libpq(
                String(""),
                String("libpq ") + probe.version_text() + " at " + probe.path,
            )
        except e:
            facts.libpq(String(e), String(""))
    return facts^


struct Imported(Movable):
    """What importing the application decided, and the checks that needed it."""

    var loaded: Bool
    var is_asgi: Bool
    var auto_pool: Bool
    """The pool size was the server's to choose (`pool_is_default`)."""
    var executor: Bool
    """`use_asgi_executor`'s answer, over the resolved pool size."""
    var checks: List[ServeCheck]
    """`app_checks`: the import's own verdict first."""

    def __init__(
        out self,
        loaded: Bool,
        is_asgi: Bool,
        auto_pool: Bool,
        executor: Bool,
        var checks: List[ServeCheck],
    ):
        self.loaded = loaded
        self.is_asgi = is_asgi
        self.auto_pool = auto_pool
        self.executor = executor
        self.checks = checks^

    def __init__(out self, *, deinit move: Self):
        self.loaded = move.loaded
        self.is_asgi = move.is_asgi
        self.auto_pool = move.auto_pool
        self.executor = move.executor
        self.checks = move.checks^


def _import_and_check(
    mut opts: ServeOptions,
    interp: Optional[FreeThreadingReport] = None,
) -> Imported:
    """Import what `opts` serves, resolve what the import decides, and
    evaluate the checks that need it (`app_checks`).

    ONE sequence for prefork's worker, the `--threads` main thread and
    `--doctor`, each of which spelled it out: put `--app-dir` on
    `sys.path`, resolve the spec or every mount and detect each protocol --
    WITHOUT building a bridge, because the executor decision needs the
    protocol before any lifespan may run -- then size the pool
    (`resolve_blocking_threads`, written back into `opts`, which
    `use_asgi_executor` reads) and decide the executor. Under prefork this
    is the process's first Python call, after the fork.

    `interp` is the interpreter's report when the caller has one (the
    threaded mode probed it for its own guard, the doctor for its facts);
    otherwise it is probed here, and only if the executor would run, which
    is what `app_checks` asks it about. A probe that fails invents no
    refusal.
    """
    var error: Optional[String] = None
    var is_asgi = False
    try:
        if opts.app_dir.byte_length() > 0 and isdir(opts.app_dir):
            prepend_to_path(opts.app_dir)
        if len(opts.mount_prefixes) > 0:
            is_asgi = _resolve_mounts(opts)
        else:
            is_asgi = _resolve_spec(opts)
    except e:
        error = String(e)
    if error:
        return Imported(False, False, False, False, app_checks(opts, error, False, interp))
    # Zero-config: with no topology flag or M0_* topology variable at all,
    # the protocol picks the concurrency -- a pool for WSGI, the asyncio
    # executor for ASGI. Detection had to run first, which is why this sits
    # after the import (and, under prefork, inside each worker; every worker
    # resolves the same app to the same answer).
    var auto_pool = pool_is_default(opts)
    opts.blocking_threads = resolve_blocking_threads(opts, is_asgi, pool_cpus())
    var executor = use_asgi_executor(opts, is_asgi)
    var report = interp.copy()
    if executor and not report:
        try:
            report = probe_free_threading()
        except:
            pass
    return Imported(
        True, is_asgi, auto_pool, executor, app_checks(opts, None, is_asgi, report)
    )


def _adopt_listener(opts: ServeOptions) raises -> NoTLSListener[NetworkType.tcp4]:
    """The listener a spawned worker inherited, by fd number (`M0_LISTEN_FD`)."""
    var raw = getenv("M0_LISTEN_FD", "")
    var fd: Int
    try:
        fd = Int(raw)
    except:
        _fail("spawned worker: M0_LISTEN_FD is not set", EXIT_STARTUP)
        raise Error("unreachable")
    # Kept across this worker's own exec only (`_exec_if_spawning`); the
    # application's children must not inherit it (SPEC G16).
    set_cloexec(fd)
    var local = parse_address[NetworkType.tcp4](opts.address())
    var sock = Socket[TCPAddr[NetworkType.tcp4]](
        fd=FileDescriptor(fd),
        local_address=TCPAddr[NetworkType.tcp4](ip=local.host, port=local.port),
    )
    return NoTLSListener[NetworkType.tcp4](sock^)


def _listen_or_fail(opts: ServeOptions) raises -> NoTLSListener[NetworkType.tcp4]:
    """Bind, or say why not and exit `EXIT_STARTUP`.

    Five attempts a second apart on an address IN USE: a restart racing the
    previous process's 5 s drain still succeeds, and a port still busy
    after that belongs to another server — which is the message a
    developer needs, not the listener's retry chatter. Every other failure
    — an address not on this machine, a privileged port — is not retried
    and is reported in its own words: it used to wait out the same five
    seconds and then read "address already in use". `SO_REUSEPORT` is off
    (the `ListenConfig` default since 0.14.0), so a second `m0serve` on a
    busy port fails here instead of binding beside the first and taking a
    share of its connections. `quiet=True`: the startup line printed after
    the application loads is the ready signal, so "ready" means ready — the
    banner used to print before the load, and a failed import read as
    "Ready" followed by exit 1. `smoke-serve` pins all three.
    """
    if spawned_worker_index() >= 0:
        return _adopt_listener(opts)
    var listener: NoTLSListener[NetworkType.tcp4]
    try:
        listener = ListenConfig(max_bind_retries=5, quiet=True).listen(
            opts.address()
        )
    except e:
        if e.address_in_use():
            _fail(
                "address already in use: " + opts.address()
                + " -- is another server running? (pick another --port, or"
                + " stop it)",
                EXIT_STARTUP,
            )
        _fail(
            "cannot listen on " + opts.address() + ": " + String(e)
            + " (check --host and --port)",
            EXIT_STARTUP,
        )
        raise Error("unreachable: _fail exits the process")
    # Where a spawned worker finds it. Set unconditionally: it is one
    # variable, and the fd number is the same whether or not anyone execs —
    # a forked worker simply keeps using the listener itself. Close-on-exec
    # like every socket here (SPEC G16); the spawn's own exec is the one
    # that keeps it (`spawn_inherited_env`).
    _ = setenv("M0_LISTEN_FD", String(listener.socket.fd.value), True)
    return listener^


def _resolve_spec(mut opts: ServeOptions) raises -> Bool:
    """Import, resolve discovery, and detect the protocol — no lifespan.

    `resolve_app` does all three, for this spec and for every `--mount`
    alike; `opts` is updated to the winner so the banner and the
    per-thread handlers name what is actually being served.

    Detection is deliberately separate from `WSGIApp` construction: the
    executor mode's decision needs the protocol BEFORE any bridge exists,
    so that exactly one lifespan runs per event loop (the executor's), not
    one per candidate tried. The caller must have put `--app-dir` on
    `sys.path`; the imports here are `sys.modules` hits for everything
    that follows.
    """
    var resolved = resolve_app(
        opts.module, opts.attribute, opts.attribute_explicit, opts.protocol
    )
    opts.module = resolved[0]
    opts.attribute = resolved[1]
    return resolved[2]


def _resolve_mounts(mut opts: ServeOptions) raises -> Bool:
    """Detect every mount's protocol; returns True when they are all ASGI.

    Each mount resolves independently, through the positional spec's own
    `resolve_app` — discovery included, so `--mount /=djangoproj` finds
    `djangoproj.wsgi` exactly as a positional spec would, and a candidate
    that raises on import is reported with its traceback rather than
    skipped for the next convention — and the winner is written back so
    the banner and every handler name what is actually served.

    Mixed WSGI/ASGI mounts are the point: each gets its native execution
    mode, so `opts.asgi_mounts` records which mounts are ASGI rather than
    reducing detection to one answer for the process. A `--mount X=mojo`
    is skipped here: it has no importable object, so there is nothing to
    detect and nothing to discover. Any number of each:
    every ASGI mount gets its own executor, on its own submit lane, with
    its own drain-ack pair — the chunk channel is the one thing executors
    share, and its datagrams are slot-addressed.
    """
    var asgi_count = 0
    for i in range(len(opts.mount_prefixes)):
        # A Mojo mount has no importable object to detect a protocol from —
        # its handler is a type this binary was compiled with. Nothing to
        # resolve, and nothing to import: skip it entirely so a mounted
        # server of one Mojo mount starts no interpreter work for it.
        if is_compiled_mount(opts, i):
            continue
        var resolved = resolve_app(
            opts.mount_modules[i], opts.mount_attributes[i],
            opts.mount_explicit[i], opts.protocol,
        )
        opts.mount_modules[i] = resolved[0]
        opts.mount_attributes[i] = resolved[1]
        if resolved[2]:
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
    """Everything a worker shares that must exist BEFORE the fork and before Python.

    Returns the bus. The page, the bus and their exports are
    `m0_http.prefork`'s -- the same code the Mojo host runs -- and what is
    left here is m0serve's own: `channels` (`--workers` under prefork,
    `--threads` under the threaded mode; a `SOCK_DGRAM` socketpair delivers
    the same whether the peer draining it is another process or another
    thread), a file-backed page REQUIRED under `--spawn-workers` (the
    workers cannot reach an anonymous one at all), and `M0_CORE_LIB` for
    `m0pub`.

    The ordering rule is the same for all of it: before the fork, so every
    worker's environment agrees, and before any Python touch, because
    CPython snapshots the C environ at interpreter init. Under `--threads`
    there is no fork, but the second half still binds -- the interpreter
    comes up inside `_serve_threaded`'s `probe_free_threading`.

    The bus is created UNCONDITIONALLY, `--realtime` or not, one worker or
    many: an ASGI application's pub/sub (`state["m0"]`) rides it, the
    decision must be made here -- pre-fork and pre-Python, while protocol
    detection can only happen after the fork -- and a single-worker app
    publishing to its own subscribers still needs its own loop's channel
    (there is no separate local-delivery path to keep in sync, by design).

    The page is file-backed and exported by fd, not only by address (#322):
    an anonymous mapping survives fork and nothing else, so a process that
    EXECs -- a spawned worker, and just as much a child an application
    starts to publish from -- can only reach it through a descriptor, and
    the magic word is what lets `m0pub` refuse an address or a descriptor
    number it inherited that is not this page. A spawned worker adopts all
    of it by fd and re-exports the page's address in its own image.
    """
    _ = prefork_page(opts.workers, required=opts.spawn_workers)
    var bus = prefork_bus(channels)
    if spawned_worker_index() < 0 and getenv("M0_CORE_LIB", "").byte_length() == 0:
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


def _run_doctor(mut opts: ServeOptions) -> Int:
    """`--doctor`: report the configuration, bind nothing, fork nothing.

    Every refusal comes from `m0_wsgi.checks`, the lists `main` refuses by,
    in the order it evaluates them -- the flags (`flag_checks`), the
    interpreter (`interpreter_checks`), the application (`app_checks`) -- so
    `Report.exit_code`, the first failure's code, is the server's by
    construction rather than by a second description kept in step by hand,
    which is what this function used to be. One entry is the doctor's own:
    `interpreter`, because the doctor probes CPython first for its facts, and
    a binary that cannot load libpython says so there; the server finds the
    same thing importing the application, and exits the same 1.

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
    # The generation the binary was compiled for (`apple_target`): the
    # wheel says m1 on every Mac, a native build names its host.
    comptime if CompilationTarget.is_macos():
        report.add_fact(String("build"), String("apple_target"), apple_target())

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
    var interp: Optional[FreeThreadingReport] = None
    var py_error = String("")
    try:
        var py = probe_free_threading()
        report.add_fact(String("python"), String("version"), py.version)
        report.add_bool(
            String("python"), String("free_threaded_build"),
            py.free_threaded_build,
        )
        report.add_bool(String("python"), String("gil_enabled"), py.gil_enabled)
        interp = py^
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

    # Before the bind: the same list, and the same facts, `main` refuses by.
    var facts = _check_facts(opts)
    add_checks(report, flag_checks(opts, facts))
    report.add_bool(String("topology"), String("parallel_runtime"), facts.parallel_runtime)

    # Python enters here, in `main`'s order: after every check that needs no
    # interpreter at all.
    var threads_ok: Bool
    if interp:
        report.pass_check(
            String("interpreter"), "CPython " + interp.value().version + " resolved"
        )
        var interpreter = interpreter_checks(opts, interp.value())
        add_checks(report, interpreter)
        threads_ok = not first_refusal(interpreter)
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
    var imported = Imported(False, False, False, False, List[ServeCheck]())
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
        imported = _import_and_check(opts, interp.copy())
        if imported.loaded:
            report.add_fact(
                String("application"), String("spec"), opts.served()
            )
            report.add_fact(
                String("application"),
                String("protocol"),
                String("asgi") if imported.is_asgi else String("wsgi"),
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
        # After the import: the application's own verdict, then what needs
        # its protocol -- the list `main` refuses by at the same point.
        add_checks(report, imported.checks)

    # Topology, resolved the way the server resolves it -- which needs the
    # protocol, hence its place after the import. Without a resolved app the
    # requested values are reported and `resolved` says so.
    var cpus = effective_cpus()
    report.add_int(String("topology"), String("cpus"), cpus)
    report.add_int(
        String("topology"), String("performance_cpus"), performance_cpus()
    )
    # What the MACHINE has online, and what this PROCESS may use, are
    # different numbers in a container and only the second is actionable
    # (`usable_cpus`). Reported beside each other rather than one replacing
    # the other: `cpus` has always meant the machine, and a diagnostic that
    # silently changes what a field means is worse than one that adds a
    # field. Equal on an unconstrained host.
    report.add_int(String("topology"), String("usable_cpus"), usable_cpus())
    report.add_bool(String("topology"), String("qos"), opts.qos)
    report.add_int(String("topology"), String("workers"), opts.workers)
    report.add_fact(
        String("topology"), String("worker_mode"),
        String("spawn") if opts.spawn_workers else String("fork"),
    )
    report.add_bool(
        String("topology"), String("accept_sharing"), accept_sharing_wanted(opts.workers)
    )
    report.add_int(String("topology"), String("threads"), opts.threads)
    if imported.loaded:
        # `_import_and_check` wrote the resolved pool size back, as `main`'s
        # does, so `blocking_threads` is the number the server would use.
        var blocking = opts.blocking_threads
        var executor = imported.executor
        report.add_int(
            String("topology"), String("blocking_threads"), blocking
        )
        report.add_fact(
            String("topology"),
            String("blocking_threads_source"),
            String("default") if imported.auto_pool else String("configured"),
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
        # WHICH LOOP, which `mode` does not say: it answered `single` for
        # the pump and for the inversion alike, so the two shapes were
        # indistinguishable from outside the process and only the startup
        # banner told you which one you had. `use_loop_inversion` over
        # `pool_thread_count` is exactly what `_serve_offloaded` branches
        # on, so this cannot drift from what actually runs. "n/a" where no
        # executor serves the application at all (WSGI, or an explicit pool).
        var loop_shape: String
        if not executor:
            loop_shape = String("n/a")
        elif use_loop_inversion(
            opts, executor, pool_thread_count(opts, executor, blocking)
        ):
            loop_shape = String("inverted")
        else:
            loop_shape = String("pump")
        report.add_fact(String("topology"), String("loop"), loop_shape)
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
    report.add_int(
        String("server"), String("max_keepalive_requests"),
        opts.max_keepalive_requests,
    )
    report.add_int(
        String("server"), String("idle_timeout"), opts.idle_timeout
    )
    report.add_int(
        String("server"), String("body_timeout"), opts.body_timeout
    )
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
    # Before the checks below, which stop at the first failure where the
    # doctor's job is to report all of them at once.
    if opts.show_doctor:
        process_exit(_run_doctor(opts))
        return

    # Everything decidable without an interpreter, refused before the bind
    # and the fork: `flag_checks`, the list `--doctor` renders, read here to
    # its first failure. Before the bind because a refusal after it ran in
    # every worker and never in the supervisor -- the server forked, every
    # child refused, the parent respawned them -- so a usage error read as a
    # crash loop, which is how the pg-listen and mount refusals first shipped.
    refuse_first(flag_checks(opts, _check_facts(opts)))

    # Bind before forking; every worker accepts from this one socket.
    var listener = _listen_or_fail(opts)

    # Then everything `--realtime` shares, still before the fork and still
    # before the first Python call. Inert without the flag.
    var channels = opts.threads if opts.threads > 1 else opts.workers
    var bus = _prepare_realtime(opts, channels)
    var share = prefork_accept_share(opts.workers)

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
    var is_supervised = supervised(opts)
    var worker = 0
    # A spawned worker is a supervised process that must NOT supervise: its
    # parent already does, and it serves the index it was exec'd with.
    var spawned = spawned_worker_index()
    if spawned >= 0:
        is_supervised = False
        worker = spawned
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
    if is_supervised:
        var supervisor = WorkerSupervisor(opts.workers)
        if opts.reload:
            supervisor.enable_reload(_reload_dirs(opts), String(".py"))
        if opts.spawn_workers:
            # The worker re-runs THIS argv in a fresh image; the listener,
            # the bus and the shared page reach it by fd through the env
            # exports above. `executable_path` rather than argv[0], which
            # may be a bare name or relative to a cwd the worker keeps.
            var full_argv = List[String]()
            for i in range(len(raw)):
                full_argv.append(String(raw[i]))
            supervisor.enable_spawn(executable_path(), full_argv^)
        supervisor.fork_all()
        worker = supervisor.worker_index
    # Accept sharing binds to this worker's index; inert with one worker
    # (`--threads` included), so a single-worker server pays nothing.
    bind_accept_share(share, worker, shared_id_addr())

    if opts.threads > 1:
        # The listener is borrowed, not reduced to its fd: its last use would
        # otherwise be that read, and Mojo's destroy-at-last-use would close
        # the listening socket before the threads dup it — the dup then lands
        # on whatever descriptor number the kernel recycled, and four loops
        # watch a pipe. Prefork never hits this because `serve_nonblocking`
        # uses the listener itself, later.
        _serve_threaded(opts, listener, bus)
        if is_supervised:
            # Forked, so it must leave through `exit_worker()` — returning
            # from `main` runs a teardown that reaches into libdispatch.
            exit_worker()
        return

    # The first Python call in this process: import what is served and
    # decide the pool and the executor, WITHOUT building a bridge -- the
    # executor decision needs the protocol before any lifespan may run --
    # then refuse by the checks that needed the import (`app_checks`, the
    # doctor's too). In the worker, so a refusal is 78 or 1, which the
    # supervisor stops on rather than respawning (E10).
    var imported = _import_and_check(opts)
    refuse_first(imported.checks)
    var is_asgi = imported.is_asgi
    var auto_pool = imported.auto_pool
    var executor_mode = imported.executor
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
        + (" reload" if opts.reload else "")
        + (" spawn" if opts.spawn_workers and opts.workers > 1 else "")
        + (" shared-accepts" if share.active() else ""),
        flush=True,
    )
    var server_config = opts.server_config(AppConfig(default_port=DEFAULT_PORT))
    # After fork_all — each worker arms its own pipe.
    var shutdown_fd = install_shutdown_signals()

    # The Postgres listener, worker 0 only: every worker running one would
    # open its own connection and deliver its own copy of every
    # notification. The same rule `apps/datastar_counter` follows for its
    # tick. Started AFTER fork_all() returned, like every other thread here,
    # and stopped on both serve paths below.
    var pg = PgListener()
    if opts.pg_listen and worker == 0:
        try:
            pg = PgListener.start(
                opts.pg_listen,
                String(DEFAULT_CHANNEL),
                bus.write_fds.copy(),
                # The shared id slot, so a NOTIFY's event id is monotonic
                # across workers exactly as an in-process publish's is —
                # `Last-Event-ID` means nothing otherwise. Exported by
                # `_prepare_realtime` before the fork; 0 when there is none.
                shared_id_addr(),
            )
        except e:
            # A listener that cannot start is not a reason to refuse to
            # serve: the server's own job is unaffected, and the thread
            # would retry a connection anyway. It is loud, and --doctor
            # reports the same condition before anything starts.
            print("m0serve: pg-listen did not start: " + String(e), flush=True)

    if serves_offloaded(opts, executor_mode, opts.blocking_threads):
        # Offloaded serving under prefork: this process gets one acceptor
        # loop and either the asyncio executor (ASGI) or a handler pool.
        # The threads are spawned AFTER `fork_all()` returned and after the
        # resolve above made this process's first Python call, so the
        # prefork rule is untouched — a forked child that then makes
        # threads is fine; a threaded parent that then forks is not.
        _serve_offloaded(
            opts, listener, handler, server_config, shutdown_fd,
            executor_mode,
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
            accept_share=share,
        )
        # The loop's own handler serves the inline fallback; in executor
        # mode its lifespan never ran, and shutdown just closes its loop.
        handler.shutdown()
        pg.stop()
        if is_supervised:
            exit_worker()
        return

    var server = Server(server_config^)
    # `bus.read_fd` answers -1 off the flag, which is what "no bus" means to
    # the loop. Passed unconditionally under `--realtime`, single worker
    # included: draining our own channel IS local delivery, because `m0pub`
    # writes every channel including the publisher's. There is no second
    # delivery path to keep in sync with this one.
    if opts.qos:
        _ = request_qos_class(QOS_CLASS_USER_INTERACTIVE)
    # The handler runs inline here, so the loop stays attached while it
    # works -- but it must NOT stay attached while it waits. This thread has
    # held the GIL since `Py_Initialize`, and a thread blocked in `kevent`
    # never reaches the eval breaker that would hand it over: a thread the
    # application starts ran only when a request happened to run Python
    # (#310, SPEC E20).
    # `DetachingBackend` releases the thread state around each wait and
    # restores it after, the threaded mode's shape.
    var backend = DetachingBackend[PlatformBackend](PlatformBackend())
    run_event_loop(
        listener.socket.fd, handler, backend, server.config,
        server.address(), server.tcp_keep_alive,
        shutdown_fd, bus.read_fd(worker),
        accept_share=share,
    )
    # Only the fd number crossed; without this the listener is destroyed --
    # and its socket closed -- before the loop's first `fcntl` on it.
    _ = listener
    handler.shutdown()
    pg.stop()
    if is_supervised:
        exit_worker()


def _serve_offloaded(
    opts: ServeOptions,
    listener: NoTLSListener[NetworkType.tcp4],
    mut handler: WSGIHandler,
    config: ServerConfig,
    shutdown_fd: Int,
    executor: Bool,
    peer_bus_fd: Int = -1,
    hold_notify_fd: Int = -1,
    accept_share: AcceptShare = AcceptShare(),
) raises:
    """One acceptor loop feeding either a handler pool or the executor.

    `--blocking-threads N` (WSGI, or the ASGI escape hatch) puts N handler
    threads behind the loop; `executor` puts the one asyncio-executor
    thread there instead — both speak the same `OffloadPool`, so the loop
    is identical either way. With `--mount`, both run AT ONCE, each mount on
    its own lane, so sync applications and async ones share this loop, this
    listener and this shutdown while each keeps its native concurrency.
    `wire_offload` lays the lanes and starts their threads, the same wiring
    each `--threads` loop uses (`threaded._serve_one`); what is prefork's
    alone stays here -- the inversion, the compiled mounts' pools, whose
    handler types are this file's, and the loop that holds no thread state.

    `Server.serve_nonblocking` is bypassed for that last one — the loop
    thread serves with NO thread state (docs/notes/detached-loop.md). It
    runs no Python except the inline fallback, which `WSGIHandler.func`
    attaches around for itself. Attached, it re-acquired the GIL after every
    wait and was blocked in that acquire 36–45 % of wall time under load, so
    the executor's and the pool's Python never overlapped its own parsing
    and writing; detached, the executor and pool rows ran +50–100 %.
    `M0_LOOP_ATTACHED=1` restores the old shape for an A/B.

    `peer_bus_fd` is this worker's BroadcastBus channel (M0_WORKERS>1),
    registered beside the chunk channel: GRIP-named frames on it are
    forwarded to the executors for `state["m0"]` subscribers.
    `hold_notify_fd` is how a pool thread's hold under `--realtime` reaches
    this loop's registries: a reserved frame on this loop's own bus channel.
    """
    var pool = OffloadPool(config.max_connections)
    # Without a GIL a parked thread beside a queued job is an idle core,
    # so the pool wakes eagerly there (`OffloadPool.parallel`). A Python
    # call, startup-only, on the worker's attached main thread — after
    # the process's first.
    pool.set_parallel(not probe_free_threading().gil_enabled)
    if use_loop_inversion(
        opts, executor, pool_thread_count(opts, executor, opts.blocking_threads)
    ):
        # M0_INVERTED: the loop inversion, on one thread. Unmounted,
        # pool-free ASGI only -- the benchmark shape -- and behind the
        # variable until its gate passes (docs/ROADMAP.md, "The loop
        # inversion"), so the A/B against the pump is one env var. Every
        # other topology stays on the pump below.
        #
        # Known limitation, measured 2026-08-29 and recorded rather than
        # fixed: the drain is the blocking first cut, so a request that
        # is mid-await at SIGTERM is answered at the 5 s drain deadline
        # (5.30 s for a 1.5 s request; the pump answers it at 1.50 s).
        # Give an inverted server a stop grace of 10 s or more. The
        # reshaped drain is ROADMAP design item 6, deferred to the
        # inversion's promotion bar.
        pool.enable_stream_channel()
        pool.enable_base_stream_ack()
        serve_inverted(
            opts, listener.socket.fd, config, opts.address(), shutdown_fd,
            pool, peer_bus_fd, accept_share,
        )
        return
    var opts_ptr = Pointer(to=opts)
    var opts_addr = Pointer(to=opts_ptr).unsafe_bitcast[Int]()[]
    var threads = wire_offload[WSGIHandler](
        pool, handler, opts, executor, opts.blocking_threads, opts_addr,
        hold_notify_fd=hold_notify_fd,
    )
    # The compiled mounts' workers, sized and reserved by `wire_offload`.
    # They are started like the WSGI pool and are unlike it in the one way
    # that matters: `MojoPool`'s body has no attach/detach bracket, because
    # there is nothing to attach to. A job on one of these lanes never
    # touches the interpreter, which is what lets this mount answer while
    # every Python thread is behind the GIL. Two `MojoPool`s rather than one
    # because `start[T]` is generic over the handler, and each lane is dealt
    # only its own kind.
    if threads.mojo_pool.count > 0:
        threads.mojo_pool.start[MojoMount](
            pool.addr(), user=0, lanes=mojo_lanes(opts)
        )
    if threads.hold_pool.count > 0:
        threads.hold_pool.start[HoldMount](
            pool.addr(), user=0, lanes=hold_lanes(opts)
        )

    var stream_bus_fd = pool.stream_chunk_read if pool.chunk_active() else -1

    # The loop releases its thread state here and takes it back only after
    # `run_event_loop` returns. Everything the loop does in between is Mojo;
    # `WSGIHandler.func` attaches for itself on the inline fallback. The
    # detached wait below is then a plain wait. Attached (M0_LOOP_ATTACHED=1,
    # the A/B knob) is the pre-0.18 shape: re-attach after every wait.
    var loop_attached = getenv("M0_LOOP_ATTACHED", "") == "1"
    ref cpy0 = Python().cpython()
    if not loop_attached:
        handler.set_attach_in_func()
    var loop_ts = cpy0.PyEval_SaveThread()
    if loop_attached:
        cpy0.PyEval_RestoreThread(loop_ts)

    if opts.qos:
        _ = request_qos_class(QOS_CLASS_USER_INTERACTIVE)
    var backend = DetachingBackend[PlatformBackend](PlatformBackend())
    if not loop_attached:
        backend.set_loop_detached()
    run_event_loop(
        listener.socket.fd, handler, backend, config, opts.address(), True,
        shutdown_fd, stream_bus_fd, pool.addr(),
        peer_bus_fd=peer_bus_fd,
        accept_share=accept_share,
    )
    if not loop_attached:
        cpy0.PyEval_RestoreThread(loop_ts)

    join_offload(threads, pool, "m0serve: ")
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
    thread (`probe_free_threading` is the first Python call, and
    `interpreter_checks` the place a GIL-enabled interpreter is refused,
    before anything is imported), the application is imported once here so
    Django's `setup()` runs single-threaded, the signal pipe is armed once
    for the process — and only then does `ThreadedServer.serve` detach this
    thread and spawn the loops, each of which builds its own `WSGIHandler`
    from `opts` via `WSGIHandler.make` and wires its pool as prefork's
    worker does (`wire_offload`). No fork, so `main` returns normally.

    Under `--realtime` each thread also drains its own bus channel, exactly
    as a worker drains its own. `bus` was built on the main thread before
    any of this, so `M0_BUS_WRITE_FDS` is already in the environment the
    interpreter is about to snapshot, and `m0pub` reaches N threads with the
    same N `os.write`s it used to reach N processes — it never learns which
    it is talking to.
    """
    var interp = probe_free_threading()
    refuse_first(interpreter_checks(opts, interp))
    # The Postgres listener, once for the process — there is one here, where
    # prefork has one per worker and starts it only on worker 0. It publishes
    # to `bus.write_fds`, which in this mode is one channel per THREAD, and
    # each thread drains its own exactly as a worker does; the listener never
    # learns which it is talking to, for the same reason `m0pub` does not.
    # Started before the interpreter is touched and stopped after the loops
    # join, so it is outside every Python rule this function exists to keep.
    var pg = PgListener()
    if opts.pg_listen:
        try:
            pg = PgListener.start(
                opts.pg_listen,
                String(DEFAULT_CHANNEL),
                bus.write_fds.copy(),
                shared_id_addr(),
            )
        except e:
            print("m0serve: pg-listen did not start: " + String(e), flush=True)
    # Import once on main (so Django's setup() runs single-threaded) and
    # detect the protocol while at it — the imports below are sys.modules
    # hits for every serving thread. Then the checks that needed it, as
    # prefork's worker makes them: `--threads` REQUIRES a free-threaded
    # build and the executor cannot run on one, so an ASGI application is
    # refused here whatever the thread count; and each loop deals its
    # --blocking-threads over the WSGI lanes exactly as prefork's does, so
    # the same shortfall leaves the same mount unserved.
    var imported = _import_and_check(opts, interp.copy())
    refuse_first(imported.checks)
    var is_asgi = imported.is_asgi
    var auto_pool = imported.auto_pool
    var executor_mode = imported.executor
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
    # Stopped after the loops join and BEFORE the exit below, so a startup
    # failure does not leave the listener holding a connection while the
    # process ends.
    pg.stop()
    if failed > 0:
        process_exit(EXIT_STARTUP)
