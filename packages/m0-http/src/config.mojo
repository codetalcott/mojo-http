"""Application configuration loaded from M0_-prefixed environment variables.

Provides sensible defaults for all fields. No config file parsing —
env vars are the container convention.

Env vars:
    M0_PORT       — HTTP listen port (default: 8080)
    M0_BASE_URL   — Public base URL (default: http://localhost:{port})
    M0_API_KEY    — API key for mutation auth (default: "" = disabled)
    M0_WORKERS    — Worker count for multi-worker mode (default: 1)
    M0_ACCESS_LOG — Enable access logging: "true" or "1" (default: false)
    M0_SSE_HEARTBEAT_MS — Milliseconds between SSE heartbeat comments on idle
                    streams; "0" disables them (default: 15000)
    M0_APP_TICK_MS — Milliseconds between application `tick` hook calls;
                    "0" disables the tick entirely (default: 0 — the hook
                    is opt-in, ticking costs wakeups)
"""

from std.os import getenv


struct AppConfig(Copyable, Movable):
    """Application configuration loaded from environment."""
    var port: Int
    var base_url: String
    var api_key: String
    var workers: Int
    var access_log: Bool
    var sse_heartbeat_ms: Int
    var app_tick_ms: Int

    def __init__(out self, default_port: Int = 8080):
        """Load configuration from M0_-prefixed env vars with defaults."""
        self.port = _parse_int_env("M0_PORT", default_port)
        self.api_key = getenv("M0_API_KEY", "")
        self.workers = _parse_int_env("M0_WORKERS", 1)
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
        self.port = copy.port
        self.base_url = copy.base_url
        self.api_key = copy.api_key
        self.workers = copy.workers
        self.access_log = copy.access_log
        self.sse_heartbeat_ms = copy.sse_heartbeat_ms
        self.app_tick_ms = copy.app_tick_ms

    def __init__(out self, *, deinit move: Self):
        self.port = move.port
        self.base_url = move.base_url^
        self.api_key = move.api_key^
        self.workers = move.workers
        self.access_log = move.access_log
        self.sse_heartbeat_ms = move.sse_heartbeat_ms
        self.app_tick_ms = move.app_tick_ms

    def address(self) -> String:
        """Return listen address string (e.g. '0.0.0.0:8080')."""
        return "0.0.0.0:" + String(self.port)


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
