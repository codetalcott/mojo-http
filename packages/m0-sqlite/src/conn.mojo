"""Database connections.

`Connection` owns its `sqlite3*` and closes it on destruction. Like `Statement`
it is `Movable` but not `Copyable`, so a handle cannot be duplicated into a
second owner that would close it twice.

**Threading.** This package opens connections with `SQLITE_OPEN_NOMUTEX` — one
connection per thread or per process, which is also what the multi-worker fork
model in `m0-http` implies. Do not share a `Connection` across threads.
`open_serialized` is provided for the case where you must; its
`SQLITE_OPEN_FULLMUTEX` selects serialized mode per connection whatever the
library's compiled default is (macOS ships `THREADSAFE=2`, multi-thread).
"""

from std.ffi import external_call, c_int
from std.memory import Pointer, stack_allocation

from .ffi import (
    SQLITE_OK,
    SQLITE_OPEN_READONLY,
    SQLITE_OPEN_READWRITE,
    SQLITE_OPEN_CREATE,
    SQLITE_OPEN_NOMUTEX,
    SQLITE_OPEN_FULLMUTEX,
    c_string,
    describe,
    describe_in,
    libversion,
    libversion_number,
    db_errmsg,
    check_c_int_length,
)
from .stmt import Statement
from .vtab import _register, SQLITE_MIN_VTAB_VERSION


comptime MEMORY = ":memory:"
"""Path for a private, in-memory database. Ideal for tests."""

comptime DEFAULT_BUSY_TIMEOUT_MS = 5000
"""How long a file-backed connection waits for a lock before giving up.

Without a busy handler SQLite fails a contended write *immediately*: a second
connection meeting an open write transaction gets "database is locked" with no
wait and no retry. That is the wrong default anywhere two connections exist,
and two connections is the normal case here — WAL exists to let a writer and
readers overlap, and `m0-http` with `M0_WORKERS>1` forks a process per worker,
each holding its own connection to the same file.
"""


