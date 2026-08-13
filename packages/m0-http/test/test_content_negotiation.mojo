"""Tests for content negotiation."""

from std.testing import assert_true, assert_false, assert_equal, TestSuite

from src.content_negotiation import parse_accept, wants_html, wants_event_stream


comptime VENDOR_BIN = "application/vnd.siren+bin"
comptime VENDOR_LINKS = "application/links+json"


def _vendor_types() -> List[String]:
    """A caller's registered vendor media types, as an app would supply them."""
    return [String(VENDOR_BIN), String(VENDOR_LINKS)]


def test_json_only() raises:
    """application/json should set wants_json."""
    var r = parse_accept("application/json", _vendor_types())
    assert_true(r.wants_json)
    assert_false(r.wants_html)
    assert_false(r.accepts(VENDOR_BIN))


def test_registered_vendor_type() raises:
    """A registered vendor type should be recorded in extra_types."""
    var r = parse_accept(VENDOR_BIN, _vendor_types())
    assert_true(r.accepts(VENDOR_BIN))
    assert_false(r.accepts(VENDOR_LINKS))
    assert_false(r.wants_json)


def test_unregistered_vendor_type_ignored() raises:
    """A vendor type the caller did not register should not match."""
    var r = parse_accept("application/vnd.siren+bin", List[String]())
    assert_false(r.accepts(VENDOR_BIN))
    assert_equal(len(r.extra_types), 0)


def test_vendor_type_quality_zero() raises:
    """q=0 should disable a registered vendor type."""
    var r = parse_accept(String(VENDOR_BIN) + ";q=0", _vendor_types())
    assert_false(r.accepts(VENDOR_BIN))


def test_vendor_type_last_occurrence_wins() raises:
    """A later q=0 should clear an earlier positive match."""
    var header = String(VENDOR_BIN) + ", " + String(VENDOR_BIN) + ";q=0"
    var r = parse_accept(header, _vendor_types())
    assert_false(r.accepts(VENDOR_BIN))


def test_vendor_type_not_duplicated() raises:
    """A repeated vendor type should be recorded once."""
    var header = String(VENDOR_BIN) + ", " + String(VENDOR_BIN)
    var r = parse_accept(header, _vendor_types())
    assert_true(r.accepts(VENDOR_BIN))
    assert_equal(len(r.extra_types), 1)


def test_html() raises:
    """text/html should set wants_html."""
    var r = parse_accept("text/html")
    assert_true(r.wants_html)
    assert_false(r.wants_json)


def test_event_stream() raises:
    """text/event-stream should set wants_event_stream."""
    var r = parse_accept("text/event-stream")
    assert_true(r.wants_event_stream)


def test_multiple_types() raises:
    """Comma-separated standard and vendor types should all be recognized."""
    var r = parse_accept(
        "text/html, application/json, application/links+json", _vendor_types()
    )
    assert_true(r.wants_html)
    assert_true(r.wants_json)
    assert_true(r.accepts(VENDOR_LINKS))


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


def test_wildcard_does_not_override_refusal() raises:
    """A trailing */* must not revive a type refused with q=0."""
    var r = parse_accept("application/json;q=0, */*")
    assert_false(r.wants_json)


def test_wildcard_before_refusal() raises:
    """Order must not matter: the more specific range still wins."""
    var r = parse_accept("*/*, application/json;q=0")
    assert_false(r.wants_json)


def test_wildcard_selects_json_only() raises:
    """*/* is a JSON fallback: it must not select HTML or a vendor binary.

    Plain `curl` sends `Accept: */*`; handing it an opaque binary because it
    said it would take anything is the wrong default.
    """
    var r = parse_accept("*/*", _vendor_types())
    assert_true(r.wants_json)
    assert_false(r.wants_html)
    assert_false(r.wants_event_stream)
    assert_false(r.accepts(VENDOR_BIN))


def test_subtype_wildcard_does_not_select_vendor_type() raises:
    """A vendor type must be named exactly, never matched by application/*."""
    var r = parse_accept("application/*", _vendor_types())
    assert_true(r.wants_json)
    assert_false(r.accepts(VENDOR_BIN))


def test_subtype_wildcard() raises:
    """text/* should match text/html and text/event-stream, not JSON."""
    var r = parse_accept("text/*")
    assert_true(r.wants_html)
    assert_true(r.wants_event_stream)
    assert_false(r.wants_json)


def test_subtype_wildcard_refusal_is_specific() raises:
    """An exact range beats a subtype wildcard that refuses it."""
    var r = parse_accept("text/*;q=0, text/html")
    assert_true(r.wants_html)
    assert_false(r.wants_event_stream)


def test_media_type_is_case_insensitive() raises:
    """RFC 9110 8.3.1: type and subtype are case-insensitive."""
    var r = parse_accept("Text/HTML, APPLICATION/JSON")
    assert_true(r.wants_html)
    assert_true(r.wants_json)


def test_vendor_type_case_insensitive() raises:
    """Registered vendor types should match regardless of header casing."""
    var r = parse_accept("Application/VND.Siren+Bin", _vendor_types())
    assert_true(r.accepts(VENDOR_BIN))


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

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
