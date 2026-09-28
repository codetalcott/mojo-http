"""Every refusal `m0serve` makes, as one ordered list `main` and `--doctor` both read.

The shape is the Mojo host's `host_checks`: each rule is evaluated into a
`ServeCheck` -- a verdict, the line the server prints, the fix, and the exit
code -- and the list is in the order the server applies them. `main` stops at
the first failure (`refuse_first`); `--doctor` renders all of them
(`add_checks`) and `Report.exit_code` answers with the first failure's code.
So the doctor cannot call a configuration healthy that the server refuses,
or refuse it for another reason. Until this module the doctor mirrored
`main`'s order by hand, in a second description of every rule.

Three points in `main` evaluate them, because three things happen between:

1. `flag_checks`, BEFORE the bind and the fork: everything decidable from
   the flags, the environment and the filesystem. Nothing here may start
   the interpreter -- the fork must precede the first Python call.
2. `interpreter_checks`, under `--threads`, once the interpreter is up and
   before the application is imported (a GIL-enabled interpreter refuses
   the mode before Django's `setup()` runs).
3. `app_checks`, after the import: what needs the application's protocol.

The doctor evaluates all three in the same order, which is the order its
report lists them in.

The lists are pure functions of `ServeOptions` and of facts the caller
gathers (`CheckFacts`, the interpreter report, the import's outcome), so
`test_checks.mojo` pins the order and every code with no interpreter, no
libpq and no MAX. The directory checks read the filesystem themselves;
every other side effect -- the libpq probe, the interpreter probe, the
import -- is the caller's, done once and handed in.
"""

from std.os import getenv
from std.os.path import isdir
from std.sys.info import CompilationTarget

from lightbug_http.c.process import process_exit
from m0_http import GRANT_KEY_ENV, threads_conflict
from m0_http.parallel_runtime import parallel_runtime_linked

from .cli import (
    ServeOptions,
    usage,
    compiled_mount_threads_needed,
    has_python_mount,
    has_wsgi_mount,
    parallel_runtime_forked,
    pg_listen_forked,
    supervised,
    use_asgi_executor,
    wsgi_lanes,
    wsgi_lanes_unserved,
    EXIT_CONFIG,
    EXIT_STARTUP,
    EXIT_USAGE,
    PROTOCOL_ASGI,
)
from .doctor import Report
from .threaded import (
    FreeThreadingReport,
    asgi_free_threading_refusal,
    free_threading_refusal,
    EXIT_NOT_FREE_THREADED,
)


comptime HOLD_MOUNT_NEEDS_REALTIME = (
    "--mount PREFIX=hold needs --realtime: the flag is what wires a pool"
    " thread's hold to the event loop, and a hold mount can do nothing else"
)
comptime HOLD_MOUNT_NEEDS_KEY = (
    "--mount PREFIX=hold needs M0_GRANT_KEY: the mount verifies grants the"
    " application signed with it (32 random bytes; openssl rand -base64 32)"
)
comptime MOUNTS_WITHOUT_PYTHON = (
    "every --mount is 'mojo' or 'hold', so there is no Python application to"
    " host; write a Mojo server binary instead of using m0serve"
)
comptime COMPILED_MOUNT_UNDER_THREADS = (
    "--mount PREFIX=mojo and PREFIX=hold are not served under --threads: the"
    " threaded loops start no Mojo pool, so the mount would never answer"
)
comptime PARALLEL_RUNTIME_FORKED = (
    "a forked worker cannot serve MAX's parallel runtime: --workers N forks"
    " one, and so does --reload, which supervises even a single worker, and"
    " this binary links libAsyncRTMojoBindings -- what"
    " max.algorithm.parallelize needs -- whose worker threads a fork() does"
    " not copy, so a parallelize in a forked worker never returns. Use"
    " --spawn-workers (the worker forks, then execs this binary, and the"
    " runtime starts fresh in it), or --workers 1 without --reload"
)
comptime PARALLEL_RUNTIME_FIX = "--spawn-workers, or --workers 1 without --reload"
comptime PG_LISTEN_NEEDS_REALTIME = (
    "--pg-listen needs --realtime: the flag is what creates the broadcast bus"
    " and the subscriber registries, and a listener with nothing to publish"
    " into can do nothing at all"
)
comptime PG_LISTEN_FORKED_ON_MACOS = (
    "--pg-listen with a forked worker is refused on macOS: --workers N forks"
    " one, and so does --reload, which supervises even a single worker."
    " libpq's connect reaches GSSAPI, which reaches Kerberos and"
    " CoreFoundation, and Objective-C aborts a forked child rather than run"
    " in one. The worker dies with SIGKILL and the supervisor respawns it,"
    " which reads as a load problem and is not. Use --spawn-workers (the"
    " child execs, so the rule does not apply; it composes with --reload),"
    " or serve without --reload on one worker or --threads, or put"
    " gssencmode=disable in the connection string if you do not use GSSAPI"
    " encryption"
)
comptime REALTIME_ASGI_CONFLICT = (
    "--realtime requires a WSGI application: the M0-Hold contract is a"
    " response-header protocol for buffered WSGI responses, and an ASGI"
    " application streams through its own send() instead. Serve it without"
    " --realtime."
)
comptime _REALTIME_FIX = "drop --realtime; an ASGI app streams natively"


