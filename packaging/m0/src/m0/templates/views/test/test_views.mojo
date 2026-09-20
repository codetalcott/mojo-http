"""One real assertion per route, through the table the server serves.

`uv run m0 test` runs this in two or three seconds: no link, no socket, no
server. Put logic where a test like these can reach it.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI

from pages import render_list
from views import Items, item_urls


def _get(path: String, partial: Bool = False) raises -> HTTPRequest:
    var headers = Headers()
    if partial:
        headers = Headers(Header("HX-Request-Type", "partial"))
    return HTTPRequest(URI.parse(String("http://127.0.0.1", path)), headers=headers^)


def _send(method: String, path: String, body: String) raises -> HTTPRequest:
    return HTTPRequest(
        URI.parse(String("http://127.0.0.1", path)),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, "application/x-www-form-urlencoded"),
            Header("HX-Request-Type", "partial"),
        ),
        method=method,
        body=Bytes(body.as_bytes()),
    )


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


def test_the_list_is_a_document_or_a_bare_fragment() raises:
    var items = Items()
    var table = item_urls()
    var page = _body(table.dispatch(_get("/items"), items))
    assert_true(page.startswith("<!doctype html>"))
    var bare = _body(table.dispatch(_get("/items", partial=True), items))
    assert_true(bare.startswith('<section id="items"'))


def test_create_adds_and_answers_the_list() raises:
    var items = Items()
    var table = item_urls()
    var resp = table.dispatch(_send("POST", "/items", "title=milk"), items)
    assert_equal(resp.status_code, 200)
    assert_equal(len(items.ids), 1)
    assert_true("milk" in _body(resp))


def test_an_empty_title_is_a_422_fragment_with_an_alert() raises:
    var items = Items()
    var table = item_urls()
    var resp = table.dispatch(_send("POST", "/items", "title="), items)
    assert_equal(resp.status_code, 422)
    assert_equal(resp.status_text, "Unprocessable Content")
    assert_true('role="alert"' in _body(resp))
    assert_equal(len(items.ids), 0)


def test_detail_shows_one_item_and_a_missing_one_is_404() raises:
    var items = Items()
    items.add(String("milk"))
    var table = item_urls()
    assert_true("milk" in _body(table.dispatch(_get("/items/1"), items)))
    assert_equal(table.dispatch(_get("/items/9"), items).status_code, 404)
    assert_equal(table.dispatch(_get("/items/x"), items).status_code, 404)


def test_delete_removes_the_item() raises:
    var items = Items()
    items.add(String("milk"))
    items.add(String("eggs"))
    var table = item_urls()
    var resp = table.dispatch(_send("DELETE", "/items/1", ""), items)
    assert_equal(resp.status_code, 200)
    assert_equal(len(items.ids), 1)
    assert_false("milk" in _body(resp))
    assert_true("eggs" in _body(resp))


def test_a_title_is_escaped_where_it_is_rendered() raises:
    var html = render_list([1], [String("<b>&")], String(""))
    assert_true("&lt;b&gt;&amp;" in html)
    assert_false("<b>" in html)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
