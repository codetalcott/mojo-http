"""Tests for the JSON field extraction parser."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.json_parse import parse_json_field, parse_json_int, parse_json_number, parse_json_bool


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
