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

from std.os import getenv
from std.ffi import external_call
from std.sys.info import CompilationTarget, num_performance_cores

from lightbug_http.offload import match_path_prefix
from lightbug_http.c.platform import SC_NPROCESSORS_ONLN
from lightbug_http.server_config import ServerConfig
from m0_http.config import AppConfig


comptime M0SERVE_VERSION = "1.0.0"
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
    var asgi_mounts: List[Int]
    """Indexes of the ASGI mounts; empty when every mount is WSGI.

    Written by `m0serve`'s detection pass, not by a flag. Each names a
    submit lane one asyncio executor reads while the handler pool serves
    the rest — the per-mount execution mode that makes a mixed sync/async
    process worth having. Several are allowed: executors share only the
    slot-addressed chunk channel, and each gets its own drain-ack pair,
    because credit belongs to the executor that owns the slot.
    """
    var mojo_mounts: List[Int]
    """Indexes of the mounts answered by a compiled-in Mojo handler.

    Written by the `--mount PREFIX=mojo` parse, not by detection: a Mojo
    handler is a compile-time type, not an importable object, so there is
    nothing to detect. Each names a submit lane a `MojoPool` thread reads,
    and those threads never attach to the interpreter at all.

    A third kind, so nothing may infer "not ASGI" to mean "WSGI" — three
    kinds cannot be read off two booleans, and every place that tried is
    listed in `wsgi_lanes`.
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
    composes with `--realtime` too: a hold a pool thread takes reaches the
    loop's registries as a reserved frame on the loop's own bus channel.
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
    """Internal, never a flag: the loop will have a chunk channel — an
    asyncio executor, or a handler pool streaming WSGI iterables — so
    handlers built from these options size their registries to give every
    slot the outbox its chunks ride. The name predates the pool's use of
    the channel."""
    var app_dir: String
    """Prepended to `sys.path` so `module` can be imported; relative to cwd."""
    var static_prefixes: List[String]
    """URL prefixes of static mounts, parallel to `static_dirs`."""
    var static_dirs: List[String]
    var static_cache_control: String
    var access_log: Bool
    var spawn_workers: Bool
    """`--spawn-workers` / `M0_SPAWN_WORKERS`: each worker is forked and then
    execs this binary afresh, so it starts with no inherited runtime state.
    For applications that use what a forked child cannot — Core ML,
    Objective-C, CoreFoundation, libdispatch — at the cost of a second
    process start per worker. Ignored without `--workers` > 1 (or
    `--reload`, which supervises one worker)."""
    var qos: Bool
    """`--qos` / `M0_QOS`: on macOS, the loop at user-interactive QoS and its
    worker threads at user-initiated (`m0_http.threads.request_qos_class`);
    accepted and ignored elsewhere."""
    var max_body: Int
    """Request body cap in bytes; -1 leaves `ServerConfig`'s default alone."""
    var max_keepalive_requests: Int
    """`--max-keepalive-requests`: requests a keep-alive connection may carry
    before the server closes it (0 = never); -1 leaves the environment's
    `M0_MAX_KEEPALIVE_REQUESTS` or its default alone."""
    var idle_timeout: Int
    """Seconds a keep-alive connection may sit between requests; -1 leaves
    `ServerConfig`'s default (60) alone.

    0 is a MEANINGFUL value, not an unset one, which is why the sentinel is
    -1: it turns the idle sweep off, and the sweep is what bounds a
    WebSocket that this side has closed while it waits for the peer's Close
    reply (RFC 6455 5.5.1). With no sweep there is nothing to reap a peer
    that never replies, so that configuration deliberately keeps the older
    close-at-once behaviour rather than leaking the slot -- see
    `WS_CLOSE_LINGER_NS` in event_loop.mojo.
    """
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
    var show_doctor: Bool
    """`--doctor`: report what this configuration would do, and start nothing.

    Set here rather than handled in `m0serve.main` alone because the parser
    must know the flag needs no positional — `m0serve --doctor` with no
    MODULE is the "is this environment sane at all" call, and it is the one
    an agent reaches for first.
    """

    def __init__(out self):
        """Hard defaults — what applies when neither flag nor env says."""
        self.module = String("")
        self.attribute = String(DEFAULT_ATTRIBUTE)
        self.attribute_explicit = False
        self.mount_prefixes = List[String]()
        self.mount_modules = List[String]()
        self.mount_attributes = List[String]()
        self.mount_explicit = List[Bool]()
        self.asgi_mounts = List[Int]()
        self.mojo_mounts = List[Int]()
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
        self.qos = False
        self.spawn_workers = False
        self.max_body = -1
        self.max_keepalive_requests = -1
        self.idle_timeout = -1
        self.metrics = False
        self.realtime = False
        self.reload = False
        self.reload_dirs = List[String]()
        self.health_path = String("")
        self.show_help = False
        self.show_version = False
        self.show_doctor = False

    def __init__(out self, *, copy: Self):
        self.module = copy.module
        self.attribute = copy.attribute
        self.attribute_explicit = copy.attribute_explicit
        self.mount_prefixes = copy.mount_prefixes.copy()
        self.mount_modules = copy.mount_modules.copy()
        self.mount_attributes = copy.mount_attributes.copy()
        self.mount_explicit = copy.mount_explicit.copy()
        self.asgi_mounts = copy.asgi_mounts.copy()
        self.mojo_mounts = copy.mojo_mounts.copy()
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
        self.qos = copy.qos
        self.spawn_workers = copy.spawn_workers
        self.max_body = copy.max_body
        self.max_keepalive_requests = copy.max_keepalive_requests
        self.idle_timeout = copy.idle_timeout
        self.metrics = copy.metrics
        self.realtime = copy.realtime
        self.reload = copy.reload
        self.reload_dirs = copy.reload_dirs.copy()
        self.health_path = copy.health_path
        self.show_help = copy.show_help
        self.show_version = copy.show_version
        self.show_doctor = copy.show_doctor

    def __init__(out self, *, deinit move: Self):
        self.module = move.module^
        self.attribute = move.attribute^
        self.attribute_explicit = move.attribute_explicit
        self.mount_prefixes = move.mount_prefixes^
        self.mount_modules = move.mount_modules^
        self.mount_attributes = move.mount_attributes^
        self.mount_explicit = move.mount_explicit^
        self.asgi_mounts = move.asgi_mounts^
        self.mojo_mounts = move.mojo_mounts^
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
        self.qos = move.qos
        self.spawn_workers = move.spawn_workers
        self.max_body = move.max_body
        self.max_keepalive_requests = move.max_keepalive_requests
        self.idle_timeout = move.idle_timeout
        self.metrics = move.metrics
        self.realtime = move.realtime
        self.reload = move.reload
        self.reload_dirs = move.reload_dirs^
        self.health_path = move.health_path^
        self.show_help = move.show_help
        self.show_version = move.show_version
        self.show_doctor = move.show_doctor

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
        opts.qos = config.qos
        opts.spawn_workers = config.spawn_workers
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
        have); `--max-body`, `--idle-timeout` and `--metrics` are server-only
        tunings the environment cannot reach and a command line can;
        `--max-keepalive-requests` overrides `M0_MAX_KEEPALIVE_REQUESTS`.
        """
        var sc = base.server_config()
        if self.access_log:
            sc.access_log = True
        if self.max_body >= 0:
            sc.max_request_body_size = self.max_body
        if self.max_keepalive_requests >= 0:
            sc.max_keepalive_requests = self.max_keepalive_requests
        if self.idle_timeout >= 0:
            sc.idle_timeout = self.idle_timeout
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
    var module = String(StringSpan(text)[byte = :colon])
    var attribute = String(StringSpan(text)[byte = colon + 1 :])
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
        digits = String(StringSpan(trimmed)[byte = : n - 1])
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
    any value, keeps `opts.blocking_threads` verbatim. An unmounted
    `--realtime` keeps the single-loop shape *by default* — the demo and
    its smokes assume it — while an explicit `--blocking-threads N`
    composes with it (a hold taken on a pool thread is forwarded to the
    loop's registries). A **mounted** `--realtime` follows the mount rule
    below instead: its WSGI mounts need pool threads whatever the flag,
    because those threads are the only workers parked on their lanes. A zero-config WSGI app gets a small pool: one slow view
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
    if opts.realtime and len(opts.mount_prefixes) == 0:
        return 0
    if len(opts.mount_prefixes) > 0:
        # Counted, not inferred by subtraction: a Mojo mount is neither
        # ASGI nor WSGI and must not conjure a pool of WSGI handler threads.
        return default_blocking_threads(cpus) if has_wsgi_mount(opts) else 0
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
    # A mounted server routes by lane, so one executor per ASGI mount
    # serves the async ones while pool threads serve the sync ones;
    # `asgi_mounts` names them and the blocking-threads count is about
    # the pool, not about whether executors run at all.
    if len(opts.mount_prefixes) > 0:
        # `--realtime` no longer zeroes this: under `--mount` the flag is
        # per-mount in effect — WSGI mounts take holds, ASGI mounts stream
        # through their own executor, and the loop tells the two apart by
        # lane (`OffloadPool.slot_is_executor`).
        return len(opts.asgi_mounts) > 0
    return is_asgi and not opts.realtime and opts.blocking_threads == 0


def use_loop_inversion(opts: ServeOptions, executor: Bool, pool_count: Int) -> Bool:
    """Whether the Mojo event loop runs INSIDE the executor's asyncio loop
    on one thread (`M0_INVERTED=1`) rather than beside it on two.

    One predicate so `main` and `--doctor` cannot disagree about which
    loop a deployment gets. `--doctor` reported `mode: single` for both
    shapes before this existed, so the two were indistinguishable from
    outside the process -- only the startup banner said which.

    `executor` is `use_asgi_executor`'s answer -- the asyncio executor
    serves this deployment -- and the rest are the inversion's own
    topology conditions: unmounted, no handler pool, no `--realtime`,
    because those are the shapes `serve_inverted` implements. It stays behind the
    variable and is NOT chosen automatically, even where it measures
    faster (one usable CPU: 1.14x the pump at saturation,
    docs/notes/inversion-on-a-constrained-box.md). Picking it by detected
    core count would switch EXECUTION MODELS on the environment rather
    than a parameter within one, would put the less-exercised path in the
    most constrained deployments, and would silently change model the day
    an application adds a mount, a pool or a hold. The note argues it at
    length; the short version is that a 14 % saturation gain does not buy
    those three.
    """
    return (
        loop_inversion_topology(opts, executor, pool_count)
        and getenv("M0_INVERTED", "") == "1"
    )


def loop_inversion_topology(
    opts: ServeOptions, executor: Bool, pool_count: Int
) -> Bool:
    """Whether this deployment's SHAPE is one `serve_inverted` implements,
    ignoring the variable.

    Split from `use_loop_inversion` so it can be tested: a portable test
    cannot set the process's environment and still be a pure unit test, so
    without this the topology conditions would be the unguarded half --
    the same reason `clamp_cpus` exists beside `usable_cpus`.
    """
    return (
        executor
        and len(opts.mount_prefixes) == 0
        and pool_count == 0
        and not opts.realtime
    )


def _in(indexes: List[Int], i: Int) -> Bool:
    for k in range(len(indexes)):
        if indexes[k] == i:
            return True
    return False


def wsgi_lanes(opts: ServeOptions) -> List[Int]:
    """The lanes the WSGI handler pool serves: neither ASGI nor Mojo.

    Here rather than beside its caller because BOTH execution modes deal
    the same lanes: prefork's `_serve_offloaded` and the `--threads`
    serving loop must partition the mounts identically, or a job reaches a
    worker that cannot run it.

    This used to read "every mount except the ASGI ones", which was correct
    while there were two kinds and silently wrong the moment there were
    three: a Mojo lane would have been dealt to `WSGIHandler.make` with
    `only_mount` naming a Python module that does not exist. Ask what a
    mount IS, never what it is not.
    """
    var lanes = List[Int]()
    for i in range(len(opts.mount_prefixes)):
        if not _in(opts.asgi_mounts, i) and not _in(opts.mojo_mounts, i):
            lanes.append(i)
    return lanes^


def mojo_lanes(opts: ServeOptions) -> List[Int]:
    """The lanes a `MojoPool` serves. Its threads never touch Python."""
    return opts.mojo_mounts.copy()


def has_wsgi_mount(opts: ServeOptions) -> Bool:
    """Whether any mount is WSGI — asked positively, see `wsgi_lanes`."""
    return len(wsgi_lanes(opts)) > 0


def asgi_mount_names(opts: ServeOptions) -> String:
    """`/app,/api` — the mounts whose lanes executors read, for the banner."""
    var out = String("")
    for k in range(len(opts.asgi_mounts)):
        if k > 0:
            out += ","
        ref prefix = opts.mount_prefixes[opts.asgi_mounts[k]]
        out += "/" if prefix.byte_length() == 0 else prefix
    return out^


def effective_cpus() -> Int:
    """Logical CPU count via `sysconf(_SC_NPROCESSORS_ONLN)`; 1 on failure.

    `sysconf` rather than a Python `os.cpu_count()` because the count is
    needed before the fork, and the fork must precede the first Python
    call. The constant differs per platform (glibc 84, macOS 58).
    """
    var count = external_call["sysconf", Int](Int(SC_NPROCESSORS_ONLN))
    return count if count > 0 else 1


def _read_small_file(path: String) -> String:
    """A whole small text file, or "" if it cannot be read.

    `open` and read-to-EOF rather than a `stat`-sized read: every file this
    is used on lives in `/proc` or `/sys`, which report a size of 0 and
    yield their contents only when read. Verified on the toolchain --
    `/proc/self/status` reads 1128 bytes against a stat size of 0 -- and it
    is why nothing here binds `read(2)` itself. On macOS none of these
    paths exist and the raise is the answer: every caller reads "" as "no
    limit expressed here".
    """
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return String("")


def parse_cpus_allowed(text: String) -> Int:
    """CPUs in `/proc/self/status`'s `Cpus_allowed:` mask; 0 if absent.

    The mask is hex, most significant group first, 32-bit groups separated
    by commas (`ffffffff,ffffffff`), so the count is a popcount over the hex
    digits and the grouping does not matter. `Cpus_allowed_list` would need
    range parsing for the same answer.

    Byte-wise, not codepoint-wise: the field is ASCII hex by definition, and
    a byte scan needs no decoder. A pure function of the file's text so it
    can be tested without a process that is actually pinned -- the shape
    `spec_sheet.py` and `shim_ownership.py` use for the same reason.
    """
    comptime KEY = "Cpus_allowed:"
    var lines = text.split("\n")
    for i in range(len(lines)):
        ref line = lines[i]
        if not line.startswith(KEY):
            continue
        # The trailing colon in KEY is load-bearing: `/proc/self/status`
        # also carries `Cpus_allowed_list:`, which this prefix does not
        # match, so the mask line is picked and the range line is not.
        var b = line.as_bytes()
        var bits = 0
        for j in range(KEY.byte_length(), len(b)):
            var c = Int(b[j])
            var v = -1
            if c >= ord("0") and c <= ord("9"):
                v = c - ord("0")
            elif c >= ord("a") and c <= ord("f"):
                v = c - ord("a") + 10
            elif c >= ord("A") and c <= ord("F"):
                v = c - ord("A") + 10
            if v < 0:
                continue          # whitespace and the group commas
            while v > 0:
                bits += v & 1
                v >>= 1
        return bits
    return 0


def _ceil_div(a: Int, b: Int) -> Int:
    return (a + b - 1) // b if b > 0 else 0


def parse_cgroup_cpu_max(text: String) -> Int:
    """CPUs from a cgroup **v2** `cpu.max` (`"<quota> <period>"`); 0 if none.

    `"max <period>"` is cgroup v2 for unlimited and answers 0, which every
    caller reads as "this file expresses no limit". A fractional quota
    rounds UP: `--cpus 1.5` may run 2 runnable threads at once, and a count
    used to SIZE things should not claim fewer than can actually run.
    """
    var parts = text.strip().split(" ")
    if len(parts) < 2:
        return 0
    if parts[0] == "max":
        return 0
    try:
        var quota = Int(parts[0])
        var period = Int(parts[1])
        if quota <= 0 or period <= 0:
            return 0
        return _ceil_div(quota, period)
    except:
        return 0


def parse_cgroup_v1_quota(quota_text: String, period_text: String) -> Int:
    """CPUs from cgroup **v1**'s `cpu.cfs_quota_us` / `cpu.cfs_period_us`.

    v1 spells unlimited as a quota of -1. Same rounding rule as v2.
    """
    try:
        var quota = Int(quota_text.strip())
        var period = Int(period_text.strip())
        if quota <= 0 or period <= 0:
            return 0
        return _ceil_div(quota, period)
    except:
        return 0


def cgroup_cpu_quota() -> Int:
    """The container CPU limit in whole CPUs, or 0 where none is expressed.

    v2 first (`/sys/fs/cgroup/cpu.max`), then v1. In a container the cgroup
    namespace makes these the container's OWN files, so no path walking is
    needed; on a host the v2 root has no `cpu.max` and the answer is 0.
    """
    var v2 = parse_cgroup_cpu_max(_read_small_file("/sys/fs/cgroup/cpu.max"))
    if v2 > 0:
        return v2
    return parse_cgroup_v1_quota(
        _read_small_file("/sys/fs/cgroup/cpu/cpu.cfs_quota_us"),
        _read_small_file("/sys/fs/cgroup/cpu/cpu.cfs_period_us"),
    )


def clamp_cpus(online: Int, affinity: Int, quota: Int) -> Int:
    """Whichever CPU bound binds first, never below 1.

    `affinity` and `quota` use 0 for "this mechanism expresses no limit",
    which is what both readers answer when their file is absent (macOS, a
    host with no cgroup v2 root `cpu.max`) or says unlimited (`max`, or
    v1's `-1`). A limit ABOVE the online count is not a limit.

    Split out from `usable_cpus` so the composition is a pure function and
    can be tested: a portable test cannot pin its own process, so without
    this the clamp itself would be the one unguarded line here -- verified
    by reverting it, which no test caught until this existed.
    """
    var n = online
    if affinity > 0 and affinity < n:
        n = affinity
    if quota > 0 and quota < n:
        n = quota
    return n if n >= 1 else 1


def usable_cpus() -> Int:
    """The CPUs this PROCESS may use: online, affinity and quota, whichever
    binds first. Never below 1.

    `effective_cpus` answers how many CPUs the MACHINE has online, which is
    not the same question and in a container is not the same number. Both
    of the ways a deployment is actually limited are invisible to it,
    measured 2026-09-08 in a Linux container:

    - **affinity** (`taskset`, Kubernetes' static CPU manager) -- pinned to
      one CPU, `sysconf` still answered 8 while the kernel answered 1;
    - **quota** (`docker run --cpus 1`, Kubernetes `limits.cpu`) -- the
      usual mechanism, and the one nothing else reveals: `nproc` answered
      8, `sysconf` answered 8, and only `cpu.max` (`100000 100000`) said
      1.0.

    So this is what a decision about the process's own CPU budget must
    ask, and `--doctor` reports it beside `cpus` so the two questions stay
    distinct rather than one silently standing in for the other.

    It deliberately does NOT size the handler pool -- see `pool_cpus`.
    """
    return clamp_cpus(
        effective_cpus(),
        parse_cpus_allowed(_read_small_file("/proc/self/status")),
        cgroup_cpu_quota(),
    )


def performance_cpus() -> Int:
    """Cores worth sizing CPU-bound work to: the performance cores on Apple
    Silicon, every logical CPU elsewhere.

    `sysconf` counts the efficiency cores too, and on an M4 that is 10 for
    a machine with 4 cores that serve at full speed (docs/BENCHMARKS.md
    measured an E-core at about a quarter of a P-core on this workload).
    The stdlib's `num_performance_cores` reads `hw.perflevel0.logicalcpu`;
    a Linux box has one performance level, so this is `effective_cpus`
    there and the two counts agree. A runtime probe, not a compile-time
    one: the wheel is built for the oldest Apple Silicon and runs on all
    of them, and the P-core count is a property of the machine it lands
    on, not of the build.
    """
    comptime if CompilationTarget.is_macos():
        var n = num_performance_cores()
        return n if n > 0 else effective_cpus()
    else:
        return effective_cpus()


def pool_cpus() -> Int:
    """The core count the zero-config handler pool is sized from.

    Every logical CPU, on every platform -- NOT the performance-core count,
    although the M4 that raised the question has 4 of those and 10 logical
    CPUs. Measured 2026-09-04 on that machine, pools of 4 and 8 threads tie:
    a CPU-bound view holding the GIL for 1 ms served about 970 requests per
    second with either, which is the GIL's ceiling and not the pool's, and
    hello-world differed only inside the run-to-run noise. A pool thread's
    parallelism is WAITING -- a thread parked in a view holds no core -- so
    the count that matters is how many views may wait at once, and the
    efficiency cores are as good as any for that. What the P-core count
    does steer is PLACEMENT, through `--qos`; `--doctor` reports it beside
    this count so the two questions stay distinct. One function, so the
    policy has one home to change if a measurement ever says otherwise.

    **Deliberately `effective_cpus`, not `usable_cpus`**, although the
    latter is the truthful count of what this process may run on. The
    obvious reading of a one-CPU container -- eight handler threads is
    seven too many -- is wrong, measured 2026-09-08 on bare WSGI pinned to
    one CPU: the zero-config pool of eight served 77,097 rps against one
    thread's 77,738 at 16 connections (0.99x, inside the noise) and
    **155,740 against 142,159 at 256 (1.10x, a gain)**. It is the same
    reason as the paragraph above -- a pool thread's parallelism is
    WAITING, and how many views may wait at once has nothing to do with
    the CPU budget -- and the elastic wake rules
    (docs/notes/elastic-pool.md) are what stopped the extra threads
    costing anything. What the over-sized pool does cost is memory, about
    17 MB of RSS for seven more bridges (52.8 MB against 35.5), which is a
    footprint question and not this function's.
    """
    return effective_cpus()


def apple_target() -> String:
    """The Apple Silicon generation this binary was COMPILED for; "" off macOS.

    A compile-time fact, deliberately: the portable wheel answers `m1` on
    every Mac it runs on, because `build-serve` pins `--target-cpu` to the
    oldest Apple Silicon so one artifact runs on all of them, while
    `build-serve-native` answers the build host's generation. Comparing
    this line to `sysctl machdep.cpu.brand_string` says which of the two
    a binary is, which nothing else about it reveals.
    """
    comptime if CompilationTarget.is_macos():
        comptime if CompilationTarget.is_apple_m1():
            return String("m1")
        elif CompilationTarget.is_apple_m2():
            return String("m2")
        elif CompilationTarget.is_apple_m3():
            return String("m3")
        elif CompilationTarget.is_apple_m4():
            return String("m4")
        else:
            return String("other")
    else:
        return String("")


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
        or name == "--max-keepalive-requests"
        or name == "--idle-timeout"
        or name == "--health-path"
        or name == "--reload-dir"
        or name == "--protocol"
        or name == "--mount"
    )


def _is_bool(name: String) -> Bool:
    return (
        name == "--access-log"
        or name == "--qos"
        or name == "--spawn-workers"
        or name == "--metrics"
        or name == "--realtime"
        or name == "--reload"
        or name == "--help"
        or name == "--version"
        or name == "--doctor"
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
        var prefix = String(StringSpan(value)[byte = :eq])
        var directory = String(StringSpan(value)[byte = eq + 1 :])
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
        var raw = String(StringSpan(value)[byte = :meq])
        var spec = String(StringSpan(value)[byte = meq + 1 :])
        if not raw.startswith("/"):
            raise Error("--mount prefix must start with '/', got '" + raw + "'")
        # Stored without the trailing slash, so '/' becomes '' -- PEP 3333's
        # SCRIPT_NAME and ASGI's root_path for an app at the root are both
        # the empty string, and the matcher gets one shape to compare.
        var prefix = raw
        while prefix.endswith("/"):
            prefix = String(
                StringSpan(prefix)[byte = : prefix.byte_length() - 1]
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
        # `=mojo` names the compiled-in Mojo handler rather than an
        # importable object. A Mojo handler is a compile-time type, so
        # there is nothing to import and nothing to detect: it is recorded
        # here and skipped by `_resolve_mounts`.
        if spec == "mojo":
            opts.mojo_mounts.append(len(opts.mount_prefixes) - 1)
            opts.mount_explicit.append(True)
        else:
            opts.mount_explicit.append(spec.find(":") >= 0)
    elif name == "--static-cache-control":
        opts.static_cache_control = value
    elif name == "--max-body":
        opts.max_body = parse_size(value)
    elif name == "--max-keepalive-requests":
        var cap = parse_int(value, "--max-keepalive-requests")
        if cap < 0:
            raise Error(
                "--max-keepalive-requests must be 0 (never close for count)"
                " or a positive count, got '" + value + "'"
            )
        opts.max_keepalive_requests = cap
    elif name == "--idle-timeout":
        var idle = parse_int(value, "--idle-timeout")
        if idle < 0:
            raise Error(
                "--idle-timeout must be 0 or more seconds, got " + value
            )
        opts.idle_timeout = idle
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
                name = String(StringSpan(arg)[byte = :eq])
                inline = String(StringSpan(arg)[byte = eq + 1 :])
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
                elif name == "--qos":
                    opts.qos = True
                elif name == "--spawn-workers":
                    opts.spawn_workers = True
                elif name == "--realtime":
                    opts.realtime = True
                elif name == "--reload":
                    opts.reload = True
                elif name == "--metrics":
                    opts.metrics = True
                elif name == "--doctor":
                    opts.show_doctor = True
                else:
                    # Unreachable: `_is_bool` gated entry. Explicit anyway --
                    # this used to be `opts.metrics = True`, so a new boolean
                    # flag added to `_is_bool` and forgotten here silently
                    # turned on Prometheus metrics instead of doing its job.
                    raise Error("unhandled boolean option " + name)
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
        and not opts.show_doctor
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
        "  --spawn-workers             workers exec a fresh image after the fork:\n"
        "                              for apps using Core ML, Objective-C or\n"
        "                              libdispatch, which a forked child cannot\n"
        "                              (M0_SPAWN_WORKERS)\n"
        "  --qos                       macOS: keep the loop and its worker threads\n"
        "                              on performance cores under contention (M0_QOS)\n"
        "  --max-body SIZE             request body cap: bytes, or 512k / 64m / 1g\n"
        "                              (default 4m)\n"
        "  --max-keepalive-requests N  close a keep-alive connection after N\n"
        "                              requests (default 1000, 0 = never;\n"
        "                              M0_MAX_KEEPALIVE_REQUESTS)\n"
        "  --idle-timeout SECONDS      close a keep-alive connection left idle\n"
        "                              this long (default 60, 0 = never)\n"
        "  --metrics                   serve Prometheus metrics at /__metrics\n"
        "  --realtime                  hold SSE streams and WebSockets the app\n"
        "                              approves with M0-Hold; publish with m0pub.py\n"
        "  --health-path PATH          answer PATH in Mojo with a liveness JSON,\n"
        "                              never entering the application\n"
        "  --reload                    restart workers when a watched .py changes\n"
        "                              (development; forces a supervisor)\n"
        "  --reload-dir DIR            directory --reload watches; repeatable,\n"
        "                              defaults to --app-dir\n"
        "  --doctor                    report this configuration as JSON and\n"
        "                              exit: platform, interpreter, resolved\n"
        "                              topology, and every startup check, with\n"
        "                              the exit code the server itself would use\n"
        "  -h, --help                  show this help and exit\n"
        "  -V, --version               show the version and exit\n"
        "\n"
        "The binary resolves libpython from the python3 on PATH: run it from a\n"
        "virtualenv that has your framework installed, or set MOJO_PYTHON_LIBRARY.\n"
    )
