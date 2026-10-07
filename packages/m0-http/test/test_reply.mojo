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
from lightbug_http.uri import URI, unquote

from src.reply import (
    accept_header,
    body_string,
    empty,
    html,
    json,
    no_content,
    param_int,
    problem,
    reason_phrase,
    redirect,
    vary,
    vary_accept,
)


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


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
    # The status is the caller's, and so is its own phrase: a 201 with a
    # `Location` is `Created`, where the redirect's own table said `Redirect`.
    assert_equal(redirect(201, String("/a")).status_text, "Created")


def test_reason_phrase_matches_http_client_responses() raises:
    """The one table (`m0serve`'s ASGI path answers an application's integer
    status with it too): CPython 3.13's `http.client.responses`, including
    the two it renamed (413, 422) and the one everybody checks (418)."""
    assert_equal(reason_phrase(200), "OK")
    assert_equal(reason_phrase(101), "Switching Protocols")
    assert_equal(reason_phrase(304), "Not Modified")
    assert_equal(reason_phrase(404), "Not Found")
    assert_equal(reason_phrase(413), "Content Too Large")
    assert_equal(reason_phrase(418), "I'm a Teapot")
    assert_equal(reason_phrase(422), "Unprocessable Content")
    assert_equal(reason_phrase(500), "Internal Server Error")
    assert_equal(reason_phrase(511), "Network Authentication Required")


def test_reason_phrase_of_an_unknown_code_is_empty() raises:
    """`responses.get(status, '')`, which the executor shim used, gave an
    unknown code an empty phrase; the status line then carries the code
    alone, which is legal."""
    assert_equal(reason_phrase(299), "")
    assert_equal(reason_phrase(599), "")
    assert_equal(reason_phrase(0), "")
    assert_equal(reason_phrase(1000), "")


def _with_byte(before: String, byte: Int, after: String) -> String:
    """`before`, one raw byte, then `after`: a target a view built from
    request data, where `unquote` has already turned `%0D` into the byte."""
    var b = List[UInt8]()
    for c in before.as_bytes():
        b.append(c)
    b.append(UInt8(byte))
    for c in after.as_bytes():
        b.append(c)
    return String(StringSpan(unsafe_from_utf8=Span(b)))


def _escaped(byte: Int) -> String:
    comptime HEX = "0123456789ABCDEF"
    return String("%", HEX[byte=byte >> 4 : (byte >> 4) + 1], HEX[byte=byte & 15 : (byte & 15) + 1])


def test_redirect_percent_encodes_a_control_byte_in_its_target() raises:
    """A target a view built from request data -- `?next=%0D%0A...`, which
    `unquote` decodes to a real line break -- keeps its `Location`. Every
    C0 control byte and DEL is percent-encoded, as `url_for` encodes one, so
    the header survives the writer, which drops a value carrying CR, LF or
    NUL rather than let it split the response, and the browser is still
    sent where the view asked. Judged on the header and on the head's own
    bytes: one `location` line, intact, and no line the target smuggled in.

    Every other byte is left alone, so an ordinary target -- a query, an
    escape already made, a fragment, UTF-8, a request byte that is not
    UTF-8 -- is byte-identical to what it was.

    covers: G2
    """
    var split = redirect(303, String("/next\r\nSet-Cookie: s=1"))
    assert_equal(split.headers[HeaderKey.LOCATION], "/next%0D%0ASet-Cookie: s=1")
    var wire = String(unsafe_from_utf8=split^.encode())
    assert_true("\r\nlocation: /next%0D%0ASet-Cookie: s=1\r\n" in wire, wire)
    assert_false("\r\nSet-Cookie" in wire, wire)

    var controls = List[Int]()
    for byte in range(0x20):
        controls.append(byte)
    controls.append(0x7F)
    for byte in controls:
        var target = _with_byte("/a", byte, "b")
        var want = String("/a", _escaped(byte), "b")
        var r = redirect(302, target)
        assert_equal(r.headers[HeaderKey.LOCATION], want, String("byte ", byte))
        var head = String(unsafe_from_utf8=r^.encode())
        assert_true(String("\r\nlocation: ", want, "\r\n") in head, String("byte ", byte))

    # A non-UTF-8 request byte beside a control byte: a byte walk, never a
    # codepoint slice, which would trap on the 0x80 (SPEC G14).
    var mixed = redirect(303, _with_byte(_with_byte("/x", 0x80, ""), 0x0D, "y"))
    assert_equal(
        mixed.headers[HeaderKey.LOCATION], String(_with_byte("/x", 0x80, ""), "%0Dy")
    )

    var ordinary = List[String]()
    ordinary.append(String("/items"))
    ordinary.append(String("/items?page=2&q=a%20b&next=%2Fx"))
    ordinary.append(String("https://example.com/a/b?c=d#e"))
    ordinary.append(String("/café au lait"))
    ordinary.append(String("/a%0D%0Ab"))
    ordinary.append(_with_byte("/raw", 0x80, "~"))
    ordinary.append(String(""))
    for target in ordinary:
        assert_equal(redirect(301, target).headers[HeaderKey.LOCATION], target)


