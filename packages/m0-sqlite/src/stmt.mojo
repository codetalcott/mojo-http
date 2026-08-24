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
from std.memory import Pointer, unsafe_memcpy

from .vtab import KIND_INT, KIND_FLOAT, _bind_spec
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
    describe,
    stmt_errmsg,
    check_c_int_length,
)


struct Statement(Movable):
    """A compiled SQL statement. Finalized automatically when it goes out of scope."""

    var _handle: Int

    def __init__(out self, handle: Int) raises:
        """Take ownership of a `sqlite3_stmt*` carried as an opaque address.

        Refuses a NULL handle. `Connection.prepare` already rejects the case
        SQLite produces one — text that compiles to no statement — but this
        constructor is public and takes a bare `Int`, so `Statement(0)` was
        reachable and its first `step` would call `sqlite3_step(NULL)`.
        """
        if handle == 0:
            raise Error(
                "Statement was handed a NULL sqlite3_stmt* — a statement can"
                " only be built from a handle sqlite3_prepare_v2 produced"
            )
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
        check_c_int_length("bind_text", len(bytes))
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
        check_c_int_length("bind_blob", len(value))
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

        A failed step leaves the statement resettable, not poisoned: call
        `reset` and the statement is ready for new bindings.
        """
        var rc = Int(external_call["sqlite3_step", c_int](self._handle))
        if rc == SQLITE_ROW:
            return True
        if rc == SQLITE_DONE:
            return False
        raise Error(describe("step", rc, stmt_errmsg(self._handle, rc)))

    def reset(mut self) raises:
        """Rewind for reuse. Bindings survive; use `clear_bindings` to drop them.

        The result code is deliberately discarded. `sqlite3_reset` always
        resets; what it *returns* is the error code from the statement's most
        recent evaluation. Raising on it would mean that recovering from a
        failed `step` — reset, rebind, retry — is impossible without catching a
        second, stale copy of the error `step` already raised.
        """
        _ = external_call["sqlite3_reset", c_int](self._handle)

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

    def _check_column(self, index: Int) raises:
        """Reject an index outside the result set.

        SQLite documents an out-of-range column index as undefined behaviour,
        and what it does in practice is worse than a crash: `column_int64`
        answers 0, `column_text` answers NULL, and `column_type` answers
        SQLITE_NULL — so a typo'd index is indistinguishable from a stored
        NULL, which is the one distinction `is_null` exists to make.
        `sqlite3_column_name` answers NULL outright, which used to be a
        segfault inside `cstr_len`.

        The count is re-read per call rather than cached on the statement.
        `sqlite3_prepare_v2` silently re-prepares after a schema change, so a
        `SELECT *` really can change its column count mid-life, and a cached
        count would then be wrong in exactly the direction that reintroduces
        the out-of-range read.

        That costs one extra C call per cell read. Measured in isolation
        against libsqlite3 3.51.0, a 100k-row single-column integer scan — the
        worst case, since there per-cell is also per-row — goes from 31.68 to
        32.70 ns/row: **1.02 ns/row, +3.2%**. Paid deliberately. It is under
        the run-to-run noise of `bench_sqlite.mojo`, and it buys the difference
        between a wrong answer and an error.
        """
        var n = self.column_count()
        if index < 0 or index >= n:
            raise Error(
                "column index "
                + String(index)
                + " is out of range: this statement has "
                + String(n)
                + (" columns" if n != 1 else " column")
            )

    def column_type(self, index: Int) raises -> Int:
        """One of SQLITE_INTEGER / FLOAT / TEXT / BLOB / NULL."""
        self._check_column(index)
        return Int(
            external_call["sqlite3_column_type", c_int](
                self._handle, c_int(index)
            )
        )

    def is_null(self, index: Int) raises -> Bool:
        """Whether the column holds SQL NULL.

        Worth checking explicitly: `column_int` on a NULL returns 0 and
        `column_text` returns "", neither of which is distinguishable from a
        real stored value. An index outside the result set raises rather than
        answering True, which is what it used to do — see `_check_column`.
        """
        return self.column_type(index) == SQLITE_NULL

    def column_int(self, index: Int) raises -> Int:
        """Read as a 64-bit integer. Returns 0 for NULL — see `is_null`."""
        self._check_column(index)
        return Int(
            external_call["sqlite3_column_int64", Int64](
                self._handle, c_int(index)
            )
        )

    def column_float(self, index: Int) raises -> Float64:
        """Read as a double. Returns 0.0 for NULL — see `is_null`."""
        self._check_column(index)
        return external_call["sqlite3_column_double", Float64](
            self._handle, c_int(index)
        )

    def column_text(self, index: Int) raises -> String:
        """Read as text. Returns "" for NULL — see `is_null`.

        Uses `column_bytes` for the length rather than scanning for a NUL, so a
        value containing an embedded NUL round-trips intact.

        `sqlite3_column_text` is called *before* `sqlite3_column_bytes`, which
        is the order SQLite documents: fetching the pointer forces the value
        into the requested format, and only then does the reported length
        describe that format rather than the one stored.

        The bytes are trusted as UTF-8 without validation. That holds for
        anything this package wrote, but SQLite stores TEXT as whatever bytes
        it was handed, so a database written elsewhere can legally hold
        invalid UTF-8 — and it lands in the returned String as-is. Validation
        belongs to the caller who knows the data's provenance.

        **Scanning many rows?** The String built here is the dominant cost of
        a text scan — 2.1x at both 64 B and 4 KB (`bench_sqlite.mojo`). A
        zero-allocation read already exists: `column_blob_into` works on a
        TEXT column too, handing the UTF-8 bytes into a reused buffer.
        """
        self._check_column(index)
        var p = external_call["sqlite3_column_text", CharPtr](
            self._handle, c_int(index)
        )
        var n = Int(
            external_call["sqlite3_column_bytes", c_int](
                self._handle, c_int(index)
            )
        )
        if n <= 0:
            return String("")
        return cstr_to_string(p, n)

    def column_blob(self, index: Int) raises -> List[UInt8]:
        """Read as raw bytes. Returns an empty list for NULL — see `is_null`.

        One `unsafe_memcpy` rather than a per-byte loop: SQLite hands back a
        contiguous buffer whose length it already told us, so there is nothing
        to scan for. (Measured at ~13x for 4 KB and ~20x for 1 MB.)

        `sqlite3_column_blob` is called *before* `sqlite3_column_bytes`, which
        is the order SQLite documents: fetching the pointer forces the value
        into the requested format, and only then does the reported length
        describe that format rather than the one stored.
        """
        self._check_column(index)
        var p = external_call["sqlite3_column_blob", CharPtr](
            self._handle, c_int(index)
        )
        var n = Int(
            external_call["sqlite3_column_bytes", c_int](
                self._handle, c_int(index)
            )
        )
        if n <= 0:
            return List[UInt8]()
        var out = List[UInt8](unsafe_uninit_length=n)
        unsafe_memcpy(dest=out.unsafe_ptr(), src=p, count=n)
        return out^

    def column_blob_into(
        self, index: Int, mut buf: List[UInt8]
    ) raises -> Int:
        """Read raw bytes into a caller-owned buffer; returns the byte count.

        `buf` is resized to exactly the blob's length and fully overwritten, so
        one buffer can be reused across every row of a scan instead of
        allocating a fresh `List` per row. Returns 0 for NULL and for a
        zero-length blob alike — see `is_null` to tell them apart.

        **Works on TEXT columns too**, and is the zero-allocation text scan:
        SQLite converts TEXT to blob bytes on request, and for TEXT stored as
        UTF-8 that conversion is a pointer handoff, not a copy. Measured 2.1x
        over `column_text` at 64 B and at 4 KB — the whole difference is the
        per-row String. The bytes arrive without a terminating NUL, exactly
        as `column_text` would have seen them.
        """
        self._check_column(index)
        # Pointer before length, as in `column_blob` — SQLite documents that
        # order, because fetching the pointer is what forces the value into the
        # requested format.
        var p = external_call["sqlite3_column_blob", CharPtr](
            self._handle, c_int(index)
        )
        var n = Int(
            external_call["sqlite3_column_bytes", c_int](
                self._handle, c_int(index)
            )
        )
        if n <= 0:
            buf.resize(0, 0)
            return 0
        # Uninitialized: every byte is overwritten by the memcpy below, so a
        # zero-fill of the grown tail would be written twice. This method
        # exists to avoid per-row work; that includes its own.
        buf.resize(unsafe_uninit_length=n)
        unsafe_memcpy(dest=buf.unsafe_ptr(), src=p, count=n)
        return n

    def column_name(self, index: Int) raises -> String:
        """Declared name of a result column."""
        self._check_column(index)
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

    # --- Array parameters (borrow-enforced) --------------------------------
    #
    # These bind a Mojo `List` to the `m0_array(?)` virtual table without
    # copying it, for `INSERT INTO t SELECT value FROM m0_array(?1)` and the
    # like. Register the module first with `Connection.register_array_module`.
    #
    # Every other binder in this file passes SQLITE_TRANSIENT, so SQLite copies
    # immediately and no Mojo buffer ever has to outlive a call.
    # `sqlite3_bind_pointer` cannot do that: it lends SQLite the raw buffer for
    # the life of the statement. Mojo makes that sharper than C does, because it
    # destroys a value at its **last syntactic use** — so the obvious API is
    # silently wrong:
    #
    #     stmt.bind_array(1, data)   # hypothetical
    #     _ = stmt.step()            # `data` was freed one line ago
    #
    # It does not even crash: the allocator writes a freelist pointer into the
    # block's first word, so element 0 comes back as a heap address and every
    # other element reads fine.
    #
    # A guard object does not fix this — the guard would itself die at its own
    # last use, still before the step. So the borrow is enforced by shape
    # instead: the array is an **argument to the call that also finishes the
    # statement**. It is alive for the whole call by construction, there is no
    # window in which it is bound but dead, and there is nothing for a caller to
    # hold correctly. The binding is dropped again before returning, so a later
    # `step` cannot reach a stale pointer either.
    #
    # The cost of that guarantee is that these run the statement to completion,
    # so they do not compose with incremental stepping. That is the trade, and
    # it is the right way round for the case that motivated them: bulk ingest
    # measured ~2.9x against the per-row bind/step/reset loop.
    #
    # It also means **one array per statement**. The array is an argument to
    # the call, and there is one of it, so `SELECT ... FROM m0_array(?1) JOIN
    # m0_array(?2)` cannot be written through the safe API — nor should it be
    # reached for by dropping to `_bind_spec`, which is exactly the shape the
    # borrow rule exists to forbid. Two arrays would need a call taking both,
    # and nothing has wanted one yet.
    #
    # The read side is deliberately int-only (`fetch_ints_over`), although
    # `execute_over` takes float arrays too: ingest is the case that earns the
    # module its keep, and a float read-out variant should be added the day
    # something needs it, not speculatively.

    def execute_over(mut self, param: Int, data: List[Int]) raises:
        """Run this statement with `data` bound to `param` as `m0_array(?)`.

        Steps to completion. Use `Connection.changes` for the row count.
        """
        self._run_over(param, Int(data.unsafe_ptr()), len(data), KIND_INT)

    def execute_over(mut self, param: Int, data: List[Float64]) raises:
        """Run this statement with a float array bound to `param`."""
        self._run_over(param, Int(data.unsafe_ptr()), len(data), KIND_FLOAT)

    def fetch_ints_over(
        mut self,
        col: Int,
        param: Int,
        data: List[Int],
        mut out: List[Int],
    ) raises -> Int:
        """Read `col` of every row, with `data` bound to `param`.

        The query runs to completion inside this call — which is what keeps
        `data` alive across the steps — so `out` should be sized for the whole
        result set.
        """
        self.reset()
        _bind_spec(self._handle, param, Int(data.unsafe_ptr()), len(data), KIND_INT)
        var rows = 0
        try:
            while self.step():
                out.append(self.column_int(col))
                rows += 1
        finally:
            self._drop_borrow(param)
        return rows

    def _run_over(
        mut self, param: Int, data: Int, count: Int, kind: Int
    ) raises:
        self.reset()
        _bind_spec(self._handle, param, data, count, kind)
        try:
            while self.step():
                pass
        finally:
            self._drop_borrow(param)

    def _drop_borrow(mut self, param: Int) raises:
        """Unbind the array before returning, so no stale pointer survives.

        Binding requires a reset first — SQLite returns SQLITE_MISUSE on a
        statement that has been stepped since its last reset. That reset is
        deliberately quiet: `sqlite3_reset` re-reports the *previous* step's
        error, which `step` has already raised, and re-raising it here would
        replace the real error with an echo of it on the way out of `finally`.
        """
        _ = external_call["sqlite3_reset", c_int](self._handle)
        self.bind_null(param)

    # --- Lifetime ----------------------------------------------------------

    def finalize(mut self):
        """Release the statement early. Idempotent; `__deinit__` also calls it.

        Only needed when you want the handle gone before the value's scope ends.

        Like `reset`, this cannot fail and does not raise. `sqlite3_finalize`
        always deallocates the statement; its return value is the error code of
        the most recent evaluation, so raising on it would turn cleanup after a
        failed `step` into a second exception reporting an error that has
        already been raised once — and thrown from a path the caller cannot
        retry.
        """
        if self._handle == 0:
            return
        _ = external_call["sqlite3_finalize", c_int](self._handle)
        self._handle = 0

    def _check(self, rc: Int, what: String) raises:
        if rc != SQLITE_OK:
            raise Error(describe(what, rc, stmt_errmsg(self._handle, rc)))
