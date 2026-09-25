"""The libsqlite3 loader: the handle, every entry point, and the three
lifetime rules that hold them together.

Until 2026-09-25 this package reached SQLite through `external_call`, which
put `libsqlite3` on the link line of every binary that used it — no flag on
macOS, where the dyld shared cache resolves it, and `-Xlinker -lsqlite3`
plus `libsqlite3-dev` on Linux. Two things wanted that gone. `m0 build`
takes no link flags (DECISIONS D40), so an application built with the `m0`
wheel could not use this package at all. And `mojo run` resolves symbols
only from libraries already in its process, so on Linux every test here had
to be built and run rather than run — the shape `m0 test` cannot take.
Loading the library the way `m0-postgres` loads libpq answers both: no
binary links it, and a JIT'd test opens it like any other process.

The shape is `m0-postgres/src/lib.mojo`'s, and its three rules — each
found there by crashing — are adopted here up front:

  - **The handle and the pointers loaded from it live in ONE struct.** A
    `thin` pointer loaded from a handle carries no borrow, so an
    `OwnedDLHandle` held anywhere else is `dlclose`d at its last mention
    and the next call jumps into unmapped memory. `SqliteLib` holds both.

  - **A `thin` pointer FIELD is called only from a method beside it.** The
    same pointer, identical by address, faults when called as
    `table.field()` from outside its struct and answers correctly from a
    method next to it (measured on this toolchain, in m0-postgres). So every
    entry point is private behind a wrapper, and nothing outside this file
    calls one.

  - **The library is never unloaded once opened.** `SqliteLib.__init__`
    re-opens the image with `RTLD_NODELETE` (`pin_library`), so no
    `dlclose` unmaps it. That is what makes it sound for a `Statement` to
    hold a COPY of the entry points it calls (`StmtLib`) and outlive the
    `Connection` — and the handle — that loaded them: Mojo destroys a
    connection at its last use, routinely the `prepare()` itself (O2), and
    without the pin the statement's next `step` would call into memory the
    connection's `dlclose` had just unmapped. The virtual-table callbacks
    hold a copy the same way (`VtabLib`), in the buffer SQLite owns.

Each `Connection` opens its own table: a `dlopen` of an already-mapped image
is a reference count and ~41 `dlsym`s, paid once per connection, which this
package opens once per thread. A call through a stored pointer then costs
what a direct call does.

Every entry point goes through `_checked`, which asks `check_symbol` before
`load` — `load` ABORTS the process on a missing symbol — so a libsqlite3
too old, or a library that is not libsqlite3 at all, is an error naming the
symbol. Checking and loading in one place, taking the name from the
declaration, is what keeps the two from drifting.
"""

from std.collections.span import Span
from std.ffi import OwnedDLHandle, c_int
from std.memory import Pointer
from std.os import getenv
from std.python._cpython import ExternalFunction
from std.sys import CompilationTarget

from .ffi import CharPtr, cstr_len, cstr_to_string


comptime CStr = Pointer[UInt8, ImmutAnyOrigin]
"""A `const char *` argument: typed, so the buffer outlives the call."""

comptime FreeFn = def (Int) thin abi("C") -> None
"""`void (*)(void *)`: the destructor SQLite takes for a buffer it owns."""

comptime MIN_SQLITE_VERSION: Int = 3_020_000
"""SQLite 3.20.0, the floor: `sqlite3_bind_pointer` arrived there, and the
table below loads it whole. The virtual table asks for 3.26.0 on top
(`SQLITE_MIN_VTAB_VERSION`), at registration, for the planner contract it
depends on. Checked at open, where the version is a number and the error
can name the library, rather than discovered as a missing symbol."""


def as_cstr(ref buf: List[UInt8]) -> CStr:
    """A typed `const char *` over a buffer the caller holds.

    Typed rather than `Int(...)`: an integer argument erases the origin and
    the buffer is freed before the call.
    """
    return buf.unsafe_ptr().as_imm().as_unsafe_any_origin()


def str_cstr(ref s: String) -> CStr:
    """`as_cstr` for a `String`'s bytes — for the entry points that take an
    explicit length and so need no NUL."""
    return s.unsafe_ptr().as_imm().as_unsafe_any_origin()


# --- The C signatures ------------------------------------------------------
#
# Opaque handles (`sqlite3 *`, `sqlite3_stmt *`, `sqlite3_value *`,
# `sqlite3_context *`) and out-parameters as Int; buffers as CStr; text that
# SQLite owns comes back as an Int address and is read through `CharPtr`.
# Each is the declaration sqlite3.h carries, transcribed.

