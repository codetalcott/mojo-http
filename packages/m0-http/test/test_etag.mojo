"""Tests for ETag computation and matching."""

from std.testing import assert_equal, assert_true, assert_false, assert_not_equal, TestSuite

from src.etag import compute_etag, etag_matches


def _bytes4() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(1); b.append(2); b.append(3); b.append(4)
    return b^


def _bytes5() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(10); b.append(20); b.append(30); b.append(40); b.append(50)
    return b^


def test_etag_format() raises:
    """ETag should be in W/\"hex\" format."""
    var buf = _bytes4()
    var etag = compute_etag(buf)
    assert_true(etag.startswith('W/"'))
    assert_true(etag.endswith('"'))
    # W/" (3) + 16 hex chars + " (1) = 20 chars
    assert_equal(etag.byte_length(), 20)


def test_etag_consistency() raises:
    """Same buffer should produce same ETag."""
    var buf = _bytes5()
    var e1 = compute_etag(buf)
    var e2 = compute_etag(buf)
    assert_equal(e1, e2)


def test_etag_different_buffers() raises:
    """Different buffers should produce different ETags."""
    var buf1 = List[UInt8]()
    buf1.append(1); buf1.append(2); buf1.append(3)
    var buf2 = List[UInt8]()
    buf2.append(4); buf2.append(5); buf2.append(6)
    assert_not_equal(compute_etag(buf1), compute_etag(buf2))


def test_etag_matches_exact() raises:
    """Exact ETag match should return True."""
    var etag = 'W/"abc123"'
    assert_true(etag_matches(etag, etag))


def test_etag_matches_wildcard() raises:
    """* should match any ETag."""
    assert_true(etag_matches('W/"abc"', "*"))


def test_etag_matches_empty() raises:
    """Empty If-None-Match should not match."""
    assert_false(etag_matches('W/"abc"', ""))


def test_etag_matches_in_list() raises:
    """ETag should be found in comma-separated list."""
    assert_true(etag_matches('W/"abc"', 'W/"xyz", W/"abc", W/"def"'))


def test_etag_no_match() raises:
    """Non-matching ETag should return False."""
    assert_false(etag_matches('W/"abc"', 'W/"xyz"'))


def test_etag_no_partial_match() raises:
    """Substring of an ETag should not match."""
    assert_false(etag_matches('W/"abc"', 'W/"abcdef"'))
    assert_false(etag_matches('W/"abc"', 'W/"abcdef", W/"xyz"'))


def test_etag_matches_with_spaces() raises:
    """ETag matching should handle extra whitespace around commas."""
    assert_true(etag_matches('W/"abc"', 'W/"xyz" , W/"abc" , W/"def"'))

def _raw(*bytes: Int) -> String:
    """A String holding exactly these bytes, valid UTF-8 or not."""
    var l = List[UInt8]()
    for b in bytes:
        l.append(UInt8(b))
    return String(unsafe_from_utf8=Span(l))


def test_an_if_none_match_that_is_not_utf8_does_not_trap() raises:
    """`etag_matches` trims each candidate with a String slice; a byte that
    is not UTF-8 at the slice end trapped. It must compare bytes.

    covers: G14
    """
    assert_false(etag_matches('W/"x"', _raw(0x80)))
    assert_false(etag_matches('W/"x"', String(" ") + _raw(0x80) + String(" , W/\"x") + _raw(0xFF)))
    # The same bytes on both sides, with surrounding whitespace to trim, match.
    var tag = String('"') + _raw(0x80) + String('"')
    assert_true(etag_matches(tag, String("  ") + tag + String(" ")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
