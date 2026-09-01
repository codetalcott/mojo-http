"""Tests for m0-http auth module."""

from m0_http.auth import check_api_key
from lightbug_http.header import Headers
from std.testing import assert_true, assert_false, TestSuite


def test_auth_disabled() raises:
    """Empty expected key means auth disabled — always passes."""
    var headers = Headers()
    assert_true(check_api_key(headers, String("")))


def test_auth_no_header() raises:
    """Missing X-API-Key header fails."""
    var headers = Headers()
    assert_false(check_api_key(headers, String("secret")))


def test_auth_correct_key() raises:
    """Matching key passes."""
    var headers = Headers()
    headers["X-API-Key"] = "my-secret-key"
    assert_true(check_api_key(headers, String("my-secret-key")))


def test_auth_wrong_key() raises:
    """Non-matching key fails."""
    var headers = Headers()
    headers["X-API-Key"] = "wrong-key"
    assert_false(check_api_key(headers, String("my-secret-key")))


def test_auth_length_mismatch() raises:
    """Different-length keys fail."""
    var headers = Headers()
    headers["X-API-Key"] = "short"
    assert_false(check_api_key(headers, String("much-longer-key")))


def test_auth_empty_provided() raises:
    """Empty provided key fails when expected is non-empty."""
    var headers = Headers()
    headers["X-API-Key"] = ""
    assert_false(check_api_key(headers, String("secret")))


def test_auth_case_sensitive() raises:
    """Key comparison is case-sensitive."""
    var headers = Headers()
    headers["X-API-Key"] = "Secret"
    assert_false(check_api_key(headers, String("secret")))


def test_a_rotation_of_the_key_is_rejected() raises:
    """The comparison indexes each side modulo its own length, so a value
    that repeats the real key must not compare equal. The length check is
    what catches it — this asserts the two work together.

    covers: G9
    """
    var h = Headers()
    h["X-API-Key"] = "abab"
    assert_false(check_api_key(h, String("ab")))
    var h2 = Headers()
    h2["X-API-Key"] = "ab"
    assert_false(check_api_key(h2, String("abab")))


def test_a_key_longer_than_the_round_floor_is_compared_in_full() raises:
    """Every byte of the expected key must be compared, however long it is.

    The fixed round count has a floor, not a ceiling: capping it would have
    meant a key past that length had its tail ignored, so two keys sharing
    a long prefix would both authenticate.
    """
    var long_key = String("k") * 100
    var almost = String("k") * 99 + "X"  # differs only at the last byte
    var ok = Headers()
    ok["X-API-Key"] = long_key
    assert_true(check_api_key(ok, long_key))
    var bad = Headers()
    bad["X-API-Key"] = almost
    assert_false(check_api_key(bad, long_key))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
