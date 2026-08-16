"""Tests for the HTTP client's pure half: response framing and URL helpers.

The client reads to EOF (it sends `Connection: close`), so `_parse_response`
always sees a complete raw response — these tests feed it canned bytes for
each body shape a server can legally send. The socket half is covered by
`poe smoke-client`, which runs a real request against a real server.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.uri import URI

from src.client import (
    _find_header_end,
    _host_header,
    _parse_response,
    _strip_brackets,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def test_content_length_body() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n"
        "content-length: 5\r\n\r\nhello"
    )
    var resp = _parse_response(Span(raw))
    assert_equal(resp.status_code, 200)
    assert_equal(len(resp.body_raw), 5)
    assert_equal(String(StringSlice(unsafe_from_utf8=Span(resp.body_raw))), "hello")


def test_truncated_content_length_is_loud() raises:
    """A body shorter than Content-Length must fail, not silently truncate."""
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nshort"
    )
    var failed = False
    try:
        _ = _parse_response(Span(raw))
    except:
        failed = True
    assert_true(failed, "truncated response parsed silently")


def test_chunked_body_is_decoded() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
    )
    var resp = _parse_response(Span(raw))
    assert_equal(
        String(StringSlice(unsafe_from_utf8=Span(resp.body_raw))), "hello world"
    )
    # The body is decoded, so the header describing the encoding must go.
    assert_true(resp.headers.get("transfer-encoding") is None)
    assert_equal(resp.content_length(), 11)


def test_close_delimited_body() raises:
    """No Content-Length, not chunked: everything after the headers is body."""
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nuntil the close"
    )
    var resp = _parse_response(Span(raw))
    assert_equal(
        String(StringSlice(unsafe_from_utf8=Span(resp.body_raw))),
        "until the close",
    )


def test_error_statuses_are_responses_not_errors() raises:
    var raw = _bytes(
        'HTTP/1.1 404 Not Found\r\ncontent-type: application/problem+json\r\n'
        'content-length: 2\r\n\r\n{}'
    )
    var resp = _parse_response(Span(raw))
    assert_equal(resp.status_code, 404)


def test_empty_body_without_length_is_empty() raises:
    var raw = _bytes("HTTP/1.1 204 No Content\r\n\r\n")
    var resp = _parse_response(Span(raw))
    assert_equal(resp.status_code, 204)
    assert_equal(len(resp.body_raw), 0)


def test_find_header_end() raises:
    var raw = _bytes("HTTP/1.1 200 OK\r\nx: y\r\n\r\nBODY")
    var end = _find_header_end(Span(raw))
    assert_equal(String(chr(Int(raw[end]))), "B")
    var no_end = _bytes("HTTP/1.1 200 OK\r\nx: y\r\n")
    assert_equal(_find_header_end(Span(no_end)), -1)


def test_host_header_omits_default_port() raises:
    assert_equal(_host_header(URI.parse("http://example.test/x")), "example.test")
    assert_equal(_host_header(URI.parse("http://example.test:80/x")), "example.test")
    assert_equal(
        _host_header(URI.parse("http://example.test:8091/x")), "example.test:8091"
    )


def test_strip_brackets() raises:
    assert_equal(_strip_brackets("[::1]"), "::1")
    assert_equal(_strip_brackets("localhost"), "localhost")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