struct ServeCheck(Copyable, Movable):
    """One rule the server refuses by, evaluated: an entry of the list."""

    var name: String
    """The doctor's name for it (`app-dir`, `threads-vs-workers`, ...). Stable:
    smokes and scripts find a check in the report by it."""
    var ok: Bool
    var detail: String
    """What was found. When not ok, the line the server prints."""
    var fix: String
    """What to change, for the doctor's report. Empty when ok."""
    var code: Int
    """The exit code the server leaves with when this is its first failure;
    0 when ok."""
    var usage: Bool
    """The server prints `usage()` before the line, as for the two flag
    combinations that are wrong on any machine."""
    var prefixed: Bool
    """The server prints the line after `m0serve: `. False for the threaded
    mode's guard alone, whose message has named its package
    (`m0-wsgi: M0_THREADS=...`) since it was written, and is printed as it
    always was."""

    def __init__(out self, var name: String, var detail: String):
        """A rule that passed."""
        self.name = name^
        self.ok = True
        self.detail = detail^
        self.fix = String("")
        self.code = 0
        self.usage = False
        self.prefixed = True

    def __init__(
        out self,
        var name: String,
        var detail: String,
        var fix: String,
        code: Int,
        usage: Bool = False,
        prefixed: Bool = True,
    ):
        """A rule that failed, with the code the server exits with."""
        self.name = name^
        self.ok = False
        self.detail = detail^
        self.fix = fix^
        self.code = code
        self.usage = usage
        self.prefixed = prefixed


struct CheckFacts(Copyable, Movable):
    """What `flag_checks` needs that is not in the options.

    Gathered once by the caller and handed in, which is what lets the unit
    test supply each by hand: the platform, whether this binary links MAX's
    parallel runtime, whether the grant key is set, and -- only when the
    list reaches it (`pg_listen_needs_libpq`) -- the libpq probe's outcome,
    which the caller makes because this module does not link the Postgres
    bindings.
    """

    var macos: Bool
    var parallel_runtime: Bool
    var grant_key_set: Bool
    var libpq_probed: Bool
    var libpq_error: String
    """Why the library could not be opened; empty when it was found."""
    var libpq_found: String
    """What was found (`libpq 16.4 at /path`), for the doctor."""

    def __init__(
        out self,
        macos: Bool,
        parallel_runtime: Bool,
        grant_key_set: Bool,
    ):
        self.macos = macos
        self.parallel_runtime = parallel_runtime
        self.grant_key_set = grant_key_set
        self.libpq_probed = False
        self.libpq_error = String("")
        self.libpq_found = String("")

    @staticmethod
    def gather() -> Self:
        """This process's facts, the libpq probe aside. `parallel_runtime_linked`
        reads the loaded images and starts nothing, so it is safe before the
        fork, where `main` asks it."""
        return Self(
            CompilationTarget.is_macos(),
            parallel_runtime_linked(),
            getenv(GRANT_KEY_ENV, "").byte_length() > 0,
        )

    def libpq(mut self, var error: String, var found: String):
        """Record the probe: `error` when `PgLib.open` raised, else `found`."""
        self.libpq_probed = True
        self.libpq_error = error^
        self.libpq_found = found^


def pg_listen_needs_libpq(opts: ServeOptions, facts: CheckFacts) -> Bool:
    """Whether `flag_checks` reaches the libpq probe: `--pg-listen` with
    `--realtime`, in a process that would not connect from a forked child.
    The caller opens the library exactly then, as `main` always has --
    pre-fork, so an absent one is a refusal naming every path tried rather
    than a listener that silently hears nothing."""
    return (
        len(opts.pg_listen.as_bytes()) > 0
        and opts.realtime
        and not pg_listen_forked(opts, facts.macos)
    )


