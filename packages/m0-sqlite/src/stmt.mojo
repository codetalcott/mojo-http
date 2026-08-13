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
from std.memory import UnsafePointer, unsafe_memcpy

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
        """Read as raw bytes. Returns an empty list for NULL — see `is_null`.

        One `unsafe_memcpy` rather than a per-byte loop: SQLite hands back a
        contiguous buffer whose length it already told us, so there is nothing
        to scan for.
        """
        var n = Int(
            external_call["sqlite3_column_bytes", c_int](
                self._handle, c_int(index)
            )
        )
        if n <= 0:
            return List[UInt8]()
        var p = external_call["sqlite3_column_blob", CharPtr](
            self._handle, c_int(index)
        )
        var out = List[UInt8](unsafe_uninit_length=n)
        unsafe_memcpy(dest=out.unsafe_ptr(), src=p, count=n)
        return out^

    def column_blob_into(self, index: Int, mut buf: List[UInt8]) -> Int:
        """Read raw bytes into a caller-owned buffer; returns the byte count.

        `buf` is resized to exactly the blob's length and fully overwritten, so
        one buffer can be reused across every row of a scan instead of
        allocating a fresh `List` per row. Returns 0 for NULL and for a
        zero-length blob alike — see `is_null` to tell them apart.
        """
        var n = Int(
            external_call["sqlite3_column_bytes", c_int](
                self._handle, c_int(index)
            )
        )
        if n <= 0:
            buf.resize(0, 0)
            return 0
        buf.resize(n, 0)
        var p = external_call["sqlite3_column_blob", CharPtr](
            self._handle, c_int(index)
        )
        unsafe_memcpy(dest=buf.unsafe_ptr(), src=p, count=n)
        return n

    def column_name(self, index: Int) -> String:
        """Declared name of a result column."""
        var p = external_call["sqlite3_column_name", CharPtr](
            self._handle, c_int(index)
        )
        return cstr_to_string(p, cstr_len(p))

    # --- Bulk read-out (SoA) ----------------------------------------------
    #
    # These are a shape convenience, **not** a speed-up, and the distinction is
    # worth stating plainly: `bench_sqlite.mojo` measures them at 4.37ms against
    # 4.29ms for the equivalent `while step():` loop over 100k rows — i.e. no
    # win, slightly negative, which is what you would expect. SQLite has no bulk
    # column API (`sqlite3_step` is per row, `sqlite3_column_*` is per cell) and
    # `external_call` is a direct call, so there is no per-row boundary cost for
    # a loop up here to save.
    #
    # What they are for is the output shape: a caller-owned `List` per column,
    # sized once up front, which is what a SIMD pass over the results wants and
    # what the parallel-`List` layout used elsewhere in the repo expects.
    # Reach for them when you want columns; keep the explicit loop when you
    # want rows.
    #
    # Each returns the number of rows appended and leaves the statement
    # positioned after the last row read, so a capped call can be resumed by
    # calling again. `max_rows < 0` means "until SQLITE_DONE".
    #
    # Exhaustion is signalled by a **short read**: a call that returns fewer
    # than `max_rows` has hit the end of the result set. Never probe for it by
    # calling again and expecting 0 — what happens when you step past
    # SQLITE_DONE is not portable, and both outcomes are bad:
    #
    #   Linux (libsqlite3 3.45)  auto-resets and silently re-runs the query,
    #                            so `while fetch(...) > 0` never terminates.
    #   macOS (system SQLite)    returns SQLITE_MISUSE, which `step` raises.
    #
    # Measured, not assumed — CI caught the divergence. It is inherited from
    # `sqlite3_step` and is equally present in the plain `while stmt.step():`
    # loop. It is surfaced rather than papered over: hiding it would mean
    # holding a "done" flag that could disagree with the statement's own state.
    # Stop on the short read and this never arises.

    def fetch_ints(
        mut self, col: Int, mut out: List[Int], max_rows: Int = -1
    ) raises -> Int:
        """Append column `col` of every remaining row to `out` as integers."""
        var rows = 0
        while max_rows < 0 or rows < max_rows:
            if not self.step():
                break
            out.append(self.column_int(col))
            rows += 1
        return rows

    def fetch_floats(
        mut self, col: Int, mut out: List[Float64], max_rows: Int = -1
    ) raises -> Int:
        """Append column `col` of every remaining row to `out` as doubles."""
        var rows = 0
        while max_rows < 0 or rows < max_rows:
            if not self.step():
                break
            out.append(self.column_float(col))
            rows += 1
        return rows

    def fetch_texts(
        mut self, col: Int, mut out: List[String], max_rows: Int = -1
    ) raises -> Int:
        """Append column `col` of every remaining row to `out` as text."""
        var rows = 0
        while max_rows < 0 or rows < max_rows:
            if not self.step():
                break
            out.append(self.column_text(col))
            rows += 1
        return rows

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
