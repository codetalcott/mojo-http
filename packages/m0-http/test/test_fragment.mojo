"""The fragment-or-page decision in `src/fragment.mojo`.

The view returns one thing; the framework reads the request header and
decides whether to wrap it. Both answers must say they vary on that header,
and saying so must not lose a `Vary` the response already carried.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.uri import URI

from src.fragment import page_or_fragment, wants_fragment
from src.reply import vary_accept


struct Shell:
    """What a document knows that a fragment does not: here, a title."""

    var title: String

    def __init__(out self, var title: String):
        self.title = title^


def wrap(shell: Shell, fragment: String) raises -> String:
    return String("<!doctype html><title>", shell.title, "</title>", fragment)


def _req(hx: String) raises -> HTTPRequest:
    if hx.byte_length() == 0:
        return HTTPRequest(URI.parse("http://127.0.0.1/notes"))
    return HTTPRequest(
        URI.parse("http://127.0.0.1/notes"),
        headers=Headers(Header("HX-Request", hx)),
    )


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


def test_wants_fragment_reads_the_header_exactly() raises:
    """htmx sends the literal `true`; anything else is not a request for
    a fragment, and absence is a direct navigation."""
    assert_true(wants_fragment(_req("true")))
    assert_false(wants_fragment(_req("")))
    assert_false(wants_fragment(_req("false")))
    assert_false(wants_fragment(_req("1")))


def test_page_or_fragment_wraps_only_without_the_header() raises:
    var frag = String('<section id="notes">x</section>')
    var bare = page_or_fragment(_req("true"), frag, Shell("t"), wrap)
    assert_equal(_body(bare), frag)
    var page = page_or_fragment(_req(""), frag, Shell("t"), wrap)
    assert_equal(_body(page), String("<!doctype html><title>t</title>", frag))
    assert_equal(page.status_code, 200)
    assert_equal(page.headers[HeaderKey.CONTENT_TYPE], "text/html; charset=utf-8")


def test_both_representations_vary_on_the_header() raises:
    var frag = String("<p>x</p>")
    assert_equal(
        page_or_fragment(_req("true"), frag, Shell("t"), wrap).headers[HeaderKey.VARY],
        "HX-Request",
    )
    assert_equal(
        page_or_fragment(_req(""), frag, Shell("t"), wrap).headers[HeaderKey.VARY],
        "HX-Request",
    )


def test_vary_on_the_header_keeps_a_vary_on_accept() raises:
    """A view that negotiated on `Accept` and then answered a fragment
    names both; the overwrite this replaced kept one."""
    var resp = vary_accept(page_or_fragment(_req("true"), String("<p>x</p>"), Shell("t"), wrap))
    assert_equal(resp.headers[HeaderKey.VARY], "HX-Request, Accept")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
