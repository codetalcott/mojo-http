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
    errstr,
    error_code,
    db_errmsg,
    c_string,
    SQLITE_OK,
    SQLITE_BUSY,
    SQLITE_ROW,
    SQLITE_DONE,
    SQLITE_INTEGER,
    SQLITE_FLOAT,
    SQLITE_TEXT,
    SQLITE_BLOB,
    SQLITE_NULL,
    SQLITE_OPEN_READONLY,
    SQLITE_OPEN_READWRITE,
    SQLITE_OPEN_CREATE,
)
from .stmt import Statement
from .conn import (
    Connection,
    open,
    open_readonly,
    open_memory,
    open_serialized,
    MEMORY,
    DEFAULT_BUSY_TIMEOUT_MS,
)
