"""Structured JSON logging for M0 HTTP servers.

Writes JSON-lines to stdout for machine-parseable access logs. Fields: time,
level, msg, then the caller's key-value pairs.

`time` is the wall clock: RFC 3339 in UTC with milliseconds,
`2026-10-04T01:35:05.221Z`, which a log shipper parses and a person reads,
and which matches a line against an application's own log. UTC because a
container runs in it and it needs no timezone database; milliseconds because
under load a second holds many lines. `LogClock` caches the second's
`YYYY-MM-DDTHH:MM:SS.` and adds three digits, so a line pays one
`clock_gettime` and no calendar arithmetic. The clock can step when it is
set; `dur_us`, the latency, comes from the monotonic clock and does not.
`time` replaced `ts`, a monotonic millisecond count with an arbitrary origin,
which ordered the lines of one process and said nothing else.

A value added with `add_int` is a JSON number, written bare, so
`jq 'select(.status >= 500)'` compares numerically; as a string it sorted
after every number and matched every line. Everything else is a string and
goes through the escaper, keys included.

`format_json` builds a record and `log_json` prints it — the split exists so
the formatting is testable without capturing stdout. The access line, written
on the event loop for every response, has a writer of its own,
`format_access`, which `test_log.mojo` holds to `format_json`'s output byte
for byte.
"""

from std.ffi import c_int, external_call

from m0_core.json_escape import escape_json_string_into


struct LogEntry(Movable):
    """Structured log entry with key-value pairs (SoA)."""
    var level: String
    var msg: String
    var kv_keys: List[String]
    var kv_values: List[String]
    var kv_raw: List[Bool]
    """Whether each value is written bare. True for `add_int`'s, whose text
    is digits after an optional sign: a JSON number, and nothing a string
    needs escaping from."""

    def __init__(out self, level: String, msg: String):
        self.level = level
        self.msg = msg
        self.kv_keys = List[String]()
        self.kv_values = List[String]()
        self.kv_raw = List[Bool]()

    def add(mut self, key: String, value: String):
        self.kv_keys.append(key)
        self.kv_values.append(value)
        self.kv_raw.append(False)

    def add_int(mut self, key: String, value: Int):
        self.kv_keys.append(key)
        self.kv_values.append(String(value))
        self.kv_raw.append(True)


def format_json(entry: LogEntry, time: String) -> String:
    """Render one JSON-lines record. Pure — the caller supplies the time.

    Every string goes through the escaper, including the keys: a key-value
    pair whose key came from a request header would otherwise be able to
    close the string and inject structure into the log. The time too, which
    costs a scan of 24 bytes and means no caller can break a record.

    Assembled in one byte buffer rather than by `+`-ing Strings together.
    The old form allocated a String for each escaped value and then another
    for each concatenation — about a dozen per access-log line, to produce
    one line. Same output, measured 4.5x faster on a five-field access
    record (1218 -> 268 ns).
    """
    var out = List[UInt8](capacity=256)
    out.extend(String('{"time":').as_bytes())
    escape_json_string_into(out, time)
    out.extend(String(',"level":').as_bytes())
    escape_json_string_into(out, entry.level)
    out.extend(String(',"msg":').as_bytes())
    escape_json_string_into(out, entry.msg)
    for i in range(len(entry.kv_keys)):
        out.append(UInt8(ord(',')))
        escape_json_string_into(out, entry.kv_keys[i])
        out.append(UInt8(ord(':')))
        if entry.kv_raw[i]:
            out.extend(entry.kv_values[i].as_bytes())
        else:
            escape_json_string_into(out, entry.kv_values[i])
    out.append(UInt8(ord('}')))
    return String(unsafe_from_utf8=Span(out))


struct _TimeSpec(Movable):
    """`struct timespec`: two 64-bit words on every 64-bit libc."""

    var sec: Int64
    var nsec: Int64

    def __init__(out self):
        self.sec = 0
        self.nsec = 0


comptime _CLOCK_REALTIME = 0
"""The same number on Linux and on macOS."""


def realtime_ns() -> Int:
    """The wall clock, in nanoseconds since the Unix epoch.

    `clock_gettime(CLOCK_REALTIME)`, about 12 ns, and the program's only
    declaration of it: a second `external_call` of the same symbol with
    another signature does not compile. macOS reports microseconds, which
    is three digits more than a log line prints.
    """
    var ts = _TimeSpec()
    _ = external_call["clock_gettime", c_int](
        c_int(_CLOCK_REALTIME), Pointer(to=ts)
    )
    return Int(ts.sec) * 1_000_000_000 + Int(ts.nsec)


