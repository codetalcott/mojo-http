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
    """Floor for one connection's receive buffer; the cap is `recv_buffer_limit`.

    Never the effective ceiling on its own. A request is headers plus body
    and each has its own limit, so the buffer must be allowed to hold
    `max_total_header_size + max_request_body_size`, or a body the server
    advertises as acceptable is refused — and refused by the buffer check as
    a `400 Bad Request`, not the `413` the body limit sends. That is what
    happened: 2 MB here against the 4 MB body default meant every upload
    between the two failed with a 400 under every `--max-body`, including
    no flag at all; three real Django projects' image uploads found it
    (docs/REAL_APP_VALIDATION.md, 2026-08-26).
    """

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
        # 1000, nginx's default since 1.19.10, from 100: every close is a
        # reconnect for the client, and one per hundred requests was the
        # fast route's whole 99th percentile on a loopback benchmark
        # (docs/notes/pool-tail.md). 0 never closes for count.
        self.max_keepalive_requests = 1000

        self.socket_buffer_size = default_buffer_size
        self.recv_buffer_max = 2 * 1024 * 1024  # a floor; see recv_buffer_limit

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

    def recv_buffer_limit(self) -> Int:
        """The most bytes one connection may hold buffered and unprocessed.

        `recv_buffer_max` or the headers-plus-body allowance, whichever is
        larger — so raising `max_request_body_size` (m0serve's `--max-body`)
        raises this with it, whichever field a caller set and in whichever
        order. The check sites, in `loop/request.mojo`, compare against
        this, never against the field.
        """
        var allowance = self.max_total_header_size + self.max_request_body_size
        return self.recv_buffer_max if self.recv_buffer_max > allowance else allowance