comptime _libversion = ExternalFunction[
    "sqlite3_libversion", def () thin abi("C") -> Int
]
comptime _libversion_number = ExternalFunction[
    "sqlite3_libversion_number", def () thin abi("C") -> c_int
]
comptime _threadsafe = ExternalFunction[
    "sqlite3_threadsafe", def () thin abi("C") -> c_int
]
comptime _errstr = ExternalFunction[
    "sqlite3_errstr", def (c_int) thin abi("C") -> Int
]
comptime _errmsg = ExternalFunction[
    "sqlite3_errmsg", def (Int) thin abi("C") -> Int
]
comptime _errcode = ExternalFunction[
    "sqlite3_errcode", def (Int) thin abi("C") -> c_int
]
comptime _db_handle = ExternalFunction[
    "sqlite3_db_handle", def (Int) thin abi("C") -> Int
]
comptime _open_v2 = ExternalFunction[
    # int sqlite3_open_v2(const char *, sqlite3 **, int flags, const char *zVfs)
    "sqlite3_open_v2", def (CStr, Int, c_int, Int) thin abi("C") -> c_int
]
comptime _close_v2 = ExternalFunction[
    "sqlite3_close_v2", def (Int) thin abi("C") -> c_int
]
comptime _exec = ExternalFunction[
    # int sqlite3_exec(sqlite3 *, const char *sql, callback, void *, char **errmsg)
    "sqlite3_exec", def (Int, CStr, Int, Int, Int) thin abi("C") -> c_int
]
comptime _prepare_v2 = ExternalFunction[
    # int sqlite3_prepare_v2(sqlite3 *, const char *, int nByte, sqlite3_stmt **, const char **tail)
    "sqlite3_prepare_v2", def (Int, CStr, c_int, Int, Int) thin abi("C") -> c_int
]
comptime _finalize = ExternalFunction[
    "sqlite3_finalize", def (Int) thin abi("C") -> c_int
]
comptime _get_autocommit = ExternalFunction[
    "sqlite3_get_autocommit", def (Int) thin abi("C") -> c_int
]
comptime _last_insert_rowid = ExternalFunction[
    "sqlite3_last_insert_rowid", def (Int) thin abi("C") -> Int64
]
comptime _changes = ExternalFunction[
    "sqlite3_changes", def (Int) thin abi("C") -> c_int
]
comptime _total_changes = ExternalFunction[
    "sqlite3_total_changes", def (Int) thin abi("C") -> c_int
]
comptime _busy_timeout = ExternalFunction[
    "sqlite3_busy_timeout", def (Int, c_int) thin abi("C") -> c_int
]
comptime _bind_int64 = ExternalFunction[
    "sqlite3_bind_int64", def (Int, c_int, Int64) thin abi("C") -> c_int
]
comptime _bind_double = ExternalFunction[
    "sqlite3_bind_double", def (Int, c_int, Float64) thin abi("C") -> c_int
]
comptime _bind_text = ExternalFunction[
    # int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int n, void (*)(void *))
    "sqlite3_bind_text", def (Int, c_int, CStr, c_int, Int) thin abi("C") -> c_int
]
comptime _bind_blob = ExternalFunction[
    "sqlite3_bind_blob", def (Int, c_int, CStr, c_int, Int) thin abi("C") -> c_int
]
comptime _bind_null = ExternalFunction[
    "sqlite3_bind_null", def (Int, c_int) thin abi("C") -> c_int
]
comptime _bind_pointer = ExternalFunction[
    # int sqlite3_bind_pointer(sqlite3_stmt *, int, void *, const char *type, void (*)(void *))
    "sqlite3_bind_pointer", def (Int, c_int, Int, CStr, FreeFn) thin abi("C") -> c_int
]
comptime _step = ExternalFunction["sqlite3_step", def (Int) thin abi("C") -> c_int]
comptime _reset = ExternalFunction["sqlite3_reset", def (Int) thin abi("C") -> c_int]
comptime _clear_bindings = ExternalFunction[
    "sqlite3_clear_bindings", def (Int) thin abi("C") -> c_int
]
comptime _column_count = ExternalFunction[
    "sqlite3_column_count", def (Int) thin abi("C") -> c_int
]
comptime _column_type = ExternalFunction[
    "sqlite3_column_type", def (Int, c_int) thin abi("C") -> c_int
]
comptime _column_int64 = ExternalFunction[
    "sqlite3_column_int64", def (Int, c_int) thin abi("C") -> Int64
]
comptime _column_double = ExternalFunction[
    "sqlite3_column_double", def (Int, c_int) thin abi("C") -> Float64
]
comptime _column_text = ExternalFunction[
    "sqlite3_column_text", def (Int, c_int) thin abi("C") -> Int
]
comptime _column_blob = ExternalFunction[
    "sqlite3_column_blob", def (Int, c_int) thin abi("C") -> Int
]
comptime _column_bytes = ExternalFunction[
    "sqlite3_column_bytes", def (Int, c_int) thin abi("C") -> c_int
]
comptime _column_name = ExternalFunction[
    "sqlite3_column_name", def (Int, c_int) thin abi("C") -> Int
]
comptime _declare_vtab = ExternalFunction[
    "sqlite3_declare_vtab", def (Int, CStr) thin abi("C") -> c_int
]
comptime _malloc64 = ExternalFunction[
    "sqlite3_malloc64", def (Int64) thin abi("C") -> Int
]
comptime _free = ExternalFunction["sqlite3_free", def (Int) thin abi("C") -> None]
comptime _value_pointer = ExternalFunction[
    "sqlite3_value_pointer", def (Int, CStr) thin abi("C") -> Int
]
comptime _result_null = ExternalFunction[
    "sqlite3_result_null", def (Int) thin abi("C") -> None
]
comptime _result_double = ExternalFunction[
    "sqlite3_result_double", def (Int, Float64) thin abi("C") -> None
]
comptime _result_int64 = ExternalFunction[
    "sqlite3_result_int64", def (Int, Int64) thin abi("C") -> None
]
comptime _create_module_v2 = ExternalFunction[
    # int sqlite3_create_module_v2(sqlite3 *, const char *, const sqlite3_module *, void *pAux, void (*xDestroy)(void *))
    "sqlite3_create_module_v2", def (Int, CStr, Int, Int, FreeFn) thin abi("C") -> c_int
]


