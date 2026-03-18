"""Tests for the JSON field extraction parser."""

from std.testing import assert_equal, assert_true

from src.json_parse import parse_json_field, parse_json_int, parse_json_number, parse_json_bool


fn test_parse_simple_field() raises:
    """Should extract a simple string value."""
    var result = parse_json_field('{"name":"Alice"}', "name")
    assert_equal(result, "Alice")


fn test_parse_with_whitespace() raises:
    """Should handle whitespace around colon and value."""
    var result = parse_json_field('{"name" : "Alice"}', "name")
    assert_equal(result, "Alice")


fn test_parse_missing_field() raises:
    """Should return empty string for missing field."""
    var result = parse_json_field('{"name":"Alice"}', "age")
    assert_equal(result, "")


fn test_parse_escaped_quotes() raises:
    """Should handle escaped quotes in values."""
    var result = parse_json_field('{"msg":"he said \\"hi\\""}', "msg")
    assert_equal(result, 'he said "hi"')


fn test_parse_escaped_backslash() raises:
    """Should handle escaped backslashes in values."""
    var result = parse_json_field('{"path":"c:\\\\dir\\\\file"}', "path")
    assert_equal(result, "c:\\dir\\file")


fn test_parse_escaped_newline() raises:
    """Should handle escaped newlines in values."""
    var result = parse_json_field('{"text":"line1\\nline2"}', "text")
    assert_equal(result, "line1\nline2")


fn test_parse_multiple_fields() raises:
    """Should extract the correct field from an object with multiple keys."""
    var body = '{"title":"Fix bug","priority":"high","status":"open"}'
    assert_equal(parse_json_field(body, "title"), "Fix bug")
    assert_equal(parse_json_field(body, "priority"), "high")
    assert_equal(parse_json_field(body, "status"), "open")


fn test_parse_empty_value() raises:
    """Should handle empty string values."""
    var result = parse_json_field('{"name":""}', "name")
    assert_equal(result, "")


fn test_parse_empty_body() raises:
    """Should return empty string for empty body."""
    var result = parse_json_field("", "name")
    assert_equal(result, "")


# --- Integer extraction ---

fn test_parse_int_simple() raises:
    """Should extract an integer value."""
    assert_equal(parse_json_int('{"count":42}', "count"), 42)


fn test_parse_int_negative() raises:
    """Should extract a negative integer value."""
    assert_equal(parse_json_int('{"offset":-5}', "offset"), -5)


fn test_parse_int_missing() raises:
    """Should return -1 for missing field."""
    assert_equal(parse_json_int('{"count":42}', "total"), -1)


fn test_parse_int_not_numeric() raises:
    """Should return -1 for non-numeric value."""
    assert_equal(parse_json_int('{"name":"Alice"}', "name"), -1)


# --- Number extraction ---

fn test_parse_number_integer() raises:
    """Should extract an integer as Float64."""
    var result = parse_json_number('{"price":100}', "price")
    assert_true(result > 99.9 and result < 100.1)


fn test_parse_number_decimal() raises:
    """Should extract a decimal number."""
    var result = parse_json_number('{"price":9.99}', "price")
    assert_true(result > 9.98 and result < 10.0)


fn test_parse_number_missing() raises:
    """Should return 0.0 for missing field."""
    var result = parse_json_number('{"price":9.99}', "cost")
    assert_true(result == 0.0)


# --- Boolean extraction ---

fn test_parse_bool_true() raises:
    """Should extract true as 1."""
    assert_equal(parse_json_bool('{"active":true}', "active"), 1)


fn test_parse_bool_false() raises:
    """Should extract false as 0."""
    assert_equal(parse_json_bool('{"active":false}', "active"), 0)


fn test_parse_bool_missing() raises:
    """Should return -1 for missing field."""
    assert_equal(parse_json_bool('{"active":true}', "enabled"), -1)
