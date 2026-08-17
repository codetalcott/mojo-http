"""ServerConfig — extracted to avoid circular imports between server.mojo
and event_loop.mojo."""

from lightbug_http.connection import default_buffer_size


struct ServerConfig(Copyable, Movable):
    """Configuration for the HTTP server."""

    var max_connections: Int
    """Maximum number of concurrent connections."""

    var max_keepalive_requests: Int
    """Maximum requests per keepalive connection (0 = unlimited)."""

    var socket_buffer_size: Int
    """Size of socket read buffer."""

    var recv_buffer_max: Int
    """Maximum total receive buffer size."""

    var max_request_body_size: Int
    """Maximum request body size."""

    var max_request_uri_length: Int
    """Maximum URI length."""

    var max_total_header_size: Int
    """Maximum total header size in bytes."""

    var header_read_timeout: Int
    """Seconds to wait for complete request headers (0 = no timeout)."""

    var body_read_timeout: Int
    """Seconds to wait for request body (0 = no timeout)."""

    var idle_timeout: Int
    """Seconds to wait for next request on keep-alive connection (0 = no timeout)."""

    var access_log: Bool
    """Write one access log line per completed request to stdout (default: False)."""

    var enable_metrics: Bool
    """Serve Prometheus-format metrics at GET /__metrics (default: False)."""

    var sse_heartbeat_ms: Int
    """Milliseconds between SSE heartbeat comments (default: 15000)."""

    var app_tick_ms: Int
    """Milliseconds between application `tick` hook calls (0 = never, default)."""

    def __init__(out self):
        self.max_connections = 1024
        self.max_keepalive_requests = 100

        self.socket_buffer_size = default_buffer_size
        self.recv_buffer_max = 2 * 1024 * 1024  # 2MB

        self.max_request_body_size = 4 * 1024 * 1024  # 4MB
        self.max_request_uri_length = 8192
        self.max_total_header_size = 32 * 1024  # 32KB

        self.header_read_timeout = 10
        self.body_read_timeout = 30
        self.idle_timeout = 60

        self.access_log = False
        self.enable_metrics = False
        self.sse_heartbeat_ms = 15000
        self.app_tick_ms = 0

    def __init__(out self, *, copy: Self):
        self.max_connections = copy.max_connections
        self.max_keepalive_requests = copy.max_keepalive_requests
        self.socket_buffer_size = copy.socket_buffer_size
        self.recv_buffer_max = copy.recv_buffer_max
        self.max_request_body_size = copy.max_request_body_size
        self.max_request_uri_length = copy.max_request_uri_length
        self.max_total_header_size = copy.max_total_header_size
        self.header_read_timeout = copy.header_read_timeout
        self.body_read_timeout = copy.body_read_timeout
        self.idle_timeout = copy.idle_timeout
        self.access_log = copy.access_log
        self.enable_metrics = copy.enable_metrics
        self.sse_heartbeat_ms = copy.sse_heartbeat_ms
        self.app_tick_ms = copy.app_tick_ms

    def __init__(out self, *, deinit take: Self):
        self.max_connections = take.max_connections
        self.max_keepalive_requests = take.max_keepalive_requests
        self.socket_buffer_size = take.socket_buffer_size
        self.recv_buffer_max = take.recv_buffer_max
        self.max_request_body_size = take.max_request_body_size
        self.max_request_uri_length = take.max_request_uri_length
        self.max_total_header_size = take.max_total_header_size
        self.header_read_timeout = take.header_read_timeout
        self.body_read_timeout = take.body_read_timeout
        self.idle_timeout = take.idle_timeout
        self.access_log = take.access_log
        self.enable_metrics = take.enable_metrics
        self.sse_heartbeat_ms = take.sse_heartbeat_ms
        self.app_tick_ms = take.app_tick_ms
