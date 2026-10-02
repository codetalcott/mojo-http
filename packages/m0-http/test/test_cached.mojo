"""`Cached` and `conditional`: a rendering kept until a clock moves, and
the 304 a client that holds the bytes is answered with.

SPEC N47 is this file's row.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.uri import URI

from src import reply
from src.cached import Cached, conditional
from src.etag import compute_etag
from src.fragment import PageShell, page_or_fragment
from src.login import no_store


def _req(method: String, path: String) raises -> HTTPRequest:
    var r = HTTPRequest(URI.parse(String("http://127.0.0.1", path)))
    r.method = method
    return r^


def _asking(method: String, tag: String) raises -> HTTPRequest:
    var r = _req(method, "/notes")
    r.headers[HeaderKey.IF_NONE_MATCH] = tag
    return r^


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=resp.body_raw))


def _tag_of(body: String) -> String:
    var b = List[UInt8]()
    for byte in body.as_bytes():
        b.append(byte)
    return compute_etag(b)


struct Shell(PageShell):
    var title: String

    def __init__(out self, var title: String):
        self.title = title^

    def wrap(self, fragment: String) raises -> String:
        return String("<title>", self.title, "</title>", fragment)


def test_a_rendering_is_current_until_the_clock_moves() raises:
    """A cache is empty until filled, current at the clock it was filled
    at, and stale at any other value, an earlier one included.

    covers: N47
    """
    var c = Cached()
    assert_false(c.current(0))
    assert_false(c.current(7))
    assert_true(c.fill(7, String("<ul></ul>")))
    assert_true(c.current(7))
    assert_false(c.current(8))
    assert_false(c.current(6))
    assert_equal(c.body, "<ul></ul>")
    assert_equal(c.fills, 1)


def test_fill_says_whether_the_bytes_changed_not_the_clock() raises:
    """A clock moves for a commit to any table; the rendering of a table
    that did not change is the same bytes, and `fill` says so."""
    var c = Cached()
    assert_true(c.fill(1, String("<li>a</li>")))
    assert_false(c.fill(2, String("<li>a</li>")))
    assert_true(c.current(2))
    assert_true(c.fill(3, String("<li>b</li>")))
    # Same length, different bytes: a size-and-time validator's blind spot.
    assert_true(c.fill(4, String("<li>c</li>")))
    assert_equal(c.fills, 4)


def test_an_empty_rendering_is_a_rendering() raises:
    var c = Cached()
    assert_true(c.fill(1, String("")))
    assert_true(c.current(1))
    assert_false(c.fill(2, String("")))


def test_a_first_get_carries_the_tag_and_a_policy() raises:
    var resp = conditional(_req("GET", "/notes"), reply.html("<p>a</p>"))
    assert_equal(resp.status_code, 200)
    assert_equal(_body(resp), "<p>a</p>")
    assert_equal(resp.headers[HeaderKey.ETAG], _tag_of("<p>a</p>"))
    assert_equal(resp.headers[HeaderKey.CACHE_CONTROL], "no-cache")


def test_a_get_naming_the_tag_is_304_with_no_content() raises:
    var tag = _tag_of("<p>a</p>")
    var resp = conditional(_asking("GET", tag), reply.html("<p>a</p>"))
    assert_equal(resp.status_code, 304)
    assert_equal(resp.status_text, "Not Modified")
    assert_equal(len(resp.body_raw), 0)
    assert_equal(resp.headers[HeaderKey.ETAG], tag)
    assert_equal(resp.headers[HeaderKey.CACHE_CONTROL], "no-cache")
    assert_false(HeaderKey.CONTENT_TYPE in resp.headers)
    # Weak comparison: the same opaque tag without its `W/` is the tag.
    var strong = String(unsafe_from_utf8=tag.as_bytes()[2:])
    assert_equal(conditional(_asking("GET", strong), reply.html("<p>a</p>")).status_code, 304)
    assert_equal(conditional(_asking("GET", String(" ", tag, " ")), reply.html("<p>a</p>")).status_code, 304)
    assert_equal(
        conditional(_asking("GET", 'W/"0000000000000000"'), reply.html("<p>a</p>")).status_code, 200
    )
    # A list of tags, and the wildcard.
    var listed = conditional(
        _asking("GET", String('W/"0000000000000000", ', tag)), reply.html("<p>a</p>")
    )
    assert_equal(listed.status_code, 304)
    assert_equal(conditional(_asking("HEAD", "*"), reply.html("<p>a</p>")).status_code, 304)


def test_a_stale_tag_gets_the_new_bytes_and_the_new_tag() raises:
    var old = _tag_of("<p>a</p>")
    var resp = conditional(_asking("GET", old), reply.html("<p>b</p>"))
    assert_equal(resp.status_code, 200)
    assert_equal(_body(resp), "<p>b</p>")
    assert_equal(resp.headers[HeaderKey.ETAG], _tag_of("<p>b</p>"))


def test_the_304_keeps_vary_and_the_cookies() raises:
    """What a cache needs to file the 304 under the right representation,
    and a cookie the 200 would have set."""
    var req = _req("GET", "/notes")
    var first = conditional(req, page_or_fragment(req, String("<p>a</p>"), Shell("t")))
    var tag = first.headers[HeaderKey.ETAG]
    var again = _asking("GET", tag)
    var page = page_or_fragment(again, String("<p>a</p>"), Shell("t"))
    page.cookies.add_raw(String("seen=1; Path=/"))
    var resp = conditional(again, page^)
    assert_equal(resp.status_code, 304)
    assert_equal(resp.headers[HeaderKey.VARY], first.headers[HeaderKey.VARY])
    assert_equal(len(resp.cookies.raw), 1)


def test_the_page_and_the_fragment_of_one_rendering_have_two_tags() raises:
    """One URL, two representations: the tag is over the bytes sent, so
    the fragment's tag never validates the page."""
    var plain = _req("GET", "/notes")
    var page = conditional(plain, page_or_fragment(plain, String("<p>a</p>"), Shell("t")))
    var swap = _req("GET", "/notes")
    swap.headers["hx-request-type"] = "partial"
    var frag = conditional(swap, page_or_fragment(swap, String("<p>a</p>"), Shell("t")))
    assert_true(page.headers[HeaderKey.ETAG] != frag.headers[HeaderKey.ETAG])
    # And a shell that changed under the same rows is a new page.
    var retitled = conditional(
        _asking("GET", page.headers[HeaderKey.ETAG]),
        page_or_fragment(plain, String("<p>a</p>"), Shell("u")),
    )
    assert_equal(retitled.status_code, 200)


