"""Command-line options for `m0serve`, parsed without touching the interpreter.

`m0serve` is the uvicorn-shaped entry point: one built binary that takes
`MODULE[:ATTR]` and the usual flags, and serves any WSGI application. This
module is the pure half — `ServeOptions`, the parser, the size and spec
helpers, and the `--help` text — kept free of `std.python` and of `getenv`
inside the parser so it is testable in `test-wsgi`, which needs no Python.

Precedence is **flag > `M0_*` environment > default**, achieved by layering:
`ServeOptions.from_env()` seeds from `AppConfig` (so every `M0_` variable keeps
its meaning and its one parser in `m0_http.config`), and `parse_args` then
overrides whatever flags name. That is also why the parser takes a seed rather
than reading the environment itself.

Flags are strict where the environment is lenient. `_parse_int_env` swallows
`M0_PORT=80eighty` and serves on the default — a defensible choice for a
variable a container set, documented as a sharp edge in `test_config.mojo`.
A person who typed `--port 80eighty` at a prompt wants to be told, so every
flag value is validated and a bad one is a usage error (exit 2), never a
silent default.
"""

from std.ffi import external_call
from std.sys.info import CompilationTarget

from lightbug_http.offload import match_path_prefix
from lightbug_http.server_config import ServerConfig
from m0_http.config import AppConfig


comptime M0SERVE_VERSION = "0.9.0"
"""Reported by `--version`. Bumped with the release (see docs/RELEASING.md)."""

comptime DEFAULT_ATTRIBUTE = "application"
"""PEP 3333's conventional name, and gunicorn's default — not uvicorn's `app`."""

comptime DEFAULT_PORT = 8000
"""The port uvicorn and gunicorn default to; the in-repo rows always pass `--port`."""

comptime EXIT_USAGE = 2
"""A bad command line — getopt's and click's convention."""

comptime EXIT_STARTUP = 1
"""The application could not be loaded or the server could not start."""

comptime PROTOCOL_AUTO = "auto"
"""Detect WSGI vs ASGI from the application object at load time."""

comptime PROTOCOL_WSGI = "wsgi"

comptime PROTOCOL_ASGI = "asgi"

comptime MAX_AUTO_BLOCKING_THREADS = 8
"""Cap on the zero-config handler pool. Past the count of cores the pool's
parallelism is waiting, not computing, and each thread costs a live handler
(interpreter state included); eight covers the common core counts without
turning a 128-core box into 128 interpreters nobody asked for."""