def _pin_flags() -> Int:
    """`RTLD_LAZY | RTLD_GLOBAL | RTLD_NODELETE`, the mode the pin re-opens with.

    m0-postgres's measurement, kept as written there: glibc refuses a mode
    carrying neither `RTLD_LAZY` (1) nor `RTLD_NOW` (2), and `RTLD_NODELETE`
    is 0x1000 in glibc's `dlfcn.h` and 0x80 in macOS's. Both loaders promote
    an already-loaded image to it on a re-open. Lazy, because this is a
    re-open of an image already mapped and asks for nothing the first open
    did not.
    """
    comptime if CompilationTarget.is_macos():
        return 1 | 8 | 0x80
    else:
        return 1 | 256 | 0x1000


def pin_library(path: String) raises:
    """Keep the library at `path` loaded for the life of the process.

    A second `dlopen` of the image the caller already holds, flagged
    `RTLD_NODELETE`: from then on no `dlclose` unmaps it, this handle's own
    included, so the handle is let go at once and what remains is the flag.
    The module docstring's third rule says why this exists: without it a
    `Statement` outliving its `Connection` — the shape O2 promises — steps
    into memory the connection's handle unmapped.
    """
    try:
        var pin = OwnedDLHandle(path, _pin_flags())
        _ = pin.check_symbol("sqlite3_libversion")
    except e:
        raise Error(
            "the library at " + path + " opened once and could not be"
            " pinned for the life of the process (" + String(e) + "); a"
            " statement stepped after its connection closed would call into"
            " unloaded code"
        )


def _checked[
    name: StaticString, T: TrivialRegisterPassable
](ref handle: OwnedDLHandle, path: String) raises -> T:
    """Resolve one entry point, or raise naming the symbol that is missing.

    `ExternalFunction.load` ABORTS the process on a missing symbol — it is
    statically non-raising, so a `try` around it is dead code the compiler
    says so about — and a libsqlite3 too old, or a library that is not
    libsqlite3 at all, must be an error naming the symbol rather than a
    stack trace with no cause in it. `check_symbol` is the question that
    can be answered. Checking and loading in ONE place, the name taken
    from the declaration, is what keeps checked-but-not-loaded and
    loaded-but-not-checked unspellable.
    """
    if not handle.check_symbol(name):
        raise Error(
            "the library at " + path + " has no symbol `" + String(name)
            + "` — this is either not libsqlite3, or a libsqlite3 older"
            " than 3.20.0, the oldest this package supports"
        )
    return ExternalFunction[name, T].load(handle.borrow())


def default_search_path() -> List[String]:
    """Where to look for libsqlite3 when `M0_LIBSQLITE3` does not say.

    Bare names first: the loader finds a system library by name, on macOS
    from the dyld shared cache and on Linux through `ld.so`'s cache, and the
    rest of this list never runs. Then the places a package manager puts a
    newer build. The whole list appears in the error when none of them
    opens, because "libsqlite3 not found" without the paths tried is the
    least actionable message a server can print.
    """
    var out = List[String]()
    comptime if CompilationTarget.is_macos():
        out.append("libsqlite3.dylib")
        out.append("/usr/lib/libsqlite3.dylib")
        out.append("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib")
        out.append("/usr/local/opt/sqlite/lib/libsqlite3.dylib")
    else:
        out.append("libsqlite3.so.0")
        out.append("/usr/lib/x86_64-linux-gnu/libsqlite3.so.0")
        out.append("/usr/lib/aarch64-linux-gnu/libsqlite3.so.0")
        out.append("/usr/lib64/libsqlite3.so.0")
        out.append("/usr/local/lib/libsqlite3.so.0")
    return out^