def realtime_without_wsgi(opts: ServeOptions, is_asgi: Bool) -> Bool:
    """Whether `--realtime` has no application that could ever take a hold.

    `M0-Hold` is a response-header protocol for buffered WSGI responses, so
    the flag needs a WSGI application somewhere. Unmounted that is the whole
    question. **Mounted it is per mount**: a server whose WSGI mounts take
    holds while its ASGI mounts stream through their own executor is exactly
    the mixed application this pair was refused for, and the loop tells the
    two apart by lane. Only a mounted server with no WSGI mount at all is
    asking for nothing -- asked positively, because with three kinds of
    mount "every mount is ASGI" let a server of one Mojo mount take
    `--realtime` with nothing that could ever hold a connection.
    """
    if len(opts.mount_prefixes) == 0:
        return is_asgi
    return not has_wsgi_mount(opts)


def wsgi_lanes_unserved_message(unserved: Int, blocking_threads: Int) -> String:
    """The line for a WSGI mount the resolved pool leaves with no thread."""
    return (
        String(unserved) + " WSGI mount(s) would have no handler thread:"
        + " beside an ASGI mount or a handler pool every mount is served from"
        + " its own lane, and --blocking-threads " + String(blocking_threads)
        + " deals too few threads to give each WSGI mount one, so its"
        + " requests would never be answered. An explicit --blocking-threads is"
        + " honoured as given, never raised; leave it unset and every mount"
        + " gets a thread"
    )


def _rule(
    mut out: List[ServeCheck],
    name: String,
    ok: Bool,
    passed: String,
    refused: String,
    fix: String,
    code: Int,
    usage: Bool = False,
):
    """Append one rule, evaluated: `passed` when `ok`, else refused -- the
    line, its fix and the code the server exits with."""
    if ok:
        out.append(ServeCheck(name, passed))
    else:
        out.append(ServeCheck(name, refused, fix, code, usage=usage))


