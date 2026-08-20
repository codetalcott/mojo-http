"""`m0-sqlite`: SQLite bindings for Mojo.

A thin, honest layer over the SQLite C API — no ORM, no query builder, no
connection pool. `Connection` and `Statement` own their handles and release
them on destruction; both are `Movable` but not `Copyable`, so a handle cannot
be duplicated into a second owner.

    from m0_sqlite import open_memory

    var db = open_memory()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

    var ins = db.prepare("INSERT INTO t (name) VALUES (?)")
    ins.bind_text(1, "ada")       # parameters are 1-based
    _ = ins.step()

    var q = db.prepare("SELECT id, name FROM t")
    while q.step():
        print(q.column_int(0), q.column_text(1))   # columns are 0-based

For bulk work there is `m0_array(?)`, an opt-in virtual table that streams a
Mojo `List` into SQL without copying it, so N rows insert in one step rather
than N (~3x on 10k and 200k rows):

    db.register_array_module()
    var ins = db.prepare("INSERT INTO t (name) SELECT value FROM m0_array(?1)")
    ins.execute_over(1, values)

Arrays are only bindable through `Statement.execute_over` / `fetch_ints_over`,
which take the array as an argument and finish the statement before returning.
That is not a convenience — it is what keeps the borrow safe; see the note
above those methods in `stmt.mojo`.

Depends on nothing else in this repo — it is a sibling of `m0-core` and
`m0-http`, not a layer on top of them.
"""

from .ffi import (
    libversion,
    libversion_number,
    errstr,
    error_code,
    db_errmsg,
    c_string,
    # Result codes. `error_code` hands back one of these, so the set worth
    # exporting is the set worth branching on — which is why SQLITE_CONSTRAINT
    # and SQLITE_RANGE are here and were not before, despite this package's own
    # tests having to spell them 19 and 25 with a comment.
    SQLITE_OK,
    SQLITE_ERROR,
    SQLITE_PERM,
    SQLITE_ABORT,
    SQLITE_BUSY,
    SQLITE_LOCKED,
    SQLITE_NOMEM,
    SQLITE_READONLY,
    SQLITE_INTERRUPT,
    SQLITE_IOERR,
    SQLITE_CORRUPT,
    SQLITE_FULL,
    SQLITE_CANTOPEN,
    SQLITE_CONSTRAINT,
    SQLITE_MISMATCH,
    SQLITE_MISUSE,
    SQLITE_RANGE,
    SQLITE_NOTADB,
    # Not returned by `error_code` — `step` maps them to Bool — but exported so
    # the mapping is nameable when reading the source.
    SQLITE_ROW,
    SQLITE_DONE,
    # Column types, as returned by `Statement.column_type`.
    SQLITE_INTEGER,
    SQLITE_FLOAT,
    SQLITE_TEXT,
    SQLITE_BLOB,
    SQLITE_NULL,
    # Open flags, for the explicit `Connection(path, flags)` constructor. The
    # mutex flags are here because the package's own constructors use them:
    # without them a caller assembling a custom flag set cannot reproduce the
    # threading model `open` picks.
    SQLITE_OPEN_READONLY,
    SQLITE_OPEN_READWRITE,
    SQLITE_OPEN_CREATE,
    SQLITE_OPEN_NOMUTEX,
    SQLITE_OPEN_FULLMUTEX,
)
from .stmt import Statement
from .reduce import ColumnStats, sum_ints, min_ints, max_ints, stats_ints
from .conn import (
    Connection,
    open,
    open_readonly,
    open_memory,
    open_serialized,
    MEMORY,
    DEFAULT_BUSY_TIMEOUT_MS,
)
