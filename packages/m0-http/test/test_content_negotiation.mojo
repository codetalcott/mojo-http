"""Tests for content negotiation."""

from std.testing import assert_true, assert_false

from src.content_negotiation import parse_accept, wants_html, wants_event_stream


def test_json_only() raises:
    """application/json should set wants_json."""
    var r = parse_accept("application/json")
    assert_true(r.wants_json)
    assert_false(r.wants_html)
    assert_false(r.wants_siren_bin)


def test_siren_bin() raises:
    """application/vnd.siren+bin should set wants_siren_bin."""
    var r = parse_accept("application/vnd.siren+bin")
    assert_true(r.wants_siren_bin)
    assert_false(r.wants_json)


def test_siren_bin_patch() raises:
    """application/vnd.siren+bin-patch should set wants_siren_bin_patch."""
    var r = parse_accept("application/vnd.siren+bin-patch")
    assert_true(r.wants_siren_bin_patch)


def test_html() raises:
    """text/html should set wants_html."""
    var r = parse_accept("text/html")
    assert_true(r.wants_html)
    assert_false(r.wants_json)


def test_links_json() raises:
    """application/links+json should set wants_links_json."""
    var r = parse_accept("application/links+json")
    assert_true(r.wants_links_json)


def test_event_stream() raises:
    """text/event-stream should set wants_event_stream."""
    var r = parse_accept("text/event-stream")
    assert_true(r.wants_event_stream)


def test_multiple_types() raises:
    """Comma-separated types should all be recognized."""
    var r = parse_accept("text/html, application/json, application/links+json")
    assert_true(r.wants_html)
    assert_true(r.wants_json)
    assert_true(r.wants_links_json)


def test_quality_zero_disables() raises:
    """q=0 should disable a type."""
    var r = parse_accept("application/json;q=0")
    assert_false(r.wants_json)


def test_quality_nonzero_enables() raises:
    """q=0.5 should enable a type."""
    var r = parse_accept("application/json;q=0.5")
    assert_true(r.wants_json)


def test_wildcard() raises:
    """*/* should enable JSON as fallback."""
    var r = parse_accept("*/*")
    assert_true(r.wants_json)


def test_empty_accept() raises:
    """Empty Accept header should leave everything false."""
    var r = parse_accept("")
    assert_false(r.wants_json)
    assert_false(r.wants_html)


def test_convenience_wants_html() raises:
    """wants_html convenience should work."""
    assert_true(wants_html("text/html"))
    assert_false(wants_html("application/json"))


def test_convenience_wants_event_stream() raises:
    """wants_event_stream convenience should work."""
    assert_true(wants_event_stream("text/event-stream"))
    assert_false(wants_event_stream("text/html"))


def test_problem_json() raises:
    """application/problem+json should set wants_problem_json."""
    var r = parse_accept("application/problem+json")
    assert_true(r.wants_problem_json)
    assert_false(r.wants_json)
