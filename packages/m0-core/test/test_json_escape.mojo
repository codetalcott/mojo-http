"""Tests for JSON string escape."""

from std.testing import assert_equal, assert_true

from src.json_escape import escape_json_string


def test_simple_string() raises:
    """Simple strings should be wrapped in quotes."""
    assert_equal(escape_json_string("hello"), '"hello"')


def test_empty_string() raises:
    """Empty string should produce empty quotes."""
    assert_equal(escape_json_string(""), '""')


def test_escape_quote() raises:
    """Double quotes should be escaped."""
    var result = escape_json_string('say "hi"')
    assert_true(result.find('\\"') != -1)


def test_escape_backslash() raises:
    """Backslashes should be escaped."""
    var result = escape_json_string("path\\to\\file")
    assert_true(result.find("\\\\") != -1)


def test_escape_newline() raises:
    """Newlines should be escaped as \\n."""
    var result = escape_json_string("line1\nline2")
    assert_true(result.find("\\n") != -1)


def test_escape_tab() raises:
    """Tabs should be escaped as \\t."""
    var result = escape_json_string("col1\tcol2")
    assert_true(result.find("\\t") != -1)


def test_no_escape_needed() raises:
    """Strings without special chars should pass through unchanged."""
    assert_equal(escape_json_string("abc123"), '"abc123"')