struct ServeOptions(Copyable, Movable):
    """Everything `m0serve` needs to know, after flags and environment agree."""

    var module: String
    """Importable module holding the application callable, e.g. `myproject.wsgi`."""
    var attribute: String
    """Name of the callable in that module."""
    var attribute_explicit: Bool
    """Whether the user wrote `:ATTR` themselves. A bare MODULE may fall back
    to the discovery conventions (`discovery_specs`) when the default
    attribute is not there; an explicit one never does."""
    var mount_prefixes: List[String]
    """URL prefixes of mounted applications, parallel to `mount_modules`,
    `mount_attributes` and `mount_explicit`. Empty when the server hosts the
    one application the positional spec names — the ordinary case.

    A prefix is stored **without** its trailing slash, so the root mount `/`
    is the empty string: exactly PEP 3333's `SCRIPT_NAME` for an application
    at the root, and exactly ASGI's `root_path`. Longest match wins, which is
    what lets `/` and `/app` coexist without either shadowing the other.
    """
    var mount_modules: List[String]
    var mount_attributes: List[String]
    var asgi_mount: Int
    """Index of the ASGI mount, or -1 when every mount is WSGI.

    Written by `m0serve`'s detection pass, not by a flag. It is what decides
    which submit lane the asyncio executor reads while the handler pool
    serves the others — the per-mount execution mode that makes a mixed
    sync/async process worth having.
    """
    var mount_explicit: List[Bool]
    """Per mount, whether the user wrote `:ATTR`. Discovery applies to a
    mount exactly as it does to a positional spec, and for the same reason:
    an explicit attribute never falls back."""
    var protocol: String
    """`auto` (detect from the object), or a forced `wsgi` / `asgi`."""
    var host: String
    var port: Int
    var workers: Int
    var threads: Int
    """Serving threads in one process (free-threaded CPython only); 1 = off."""
    var blocking_threads: Int
    """Handler threads per event loop; 0 = off, and the loop calls handlers itself.

    Stage B. The loop becomes an acceptor: it parses the request, hands it to
    a pool thread, and goes back to `wait()`, so one slow view no longer holds
    the keep-alive connections that loop happens to own. Explicitly 0 means
    off, and the loop calls handlers itself; when no topology flag or `M0_*`
    topology variable is set at all, `resolve_blocking_threads` turns a small
    pool on by default — one slow view stalling every connection is the wrong
    out-of-box experience. Composes with `--workers` and with `--threads`;
    refused with `--realtime`, whose streaming hooks run on the loop's handler.
    """
    var workers_set: Bool
    """Whether `--workers` or `M0_WORKERS` was given, at any value.

    The three `*_set` fields exist so zero-config can tell "one worker
    because nobody said" from "one worker, and I chose that" — only the
    former lets `resolve_blocking_threads` pick a default pool.
    """
    var threads_set: Bool
    var blocking_threads_set: Bool
    var handler_lifespan: Bool
    """Internal, never a flag: whether handlers built from these options
    run ASGI lifespan in their own bridge. The executor mode sets it False
    so per-loop fallback handlers do not run a second lifespan beside the
    executor's — the executor's own app is built with lifespan on,
    explicitly."""
    var asgi_streaming: Bool
    """Internal, never a flag: executor mode with the streaming channel —
    handlers built from these options size their registries so ASGI
    response chunks have per-slot outboxes to ride."""
    var app_dir: String
    """Prepended to `sys.path` so `module` can be imported; relative to cwd."""
    var static_prefixes: List[String]
    """URL prefixes of static mounts, parallel to `static_dirs`."""
    var static_dirs: List[String]
    var static_cache_control: String
    var access_log: Bool
    var max_body: Int
    """Request body cap in bytes; -1 leaves `ServerConfig`'s default alone."""
    var metrics: Bool
    var realtime: Bool
    """Hold SSE streams and WebSockets that the application approves.

    Off by default: it costs two `SSERegistry` slot arrays, a `BroadcastBus`
    and a `SharedAtomics` page, and it makes `M0-Hold` a header the server
    consumes rather than one the application may emit for its own reasons.
    """
    var reload: Bool
    """Restart workers when a watched `.py` changes. A development flag.

    Forces a supervisor even for one worker and under `--threads`, because
    something has to outlive the process it restarts.
    """
    var reload_dirs: List[String]
    """Directories `--reload` watches; empty means `--app-dir` alone."""
    var health_path: String
    """Path answered in Mojo with a liveness JSON; empty = the app owns it.

    Opt-in for the same reason: a WSGI application may already route
    `/health`, and a server that silently took the path would shadow it.
    """
    var show_help: Bool
    var show_version: Bool

    def __init__(out self):
        """Hard defaults — what applies when neither flag nor env says."""
        self.module = String("")
        self.attribute = String(DEFAULT_ATTRIBUTE)
        self.attribute_explicit = False
        self.mount_prefixes = List[String]()
        self.mount_modules = List[String]()
        self.mount_attributes = List[String]()
        self.mount_explicit = List[Bool]()
        self.asgi_mount = -1
        self.protocol = String(PROTOCOL_AUTO)
        self.host = String("0.0.0.0")
        self.port = DEFAULT_PORT
        self.workers = 1
        self.threads = 1
        self.blocking_threads = 0
        self.workers_set = False
        self.threads_set = False
        self.blocking_threads_set = False
        self.handler_lifespan = True
        self.asgi_streaming = False
        self.app_dir = String(".")
        self.static_prefixes = List[String]()
        self.static_dirs = List[String]()
        self.static_cache_control = String("")
        self.access_log = False
        self.max_body = -1
        self.metrics = False
        self.realtime = False
        self.reload = False
        self.reload_dirs = List[String]()
        self.health_path = String("")
        self.show_help = False
        self.show_version = False

    def __init__(out self, *, copy: Self):
        self.module = copy.module
        self.attribute = copy.attribute
        self.attribute_explicit = copy.attribute_explicit
        self.mount_prefixes = copy.mount_prefixes.copy()
        self.mount_modules = copy.mount_modules.copy()
        self.mount_attributes = copy.mount_attributes.copy()
        self.mount_explicit = copy.mount_explicit.copy()
        self.asgi_mount = copy.asgi_mount
        self.protocol = copy.protocol
        self.host = copy.host
        self.port = copy.port
        self.workers = copy.workers
        self.threads = copy.threads
        self.blocking_threads = copy.blocking_threads
        self.workers_set = copy.workers_set
        self.threads_set = copy.threads_set
        self.blocking_threads_set = copy.blocking_threads_set
        self.handler_lifespan = copy.handler_lifespan
        self.asgi_streaming = copy.asgi_streaming
        self.app_dir = copy.app_dir
        self.static_prefixes = copy.static_prefixes.copy()
        self.static_dirs = copy.static_dirs.copy()
        self.static_cache_control = copy.static_cache_control
        self.access_log = copy.access_log
        self.max_body = copy.max_body
        self.metrics = copy.metrics
        self.realtime = copy.realtime
        self.reload = copy.reload
        self.reload_dirs = copy.reload_dirs.copy()
        self.health_path = copy.health_path
        self.show_help = copy.show_help
        self.show_version = copy.show_version

    def __init__(out self, *, deinit move: Self):
        self.module = move.module^
        self.attribute = move.attribute^
        self.attribute_explicit = move.attribute_explicit
        self.mount_prefixes = move.mount_prefixes^
        self.mount_modules = move.mount_modules^
        self.mount_attributes = move.mount_attributes^
        self.mount_explicit = move.mount_explicit^
        self.asgi_mount = move.asgi_mount
        self.protocol = move.protocol^
        self.host = move.host^
        self.port = move.port
        self.workers = move.workers
        self.threads = move.threads
        self.blocking_threads = move.blocking_threads
        self.workers_set = move.workers_set
        self.threads_set = move.threads_set
        self.blocking_threads_set = move.blocking_threads_set
        self.handler_lifespan = move.handler_lifespan
        self.asgi_streaming = move.asgi_streaming
        self.app_dir = move.app_dir^
        self.static_prefixes = move.static_prefixes^
        self.static_dirs = move.static_dirs^
        self.static_cache_control = move.static_cache_control^
        self.access_log = move.access_log
        self.max_body = move.max_body
        self.metrics = move.metrics
        self.realtime = move.realtime
        self.reload = move.reload
        self.reload_dirs = move.reload_dirs^
        self.health_path = move.health_path^
        self.show_help = move.show_help
        self.show_version = move.show_version

    @staticmethod
    def from_env() -> Self:
        """Defaults overlaid with whatever `M0_*` variables are set.

        Delegates to `AppConfig` so the environment has exactly one parser in
        the repo; only the fields a flag can also name are taken from it.
        """
        var config = AppConfig(default_port=DEFAULT_PORT)
        var opts = Self()
        opts.host = config.host
        opts.port = config.port
        opts.workers = config.workers
        opts.threads = config.threads
        opts.blocking_threads = config.blocking_threads
        opts.workers_set = config.workers_set
        opts.threads_set = config.threads_set
        opts.blocking_threads_set = config.blocking_threads_set
        opts.access_log = config.access_log
        return opts^

    def address(self) -> String:
        """The listen address, `host:port`."""
        return self.host + ":" + String(self.port)

    def spec(self) -> String:
        """The `module:attribute` pair as the user would write it."""
        return self.module + ":" + self.attribute

    def served(self) -> String:
        """What this server hosts, as the banner reports it.

        The positional `module:attribute`, or every mount as
        `PREFIX=module:attribute` joined by commas (the root mount shown as
        `/`, since the empty string it is stored as would read as a typo).
        """
        if len(self.mount_prefixes) == 0:
            return self.spec()
        var out = String("")
        for i in range(len(self.mount_prefixes)):
            if i > 0:
                out += ","
            ref shown = self.mount_prefixes[i]
            out += ("/" if shown.byte_length() == 0 else shown) + "="
            out += self.mount_modules[i] + ":" + self.mount_attributes[i]
        return out^

    def server_config(self, base: AppConfig) -> ServerConfig:
        """`base.server_config()` with the flags that reach `ServerConfig` applied.

        `--access-log` can only turn logging on (the environment may already
        have); `--max-body` and `--metrics` are the first two server-only
        tunings the environment cannot reach and a command line can.
        """
        var sc = base.server_config()
        if self.access_log:
            sc.access_log = True
        if self.max_body >= 0:
            sc.max_request_body_size = self.max_body
        sc.enable_metrics = self.metrics
        return sc^


