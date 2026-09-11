"""`unquote`, the percent-decoder every request target and form body goes through.

Two things are pinned. The decoding rules, which were previously asserted
only through `URI.parse` — `+` expands only when asked, a truncated or
malformed escape is kept verbatim, a disallowed byte stays `%XX` in
uppercase, multi-byte escapes decode to their bytes. And the one that made
this file exist: **bytes that are not UTF-8 must not trap the process.**
`unquote` used to slice its input with `String[byte=a:b]`, which asserts a
codepoint boundary, so a request whose target held a lone continuation
byte next to a percent-escape killed the worker on the loop thread —
every app, the production WSGI deployment included, from one `GET`. A
trap ends the test process rather than failing a test, so the gate here
is the file passing at all; reverting `unquote` to the String-slicing
body makes `poe test-http` die on this file.
"""

from std.testing import TestSuite, assert_equal, assert_true

from lightbug_http.uri import URI, unquote


def _raw(*bytes: Int) -> String:
    """A String holding exactly these bytes, valid UTF-8 or not."""
    var l = List[UInt8]()
    for b in bytes:
        l.append(UInt8(b))
    return String(unsafe_from_utf8=Span(l))


def _assert_bytes(got: String, *want: Int) raises:
    var b = got.as_bytes()
    assert_equal(len(b), len(want), "byte length")
    for i in range(len(want)):
        assert_equal(Int(b[i]), want[i], String("byte ", i))


def test_percent_escapes_decode_and_plain_text_passes() raises:
    assert_equal(unquote("a%20b"), "a b")
    assert_equal(unquote("%41%42%43"), "ABC")
    assert_equal(unquote("no escapes here"), "no escapes here")
    assert_equal(unquote(""), "")
    assert_equal(unquote("%2f"), "/")


def test_plus_expands_only_when_asked_and_never_from_an_escape() raises:
    assert_equal(unquote("a+b"), "a+b")
    assert_equal(unquote[expand_plus=True]("a+b"), "a b")
    # An encoded plus is a plus: the escape is decoded, not then expanded.
    assert_equal(unquote[expand_plus=True]("a%2Bb"), "a+b")


def test_truncated_or_malformed_escapes_are_kept_verbatim() raises:
    assert_equal(unquote("%4"), "%4")
    assert_equal(unquote("100%"), "100%")
    assert_equal(unquote("%zz"), "%zz")
    assert_equal(unquote("%4%41"), "%4A")
    assert_equal(unquote("%%41"), "%A")
    # Not hex digits, whatever `atol` would have accepted.
    assert_equal(unquote("%+1"), "%+1")
    assert_equal(unquote("% 1"), "% 1")


def test_a_disallowed_byte_stays_escaped_in_uppercase() raises:
    assert_equal(unquote("a%2fb", disallowed_escapes=["/"]), "a%2Fb")
    assert_equal(unquote("a%2Fb%2fc", disallowed_escapes=["/"]), "a%2Fb%2Fc")
    assert_equal(unquote("a%2fb"), "a/b")
    assert_equal(unquote("%41%2F%42", disallowed_escapes=["/"]), "A%2FB")


def test_multibyte_escapes_decode_to_their_bytes() raises:
    assert_equal(unquote("Caf%C3%A9"), "Café")
    assert_equal(unquote[expand_plus=True]("Caf%C3%A9+au+lait"), "Café au lait")


def test_invalid_utf8_beside_an_escape_does_not_trap() raises:
    """The remote crash. A lone continuation byte (0x80) next to a
    percent-escape reached `String[byte=a:b]` inside `unquote`, which
    asserts a codepoint boundary and traps the process. The decoder is a
    byte operation and must treat every input byte as a byte.

    covers: G14
    """
    # raw 0x80 then %41
    _assert_bytes(unquote(_raw(0x80, 0x25, 0x34, 0x31)), 0x80, 0x41)
    # %41 then raw 0x80
    _assert_bytes(unquote(_raw(0x25, 0x34, 0x31, 0x80)), 0x41, 0x80)
    # a raw 0xFF between literal text and an escape, plus expanded
    _assert_bytes(
        unquote[expand_plus=True](_raw(0x61, 0xFF, 0x2B, 0x25, 0x32, 0x30, 0x62)),
        0x61, 0xFF, 0x20, 0x20, 0x62,
    )
    # invalid bytes and no escape at all
    _assert_bytes(unquote(_raw(0x80, 0x80)), 0x80, 0x80)
    # a truncated escape after an invalid byte
    _assert_bytes(unquote(_raw(0xC3, 0x25, 0x34)), 0xC3, 0x25, 0x34)


def test_uri_parse_survives_invalid_utf8_in_path_and_query() raises:
    """The same bytes where they actually arrive: a request target. Both
    the path and the query go through `unquote` during parsing, on the
    loop thread, before any handler."""
    var target = String("http://127.0.0.1/a") + _raw(0x80) + String("%41b?x=") + _raw(0x80) + String("%41&y=1")
    var uri = URI.parse(target)
    _assert_bytes(uri.path, 0x2F, 0x61, 0x80, 0x41, 0x62)
    _assert_bytes(uri.queries["x"], 0x80, 0x41)
    assert_equal(uri.queries["y"], "1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