def _tail_is_blank(sql: String, start: Int) -> Bool:
    """Whether everything from `start` on is whitespace, separators or comments.

    Comments count as blank because SQLite compiles them to nothing:
    `prepare("SELECT 1; -- note")` carries one statement, not a script. An
    unterminated block comment runs to the end of the text, as SQLite's own
    tokenizer treats it.
    """
    var bytes = sql.as_bytes()
    var n = len(bytes)
    var i = start
    while i < n:
        var c = bytes[i]
        # space, tab, newline, carriage return, vertical tab, form feed, ';'
        if c == 32 or c == 9 or c == 10 or c == 13 or c == 11 or c == 12 or c == 59:
            i += 1
        elif c == 45 and i + 1 < n and bytes[i + 1] == 45:  # "--" to end of line
            i += 2
            while i < n and bytes[i] != 10:
                i += 1
        elif c == 47 and i + 1 < n and bytes[i + 1] == 42:  # "/*" to "*/"
            i += 2
            while i + 1 < n and not (bytes[i] == 42 and bytes[i + 1] == 47):
                i += 1
            if i + 1 >= n:
                return True
            i += 2
        else:
            return False
    return True


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
            # Read the message before closing: the handle is what carries it.
            var detail = String("")
            if self._handle != 0:
                detail = self.errmsg()
                # close_v2 everywhere: statements outliving their connection is
                # a property this package relies on, and only close_v2 has it.
                _ = external_call["sqlite3_close_v2", c_int](self._handle)
                self._handle = 0
            raise Error(describe_in("open_v2", rc, detail, path))

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
            raise Error(describe_in("exec", rc, self.errmsg(), sql))

    def prepare(self, sql: String) raises -> Statement:
        """Compile exactly one statement.

        The byte length is passed explicitly rather than -1, so this does not
        depend on Mojo's String NUL termination.

        Two things SQLite reports as success are treated as errors here, both
        because the alternative is silence:

        - **Text after the first statement.** `sqlite3_prepare_v2` compiles the
          first statement and hands back a pointer to the rest, which this used
          to discard — so `prepare("INSERT ...; INSERT ...")` ran one of the two
          and reported nothing. Use `execute` for a script.
        - **Text that compiles to no statement at all** (empty, whitespace, or
          only comments). SQLite returns OK with a NULL handle, which would
          become a `Statement` whose first `step` calls `sqlite3_step(NULL)`.
        """
        var pstmt = stack_allocation[1, Int]()
        pstmt[unsafe_offset=0] = 0
        var ptail = stack_allocation[1, Int]()
        ptail[unsafe_offset=0] = 0
        check_c_int_length("prepare_v2", len(sql.as_bytes()))
        var base = sql.unsafe_ptr()
        var rc = Int(
            external_call["sqlite3_prepare_v2", c_int](
                self._handle,
                base,
                c_int(len(sql.as_bytes())),
                pstmt,
                ptail,
            )
        )
        if rc != SQLITE_OK:
            raise Error(describe_in("prepare_v2", rc, self.errmsg(), sql))

        var handle = pstmt[unsafe_offset=0]
        if handle == 0:
            raise Error(
                "sqlite3_prepare_v2 compiled no statement — the text is empty,"
                " whitespace or comments only [" + sql + "]"
            )

        var tail = ptail[unsafe_offset=0]
        if tail != 0 and not _tail_is_blank(sql, tail - Int(base)):
            # Finalize before raising: this path owns the handle and no
            # Statement has been constructed to release it.
            _ = external_call["sqlite3_finalize", c_int](handle)
            raise Error(
                "sqlite3_prepare_v2 left "
                + String(len(sql.as_bytes()) - (tail - Int(base)))
                + " bytes uncompiled — prepare() takes one statement, use"
                " execute() for a script [" + sql + "]"
            )

        return Statement(handle)

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
        """Rows modified since this connection was opened.

        Counted by `sqlite3_total_changes`, which returns a C `int` and so
        wraps past 2^31 — reachable for a long-lived server process, if not a
        short one. `sqlite3_total_changes64` fixes it and needs SQLite 3.37,
        which would raise the floor for the whole package rather than just for
        `m0_array`; not worth it for a counter. Treat this as advisory.
        """
        return Int(external_call["sqlite3_total_changes", c_int](self._handle))

    def errmsg(self) -> String:
        """Text of the most recent error on this connection."""
        return db_errmsg(self._handle)

    def query_scalar(self, sql: String) raises -> String:
        """Run a one-row, one-column query and return the value as text.

        For pragmas and counts, where preparing a statement by hand to read a
        single cell is all ceremony.
        """
        var q = self.prepare(sql)
        if not q.step():
            return String("")
        return q.column_text(0)

    def mmap_size(self, bytes_: Int) raises:
        """Map up to `bytes_` of the database file into the process.

        Worth 40% on random reads over a database larger than the page cache
        (see docs/SQLITE_PERFORMANCE.md). Deliberately **not** applied by
        `open`, because it changes how failures present: with memory-mapped
        I/O, a disk error that would have surfaced as `SQLITE_IOERR` arrives
        instead as a SIGBUS, and a stray write in this process can reach the
        database file rather than being caught at the syscall boundary. That
        trade belongs to the application that knows its storage, not to a
        default.

        Capped by the library's `SQLITE_MAX_MMAP_SIZE` (1 GB on macOS); a
        larger request is silently clamped, so read back with
        `query_scalar("PRAGMA mmap_size")` if the exact value matters.
        """
        self.execute("PRAGMA mmap_size=" + String(bytes_))

    def busy_timeout(self, milliseconds: Int) raises:
        """Wait up to `milliseconds` for a lock before failing with SQLITE_BUSY.

        Applied by every file-backed constructor; call this to override it. A
        non-positive value removes the handler and restores SQLite's default of
        failing instantly.

        This is not a substitute for `begin_immediate`. The handler cannot help
        a deferred transaction that has already read and then tries to upgrade
        to a write — SQLite must return SQLITE_BUSY there rather than wait,
        because waiting could not preserve what the transaction already read.
        """
        var rc = Int(
            external_call["sqlite3_busy_timeout", c_int](
                self._handle, c_int(milliseconds)
            )
        )
        if rc != SQLITE_OK:
            raise Error(describe("busy_timeout", rc, self.errmsg()))

    def register_array_module(mut self) raises:
        """Make `m0_array(?)` available on this connection.

        A table-valued function that streams a Mojo `List` without copying it,
        so N rows can be inserted with one `sqlite3_step`:

            db.register_array_module()
            var ins = db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
            ins.execute_over(1, values)

        Per connection, not per process, and not done by default — it is only
        worth its cost if you use it. Arrays may only be bound through the
        `Statement.*_over` helpers; see the note above them for why.

        Raises on SQLite older than 3.26.0. `sqlite3_bind_pointer` arrived in
        3.20.0, but the planner's side of the contract — SQLITE_CONSTRAINT
        from xBestIndex meaning "reject this plan", which `m0_array` uses to
        refuse a scan without its array — is only honoured from 3.26.0, and on
        the versions between, that refusal fails legitimate queries. A
        pre-3.20 build would already be a hard failure — a missing symbol at
        link time on Linux, at load time on macOS — but an unresolved symbol
        names neither the feature that wanted it nor the version that would
        provide it, so it is worth saying plainly here.
        """
        var have = libversion_number()
        if have < SQLITE_MIN_VTAB_VERSION:
            raise Error(
                "m0_array needs SQLite 3.26.0 or newer (sqlite3_bind_pointer"
                " and the SQLITE_CONSTRAINT xBestIndex contract), but this"
                " build links "
                + libversion()
                + " ("
                + String(have)
                + ")"
            )
        _register(self._handle)

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
            # No errmsg(): the handle this would ask is the one just closed.
            raise Error(describe("close_v2", rc, String("")))


