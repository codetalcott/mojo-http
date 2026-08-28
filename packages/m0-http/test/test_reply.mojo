"""The response constructors in `src/reply.mojo`.

These were lifted from three apps that each carried their own copy, so the
assertions are mostly "the wire output did not move" — status, reason phrase,
content type and body, which is what the apps' smokes check end to end.

`param_int` is the exception: it gained a length bound the hand-written
copies did not have, and the overflow test is the reason it exists.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI

from src.reply import (
    accept_header,
    body_string,
    empty,
    html,
    json,
    no_content,
    param_int,
    problem,
    redirect,
    vary_accept,
)


def _body(resp: HTTPResponse) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(resp.body_raw)))


def test_json_sets_content_type_status_and_body() raises:
    var r = json(200, String("OK"), String('{"a":1}'))
    assert_equal(r.status_code, 200)
    assert_equal(r.status_text, "OK")
    assert_equal(r.headers[HeaderKey.CONTENT_TYPE], "application/json")
    assert_equal(_body(r), '{"a":1}')


def test_json_emits_its_body_verbatim() raises:
    """It does not escape — the caller owns that, as the apps' copies did."""
    var r = json(400, String("Bad Request"), String('{"e":"a\\"b"}'))
    assert_equal(_body(r), '{"e":"a\\"b"}')


def test_html_is_200_with_a_charset() raises:
    var r = html(String("<p>hi</p>"))
    assert_equal(r.status_code, 200)
    assert_equal(r.headers[HeaderKey.CONTENT_TYPE], "text/html; charset=utf-8")
    assert_equal(_body(r), "<p>hi</p>")


def test_empty_and_no_content_carry_no_body() raises:
    var r = no_content()
    assert_equal(r.status_code, 204)
    assert_equal(r.status_text, "No Content")
    assert_equal(len(r.body_raw), 0)
    var m = empty(304, String("Not Modified"))
    assert_equal(m.status_code, 304)
    assert_equal(len(m.body_raw), 0)


def test_redirect_sets_location_and_a_real_reason_phrase() raises:
    var r = redirect(308, String("/new"))
    assert_equal(r.status_code, 308)
    assert_equal(r.status_text, "Permanent Redirect")
    assert_equal(r.headers[HeaderKey.LOCATION], "/new")
    assert_equal(len(r.body_raw), 0)
    assert_equal(redirect(301, String("/a")).status_text, "Moved Permanently")
    assert_equal(redirect(302, String("/a")).status_text, "Found")
    assert_equal(redirect(303, String("/a")).status_text, "See Other")
    assert_equal(redirect(307, String("/a")).status_text, "Temporary Redirect")


def test_problem_is_rfc9457_shaped() raises:
    var r = problem(404, String("Not Found"), String("no note"), String("/notes/1"))
    assert_equal(r.status_code, 404)
    assert_equal(r.status_text, "Not Found")
    assert_equal(
        r.headers[HeaderKey.CONTENT_TYPE], "application/problem+json"
    )
    var b = _body(r)
    assert_true('"type":"about:blank"' in b)
    assert_true('"status":404' in b)
    assert_true('"instance":"/notes/1"' in b)


def test_problem_escapes_the_text_it_is_given() raises:
    """Title and detail reach the body from user-ish input; a raw quote would break it."""
    var r = problem(400, String('a"b'), String("c\\d"), String("/x"))
    var b = _body(r)
    assert_true('\\"' in b)
    assert_false('"title":"a"b"' in b)


def test_vary_accept_marks_the_response() raises:
    var r = vary_accept(json(200, String("OK"), String("{}")))
    assert_equal(r.headers[HeaderKey.VARY], "Accept")


def test_accept_header_defaults_to_star_when_absent() raises:
    var req = HTTPRequest(URI.parse("http://127.0.0.1/x"))
    assert_equal(accept_header(req), "*/*")


def test_accept_header_returns_what_was_sent() raises:
    var req = HTTPRequest(
        URI.parse("http://127.0.0.1/x"),
        headers=Headers(Header(HeaderKey.ACCEPT, "text/html")),
    )
    assert_equal(accept_header(req), "text/html")


def test_body_string_is_empty_without_a_body() raises:
    var req = HTTPRequest(URI.parse("http://127.0.0.1/x"))
    assert_equal(body_string(req), "")


def test_body_string_reads_the_body() raises:
    var req = HTTPRequest(
        URI.parse("http://127.0.0.1/x"), body=Bytes(String('{"t":"x"}').as_bytes())
    )
    assert_equal(body_string(req), '{"t":"x"}')


def test_param_int_parses_decimals() raises:
    assert_equal(param_int(String("0")), 0)
    assert_equal(param_int(String("7")), 7)
    assert_equal(param_int(String("1234567890")), 1234567890)


def test_param_int_rejects_non_digits_and_empty() raises:
    assert_equal(param_int(String("")), -1)
    assert_equal(param_int(String("abc")), -1)
    assert_equal(param_int(String("1a")), -1)
    assert_equal(param_int(String("-1")), -1)
    assert_equal(param_int(String(" 1")), -1)


def test_param_int_refuses_to_overflow() raises:
    """The copies this replaces wrapped: 20 digits silently became another id."""
    assert_equal(param_int(String("999999999999999999")), 999999999999999999)
    assert_equal(param_int(String("9999999999999999999")), -1)
    assert_equal(param_int(String("99999999999999999999")), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