def parse_app_spec(spec: String) raises -> Tuple[String, String]:
    """Split `MODULE[:ATTR]`; the attribute defaults to `application`.

    `myproject.wsgi` and `myproject.wsgi:application` mean the same thing.
    An empty module, or a colon with nothing after it, is an error — both
    are typos, and importing `""` would fail five lines deep in Python with
    a message that names none of this.
    """
    var text = String(spec.strip())
    var colon = text.find(":")
    if colon < 0:
        if text.byte_length() == 0:
            raise Error("missing MODULE[:ATTR]")
        return (text^, String(DEFAULT_ATTRIBUTE))
    var module = String(StringSlice(text)[byte = :colon])
    var attribute = String(StringSlice(text)[byte = colon + 1 :])
    if module.byte_length() == 0:
        raise Error("missing module before ':' in '" + text + "'")
    if attribute.byte_length() == 0:
        raise Error("missing attribute after ':' in '" + text + "'")
    return (module^, attribute^)


def parse_int(text: String, what: String) raises -> Int:
    """Strict decimal parse; anything but digits is a usage error."""
    var digits = String(text.strip())
    var n = digits.byte_length()
    if n == 0 or n > 18:
        raise Error(what + " must be a number, got '" + text + "'")
    var bytes = digits.as_bytes()
    var value = 0
    for i in range(n):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            raise Error(what + " must be a number, got '" + text + "'")
        value = value * 10 + (c - ord("0"))
    return value