struct SqliteLib(Movable):
    """An open libsqlite3 and every entry point this package uses.

    One struct on purpose: the module docstring's first rule. The handle
    must outlive every call made through the pointers beside it, and the
    only way to say that in Mojo — where a loaded pointer carries no borrow
    — is to give them the same lifetime. A `Connection` holds one; a
    `Statement` holds the copy `stmt_lib` cuts from it, which the pin makes
    sound.
    """

    var _lib: OwnedDLHandle
    """First field, and the reason this struct exists."""

    var path: String
    """Which file was opened — reported, never guessed at."""

    var _libversion: _libversion.type
    var _libversion_number: _libversion_number.type
    var _threadsafe: _threadsafe.type
    var _errstr: _errstr.type
    var _errmsg: _errmsg.type
    var _errcode: _errcode.type
    var _db_handle: _db_handle.type
    var _open_v2: _open_v2.type
    var _close_v2: _close_v2.type
    var _exec: _exec.type
    var _prepare_v2: _prepare_v2.type
    var _finalize: _finalize.type
    var _get_autocommit: _get_autocommit.type
    var _last_insert_rowid: _last_insert_rowid.type
    var _changes: _changes.type
    var _total_changes: _total_changes.type
    var _busy_timeout: _busy_timeout.type
    var _bind_int64: _bind_int64.type
    var _bind_double: _bind_double.type
    var _bind_text: _bind_text.type
    var _bind_blob: _bind_blob.type
    var _bind_null: _bind_null.type
    var _bind_pointer: _bind_pointer.type
    var _step: _step.type
    var _reset: _reset.type
    var _clear_bindings: _clear_bindings.type
    var _column_count: _column_count.type
    var _column_type: _column_type.type
    var _column_int64: _column_int64.type
    var _column_double: _column_double.type
    var _column_text: _column_text.type
    var _column_blob: _column_blob.type
    var _column_bytes: _column_bytes.type
    var _column_name: _column_name.type
    var _declare_vtab: _declare_vtab.type
    var _malloc64: _malloc64.type
    var _free: _free.type
    var _value_pointer: _value_pointer.type
    var _result_null: _result_null.type
    var _result_double: _result_double.type
    var _result_int64: _result_int64.type
    var _create_module_v2: _create_module_v2.type
    """Every entry point, private: the module docstring's second rule."""

    def __init__(out self, var handle: OwnedDLHandle, var path: String) raises:
        """Resolve every entry point from an already-open handle.

        Private in effect: `open_library` is the constructor callers use.
        The pin comes first, so no path out of this constructor leaves a
        table whose library can be unmapped under it; `path` and `_lib`
        are assigned last, so a missing symbol leaves no table to half-own.
        """
        pin_library(path)
        self._libversion = _checked[_libversion.name, _libversion.type](handle, path)
        self._libversion_number = _checked[
            _libversion_number.name, _libversion_number.type
        ](handle, path)
        self._threadsafe = _checked[_threadsafe.name, _threadsafe.type](handle, path)
        self._errstr = _checked[_errstr.name, _errstr.type](handle, path)
        self._errmsg = _checked[_errmsg.name, _errmsg.type](handle, path)
        self._errcode = _checked[_errcode.name, _errcode.type](handle, path)
        self._db_handle = _checked[_db_handle.name, _db_handle.type](handle, path)
        self._open_v2 = _checked[_open_v2.name, _open_v2.type](handle, path)
        self._close_v2 = _checked[_close_v2.name, _close_v2.type](handle, path)
        self._exec = _checked[_exec.name, _exec.type](handle, path)
        self._prepare_v2 = _checked[_prepare_v2.name, _prepare_v2.type](handle, path)
        self._finalize = _checked[_finalize.name, _finalize.type](handle, path)
        self._get_autocommit = _checked[
            _get_autocommit.name, _get_autocommit.type
        ](handle, path)
        self._last_insert_rowid = _checked[
            _last_insert_rowid.name, _last_insert_rowid.type
        ](handle, path)
        self._changes = _checked[_changes.name, _changes.type](handle, path)
        self._total_changes = _checked[
            _total_changes.name, _total_changes.type
        ](handle, path)
        self._busy_timeout = _checked[_busy_timeout.name, _busy_timeout.type](handle, path)
        self._bind_int64 = _checked[_bind_int64.name, _bind_int64.type](handle, path)
        self._bind_double = _checked[_bind_double.name, _bind_double.type](handle, path)
        self._bind_text = _checked[_bind_text.name, _bind_text.type](handle, path)
        self._bind_blob = _checked[_bind_blob.name, _bind_blob.type](handle, path)
        self._bind_null = _checked[_bind_null.name, _bind_null.type](handle, path)
        self._bind_pointer = _checked[_bind_pointer.name, _bind_pointer.type](handle, path)
        self._step = _checked[_step.name, _step.type](handle, path)
        self._reset = _checked[_reset.name, _reset.type](handle, path)
        self._clear_bindings = _checked[
            _clear_bindings.name, _clear_bindings.type
        ](handle, path)
        self._column_count = _checked[_column_count.name, _column_count.type](handle, path)
        self._column_type = _checked[_column_type.name, _column_type.type](handle, path)
        self._column_int64 = _checked[_column_int64.name, _column_int64.type](handle, path)
        self._column_double = _checked[
            _column_double.name, _column_double.type
        ](handle, path)
        self._column_text = _checked[_column_text.name, _column_text.type](handle, path)
        self._column_blob = _checked[_column_blob.name, _column_blob.type](handle, path)
        self._column_bytes = _checked[_column_bytes.name, _column_bytes.type](handle, path)
        self._column_name = _checked[_column_name.name, _column_name.type](handle, path)
        self._declare_vtab = _checked[_declare_vtab.name, _declare_vtab.type](handle, path)
        self._malloc64 = _checked[_malloc64.name, _malloc64.type](handle, path)
        self._free = _checked[_free.name, _free.type](handle, path)
        self._value_pointer = _checked[
            _value_pointer.name, _value_pointer.type
        ](handle, path)
        self._result_null = _checked[_result_null.name, _result_null.type](handle, path)
        self._result_double = _checked[
            _result_double.name, _result_double.type
        ](handle, path)
        self._result_int64 = _checked[_result_int64.name, _result_int64.type](handle, path)
        self._create_module_v2 = _checked[
            _create_module_v2.name, _create_module_v2.type
        ](handle, path)
        self.path = path^
        # Last, so the handle's own last mention is after every load above.
        self._lib = handle^

    # --- Library ----------------------------------------------------------

    def libversion(self) -> String:
        """`sqlite3_libversion`, e.g. "3.45.1"."""
        var p = CharPtr(unsafe_from_address=Int(self._libversion()))
        return cstr_to_string(p, cstr_len(p))

    def libversion_number(self) -> Int:
        """`sqlite3_libversion_number`: major*1000000 + minor*1000 + patch."""
        return Int(self._libversion_number())

    def threadsafe(self) -> Int:
        """`sqlite3_threadsafe`: 0 when the library was built single-threaded."""
        return Int(self._threadsafe())

    def errstr(self, code: Int) -> String:
        """`sqlite3_errstr`: English text for a primary result code."""
        var p = CharPtr(unsafe_from_address=Int(self._errstr(c_int(code))))
        return cstr_to_string(p, cstr_len(p))

    def errmsg(self, db: Int) -> String:
        """`sqlite3_errmsg`: the most recent error on a connection; "" for NULL."""
        if db == 0:
            return String("")
        var p = CharPtr(unsafe_from_address=Int(self._errmsg(db)))
        return cstr_to_string(p, cstr_len(p))

    def errcode(self, db: Int) -> Int:
        """`sqlite3_errcode`; SQLITE_OK for NULL."""
        if db == 0:
            return 0
        return Int(self._errcode(db))

    # --- Connections ------------------------------------------------------

    def open_v2(self, path: CStr, out_db: Int, flags: Int, vfs: Int) -> Int:
        """`sqlite3_open_v2`."""
        return Int(self._open_v2(path, out_db, c_int(flags), vfs))

    def close_v2(self, db: Int) -> Int:
        """`sqlite3_close_v2`."""
        return Int(self._close_v2(db))

    def exec(self, db: Int, sql: CStr) -> Int:
        """`sqlite3_exec` with no callback and no message out-parameter."""
        return Int(self._exec(db, sql, 0, 0, 0))

    def prepare_v2(
        self, db: Int, sql: CStr, length: Int, out_stmt: Int, out_tail: Int
    ) -> Int:
        """`sqlite3_prepare_v2`."""
        return Int(self._prepare_v2(db, sql, c_int(length), out_stmt, out_tail))

    def finalize(self, stmt: Int) -> Int:
        """`sqlite3_finalize`."""
        return Int(self._finalize(stmt))

    def get_autocommit(self, db: Int) -> Int:
        """`sqlite3_get_autocommit`."""
        return Int(self._get_autocommit(db))

    def last_insert_rowid(self, db: Int) -> Int:
        """`sqlite3_last_insert_rowid`."""
        return Int(self._last_insert_rowid(db))

    def changes(self, db: Int) -> Int:
        """`sqlite3_changes`."""
        return Int(self._changes(db))

    def total_changes(self, db: Int) -> Int:
        """`sqlite3_total_changes`."""
        return Int(self._total_changes(db))

    def busy_timeout(self, db: Int, ms: Int) -> Int:
        """`sqlite3_busy_timeout`."""
        return Int(self._busy_timeout(db, c_int(ms)))

    def declare_vtab(self, db: Int, decl: CStr) -> Int:
        """`sqlite3_declare_vtab`."""
        return Int(self._declare_vtab(db, decl))

    def malloc64(self, size: Int) -> Int:
        """`sqlite3_malloc64`: an address, or 0."""
        return Int(self._malloc64(Int64(size)))

    def free(self, p: Int):
        """`sqlite3_free`."""
        self._free(p)

    def free_fn(self) -> FreeFn:
        """`sqlite3_free` itself, as the destructor SQLite is handed for a
        buffer it should own — the module and the array specs. A pointer
        loaded from the library, never a Mojo shim that would need a table
        of its own to reach `sqlite3_free`."""
        return self._free

    def create_module_v2(
        self, db: Int, name: CStr, module: Int, aux: Int, destroy: FreeFn
    ) -> Int:
        """`sqlite3_create_module_v2`."""
        return Int(self._create_module_v2(db, name, module, aux, destroy))

    # --- Copies for the values that outlive a connection -------------------

    def stmt_lib(self) -> StmtLib:
        """The entry points a `Statement` calls, copied out of this table.

        A copy is sound because of the third rule: the library these
        pointers came from is pinned for the life of the process, so they
        stay valid after this table — and the `Connection` holding it — is
        gone, which is exactly when a statement is still stepping (O2).
        """
        return StmtLib(
            self._finalize,
            self._bind_int64,
            self._bind_double,
            self._bind_text,
            self._bind_blob,
            self._bind_null,
            self._bind_pointer,
            self._step,
            self._reset,
            self._clear_bindings,
            self._column_count,
            self._column_type,
            self._column_int64,
            self._column_double,
            self._column_text,
            self._column_blob,
            self._column_bytes,
            self._column_name,
            self._db_handle,
            self._errcode,
            self._errmsg,
            self._errstr,
            self._malloc64,
            self._free,
        )

    def vtab_lib(self) -> VtabLib:
        """The entry points the virtual-table callbacks call, copied out,
        for `vtab.mojo` to store in the module buffer SQLite owns."""
        return VtabLib(
            self._declare_vtab,
            self._malloc64,
            self._free,
            self._value_pointer,
            self._result_null,
            self._result_double,
            self._result_int64,
        )


