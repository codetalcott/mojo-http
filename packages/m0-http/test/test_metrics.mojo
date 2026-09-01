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


def test_empty_histogram_is_well_formed() raises:
    var m = ServerMetrics()
    var text = m.histogram_text()
    assert_true(text.find('http_request_duration_us_bucket{le="+Inf"} 0\n') >= 0)
    assert_true(text.find("http_request_duration_us_count 0\n") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
