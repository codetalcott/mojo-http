"""HTTP date formatting utilities (RFC 9110 Section 5.6.7).

Uses POSIX time/gmtime instead of small_time dependency.
"""

from std.ffi import external_call
from std.memory.alloc import unsafe_alloc


def unix_now() -> Int64:
    """Current wall-clock time as Unix seconds (POSIX time(NULL), vDSO-fast)."""
    return external_call["time", Int64, Int64](0)


def http_date_now() -> String:
    """Get current time formatted as HTTP date.

    Returns:
        Current time in HTTP date format (IMF-fixdate).
        Format: Day, DD Mon YYYY HH:MM:SS GMT
    """
    return http_date_from_unix(unix_now())


def http_date_from_unix(t: Int64) -> String:
    """Format a Unix timestamp as an HTTP date (IMF-fixdate).

    Split out from http_date_now so the event loop can format once per
    second and reuse the string — formatting costs ~10 small String
    allocations plus gmtime, which is measurable at request rate.
    """
    # Allocate space for the time value
    # Freed below; `unsafe_alloc` is the non-Layout allocator (std.memory.alloc).
    var t_ptr = unsafe_alloc[Int64](count=1)
    t_ptr[] = t

    # gmtime returns a pointer to struct tm
    # gmtime() returns NULL on failure, so bind the result as an
    # OptionalPointer — Pointer is non-null by design and Bool(ptr)
    # is no longer meaningful. Optional has the same layout, with None as the
    # null niche, so this stays ABI-compatible with the C signature.
    var tm_opt = external_call[
        "gmtime",
        OptionalPointer[Int32, MutUntrackedOrigin],
        Pointer[Int64, MutUntrackedOrigin],
    ](t_ptr)

    t_ptr.unsafe_free()

    if tm_opt is None:
        return "Thu, 01 Jan 1970 00:00:00 GMT"
    var tm_ptr = tm_opt.value()

    # struct tm fields (all Int32):
    # [0] tm_sec, [1] tm_min, [2] tm_hour, [3] tm_mday,
    # [4] tm_mon (0-11), [5] tm_year (years since 1900),
    # [6] tm_wday (0=Sunday)
    var sec = Int(tm_ptr[unsafe_offset=0])
    var minute = Int(tm_ptr[unsafe_offset=1])
    var hour = Int(tm_ptr[unsafe_offset=2])
    var day = Int(tm_ptr[unsafe_offset=3])
    var mon = Int(tm_ptr[unsafe_offset=4])  # 0-based
    var year = Int(tm_ptr[unsafe_offset=5]) + 1900
    var wday = Int(tm_ptr[unsafe_offset=6])

    # Day-of-week names
    var wday_str: String
    if wday == 0:
        wday_str = "Sun"
    elif wday == 1:
        wday_str = "Mon"
    elif wday == 2:
        wday_str = "Tue"
    elif wday == 3:
        wday_str = "Wed"
    elif wday == 4:
        wday_str = "Thu"
    elif wday == 5:
        wday_str = "Fri"
    else:
        wday_str = "Sat"

    # Month names (0-based)
    var mon_str: String
    if mon == 0:
        mon_str = "Jan"
    elif mon == 1:
        mon_str = "Feb"
    elif mon == 2:
        mon_str = "Mar"
    elif mon == 3:
        mon_str = "Apr"
    elif mon == 4:
        mon_str = "May"
    elif mon == 5:
        mon_str = "Jun"
    elif mon == 6:
        mon_str = "Jul"
    elif mon == 7:
        mon_str = "Aug"
    elif mon == 8:
        mon_str = "Sep"
    elif mon == 9:
        mon_str = "Oct"
    elif mon == 10:
        mon_str = "Nov"
    else:
        mon_str = "Dec"

    # Zero-pad
    var day_str = String(day) if day >= 10 else String("0", day)
    var hour_str = String(hour) if hour >= 10 else String("0", hour)
    var min_str = String(minute) if minute >= 10 else String("0", minute)
    var sec_str = String(sec) if sec >= 10 else String("0", sec)

    return String(
        wday_str,
        ", ",
        day_str,
        " ",
        mon_str,
        " ",
        String(year),
        " ",
        hour_str,
        ":",
        min_str,
        ":",
        sec_str,
        " GMT",
    )
