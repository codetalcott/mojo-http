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

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
