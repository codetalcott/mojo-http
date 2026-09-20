"""The Mojo host's command line: flags over `AppConfig`, `--doctor`, `--help`.

    ./server --port 9000 --workers 2
    ./server --doctor --threads 4        # one JSON object, nothing started

A host application was env-only until 2026-09-19 (DECISIONS D29, retired by
this file). The precedence is m0serve's exactly -- **flag > env > default**
-- and it falls out of the shape: `AppConfig()` has already resolved env over
default, and `parse_host_flags` overlays the command line on it. A flag sets
the same `*_set` word its variable does, so `--workers 1` is "one worker, and
I chose that", as `M0_WORKERS=1` is.

**Strict where the environment is lenient.** `M0_PORT=abc` is the default
port; `--port abc` is exit 2 with the usage. So is an unknown flag, a missing
value, a value on a boolean, a port outside 1-65535, and any positional: a
host application takes no arguments of its own, and its own configuration
stays in its own variables, checked in its `main` before `serve` is called.

**What is NOT a usage error.** A count the host cannot serve --
`--workers 0`, both modes at once, more workers than the application's state
allows -- is a REFUSAL, exit 78, decided by `host_checks` whichever way the
number arrived. One path, so `M0_THREADS=0` and `--threads 0` cannot be
answered differently. (m0serve answers its `--workers 0` with 2; it has no
env-side refusal to agree with.)

**The overlay is idempotent**, which is what lets it run twice: `serve`
always applies the command line to the config it is given, and an
application that prints its own address first takes its config from
`host_config()`, which has applied it already. `serve(AppConfig())` and
`serve(host_config())` serve the same thing; only the second's banner is
true under `--port`.

Pure: `parse_host_flags` takes its arguments as a list and touches nothing
but the `M0_BASE_URL` lookup `AppConfig` itself makes. `host.mojo` owns the
exits.
"""

from std.os import getenv
from std.sys.arg import argv

from lightbug_http.c.process import process_exit
from lightbug_http.server_config import ServerConfig

from m0_http.config import AppConfig


comptime EX_USAGE = 2
"""A command line the host cannot read. `EX_CONFIG` (78) is one it read and
will not serve."""

comptime DOCTOR_FORMAT = "1"
"""The `--doctor` report's shape, its first key's value (`"m0_host":"1"`).
A format number, not a release: the version lives in `pyproject.toml` and
`cli.mojo` and nowhere else (docs/RELEASING.md)."""


def _takes_value(name: String) -> Bool:
    return (
        name == "--host"
        or name == "--port"
        or name == "--workers"
        or name == "--threads"
        or name == "--blocking-threads"
        or name == "--sse-heartbeat-ms"
        or name == "--app-tick-ms"
        or name == "--max-keepalive-requests"
    )


def _is_bool(name: String) -> Bool:
    return (
        name == "--access-log"
        or name == "--qos"
        or name == "--spawn-workers"
        or name == "--doctor"
        or name == "--help"
    )


def _env_of(name: String) -> String:
    """The variable a flag overrides; empty for `--doctor` and `--help`."""
    if name == "--host":
        return "M0_HOST"
    if name == "--port":
        return "M0_PORT"
    if name == "--workers":
        return "M0_WORKERS"
    if name == "--threads":
        return "M0_THREADS"
    if name == "--blocking-threads":
        return "M0_BLOCKING_THREADS"
    if name == "--sse-heartbeat-ms":
        return "M0_SSE_HEARTBEAT_MS"
    if name == "--app-tick-ms":
        return "M0_APP_TICK_MS"
    if name == "--max-keepalive-requests":
        return "M0_MAX_KEEPALIVE_REQUESTS"
    if name == "--access-log":
        return "M0_ACCESS_LOG"
    if name == "--qos":
        return "M0_QOS"
    if name == "--spawn-workers":
        return "M0_SPAWN_WORKERS"
    return ""


def _parse_int(text: String, what: String) raises -> Int:
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


