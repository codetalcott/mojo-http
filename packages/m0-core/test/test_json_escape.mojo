"""Tests for JSON string escape."""

from std.testing import assert_equal, assert_true, TestSuite

from src.json_escape import escape_json_string


def test_simple_string() raises:
    """Simple strings should be wrapped in quotes."""
    assert_equal(escape_json_string("hello"), '"hello"')


def test_empty_string() raises:
    """Empty string should produce empty quotes."""
    assert_equal(escape_json_string(""), '""')


def test_escape_quote() raises:
    """Double quotes should be escaped as \\\"."""
    assert_equal(escape_json_string('say "hi"'), '"say \\"hi\\""')


def test_escape_backslash() raises:
    """Backslashes should be escaped as \\\\."""
    assert_equal(escape_json_string("path\\to\\file"), '"path\\\\to\\\\file"')


def test_escape_newline() raises:
    """Newlines should be escaped as \\n."""
    assert_equal(escape_json_string("line1\nline2"), '"line1\\nline2"')


def test_escape_tab() raises:
    """Tabs should be escaped as \\t."""
    assert_equal(escape_json_string("col1\tcol2"), '"col1\\tcol2"')


def test_escape_carriage_return() raises:
    """Carriage returns should be escaped as \\r."""
    assert_equal(escape_json_string("a\rb"), '"a\\rb"')


def test_no_escape_needed() raises:
    """Strings without special chars should pass through unchanged."""
    assert_equal(escape_json_string("abc123"), '"abc123"')


def test_control_char_u_escape() raises:
    """Control chars below 0x20 (other than \\n/\\r/\\t) use \\u00XX."""
    var buf = List[UInt8](capacity=4)
    buf.append(UInt8(ord("a")))
    buf.append(0x01)
    buf.append(UInt8(ord("b")))
    buf.append(0)
    var s = String(unsafe_from_utf8=Span(ptr=buf.unsafe_ptr(), length=3))
    assert_equal(escape_json_string(s), '"a\\u0001b"')


def test_simd_boundary() raises:
    """Escape lying just past the 64-byte SIMD boundary must still be caught."""
    # 70 safe bytes ('a'*70) then a backslash and 'z'.
    var buf = List[UInt8](capacity=80)
    for _ in range(70):
        buf.append(UInt8(ord("a")))
    buf.append(0x5C)  # backslash — must be escaped
    buf.append(UInt8(ord("z")))
    buf.append(0)
    var s = String(unsafe_from_utf8=Span(ptr=buf.unsafe_ptr(), length=72))
    var out = escape_json_string(s)
    # Expected: opening quote, 70 a's, "\\\\" (escaped backslash), "z", closing quote.
    var expected = String('"')
    for _ in range(70):
        expected += "a"
    expected += "\\\\z\""
    assert_equal(out, expected)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
