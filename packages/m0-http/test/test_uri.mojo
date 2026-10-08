"""Edge cases of `URI.parse`, from the fork review's audit of what was left
of the imported parser (lane A2).

The wire reaches the parser one way: the server's address, then an
origin-form target holding a `%` or a `?` (`from_parsed` builds every other
target's URI itself, and the header parse has already reduced an
absolute-form target to its path). An application reaches it another: its
tests build requests with `URI.parse("http://127.0.0.1" + path)`, so a URL
with a scheme, an authority and anything after it. Both are held here.
`test_unquote.mojo`, `test_uri_scheme.mojo` and `test_uri_userinfo.mojo`
hold the escapes, the scheme and the userinfo.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.uri import URI


def _refused(url: String) -> Bool:
    try:
        _ = URI.parse(url)
    except:
        return True
    return False


def test_a_query_right_after_the_authority_is_the_query_of_the_root() raises:
    """RFC 3986 §3.2 ends the authority at its first `/`, `?` or `#`, and an
    empty path is `/` (RFC 9110 §4.2.3). The authority ran to the first `/`
    alone, so `http://h?q=1` was a host `h?q=1` with no query, and
    `http://h:80?q=1` lost its query to the port's digits (review record
    LF50).

    covers: A35
    """
    var uri = URI.parse("http://h?q=1&r=2")
    assert_equal(uri.host, "h")
    assert_false(uri.port)
    assert_equal(uri.path, "/")
    assert_equal(uri.request_uri, "/?q=1&r=2")
    assert_equal(uri.query_string, "q=1&r=2")
    assert_equal(uri.queries["q"], "1")
    assert_equal(uri.queries["r"], "2")
    var ported = URI.parse("http://h:80?q=1")
    assert_equal(ported.host, "h")
    assert_equal(Int(ported.port.value()), 80)
    assert_equal(ported.path, "/")
    assert_equal(ported.query_string, "q=1")
    # The paths that always worked, as controls.
    var plain = URI.parse("http://h/p?q=1")
    assert_equal(plain.host, "h")
    assert_equal(plain.path, "/p")
    assert_equal(plain.request_uri, "/p?q=1")
    assert_equal(plain.query_string, "q=1")
    var bare = URI.parse("http://h")
    assert_equal(bare.host, "h")
    assert_equal(bare.path, "/")
    assert_equal(bare.request_uri, "/")


def test_a_port_is_digits_up_to_65535() raises:
    """RFC 3986 §3.2.3: a port is `*DIGIT`, and a TCP port is at most 65535.
    The parser read the digits up to the first other byte and narrowed the
    number to 16 bits, so `:99999` was port 34463, `:65536` port 0 and
    `:8x` port 8, and it refused the empty port the RFC allows, which means
    the scheme's default (review record LF51).

    covers: A36
    """
    assert_true(_refused("http://h:99999/x"))
    assert_true(_refused("http://h:65536/x"))
    assert_true(_refused("http://h:8x/x"))
    assert_true(_refused("http://h:-1/x"))
    assert_true(_refused("http://h:+80/x"))
    assert_true(_refused("http://[::1]:8x/x"))
    assert_equal(Int(URI.parse("http://h:65535/x").port.value()), 65535)
    assert_equal(Int(URI.parse("http://h:0/x").port.value()), 0)
    assert_equal(Int(URI.parse("http://h:00080/x").port.value()), 80)
    assert_equal(Int(URI.parse("http://[::1]:8080/x").port.value()), 8080)
    var empty = URI.parse("http://h:/x")
    assert_equal(empty.host, "h")
    assert_false(empty.port)
    assert_equal(empty.path, "/x")


def test_a_hash_in_a_target_is_data() raises:
    """A request target carries no fragment (RFC 9112 §3.2), and the header
    parse accepts a `#` as any other visible byte (SPEC B19), as h11 does.
    It reaches the application where it was sent, in the path or the query,
    as uvicorn's h11 server hands it on; an inherited TODO had it cut away
    as an anchor. This is the wire's shape: the server's address, then a
    target holding a `%` or a `?`.

    covers: B19
    """
    var query = URI.parse("127.0.0.1:8080/a?x=1#frag")
    assert_equal(query.path, "/a")
    assert_equal(query.query_string, "x=1#frag")
    assert_equal(query.queries["x"], "1#frag")
    assert_equal(query.request_uri, "/a?x=1#frag")
    var path = URI.parse("127.0.0.1:8080/a%20b#frag?x=1")
    assert_equal(path.path, "/a b#frag")
    assert_equal(path.query_string, "x=1")


def test_the_query_items_edges() raises:
    """The query loop over the wire's targets: empty items, an item with no
    `=` (an empty value), one with no name (skipped), a value holding `=`,
    `+` and escapes decoded after the split, a repeated name (the last
    wins), an empty query, and a `?` inside the query.
    """
    var uri = URI.parse(
        "127.0.0.1:8080/p?&&=v&k&a=1&a=2&b=1=2&c+d=e+f&g%3Dh=i%26j"
    )
    assert_equal(uri.path, "/p")
    assert_equal(uri.queries["k"], "")
    assert_false("" in uri.queries)
    assert_equal(uri.queries["a"], "2")
    assert_equal(uri.queries["b"], "1=2")
    assert_equal(uri.queries["c d"], "e f")
    assert_equal(uri.queries["g=h"], "i&j")
    assert_equal(len(uri.queries), 5)
    var empty = URI.parse("127.0.0.1:8080/p?")
    assert_equal(empty.path, "/p")
    assert_equal(empty.query_string, "")
    assert_equal(len(empty.queries), 0)
    assert_equal(empty.request_uri, "/p?")
    var inner = URI.parse("127.0.0.1:8080/p?next=/q?r=1")
    assert_equal(inner.queries["next"], "/q?r=1")
    var root = URI.parse("127.0.0.1:8080/?x")
    assert_equal(root.path, "/")
    assert_equal(root.queries["x"], "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
