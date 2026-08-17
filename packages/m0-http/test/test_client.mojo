"""Tests for the HTTP client's pure half: response framing and URL helpers.

`classify_response` decides where a response ends — the decision keep-alive
lives or dies by — and `_parse_response` consumes exactly one complete
message; these tests feed both canned bytes for each body shape a server
can legally send, including split at awkward offsets. The socket half
(reuse itself, the stale-connection retry) is covered by `poe
smoke-client`, which runs real requests against a real server and counts
its accepts.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.uri import URI

from src.client import (
    classify_response,
    FRAME_COMPLETE,
    FRAME_ERROR,
    FRAME_INCOMPLETE,
    FRAME_UNTIL_CLOSE,
    _find_header_end,
    _host_header,
    _parse_response,
    _status_code,
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


# --- Framing: where does the response end? -----------------------------------


def test_frame_content_length_boundary() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello"
    )
    var res = classify_response(Span(raw), "GET")
    assert_equal(res.kind, FRAME_COMPLETE)
    assert_equal(res.end, len(raw))


def test_frame_incomplete_until_full_body() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhel"
    )
    assert_equal(classify_response(Span(raw), "GET").kind, FRAME_INCOMPLETE)


def test_frame_incomplete_mid_headers() raises:
    var raw = _bytes("HTTP/1.1 200 OK\r\ncontent-len")
    assert_equal(classify_response(Span(raw), "GET").kind, FRAME_INCOMPLETE)


def test_frame_extra_bytes_past_boundary_are_not_this_message() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhelloJUNK"
    )
    var res = classify_response(Span(raw), "GET")
    assert_equal(res.kind, FRAME_COMPLETE)
    assert_equal(res.end, len(raw) - 4)


def test_frame_chunked_terminal_chunk_ends_it() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        "5\r\nhello\r\n0\r\n\r\n"
    )
    var res = classify_response(Span(raw), "GET")
    assert_equal(res.kind, FRAME_COMPLETE)
    assert_equal(res.end, len(raw))


def test_frame_chunked_incomplete_without_terminal() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        "5\r\nhello\r\n"
    )
    assert_equal(classify_response(Span(raw), "GET").kind, FRAME_INCOMPLETE)


def test_frame_chunked_final_crlf_pending_is_incomplete() raises:
    # The last-chunk marker arrived but its closing CRLF has not: one more
    # read is owed, and calling this complete would desync the connection.
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        "5\r\nhello\r\n0\r\n"
    )
    assert_equal(classify_response(Span(raw), "GET").kind, FRAME_INCOMPLETE)


def test_frame_chunked_trailers_end_at_blank_line() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        "5\r\nhello\r\n0\r\nExpires: never\r\n\r\n"
    )
    var res = classify_response(Span(raw), "GET")
    assert_equal(res.kind, FRAME_COMPLETE)
    assert_equal(res.end, len(raw))


def test_frame_chunked_garbage_is_error() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        "zz\r\nhello\r\n"
    )
    assert_equal(classify_response(Span(raw), "GET").kind, FRAME_ERROR)


def test_frame_head_response_ends_at_headers() raises:
    # A HEAD response advertises the length its GET twin would have — the
    # advertised bytes never come, and waiting for them would hang forever.
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-length: 5000\r\n\r\n"
    )
    var res = classify_response(Span(raw), "HEAD")
    assert_equal(res.kind, FRAME_COMPLETE)
    assert_equal(res.end, len(raw))


def test_frame_bodiless_statuses_end_at_headers() raises:
    for status in ["204 No Content", "304 Not Modified", "100 Continue"]:
        var raw = _bytes("HTTP/1.1 " + status + "\r\n\r\n")
        var res = classify_response(Span(raw), "GET")
        assert_equal(res.kind, FRAME_COMPLETE)
        assert_equal(res.end, len(raw))


def test_frame_no_length_means_until_close() raises:
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nsome body"
    )
    assert_equal(classify_response(Span(raw), "GET").kind, FRAME_UNTIL_CLOSE)


def test_head_response_parses_without_truncation_error() raises:
    # HEAD advertises its GET twin's length and sends nothing — that is not
    # truncation, and the parsed body is empty.
    var raw = _bytes(
        "HTTP/1.1 200 OK\r\ncontent-length: 39\r\n\r\n"
    )
    var resp = _parse_response(Span(raw), "HEAD")
    assert_equal(resp.status_code, 200)
    assert_equal(len(resp.body_raw), 0)


def test_204_parses_without_body() raises:
    var raw = _bytes("HTTP/1.1 204 No Content\r\n\r\n")
    var resp = _parse_response(Span(raw), "GET")
    assert_equal(resp.status_code, 204)
    assert_equal(len(resp.body_raw), 0)


def test_status_code_parses_and_rejects() raises:
    assert_equal(_status_code(Span(_bytes("HTTP/1.1 204 No Content\r\n"))), 204)
    assert_equal(_status_code(Span(_bytes("HTTP/1.1 200 OK\r\n"))), 200)
    assert_equal(_status_code(Span(_bytes("garbage-no-space-then\r\n"))), -1)
    assert_equal(_status_code(Span(_bytes("HTTP/1.1 abc\r\n"))), -1)
