"""SQLSTATE: the five-character code every Postgres error carries.

The twin of `m0-sqlite`'s `describe` / `error_code`. A Mojo `Error` is only
text, so the code travels in the message — every error raised from this
package that had one ends in `(sqlstate=42P01)` — and `sqlstate(String(e))`
recovers it:

    try:
        conn.execute("INSERT INTO users (name) VALUES ('ada')")
    except e:
        if sqlstate(String(e)) == UNIQUE_VIOLATION:
            ...

Which codes are named here is the set a server application can do something
about: retry (serialization failure, deadlock), report to a user (the
constraint violations), reconnect (the shutdown and connection classes),
size a pool (too many connections), or fix a query (the syntax and undefined
classes). Everything else is text.

**Codes are five characters, not numbers**, and the digits are not decimal:
`42P01` and `40P01` both carry a letter in the middle. Comparing them as
integers, which the SQLite twin can do with its `rc`, is not available here —
so the constants are strings and the recovery reads a fixed five-character
field rather than scanning digits.
"""


comptime SQLSTATE_LEN: Int = 5
"""Every SQLSTATE is exactly five characters: a two-character class and a
three-character subclass. Fixed width is what makes the recovery below a
slice rather than a scan."""

# --- Class 08 — connection exception ---
comptime CONNECTION_EXCEPTION = "08000"
comptime CONNECTION_FAILURE = "08006"
"""The connection broke mid-statement. With `ADMIN_SHUTDOWN`, the pair a
pool thread meets when the server restarts under it."""

# --- Class 23 — integrity constraint violation ---
comptime NOT_NULL_VIOLATION = "23502"
comptime FOREIGN_KEY_VIOLATION = "23503"
comptime UNIQUE_VIOLATION = "23505"
comptime CHECK_VIOLATION = "23514"

# --- Class 25 — invalid transaction state ---
comptime READ_ONLY_SQL_TRANSACTION = "25006"
"""What a write meets on a connection opened by `open_readonly`. Named so an
application can tell "this connection may not write" from "this role may
not write" (`INSUFFICIENT_PRIVILEGE`), which are different mistakes."""

# --- Class 40 — transaction rollback ---
comptime SERIALIZATION_FAILURE = "40001"
comptime DEADLOCK_DETECTED = "40P01"
"""The two that mean "try the whole transaction again". This package does
not retry on its own: a hidden retry of a transaction whose effects the
caller cannot see is a hidden double write."""

# --- Class 42 — syntax error or access rule violation ---
comptime SYNTAX_ERROR = "42601"
comptime INSUFFICIENT_PRIVILEGE = "42501"
comptime UNDEFINED_COLUMN = "42703"
comptime UNDEFINED_TABLE = "42P01"
comptime UNDEFINED_FUNCTION = "42883"

# --- Class 53 — insufficient resources ---
comptime TOO_MANY_CONNECTIONS = "53300"
"""`FATAL: sorry, too many clients already`. The failure a server holding one
connection per pool thread per mount reaches first, and the reason
`--doctor` prints the count it will open."""

comptime OUT_OF_MEMORY = "53200"
comptime DISK_FULL = "53100"

# --- Class 55 — object not in prerequisite state ---
comptime LOCK_NOT_AVAILABLE = "55P03"

# --- Class 57 — operator intervention ---
comptime QUERY_CANCELED = "57014"
"""What the statement timeout `open` applies produces. Distinguishable from
a connection loss, which is what makes a slow query reportable as a slow
query."""

comptime ADMIN_SHUTDOWN = "57P01"
comptime CRASH_SHUTDOWN = "57P02"
comptime CANNOT_CONNECT_NOW = "57P03"

# --- Class 3D / 28 — the two a misconfigured URL produces ---
comptime INVALID_CATALOG_NAME = "3D000"
"""The database named in the URL does not exist."""

comptime INVALID_PASSWORD = "28P01"
comptime INVALID_AUTHORIZATION = "28000"


def is_connection_lost(state: String) -> Bool:
    """Whether this code means the connection is gone, not the statement.

    The question `Connection.healthy` answers after the fact and a guard asks
    before deciding to reset. Class 08 is the connection class outright; the
    three 57 codes are the server going away underneath, which reaches the
    client as a failed statement and leaves the handle dead either way.
    """
    return (
        state.startswith("08")
        or state == ADMIN_SHUTDOWN
        or state == CRASH_SHUTDOWN
        or state == CANNOT_CONNECT_NOW
    )


def is_retryable(state: String) -> Bool:
    """Whether re-running the whole transaction is the documented answer.

    True for exactly the two class-40 codes. Not a retry policy — this
    package has none — but the predicate an application's own policy asks,
    so that "which errors are these again?" is answered once here rather
    than as a literal in every caller.
    """
    return state == SERIALIZATION_FAILURE or state == DEADLOCK_DETECTED


def describe(what: String, state: String, message: String) -> String:
    """Uniform error text ending in the SQLSTATE.

    The code goes LAST, for the reason `m0-sqlite`'s `describe_in` puts its
    result code last: `sqlstate` recovers the code from the end, so anything
    appended after it makes the code silently unrecoverable.
    """
    var detail = String(message.strip())
    if not detail:
        detail = String("(no message)")
    if len(state.as_bytes()) != SQLSTATE_LEN:
        return "PQ" + what + " failed: " + detail
    return "PQ" + what + " failed: " + detail + " (sqlstate=" + state + ")"


def describe_in(
    what: String, state: String, message: String, context: String
) -> String:
    """`describe`, plus the SQL the failing call was made against.

    The context is the SQL and NEVER the connection URL: a URL carries a
    password in its authority, and an error message is the most widely
    copied string a server produces. `redact` in `url.mojo` is what the
    paths that must name a URL go through.
    """
    var detail = String(message.strip())
    if not detail:
        detail = String("(no message)")
    var head = "PQ" + what + " failed: " + detail + " [" + context + "]"
    if len(state.as_bytes()) != SQLSTATE_LEN:
        return head
    return head + " (sqlstate=" + state + ")"


def sqlstate(message: String) -> String:
    """The SQLSTATE carried by an error raised from this package, or "".

    Reads the fixed-width field from the end: `(sqlstate=XXXXX)` is the last
    16 bytes of any message that has one.
    """
    var b = message.as_bytes()
    var n = len(b)
    comptime OPEN = "(sqlstate="
    var open_len = len(OPEN.as_bytes())
    var want = open_len + SQLSTATE_LEN + 1
    if n < want:
        return String("")
    if b[n - 1] != UInt8(ord(")")):
        return String("")
    var start = n - want
    var ob = OPEN.as_bytes()
    for i in range(open_len):
        if b[start + i] != ob[i]:
            return String("")
    return String(unsafe_from_utf8=b[start + open_len : n - 1])
