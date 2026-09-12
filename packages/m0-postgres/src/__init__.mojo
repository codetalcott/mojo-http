"""`m0-postgres`: PostgreSQL bindings for Mojo, over libpq.

A thin, honest layer over the libpq C API — no ORM, no query builder, no
connection pool. `Connection` owns its handle and finishes it on
destruction; `Result` owns its `PGresult` and clears it on destruction.
Both are `Movable` but not `Copyable`, so a handle cannot be duplicated into
a second owner that would release it twice.

    from m0_postgres import Params, open

    var db = open("postgres://localhost/app")
    db.execute("CREATE TABLE t (id bigserial PRIMARY KEY, name text)")

    var p = Params()
    p.text("ada")
    _ = db.query("INSERT INTO t (name) VALUES ($1)", p)

    var rows = db.query("SELECT id, name FROM t ORDER BY id", Params())
    for r in range(rows.rows):
        print(rows.int(r, 0), rows.text(r, 1))    # rows and columns are 0-based

**libpq is opened at run time, not linked.** Nothing in this repo carries a
libpq dependency on its link line, including `bin/m0serve` and the wheel, so
a server that never names a database never needs the library present. An
absent library is one raised error naming every path tried. `M0_LIBPQ` names
the file outright. See `lib.mojo`, whose three rules — the handle lives with
its function pointers, every buffer argument is typed as a pointer, and the
library is never unloaded once opened, which is what lets a `Result` outlive
its `Connection` — were each found by crashing.

**One connection per thread.** libpq permits concurrent use of distinct
connections and nothing else. A mounted Mojo application builds its
connection in `PoolHandler.make`, which runs on the thread that will use it.

Depends on nothing else in this repo — a sibling of `m0-core`, `m0-http` and
`m0-sqlite`, not a layer on any of them.
"""

from .lib import (
    CStr,
    MIN_LIBPQ_VERSION,
    PGRES_COMMAND_OK,
    PGRES_EMPTY_QUERY,
    PGRES_FATAL_ERROR,
    PGRES_TUPLES_OK,
    PgLib,
    default_search_path,
    required_symbols,
)
from .conn import (
    Connection,
    Notification,
    Prepared,
    connect_with,
    open,
    open_readonly,
)
from .params import Params
from .result import Result
from .sqlstate import (
    ADMIN_SHUTDOWN,
    CANNOT_CONNECT_NOW,
    CHECK_VIOLATION,
    CONNECTION_FAILURE,
    CRASH_SHUTDOWN,
    DEADLOCK_DETECTED,
    FOREIGN_KEY_VIOLATION,
    INSUFFICIENT_PRIVILEGE,
    INVALID_CATALOG_NAME,
    INVALID_PASSWORD,
    LOCK_NOT_AVAILABLE,
    NOT_NULL_VIOLATION,
    QUERY_CANCELED,
    READ_ONLY_SQL_TRANSACTION,
    SERIALIZATION_FAILURE,
    SYNTAX_ERROR,
    TOO_MANY_CONNECTIONS,
    UNDEFINED_COLUMN,
    UNDEFINED_FUNCTION,
    UNDEFINED_TABLE,
    UNIQUE_VIOLATION,
    is_connection_lost,
    is_retryable,
    sqlstate,
)
from .url import redact, redact_message, with_defaults
from .wire import (
    OID_BOOL,
    OID_BYTEA,
    OID_FLOAT4,
    OID_FLOAT8,
    OID_INT2,
    OID_INT4,
    OID_INT8,
    OID_JSON,
    OID_JSONB,
    OID_TEXT,
    OID_TIMESTAMP,
    OID_TIMESTAMPTZ,
    OID_UNKNOWN,
    OID_UUID,
    OID_VARCHAR,
    has_binary_decoder,
    type_name,
    unix_micros,
)
