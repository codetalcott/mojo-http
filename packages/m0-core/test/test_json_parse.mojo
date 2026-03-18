"""Tests for the JSON field extraction parser."""

from std.testing import assert_equal

from src.json_parse import parse_json_field


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