def parse_size(text: String) raises -> Int:
    """A byte count: plain digits or a `k`/`m`/`g` suffix (`512k`, `64M`, `1g`).

    Binary units — `k` is 1024 — because that is what every server's body
    cap means and what the 4 MB default is measured in.
    """
    var trimmed = String(text.strip())
    var n = trimmed.byte_length()
    if n == 0:
        raise Error("--max-body must be a size like 4m or 4194304, got ''")
    var last = trimmed.as_bytes()[n - 1]
    var multiplier = 1
    var digits = trimmed
    if last == UInt8(ord("k")) or last == UInt8(ord("K")):
        multiplier = 1024
    elif last == UInt8(ord("m")) or last == UInt8(ord("M")):
        multiplier = 1024 * 1024
    elif last == UInt8(ord("g")) or last == UInt8(ord("G")):
        multiplier = 1024 * 1024 * 1024
    if multiplier != 1:
        digits = String(StringSlice(trimmed)[byte = : n - 1])
    try:
        return parse_int(digits, "--max-body") * multiplier
    except:
        raise Error(
            "--max-body must be a size like 4m or 4194304, got '" + text + "'"
        )


def zero_config_topology(opts: ServeOptions) -> Bool:
    """Whether the user said nothing at all about topology.

    True only when none of `--workers`/`--threads`/`--blocking-threads` (or
    their `M0_*` variables) were given — including at their default values:
    `M0_WORKERS=1` is a choice, and a choice disables the auto default.
    """
    return not (
        opts.workers_set or opts.threads_set or opts.blocking_threads_set
    )