struct StmtLib(ImplicitlyCopyable, Movable):
    """The entry points a `Statement` needs, held by value.

    Implicitly copyable, unlike `SqliteLib`, because it owns nothing: no
    handle, no buffer, only addresses into a library that is never
    unloaded. The fields are private and every call goes through a method
    beside them, for the second rule.
    """

    var _finalize: _finalize.type
    var _bind_int64: _bind_int64.type
    var _bind_double: _bind_double.type
    var _bind_text: _bind_text.type
    var _bind_blob: _bind_blob.type
    var _bind_null: _bind_null.type
    var _bind_pointer: _bind_pointer.type
    var _step: _step.type
    var _reset: _reset.type
    var _clear_bindings: _clear_bindings.type
    var _column_count: _column_count.type
    var _column_type: _column_type.type
    var _column_int64: _column_int64.type
    var _column_double: _column_double.type
    var _column_text: _column_text.type
    var _column_blob: _column_blob.type
    var _column_bytes: _column_bytes.type
    var _column_name: _column_name.type
    var _db_handle: _db_handle.type
    var _errcode: _errcode.type
    var _errmsg: _errmsg.type
    var _errstr: _errstr.type
    var _malloc64: _malloc64.type
    var _free: _free.type

    def __init__(
        out self,
        finalize: _finalize.type,
        bind_int64: _bind_int64.type,
        bind_double: _bind_double.type,
        bind_text: _bind_text.type,
        bind_blob: _bind_blob.type,
        bind_null: _bind_null.type,
        bind_pointer: _bind_pointer.type,
        step: _step.type,
        reset: _reset.type,
        clear_bindings: _clear_bindings.type,
        column_count: _column_count.type,
        column_type: _column_type.type,
        column_int64: _column_int64.type,
        column_double: _column_double.type,
        column_text: _column_text.type,
        column_blob: _column_blob.type,
        column_bytes: _column_bytes.type,
        column_name: _column_name.type,
        db_handle: _db_handle.type,
        errcode: _errcode.type,
        errmsg: _errmsg.type,
        errstr: _errstr.type,
        malloc64: _malloc64.type,
        free: _free.type,
    ):
        self._finalize = finalize
        self._bind_int64 = bind_int64
        self._bind_double = bind_double
        self._bind_text = bind_text
        self._bind_blob = bind_blob
        self._bind_null = bind_null
        self._bind_pointer = bind_pointer
        self._step = step
        self._reset = reset
        self._clear_bindings = clear_bindings
        self._column_count = column_count
        self._column_type = column_type
        self._column_int64 = column_int64
        self._column_double = column_double
        self._column_text = column_text
        self._column_blob = column_blob
        self._column_bytes = column_bytes
        self._column_name = column_name
        self._db_handle = db_handle
        self._errcode = errcode
        self._errmsg = errmsg
        self._errstr = errstr
        self._malloc64 = malloc64
        self._free = free

    def finalize(self, stmt: Int) -> Int:
        """`sqlite3_finalize`."""
        return Int(self._finalize(stmt))

    def bind_int64(self, stmt: Int, index: Int, value: Int) -> Int:
        """`sqlite3_bind_int64`."""
        return Int(self._bind_int64(stmt, c_int(index), Int64(value)))

    def bind_double(self, stmt: Int, index: Int, value: Float64) -> Int:
        """`sqlite3_bind_double`."""
        return Int(self._bind_double(stmt, c_int(index), value))

    def bind_text(
        self, stmt: Int, index: Int, text: CStr, length: Int, destructor: Int
    ) -> Int:
        """`sqlite3_bind_text`; `destructor` is SQLITE_TRANSIENT here."""
        return Int(self._bind_text(stmt, c_int(index), text, c_int(length), destructor))

    def bind_blob(
        self, stmt: Int, index: Int, data: CStr, length: Int, destructor: Int
    ) -> Int:
        """`sqlite3_bind_blob`."""
        return Int(self._bind_blob(stmt, c_int(index), data, c_int(length), destructor))

    def bind_null(self, stmt: Int, index: Int) -> Int:
        """`sqlite3_bind_null`."""
        return Int(self._bind_null(stmt, c_int(index)))

    def bind_pointer(
        self, stmt: Int, index: Int, p: Int, tag: CStr, destroy: FreeFn
    ) -> Int:
        """`sqlite3_bind_pointer`."""
        return Int(self._bind_pointer(stmt, c_int(index), p, tag, destroy))

    def step(self, stmt: Int) -> Int:
        """`sqlite3_step`."""
        return Int(self._step(stmt))

    def reset(self, stmt: Int) -> Int:
        """`sqlite3_reset`."""
        return Int(self._reset(stmt))

    def clear_bindings(self, stmt: Int) -> Int:
        """`sqlite3_clear_bindings`."""
        return Int(self._clear_bindings(stmt))

    def column_count(self, stmt: Int) -> Int:
        """`sqlite3_column_count`."""
        return Int(self._column_count(stmt))

    def column_type(self, stmt: Int, index: Int) -> Int:
        """`sqlite3_column_type`."""
        return Int(self._column_type(stmt, c_int(index)))

    def column_int64(self, stmt: Int, index: Int) -> Int:
        """`sqlite3_column_int64`."""
        return Int(self._column_int64(stmt, c_int(index)))

    def column_double(self, stmt: Int, index: Int) -> Float64:
        """`sqlite3_column_double`."""
        return self._column_double(stmt, c_int(index))

    def column_text(self, stmt: Int, index: Int) -> CharPtr:
        """`sqlite3_column_text`: SQLite's own buffer, valid until the next step."""
        return CharPtr(unsafe_from_address=Int(self._column_text(stmt, c_int(index))))

    def column_blob(self, stmt: Int, index: Int) -> CharPtr:
        """`sqlite3_column_blob`: SQLite's own buffer, valid until the next step."""
        return CharPtr(unsafe_from_address=Int(self._column_blob(stmt, c_int(index))))

    def column_bytes(self, stmt: Int, index: Int) -> Int:
        """`sqlite3_column_bytes`."""
        return Int(self._column_bytes(stmt, c_int(index)))

    def column_name(self, stmt: Int, index: Int) -> CharPtr:
        """`sqlite3_column_name`; NULL for an index out of range."""
        return CharPtr(unsafe_from_address=Int(self._column_name(stmt, c_int(index))))

    def errstr(self, code: Int) -> String:
        """`sqlite3_errstr`."""
        var p = CharPtr(unsafe_from_address=Int(self._errstr(c_int(code))))
        return cstr_to_string(p, cstr_len(p))

    def stmt_errmsg(self, stmt: Int, rc: Int) -> String:
        """Message for `rc` from the connection owning `stmt`, or "" if unsure.

        `sqlite3_db_handle` recovers the owning `sqlite3*` from the
        statement, so a `Statement` gets SQLite's real message without
        storing a connection handle.

        The corroboration check is not paranoia. Mojo destroys a value at
        its last use, so a `Connection` whose last mention was `prepare()`
        is already closed by the time the statement fails — the statement
        keeps working (close_v2 leaves the connection alive until its
        statements finalize) but the closed connection answers
        SQLITE_MISUSE to every question. Reporting that would turn a true
        "UNIQUE constraint failed: u.name" into a false "bad parameter or
        other API misuse". So the message is used only when the
        connection's own error code agrees with the code being described;
        otherwise the caller falls back to `errstr`, which is less specific
        but always true.

        That comparison assumes **primary** result codes on both sides,
        which holds only because nothing here calls
        `sqlite3_extended_result_codes`. Turn those on and `sqlite3_step`
        starts returning 2067 where `sqlite3_errcode` still answers 19, the
        corroboration fails every time, and every message silently degrades
        to `errstr`. If extended codes are ever wanted, this must compare
        against `sqlite3_extended_errcode` instead.
        """
        if stmt == 0:
            return String("")
        var db = Int(self._db_handle(stmt))
        if db == 0 or Int(self._errcode(db)) != rc:
            return String("")
        var p = CharPtr(unsafe_from_address=Int(self._errmsg(db)))
        return cstr_to_string(p, cstr_len(p))

    def malloc64(self, size: Int) -> Int:
        """`sqlite3_malloc64`: an address, or 0."""
        return Int(self._malloc64(Int64(size)))

    def free_fn(self) -> FreeFn:
        """`sqlite3_free`, as a bind destructor (see `SqliteLib.free_fn`)."""
        return self._free


