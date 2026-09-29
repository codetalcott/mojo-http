"""Tests for the JSON field extraction parser."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.json_parse import (
    _scan_json_number,
    has_json_field,
    parse_json_bool,
    parse_json_field,
    parse_json_int,
    parse_json_number,
    parse_json_string,
)


def test_parse_simple_field() raises:
    """Should extract a simple string value."""
    var result = parse_json_field('{"name":"Alice"}', "name")
    assert_equal(result, "Alice")


def test_parse_with_whitespace() raises:
    """Should handle whitespace around colon and value."""
    var result = parse_json_field('{"name" : "Alice"}', "name")
    assert_equal(result, "Alice")


def test_parse_missing_field() raises:
    """Should return empty string for missing field."""
    var result = parse_json_field('{"name":"Alice"}', "age")
    assert_equal(result, "")


def test_parse_escaped_quotes() raises:
    """Should handle escaped quotes in values."""
    var result = parse_json_field('{"msg":"he said \\"hi\\""}', "msg")
    assert_equal(result, 'he said "hi"')


def test_parse_escaped_backslash() raises:
    """Should handle escaped backslashes in values."""
    var result = parse_json_field('{"path":"c:\\\\dir\\\\file"}', "path")
    assert_equal(result, "c:\\dir\\file")


def test_parse_escaped_newline() raises:
    """Should handle escaped newlines in values."""
    var result = parse_json_field('{"text":"line1\\nline2"}', "text")
    assert_equal(result, "line1\nline2")


def test_parse_escaped_backspace_formfeed() raises:
    """\\b and \\f should decode to 0x08 and 0x0C."""
    var b = parse_json_field('{"x":"\\b"}', "x")
    assert_equal(b.byte_length(), 1)
    assert_equal(Int(b.as_bytes()[0]), 0x08)
    var f = parse_json_field('{"x":"\\f"}', "x")
    assert_equal(f.byte_length(), 1)
    assert_equal(Int(f.as_bytes()[0]), 0x0C)


def test_parse_escaped_unicode_bmp() raises:
    """\\uXXXX for a BMP code point should decode as UTF-8."""
    var result = parse_json_field('{"x":"caf\\u00e9"}', "x")
    assert_equal(result, "café")


def test_parse_escaped_unicode_surrogate_pair() raises:
    """\\uD83D\\uDE00 should decode to U+1F600 (😀) as 4-byte UTF-8."""
    var result = parse_json_field('{"x":"\\uD83D\\uDE00"}', "x")
    assert_equal(result, "😀")


def test_parse_unknown_escape_rejected() raises:
    """Unknown escape sequences return the empty string (strict)."""
    var result = parse_json_field('{"x":"\\q"}', "x")
    assert_equal(result, "")


def test_parse_lone_surrogate_rejected() raises:
    """A lone low surrogate (no preceding high) returns the empty string."""
    var result = parse_json_field('{"x":"\\uDC00"}', "x")
    assert_equal(result, "")


def test_parse_field_name_substring_collision() raises:
    """Field-name-like substrings inside values must not match (structural scan)."""
    var body = '{"other":"name","name":"Alice"}'
    assert_equal(parse_json_field(body, "name"), "Alice")
    # And the inverse: searching for a field that only appears inside a value
    var body2 = '{"note":"please check status"}'
    assert_equal(parse_json_field(body2, "status"), "")


def test_parse_nested_object_not_searched() raises:
    """Top-level scan does not descend into nested objects."""
    var body = '{"outer":{"x":"inner"},"x":"top"}'
    assert_equal(parse_json_field(body, "x"), "top")


def test_parse_multiple_fields() raises:
    """Should extract the correct field from an object with multiple keys."""
    var body = '{"title":"Fix bug","priority":"high","status":"open"}'
    assert_equal(parse_json_field(body, "title"), "Fix bug")
    assert_equal(parse_json_field(body, "priority"), "high")
    assert_equal(parse_json_field(body, "status"), "open")


def test_parse_empty_value() raises:
    """Should handle empty string values."""
    var result = parse_json_field('{"name":""}', "name")
    assert_equal(result, "")


def test_parse_empty_body() raises:
    """Should return empty string for empty body."""
    var result = parse_json_field("", "name")
    assert_equal(result, "")


# --- Integer extraction ---

def test_parse_int_simple() raises:
    """Should extract an integer value."""
    var r = parse_json_int('{"count":42}', "count")
    assert_true(Bool(r))
    assert_equal(r.value(), 42)


def test_parse_int_negative() raises:
    """Should extract a negative integer value."""
    var r = parse_json_int('{"offset":-5}', "offset")
    assert_true(Bool(r))
    assert_equal(r.value(), -5)


def test_parse_int_negative_one_valid() raises:
    """The value -1 must be distinguishable from 'not found' (regression for Optional switch)."""
    var r = parse_json_int('{"x":-1}', "x")
    assert_true(Bool(r))
    assert_equal(r.value(), -1)


def test_parse_int_missing() raises:
    """Should return None for missing field."""
    var r = parse_json_int('{"count":42}', "total")
    assert_false(Bool(r))


def test_parse_int_not_numeric() raises:
    """Should return None for non-numeric value."""
    var r = parse_json_int('{"name":"Alice"}', "name")
    assert_false(Bool(r))


def test_parse_int_refuses_a_fraction_or_an_exponent() raises:
    """A number not written as an integer is refused, not cut to its digits.

    The digits were read up to the first byte that was not one and
    returned, so `1.9` read as 1 and `1e3`, a thousand, read as 1, where
    the contract is None for a value that is not a valid integer: a caller
    cannot tell a truncated 1 from a real one. The value must end where
    its digits end, at whitespace, `,`, `}`, `]` or the end of the body,
    which is where `_skip_value` ends a number too.
    """
    var refused = [
        String('{"n":1.9}'),
        String('{"n":1e3}'),
        String('{"n":1E3}'),
        String('{"n":1e+3}'),
        String('{"n":3e-1}'),
        String('{"n":-2.5}'),
        String('{"n":1.0}'),
        String('{"n":7.}'),
        String('{"n":12abc}'),
        String('{"n":1-2}'),
    ]
    for body in refused:
        var r = parse_json_int(body, "n")
        assert_false(Bool(r), String("parse_json_int read ", body, " as an integer"))
    # The control: an integer ends at every terminator a number may have.
    var kept = [
        (String('{"n":12}'), 12),
        (String('{"n":12 }'), 12),
        (String('{"n":12,"m":1.5}'), 12),
        (String('{"n":-7\n}'), -7),
        (String('{"n":0\t,"m":1}'), 0),
        (String('{"a":[1],"n":5]'), 5),
        (String('{"n":34'), 34),
    ]
    for pair in kept:
        var r = parse_json_int(pair[0], "n")
        assert_true(Bool(r), String("parse_json_int refused ", pair[0]))
        assert_equal(r.value(), pair[1])
    # The field's own fraction is refused; a neighbour's does not matter.
    assert_equal(parse_json_int('{"m":1.5,"n":9}', "n").value(), 9)


def test_parse_int_refuses_a_leading_zero() raises:
    """A zero before other digits is refused, as JSON's grammar refuses it.

    RFC 8259 section 6: an integer part is `0` alone, or a digit 1-9 and
    the digits after it, so `01` is not a JSON number at all -- every
    browser's `JSON.parse` and Python's `json` refuse it. It was read as
    1, and `-007` as -7. Zero itself and a negative zero are integers.
    """
    var refused = [
        String('{"n":01}'),
        String('{"n":00}'),
        String('{"n":-01}'),
        String('{"n":-007}'),
        String('{"n":0123,"m":1}'),
    ]
    for body in refused:
        var r = parse_json_int(body, "n")
        assert_false(Bool(r), String("parse_json_int read ", body, " as an integer"))
    var kept = [
        (String('{"n":0}'), 0),
        (String('{"n":-0}'), 0),
        (String('{"n":10}'), 10),
        (String('{"n":100 }'), 100),
        (String('{"n":-205,"m":1}'), -205),
    ]
    for pair in kept:
        var r = parse_json_int(pair[0], "n")
        assert_true(Bool(r), String("parse_json_int refused ", pair[0]))
        assert_equal(r.value(), pair[1])


# --- Number extraction ---

def test_parse_number_integer() raises:
    """Should extract an integer as Float64."""
    var r = parse_json_number('{"price":100}', "price")
    assert_true(Bool(r))
    assert_true(r.value() > 99.9 and r.value() < 100.1)


def test_parse_number_decimal() raises:
    """Should extract a decimal number."""
    var r = parse_json_number('{"price":9.99}', "price")
    assert_true(Bool(r))
    assert_true(r.value() > 9.98 and r.value() < 10.0)


def test_parse_number_missing() raises:
    """Should return None for missing field."""
    var r = parse_json_number('{"price":9.99}', "cost")
    assert_false(Bool(r))


def test_parse_number_follows_the_json_grammar() raises:
    """A value JSON would not parse as a number is refused, not read in part.

    The scan took digits, then a fraction and an exponent if it saw them,
    and converted what it had whatever came next: `12abc` read as 12, `01`
    as 1 and `1.5.3` as 1.5. RFC 8259 section 6 is the rule now: an
    optional `-`; `0` alone, or a digit 1-9 and its digits; a fraction of
    `.` and at least one digit; an exponent of `e` or `E`, an optional
    sign and at least one digit, leading zeros allowed there. And the
    number must end where a JSON value may, at whitespace, `,`, `}`, `]`
    or the end of the body.
    """
    var refused = [
        String('{"n":12abc}'),
        String('{"n":1e5x}'),
        String('{"n":1.5.3}'),
        String('{"n":1-2}'),
        String('{"n":0x10}'),
        String('{"n":1_000}'),
        String('{"n":01}'),
        String('{"n":-01.5}'),
        String('{"n":00.5}'),
        String('{"n":.5}'),
        String('{"n":-.5}'),
        String('{"n":1.}'),
        String('{"n":1.e3}'),
        String('{"n":1e}'),
        String('{"n":1e+}'),
        String('{"n":1e+,"m":1}'),
        String('{"n":+1}'),
        String('{"n":-}'),
        String('{"n":--1}'),
        String('{"n":Infinity}'),
        String('{"n":-Infinity}'),
        String('{"n":NaN}'),
    ]
    for body in refused:
        var r = parse_json_number(body, "n")
        assert_false(Bool(r), String("parse_json_number read ", body, " as a number"))
    # Every value here is exact in binary, so equality is the right test.
    var kept = [
        (String('{"n":0}'), Float64(0)),
        (String('{"n":-0}'), Float64(0)),
        (String('{"n":0.5}'), Float64(0.5)),
        (String('{"n":-0.25}'), Float64(-0.25)),
        (String('{"n":10}'), Float64(10)),
        (String('{"n":1e3}'), Float64(1000)),
        (String('{"n":1E+2}'), Float64(100)),
        (String('{"n":125e-3}'), Float64(0.125)),
        (String('{"n":5e-01}'), Float64(0.5)),
        (String('{"n":12,"m":1}'), Float64(12)),
        (String('{"n":12 }'), Float64(12)),
        (String('{"n":12\n}'), Float64(12)),
        (String('{"a":[1],"n":12]'), Float64(12)),
        (String('{"n":12'), Float64(12)),
    ]
    for pair in kept:
        var r = parse_json_number(pair[0], "n")
        assert_true(Bool(r), String("parse_json_number refused ", pair[0]))
        assert_equal(r.value(), pair[1])
    # The field's own trailing bytes are refused; a neighbour's do not matter.
    assert_equal(parse_json_number('{"m":12abc,"n":3}', "n").value(), 3.0)


def _scan(text: String) -> Int:
    return _scan_json_number(text.as_bytes(), text.byte_length(), 0, integer=False)


def test_scan_json_number_is_the_grammar_not_the_conversion() raises:
    """The scan refuses what JSON refuses, whatever `Float64()` accepts.

    The conversion behind `parse_json_number` is Mojo's own parser, and it
    is laxer than JSON on this toolchain -- it reads `1.`, `.5`, `01`,
    `+1`, `inf` and `nan` -- while it happens to refuse an exponent with
    no digits. So `parse_json_number` cannot show whether the scan refuses
    `1e` itself, and the scan's rule is pinned here, where no conversion
    stands behind it.
    """
    for text in ["1e", "1E", "1e+", "1e-", "-2E ]", "1e,", "3e+}", "5.5e"]:
        assert_equal(_scan(text), -1, String("scanned ", text, " as a number"))
    assert_equal(_scan("1e0"), 3)
    assert_equal(_scan("1E+05,"), 5)
    assert_equal(_scan("-2.5e-1 "), 7)


def test_parse_number_before_a_non_utf8_byte_does_not_trap() raises:
    """A number followed by a byte that is not UTF-8 is answered, not trapped.

    The value is cut out of a request body, and the byte after its last
    digit is whatever the client sent. The cut used to be
    `body[byte=start:i]`, which asserts a codepoint boundary at `i`: a
    POST of `{"x":1<0x80>}` killed the process on the loop thread. No app
    in the tree called this until `apps/blobs`' drop view, which is how
    it was found. The other extractors pass the same fuzz; this one alone
    trapped. A number must now end at a delimiter, so that body is
    refused; one whose non-UTF-8 byte comes after the delimiter is read.

    covers: G14
    """
    var b = List[UInt8]()
    for c in String('{"x":1').as_bytes():
        b.append(c)
    b.append(UInt8(0x80))
    b.append(UInt8(ord("}")))
    var body = String(unsafe_from_utf8=Span(b))
    assert_false(Bool(parse_json_number(body, "x")))
    var d = List[UInt8]()
    for c in String('{"x":1 ').as_bytes():
        d.append(c)
    d.append(UInt8(0x80))
    d.append(UInt8(ord("}")))
    var r = parse_json_number(String(unsafe_from_utf8=Span(d)), "x")
    assert_true(Bool(r))
    assert_equal(r.value(), 1.0)
    # A continuation byte right after the sign: nothing to read, no trap.
    var c = List[UInt8]()
    for ch in String('{"x":-').as_bytes():
        c.append(ch)
    c.append(UInt8(0xBF))
    assert_false(Bool(parse_json_number(String(unsafe_from_utf8=Span(c)), "x")))


# --- Boolean extraction ---

def test_parse_bool_true() raises:
    """Should extract true."""
    var r = parse_json_bool('{"active":true}', "active")
    assert_true(Bool(r))
    assert_true(r.value())


def test_parse_bool_false() raises:
    """Should extract false."""
    var r = parse_json_bool('{"active":false}', "active")
    assert_true(Bool(r))
    assert_false(r.value())


def test_parse_bool_missing() raises:
    """Should return None for missing field."""
    var r = parse_json_bool('{"active":true}', "enabled")
    assert_false(Bool(r))


def test_parse_string_tells_empty_from_absent_and_wrong_typed() raises:
    """A real `""` is a value; absent, non-string and malformed are None.

    `parse_json_field` answers `""` for all four, which is how a NOTIFY
    whose `data` was an object reached every subscriber as an empty event.
    """
    var empty = parse_json_string('{"data":""}', "data")
    assert_true(Bool(empty))
    assert_equal(empty.value(), "")
    assert_equal(parse_json_string('{"data":"x\\ny"}', "data").value(), "x\ny")
    for body in [
        '{"other":"x"}',
        '{"data":{"n":1}}',
        '{"data":[1,2]}',
        '{"data":42}',
        '{"data":true}',
        '{"data":null}',
        '{"data":"bad \\q escape"}',
        '{"data":"unterminated',
        "not json",
    ]:
        assert_false(Bool(parse_json_string(body, "data")))
    assert_false(has_json_field('{"other":"x"}', "data"))
    assert_true(has_json_field('{"data":{"n":1}}', "data"))
    assert_true(has_json_field('{"data":null}', "data"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
