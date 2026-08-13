"""Prepared statements.

`Statement` owns its `sqlite3_stmt*` and finalizes it on destruction. It is
deliberately **not** `Copyable`: copying would duplicate the handle and the
second destructor would finalize an already-finalized statement. Move it with
`^` when you need to pass ownership.

Parameter indices are 1-based (SQLite's convention); column indices are 0-based.
That asymmetry is SQLite's, not ours, and is preserved so the C documentation
reads across directly.
"""

from std.collections.span import Span
from std.ffi import external_call, c_int
from std.memory import UnsafePointer

from .ffi import (
    CharPtr,
    SQLITE_OK,
    SQLITE_ROW,
    SQLITE_DONE,
    SQLITE_TRANSIENT,
    SQLITE_NULL,
    cstr_to_string,
    cstr_len,
    errstr,
)


struct Statement(Movable):
    """A compiled SQL statement. Finalized automatically when it goes out of scope."""

    var _handle: Int

    def __init__(out self, handle: Int):
        """Take ownership of a `sqlite3_stmt*` carried as an opaque address."""
        self._handle = handle

    def __deinit__(deinit self):
        if self._handle != 0:
            _ = external_call["sqlite3_finalize", c_int](self._handle)

    # --- Binding (1-based, as SQLite defines it) ---------------------------

    def bind_int(mut self, index: Int, value: Int) raises:
        """Bind a 64-bit integer."""
        self._check(
            Int(
                external_call["sqlite3_bind_int64", c_int](
                    self._handle, c_int(index), Int64(value)
                )
            ),
            "bind_int",
        )

    def bind_float(mut self, index: Int, value: Float64) raises:
        """Bind a double."""
        self._check(
            Int(
                external_call["sqlite3_bind_double", c_int](
                    self._handle, c_int(index), value
                )
            ),
            "bind_float",
        )

    def bind_text(mut self, index: Int, value: String) raises:
        """Bind text.

        Passes an explicit byte length, so this does not depend on Mojo's String
        NUL termination, and SQLITE_TRANSIENT so SQLite copies immediately —
        the caller's buffer need not outlive the call.
        """
        var bytes = value.as_bytes()
        self._check(
            Int(
                external_call["sqlite3_bind_text", c_int](
                    self._handle,
                    c_int(index),
                    value.unsafe_ptr(),
                    c_int(len(bytes)),
                    Int(SQLITE_TRANSIENT),
                )
            ),
            "bind_text",
        )

    def bind_blob(mut self, index: Int, value: List[UInt8]) raises:
        """Bind an arbitrary byte string. SQLite copies it immediately."""
        self._check(
            Int(
                external_call["sqlite3_bind_blob", c_int](
                    self._handle,
                    c_int(index),
                    value.unsafe_ptr(),
                    c_int(len(value)),
                    Int(SQLITE_TRANSIENT),
                )
            ),
            "bind_blob",
        )

    def bind_null(mut self, index: Int) raises:
        """Bind SQL NULL."""
        self._check(
            Int(
                external_call["sqlite3_bind_null", c_int](
                    self._handle, c_int(index)
                )
            ),
            "bind_null",
        )

    # --- Execution ---------------------------------------------------------

    def step(mut self) raises -> Bool:
        """Advance the cursor. True if a row is available, False when done.

        Raises on any result code that is neither ROW nor DONE, so callers can
        write `while stmt.step():` without checking an error code each turn.
        """
        var rc = Int(external_call["sqlite3_step", c_int](self._handle))
        if rc == SQLITE_ROW:
            return True
        if rc == SQLITE_DONE:
            return False
        raise Error("sqlite3_step failed: " + errstr(rc) + " (rc=" + String(rc) + ")")

    def reset(mut self) raises:
        """Rewind for reuse. Bindings survive; use `clear_bindings` to drop them."""
        self._check(
            Int(external_call["sqlite3_reset", c_int](self._handle)), "reset"
        )

    def clear_bindings(mut self) raises:
        """Reset every bound parameter to NULL."""
        self._check(
            Int(external_call["sqlite3_clear_bindings", c_int](self._handle)),
            "clear_bindings",
        )

    # --- Reading the current row (0-based, as SQLite defines it) -----------

    def column_count(self) -> Int:
        """Number of columns in the result set."""
        return Int(external_call["sqlite3_column_count", c_int](self._handle))

    def column_type(self, index: Int) -> Int:
        """One of SQLITE_INTEGER / FLOAT / TEXT / BLOB / NULL."""
        return Int(
            external_call["sqlite3_column_type", c_int](
                self._handle, c_int(index)
            )
        )

    def is_null(self, index: Int) -> Bool:
        """Whether the column holds SQL NULL.

        Worth checking explicitly: `column_int` on a NULL returns 0 and
        `column_text` returns "", neither of which is distinguishable from a
        real stored value.
        """
        return self.column_type(index) == SQLITE_NULL

    def column_int(self, index: Int) -> Int:
        """Read as a 64-bit integer. Returns 0 for NULL — see `is_null`."""
        return Int(
            external_call["sqlite3_column_int64", Int64](
                self._handle, c_int(index)
            )
        )

    def column_float(self, index: Int) -> Float64:
        """Read as a double. Returns 0.0 for NULL — see `is_null`."""
        return external_call["sqlite3_column_double", Float64](
            self._handle, c_int(index)
        )

    def column_text(self, index: Int) -> String:
        """Read as text. Returns "" for NULL — see `is_null`.

        Uses `column_bytes` for the length rather than scanning for a NUL, so a
        value containing an embedded NUL round-trips intact.
        """
        var n = Int(
            external_call["sqlite3_column_bytes", c_int](
                self._handle, c_int(index)
            )
        )
        if n <= 0:
            return String("")
        var p = external_call["sqlite3_column_text", CharPtr](
            self._handle, c_int(index)
        )
        return cstr_to_string(p, n)

    def column_blob(self, index: Int) -> List[UInt8]:
        """Read as raw bytes. Returns an empty list for NULL — see `is_null`."""
        var n = Int(
            external_call["sqlite3_column_bytes", c_int](
                self._handle, c_int(index)
            )
        )
        var out = List[UInt8](capacity=n if n > 0 else 1)
        if n <= 0:
            return out^
        var p = external_call["sqlite3_column_blob", CharPtr](
            self._handle, c_int(index)
        )
        for i in range(n):
            out.append(p[unsafe_offset=i])
        return out^

    def column_name(self, index: Int) -> String:
        """Declared name of a result column."""
        var p = external_call["sqlite3_column_name", CharPtr](
            self._handle, c_int(index)
        )
        return cstr_to_string(p, cstr_len(p))

    # --- Lifetime ----------------------------------------------------------

    def finalize(mut self) raises:
        """Release the statement early. Idempotent; `__deinit__` also calls it.

        Only needed when you want the error code surfaced, or want the handle
        gone before the value's scope ends.
        """
        if self._handle == 0:
            return
        var rc = Int(external_call["sqlite3_finalize", c_int](self._handle))
        self._handle = 0
        if rc != SQLITE_OK:
            raise Error("sqlite3_finalize failed: " + errstr(rc))

    def _check(self, rc: Int, what: String) raises:
        if rc != SQLITE_OK:
            raise Error(
                "sqlite3_" + what + " failed: " + errstr(rc) + " (rc=" + String(rc) + ")"
            )
