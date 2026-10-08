"""Application configuration loaded from M0_-prefixed environment variables.

Provides sensible defaults for all fields. No config file parsing —
env vars are the container convention.

Env vars:
    M0_HOST       — Listen address: an IPv4 literal, an IPv6 one (`::`
                    listens on both families, `::1` is the IPv6 loopback;
                    brackets, `[::1]`, are accepted), or "localhost" for
                    127.0.0.1 (default: 0.0.0.0 — every IPv4 interface).
                    Not resolved: a hostname would need DNS the server
                    deliberately does not do.
    M0_PORT       — HTTP listen port (default: 8080)
    M0_BASE_URL   — Public base URL (default: http://localhost:{port})
    M0_WORKERS    — Worker count for multi-worker mode (default: 1)
    M0_THREADS    — Serving threads in ONE process, free-threaded CPython
                    only (default: 1). Mutually exclusive with M0_WORKERS>1;
                    see `threads_conflict`.
    M0_BLOCKING_THREADS — Handler threads per event loop (default: 0 = off).
                    The loop hands requests to a pool instead of running them
                    itself, so one slow view stops holding the keep-alive
                    connections that loop owns. Composes with either of the
                    two above.
    M0_ACCESS_LOG — Enable access logging: "true" or "1" (default: false)
    M0_SSE_HEARTBEAT_MS — Milliseconds between SSE heartbeat comments on idle
                    streams; "0" disables them (default: 15000)
    M0_APP_TICK_MS — Milliseconds between application `tick` hook calls;
                    "0" disables the tick entirely (default: 0 — the hook
                    is opt-in, ticking costs wakeups)
    M0_SPAWN_WORKERS — "true" or "1": workers exec a fresh image after the
                  fork, for applications that use platform runtimes a forked
                  child cannot (Core ML, Objective-C, libdispatch)
    M0_QOS        — "true" or "1": on macOS, run the event loop at
                    user-interactive QoS and its worker threads at
                    user-initiated, which keeps them on performance cores
                    under contention. Ignored elsewhere (default: off)
    M0_MAX_KEEPALIVE_REQUESTS — requests a keep-alive connection may carry
                    before the server closes it with `Connection: close`;
                    "0" never closes for count (default: 1000, nginx's).
                    The cap's cost is a reconnect per N requests, and at
                    100 that was the fast route's whole p99 on a loopback
                    benchmark (docs/notes/pool-tail.md)
"""

from std.os import getenv

from lightbug_http.address import join_host_port
from lightbug_http.server_config import ServerConfig


struct AppConfig(Copyable, Movable):
    """Application configuration loaded from environment."""
    var host: String
    var port: Int
    var base_url: String
    var workers: Int
    var threads: Int
    var blocking_threads: Int
    var workers_set: Bool
    var threads_set: Bool
    var blocking_threads_set: Bool
    var access_log: Bool
    var sse_heartbeat_ms: Int
    var app_tick_ms: Int
    var qos: Bool
    var spawn_workers: Bool
    """`M0_SPAWN_WORKERS`: workers exec a fresh image after the fork."""
    var max_keepalive_requests: Int
    """`M0_MAX_KEEPALIVE_REQUESTS`: the keep-alive request cap (0 = never)."""

    def __init__(out self, default_port: Int = 8080):
        """Load configuration from M0_-prefixed env vars with defaults."""
        self.host = _parse_host(getenv("M0_HOST", ""))
        self.port = _parse_int_env("M0_PORT", default_port)
        self.workers = _parse_int_env("M0_WORKERS", 1)
        self.threads = _parse_int_env("M0_THREADS", 1)
        self.blocking_threads = _parse_int_env("M0_BLOCKING_THREADS", 0)
        # An explicitly-set topology variable counts as explicit for the
        # zero-config default, even when it names today's default value:
        # M0_WORKERS=1 means "one worker, and I chose that".
        self.workers_set = _env_present("M0_WORKERS")
        self.threads_set = _env_present("M0_THREADS")
        self.blocking_threads_set = _env_present("M0_BLOCKING_THREADS")
        var access_log_str = getenv("M0_ACCESS_LOG", "")
        self.access_log = access_log_str == "true" or access_log_str == "1"
        self.sse_heartbeat_ms = _parse_int_env("M0_SSE_HEARTBEAT_MS", 15000)
        self.app_tick_ms = _parse_int_env("M0_APP_TICK_MS", 0)
        var qos_str = getenv("M0_QOS", "")
        self.qos = qos_str == "true" or qos_str == "1"
        var spawn_str = getenv("M0_SPAWN_WORKERS", "")
        self.spawn_workers = spawn_str == "true" or spawn_str == "1"
        self.max_keepalive_requests = _parse_int_env("M0_MAX_KEEPALIVE_REQUESTS", 1000)
        if self.max_keepalive_requests < 0:
            self.max_keepalive_requests = 1000

        var base_url_env = getenv("M0_BASE_URL", "")
        if base_url_env.byte_length() > 0:
            self.base_url = base_url_env
        else:
            self.base_url = "http://localhost:" + String(self.port)

    def address(self) -> String:
        """Return listen address string (e.g. '0.0.0.0:8080', '[::]:8080')."""
        return join_host_port(self.host, String(self.port))

    def server_config(self) -> ServerConfig:
        """A `ServerConfig` carrying every field this config shares with it.

        `AppConfig` reads the environment; `ServerConfig` is what the server
        actually consults. Three fields exist in both, and every app used to
        copy them across by hand — which meant each app copied a different
        subset, and two copied none at all, so `M0_ACCESS_LOG` silently did
        nothing there. The mapping lives here now so there is one place to
        update when a fourth shared field appears.

        Server-only tuning (connection limits, timeouts, body caps) keeps its
        defaults; this sets only what the environment is allowed to reach.
        """
        var sc = ServerConfig()
        sc.access_log = self.access_log
        sc.sse_heartbeat_ms = self.sse_heartbeat_ms
        sc.app_tick_ms = self.app_tick_ms
        sc.max_keepalive_requests = self.max_keepalive_requests
        return sc^