def default_blocking_threads(cpus: Int) -> Int:
    """The zero-config handler-pool size: `min(max(cpus, 1), 8)`.

    Floored at one because a broken CPU probe must not disable the pool
    the caller already decided to start; capped because the parallelism a
    handler pool buys is waiting, and past eight threads per loop the extra
    interpreters' worth of handler state buys nothing (see
    `MAX_AUTO_BLOCKING_THREADS`).
    """
    var floored = cpus if cpus > 1 else 1
    if floored > MAX_AUTO_BLOCKING_THREADS:
        return MAX_AUTO_BLOCKING_THREADS
    return floored


def resolve_blocking_threads(
    opts: ServeOptions, is_asgi: Bool, cpus: Int
) -> Int:
    """The handler-pool size actually used, after zero-config kicks in.

    Explicit topology always wins — any of the three flags or variables, at
    any value, keeps `opts.blocking_threads` verbatim. `--realtime` keeps
    the single-loop shape (the streaming hooks run on the loop's handler,
    which is exactly what a pool breaks — the existing refusal, extended to
    the default). A zero-config WSGI app gets a small pool: one slow view
    must not stall every connection out of the box. A zero-config ASGI app
    gets NO pool, because it gets the asyncio executor instead
    (`use_asgi_executor`) — its concurrency is the application's own
    awaits, and pool threads would only multiply interpreter-side handler
    state for nothing.

    A **mounted** server is decided per mount rather than per process: if
    any mount is WSGI it needs a pool, whatever the others are, because its
    handler threads are the only workers parked on its lane. `is_asgi` for
    a mounted server means "some mount is ASGI" and answers a different
    question — which lane the executor takes — so it must not zero the pool
    here.
    """
    if not zero_config_topology(opts):
        return opts.blocking_threads
    if opts.realtime:
        return 0
    if len(opts.mount_prefixes) > 0:
        var wsgi_mounts = 0
        for i in range(len(opts.mount_prefixes)):
            if i != opts.asgi_mount:
                wsgi_mounts += 1
        return default_blocking_threads(cpus) if wsgi_mounts > 0 else 0
    if is_asgi:
        return 0
    return default_blocking_threads(cpus)


def use_asgi_executor(opts: ServeOptions, is_asgi: Bool) -> Bool:
    """Whether this deployment runs the per-loop asyncio executor.

    The executor is ASGI's default concurrency: requests overlap wherever
    the application awaits, uvicorn's shape. It engages whenever the app
    is ASGI and no handler pool is in play — which zero-config guarantees
    (`resolve_blocking_threads` answers 0 for ASGI) and an explicit
    `--blocking-threads 0` also selects. An explicit `--blocking-threads
    N>0` with an ASGI app keeps the Phase-1 buffered pool instead — the
    documented escape hatch while the executor is young. Call AFTER
    `resolve_blocking_threads`'s answer has been written back into
    `opts.blocking_threads`.
    """
    # A mounted server routes by lane, so the executor serves the ASGI
    # mount while pool threads serve the sync ones; `asgi_mount` names it
    # and the blocking-threads count is about the pool, not about whether
    # the executor runs at all.
    if len(opts.mount_prefixes) > 0:
        return opts.asgi_mount >= 0 and not opts.realtime
    return is_asgi and not opts.realtime and opts.blocking_threads == 0


def effective_cpus() -> Int:
    """Logical CPU count via `sysconf(_SC_NPROCESSORS_ONLN)`; 1 on failure.

    `sysconf` rather than a Python `os.cpu_count()` because the count is
    needed before the fork, and the fork must precede the first Python
    call. The constant differs per platform (glibc 84, macOS 58).
    """
    comptime _SC_NPROCESSORS_ONLN = 58 if CompilationTarget.is_macos() else 84
    var count = external_call["sysconf", Int](Int(_SC_NPROCESSORS_ONLN))
    return count if count > 0 else 1


