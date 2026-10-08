"""Tests for the latency histogram on `ServerMetrics` (SPEC F5).

The bucket math is exercised at its boundaries because `le` semantics put a
duration exactly on a bound INSIDE that bound's band — off by one here is a
histogram whose tail quantiles silently read a decade wrong. The render is
checked for the two properties a scraper depends on: cumulative counts are
non-decreasing in `le` order, and `le="+Inf"` equals `_count`.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.metrics import (
    LATENCY_BUCKET_COUNT,
    ServerMetrics,
    latency_bucket_index,
    latency_bucket_label,
)


def test_boundary_durations_land_at_their_bound() raises:
    # `le` semantics: exactly on a bound belongs to that bound's band.
    assert_equal(latency_bucket_index(0), 0)
    assert_equal(latency_bucket_index(100), 0)
    assert_equal(latency_bucket_index(101), 1)
    assert_equal(latency_bucket_index(1_000), 1)
    assert_equal(latency_bucket_index(1_001), 2)
    assert_equal(latency_bucket_index(10_000), 2)
    assert_equal(latency_bucket_index(10_001), 3)
    assert_equal(latency_bucket_index(100_000), 3)
    assert_equal(latency_bucket_index(100_001), 4)
    assert_equal(latency_bucket_index(1_000_000), 4)
    assert_equal(latency_bucket_index(1_000_001), 5)


def test_every_band_has_a_label_and_inf_is_last() raises:
    assert_equal(latency_bucket_label(0), "100")
    assert_equal(latency_bucket_label(1), "1000")
    assert_equal(latency_bucket_label(2), "10000")
    assert_equal(latency_bucket_label(3), "100000")
    assert_equal(latency_bucket_label(4), "1000000")
    assert_equal(latency_bucket_label(LATENCY_BUCKET_COUNT - 1), "+Inf")


def test_sum_count_and_bands_track_samples() raises:
    var m = ServerMetrics()
    m.record_duration(50)
    m.record_duration(500)
    m.record_duration(2_000_000)
    assert_equal(m.latency_count, 3)
    assert_equal(m.latency_sum_us, 2_000_550)
    assert_equal(m.latency_bands[0], 1)
    assert_equal(m.latency_bands[1], 1)
    assert_equal(m.latency_bands[5], 1)
    assert_equal(m.latency_bands[2] + m.latency_bands[3] + m.latency_bands[4], 0)


def test_render_is_cumulative_and_inf_equals_count() raises:
    var m = ServerMetrics()
    # One sample in every band, so the cumulative render must read 1..6 —
    # a render that emitted the per-band counts instead would read all 1s,
    # and one that mis-ordered a bound would break the non-decreasing run.
    m.record_duration(100)
    m.record_duration(1_000)
    m.record_duration(10_000)
    m.record_duration(100_000)
    m.record_duration(1_000_000)
    m.record_duration(1_000_001)
    var text = m.histogram_text()
    assert_true(text.find('http_request_duration_us_bucket{le="100"} 1\n') >= 0)
    assert_true(text.find('http_request_duration_us_bucket{le="1000"} 2\n') >= 0)
    assert_true(text.find('http_request_duration_us_bucket{le="10000"} 3\n') >= 0)
    assert_true(
        text.find('http_request_duration_us_bucket{le="100000"} 4\n') >= 0
    )
    assert_true(
        text.find('http_request_duration_us_bucket{le="1000000"} 5\n') >= 0
    )
    assert_true(text.find('http_request_duration_us_bucket{le="+Inf"} 6\n') >= 0)
    assert_true(text.find("http_request_duration_us_sum 2111101\n") >= 0)
    assert_true(text.find("http_request_duration_us_count 6\n") >= 0)


def test_histogram_reaches_the_exposition() raises:
    # `/__metrics` serves `to_text()`; a histogram rendered only by its own
    # method would be a number that exists in the process and reaches nobody.
    var m = ServerMetrics()
    m.record_duration(42)
    var text = m.to_text()
    assert_true(text.find("# TYPE http_request_duration_us histogram\n") >= 0)
    assert_true(text.find("# HELP http_request_duration_us ") >= 0)
    assert_true(text.find('http_request_duration_us_bucket{le="+Inf"} 1\n') >= 0)


def test_every_answered_request_is_in_one_status_class() raises:
    """`http_requests_total` counts requests answered, and each is in one
    class of `http_responses_total`, a 101 in `1xx` (review record LF32).

    A 101 Switching Protocols, the answer to every WebSocket upgrade, was
    in the total and in no class, so the classes summed to less than the
    total on any server holding WebSockets, and the total's help text said
    "received" of a count taken as each response's head lands.

    covers: F23
    """
    var m = ServerMetrics()
    m.record_response(101, 129)
    m.record_response(200, 10)
    m.record_response(304, 0)
    m.record_response(404, 5)
    m.record_response(503, 7)
    m.record_response(101, 129)
    assert_equal(m.requests_total, 6)
    assert_equal(m.responses_1xx, 2, "a 101 is in no status class")
    assert_equal(
        m.responses_1xx + m.responses_2xx + m.responses_3xx
        + m.responses_4xx + m.responses_5xx,
        m.requests_total,
        "the status classes do not sum to the total",
    )
    var text = m.to_text()
    assert_true(
        text.find('http_responses_total{status="1xx"} 2\n') >= 0,
        "the 1xx class is not in the exposition",
    )
    assert_true(text.find("http_requests_total 6\n") >= 0)
    assert_true(
        text.find("# HELP http_requests_total Total HTTP requests answered\n") >= 0,
        "the total's help text does not say what it counts",
    )


def test_empty_histogram_is_well_formed() raises:
    var m = ServerMetrics()
    var text = m.histogram_text()
    assert_true(text.find('http_request_duration_us_bucket{le="+Inf"} 0\n') >= 0)
    assert_true(text.find("http_request_duration_us_count 0\n") >= 0)



def test_a_status_outside_100_to_599_is_in_the_total_alone() raises:
    """Every response is counted, and its bytes summed; a status from 100
    to 599 lands in one class, and one outside that range -- nothing
    range-checks an application's status -- in none, as the field's
    docstring says. `-200 // 100` is -2, a class of none."""
    var m = ServerMetrics()
    m.record_response(0, 3)
    m.record_response(99, 4)
    m.record_response(600, 5)
    m.record_response(999, 6)
    m.record_response(-200, 7)
    m.record_response(100, 8)
    m.record_response(599, 9)
    assert_equal(m.requests_total, 7)
    assert_equal(m.bytes_sent_total, 42)
    assert_equal(m.responses_1xx, 1)
    assert_equal(m.responses_2xx, 0)
    assert_equal(m.responses_3xx, 0)
    assert_equal(m.responses_4xx, 0)
    assert_equal(m.responses_5xx, 1)


def test_every_family_has_help_type_and_its_sample() raises:
    """A scraper drops a family whose HELP or TYPE line is missing
    (exposition 0.0.4), and each sample must be the field it names. Every
    counter and gauge family `to_text` renders, the bus's refusals among
    them; `Smoke test the serve CLI` checks eight of the nine on the wire.

    covers: F4
    """
    var m = ServerMetrics()
    m.requests_total = 11
    m.responses_1xx = 1
    m.responses_2xx = 6
    m.responses_3xx = 2
    m.responses_4xx = 1
    m.responses_5xx = 1
    m.active_connections = 3
    m.bytes_sent_total = 1234
    m.accepts_total = 5
    m.closes_total = 4
    m.pool_available = 1021
    m.pool_capacity = 1024
    m.bus_frames_refused = 2
    var text = m.to_text()
    var families = [
        ("http_requests_total", "counter", "11"),
        ("http_active_connections", "gauge", "3"),
        ("http_bytes_sent_total", "counter", "1234"),
        ("http_accepts_total", "counter", "5"),
        ("http_closes_total", "counter", "4"),
        ("http_pool_available", "gauge", "1021"),
        ("http_pool_capacity", "gauge", "1024"),
        ("http_bus_frames_refused_total", "counter", "2"),
    ]
    for f in families:
        var name = String(f[0])
        assert_true(text.find("# HELP " + name + " ") >= 0, name)
        assert_true(
            text.find("# TYPE " + name + " " + String(f[1]) + "\n") >= 0, name
        )
        assert_true(text.find("\n" + name + " " + String(f[2]) + "\n") >= 0, name)
    assert_true(text.find("# HELP http_responses_total ") >= 0)
    assert_true(text.find("# TYPE http_responses_total counter\n") >= 0)
    var classes = [("1xx", "1"), ("2xx", "6"), ("3xx", "2"), ("4xx", "1"), ("5xx", "1")]
    for c in classes:
        var line = String(
            'http_responses_total{status="', String(c[0]), '"} ', String(c[1]), "\n"
        )
        assert_true(text.find(line) >= 0, line)
    # Every line is a comment or a sample of a family above, and the text
    # ends a line.
    assert_true(text.endswith("\n"))
    for line in text.split("\n"):
        var l = String(line)
        if l.byte_length() == 0:
            continue
        assert_true(l.startswith("# ") or l.startswith("http_"), l)


def test_a_new_server_counts_nothing() raises:
    """Every counter and gauge starts at zero, and the histogram has its six
    bands."""
    var m = ServerMetrics()
    assert_equal(m.requests_total, 0)
    assert_equal(
        m.responses_1xx + m.responses_2xx + m.responses_3xx
        + m.responses_4xx + m.responses_5xx,
        0,
    )
    assert_equal(m.active_connections, 0)
    assert_equal(m.bytes_sent_total, 0)
    assert_equal(m.accepts_total, 0)
    assert_equal(m.closes_total, 0)
    assert_equal(m.pool_available, 0)
    assert_equal(m.pool_capacity, 0)
    assert_equal(m.bus_frames_refused, 0)
    assert_equal(len(m.latency_bands), LATENCY_BUCKET_COUNT)
    assert_equal(m.latency_sum_us, 0)
    assert_equal(m.latency_count, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