def flag_checks(opts: ServeOptions, facts: CheckFacts) -> List[ServeCheck]:
    """The rules decidable before the bind, in the order the server applies them.

    None needs an interpreter, and each used to run somewhere later for
    that reason alone: `--pg-listen`'s pair and the mount refusals ran in
    every forked worker, where each child refused, the supervisor respawned
    them and the process ended in "5 rapid crashes" with exit 1 -- a usage
    error read as a crash loop. Before the bind they are one line and the
    right code.

    Which rules appear depends on the configuration -- a mount rule only
    for a mounted server, the pg-listen rule only with `--pg-listen` -- and
    each that appears is evaluated whether or not an earlier one failed, so
    the doctor reports every problem at once; the server stops at the
    first, which is why the order is the contract.
    """
    var out = List[ServeCheck]()

    # The directories, exit 1: what the server was pointed at is not there.
    _rule(out, "app-dir", isdir(opts.app_dir), opts.app_dir + " exists",
        "app dir does not exist: " + opts.app_dir,
        "create it, or pass --app-dir with the directory holding " + opts.module,
        EXIT_STARTUP)
    for i in range(len(opts.static_dirs)):
        ref d = opts.static_dirs[i]
        _rule(out, "static-dir", isdir(d), d + " exists",
            "static dir does not exist: " + d,
            "create it, or drop --static " + opts.static_prefixes[i], EXIT_STARTUP)
    for i in range(len(opts.reload_dirs)):
        ref d = opts.reload_dirs[i]
        _rule(out, "reload-dir", isdir(d), d + " exists",
            "reload dir does not exist: " + d,
            "create it, or drop --reload-dir " + d, EXIT_STARTUP)

    # Flag combinations wrong on any machine: exit 2, with the usage.
    var conflict = threads_conflict(opts.workers, opts.threads)
    _rule(out, "threads-vs-workers", not conflict, "topology flags are consistent",
        conflict.value() if conflict else String(""),
        "give one of --workers or --threads, not both", EXIT_USAGE, usage=True)
    if opts.realtime:
        # The forced half of the ASGI/realtime refusal; the detected half
        # needs the import and is `app_checks`' `realtime-vs-asgi`, with
        # the same line.
        _rule(out, "protocol-vs-realtime", opts.protocol != PROTOCOL_ASGI,
            "--protocol " + opts.protocol + " leaves a WSGI application possible",
            String(REALTIME_ASGI_CONFLICT), _REALTIME_FIX, EXIT_USAGE, usage=True)

    # `--pg-listen`: one rule, its outcome named by the first thing that
    # stops it. The library is opened only when nothing before it has.
    if len(opts.pg_listen.as_bytes()) > 0:
        if not opts.realtime:
            out.append(ServeCheck("pg-listen-vs-realtime", String(PG_LISTEN_NEEDS_REALTIME),
                "add --realtime", EXIT_USAGE))
        elif pg_listen_forked(opts, facts.macos):
            out.append(ServeCheck("pg-listen-vs-fork", String(PG_LISTEN_FORKED_ON_MACOS),
                "add --spawn-workers, or serve one worker without --reload", EXIT_USAGE))
        elif not facts.libpq_probed:
            # A caller that skipped the probe `pg_listen_needs_libpq` asked
            # for. Refused rather than passed: a listener whose library was
            # never looked for is the silent listener this rule prevents.
            out.append(ServeCheck("pg-listen-libpq", "libpq was not probed",
                "open it with PgLib.open() where pg_listen_needs_libpq says to", EXIT_CONFIG))
        elif facts.libpq_error.byte_length() > 0:
            out.append(ServeCheck("pg-listen-libpq", facts.libpq_error,
                "set M0_LIBPQ, or install a libpq where it can be found", EXIT_CONFIG))
        else:
            out.append(ServeCheck("pg-listen", facts.libpq_found))

    # Mount sets some mount could not be served in (SPEC M20), all
    # decidable from the flags: a compiled mount's kind is in its spec.
    var mounts = len(opts.mount_prefixes)
    if mounts > 0:
        # m0serve exists to host Python; `WSGIHandler.build` would have no
        # application to build. `apps/pool_spike` is the Mojo server shape.
        _rule(out, "mounts-without-python", has_python_mount(opts),
            "a Python application is mounted", String(MOUNTS_WITHOUT_PYTHON),
            "mount a Python application beside it, or build a Mojo server binary"
            " (apps/pool_spike is the shape)", EXIT_USAGE)
        if len(opts.hold_mounts) > 0:
            _rule(out, "hold-mount-vs-realtime", opts.realtime, "--realtime is on",
                String(HOLD_MOUNT_NEEDS_REALTIME), "add --realtime", EXIT_USAGE)
            _rule(out, "hold-mount-key", facts.grant_key_set, "M0_GRANT_KEY is set",
                String(HOLD_MOUNT_NEEDS_KEY),
                "export M0_GRANT_KEY, the same value the application signs with",
                EXIT_USAGE)
        var needed = compiled_mount_threads_needed(opts)
        if needed > 0:
            # A compiled mount under --threads was accepted and never
            # served, since the threaded loops start no `MojoPool`.
            _rule(out, "compiled-mount-vs-threads", opts.threads <= 1,
                "no --threads: a Mojo pool serves the compiled mounts",
                String(COMPILED_MOUNT_UNDER_THREADS),
                "serve with --workers N instead of --threads", EXIT_USAGE)
            # Below the count, the mounts were served inline (at 0, where
            # the loop's handler knows only the Python mounts and a request
            # under `/native` fell through to the root application) or by a
            # `MojoPool` with a lane no thread reads. `--workers N` alone is
            # not refused: a compiled mount makes the pool the server's to
            # size (`pool_is_default`).
            _rule(out, "compiled-mount-threads",
                not (opts.blocking_threads_set and opts.blocking_threads < needed),
                "a thread for each compiled mount of a kind",
                "--mount PREFIX=mojo and PREFIX=hold are served by handler threads,"
                + " one per mount of a kind, and --blocking-threads is "
                + String(opts.blocking_threads) + " where these mounts need "
                + String(needed) + ": a lane with no thread never answers, and an"
                + " explicit --blocking-threads is honoured as given, never raised."
                + " Leave it unset and these mounts get the default pool",
                "add --blocking-threads " + String(needed) + " or more", EXIT_USAGE)

    # A forked worker cannot carry MAX's parallel runtime (SPEC E33). The
    # fact is the binary's, so the shipped m0serve -- which links no MAX --
    # passes this one wherever its load commands lack the runtime.
    var runtime = String("MAX's parallel runtime is not linked")
    if facts.parallel_runtime:
        runtime = String("MAX's parallel runtime is linked; ") + (
            String("spawned workers exec and start it fresh")
            if opts.spawn_workers and supervised(opts)
            else String("one process serves it")
        )
    _rule(out, "workers-vs-parallel-runtime",
        not parallel_runtime_forked(opts, facts.parallel_runtime), runtime,
        String(PARALLEL_RUNTIME_FORKED), String(PARALLEL_RUNTIME_FIX), EXIT_USAGE)
    return out^


