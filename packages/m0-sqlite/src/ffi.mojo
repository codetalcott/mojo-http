"""Raw SQLite C-API surface: constants, string marshalling, version probe.

Everything that touches `external_call` directly lives here so `conn.mojo` and
`stmt.mojo` read as ordinary Mojo. Seeded from a benchmark binding written
against Mojo 1.0.0 / SQLite 3.51.0.

Three facts that shape this whole package:

  - **libsqlite3 needs no link flags on macOS**, because libsqlite3.dylib lives
    in the dyld shared cache and `external_call` resolves against it. On Linux
    the library must be present at link time; see the README.

  - **Mojo 1.0 pointers are non-null by design**, so a NULL argument cannot be
    written `UnsafePointer[T]()`. `sqlite3*` and `sqlite3_stmt*` are carried as
    opaque `Int` addresses with `Int(0)` for NULL. That is also the honest
    representation — they are opaque to us.

  - **Mojo's `String` does not guarantee a NUL terminator.** See `c_string`.
"""

from std.collections.span import Span
from std.ffi import external_call, c_int
from std.memory import UnsafePointer

# --- Result codes ---
comptime SQLITE_OK: Int = 0
comptime SQLITE_ERROR: Int = 1
comptime SQLITE_BUSY: Int = 5
comptime SQLITE_MISUSE: Int = 21
comptime SQLITE_ROW: Int = 100
comptime SQLITE_DONE: Int = 101

# --- Open flags ---
comptime SQLITE_OPEN_READONLY: Int = 0x00000001
comptime SQLITE_OPEN_READWRITE: Int = 0x00000002
comptime SQLITE_OPEN_CREATE: Int = 0x00000004
comptime SQLITE_OPEN_FULLMUTEX: Int = 0x00010000
comptime SQLITE_OPEN_NOMUTEX: Int = 0x00008000

# --- Column types, as returned by sqlite3_column_type ---
comptime SQLITE_INTEGER: Int = 1
comptime SQLITE_FLOAT: Int = 2
comptime SQLITE_TEXT: Int = 3
comptime SQLITE_BLOB: Int = 4
comptime SQLITE_NULL: Int = 5

# sqlite3_bind_text/blob destructor sentinel: copy the buffer immediately.
# Passing -1 (SQLITE_TRANSIENT) means SQLite makes its own copy, so the Mojo
# buffer does not need to outlive the call.
comptime SQLITE_TRANSIENT: Int = -1

comptime CharPtr = UnsafePointer[UInt8, MutAnyOrigin]

comptime MAX_C_INT: Int = 2147483647
"""Largest length expressible in the `int` parameters SQLite takes.

Lengths are passed to `sqlite3_bind_text`, `sqlite3_bind_blob` and
`sqlite3_prepare_v2` as C `int`. Past this, the cast wraps negative — and a
negative length is not merely wrong, it is *meaningful*: `sqlite3_bind_text`
reads it as "scan to the first NUL", on a Mojo `String` that has no guaranteed
NUL. The read then runs off the end of the buffer. Callers get an error
instead.
"""


def check_c_int_length(what: String, length: Int) raises:
    """Reject a length that would wrap when narrowed to C `int`."""
    if length > MAX_C_INT:
        raise Error(
            "sqlite3_"
            + what
            + ": "
            + String(length)
            + " bytes exceeds the "
            + String(MAX_C_INT)
            + "-byte limit of SQLite's int length parameter"
        )


def cstr_to_string(p: CharPtr, length: Int) -> String:
    """Build a String from a pointer plus an explicit length.

    Length-driven rather than NUL-scanning, so it neither depends on SQLite's
    termination nor rescans a string whose length SQLite already told us.
    """
    if length <= 0:
        return String("")
    return String(unsafe_from_utf8=Span(unsafe_ptr=p, length=length))


def cstr_len(p: CharPtr) -> Int:
    """Length of a NUL-terminated C string, for APIs that report no length."""
    var n = 0
    while p[unsafe_offset=n] != 0:
        n += 1
    return n


def c_string(s: String) -> List[UInt8]:
    """Copy a String into an explicitly NUL-terminated byte buffer.

    Mojo's `String` does NOT guarantee a NUL byte past its logical end.
    Measured on Mojo 1.0.0: for `String(".bench-tmp") + "/tasks_" + String(500)
    + ".db"` the byte at `[byte_length()]` is 151, not 0. Handing `unsafe_ptr()`
    to a C API expecting a C string therefore reads past the end into arbitrary
    heap memory. The failure surfaces far from its cause and looks
    nondeterministic — it first appeared as `SQLITE_CANTOPEN` on one fixture
    size but not another, because whether a stray NUL happened to follow
    depended on allocation layout.

    Every entry point taking a string *without* a companion length must go
    through this. Entry points that take an explicit length
    (`sqlite3_prepare_v2`, `sqlite3_bind_text`) pass one and do not need it.

    The buffer must outlive the C call: bind it to a local, never write
    `c_string(x).unsafe_ptr()` inline.
    """
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b) + 1)
    out.extend(b)  # bulk copy: a byte-at-a-time loop here cost 40x at 4 KB
    out.append(0)
    return out^


