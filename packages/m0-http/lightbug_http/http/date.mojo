"""HTTP date formatting utilities (RFC 7231 Section 7.1.1.1).

Uses POSIX time/gmtime instead of small_time dependency.
"""

from std.ffi import external_call


fn http_date_now() -> String:
    """Get current time formatted as HTTP date.

    Returns:
        Current time in HTTP date format (IMF-fixdate).
        Format: Day, DD Mon YYYY HH:MM:SS GMT
    """
    # Get current time via POSIX time(NULL) — pass 0 as the pointer arg
    var t = external_call["time", Int64, Int64](0)

    # Allocate space for the time value
    var t_ptr = alloc[Int64](count=1)
    t_ptr[] = t

    # gmtime returns a pointer to struct tm
    var tm_ptr = external_call[
        "gmtime",
        UnsafePointer[Int32, MutExternalOrigin],
        UnsafePointer[Int64, MutExternalOrigin],
    ](t_ptr)

    t_ptr.free()

    if not tm_ptr:
        return "Thu, 01 Jan 1970 00:00:00 GMT"

    # struct tm fields (all Int32):
    # [0] tm_sec, [1] tm_min, [2] tm_hour, [3] tm_mday,
    # [4] tm_mon (0-11), [5] tm_year (years since 1900),
    # [6] tm_wday (0=Sunday)
    var sec = Int(tm_ptr[0])
    var minute = Int(tm_ptr[1])
    var hour = Int(tm_ptr[2])
    var day = Int(tm_ptr[3])
    var mon = Int(tm_ptr[4])  # 0-based
    var year = Int(tm_ptr[5]) + 1900
    var wday = Int(tm_ptr[6])

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
