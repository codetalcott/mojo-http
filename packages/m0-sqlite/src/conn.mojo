"""Database connections.

`Connection` owns its `sqlite3*` and closes it on destruction. Like `Statement`
it is `Movable` but not `Copyable`, so a handle cannot be duplicated into a
second owner that would close it twice.

**Threading.** SQLite is compiled serialized by default, but this package opens
connections with `SQLITE_OPEN_NOMUTEX` — one connection per thread or per
process, which is also what the multi-worker fork model in `m0-http` implies.
Do not share a `Connection` across threads. `open_serialized` is provided for
the case where you must.
"""

from std.ffi import external_call, c_int
from std.memory import UnsafePointer, stack_allocation

from .ffi import (
    CharPtr,
    SQLITE_OK,
    SQLITE_OPEN_READONLY,
    SQLITE_OPEN_READWRITE,
    SQLITE_OPEN_CREATE,
    SQLITE_OPEN_NOMUTEX,
    SQLITE_OPEN_FULLMUTEX,
    c_string,
    cstr_to_string,
    cstr_len,
    errstr,
)
from .stmt import Statement


comptime MEMORY = ":memory:"
"""Path for a private, in-memory database. Ideal for tests."""


struct Connection(Movable):
    """An open database. Closed automatically when it goes out of scope."""

    var _handle: Int

    def __init__(out self, path: String, flags: Int) raises:
        """Open a database with explicit flags.

        Prefer `open`, `open_readonly` or `open_memory` unless you need control
        over the flag set.
        """
        var pp = stack_allocation[1, Int]()
        pp[unsafe_offset=0] = 0
        # Must outlive the call — sqlite3_open_v2 takes no length. See c_string.
        var cpath = c_string(path)
        var rc = Int(
            external_call["sqlite3_open_v2", c_int](
                cpath.unsafe_ptr(), pp, c_int(flags), Int(0)
            )
        )
        self._handle = pp[unsafe_offset=0]
        if rc != SQLITE_OK:
            var detail = String("")
            if self._handle != 0:
                detail = String(" (") + self.errmsg() + ")"
                _ = external_call["sqlite3_close", c_int](self._handle)
                self._handle = 0
            raise Error(
                "sqlite3_open_v2 failed on " + path + ": " + errstr(rc) + detail
            )

    def __deinit__(deinit self):
        if self._handle != 0:
            _ = external_call["sqlite3_close_v2", c_int](self._handle)

    # --- Statements --------------------------------------------------------

    def execute(self, sql: String) raises:
        """Run one or more statements, discarding any rows.

        For DDL, PRAGMAs and one-shot writes. Use `prepare` when you need
        parameters or results — this takes no bindings by design, which keeps
        it impossible to build a query by string concatenation through here
        without noticing.
        """
        var csql = c_string(sql)  # sqlite3_exec takes no length argument
        var rc = Int(
            external_call["sqlite3_exec", c_int](
                self._handle, csql.unsafe_ptr(), Int(0), Int(0), Int(0)
            )
        )
        if rc != SQLITE_OK:
            raise Error("sqlite3_exec failed: " + self.errmsg() + " [" + sql + "]")

    def prepare(self, sql: String) raises -> Statement:
        """Compile a statement.

        The byte length is passed explicitly rather than -1, so this does not
        depend on Mojo's String NUL termination.
        """
        var pstmt = stack_allocation[1, Int]()
        pstmt[unsafe_offset=0] = 0
        var rc = Int(
            external_call["sqlite3_prepare_v2", c_int](
                self._handle,
                sql.unsafe_ptr(),
                c_int(len(sql.as_bytes())),
                pstmt,
                Int(0),
            )
        )
        if rc != SQLITE_OK:
            raise Error(
                "sqlite3_prepare_v2 failed: " + self.errmsg() + " [" + sql + "]"
            )
        return Statement(pstmt[unsafe_offset=0])

    # --- Transactions ------------------------------------------------------
    #
    # Explicit rather than a scope guard: Mojo has no `defer`, and a guard whose
    # destructor rolls back would make control flow depend on drop order, which
    # is exactly the kind of implicitness a storage layer should not have.

    def begin(self) raises:
        """Open a deferred transaction."""
        self.execute("BEGIN")

    def begin_immediate(self) raises:
        """Open a transaction that takes the write lock now.

        Use when several writers contend: it fails fast with SQLITE_BUSY rather
        than discovering the conflict at COMMIT and having to redo the work.
        """
        self.execute("BEGIN IMMEDIATE")

    def commit(self) raises:
        self.execute("COMMIT")

    def rollback(self) raises:
        self.execute("ROLLBACK")

    def in_transaction(self) -> Bool:
        """Whether a transaction is currently open."""
        return (
            Int(external_call["sqlite3_get_autocommit", c_int](self._handle)) == 0
        )

    # --- Introspection -----------------------------------------------------

    def last_insert_rowid(self) -> Int:
        """Rowid of the most recent successful INSERT on this connection."""
        return Int(
            external_call["sqlite3_last_insert_rowid", Int64](self._handle)
        )

    def changes(self) -> Int:
        """Rows modified by the most recent INSERT, UPDATE or DELETE."""
        return Int(external_call["sqlite3_changes", c_int](self._handle))

    def total_changes(self) -> Int:
        """Rows modified since this connection was opened."""
        return Int(external_call["sqlite3_total_changes", c_int](self._handle))

    def errmsg(self) -> String:
        """Text of the most recent error on this connection."""
        var p = external_call["sqlite3_errmsg", CharPtr](self._handle)
        return cstr_to_string(p, cstr_len(p))

    def close(mut self) raises:
        """Close early. Idempotent; `__deinit__` also closes.

        Uses `sqlite3_close_v2`, which succeeds even with statements still
        outstanding — they are finalized as they are released. Only call this
        when you want the error surfaced or the handle gone before scope end.
        """
        if self._handle == 0:
            return
        var rc = Int(external_call["sqlite3_close_v2", c_int](self._handle))
        self._handle = 0
        if rc != SQLITE_OK:
            raise Error("sqlite3_close_v2 failed: " + errstr(rc))


# --- Constructors ----------------------------------------------------------


def open(path: String) raises -> Connection:
    """Open read-write, creating the file if absent, tuned for a server.

    `journal_mode=WAL` lets readers and a writer proceed concurrently, and
    `synchronous=NORMAL` is the standard pairing: durable across process crashes
    and only at risk from an OS-level crash, which is the trade every serious
    WAL deployment makes. `foreign_keys=ON` because SQLite defaults it off for
    backward compatibility and almost nobody wants that.
    """
    var db = Connection(
        path,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
    )
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA foreign_keys=ON")
    return db^


def open_readonly(path: String) raises -> Connection:
    """Open read-only — the shape a read replica or a serve path would use."""
    return Connection(path, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)


def open_memory() raises -> Connection:
    """Open a private in-memory database.

    WAL does not apply to `:memory:`, so this skips the journal pragmas.
    """
    var db = Connection(
        MEMORY, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    )
    db.execute("PRAGMA foreign_keys=ON")
    return db^


def open_serialized(path: String) raises -> Connection:
    """Open with SQLite's full mutex, for sharing one connection across threads.

    Prefer a connection per thread; this exists for when that is not possible.
    """
    var db = Connection(
        path,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
    )
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA foreign_keys=ON")
    return db^