def test_only_a_200_to_a_get_or_a_head_is_touched() raises:
    var tag = _tag_of("<p>a</p>")
    var post = conditional(_asking("POST", tag), reply.html("<p>a</p>"))
    assert_equal(post.status_code, 200)
    assert_false(HeaderKey.ETAG in post.headers)
    var missing = reply.html("<p>a</p>")
    missing.status_code = 404
    var resp = conditional(_asking("GET", tag), missing^)
    assert_equal(resp.status_code, 404)
    assert_false(HeaderKey.ETAG in resp.headers)
    var moved = conditional(_asking("GET", "*"), reply.redirect(303, "/notes"))
    assert_equal(moved.status_code, 303)


def test_a_policy_the_application_set_is_kept() raises:
    var resp = conditional(_req("GET", "/notes"), no_store(reply.html("<p>a</p>")))
    assert_equal(resp.headers[HeaderKey.CACHE_CONTROL], "no-store")
    var private = reply.html("<p>a</p>")
    private.headers[HeaderKey.CACHE_CONTROL] = "private, no-cache"
    var kept = conditional(_asking("GET", _tag_of("<p>a</p>")), private^)
    assert_equal(kept.status_code, 304)
    assert_equal(kept.headers[HeaderKey.CACHE_CONTROL], "private, no-cache")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
