"""Tests for content negotiation."""

from std.testing import assert_true, assert_false, assert_equal, TestSuite

from src.content_negotiation import (
    negotiate_encoding,
    negotiate_language,
    parse_accept,
    wants_html,
    wants_event_stream,
)


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


def test_empty_accept() raises:
    """Empty Accept header should leave everything false."""
    var r = parse_accept("")
    assert_false(r.wants_json)
    assert_false(r.wants_html)


def test_convenience_wants_html() raises:
    """`wants_html` convenience should work."""
    assert_true(wants_html("text/html"))
    assert_false(wants_html("application/json"))


def test_convenience_wants_event_stream() raises:
    """`wants_event_stream` convenience should work."""
    assert_true(wants_event_stream("text/event-stream"))
    assert_false(wants_event_stream("text/html"))


def test_problem_json() raises:
    """`application/problem+json` should set wants_problem_json."""
    var r = parse_accept("application/problem+json")
    assert_true(r.wants_problem_json)
    assert_false(r.wants_json)


# --- Accept-Encoding (RFC 9110 §12.5.3) --------------------------------------


def _gzip_br() -> List[String]:
    var a = List[String]()
    a.append("br")
    a.append("gzip")
    return a^


def test_encoding_absent_header_means_identity() raises:
    """No Accept-Encoding: serve unencoded, the answer nobody guesses about."""
    assert_equal(negotiate_encoding("", _gzip_br()), "identity")


def test_encoding_picks_the_named_coding() raises:
    var gz = List[String]()
    gz.append("gzip")
    assert_equal(negotiate_encoding("gzip", gz), "gzip")


def test_encoding_server_preference_breaks_quality_ties() raises:
    """`available` is ordered by server preference; equal q keeps that order."""
    assert_equal(negotiate_encoding("gzip, br", _gzip_br()), "br")


def test_encoding_client_quality_beats_server_order() raises:
    """A client that says gzip;q=1, br;q=0.5 gets gzip, whatever we prefer."""
    assert_equal(negotiate_encoding("br;q=0.5, gzip;q=1", _gzip_br()), "gzip")


def test_encoding_quality_zero_disables_a_coding() raises:
    var gz = List[String]()
    gz.append("gzip")
    assert_equal(negotiate_encoding("gzip;q=0", gz), "identity")


def test_encoding_wildcard_matches_unnamed_codings() raises:
    var gz = List[String]()
    gz.append("gzip")
    assert_equal(negotiate_encoding("*", gz), "gzip")


def test_encoding_wildcard_does_not_revive_a_refused_coding() raises:
    """`gzip;q=0`, * refuses gzip explicitly; the wildcard covers the rest."""
    assert_equal(negotiate_encoding("gzip;q=0, *", _gzip_br()), "br")


def test_encoding_unknown_available_falls_back_to_identity() raises:
    """The client asked for gzip; we only have zstd. Serve identity."""
    var zs = List[String]()
    zs.append("zstd")
    assert_equal(negotiate_encoding("gzip", zs), "identity")


def test_encoding_identity_refused_yields_the_406_signal() raises:
    """`identity;q=0` with nothing acceptable available returns empty."""
    var gz = List[String]()
    gz.append("gzip")
    assert_equal(negotiate_encoding("identity;q=0, br", gz), "")


def test_encoding_star_zero_refuses_identity_too() raises:
    """*;q=0 refuses everything unnamed — identity included (RFC example)."""
    var zs = List[String]()
    zs.append("zstd")
    assert_equal(negotiate_encoding("gzip, *;q=0", zs), "")


def test_encoding_star_zero_with_identity_named_keeps_identity() raises:
    var zs = List[String]()
    zs.append("zstd")
    assert_equal(negotiate_encoding("identity;q=0.5, *;q=0", zs), "identity")


def test_encoding_is_case_insensitive() raises:
    var gz = List[String]()
    gz.append("gzip")
    assert_equal(negotiate_encoding("GZip", gz), "gzip")
    var up = List[String]()
    up.append("GZIP")
    assert_equal(negotiate_encoding("gzip", up), "gzip")


