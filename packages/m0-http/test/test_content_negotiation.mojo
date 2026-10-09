"""Tests for content negotiation."""

from std.testing import assert_true, assert_false, assert_equal, TestSuite

from src.content_negotiation import _split_media_range, parse_accept


comptime VENDOR_BIN = "application/vnd.siren+bin"
comptime VENDOR_LINKS = "application/links+json"


def _vendor_types() -> List[String]:
    """A caller's registered vendor media types, as an app would supply them."""
    return [String(VENDOR_BIN), String(VENDOR_LINKS)]


def test_json_only() raises:
    """`application/json` should set wants_json."""
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
    """`q=0` should disable a registered vendor type."""
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
    """`text/html` should set wants_html."""
    var r = parse_accept("text/html")
    assert_true(r.wants_html)
    assert_false(r.wants_json)


def test_event_stream() raises:
    """`text/event-stream` should set wants_event_stream."""
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
    """`q=0` should disable a type."""
    var r = parse_accept("application/json;q=0")
    assert_false(r.wants_json)


def test_quality_nonzero_enables() raises:
    """`q=0.5` should enable a type."""
    var r = parse_accept("application/json;q=0.5")
    assert_true(r.wants_json)


def _weight_of(entry: String) -> Float64:
    """The weight the splitter reads off one `Accept` entry."""
    var ranges = List[String]()
    var qualities = List[Float64]()
    _split_media_range(entry, ranges, qualities)
    return qualities[0]


def test_the_weight_is_the_parameter_named_q_in_any_case() raises:
    """RFC 9110 §12.4.2: the weight is the parameter NAMED `q`, and a
    parameter's name is case-insensitive (§5.6.6), so `Q=0` refuses a type
    as `q=0` does and `Q=0.5` weighs 0.5. The parameter was found by the
    substring `q=`, and an upper-case `Q` was no weight at all (review
    LF69). The first parameter named `q` is the weight.

    covers: N53
    """
    assert_false(parse_accept("text/html;Q=0").wants_html, "Q=0 ignored")
    assert_false(parse_accept("application/json;Q=0, */*").wants_json)
    assert_equal(_weight_of("text/html;Q=0.5"), 0.5)
    assert_equal(_weight_of("text/html;q=0.5;Q=0"), 0.5)


def test_a_parameter_whose_name_ends_in_q_is_not_the_weight() raises:
    """`xq=0` is a parameter named `xq`, so the type keeps its weight of 1;
    found by the substring `q=`, it read as `q=0` and refused a type the
    client asked for (review LF69). A weight after another parameter is
    still found.

    covers: N53
    """
    assert_true(parse_accept("text/html;xq=0").wants_html, "xq=0 read as q=0")
    assert_equal(_weight_of("text/html;xq=0"), 1.0)
    assert_equal(_weight_of("text/html;xq=0;q=0.5"), 0.5)
    assert_false(parse_accept("text/html;level=1;q=0").wants_html)


def test_whitespace_around_a_weights_equals_sign_is_tolerated() raises:
    """`q = 0` refuses a type and `q= 0.5` weighs 0.5. RFC 9110 §5.6.6
    allows no whitespace around a parameter's `=`, but a client that sent
    some meant the weight: before review LF69 `q =0` was no weight at all
    (the type accepted at 1) and `q= 0.5` read as 0, refusing a type the
    client asked for. Whitespace around the `;` is the grammar's own.

    covers: N53
    """
    assert_false(parse_accept("text/html;q =0").wants_html, "q =0 ignored")
    assert_false(parse_accept("text/html;q = 0").wants_html)
    assert_true(parse_accept("text/html;q= 0.5").wants_html, "q= 0.5 read as 0")
    assert_equal(_weight_of("text/html ; q= 0.5"), 0.5)
    assert_equal(_weight_of("text/html;\tq\t=\t0.5"), 0.5)
    assert_false(parse_accept("text/html ;  q=0").wants_html)


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
    """`text/*` should match text/html and text/event-stream, not JSON."""
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


def test_a_media_range_is_folded_in_ascii_only() raises:
    """A media range is case-folded as ASCII (RFC 9110 §8.3.1) and nothing
    more. It was lowered by Unicode `String.lower()`, which reads KELVIN
    SIGN (U+212A) as `k`: `application/vnd.<U+212A>` named a registered
    `application/vnd.k`, a type the client never asked for, and `C1 A2`,
    an overlong `b`, made `application/vnd.b` of `application/vnd.<C1 A2>`
    (review record LF63).

    covers: G14
    """
    var kelvin = List[UInt8]()
    kelvin.extend("application/vnd.".as_bytes())
    kelvin.append(0xE2)
    kelvin.append(0x84)
    kelvin.append(0xAA)
    var r = parse_accept(String(unsafe_from_utf8=Span(kelvin)), [String("application/vnd.k")])
    assert_false(r.accepts("application/vnd.k"), "KELVIN SIGN read as k")
    var overlong = List[UInt8]()
    overlong.extend("application/vnd.".as_bytes())
    overlong.append(0xC1)
    overlong.append(0xA2)
    r = parse_accept(String(unsafe_from_utf8=Span(overlong)), [String("application/vnd.b")])
    assert_false(r.accepts("application/vnd.b"), "an overlong C1 A2 read as b")
    r = parse_accept("Application/VND.K", [String("application/vnd.k")])
    assert_true(r.accepts("application/vnd.k"))
    assert_true(r.accepts("APPLICATION/VND.K"))


def test_empty_accept() raises:
    """Empty Accept header should leave everything false."""
    var r = parse_accept("")
    assert_false(r.wants_json)
    assert_false(r.wants_html)


def test_problem_json() raises:
    """`application/problem+json` should set wants_problem_json."""
    var r = parse_accept("application/problem+json")
    assert_true(r.wants_problem_json)
    assert_false(r.wants_json)


def _raw(*bytes: Int) -> String:
    """A String holding exactly these bytes, valid UTF-8 or not."""
    var l = List[UInt8]()
    for b in bytes:
        l.append(UInt8(b))
    return String(unsafe_from_utf8=Span(l))


def test_a_header_that_is_not_utf8_does_not_trap() raises:
    """The range splitter, the media-range splitter, the quality slice, the
    subtype wildcard and `_trim` all sliced request header values as
    Strings; a byte that is not UTF-8 at a slice end trapped the process.
    An `Accept` carrying one must parse to some answer.

    covers: G14
    """
    var bad = String("text/html;q=") + _raw(0x80) + String(", ") + _raw(0x80) + String("/x, */*;q=0.1")
    var result = parse_accept(bad)
    # Whatever the malformed ranges mean, the well-formed one still counts.
    assert_true(result.wants_json)
    _ = parse_accept(_raw(0x80))
    var padded = parse_accept(String(" ") + _raw(0xFF) + String(" ,text/event-stream"))
    assert_true(padded.wants_event_stream)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
