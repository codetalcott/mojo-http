"""Tests for m0-http cors module."""

from m0_http.cors import CorsConfig, apply_cors_headers
from lightbug_http import HTTPResponse, HeaderKey
from lightbug_http.io.bytes import Bytes
from std.testing import assert_equal, assert_true


def test_cors_default_config() raises:
    """Default CorsConfig has expected values."""
    var c = CorsConfig()
    assert_equal(c.allow_origin, "*")
    assert_true("GET" in c.allow_methods)
    assert_true("POST" in c.allow_methods)
    assert_true("X-API-Key" in c.allow_headers)
    assert_true("ETag" in c.expose_headers)


def test_cors_apply_headers() raises:
    """apply_cors_headers sets all headers."""
    var config = CorsConfig()
    var resp = HTTPResponse(body_bytes=Bytes(), status_code=200, status_text="OK")
    apply_cors_headers(resp, config)
    assert_equal(resp.headers[HeaderKey.ACCESS_CONTROL_ALLOW_ORIGIN], "*")
    assert_true("GET" in resp.headers[HeaderKey.ACCESS_CONTROL_ALLOW_METHODS])
    assert_true("X-API-Key" in resp.headers[HeaderKey.ACCESS_CONTROL_ALLOW_HEADERS])


def test_cors_custom_config() raises:
    """Custom CorsConfig values are applied."""
    var config = CorsConfig()
    config.allow_origin = "https://example.com"
    config.max_age = "7200"
    var resp = HTTPResponse(body_bytes=Bytes(), status_code=200, status_text="OK")
    apply_cors_headers(resp, config)
    assert_equal(resp.headers[HeaderKey.ACCESS_CONTROL_ALLOW_ORIGIN], "https://example.com")
    assert_equal(resp.headers[HeaderKey.ACCESS_CONTROL_MAX_AGE], "7200")


def test_cors_empty_expose_headers() raises:
    """Empty expose_headers skips the header."""
    var config = CorsConfig()
    config.expose_headers = String("")
    var resp = HTTPResponse(body_bytes=Bytes(), status_code=200, status_text="OK")
    apply_cors_headers(resp, config)
    var expose = resp.headers.get(HeaderKey.ACCESS_CONTROL_EXPOSE_HEADERS)
    assert_true(not expose)
