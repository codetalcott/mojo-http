"""Application configuration loaded from M0_-prefixed environment variables.

Provides sensible defaults for all fields. No config file parsing —
env vars are the container convention.

Env vars:
    M0_HOST       — Listen address: an IPv4 literal, or "localhost" for
                    127.0.0.1 (default: 0.0.0.0 — every interface). Not
                    resolved: the listener is IPv4-only, and a hostname
                    would need DNS the server deliberately does not do.
    M0_PORT       — HTTP listen port (default: 8080)
    M0_BASE_URL   — Public base URL (default: http://localhost:{port})
    M0_API_KEY    — API key for mutation auth (default: "" = disabled)
    M0_WORKERS    — Worker count for multi-worker mode (default: 1)
    M0_THREADS    — Serving threads in ONE process, free-threaded CPython
                    only (default: 1). Mutually exclusive with M0_WORKERS>1;
                    see `threads_conflict`.
    M0_ACCESS_LOG — Enable access logging: "true" or "1" (default: false)
    M0_SSE_HEARTBEAT_MS — Milliseconds between SSE heartbeat comments on idle
                    streams; "0" disables them (default: 15000)
    M0_APP_TICK_MS — Milliseconds between application `tick` hook calls;
                    "0" disables the tick entirely (default: 0 — the hook
                    is opt-in, ticking costs wakeups)
"""

from std.os import getenv

from lightbug_http.server_config import ServerConfig


struct AppConfig(Copyable, Movable):
    """Application configuration loaded from environment."""
    var host: String
    var port: Int
    var base_url: String
    var api_key: String
    var workers: Int
    var threads: Int
    var access_log: Bool
    var sse_heartbeat_ms: Int
    var app_tick_ms: Int

    def __init__(out self, default_port: Int = 8080):
        """Load configuration from M0_-prefixed env vars with defaults."""
        self.host = _parse_host(getenv("M0_HOST", ""))
        self.port = _parse_int_env("M0_PORT", default_port)
        self.api_key = getenv("M0_API_KEY", "")
        self.workers = _parse_int_env("M0_WORKERS", 1)
        self.threads = _parse_int_env("M0_THREADS", 1)
        var access_log_str = getenv("M0_ACCESS_LOG", "")
        self.access_log = access_log_str == "true" or access_log_str == "1"
        self.sse_heartbeat_ms = _parse_int_env("M0_SSE_HEARTBEAT_MS", 15000)
        self.app_tick_ms = _parse_int_env("M0_APP_TICK_MS", 0)

        var base_url_env = getenv("M0_BASE_URL", "")
        if base_url_env.byte_length() > 0:
            self.base_url = base_url_env
        else:
            self.base_url = "http://localhost:" + String(self.port)

    def __init__(out self, *, copy: Self):
        self.host = copy.host
        self.port = copy.port
        self.base_url = copy.base_url
        self.api_key = copy.api_key
        self.workers = copy.workers
        self.threads = copy.threads
        self.access_log = copy.access_log
        self.sse_heartbeat_ms = copy.sse_heartbeat_ms
        self.app_tick_ms = copy.app_tick_ms

    def __init__(out self, *, deinit move: Self):
        self.host = move.host^
        self.port = move.port
        self.base_url = move.base_url^
        self.api_key = move.api_key^
        self.workers = move.workers
        self.threads = move.threads
        self.access_log = move.access_log
        self.sse_heartbeat_ms = move.sse_heartbeat_ms
        self.app_tick_ms = move.app_tick_ms

    def address(self) -> String:
        """Return listen address string (e.g. '0.0.0.0:8080')."""
        return self.host + ":" + String(self.port)

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
    """Normalize a listen address; empty means every interface.

    `localhost` becomes `127.0.0.1` because the listener is IPv4-only and
    does no name resolution — a user who types the word expects the loopback
    bind it names everywhere else, not a bind failure. Anything else is
    passed through verbatim for the socket layer to accept or reject.
    """
    var host = raw.strip()
    if host.byte_length() == 0:
        return String("0.0.0.0")
    if host == "localhost":
        return String("127.0.0.1")
    return String(host)


def _parse_int_env(name: String, default: Int) -> Int:
    """Parse integer from env var, returning default on empty/invalid."""
    var val = getenv(name, "")
    if val.byte_length() == 0:
        return default
    var result = 0
    var bytes = val.as_bytes()
    for i in range(val.byte_length()):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return default
        result = result * 10 + (c - ord("0"))
    return result
