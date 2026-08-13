"""Tests for structured access logging.

`format_json` is the pure half of `log_json`; testing it is why the split
exists. What matters here is that a log line stays *one* line of valid JSON no
matter what a request puts in it — a path, a method and a header value all
reach these fields straight off the wire.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.log import LogEntry, format_json


def test_minimal_entry_shape() raises:
    var e = LogEntry("INFO", "access")
    assert_equal(
        format_json(e, 1234), '{"ts":1234,"level":"INFO","msg":"access"}'
    )


def test_key_value_pairs_are_appended_in_order() raises:
    var e = LogEntry("INFO", "access")
    e.add("method", "GET")
    e.add_int("status", 200)
    assert_equal(
        format_json(e, 7),
        '{"ts":7,"level":"INFO","msg":"access","method":"GET","status":"200"}',
    )


def test_quotes_in_a_value_cannot_break_the_record() raises:
    """A path is attacker-controlled. Unescaped, it ends the JSON string early."""
    var e = LogEntry("INFO", "access")
    e.add("path", '/a"b')
    var got = format_json(e, 1)
    assert_true('\\"' in got, "quote was not escaped: " + got)


def test_backslash_in_a_value_is_escaped() raises:
    var e = LogEntry("INFO", "access")
    e.add("path", "/a\\b")
    var got = format_json(e, 1)
    assert_true("\\\\" in got, "backslash was not escaped: " + got)


def test_a_newline_cannot_forge_a_second_log_line() raises:
    """JSON-lines is line-delimited: a raw newline in a value invents a record.

    That is log injection — an attacker who can put a newline plus their own
    JSON into a path can write whatever they like into the log stream.
    """
    var e = LogEntry("INFO", "access")
    e.add("path", '/x\n{"level":"INFO","msg":"forged"}')
    var got = format_json(e, 1)
    assert_false("\n" in got, "a raw newline survived into the record: " + got)


def test_keys_are_escaped_too() raises:
    """Keys are as caller-supplied as values are."""
    var e = LogEntry("INFO", "access")
    e.add('we"ird', "v")
    var got = format_json(e, 1)
    assert_true('\\"' in got, "key was not escaped: " + got)


def test_carriage_return_is_escaped() raises:
    var e = LogEntry("INFO", "access")
    e.add("path", "/a\rb")
    assert_false("\r" in format_json(e, 1))


def test_add_int_renders_as_a_string_field() raises:
    """Documents the current shape: numbers are quoted, not bare JSON numbers.

    Anything reading these logs has to parse them as strings, so a change here
    is a breaking change for downstream tooling.
    """
    var e = LogEntry("INFO", "m")
    e.add_int("n", -5)
    assert_true('"n":"-5"' in format_json(e, 1))


def test_level_and_message_are_escaped() raises:
    var e = LogEntry('IN"FO', 'a"b')
    var got = format_json(e, 1)
    assert_false(got.count('"') == 6, "level/msg went in unescaped: " + got)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