def _two(mut out: List[UInt8], n: Int):
    out.append(UInt8(48 + n // 10))
    out.append(UInt8(48 + n % 10))


def _write_int(mut out: List[UInt8], value: Int):
    """`value` in decimal, straight into `out`: what `String(value)` spells,
    without the String."""
    var n = value
    if n < 0:
        out.append(UInt8(ord("-")))
        n = -n
    var start = len(out)
    while True:
        out.append(UInt8(48 + n % 10))
        n //= 10
        if n == 0:
            break
    var lo = start
    var hi = len(out) - 1
    while lo < hi:
        var b = out[lo]
        out[lo] = out[hi]
        out[hi] = b
        lo += 1
        hi -= 1


def rfc3339_second(sec: Int) -> String:
    """Unix seconds as `YYYY-MM-DDTHH:MM:SS.` in UTC, ready for milliseconds.

    The date is Howard Hinnant's `civil_from_days`, integer arithmetic and
    no table or FFI: exact for every day of the proleptic Gregorian
    calendar. Four digits of year, which covers 0000 to 9999.
    """
    var days = sec // 86400
    var rem = sec - days * 86400
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var year = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var day = doy - (153 * mp + 2) // 5 + 1
    var month = mp + 3 if mp < 10 else mp - 9
    if month <= 2:
        year += 1
    var out = List[UInt8](capacity=20)
    _two(out, (year // 100) % 100)
    _two(out, year % 100)
    out.append(UInt8(ord("-")))
    _two(out, month)
    out.append(UInt8(ord("-")))
    _two(out, day)
    out.append(UInt8(ord("T")))
    _two(out, rem // 3600)
    out.append(UInt8(ord(":")))
    _two(out, (rem // 60) % 60)
    out.append(UInt8(ord(":")))
    _two(out, rem % 60)
    out.append(UInt8(ord(".")))
    return String(unsafe_from_utf8=Span(out))


struct LogClock(Movable):
    """RFC 3339 UTC timestamps with milliseconds, the second cached.

    One per event loop (`LoopState.log_clock`), never shared: the cache is
    two plain fields, and loops under `--threads` share a process.
    """

    var _sec: Int
    var _prefix: String

    def __init__(out self):
        self._sec = -1
        self._prefix = String("")

    def stamp_into(mut self, mut out: List[UInt8], ns: Int):
        """`ns` (`realtime_ns`) as `YYYY-MM-DDTHH:MM:SS.mmmZ`, appended."""
        var sec = ns // 1_000_000_000
        if sec != self._sec:
            self._prefix = rfc3339_second(sec)
            self._sec = sec
        var ms = (ns // 1_000_000) % 1000
        out.extend(self._prefix.as_bytes())
        out.append(UInt8(48 + ms // 100))
        _two(out, ms % 100)
        out.append(UInt8(ord("Z")))

    def stamp(mut self, ns: Int) -> String:
        """`stamp_into`, as a String."""
        var out = List[UInt8](capacity=24)
        self.stamp_into(out, ns)
        return String(unsafe_from_utf8=Span(out))

    def now(mut self) -> String:
        """The wall clock, stamped."""
        return self.stamp(realtime_ns())


def format_access(
    mut clock: LogClock, now_ns: Int, method: String, path: String,
    status: Int, dur_us: Int, body_size: Int, remote_addr: String = "",
) -> String:
    """The access record `format_json` would render for these fields, at
    `now_ns`, written straight into one buffer.

    The access line is written on the event loop's thread for every
    response, so it skips `LogEntry`, whose lists and per-number Strings
    were most of a line's cost, and the stamp goes in as bytes. The output
    depends on the arguments alone (the clock's cache changes when, not
    what), and `test_log.mojo` holds it byte for byte to `format_json`'s.
    """
    var out = List[UInt8](capacity=256)
    out.extend(StaticString('{"time":"').as_bytes())
    clock.stamp_into(out, now_ns)
    out.extend(StaticString('","level":"INFO","msg":"access","method":').as_bytes())
    escape_json_string_into(out, method)
    out.extend(StaticString(',"path":').as_bytes())
    escape_json_string_into(out, path)
    out.extend(StaticString(',"status":').as_bytes())
    _write_int(out, status)
    out.extend(StaticString(',"dur_us":').as_bytes())
    _write_int(out, dur_us)
    out.extend(StaticString(',"bytes":').as_bytes())
    _write_int(out, body_size)
    if remote_addr.byte_length() > 0:
        out.extend(StaticString(',"remote_addr":').as_bytes())
        escape_json_string_into(out, remote_addr)
    out.append(UInt8(ord("}")))
    return String(unsafe_from_utf8=Span(out))


def log_json(entry: LogEntry, time: String):
    """Write a JSON-lines log entry to stdout."""
    print(format_json(entry, time))


def log_access(
    mut clock: LogClock, method: String, path: String, status: Int,
    dur_us: Int, body_size: Int, remote_addr: String = "",
):
    """Emit a structured access log line (`format_access`), stamped now.

    `clock` is the caller's: the loop keeps one, so a line pays one clock
    read and no calendar arithmetic. `status`, `dur_us` and `bytes` are JSON
    numbers.

    `body_size` is the response body as sent: a file sent with `sendfile`
    included, nothing for a HEAD or a 304, and no head. It was the encoded
    buffer's length -- the head plus an in-memory body, and none of a file
    body -- so a 64-byte body logged 366 and a static file about the size of
    its head. A stream is logged when its head lands, with what went with it.

    `remote_addr` is the client's address as the server reports it to the
    application (WSGI's `REMOTE_ADDR`): an IPv6 peer as `::1`, an IPv4 peer
    of a `::` listener as `127.0.0.1`. Left out of the line when empty, as
    it is for a peer the server could not read.
    """
    print(
        format_access(
            clock, realtime_ns(), method, path, status, dur_us, body_size,
            remote_addr,
        )
    )