struct HostFlags(Copyable, Movable):
    """A command line, applied: the resolved config and what was asked for."""

    var config: AppConfig
    """The seed with every flag given laid over it."""
    var doctor: Bool
    var help: Bool
    var given: List[String]
    """The flags that appeared, by their long names, in order."""

    def __init__(out self, var config: AppConfig):
        self.config = config^
        self.doctor = False
        self.help = False
        self.given = List[String]()

    def was_given(self, name: String) -> Bool:
        for i in range(len(self.given)):
            if self.given[i] == name:
                return True
        return False

    def source(self, name: String) -> String:
        """Where `name`'s value came from: `flag`, `env` or `default`."""
        if self.was_given(name):
            return "flag"
        var env = _env_of(name)
        if env.byte_length() > 0 and getenv(env, "").byte_length() > 0:
            return "env"
        return "default"

    def apply_to(self, mut server_config: ServerConfig):
        """Lay the GIVEN flags over a `ServerConfig` the application built.

        `serve(config, server_config)` is handed tuning the application
        chose in code (`apps/sim_loop` sets its own tick), made before the
        command line was read. A flag that names one of the four shared
        fields outranks it, being the operator's explicit word; one that
        was not given leaves the application's value alone, which is why
        this is not `config.server_config()` again.
        """
        if self.was_given("--access-log"):
            server_config.access_log = self.config.access_log
        if self.was_given("--sse-heartbeat-ms"):
            server_config.sse_heartbeat_ms = self.config.sse_heartbeat_ms
        if self.was_given("--app-tick-ms"):
            server_config.app_tick_ms = self.config.app_tick_ms
        if self.was_given("--max-keepalive-requests"):
            server_config.max_keepalive_requests = self.config.max_keepalive_requests


def _apply(mut config: AppConfig, name: String, value: String) raises:
    """Set one value-taking flag. Only what cannot be READ is refused here;
    a count the host will not serve is `host_checks`'s to refuse, with 78."""
    if name == "--host":
        var host = String(value.strip())
        if host.byte_length() == 0:
            raise Error("--host must not be empty")
        config.host = String("127.0.0.1") if host == "localhost" else host
    elif name == "--port":
        var port = _parse_int(value, "--port")
        if port < 1 or port > 65535:
            raise Error("--port must be 1-65535, got " + value)
        config.port = port
        # `AppConfig` derives the base URL from the port it resolved; keep
        # that true of the port a flag moved, unless the URL was given.
        if getenv("M0_BASE_URL", "").byte_length() == 0:
            config.base_url = "http://localhost:" + String(port)
    elif name == "--workers":
        config.workers = _parse_int(value, "--workers")
        config.workers_set = True
    elif name == "--threads":
        config.threads = _parse_int(value, "--threads")
        config.threads_set = True
    elif name == "--blocking-threads":
        config.blocking_threads = _parse_int(value, "--blocking-threads")
        config.blocking_threads_set = True
    elif name == "--sse-heartbeat-ms":
        config.sse_heartbeat_ms = _parse_int(value, "--sse-heartbeat-ms")
    elif name == "--app-tick-ms":
        config.app_tick_ms = _parse_int(value, "--app-tick-ms")
    elif name == "--max-keepalive-requests":
        config.max_keepalive_requests = _parse_int(value, "--max-keepalive-requests")
    else:
        # Unreachable: `_takes_value` gated entry. Explicit, so a flag added
        # there and forgotten here fails instead of being silently dropped.
        raise Error("unhandled option " + name)