# --- Constructors ----------------------------------------------------------


def open(path: String) raises -> Connection:
    """Open read-write, creating the file if absent, tuned for a server.

    `journal_mode=WAL` lets readers and a writer proceed concurrently, and
    `synchronous=NORMAL` is the standard pairing: durable across process crashes
    and only at risk from an OS-level crash, which is the trade every serious
    WAL deployment makes. `foreign_keys=ON` because SQLite defaults it off for
    backward compatibility and almost nobody wants that.

    **Raises on any database that cannot do WAL** — `:memory:`, a temp database
    (`""`), some network filesystems. That is not a special case to work
    around; WAL is the promise this constructor makes, and `_set_wal` explains
    why delivering silently less is worse than failing. For an in-memory
    database use `open_memory`, which makes no such promise. Note that `MEMORY`
    is exported alongside this, so `open(MEMORY)` is easy to write by mistake —
    it raises, naming the mode SQLite reported instead.
    """
    var db = Connection(
        path,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
    )
    db.busy_timeout(DEFAULT_BUSY_TIMEOUT_MS)
    _set_wal(db, path)
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA foreign_keys=ON")
    return db^


def _set_wal(mut db: Connection, path: String) raises:
    """Switch to WAL and confirm SQLite agreed.

    `PRAGMA journal_mode` answers with the mode actually in force, and the
    request can fail quietly — a database on a network filesystem, or one
    already open elsewhere in a conflicting mode, stays on a rollback journal
    and reports "delete". Discarding that row means `open` promises WAL's
    reader/writer concurrency while delivering a lock that serializes them,
    which surfaces later as inexplicable contention rather than as an error
    here.
    """
    var mode = db.query_scalar("PRAGMA journal_mode=WAL").lower()
    if mode != "wal":
        raise Error(
            "journal_mode=WAL was not applied to "
            + path
            + " (SQLite reports '"
            + mode
            + "'); this database cannot provide WAL concurrency"
        )


def open_readonly(path: String) raises -> Connection:
    """Open read-only — the shape a read replica or a serve path would use.

    Readers in WAL rarely block, but they are not immune: a checkpoint or a
    recovery still needs an exclusive moment, so the timeout applies here too.
    """
    var db = Connection(path, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
    db.busy_timeout(DEFAULT_BUSY_TIMEOUT_MS)
    return db^


def open_memory() raises -> Connection:
    """Open a private in-memory database.

    WAL does not apply to `:memory:`, so this skips the journal pragmas — and
    the busy timeout, since a private in-memory database has exactly one
    connection and nothing to contend with.
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
    db.busy_timeout(DEFAULT_BUSY_TIMEOUT_MS)
    _set_wal(db, path)
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA foreign_keys=ON")
    return db^
