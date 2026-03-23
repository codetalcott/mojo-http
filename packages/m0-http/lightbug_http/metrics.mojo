"""Per-server HTTP metrics with Prometheus text exposition format.

Exposed at GET /__metrics when ServerConfig.enable_metrics is True.
All counters are monotonically increasing; active_connections is a gauge.
"""


struct ServerMetrics(Movable):
    """Counters and gauges tracking server activity."""

    var requests_total: Int
    """Total HTTP requests received (monotonic)."""

    var responses_2xx: Int
    """Responses with 2xx status (monotonic)."""

    var responses_3xx: Int
    """Responses with 3xx status (monotonic)."""

    var responses_4xx: Int
    """Responses with 4xx status (monotonic)."""

    var responses_5xx: Int
    """Responses with 5xx status (monotonic)."""

    var active_connections: Int
    """Current open connections (gauge)."""

    var bytes_sent_total: Int
    """Total bytes sent across all responses (monotonic)."""

    var accepts_total: Int
    """Total connections accepted (monotonic)."""

    var closes_total: Int
    """Total connections closed (monotonic)."""

    var pool_available: Int
    """Available slots in connection pool (gauge)."""

    var pool_capacity: Int
    """Total connection pool capacity (constant gauge)."""

    def __init__(out self):
        self.requests_total = 0
        self.responses_2xx = 0
        self.responses_3xx = 0
        self.responses_4xx = 0
        self.responses_5xx = 0
        self.active_connections = 0
        self.bytes_sent_total = 0
        self.accepts_total = 0
        self.closes_total = 0
        self.pool_available = 0
        self.pool_capacity = 0

    def record_response(mut self, status_code: Int, bytes_sent: Int):
        """Record a completed response."""
        self.requests_total += 1
        self.bytes_sent_total += bytes_sent
        var bucket = status_code // 100
        if bucket == 2:
            self.responses_2xx += 1
        elif bucket == 3:
            self.responses_3xx += 1
        elif bucket == 4:
            self.responses_4xx += 1
        elif bucket == 5:
            self.responses_5xx += 1

    def to_text(self) -> String:
        """Prometheus text exposition format (text/plain; version=0.0.4)."""
        return String(
            "# HELP http_requests_total Total HTTP requests received\n",
            "# TYPE http_requests_total counter\n",
            "http_requests_total ", String(self.requests_total), "\n",
            "# HELP http_responses_total HTTP responses by status class\n",
            "# TYPE http_responses_total counter\n",
            'http_responses_total{status="2xx"} ', String(self.responses_2xx), "\n",
            'http_responses_total{status="3xx"} ', String(self.responses_3xx), "\n",
            'http_responses_total{status="4xx"} ', String(self.responses_4xx), "\n",
            'http_responses_total{status="5xx"} ', String(self.responses_5xx), "\n",
            "# HELP http_active_connections Current open connections\n",
            "# TYPE http_active_connections gauge\n",
            "http_active_connections ", String(self.active_connections), "\n",
            "# HELP http_bytes_sent_total Total bytes sent in responses\n",
            "# TYPE http_bytes_sent_total counter\n",
            "http_bytes_sent_total ", String(self.bytes_sent_total), "\n",
            "# HELP http_accepts_total Total connections accepted\n",
            "# TYPE http_accepts_total counter\n",
            "http_accepts_total ", String(self.accepts_total), "\n",
            "# HELP http_closes_total Total connections closed\n",
            "# TYPE http_closes_total counter\n",
            "http_closes_total ", String(self.closes_total), "\n",
            "# HELP http_pool_available Available connection pool slots\n",
            "# TYPE http_pool_available gauge\n",
            "http_pool_available ", String(self.pool_available), "\n",
            "# HELP http_pool_capacity Total connection pool capacity\n",
            "# TYPE http_pool_capacity gauge\n",
            "http_pool_capacity ", String(self.pool_capacity), "\n",
        )