def discovery_specs(module: String) -> List[String]:
    """The `MODULE:ATTR` specs a bare MODULE tries, in order.

    Zero-config discovery: `m0serve myproject` should find a Django
    project's `asgi.py`/`wsgi.py` and a FastHTML/FastAPI `main.py` without
    the user learning either convention. The given module with the default
    attribute stays first — today's behavior — and the fallbacks only run
    when the user wrote no `:ATTR` and the first candidate fails to load.
    First match wins; a total miss reports every spec tried.
    """
    var specs = List[String]()
    specs.append(module + ":" + String(DEFAULT_ATTRIBUTE))
    specs.append(module + ".asgi:" + String(DEFAULT_ATTRIBUTE))
    specs.append(module + ".wsgi:" + String(DEFAULT_ATTRIBUTE))
    specs.append(module + ":app")
    specs.append(module + ".main:app")
    return specs^


# The flags that take a value, and the booleans. `test_cli.mojo` asserts that
# `usage()` names every one of them, so the help text cannot drift from the
# parser. (Plain comparisons rather than a comptime list of Strings: an
# `Array[String, N]` cannot be materialized at run time on this toolchain.)
def match_mount(prefixes: List[String], path: String) -> Int:
    """Index of the mount serving `path`, or -1 when none does.

    One line, because the rule belongs to exactly one implementation:
    `lightbug_http.offload.match_path_prefix`. The pool's `lane_for` routes
    a job to a worker with the same answer this routes a request to an
    application, and the two must never disagree — a request served by the
    wrong mount is the failure this whole feature exists to avoid.
    """
    return match_path_prefix(prefixes, path)


def _takes_value(name: String) -> Bool:
    return (
        name == "--host"
        or name == "--port"
        or name == "--workers"
        or name == "--threads"
        or name == "--blocking-threads"
        or name == "--app-dir"
        or name == "--static"
        or name == "--static-cache-control"
        or name == "--max-body"
        or name == "--health-path"
        or name == "--reload-dir"
        or name == "--protocol"
        or name == "--mount"
    )


def _is_bool(name: String) -> Bool:
    return (
        name == "--access-log"
        or name == "--metrics"
        or name == "--realtime"
        or name == "--reload"
        or name == "--help"
        or name == "--version"
    )


