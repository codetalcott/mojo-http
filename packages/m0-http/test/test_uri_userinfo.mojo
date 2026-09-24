"""Tests for where `URI.parse` looks for a userinfo's `@`.

The fork skipped a userinfo whenever an `@` appeared anywhere after the
scheme, so an unencoded one in a request's path or query was read as the end
of a userinfo and everything before it discarded: `GET /echo?x=a@b` reached
the application as `/` with an empty query, and a POST to `/save?x=a@b`
reached the root's POST handler. `@` is data in both places (RFC 3986 §3.3,
§3.4). `userinfo_separator` is the rule that replaced the search: the `@`
counts only inside the authority, which ends at the first `/`, `?` or `#`
(§3.2).

Kept apart from `test_parsing.mojo` because this is a change to the fork,
and a change there wants tests that name it -- `test_uri_scheme.mojo` is the
same bug's `://` half.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.header import parse_request_headers
from lightbug_http.http import HTTPRequest
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI, userinfo_separator


def request_from(raw: String, server_addr: String) raises -> HTTPRequest:
    """Build a request the way the server's read path does."""
    var parsed = parse_request_headers(raw.as_bytes())
    try:
        return HTTPRequest.from_parsed(server_addr, parsed^, Bytes(), 8192)
    except:
        raise Error("fixture request failed to build")


def test_an_at_in_a_request_query_keeps_the_path_and_query() raises:
    """The finding: the path and the query reach the application whole.

    `from_parsed` prefixes the server's address and parses the result, so
    both spellings of that address are held -- with a scheme and without.

    covers: A22
    """
    for addr in [String("http://localhost"), String("127.0.0.1:8973")]:
        var req = request_from(
            "GET /echo?x=a@b HTTP/1.1\r\nHost: a\r\n\r\n", addr
        )
        assert_equal(req.uri.path, "/echo")
        assert_equal(req.uri.query_string, "x=a@b")
        assert_equal(req.uri.queries["x"], "a@b")
        var post = request_from(
            "POST /save?x=a@b HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n",
            addr,
        )
        assert_equal(post.uri.path, "/save")
        assert_equal(post.uri.query_string, "x=a@b")


def test_every_raw_at_shape_the_finding_tried() raises:
    """`x=@`, `x=a:b@c`, `x=a/b@c`, an `@` in a second parameter, and a
    deeper path."""
    var cases = [
        ("/echo?x=@", "/echo", "x=@"),
        ("/echo?x=a:b@c", "/echo", "x=a:b@c"),
        ("/echo?x=a/b@c", "/echo", "x=a/b@c"),
        ("/echo?y=1&x=a@b", "/echo", "y=1&x=a@b"),
        ("/echo/deeper?x=user@example.com", "/echo/deeper", "x=user@example.com"),
    ]
    for c in cases:
        var uri = URI.parse(String("127.0.0.1:8973", c[0]))
        assert_equal(uri.path, c[1], c[0])
        assert_equal(uri.query_string, c[2], c[0])
        assert_equal(uri.host, "127.0.0.1", c[0])


def test_an_at_in_the_path_is_data() raises:
    """A path may hold `@` too (`/@alice`, `/users/@alice`). With no `%` or
    `?` a target skips the parser, so these are the ones that reach it."""
    var uri = URI.parse("127.0.0.1:8973/users/@alice?page=2")
    assert_equal(uri.path, "/users/@alice")
    assert_equal(uri.query_string, "page=2")
    var escaped = URI.parse("127.0.0.1:8973/a@b%20c")
    assert_equal(escaped.path, "/a@b c")
    assert_equal(escaped.request_uri, "/a@b%20c")


def test_a_client_url_is_dialled_at_its_own_host() raises:
    """The outbound client dials `URI.parse(url).host`, so an `@` in a
    query moved the connection to whatever followed it."""
    var uri = URI.parse("http://api.test/lookup?email=x@evil.test")
    assert_equal(uri.host, "api.test")
    assert_equal(uri.path, "/lookup")
    assert_equal(uri.query_string, "email=x@evil.test")


def test_a_userinfo_in_the_authority_is_still_skipped() raises:
    var uri = URI.parse("http://user:pw@example.test:81/p?q=a@b")
    assert_equal(uri.host, "example.test")
    assert_true(uri.port)
    assert_equal(Int(uri.port.value()), 81)
    assert_equal(uri.path, "/p")
    assert_equal(uri.query_string, "q=a@b")


def test_the_separator_is_bounded_by_the_authority() raises:
    assert_equal(userinfo_separator("/echo?x=a@b", 0), -1)
    assert_equal(userinfo_separator("127.0.0.1:8973/users/@alice", 0), -1)
    assert_equal(userinfo_separator("host?x=a@b", 0), -1, "? ends it")
    assert_equal(userinfo_separator("host#a@b", 0), -1, "# ends it")
    assert_equal(userinfo_separator("u:p@host/p", 0), 3)
    # From the authority's start: `http://` is seven bytes.
    assert_equal(userinfo_separator("http://u@h/x@y", 7), 8)
    # A userinfo cannot hold `@`, so the first one is the separator.
    assert_equal(userinfo_separator("a@b@c/", 0), 1)
    assert_equal(userinfo_separator("", 0), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
