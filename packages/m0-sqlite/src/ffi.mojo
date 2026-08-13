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
    for i in range(len(b)):
        out.append(b[i])
    out.append(0)
    return out^


def libversion() -> String:
    """SQLite library version, e.g. "3.51.0".

    Doubles as the cheapest possible link check: if libsqlite3 is not resolvable
    this is where it fails, before any database is touched.
    """
    var p = external_call["sqlite3_libversion", CharPtr]()
    return cstr_to_string(p, cstr_len(p))


def errstr(code: Int) -> String:
    """English text for a primary result code, independent of any connection."""
    var p = external_call["sqlite3_errstr", CharPtr](c_int(code))
    return cstr_to_string(p, cstr_len(p))
