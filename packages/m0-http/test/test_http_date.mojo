"""The Date header's formatter: right on every field, and safe on threads.

`http_date_from_unix` is what every event loop formats its Date header with
(once a second, into the loop's own cache), and `HTTPResponse.encode` calls
it for a response that carries none. Under `M0_THREADS` or `--threads` the
loops are threads of ONE process, so the formatter must share nothing
between calls: it fills a `struct tm` of its own through `gmtime_r`, where
libc's `gmtime` hands every caller glibc's one static `struct tm`.
"""

from std.ffi import external_call
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.http.date import http_date_from_unix, http_date_now, unix_now

from src.threads import (
    ThreadSet,
    ThreadBlock,
    BLK_INDEX,
    BLK_USER,
    BLK_STATUS,
    STATUS_OK,
)


def test_the_date_is_right_on_every_field() raises:
    """IMF-fixdate (RFC 9110 §5.6.7), checked against Python's own formatter.

    The first of each month of 2026 names all twelve months and all seven
    weekdays; the rest are the epoch, the RFC's own example, a leap day,
    single-digit fields, and either side of the 32-bit `time_t` limit.
    """
    assert_equal(http_date_from_unix(0), "Thu, 01 Jan 1970 00:00:00 GMT")
    assert_equal(http_date_from_unix(784111777), "Sun, 06 Nov 1994 08:49:37 GMT")
    assert_equal(http_date_from_unix(951782400), "Tue, 29 Feb 2000 00:00:00 GMT")
    assert_equal(http_date_from_unix(946688461), "Sat, 01 Jan 2000 01:01:01 GMT")
    assert_equal(http_date_from_unix(1700000000), "Tue, 14 Nov 2023 22:13:20 GMT")
    assert_equal(http_date_from_unix(2147483647), "Tue, 19 Jan 2038 03:14:07 GMT")
    assert_equal(http_date_from_unix(2147483648), "Tue, 19 Jan 2038 03:14:08 GMT")
    assert_equal(http_date_from_unix(4102444799), "Thu, 31 Dec 2099 23:59:59 GMT")
    var firsts = [
        (Int64(1767258303), "Thu, 01 Jan 2026 09:05:03 GMT"),
        (Int64(1769936703), "Sun, 01 Feb 2026 09:05:03 GMT"),
        (Int64(1772355903), "Sun, 01 Mar 2026 09:05:03 GMT"),
        (Int64(1775034303), "Wed, 01 Apr 2026 09:05:03 GMT"),
        (Int64(1777626303), "Fri, 01 May 2026 09:05:03 GMT"),
        (Int64(1780304703), "Mon, 01 Jun 2026 09:05:03 GMT"),
        (Int64(1782896703), "Wed, 01 Jul 2026 09:05:03 GMT"),
        (Int64(1785575103), "Sat, 01 Aug 2026 09:05:03 GMT"),
        (Int64(1788253503), "Tue, 01 Sep 2026 09:05:03 GMT"),
        (Int64(1790845503), "Thu, 01 Oct 2026 09:05:03 GMT"),
        (Int64(1793523903), "Sun, 01 Nov 2026 09:05:03 GMT"),
        (Int64(1796115903), "Tue, 01 Dec 2026 09:05:03 GMT"),
    ]
    for f in firsts:
        assert_equal(http_date_from_unix(f[0]), String(f[1]))


def test_now_is_the_current_second_in_the_same_shape() raises:
    """`http_date_now` is `http_date_from_unix(unix_now())`: 29 bytes, GMT."""
    var before = unix_now()
    var now = http_date_now()
    var after = unix_now()
    assert_equal(now.byte_length(), 29)
    assert_true(now.endswith(" GMT"))
    assert_true(
        now == http_date_from_unix(before) or now == http_date_from_unix(after)
    )


def _libc_gmtime(t: Int64) -> Pointer[Int32, MutUntrackedOrigin]:
    """The `struct tm` libc's own `gmtime` fills and returns.

    On glibc that is one static struct for the whole process; on macOS, one
    per thread. Either way it is the buffer every other `gmtime` caller on
    this thread writes, which is what the next test watches. Declared with
    exactly the signature `date.mojo` used for `gmtime`, the only other
    declaration there has ever been.
    """
    var t_ptr = unsafe_alloc[Int64](count=1)
    t_ptr[] = t
    var tm_opt = external_call[
        "gmtime",
        OptionalPointer[Int32, MutUntrackedOrigin],
        Pointer[Int64, MutUntrackedOrigin],
    ](t_ptr)
    t_ptr.unsafe_free()
    return tm_opt.value()