def _apply(mut opts: ServeOptions, name: String, value: String) raises:
    """Set one value-taking flag, validating as a person at a prompt expects."""
    if name == "--host":
        var host = String(value.strip())
        if host.byte_length() == 0:
            raise Error("--host must not be empty")
        opts.host = String("127.0.0.1") if host == "localhost" else host
    elif name == "--port":
        var port = parse_int(value, "--port")
        if port < 1 or port > 65535:
            raise Error("--port must be between 1 and 65535, got " + value)
        opts.port = port
    elif name == "--workers":
        var workers = parse_int(value, "--workers")
        if workers < 1:
            raise Error("--workers must be at least 1, got " + value)
        opts.workers = workers
        opts.workers_set = True
    elif name == "--threads":
        var threads = parse_int(value, "--threads")
        if threads < 1:
            raise Error("--threads must be at least 1, got " + value)
        opts.threads = threads
        opts.threads_set = True
    elif name == "--blocking-threads":
        var blocking = parse_int(value, "--blocking-threads")
        if blocking < 0:
            raise Error("--blocking-threads cannot be negative, got " + value)
        opts.blocking_threads = blocking
        opts.blocking_threads_set = True
    elif name == "--protocol":
        var protocol = String(value.strip())
        if (
            protocol != PROTOCOL_AUTO
            and protocol != PROTOCOL_WSGI
            and protocol != PROTOCOL_ASGI
        ):
            raise Error(
                "--protocol must be auto, wsgi or asgi, got '" + value + "'"
            )
        opts.protocol = protocol^
    elif name == "--app-dir":
        if value.byte_length() == 0:
            raise Error("--app-dir must not be empty")
        opts.app_dir = value
    elif name == "--static":
        # PREFIX=DIR, split on the FIRST '=': a directory may contain one.
        var eq = value.find("=")
        if eq < 0:
            raise Error("--static expects PREFIX=DIR, got '" + value + "'")
        var prefix = String(StringSlice(value)[byte = :eq])
        var directory = String(StringSlice(value)[byte = eq + 1 :])
        if not prefix.startswith("/"):
            raise Error("--static prefix must start with '/', got '" + prefix + "'")
        if directory.byte_length() == 0:
            raise Error("--static expects PREFIX=DIR, got '" + value + "'")
        opts.static_prefixes.append(prefix^)
        opts.static_dirs.append(directory^)
    elif name == "--mount":
        # PREFIX=SPEC, split on the FIRST '=': a spec never contains one, but
        # splitting last would make a typo'd prefix silently become the spec.
        var meq = value.find("=")
        if meq < 0:
            raise Error("--mount expects PREFIX=MODULE[:ATTR], got '" + value + "'")
        var raw = String(StringSlice(value)[byte = :meq])
        var spec = String(StringSlice(value)[byte = meq + 1 :])
        if not raw.startswith("/"):
            raise Error("--mount prefix must start with '/', got '" + raw + "'")
        # Stored without the trailing slash, so '/' becomes '' -- PEP 3333's
        # SCRIPT_NAME and ASGI's root_path for an app at the root are both
        # the empty string, and the matcher gets one shape to compare.
        var prefix = raw
        while prefix.endswith("/"):
            prefix = String(
                StringSlice(prefix)[byte = : prefix.byte_length() - 1]
            )
        for m in range(len(opts.mount_prefixes)):
            if opts.mount_prefixes[m] == prefix:
                raise Error(
                    "--mount prefix '" + raw + "' is mounted twice"
                )
        var mount_pair = parse_app_spec(spec)
        opts.mount_prefixes.append(prefix^)
        opts.mount_modules.append(mount_pair[0])
        opts.mount_attributes.append(mount_pair[1])
        opts.mount_explicit.append(spec.find(":") >= 0)
    elif name == "--static-cache-control":
        opts.static_cache_control = value
    elif name == "--max-body":
        opts.max_body = parse_size(value)
    elif name == "--reload-dir":
        var watched = String(value.strip())
        if watched.byte_length() == 0:
            raise Error("--reload-dir must not be empty")
        opts.reload_dirs.append(watched^)
    elif name == "--health-path":
        var path = String(value.strip())
        if not path.startswith("/"):
            raise Error(
                "--health-path must start with '/', got '" + value + "'"
            )
        opts.health_path = path^
    else:
        raise Error("unknown option " + name)


def parse_args(args: List[String], seed: ServeOptions) raises -> ServeOptions:
    """Overlay the command line on `seed` (normally `ServeOptions.from_env()`).

    `args` excludes argv[0]. Accepts `--opt value` and `--opt=value`, the
    short forms `-h` and `-V`, and exactly one positional `MODULE[:ATTR]`.
    Raises a one-line message for anything else; the caller prints it with
    `usage()` and exits `EXIT_USAGE`. `--help`/`--version` need no positional.
    """
    var opts = seed.copy()
    var have_module = False
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "-h":
            opts.show_help = True
        elif arg == "-V":
            opts.show_version = True
        elif arg.startswith("--") and arg.byte_length() > 2:
            var name = arg
            var inline = String("")
            var has_inline = False
            var eq = arg.find("=")
            if eq >= 0:
                name = String(StringSlice(arg)[byte = :eq])
                inline = String(StringSlice(arg)[byte = eq + 1 :])
                has_inline = True
            if _is_bool(name):
                if has_inline:
                    raise Error(name + " takes no value")
                if name == "--help":
                    opts.show_help = True
                elif name == "--version":
                    opts.show_version = True
                elif name == "--access-log":
                    opts.access_log = True
                elif name == "--realtime":
                    opts.realtime = True
                elif name == "--reload":
                    opts.reload = True
                else:
                    opts.metrics = True
            elif _takes_value(name):
                var value = inline
                if not has_inline:
                    if i + 1 >= len(args):
                        raise Error(name + " needs a value")
                    i += 1
                    value = args[i]
                _apply(opts, name, value)
            else:
                raise Error("unknown option " + name)
        elif arg.startswith("-") and arg.byte_length() > 1:
            raise Error("unknown option " + arg)
        else:
            if have_module:
                raise Error("unexpected argument '" + arg + "'")
            var pair = parse_app_spec(arg)
            opts.module = pair[0]
            opts.attribute = pair[1]
            opts.attribute_explicit = arg.find(":") >= 0
            have_module = True
        i += 1

    if have_module and len(opts.mount_prefixes) > 0:
        raise Error(
            "--mount and a positional MODULE[:ATTR] are exclusive; give one"
            " --mount per application"
        )
    if (
        not have_module
        and len(opts.mount_prefixes) == 0
        and not opts.show_help
        and not opts.show_version
    ):
        raise Error("missing MODULE[:ATTR]")
    return opts^


