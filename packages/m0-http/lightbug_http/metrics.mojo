"""Per-server HTTP metrics with Prometheus text exposition format.

Exposed at GET /__metrics when ServerConfig.enable_metrics is True.
All counters are monotonically increasing; active_connections is a gauge.

The latency histogram records on the event loop thread, so it is O(1) and
integer-only: fixed log-spaced bucket bounds in microseconds, one counter
per bucket, plus sum and count. Buckets are stored per-band and rendered
cumulatively, because Prometheus `le` buckets are cumulative on the wire —
`_bucket{le="+Inf"}` must equal `_count`, and a scraper computes quantiles
from the running totals. Like every other field here the instance is
per-loop: `--workers` forks it, `--threads` builds one per loop, and no
aggregation happens server-side — the scraper's `sum by ()` is the
aggregation, exactly as it is for the counters above.
"""

comptime LATENCY_BUCKET_COUNT = 6
"""Five bounded bands (100µs, 1ms, 10ms, 100ms, 1s) plus the +Inf band."""


def latency_bucket_index(elapsed_us: Int) -> Int:
    """Which histogram band a duration lands in. O(1), no floats.

    Band i counts durations at or under bound i — `le` semantics, so a
    duration exactly on a bound belongs to that bound's band, not the next.
    """
    if elapsed_us <= 100:
        return 0
    if elapsed_us <= 1_000:
        return 1
    if elapsed_us <= 10_000:
        return 2
    if elapsed_us <= 100_000:
        return 3
    if elapsed_us <= 1_000_000:
        return 4
    return 5


def latency_bucket_label(index: Int) -> String:
    """The `le` label for a band, "+Inf" for the last."""
    if index == 0:
        return "100"
    if index == 1:
        return "1000"
    if index == 2:
        return "10000"
    if index == 3:
        return "100000"
    if index == 4:
        return "1000000"
    return "+Inf"


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

    var latency_bands: List[Int]
    """Requests per latency band, NON-cumulative (see `record_duration`)."""

    var latency_sum_us: Int
    """Total microseconds across all sampled requests (monotonic)."""

    var latency_count: Int
    """Requests sampled into the histogram (monotonic)."""

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
        self.latency_bands = List[Int]()
        for _ in range(LATENCY_BUCKET_COUNT):
            self.latency_bands.append(0)
        self.latency_sum_us = 0
        self.latency_count = 0

    def record_duration(mut self, elapsed_us: Int):
        """One completed request's latency into the histogram.

        O(1) and integer-only, because it runs on the event loop thread for
        every response. One increment per sample — the band's, not every
        band at or above it; `to_text` accumulates at render time, where a
        walk over six counters is paid per scrape instead of per request.
        """
        self.latency_sum_us += elapsed_us
        self.latency_count += 1
        self.latency_bands[latency_bucket_index(elapsed_us)] += 1

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

    def histogram_text(self) -> String:
        """The latency histogram, rendered cumulatively.

        Prometheus `le` buckets are running totals: each carries every
        sample at or under its bound, and `le="+Inf"` must equal `_count`
        — which it does by construction here, being the sum of every band.
        """
        var out = String(
            "# HELP http_request_duration_us Request latency from first"
            " header byte to response sent, microseconds\n",
            "# TYPE http_request_duration_us histogram\n",
        )
        var cumulative = 0
        for i in range(LATENCY_BUCKET_COUNT):
            cumulative += self.latency_bands[i]
            out += String(
                'http_request_duration_us_bucket{le="',
                latency_bucket_label(i), '"} ', String(cumulative), "\n",
            )
        out += String(
            "http_request_duration_us_sum ", String(self.latency_sum_us),
            "\n",
            "http_request_duration_us_count ", String(self.latency_count),
            "\n",
        )
        return out

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
            self.histogram_text(),
        )