def test_formatting_writes_no_buffer_libc_shares() raises:
    """The formatter fills a `struct tm` of its own, never libc's.

    glibc's `gmtime` returns ONE static `struct tm` for the whole process.
    Every loop formats its own Date header, and under `M0_THREADS` or
    `--threads` the loops are threads of one process, so a formatter on
    `gmtime` could read the fields another loop had just written: a Date
    torn across a second's boundary. The property that rules the race out
    is that the formatter never writes that buffer: fill it with 1970
    through `gmtime` itself, format 2023, and 1970 must still be there.
    Deterministic, and on macOS too, where `gmtime`'s buffer is per thread
    and so the one this thread's formatting would overwrite.
    """
    var shared = _libc_gmtime(0)  # Thu, 01 Jan 1970 00:00:00
    assert_equal(Int(shared[unsafe_offset=5]), 70)
    assert_equal(
        http_date_from_unix(1700000000), "Tue, 14 Nov 2023 22:13:20 GMT"
    )
    # sec, min, hour, mday, mon, year - 1900, wday: every field still 1970's.
    var want = [0, 0, 0, 1, 0, 70, 4]
    for i in range(7):
        assert_equal(Int(shared[unsafe_offset=i]), want[i])


comptime _ROUNDS = 20_000
"""Formats per thread in the race below."""

comptime _BLK_WANT = 10
"""Block slot: the address of the String this thread must get every time."""
comptime _BLK_TIME = 11
"""Block slot: the instant this thread formats."""
comptime _BLK_WRONG = 12
"""Block slot, written by the thread: how many formats were not `want`."""


def _format_repeatedly(arg: Int) -> Int:
    """Thread body: format one instant `_ROUNDS` times, counting wrong answers."""
    var block = ThreadBlock(arg)
    var want = Pointer[String, MutUntrackedOrigin](
        unsafe_from_address=block.get(_BLK_WANT)
    )
    var t = Int64(block.get(_BLK_TIME))
    var wrong = 0
    for _ in range(_ROUNDS):
        if http_date_from_unix(t) != want[]:
            wrong += 1
    block.set(_BLK_WRONG, wrong)
    block.set(BLK_STATUS, STATUS_OK)
    return 0


def test_loops_on_threads_format_their_own_dates() raises:
    """Four threads format four instants at once, and none sees another's.

    Each instant differs from the others in every field, so a `struct tm`
    shared between the threads -- glibc's `gmtime` -- reads as a wrong
    answer on any thread whose fields were overwritten between the call
    and the read. Only glibc shares one, so this can fail on Linux alone;
    the test above is the gate that fails everywhere.
    """
    var times = [
        Int64(0),  # Thu, 01 Jan 1970 00:00:00
        Int64(1700000000),  # Tue, 14 Nov 2023 22:13:20
        Int64(784111777),  # Sun, 06 Nov 1994 08:49:37
        Int64(4102444799),  # Thu, 31 Dec 2099 23:59:59
    ]
    # Formatted alone, before any thread starts; the known-answer test above
    # holds these to the right strings.
    var wants = List[String]()
    for t in times:
        wants.append(http_date_from_unix(t))
    var threads = ThreadSet(4)
    for i in range(4):
        var want_ptr = Pointer(to=wants[i])
        threads.block(i).set(
            _BLK_WANT, Pointer(to=want_ptr).unsafe_bitcast[Int]()[]
        )
        threads.block(i).set(_BLK_TIME, Int(times[i]))
    var body = _format_repeatedly
    var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
    for i in range(4):
        threads.spawn(i, body_addr)
    threads.join_all()
    # The threads read `wants` through bare addresses, which do not keep it
    # alive; this does, until every thread has been joined.
    _ = wants
    assert_true(threads.all_ok())
    for i in range(4):
        assert_equal(threads.block(i).get(BLK_INDEX), i)
        assert_equal(threads.block(i).get(_BLK_WRONG), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
