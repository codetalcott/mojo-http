"""One real assertion per route and per refusal, through the table the
server serves.

`uv run m0 test` runs this in a few seconds: no link, no socket, no
server. A hand-built request parses no `Cookie` header -- only the
server's parser fills `req.cookies` -- so a test behind the session fills
the jar itself (`_signed_in`).
"""

from std.os import setenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.cookie import RequestCookieJar
from lightbug_http.header import HeaderKey, Headers
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI

from m0_http import CSRF_HEADER

from pages import render_list
from views import Items, SESSION_COOKIE, item_urls, login_from_env

comptime PASSWORD = "correct horse"


def _items() raises -> Items:
    _ = setenv("APP_KEY", "test-key-0123456789abcdef0123456789abcdef", True)
    _ = setenv("APP_PASSWORD", PASSWORD, True)
    _ = setenv("APP_SECURE", "0", True)
    return Items(login_from_env())


def _req(
    method: String,
    path: String,
    cookie: String = "",
    body: String = "",
    token: String = "",
    partial: Bool = True,
) raises -> HTTPRequest:
    var headers = Headers()
    if partial:
        headers["HX-Request-Type"] = "partial"
    if body.byte_length() > 0:
        headers[HeaderKey.CONTENT_TYPE] = "application/x-www-form-urlencoded"
    if token.byte_length() > 0:
        headers[CSRF_HEADER] = token
    var jar = RequestCookieJar()
    if cookie.byte_length() > 0:
        jar.add_pairs(cookie)
    return HTTPRequest(
        URI.parse(String("http://127.0.0.1", path)),
        headers=headers^,
        cookies=jar^,
        method=method,
        body=Bytes(body.as_bytes()),
    )


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


def _header(resp: HTTPResponse, name: String) -> String:
    var v = resp.headers.get(name)
    if not v:
        return String("")
    return v.value()


def _signed_in(mut items: Items) raises -> Tuple[String, String]:
    """Sign in through the table: the `name=value` pair the browser would
    send back, and the session's CSRF token."""
    var table = item_urls()
    var resp = table.dispatch(
        _req("POST", "/login", body=String("user=admin&password=", "correct+horse"),
             partial=False),
        items,
    )
    assert_equal(resp.status_code, 303)
    var line = resp.cookies.raw[0]
    var pair = String(unsafe_from_utf8=line.as_bytes()[: line.find(";")])
    var session = items.login.session_of(_req("GET", "/items", cookie=pair))
    assert_true(session.ok, session.reason)
    return (pair, session.csrf)


def test_signed_out_a_navigation_goes_to_login_and_a_swap_gets_the_form() raises:
    var items = _items()
    var table = item_urls()
    var nav = table.dispatch(_req("GET", "/items", partial=False), items)
    assert_equal(nav.status_code, 303)
    assert_equal(_header(nav, "Location"), "/login")
    var swap = table.dispatch(_req("GET", "/items"), items)
    assert_equal(swap.status_code, 401)
    assert_true('action="/login"' in _body(swap))
    assert_equal(_header(swap, "Cache-Control"), "no-store")


def test_the_wrong_password_is_the_form_again_with_no_cookie() raises:
    var items = _items()
    var table = item_urls()
    var resp = table.dispatch(
        _req("POST", "/login", body="user=admin&password=wrong", partial=False), items
    )
    assert_equal(resp.status_code, 401)
    assert_true('role="alert"' in _body(resp))
    assert_equal(len(resp.cookies.raw), 0)


def test_signing_in_sets_the_cookie_and_goes_to_the_list() raises:
    var items = _items()
    var table = item_urls()
    var resp = table.dispatch(
        _req("POST", "/login", body="user=admin&password=correct+horse", partial=False),
        items,
    )
    assert_equal(resp.status_code, 303)
    assert_equal(_header(resp, "Location"), "/items")
    assert_true(resp.cookies.raw[0].startswith(String(SESSION_COOKIE, "=v1.")))
    assert_true("HttpOnly; SameSite=Lax" in resp.cookies.raw[0])


def test_the_list_carries_the_token_on_every_write() raises:
    var items = _items()
    items.add(String("milk"))
    var s = _signed_in(items)
    var body = _body(item_urls().dispatch(_req("GET", "/items", cookie=s[0]), items))
    var field = String('name="csrf" value="', s[1], '"')
    assert_true(field in body)
    assert_true(String("&quot;X-CSRF-Token&quot;:&quot;", s[1], "&quot;") in body)
    assert_true('action="/logout"' in body)


def test_a_write_without_the_token_is_refused() raises:
    var items = _items()
    var s = _signed_in(items)
    var table = item_urls()
    var refused = table.dispatch(_req("POST", "/items", cookie=s[0], body="title=milk"), items)
    assert_equal(refused.status_code, 403)
    assert_equal(len(items.ids), 0)
    var resp = table.dispatch(
        _req("POST", "/items", cookie=s[0], body=String("title=milk&csrf=", s[1])), items
    )
    assert_equal(resp.status_code, 200)
    assert_equal(len(items.ids), 1)
    assert_true("milk" in _body(resp))


def test_an_empty_title_is_a_422_fragment_with_an_alert() raises:
    var items = _items()
    var s = _signed_in(items)
    var resp = item_urls().dispatch(
        _req("POST", "/items", cookie=s[0], body=String("title=&csrf=", s[1])), items
    )
    assert_equal(resp.status_code, 422)
    assert_true('role="alert"' in _body(resp))
    assert_equal(len(items.ids), 0)


def test_detail_shows_one_item_and_a_missing_one_is_404() raises:
    var items = _items()
    items.add(String("milk"))
    var s = _signed_in(items)
    var table = item_urls()
    assert_true("milk" in _body(table.dispatch(_req("GET", "/items/1", cookie=s[0]), items)))
    assert_equal(table.dispatch(_req("GET", "/items/9", cookie=s[0]), items).status_code, 404)


def test_delete_takes_its_token_from_the_header_and_never_the_query() raises:
    var items = _items()
    items.add(String("milk"))
    var s = _signed_in(items)
    var table = item_urls()
    var in_url = table.dispatch(
        _req("DELETE", String("/items/1?csrf=", s[1]), cookie=s[0]), items
    )
    assert_equal(in_url.status_code, 403)
    assert_equal(len(items.ids), 1)
    var resp = table.dispatch(_req("DELETE", "/items/1", cookie=s[0], token=s[1]), items)
    assert_equal(resp.status_code, 200)
    assert_equal(len(items.ids), 0)


def test_signing_out_expires_the_cookie() raises:
    var items = _items()
    var s = _signed_in(items)
    var resp = item_urls().dispatch(
        _req("POST", "/logout", cookie=s[0], body=String("csrf=", s[1]), partial=False), items
    )
    assert_equal(resp.status_code, 303)
    assert_equal(_header(resp, "Location"), "/login")
    assert_true(resp.cookies.raw[0].endswith("Max-Age=0"))


def test_a_title_is_escaped_where_it_is_rendered() raises:
    var html = render_list([1], [String("<b>&")], String("admin"), String("tok"), String(""))
    assert_true("&lt;b&gt;&amp;" in html)
    assert_false("<b>" in html)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
