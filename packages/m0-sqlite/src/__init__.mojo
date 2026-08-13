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

Depends on nothing else in this repo — it is a sibling of `m0-core` and
`m0-http`, not a layer on top of them.
"""

from .ffi import (
    libversion,
    errstr,
    c_string,
    SQLITE_OK,
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
)