def parse_host_flags(args: List[String], seed: AppConfig) raises -> HostFlags:
    """Overlay the command line on `seed` (normally `AppConfig()`).

    `args` excludes argv[0]. Accepts `--opt value` and `--opt=value`, and
    `-h`. Raises a one-line message for anything else; the caller prints it
    with `host_usage()` and exits `EX_USAGE`.
    """
    var flags = HostFlags(seed.copy())
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "-h":
            flags.help = True
        elif arg.startswith("--") and arg.byte_length() > 2:
            var name = arg
            var inline = String("")
            var has_inline = False
            var eq = arg.find("=")
            if eq >= 0:
                # Byte spans, not `[byte=a:b]`: a command line need not be
                # UTF-8, and that slice asserts a codepoint boundary.
                name = String(unsafe_from_utf8=arg.as_bytes()[:eq])
                inline = String(unsafe_from_utf8=arg.as_bytes()[eq + 1 :])
                has_inline = True
            if _is_bool(name):
                if has_inline:
                    raise Error(name + " takes no value")
                if name == "--help":
                    flags.help = True
                elif name == "--doctor":
                    flags.doctor = True
                elif name == "--access-log":
                    flags.config.access_log = True
                elif name == "--qos":
                    flags.config.qos = True
                elif name == "--spawn-workers":
                    flags.config.spawn_workers = True
                else:
                    raise Error("unhandled boolean option " + name)
            elif _takes_value(name):
                var value = inline
                if not has_inline:
                    if i + 1 >= len(args):
                        raise Error(name + " needs a value")
                    i += 1
                    value = args[i]
                _apply(flags.config, name, value)
            else:
                raise Error("unknown option " + name)
            if not flags.was_given(name):
                flags.given.append(name)
        elif arg.startswith("-") and arg.byte_length() > 1:
            raise Error("unknown option " + arg)
        else:
            raise Error(
                "unexpected argument '" + arg + "': a host application takes"
                " flags only, and its own settings from its own variables"
            )
        i += 1
    return flags^


def host_usage(program: String = "server") -> String:
    """The help text. Every flag names the variable it overrides."""
    return String(
        "usage: ", program, " [OPTIONS]\n"
        "\n"
        "Each option overrides its M0_ variable, which overrides the default.\n"
        "\n"
        "  --host ADDR                 listen address (M0_HOST; 0.0.0.0)\n"
        "  --port N                    listen port (M0_PORT; 8080)\n"
        "  --workers N                 processes, forked (M0_WORKERS; 1)\n"
        "  --threads N                 loops on threads of one process; not\n"
        "                              with --workers above 1 (M0_THREADS; 1)\n"
        "  --blocking-threads N        handler threads behind each loop\n"
        "                              (M0_BLOCKING_THREADS; 0 = none)\n"
        "  --access-log                one line per request (M0_ACCESS_LOG)\n"
        "  --sse-heartbeat-ms N        idle-stream heartbeat, 0 = off\n"
        "                              (M0_SSE_HEARTBEAT_MS; 15000)\n"
        "  --app-tick-ms N             the tick hook's period, 0 = off\n"
        "                              (M0_APP_TICK_MS; 0)\n"
        "  --max-keepalive-requests N  requests per connection, 0 = no cap\n"
        "                              (M0_MAX_KEEPALIVE_REQUESTS; 1000)\n"
        "  --qos                       macOS: keep the loop on performance\n"
        "                              cores (M0_QOS)\n"
        "  --spawn-workers             m0serve's; refused here with 78\n"
        "                              (M0_SPAWN_WORKERS)\n"
        "  --doctor                    print this configuration as JSON, start\n"
        "                              nothing, exit with the code serving\n"
        "                              would exit with\n"
        "  -h, --help                  this text\n"
    )


def host_args() -> List[String]:
    """This process's command line, without argv[0]."""
    var args = List[String]()
    var raw = argv()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    return args^


def program_name() -> String:
    """The last path component of argv[0], for the usage line."""
    var raw = argv()
    if len(raw) == 0:
        return "server"
    var full = String(raw[0])
    var cut = full.rfind("/")
    if cut < 0:
        return full
    return String(unsafe_from_utf8=full.as_bytes()[cut + 1 :])


def read_flags_or_exit(seed: AppConfig) -> HostFlags:
    """The command line over `seed`, or the exit it earns: the usage and 2
    for one that cannot be read, the usage and 0 for `--help`."""
    try:
        var flags = parse_host_flags(host_args(), seed)
        if flags.help:
            print(host_usage(program_name()), flush=True)
            process_exit(0)
        return flags^
    except e:
        print(host_usage(program_name()), flush=True)
        print("host: " + String(e), flush=True)
        process_exit(EX_USAGE)
        return HostFlags(seed.copy())  # never reached: the process has left


def host_config(default_port: Int = 8080) -> AppConfig:
    """`AppConfig(default_port)` with the command line applied.

    For an application that prints its own address before `serve`: the
    banner is then the address `serve` binds. `serve` applies the command
    line again, which changes nothing (module docstring).
    """
    return read_flags_or_exit(AppConfig(default_port)).config.copy()