def threads_conflict(workers: Int, threads: Int) -> Optional[String]:
    """The one message for asking for both execution modes at once.

    Prefork (`M0_WORKERS`) and threads (`M0_THREADS`) are mutually
    exclusive in this release: a process that forked would have to fork
    before its first Python call and then spawn threads that each make
    one, and nothing has measured that shape. Both > 1 is a configuration
    error, answered identically by the environment and by `m0serve`'s
    flags so a user sees one sentence wherever they set it.
    """
    if workers > 1 and threads > 1:
        return String(
            "M0_THREADS and M0_WORKERS are mutually exclusive; set one of them"
            " (workers=" + String(workers) + ", threads=" + String(threads) + ")"
        )
    return None


def _parse_host(raw: String) -> String:
    """Normalize a listen address; empty means every interface
    (`listen_host` for the rest)."""
    var host = raw.strip()
    if host.byte_length() == 0:
        return String("0.0.0.0")
    return listen_host(host)


def listen_host(host: StringSpan) -> String:
    """A listen address as the listener takes it: `M0_HOST`, and the
    `--host` of m0serve and of the Mojo host, all read it through here.

    `localhost` becomes `127.0.0.1` because the listener does no name
    resolution — a user who types the word expects the loopback bind it
    names everywhere else, not a bind failure. An IPv6 literal in brackets,
    as it is written in a URL, loses them: `[::1]` is `::1`. Anything else
    is passed through verbatim for the socket layer to accept or reject.
    """
    if host == "localhost":
        return String("127.0.0.1")
    var bytes = host.as_bytes()
    var n = len(bytes)
    if n >= 2 and bytes[0] == UInt8(ord("[")) and bytes[n - 1] == UInt8(ord("]")):
        return String(unsafe_from_utf8=bytes[1 : n - 1])
    return String(host)


def _env_present(name: String) -> Bool:
    """Whether an env var is set to a non-empty value."""
    return getenv(name, "").byte_length() > 0


def parse_env_int(raw: StringSpan) -> Optional[Int]:
    """An `M0_*` number as the environment is read: ASCII digits naming a
    value an `Int` holds, or None for anything else.

    One reading for the loader and for m0serve's note of what it ignored
    (`from_env`), so the two cannot disagree on what was readable. A value
    too large for an `Int` is None: the digits were accumulated with no
    overflow check, and `M0_PORT=18446744073709551696` wrapped to port 80
    (review record LF49).
    """
    var bytes = raw.as_bytes()
    if len(bytes) == 0:
        return None
    var result = 0
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return None
        var digit = c - ord("0")
        if result > (Int.MAX - digit) // 10:
            return None
        result = result * 10 + digit
    return result


def _parse_int_env(name: String, default: Int) -> Int:
    """Parse integer from env var, returning default on empty/invalid."""
    var value = parse_env_int(getenv(name, ""))
    if value:
        return value.value()
    return default
