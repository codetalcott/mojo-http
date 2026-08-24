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

from lightbug_http.server_config import ServerConfig
from m0_http.config import AppConfig


comptime M0SERVE_VERSION = "0.8.0"
"""Reported by `--version`. Bumped with the release (see docs/RELEASING.md)."""

comptime DEFAULT_ATTRIBUTE = "application"
"""PEP 3333's conventional name, and gunicorn's default — not uvicorn's `app`."""

comptime DEFAULT_PORT = 8000
"""The port uvicorn and gunicorn default to; the in-repo rows always pass `--port`."""

comptime EXIT_USAGE = 2
"""A bad command line — getopt's and click's convention."""

comptime EXIT_STARTUP = 1
"""The application could not be loaded or the server could not start."""


struct ServeOptions(Copyable, Movable):
    """Everything `m0serve` needs to know, after flags and environment agree."""

    var module: String
    """Importable module holding the WSGI callable, e.g. `myproject.wsgi`."""
    var attribute: String
    """Name of the callable in that module."""
    var host: String
    var port: Int
    var workers: Int
    var threads: Int
    """Serving threads in one process (free-threaded CPython only); 1 = off."""
    var blocking_threads: Int
    """Handler threads per event loop; 0 = off, and the loop calls handlers itself.

    Stage B. The loop becomes an acceptor: it parses the request, hands it to
    a pool thread, and goes back to `wait()`, so one slow view no longer holds
    the keep-alive connections that loop happens to own. Off by default
    because it costs N threads and N interpreters' worth of per-thread handler
    state per loop, and because a server whose views are all fast gains
    nothing from it. Composes with `--workers` and with `--threads`; refused
    with `--realtime`, whose streaming hooks run on the loop's handler.
    """
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
        self.host = String("0.0.0.0")
        self.port = DEFAULT_PORT
        self.workers = 1
        self.threads = 1
        self.blocking_threads = 0
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
        self.host = copy.host
        self.port = copy.port
        self.workers = copy.workers
        self.threads = copy.threads
        self.blocking_threads = copy.blocking_threads
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
        self.host = move.host^
        self.port = move.port
        self.workers = move.workers
        self.threads = move.threads
        self.blocking_threads = move.blocking_threads
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
        opts.access_log = config.access_log
        return opts^

    def address(self) -> String:
        """The listen address, `host:port`."""
        return self.host + ":" + String(self.port)

    def spec(self) -> String:
        """The `module:attribute` pair as the user would write it."""
        return self.module + ":" + self.attribute

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


# The flags that take a value, and the booleans. `test_cli.mojo` asserts that
# `usage()` names every one of them, so the help text cannot drift from the
# parser. (Plain comparisons rather than a comptime list of Strings: an
# `Array[String, N]` cannot be materialized at run time on this toolchain.)
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
    elif name == "--threads":
        var threads = parse_int(value, "--threads")
        if threads < 1:
            raise Error("--threads must be at least 1, got " + value)
        opts.threads = threads
    elif name == "--blocking-threads":
        var blocking = parse_int(value, "--blocking-threads")
        if blocking < 0:
            raise Error("--blocking-threads cannot be negative, got " + value)
        opts.blocking_threads = blocking
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
            have_module = True
        i += 1

    if not have_module and not opts.show_help and not opts.show_version:
        raise Error("missing MODULE[:ATTR]")
    return opts^


def usage() -> String:
    """The `--help` text. Every flag the parser knows appears here."""
    return String(
        "usage: m0serve [OPTIONS] MODULE[:ATTR]\n"
        "\n"
        "Serve a WSGI application (Django, Flask, anything PEP 3333) with\n"
        "mojo-http. MODULE is importable from --app-dir; ATTR defaults to\n"
        "'application'. Flags override M0_* environment variables.\n"
        "\n"
        "  --host ADDR                 bind address (default 0.0.0.0; M0_HOST)\n"
        "  --port N                    port (default 8000; M0_PORT)\n"
        "  --workers N                 prefork worker processes (default 1; M0_WORKERS)\n"
        "  --threads N                 serving threads in ONE process, free-threaded\n"
        "  --blocking-threads N        handler threads per loop; isolates slow views\n"
        "                              CPython only; exclusive with --workers (M0_THREADS)\n"
        "  --app-dir DIR               prepended to sys.path (default .)\n"
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