def interpreter_checks(opts: ServeOptions, interp: FreeThreadingReport) -> List[ServeCheck]:
    """The rule the interpreter decides before the import: under `--threads`,
    free-threaded CPython with the GIL off (`free_threading_refusal`, 78).
    Empty without `--threads`, where nothing is asked of the interpreter."""
    var out = List[ServeCheck]()
    if opts.threads > 1:
        var refusal = free_threading_refusal(opts.threads, interp)
        if refusal:
            out.append(ServeCheck("free-threading", refusal.value(),
                "use --workers N instead, or run on 3.14t with PYTHON_GIL=0",
                EXIT_NOT_FREE_THREADED, prefixed=False))
        else:
            out.append(ServeCheck(
                "free-threading", "interpreter is free-threaded and the GIL is off"
            ))
    return out^


def app_checks(
    opts: ServeOptions,
    load_error: Optional[String],
    is_asgi: Bool,
    interp: Optional[FreeThreadingReport],
) -> List[ServeCheck]:
    """The rules that need the application imported, in the order the server
    applies them. `opts` is the resolved one: the winners of discovery
    written back, `asgi_mounts` filled, and `blocking_threads` the size the
    server will use (`resolve_blocking_threads`).

    `load_error` is the import's failure, and then the list is that one
    entry: every later rule would be judged against an application that is
    not there. `interp` is the interpreter's report when the caller has one;
    without it the executor rule is not evaluated, as a doctor whose probe
    failed invents no refusal.
    """
    var out = List[ServeCheck]()
    if load_error:
        out.append(ServeCheck("application",
            "could not load " + opts.served() + " from " + opts.app_dir + ": "
            + load_error.value(),
            "check --app-dir and the MODULE[:ATTR] spec; a bare MODULE also"
            " tries MODULE.asgi, MODULE.wsgi, MODULE:app and MODULE.main:app",
            EXIT_STARTUP))
        return out^
    out.append(ServeCheck("application",
        opts.served() + " imports and classifies as "
        + (String("asgi") if is_asgi else String("wsgi"))))
    if opts.realtime:
        _rule(out, "realtime-vs-asgi", not realtime_without_wsgi(opts, is_asgi),
            "a WSGI application can take the holds", String(REALTIME_ASGI_CONFLICT),
            _REALTIME_FIX, EXIT_STARTUP)
    var executor = use_asgi_executor(opts, is_asgi)
    if executor and Bool(interp):
        # The executor's `ExecutorPort` is built with `PythonModuleBuilder`,
        # whose `PyObject` is the GIL build's 16-byte header; a
        # free-threaded build's is 32 (modular/modular#5726). The BUILD's
        # layout, not the GIL's state, so `PYTHON_GIL=1` does not help.
        # Under prefork this runs in the worker, where the supervisor stops
        # on the 78 rather than respawning (E10).
        _rule(out, "asgi-vs-free-threading", not interp.value().free_threaded_build,
            "the executor runs on a GIL-enabled build",
            asgi_free_threading_refusal(interp.value()),
            "run this application on a GIL-enabled CPython (3.10-3.14 without the"
            " t suffix), with --workers for concurrency", EXIT_NOT_FREE_THREADED)
    if len(opts.mount_prefixes) > 0:
        # Which mounts are WSGI is decided by importing them, so this is the
        # mount rule that has to wait: on the offloaded loop a job submitted
        # to a lane with no thread is never taken, and the request hangs.
        var unserved = wsgi_lanes_unserved(opts, executor, opts.blocking_threads)
        _rule(out, "wsgi-mount-threads", unserved == 0,
            "no WSGI mount is left without a thread",
            wsgi_lanes_unserved_message(unserved, opts.blocking_threads),
            "add --blocking-threads " + String(len(wsgi_lanes(opts))) + " or more",
            EXIT_CONFIG)
    return out^


def first_refusal(checks: List[ServeCheck]) -> Optional[ServeCheck]:
    """The first check that failed, or None: the one the server stops on."""
    for i in range(len(checks)):
        if not checks[i].ok:
            return checks[i].copy()
    return None


def refuse_first(checks: List[ServeCheck]):
    """`main`'s reading of a list: print the first failure and exit with its
    code. Returns only when every check passed."""
    var refused = first_refusal(checks)
    if not refused:
        return
    ref check = refused.value()
    if check.usage:
        print(usage(), flush=True)
    if check.prefixed:
        print("m0serve: " + check.detail, flush=True)
    else:
        print(check.detail, flush=True)
    process_exit(check.code)


def add_checks(mut report: Report, checks: List[ServeCheck]):
    """`--doctor`'s reading of a list: every entry, in order."""
    for i in range(len(checks)):
        ref check = checks[i]
        if check.ok:
            report.pass_check(check.name, check.detail)
        else:
            report.fail_check(check.name, check.detail, check.fix, check.code)