def test_redirect_to_an_overlong_line_break_keeps_the_head_whole() raises:
    """`?next=/%E0%80%8D%E0%80%8ASet-Cookie:...` decodes to the overlong
    forms of CR and LF, bytes above 0x7F that `redirect` leaves alone as it
    leaves UTF-8 alone. The head writer's latin-1 transcoder turned them
    into a real CRLF after the refusal had looked, so the target wrote a
    `Set-Cookie` of its own. Judged on both encoders' bytes: the `location`
    line goes out as given, and no line follows it that the view did not
    write.

    covers: G19
    """
    var target = unquote(String("/%E0%80%8D%E0%80%8ASet-Cookie:%20sid%3Dx"))
    var want = _with_byte(_with_byte(_with_byte("/", 0xE0, ""), 0x80, ""), 0x8D, "")
    want = _with_byte(_with_byte(_with_byte(want, 0xE0, ""), 0x80, ""), 0x8A, "Set-Cookie: sid=x")
    assert_equal(target, want)
    assert_equal(redirect(303, target).headers[HeaderKey.LOCATION], want)
    var line = String("\r\nlocation: ", want, "\r\n")
    var encoded = String(unsafe_from_utf8=redirect(303, target).encode())
    assert_true(line in encoded, encoded)
    assert_false("\r\nSet-Cookie" in encoded, encoded)
    var into = String(unsafe_from_utf8=redirect(303, target).encode_into(Bytes(capacity=256)))
    assert_true(line in into, into)
    assert_false("\r\nSet-Cookie" in into, into)


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


def test_vary_appends_rather_than_overwrites() raises:
    """One URL varying on two headers must name both. The overwrite this
    replaced kept whichever was set last, which no test noticed while
    nothing set `Vary` twice.

    covers: N4
    """
    var r = vary(vary_accept(json(200, String("OK"), String("{}"))), String("HX-Request"))
    assert_equal(r.headers[HeaderKey.VARY], "Accept, HX-Request")
    r = vary(html(String("x")), String("HX-Request"))
    assert_equal(r.headers[HeaderKey.VARY], "HX-Request")


def test_vary_does_not_repeat_a_name() raises:
    """Marked twice, or marked once each by two helpers spelling the name
    in different cases, is still one entry."""
    var r = vary_accept(vary_accept(json(200, String("OK"), String("{}"))))
    assert_equal(r.headers[HeaderKey.VARY], "Accept")
    r = vary(r^, String("accept"))
    assert_equal(r.headers[HeaderKey.VARY], "Accept")
    r = vary(vary(r^, String("HX-Request")), String("hx-request"))
    assert_equal(r.headers[HeaderKey.VARY], "Accept, HX-Request")


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


def test_vary_star_stands_alone_and_an_empty_vary_is_absent() raises:
    """RFC 9110 §12.5.5: `*` is the whole list; a sender must not emit
    `*, name`, and a cache that parsed it as a list would re-enable the
    caching the app disabled. An empty field is no field."""
    var r = json(200, String("OK"), String("{}"))
    r.headers[HeaderKey.VARY] = "*"
    r = vary(r^, String("HX-Request"))
    assert_equal(r.headers[HeaderKey.VARY], "*")
    r = vary_accept(r^)
    assert_equal(r.headers[HeaderKey.VARY], "*")
    var e = json(200, String("OK"), String("{}"))
    e.headers[HeaderKey.VARY] = ""
    e = vary(e^, String("HX-Request"))
    assert_equal(e.headers[HeaderKey.VARY], "HX-Request")
    var w = json(200, String("OK"), String("{}"))
    w.headers[HeaderKey.VARY] = "Accept , *"
    w = vary(w^, String("HX-Request"))
    assert_equal(w.headers[HeaderKey.VARY], "Accept , *")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
