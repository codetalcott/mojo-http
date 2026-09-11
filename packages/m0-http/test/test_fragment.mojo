"""The fragment-or-page decision in `src/fragment.mojo`.

The view returns one thing; the framework reads four request headers and
decides whether to wrap it: htmx asks for a fragment with `HX-Request`
unless it is restoring history or boosting a navigation, Datastar asks
with `Datastar-Request`.
Both answers must say they vary on every header read, and saying so must
not lose a `Vary` the response already carried.
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


def _req_with(name: String, value: String, hx: String = "") raises -> HTTPRequest:
    """A request carrying `name: value`, and `HX-Request: hx` when given."""
    if hx.byte_length() == 0:
        return HTTPRequest(
            URI.parse("http://127.0.0.1/notes"),
            headers=Headers(Header(name, value)),
        )
    return HTTPRequest(
        URI.parse("http://127.0.0.1/notes"),
        headers=Headers(Header("HX-Request", hx), Header(name, value)),
    )


comptime ALL_VARY = "HX-Request, HX-History-Restore-Request, HX-Boosted, Datastar-Request"
"""Every header the decision reads, in the order `Vary` names them."""


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


def test_wants_fragment_reads_the_header_exactly() raises:
    """The literal `true` is what htmx sends; anything else is not a request
    for a fragment, and absence is a direct navigation."""
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


def test_both_representations_vary_on_every_header_read() raises:
    """A cache must key on all three: two requests that differ only in the
    history-restore marker get different representations, and so do two
    that differ only in Datastar's header."""
    var frag = String("<p>x</p>")
    assert_equal(
        page_or_fragment(_req("true"), frag, Shell("t"), wrap).headers[HeaderKey.VARY],
        ALL_VARY,
    )
    assert_equal(
        page_or_fragment(_req(""), frag, Shell("t"), wrap).headers[HeaderKey.VARY],
        ALL_VARY,
    )


def test_vary_on_the_header_keeps_a_vary_on_accept() raises:
    """A view that negotiated on `Accept` and then answered a fragment
    names both; the overwrite this replaced kept one."""
    var resp = vary_accept(page_or_fragment(_req("true"), String("<p>x</p>"), Shell("t"), wrap))
    assert_equal(resp.headers[HeaderKey.VARY], String(ALL_VARY, ", Accept"))


def test_a_styled_error_page_keeps_its_status() raises:
    """A 404 an app renders through `page_or_fragment` is a 404 in both
    representations, not a soft 200 crawlers index and htmx swaps in as
    success."""
    var frag = String("<h1>no such page</h1>")
    var page = page_or_fragment(_req(""), frag, Shell("404"), wrap, status=404, text="Not Found")
    assert_equal(page.status_code, 404)
    assert_equal(page.status_text, "Not Found")
    assert_equal(page.headers[HeaderKey.VARY], ALL_VARY)
    var bare = page_or_fragment(_req("true"), frag, Shell("404"), wrap, status=404, text="Not Found")
    assert_equal(bare.status_code, 404)
    assert_equal(_body(bare), frag)


def test_the_header_is_compared_ignoring_case() raises:
    assert_true(wants_fragment(_req("True")))
    assert_true(wants_fragment(_req("TRUE")))


def test_a_history_restore_is_a_page() raises:
    """The htmx 2.0.4 `loadHistoryFromServer` sends `HX-Request: true` AND
    `HX-History-Restore-Request: true`, then swaps the response's body
    into the page it is rebuilding. The first header alone says fragment;
    the second wins, because a bare fragment there is a page with no head.

    covers: N8
    """
    var frag = String('<section id="notes">x</section>')
    var restore = _req_with("HX-History-Restore-Request", "true", hx="true")
    assert_false(wants_fragment(restore))
    var page = page_or_fragment(restore, frag, Shell("t"), wrap)
    assert_equal(_body(page), String("<!doctype html><title>t</title>", frag))
    assert_equal(page.headers[HeaderKey.VARY], ALL_VARY)
    # The marker without `HX-Request` is not something htmx sends; it is a
    # page too, since nothing asked for a fragment.
    assert_false(wants_fragment(_req_with("HX-History-Restore-Request", "true")))
    # And a value that is not `true` does not cancel the fragment.
    assert_true(wants_fragment(_req_with("HX-History-Restore-Request", "false", hx="true")))


def test_a_datastar_action_gets_the_bare_fragment() raises:
    """Datastar's `@get`/`@post` send `Datastar-Request: true` and accept a
    `text/html` answer, morphing it into the element whose id it carries.
    The same view, the same renderer, the other library's header.

    covers: N7
    """
    var frag = String('<section id="notes">x</section>')
    var ds = _req_with("Datastar-Request", "true")
    assert_true(wants_fragment(ds))
    var bare = page_or_fragment(ds, frag, Shell("t"), wrap)
    assert_equal(_body(bare), frag)
    assert_equal(bare.headers[HeaderKey.CONTENT_TYPE], "text/html; charset=utf-8")
    assert_equal(bare.headers[HeaderKey.VARY], ALL_VARY)
    assert_false(wants_fragment(_req_with("Datastar-Request", "false")))
    assert_true(wants_fragment(_req_with("Datastar-Request", "TRUE")))


def test_a_boosted_request_is_a_page() raises:
    """`hx-boost` sends `HX-Request: true` beside `HX-Boosted: true`,
    targets the body with `innerHTML` and takes a full document's body.
    A bare fragment there replaces the whole page with one section — the
    history-restore failure in a different coat, and the same answer.

    covers: N8
    """
    var frag = String('<section id="notes">x</section>')
    var boosted = _req_with("HX-Boosted", "true", hx="true")
    assert_false(wants_fragment(boosted))
    var page = page_or_fragment(boosted, frag, Shell("t"), wrap)
    assert_equal(_body(page), String("<!doctype html><title>t</title>", frag))
    assert_equal(page.headers[HeaderKey.VARY], ALL_VARY)
    assert_true(wants_fragment(_req_with("HX-Boosted", "false", hx="true")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