def usage() -> String:
    """The `--help` text. Every flag the parser knows appears here."""
    return String(
        "usage: m0serve [OPTIONS] MODULE[:ATTR]\n"
        "\n"
        "Serve a WSGI or ASGI application (Django, Flask, FastHTML, Starlette)\n"
        "with mojo-http; the protocol is detected from the object. MODULE is\n"
        "importable from --app-dir; ATTR defaults to 'application', and a bare\n"
        "MODULE also tries MODULE.asgi, MODULE.wsgi, MODULE:app and\n"
        "MODULE.main:app. Flags override M0_* environment variables.\n"
        "\n"
        "  --host ADDR                 bind address (default 0.0.0.0; M0_HOST)\n"
        "  --port N                    port (default 8000; M0_PORT)\n"
        "  --workers N                 prefork worker processes (default 1; M0_WORKERS)\n"
        "  --threads N                 serving threads in ONE process, free-threaded\n"
        "                              CPython only; exclusive with --workers (M0_THREADS)\n"
        "  --blocking-threads N        handler threads per loop; isolates slow views\n"
        "                              (M0_BLOCKING_THREADS; auto when no topology\n"
        "                              flag or M0_* topology variable is set, 0 = off)\n"
        "  --protocol P                auto (default), wsgi, or asgi — force the\n"
        "                              application protocol instead of detecting it\n"
        "  --app-dir DIR               prepended to sys.path (default .)\n"
        "  --mount PREFIX=SPEC         mount an application at PREFIX instead of\n"
        "                              taking one positional spec; repeatable, and\n"
        "                              each application's protocol is detected on\n"
        "                              its own (longest prefix wins)\n"
        "  --static PREFIX=DIR         serve DIR at PREFIX from Mojo, never entering\n"
        "                              Python; repeatable\n"
        "  --static-cache-control V    Cache-Control for static responses\n"
        "  --access-log                one log line per request (M0_ACCESS_LOG)\n"
        "  --max-body SIZE             request body cap: bytes, or 512k / 64m / 1g\n"
        "                              (default 4m)\n"
        "  --metrics                   serve Prometheus metrics at /__metrics\n"
        "  --realtime                  hold SSE streams and WebSockets the app\n"
        "                              approves with M0-Hold; publish with m0pub.py\n"
        "  --health-path PATH          answer PATH in Mojo with a liveness JSON,\n"
        "                              never entering the application\n"
        "  --reload                    restart workers when a watched .py changes\n"
        "                              (development; forces a supervisor)\n"
        "  --reload-dir DIR            directory --reload watches; repeatable,\n"
        "                              defaults to --app-dir\n"
        "  -h, --help                  show this help and exit\n"
        "  -V, --version               show the version and exit\n"
        "\n"
        "The binary resolves libpython from the python3 on PATH: run it from a\n"
        "virtualenv that has your framework installed, or set MOJO_PYTHON_LIBRARY.\n"
    )
