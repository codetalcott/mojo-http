"""Tests for ETag computation and matching."""

from std.testing import assert_equal, assert_true, assert_false, assert_not_equal

from src.etag import compute_etag, etag_matches


fn _bytes4() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(1); b.append(2); b.append(3); b.append(4)
    return b^


fn _bytes5() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(10); b.append(20); b.append(30); b.append(40); b.append(50)
    return b^


fn test_etag_format() raises:
    """ETag should be in W/\"hex\" format."""
    var buf = _bytes4()
    var etag = compute_etag(buf)
    assert_true(etag.startswith('W/"'))
    assert_true(etag.endswith('"'))
    # W/" (3) + 16 hex chars + " (1) = 20 chars
    assert_equal(len(etag), 20)


fn test_etag_consistency() raises:
    """Same buffer should produce same ETag."""
    var buf = _bytes5()
    var e1 = compute_etag(buf)
    var e2 = compute_etag(buf)
    assert_equal(e1, e2)


fn test_etag_different_buffers() raises:
    """Different buffers should produce different ETags."""
    var buf1 = List[UInt8]()
    buf1.append(1); buf1.append(2); buf1.append(3)
    var buf2 = List[UInt8]()
    buf2.append(4); buf2.append(5); buf2.append(6)
    assert_not_equal(compute_etag(buf1), compute_etag(buf2))


fn test_etag_matches_exact() raises:
    """Exact ETag match should return True."""
    var etag = 'W/"abc123"'
    assert_true(etag_matches(etag, etag))


fn test_etag_matches_wildcard() raises:
    """* should match any ETag."""
    assert_true(etag_matches('W/"abc"', "*"))


fn test_etag_matches_empty() raises:
    """Empty If-None-Match should not match."""
    assert_false(etag_matches('W/"abc"', ""))


fn test_etag_matches_in_list() raises:
    """ETag should be found in comma-separated list."""
    assert_true(etag_matches('W/"abc"', 'W/"xyz", W/"abc", W/"def"'))


fn test_etag_no_match() raises:
    """Non-matching ETag should return False."""
    assert_false(etag_matches('W/"abc"', 'W/"xyz"'))
