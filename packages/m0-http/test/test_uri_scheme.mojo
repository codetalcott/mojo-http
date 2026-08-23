"""Tests for what `URI.parse` treats as an absolute URI.

The fork decided "this is absolute" by searching the whole request target
for `://`, so a query parameter carrying an unencoded URL —
`/go?url=http://example.test` — was read as a URI whose scheme was
`/go?url=http`, and the request answered `400` before reaching the
application. `scheme_separator` is the rule that replaced the search: the
`://` counts only when everything before it is a scheme as RFC 3986 §3.1
defines one.

Kept apart from `test_parsing.mojo` because this is a change to the fork,
and a change there wants tests that name it.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.uri import URI, scheme_separator


def test_a_real_scheme_is_found() raises:
    assert_equal(scheme_separator("http://example.test/x"), 4)
    assert_equal(scheme_separator("https://example.test"), 5)
    assert_equal(scheme_separator("ws://a"), 2)
    # RFC 3986 allows digits, '+', '-' and '.' after the first letter.
    assert_equal(scheme_separator("a+b-c.d://host"), 7)


def test_a_url_in_a_query_is_not_a_scheme() raises:
    """The bug this exists for: `/go?url=http://x` is a path, not a URI."""
    assert_equal(scheme_separator("/go?url=http://example.test"), -1)
    assert_equal(scheme_separator("/redirect?to=https://a.test/b"), -1)
    assert_equal(scheme_separator("/a/b/c://d"), -1)
    assert_equal(scheme_separator("/x#frag://y"), -1)


def test_an_absent_or_empty_scheme_is_not_one() raises:
    assert_equal(scheme_separator("/plain/path"), -1)
    assert_equal(scheme_separator(""), -1)
    assert_equal(scheme_separator("://nohost"), -1, "an empty scheme is none")
    assert_equal(scheme_separator("1http://x"), -1, "a scheme starts with a letter")


def test_parse_keeps_a_query_carrying_a_url() raises:
    """End to end: the path and the query survive, and nothing raises."""
    var uri = URI.parse("/go?url=http://example.test/deep")
    assert_equal(uri.path, "/go")
    assert_equal(uri.query_string, "url=http://example.test/deep")
    # No scheme was named, so the parser's default stands.
    assert_equal(uri.scheme, "http")


def test_parse_still_reads_an_absolute_uri() raises:
    var uri = URI.parse("http://example.test:8080/a/b?c=1")
    assert_equal(uri.scheme, "http")
    assert_equal(uri.host, "example.test")
    assert_true(uri.port)
    assert_equal(Int(uri.port.value()), 8080)
    assert_equal(uri.path, "/a/b")
    assert_equal(uri.query_string, "c=1")


def test_parse_reads_https_absolutely() raises:
    var uri = URI.parse("https://example.test/x")
    assert_equal(uri.scheme, "https")
    assert_equal(uri.host, "example.test")
    assert_equal(uri.path, "/x")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