def test_encoding_last_occurrence_wins() raises:
    """A repeated coding behaves like an overwrite, as on the Accept side."""
    var gz = List[String]()
    gz.append("gzip")
    assert_equal(negotiate_encoding("gzip;q=0, gzip", gz), "gzip")


def test_encoding_identity_in_available_is_not_an_encoding() raises:
    """Listing identity in `available` must not make it beat a real coding."""
    var av = List[String]()
    av.append("identity")
    av.append("gzip")
    assert_equal(negotiate_encoding("gzip", av), "gzip")


def test_encoding_tolerates_whitespace() raises:
    assert_equal(
        negotiate_encoding(" br ; q=0.8 ,  gzip ; q=0.9 ", _gzip_br()), "gzip"
    )



# --- Accept-Language (RFC 9110 §12.5.4, matching per RFC 4647) ---------------


def _en_de() -> List[String]:
    var a = List[String]()
    a.append("en")
    a.append("de-CH")
    return a^


def test_language_absent_header_serves_the_default() raises:
    """No Accept-Language: the server's first choice, not an error."""
    assert_equal(negotiate_language("", _en_de()), "en")


def test_language_exact_match() raises:
    assert_equal(negotiate_language("de-CH", _en_de()), "de-CH")


def test_language_is_case_insensitive_and_keeps_caller_casing() raises:
    """BCP 47 tags compare case-insensitively; the caller's spelling returns."""
    assert_equal(negotiate_language("DE-ch", _en_de()), "de-CH")


def test_language_range_prefix_matches_regional_tag() raises:
    """RFC 4647 basic filtering: range `de` matches available `de-CH`."""
    assert_equal(negotiate_language("de", _en_de()), "de-CH")


def test_language_lookup_falls_back_to_the_base_tag() raises:
    """RFC 4647 lookup: range `en-US` finds available `en`."""
    assert_equal(negotiate_language("en-US", _en_de()), "en")


def test_language_prefix_boundary_is_respected() raises:
    """Range `de` must not match an available `denglish`."""
    var a = List[String]()
    a.append("denglish")
    a.append("en")
    assert_equal(negotiate_language("de, en;q=0.1", a), "en")


def test_language_client_quality_orders_the_choice() raises:
    assert_equal(negotiate_language("en;q=0.3, de-CH;q=0.9", _en_de()), "de-CH")


def test_language_quality_ties_keep_server_order() raises:
    assert_equal(negotiate_language("de-CH, en", _en_de()), "en")


def test_language_specific_range_beats_a_broader_one() raises:
    """`en-GB;q=0.9` with en;q=0.1: the exact range settles available en-GB."""
    var a = List[String]()
    a.append("en")
    a.append("en-GB")
    assert_equal(negotiate_language("en;q=0.1, en-GB;q=0.9", a), "en-GB")


def test_language_unmatched_request_still_gets_the_default() raises:
    """A French-only client gets the default, not a 406 — RFC advice."""
    assert_equal(negotiate_language("fr", _en_de()), "en")


def test_language_refusing_the_default_falls_to_the_next_tag() raises:
    """`en;q=0` refuses en only; unmatched de-CH is acceptance by silence."""
    assert_equal(negotiate_language("en;q=0", _en_de()), "de-CH")


def test_language_refusing_everything_is_visible() raises:
    """Only when every available tag is refused does "" come back."""
    var only_en = List[String]()
    only_en.append("en")
    assert_equal(negotiate_language("en;q=0", only_en), "")


def test_language_star_zero_refuses_everything_unnamed() raises:
    var only_en = List[String]()
    only_en.append("en")
    assert_equal(negotiate_language("fr, *;q=0", only_en), "")


def test_language_wildcard_accepts_anything() raises:
    assert_equal(negotiate_language("fr, *;q=0.1", _en_de()), "en")


def test_language_no_available_tags_is_empty() raises:
    assert_equal(negotiate_language("en", List[String]()), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