struct VtabLib(ImplicitlyCopyable, Movable):
    """The seven entry points the `m0_array` callbacks call, held by value.

    Stored as words after the `sqlite3_module` in the buffer SQLite owns
    (`vtab.mojo`, `A_LIB`), and read back by each callback from the `pAux`
    it is handed — directly by `xConnect`, through the vtab's own extra word
    by the rest — so a callback SQLite invokes from C reaches the library
    without a global. Copies, sound for the third rule.
    """

    var _declare_vtab: _declare_vtab.type
    var _malloc64: _malloc64.type
    var _free: _free.type
    var _value_pointer: _value_pointer.type
    var _result_null: _result_null.type
    var _result_double: _result_double.type
    var _result_int64: _result_int64.type

    def __init__(
        out self,
        declare_vtab: _declare_vtab.type,
        malloc64: _malloc64.type,
        free: _free.type,
        value_pointer: _value_pointer.type,
        result_null: _result_null.type,
        result_double: _result_double.type,
        result_int64: _result_int64.type,
    ):
        self._declare_vtab = declare_vtab
        self._malloc64 = malloc64
        self._free = free
        self._value_pointer = value_pointer
        self._result_null = result_null
        self._result_double = result_double
        self._result_int64 = result_int64

    def store(self, addr: Int):
        """Write the seven pointers as consecutive words at `addr`."""
        Pointer[_declare_vtab.type, MutAnyOrigin](unsafe_from_address=addr)[
            unsafe_offset=0
        ] = self._declare_vtab
        Pointer[_malloc64.type, MutAnyOrigin](unsafe_from_address=addr + 8)[
            unsafe_offset=0
        ] = self._malloc64
        Pointer[_free.type, MutAnyOrigin](unsafe_from_address=addr + 16)[
            unsafe_offset=0
        ] = self._free
        Pointer[_value_pointer.type, MutAnyOrigin](unsafe_from_address=addr + 24)[
            unsafe_offset=0
        ] = self._value_pointer
        Pointer[_result_null.type, MutAnyOrigin](unsafe_from_address=addr + 32)[
            unsafe_offset=0
        ] = self._result_null
        Pointer[_result_double.type, MutAnyOrigin](unsafe_from_address=addr + 40)[
            unsafe_offset=0
        ] = self._result_double
        Pointer[_result_int64.type, MutAnyOrigin](unsafe_from_address=addr + 48)[
            unsafe_offset=0
        ] = self._result_int64

    @staticmethod
    def load(addr: Int) -> VtabLib:
        """The seven pointers `store` wrote at `addr`."""
        return VtabLib(
            Pointer[_declare_vtab.type, MutAnyOrigin](unsafe_from_address=addr)[
                unsafe_offset=0
            ],
            Pointer[_malloc64.type, MutAnyOrigin](unsafe_from_address=addr + 8)[
                unsafe_offset=0
            ],
            Pointer[_free.type, MutAnyOrigin](unsafe_from_address=addr + 16)[
                unsafe_offset=0
            ],
            Pointer[_value_pointer.type, MutAnyOrigin](unsafe_from_address=addr + 24)[
                unsafe_offset=0
            ],
            Pointer[_result_null.type, MutAnyOrigin](unsafe_from_address=addr + 32)[
                unsafe_offset=0
            ],
            Pointer[_result_double.type, MutAnyOrigin](unsafe_from_address=addr + 40)[
                unsafe_offset=0
            ],
            Pointer[_result_int64.type, MutAnyOrigin](unsafe_from_address=addr + 48)[
                unsafe_offset=0
            ],
        )

    def declare_vtab(self, db: Int, decl: CStr) -> Int:
        """`sqlite3_declare_vtab`."""
        return Int(self._declare_vtab(db, decl))

    def malloc64(self, size: Int) -> Int:
        """`sqlite3_malloc64`: an address, or 0."""
        return Int(self._malloc64(Int64(size)))

    def free(self, p: Int):
        """`sqlite3_free`."""
        self._free(p)

    def value_pointer(self, value: Int, tag: CStr) -> Int:
        """`sqlite3_value_pointer`: the bound pointer, or 0 unless the tag matches."""
        return Int(self._value_pointer(value, tag))

    def result_null(self, ctx: Int):
        """`sqlite3_result_null`."""
        self._result_null(ctx)

    def result_double(self, ctx: Int, value: Float64):
        """`sqlite3_result_double`."""
        self._result_double(ctx, value)

    def result_int64(self, ctx: Int, value: Int):
        """`sqlite3_result_int64`."""
        self._result_int64(ctx, Int64(value))