def libversion() -> String:
    """SQLite library version, e.g. "3.51.0".

    Doubles as the cheapest possible link check: if libsqlite3 is not resolvable
    this is where it fails, before any database is touched.
    """
    var p = external_call["sqlite3_libversion", CharPtr]()
    return cstr_to_string(p, cstr_len(p))


def libversion_number() -> Int:
    """SQLite library version as an integer, e.g. 3045001 for "3.45.1".

    Encoded by SQLite as major*1000000 + minor*1000 + patch, which is what
    makes it comparable — the string form is not.
    """
    return Int(external_call["sqlite3_libversion_number", c_int]())


def errstr(code: Int) -> String:
    """English text for a primary result code, independent of any connection."""
    var p = external_call["sqlite3_errstr", CharPtr](c_int(code))
    return cstr_to_string(p, cstr_len(p))


def db_errmsg(db_handle: Int) -> String:
    """Text of the most recent error on a connection handle.

    Far more specific than `errstr`, which only knows the result code:
    "UNIQUE constraint failed: users.name" versus "constraint failed".
    """
    if db_handle == 0:
        return String("")
    var p = external_call["sqlite3_errmsg", CharPtr](db_handle)
    return cstr_to_string(p, cstr_len(p))


def db_errcode(db_handle: Int) -> Int:
    """Result code of the most recent failed API call on a connection."""
    if db_handle == 0:
        return SQLITE_OK
    return Int(external_call["sqlite3_errcode", c_int](db_handle))


def stmt_errmsg(stmt_handle: Int, rc: Int) -> String:
    """Message for `rc` from the connection owning a statement, or "" if unsure.

    `sqlite3_db_handle` recovers the owning `sqlite3*` from the statement, so
    `Statement` gets SQLite's real message without storing a connection handle
    and without any question about which of the two owns the other.

    The corroboration check is not paranoia. Mojo destroys a value at its last
    use, so a `Connection` whose last mention was `prepare()` is already closed
    by the time the statement fails — the statement keeps working (close_v2
    leaves the connection alive until its statements finalize) but the closed
    connection answers SQLITE_MISUSE to every question. Reporting that would
    turn a true "UNIQUE constraint failed: u.name" into a false "bad parameter
    or other API misuse". So the message is used only when the connection's own
    error code agrees with the code being described; otherwise the caller falls
    back to `errstr`, which is less specific but always true.
    """
    if stmt_handle == 0:
        return String("")
    var db = external_call["sqlite3_db_handle", Int](stmt_handle)
    if db_errcode(db) != rc:
        return String("")
    return db_errmsg(db)


def describe(what: String, rc: Int, detail: String) -> String:
    """Uniform error text: SQLite's own message when it has one, else the code.

    `sqlite3_errmsg` reports "not an error" when nothing failed on the
    connection, which is worse than useless in an error message, so that case
    falls back to `errstr` too.
    """
    var msg = detail
    if len(msg.as_bytes()) == 0 or msg == "not an error":
        msg = errstr(rc)
    return "sqlite3_" + what + " failed: " + msg + " (rc=" + String(rc) + ")"


def error_code(message: String) -> Int:
    """The SQLite result code carried by an error raised from this package.

    Every error that had a result code available ends in "(rc=NN)"; this
    recovers the NN, or returns -1 when the message carries none. It exists
    because a Mojo `Error` is only text, and branching on the code — retry on
    SQLITE_BUSY (5), report a constraint violation (19) — should not require
    every caller to reinvent this parse:

        try:
            db.begin_immediate()
        except e:
            if error_code(String(e)) == SQLITE_BUSY:
                ...
    """
    var b = message.as_bytes()
    var n = len(b)
    if n < 6 or b[n - 1] != 41:  # ')'
        return -1
    var i = n - 2
    var value = 0
    var scale = 1
    var digits = 0
    while i >= 0 and b[i] >= 48 and b[i] <= 57:
        value += Int(b[i] - 48) * scale
        scale *= 10
        digits += 1
        i -= 1
    if digits == 0 or i < 3:
        return -1
    # The digits must be introduced by exactly "(rc=".
    if b[i] != 61 or b[i - 1] != 99 or b[i - 2] != 114 or b[i - 3] != 40:
        return -1
    return value
