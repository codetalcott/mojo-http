"""Form bodies (`src/form.mojo`): decoding, the content-type gate, and the
one property that keeps this parser and `URI.parse`'s query loop from
drifting — a table of encodings both must decode identically.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.http import HTTPRequest
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI

from src.form import Form, form, is_form, parse_form


def _req(content_type: String, body: String) raises -> HTTPRequest:
    var headers = Headers()
    if content_type.byte_length() > 0:
        headers = Headers(Header(HeaderKey.CONTENT_TYPE, content_type))
    return HTTPRequest(
        URI.parse("http://127.0.0.1/notes"),
        headers=headers^,
        method="POST",
        body=Bytes(body.as_bytes()),
    )


def test_parse_form_decodes_plus_percent_and_multibyte() raises:
    """The continuation-byte regression, on the input side this time:
    `%C3%A9` is one character and comes back as those two bytes."""
    var f = parse_form("title=Caf%C3%A9+au+lait&body=a%26b%3Dc")
    assert_equal(len(f), 2)
    assert_equal(f.first("title"), "Café au lait")
    assert_equal(f.first("body"), "a&b=c")


def test_repeated_keys_keep_every_value_in_order() raises:
    """A checkbox group repeats its name once per tick; `all` is the
    group, `first` the first tick, and the Dict-shaped query parser would
    have kept only the last."""
    var f = parse_form("tag=work&title=t&tag=home&tag=later")
    assert_equal(len(f), 4)
    var tags = f.all("tag")
    assert_equal(len(tags), 3)
    assert_equal(tags[0], "work")
    assert_equal(tags[1], "home")
    assert_equal(tags[2], "later")
    assert_equal(f.first("tag"), "work")


def test_get_tells_absent_from_empty() raises:
    var f = parse_form("empty=&novalue&x=1")
    assert_true(f.has("empty"))
    assert_true(f.has("novalue"))
    assert_false(f.has("missing"))
    assert_equal(f.get("empty").value(), "")
    assert_equal(f.get("novalue").value(), "")
    assert_false(Bool(f.get("missing")))
    assert_equal(f.first("missing"), "")
    assert_equal(len(f.all("missing")), 0)


def test_empty_names_and_empty_bodies_are_skipped() raises:
    var f = parse_form("a=1&&=nameless&b=2")
    assert_equal(len(f), 2)
    assert_equal(f.key(0), "a")
    assert_equal(f.key(1), "b")
    assert_equal(len(parse_form("")), 0)


def test_form_is_empty_unless_the_content_type_says_form() raises:
    """Form-SHAPED bytes under a JSON content type are not a form: the
    body was never meant as one, and parsing it anyway is how a JSON
    document becomes one field named after the whole document."""
    var body = String("title=looks+like+a+form")
    assert_equal(len(form(_req("application/json", body))), 0)
    assert_equal(len(form(_req("", body))), 0)
    assert_equal(len(form(_req("text/plain", body))), 0)
    assert_false(is_form(_req("application/json", body)))


def test_form_accepts_parameters_and_any_case_on_the_content_type() raises:
    var body = String("title=t")
    var f = form(_req("application/x-www-form-urlencoded; charset=UTF-8", body))
    assert_equal(f.first("title"), "t")
    f = form(_req("Application/X-WWW-Form-URLEncoded", body))
    assert_equal(f.first("title"), "t")
    assert_true(is_form(_req("application/x-www-form-urlencoded", body)))


def test_decodes_exactly_as_the_query_parser_does() raises:
    """The anti-drift device. `URI.parse` keeps its own twelve-line loop
    because it fills a last-wins `Dict`; this module keeps repeats. They
    must still decode every VALUE the same way, so one table of encodings
    goes through both, and for every key the query's value must equal the
    form's LAST value for that key (the Dict's rule), with the same set of
    distinct keys on both sides.

    covers: N6
    """
    var cases = [
        String("a=1&b=2"),
        String("t=Caf%C3%A9+au+lait"),
        String("k=%2F%3D%26%3F"),
        String("x=&y"),
        String("sp=a+b%20c"),
        String("q=1&q=2&q=3"),
        String("a=1&&b=2"),
        String("n%20ame=v%20alue"),
        String("eq=a=b=c"),
    ]
    for enc in cases:
        var uri = URI.parse(String("http://127.0.0.1/p?", enc))
        var f = parse_form(enc)
        var distinct = 0
        for i in range(len(f)):
            var k = f.key(i)
            var seen_before = False
            for j in range(i):
                if f.key(j) == k:
                    seen_before = True
            if seen_before:
                continue
            distinct += 1
            var values = f.all(k)
            assert_equal(
                uri.queries[k],
                values[len(values) - 1],
                String("case ", enc, ": query and form disagree on `", k, "`"),
            )
        assert_equal(len(uri.queries), distinct, String("case ", enc, ": key sets differ"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