def open_library(path: String = "") raises -> SqliteLib:
    """Open libsqlite3: `path`, else `M0_LIBSQLITE3`, else the search path.

    The version floor and the library's own thread-safety flag are checked
    here, where both are one call and the answer can name the library that
    failed. A libsqlite3 built with `SQLITE_THREADSAFE=0` ignores the
    `NOMUTEX`/`FULLMUTEX` open flags this package chooses between, so one
    connection per thread would be a data race rather than a choice; it is
    refused.
    """
    var tried = List[String]()
    var candidates = List[String]()
    if path:
        candidates.append(path)
    else:
        var from_env = getenv("M0_LIBSQLITE3", "")
        if from_env:
            candidates.append(from_env)
        else:
            candidates = default_search_path()

    for candidate in candidates:
        var handle: OwnedDLHandle
        try:
            handle = OwnedDLHandle(candidate)
        except:
            tried.append(candidate)
            continue
        var lib = SqliteLib(handle^, candidate)
        var have = lib.libversion_number()
        if have < MIN_SQLITE_VERSION:
            raise Error(
                "the libsqlite3 at " + candidate + " is version "
                + lib.libversion() + " (" + String(have) + "), older than the"
                " 3.20.0 (" + String(MIN_SQLITE_VERSION) + ") this package"
                " requires"
            )
        if lib.threadsafe() == 0:
            raise Error(
                "the libsqlite3 at " + candidate + " was built with"
                " SQLITE_THREADSAFE=0, and this package opens one connection"
                " per thread"
            )
        return lib^

    var names = String("")
    for i in range(len(tried)):
        names += ("\n  " if i else "") + tried[i]
    raise Error(
        "libsqlite3 could not be opened. Set M0_LIBSQLITE3 to the library"
        " file, or install one where it can be found. Tried:\n  " + names
    )


# --- Conveniences that open the library themselves --------------------------
#
# For a banner, a version check, a test. Each opens the library — a
# reference count on an image already mapped, and ~41 symbol lookups — so
# none belongs on a request path; a connection's own table answers the same
# questions for free.


def libversion() raises -> String:
    """SQLite library version, e.g. "3.51.0", from the library the search
    path finds. Also the cheapest possible load check: an absent library
    fails here, before any database is touched."""
    return open_library().libversion()


def libversion_number() raises -> Int:
    """SQLite library version as an integer, e.g. 3045001 for "3.45.1"."""
    return open_library().libversion_number()


def errstr(code: Int) raises -> String:
    """English text for a primary result code, independent of any connection."""
    return open_library().errstr(code)
