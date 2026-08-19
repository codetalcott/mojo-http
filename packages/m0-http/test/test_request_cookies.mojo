"""Tests for request cookies: the jar's parsing, and the raw header's survival.

Both halves matter for different callers. A Mojo handler reads `req.cookies`;
a WSGI application never does — it is handed the raw `Cookie` field as
`HTTP_COOKIE` and parses it itself, which is what Django does. The jar losing a
value and the header being erased are therefore two separate regressions, and
the second one silently disabled every Django session, login and CSRF check.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.cookie import RequestCookieJar
from lightbug_http.header import HeaderKey, parse_request_headers
from lightbug_http.http import HTTPRequest
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI


def request_from(raw: String) raises -> HTTPRequest:
    """Parse a whole request the way the server's read path does.

    `from_parsed` raises `RequestBuildError`, which the test suite's plain
    `raises` cannot carry; none of the fixtures here should ever trip it, so
    restate a failure as an ordinary error rather than widening every caller.
    """
    var parsed = parse_request_headers(raw.as_bytes())
    try:
        return HTTPRequest.from_parsed(
            "http://localhost", parsed^, Bytes(), 8192
        )
    except:
        raise Error("fixture request failed to build")


def test_pairs_split_on_the_first_equals_only() raises:
    """A cookie-value is opaque and may contain `=`.

    Base64 pads with `=`, so a Django `sessionid` routinely ends in one.
    Splitting on every `=` truncated the value to its first segment, which
    turns a valid session into a silent logout.
    """
    var jar = RequestCookieJar()
    jar.add_pairs("sessionid=YWJjZGVm==; csrftoken=a=b=c")

    assert_equal(jar["sessionid"], "YWJjZGVm==")
    assert_equal(jar["csrftoken"], "a=b=c")


def test_pairs_split_per_cookie_not_across_the_whole_field() raises:
    """`a=1; b=2` is two cookies, not one named `a` holding `1; b`."""
    var jar = RequestCookieJar()
    jar.add_pairs("a=1; b=2")

    assert_equal(jar["a"], "1")
    assert_equal(jar["b"], "2")
    assert_true("a" in jar)
    assert_true("b" in jar)


def test_pairs_tolerate_a_bare_semicolon_separator() raises:
    """`a=1;b=2` without the space is common in the wild."""
    var jar = RequestCookieJar()
    jar.add_pairs("a=1;b=2")

    assert_equal(jar["a"], "1")
    assert_equal(jar["b"], "2")


def test_pairs_skip_entries_with_no_value() raises:
    """RFC 6265 §5.2: a pair with no `=` is ignored, not stored nameless.

    Storing them under `""` meant two such pairs clobbered each other, and the
    entry re-emitted as a bare `=` on the way out.
    """
    var jar = RequestCookieJar()
    jar.add_pairs("novalue; a=1; alsonovalue")

    assert_equal(jar["a"], "1")
    assert_false("" in jar)
    assert_equal(len(jar._inner), 1)


def test_lookup_is_case_sensitive_both_ways() raises:
    """Cookie names are case-sensitive (RFC 6265 §4.1.1).

    Lookup used to lowercase while storage did not, so a jar holding
    `sessionId` answered nothing to any spelling at all.
    """
    var jar = RequestCookieJar()
    jar.add_pairs("sessionId=abc")

    assert_equal(jar["sessionId"], "abc")
    assert_true("sessionId" in jar)
    assert_false("sessionid" in jar)


def test_parsed_request_exposes_cookies_both_ways() raises:
    """One request, two readers: the jar for handlers, the header for WSGI."""
    var req = request_from(
        String(
            "GET / HTTP/1.1\r\n",
            "Host: example.com\r\n",
            "Cookie: sessionid=abc123; csrftoken=xyz789\r\n",
            "\r\n",
        )
    )

    assert_equal(req.cookies["sessionid"], "abc123")
    assert_equal(req.cookies["csrftoken"], "xyz789")

    var raw = req.headers.get(HeaderKey.COOKIE)
    assert_true(Bool(raw))
    assert_equal(raw.value(), "sessionid=abc123; csrftoken=xyz789")


def test_reencoding_a_parsed_request_emits_one_cookie_field() raises:
    """The header and the jar both hold the cookies; the wire gets one field.

    `encode` writes `headers` and then the jar, so leaving `Cookie` in both
    without a guard would duplicate it — which a proxy re-issuing a parsed
    request would put on the wire.
    """
    var req = request_from(
        String(
            "GET / HTTP/1.1\r\n",
            "Host: example.com\r\n",
            "Cookie: a=1; b=2\r\n",
            "\r\n",
        )
    )

    var wire = String(unsafe_from_utf8=req^.encode())

    var count = 0
    var search_from = 0
    while True:
        var hit = String(wire[byte=search_from:]).lower().find("cookie:")
        if hit < 0:
            break
        count += 1
        search_from += hit + 7
    assert_equal(count, 1)
    assert_true("Cookie: a=1; b=2" in wire or "cookie: a=1; b=2" in wire)


def test_hand_built_request_still_writes_its_jar() raises:
    """The client builds a jar and no header; those cookies must still ship."""
    var jar = RequestCookieJar()
    jar.add_pairs("token=xyz")

    var req = HTTPRequest(uri=URI.parse("http://example.com/"), cookies=jar^)
    var wire = String(unsafe_from_utf8=req^.encode())

    assert_true("token=xyz" in wire)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
