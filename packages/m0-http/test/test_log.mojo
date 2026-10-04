"""Tests for structured access logging.

`format_json` is the pure half of `log_json`; testing it is why the split
exists. What matters here is that a log line stays *one* line of valid JSON no
matter what a request puts in it — a path, a method and a header value all
reach these fields straight off the wire. And that its numbers are numbers,
and its time the wall clock.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.http.date import unix_now

from src.log import (
    LogEntry, LogClock, format_json, format_access, realtime_ns,
    rfc3339_second,
)


comptime T = "2026-10-04T01:35:05.221Z"


def test_minimal_entry_shape() raises:
    var e = LogEntry("INFO", "access")
    assert_equal(
        format_json(e, T),
        '{"time":"2026-10-04T01:35:05.221Z","level":"INFO","msg":"access"}',
    )


def test_key_value_pairs_are_appended_in_order() raises:
    var e = LogEntry("INFO", "access")
    e.add("method", "GET")
    e.add_int("status", 200)
    assert_equal(
        format_json(e, T),
        '{"time":"' + T + '","level":"INFO","msg":"access","method":"GET",'
        + '"status":200}',
    )


def test_quotes_in_a_value_cannot_break_the_record() raises:
    """A path is attacker-controlled. Unescaped, it ends the JSON string early."""
    var e = LogEntry("INFO", "access")
    e.add("path", '/a"b')
    var got = format_json(e, T)
    assert_true('\\"' in got, "quote was not escaped: " + got)


def test_backslash_in_a_value_is_escaped() raises:
    var e = LogEntry("INFO", "access")
    e.add("path", "/a\\b")
    var got = format_json(e, T)
    assert_true("\\\\" in got, "backslash was not escaped: " + got)


def test_a_newline_cannot_forge_a_second_log_line() raises:
    """JSON-lines is line-delimited: a raw newline in a value invents a record.

    That is log injection — an attacker who can put a newline plus their own
    JSON into a path can write whatever they like into the log stream.

    covers: F1
    """
    var e = LogEntry("INFO", "access")
    e.add("path", '/x\n{"level":"INFO","msg":"forged"}')
    var got = format_json(e, T)
    assert_false("\n" in got, "a raw newline survived into the record: " + got)
    var clock = LogClock()
    var line = format_access(
        clock, 0, "GET", '/x\n{"level":"INFO","msg":"forged"}', 200, 1, 2
    )
    assert_false("\n" in line, "a raw newline survived into the access line: " + line)


def test_keys_are_escaped_too() raises:
    """Keys are as caller-supplied as values are."""
    var e = LogEntry("INFO", "access")
    e.add('we"ird', "v")
    var got = format_json(e, T)
    assert_true('\\"' in got, "key was not escaped: " + got)


def test_carriage_return_is_escaped() raises:
    var e = LogEntry("INFO", "access")
    e.add("path", "/a\rb")
    assert_false("\r" in format_json(e, T))


def test_add_int_is_a_json_number() raises:
    """A number is written bare, sign and all, so `jq` compares it as one:
    quoted, `select(.status >= 500)` matched every line, a string sorting
    after every number."""
    var e = LogEntry("INFO", "m")
    e.add_int("n", -5)
    e.add_int("z", 0)
    e.add("s", "200")
    var got = format_json(e, T)
    assert_true('"n":-5,' in got, got)
    assert_true('"z":0,' in got, got)
    assert_true('"s":"200"' in got, got)


def test_level_and_message_are_escaped() raises:
    var e = LogEntry('IN"FO', 'a"b')
    var got = format_json(e, T)
    assert_true('IN\\"FO' in got and 'a\\"b' in got, "level/msg went in unescaped: " + got)


def test_a_long_value_crossing_the_simd_boundary_is_escaped_correctly() raises:
    """`format_json` now escapes into one shared buffer, so the escaper's SIMD
    chunking runs at a non-zero starting offset. A value long enough to reach
    that path, with an escape past the first chunk, pins it."""
    var value = String("")
    for _ in range(30):
        value += "abcdefghij"        # 300 safe bytes: well past 64
    value += 'tail"quote'            # the escape lands far into the value

    var entry = LogEntry("INFO", "access")
    entry.add("path", value)
    var line = format_json(entry, T)

    # The record must still be one line, still closed, and the embedded quote
    # must be escaped rather than terminating the field.
    assert_true(line.startswith('{"time":"' + T + '",'))
    assert_true(line.endswith("}"))
    assert_true(line.find('tail\\"quote') > 0)
    assert_equal(line.count("\n"), 0)
    # Exactly the quotes we expect: no stray terminator from the long value.
    assert_true(line.find(String(value[byte=0:20])) > 0)


# --- the access line ----------------------------------------------------------


def _as_entry(
    method: String, path: String, status: Int, dur_us: Int, body_size: Int,
    remote_addr: String,
) -> LogEntry:
    var e = LogEntry("INFO", "access")
    e.add("method", method)
    e.add("path", path)
    e.add_int("status", status)
    e.add_int("dur_us", dur_us)
    e.add_int("bytes", body_size)
    if remote_addr.byte_length() > 0:
        e.add("remote_addr", remote_addr)
    return e^


def test_format_access_is_format_json_byte_for_byte() raises:
    """The access line skips `LogEntry` for speed and writes its own bytes;
    it must still be exactly the record `format_json` renders for the same
    fields at the same time, escapes, signs and an absent address included.

    covers: F20
    """
    var ns = 1791133371 * 1_000_000_000 + 789_000_000
    var cases = List[LogEntry]()
    var lines = List[String]()
    var clock = LogClock()
    lines.append(format_access(clock, ns, "GET", "/method", 200, 1234, 64, "127.0.0.1"))
    cases.append(_as_entry("GET", "/method", 200, 1234, 64, "127.0.0.1"))
    lines.append(format_access(clock, ns, "HEAD", '/q"x\\y', 304, 0, 0))
    cases.append(_as_entry("HEAD", '/q"x\\y', 304, 0, 0, ""))
    lines.append(format_access(clock, ns, "POST", "/u", 413, 9, 1048576, "::1"))
    cases.append(_as_entry("POST", "/u", 413, 9, 1048576, "::1"))
    for i in range(len(lines)):
        assert_equal(lines[i], format_json(cases[i], clock.stamp(ns)))
    assert_equal(
        lines[0],
        '{"time":"2026-10-04T17:02:51.789Z","level":"INFO","msg":"access",'
        + '"method":"GET","path":"/method","status":200,"dur_us":1234,'
        + '"bytes":64,"remote_addr":"127.0.0.1"}',
    )


def test_rfc3339_second_is_the_civil_date_in_utc() raises:
    """Against Python's `datetime`: the epoch, a day's last second, leap days
    in a year divisible by 400 and by 4, a year divisible by 100 that is not
    a leap year, and the last second four digits of year can write."""
    var secs = [
        0, 59, 86399, 86400, 951782400, 951868799, 1709164800, 1791133371,
        4107542399, 4107542400, 253402300799,
    ]
    var want = [
        String("1970-01-01T00:00:00."), String("1970-01-01T00:00:59."),
        String("1970-01-01T23:59:59."), String("1970-01-02T00:00:00."),
        String("2000-02-29T00:00:00."), String("2000-02-29T23:59:59."),
        String("2024-02-29T00:00:00."), String("2026-10-04T17:02:51."),
        String("2100-02-28T23:59:59."), String("2100-03-01T00:00:00."),
        String("9999-12-31T23:59:59."),
    ]
    for i in range(len(secs)):
        assert_equal(rfc3339_second(secs[i]), want[i])


def test_the_clock_writes_milliseconds_and_rolls_its_second() raises:
    """The cached second is replaced when the second changes, and the
    milliseconds are three digits whatever their value."""
    var clock = LogClock()
    var base = 1791133371 * 1_000_000_000
    assert_equal(clock.stamp(base), "2026-10-04T17:02:51.000Z")
    assert_equal(clock.stamp(base + 7_000_000), "2026-10-04T17:02:51.007Z")
    assert_equal(clock.stamp(base + 999_999_999), "2026-10-04T17:02:51.999Z")
    assert_equal(clock.stamp(base + 1_000_000_000), "2026-10-04T17:02:52.000Z")
    assert_equal(clock.stamp(base + 60_050_000_000), "2026-10-04T17:03:51.050Z")


def test_realtime_ns_is_the_wall_clock() raises:
    """`clock_gettime(CLOCK_REALTIME)` agrees with `time(NULL)`, the clock
    the Date header reads, to the second."""
    var before = Int(unix_now())
    var got = realtime_ns() // 1_000_000_000
    var after = Int(unix_now())
    assert_true(got >= before and got <= after, String(got))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
