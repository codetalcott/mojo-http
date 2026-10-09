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
from test.support import _raw


def request_from(raw: String) raises -> HTTPRequest:
    """Parse a whole request the way the server's read path does.

    `from_parsed` raises `RequestBuildError`, which the test suite's plain
    `raises` cannot carry; none of the fixtures here should ever trip it, so
    restate a failure as an ordinary error rather than widening every caller.
    """
    var parsed = parse_request_headers(raw.as_bytes())
    try:
        return HTTPRequest.from_parsed("localhost", None, parsed^, Bytes(), 8192)
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
    # An empty jar writes no field at all: `to_header` has none to give.
    assert_false(RequestCookieJar().to_header())
    var bare = HTTPRequest(uri=URI.parse("http://example.com/"))
    var bare_wire = String(unsafe_from_utf8=bare^.encode()).lower()
    assert_false("cookie:" in bare_wire, bare_wire)


def test_a_cookie_value_that_is_not_utf8_does_not_trap() raises:
    """The jar is built for every request, and `add_pairs` sliced each pair
    as a String around its `=` — a codepoint-boundary assert, so
    `Cookie: a=<0x80>` killed the process for every application. Bytes
    above 0x7F pass the header parser as obs-text, so this was one request
    away. The value is kept as its bytes; the pair beside it still parses.

    covers: G14
    """
    var jar = RequestCookieJar()
    jar.add_pairs(String("a=") + _raw(0x80) + String("; b=1"))
    assert_equal(jar["b"], "1")
    var a = jar["a"].as_bytes()
    assert_equal(len(a), 1)
    assert_equal(Int(a[0]), 0x80)
    # The name side is sliced too.
    jar.add_pairs(_raw(0x80) + String("=v"))
    assert_equal(jar[_raw(0x80)], "v")


def test_a_quoted_value_keeps_its_quotes() raises:
    """RFC 6265 §4.1.1 lets a cookie-value be wrapped in DQUOTEs, and its
    successor draft (draft-ietf-httpbis-rfc6265bis-22 §4.1.1) says the
    quotes are part of the value. An inherited TODO asked for them to be
    stripped; the jar keeps what the client sent, so a value an application
    set quoted reaches it as it set it.

    covers: G28
    """
    var jar = RequestCookieJar()
    jar.add_pairs('a="x y"; b=""; c="; d="q\\"r"')
    assert_equal(jar["a"], '"x y"')
    assert_equal(jar["b"], '""')
    assert_equal(jar["c"], '"')
    assert_equal(jar["d"], '"q\\"r"')


def test_the_pairs_edges() raises:
    """What reaches `add_pairs` from the wire is the joined `Cookie` lines:
    an empty value, separators with nothing between them, a pair with an
    empty name, whitespace beside the `=`, a repeated name.

    covers: G28
    """
    var empty = RequestCookieJar()
    empty.add_pairs("")
    empty.add_pairs("  ;; ; ")
    assert_equal(len(empty._inner), 0)
    var jar = RequestCookieJar()
    jar.add_pairs("=v; a=1;; b = 2 ; c=; =; d=4;")
    assert_false("" in jar, "a pair with no name is skipped")
    assert_equal(jar["a"], "1")
    # The name is trimmed; the value keeps what follows its `=`.
    assert_equal(jar["b"], " 2")
    assert_equal(jar["c"], "")
    assert_equal(jar["d"], "4")
    assert_equal(len(jar._inner), 4)
    # A repeated name keeps its last value, as Django's `parse_cookie`.
    var twice = RequestCookieJar()
    twice.add_pairs("s=first; s=second")
    assert_equal(twice["s"], "second")


def test_jars_holding_the_same_cookies_are_equal() raises:
    """Two jars are equal when each holds the other's names with the same
    values, whatever their number (review record LF30).

    `==` compared every cookie of one jar with every cookie of the other
    and answered False at the first pair that differed, so a jar of two or
    more cookies was unequal even to a jar parsed from the same field.

    covers: G22
    """
    var a = RequestCookieJar()
    a.add_pairs("sessionid=s1; csrftoken=t1; theme=dark")
    var b = RequestCookieJar()
    b.add_pairs("theme=dark; csrftoken=t1; sessionid=s1")
    assert_true(a == b, "two jars of the same three cookies are not equal")
    assert_true(b == a, "equality is not symmetric")

    var one = RequestCookieJar()
    one.add_pairs("sessionid=s1")
    var same = RequestCookieJar()
    same.add_pairs("sessionid=s1")
    assert_true(one == same, "two jars of the same cookie are not equal")

    var changed = RequestCookieJar()
    changed.add_pairs("sessionid=s1; csrftoken=t2; theme=dark")
    assert_false(a == changed, "a jar with one value changed is equal")
    var renamed = RequestCookieJar()
    renamed.add_pairs("sessionid=s1; csrf=t1; theme=dark")
    assert_false(a == renamed, "a jar with one name changed is equal")
    var fewer = RequestCookieJar()
    fewer.add_pairs("sessionid=s1; csrftoken=t1")
    assert_false(a == fewer, "a jar missing a cookie is equal")
    assert_true(RequestCookieJar() == RequestCookieJar(), "two empty jars are not equal")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
