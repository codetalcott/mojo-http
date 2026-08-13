"""Tests for the pure parts of the WSGI mapping.

Deliberately no interpreter here: `cgi_header_name` and `split_status` are
plain string transforms, and keeping them testable without Python is why they
are separate from `build_environ` and `build_response`.
"""

from std.testing import assert_equal, TestSuite

from src.environ import cgi_header_name
from src.response import split_status


def test_cgi_header_name_prefixes_ordinary_headers() raises:
    """Ordinary headers get HTTP_ and are upper-cased with dashes to underscores."""
    assert_equal(cgi_header_name("accept-encoding"), "HTTP_ACCEPT_ENCODING")
    assert_equal(cgi_header_name("host"), "HTTP_HOST")
    assert_equal(cgi_header_name("x-forwarded-proto"), "HTTP_X_FORWARDED_PROTO")


def test_cgi_header_name_content_headers_unprefixed() raises:
    """PEP 3333: Content-Type and Content-Length carry no HTTP_ prefix."""
    assert_equal(cgi_header_name("content-type"), "CONTENT_TYPE")
    assert_equal(cgi_header_name("content-length"), "CONTENT_LENGTH")


def test_cgi_header_name_is_case_insensitive() raises:
    """`Headers` lowercases keys, but the mapping must not depend on that."""
    assert_equal(cgi_header_name("Content-Type"), "CONTENT_TYPE")
    assert_equal(cgi_header_name("USER-AGENT"), "HTTP_USER_AGENT")


def test_split_status_ordinary() raises:
    """A normal status line splits into code and reason phrase."""
    var ok = split_status("200 OK")
    assert_equal(ok[0], 200)
    assert_equal(ok[1], "OK")

    var missing = split_status("404 Not Found")
    assert_equal(missing[0], 404)
    assert_equal(missing[1], "Not Found")


def test_split_status_multiword_reason() raises:
    """The reason phrase keeps its spaces."""
    var status = split_status("500 Internal Server Error")
    assert_equal(status[0], 500)
    assert_equal(status[1], "Internal Server Error")


def test_split_status_code_only() raises:
    """A bare code is legal; the reason phrase is optional in WSGI practice."""
    var status = split_status("204")
    assert_equal(status[0], 204)
    assert_equal(status[1], "")


def test_split_status_malformed_becomes_500() raises:
    """A malformed status must not discard an already-computed body."""
    var status = split_status("banana")
    assert_equal(status[0], 500)
    assert_equal(status[1], "Internal Server Error")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
