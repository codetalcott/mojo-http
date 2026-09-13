"""Connections: one per thread, with the defaults a server wants applied.

`Connection` owns its `PGconn *` and finishes it on destruction. `Movable`
and not `Copyable`, for `m0-sqlite`'s reason: a copy would duplicate the
handle and the second destructor would finish an already-finished
connection.

**One connection per thread, never shared.** libpq permits concurrent use of
DISTINCT connections and nothing else — the same rule `m0-sqlite` states as
`SQLITE_OPEN_NOMUTEX` — so a mounted application builds its connection in
`PoolHandler.make`, which runs on the pool thread that will use it, and
keeps it beside its `Views` table. The pool starts after `fork_all()`
returns, so a connection is never inherited across a fork, which would give
two processes one socket and one server one confused backend.

**Count them before deploying.** Workers times blocking threads times
Postgres-backed mounts, plus one for a listener, is what this server opens;
a default `max_connections` of 100 is reached by four workers of eight
threads across three mounts. That arithmetic is finding 3 of
docs/REAL_APP_VALIDATION.md, met by an application rather than by this
package, and the answer is a role with a `CONNECTION LIMIT`, a pooler, or
fewer threads — not a retry.

**Transactions are explicit calls, not a scope guard**, because Mojo has no
`defer` and a guard whose destructor rolled back would make control flow
depend on drop order. Same decision, same words, as `m0-sqlite`.

**Losing the server is the application's decision to handle.** `healthy` is
`PQstatus`, `reset` is `PQreset` plus re-`LISTEN`, and there is no automatic
retry anywhere: re-running a statement whose effects the caller cannot see
is a hidden double write. The guard shape the framework layer already uses —
an early return of `Optional[HTTPResponse]` — is where a policy belongs.
"""

from std.collections.span import Span
from std.ffi import c_int
from std.memory import Pointer

from .lib import (
    CONNECTION_OK,
    FORMAT_BINARY,
    FORMAT_TEXT,
    PG_DIAG_SQLSTATE,
    PGRES_COMMAND_OK,
    PGRES_EMPTY_QUERY,
    PGRES_FATAL_ERROR,
    PGRES_NONFATAL_ERROR,
    PGRES_TUPLES_OK,
    PQTRANS_IDLE,
    PQTRANS_INERROR,
    PQTRANS_INTRANS,
    PgLib,
    as_cstr,
    c_string,
    read_cstr,
)
from .params import ParamArrays, Params
from .result import Result
from .sqlstate import describe, describe_in, is_connection_lost
from .url import read_only as _read_only_url
from .url import redact, redact_message, with_defaults
from .wire import OID_UNKNOWN


struct Notification(Movable, Copyable):
    """One `NOTIFY`, as `PQnotifies` reports it.

    The three public fields of `PGnotify`; the fourth is a list link libpq
    owns and the header says so. `payload` is the empty string when the
    notifier sent none, which is not distinguishable from an empty one —
    `NOTIFY c, ''` and `NOTIFY c` arrive identically, which is Postgres's
    behaviour, not a loss here.
    """

    var channel: String
    var backend_pid: Int
    var payload: String

    def __init__(out self, var channel: String, backend_pid: Int, var payload: String):
        self.channel = channel^
        self.backend_pid = backend_pid
        self.payload = payload^


struct Prepared(Movable, Copyable):
    """A server-side prepared statement: its name, its SQL, its parameter OIDs.

    A VALUE, not a handle — which is the third way this package differs from
    `m0-sqlite`. A server-side prepared statement lives on the `PGconn` and
    dies with it, so a `Prepared` that owned something would be a
    use-after-free of the connection the moment it outlived it; and a
    borrowing form cannot be written, because origins are not spellable as
    struct parameters on this toolchain (D4's constraint, in another place).

    So it is inert data and every execution goes through the connection that
    prepared it. Using one on a different connection is an error the SERVER
    reports (`prepared statement "m0_3" does not exist`), which is the
    honest place for it: only the server knows what it has.
    """

    var name: String
    var sql: String
    var oids: List[Int]

    def __init__(out self, var name: String, var sql: String, var oids: List[Int]):
        self.name = name^
        self.sql = sql^
        self.oids = oids^


struct Connection(Movable):
    """An open database connection. Finished when it goes out of scope."""

    var _handle: Int
    var _lib: PgLib
    """This connection's own table, and the `dlopen` handle inside it.

    Held here rather than shared, because `PgLib` owns an `OwnedDLHandle`
    that must not be duplicated and must outlive every call made through
    it — `lib.mojo`'s first rule. One `dlopen` per connection is one per
    thread in every shape this package is used in, and `dlopen` of an
    already-loaded library is a refcount bump.
    """

    var _listening: List[String]
    """Channels this connection has been told to LISTEN on, so `reset` can
    restore them. A reset connection is a NEW backend session and remembers
    nothing: without this, a listener survives its reconnection and then
    silently hears nothing for the life of the process."""

    var _next_statement: Int
    var url_for_logs: String
    """The connection string with its password masked — the only form kept.

    Redacted at construction rather than at each use, so no path can print
    the original by forgetting: the original is not stored anywhere.
    """

    def __init__(out self, var lib: PgLib, url: String) raises:
        """Connect with the string exactly as given, applying no defaults.

        Prefer `open` or `open_readonly`. This exists for a caller that has
        assembled the whole conninfo itself and means it.
        """
        var safe = redact(url)
        var conninfo = c_string(url)
        var handle = lib.connectdb(as_cstr(conninfo))
        # `conninfo` is named and used after the call on every path, which is
        # what keeps libpq from parsing a freed buffer (lib.mojo, rule 2).
        var parsed_bytes = len(conninfo)
        if handle == 0:
            raise Error(
                "libpq could not allocate a connection for " + safe
                + " (" + String(parsed_bytes) + " bytes of conninfo)"
)
        if lib.status(handle) != CONNECTION_OK:
            # libpq quotes pieces of a string it could not parse — half an
            # unencoded password, measured — so its text goes through the
            # same redaction as the URL it is printed beside.
            var detail = redact_message(
                String(read_cstr(lib.errmsg(handle)).strip()), url
            )
            lib.finish(handle)
            raise Error(
                "could not connect to " + safe + ": " + detail
)
        self._handle = handle
        self._lib = lib^
        self._listening = List[String]()
        self._next_statement = 0
        self.url_for_logs = safe^

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self._lib = move._lib^
        self._listening = move._listening^
        self._next_statement = move._next_statement
        self.url_for_logs = move.url_for_logs^

    def __deinit__(deinit self):
        if self._handle != 0:
            self._lib.finish(self._handle)

    # --- State -------------------------------------------------------------

    def healthy(self) -> Bool:
        """Whether libpq still considers this connection usable.

        `PQstatus` is local and cheap: it reports what the last operation
        left behind, not a round trip. A connection the server closed
        between statements reads OK here until the next statement fails,
        which is why a guard asks this AND branches on the SQLSTATE.
        """
        return self._handle != 0 and self._lib.status(self._handle) == CONNECTION_OK

    def server_version(self) -> Int:
        """The server's version as an integer, `170006` for 17.6."""
        return self._lib.server_version(self._handle)

    def backend_pid(self) -> Int:
        """The server-side process id — what a `NOTIFY` reports as its source."""
        return self._lib.backend_pid(self._handle)

    def socket_fd(self) -> Int:
        """The connection's file descriptor, for a poll that waits on it.

        The listener's whole mechanism: park in `poll(2)` on this and a
        shutdown pipe, and a notification is a readable event rather than a
        thread spinning.
        """
        return self._lib.socket(self._handle)

    def in_transaction(self) -> Bool:
        """Whether a transaction is open, INCLUDING a failed one.

        `INERROR` counts: a transaction that has hit an error is still open
        and still holds its locks, and only `ROLLBACK` ends it. Reporting it
        as "not in a transaction" is how a connection gets handed back to a
        pool holding locks.
        """
        var st = self._lib.transaction_status(self._handle)
        return st == PQTRANS_INTRANS or st == PQTRANS_INERROR

    def errmsg(self) -> String:
        """The most recent error on this connection, as libpq worded it."""
        return String(read_cstr(self._lib.errmsg(self._handle)).strip())

    # --- Statements --------------------------------------------------------

    def execute(mut self, sql: String) raises:
        """Run one or more statements, discarding any rows.

        For DDL, `SET`, and one-shot writes. Takes no parameters BY DESIGN,
        the rule `m0-sqlite`'s `execute` keeps: a call that accepts both SQL
        and values invites building the one from the other, and this way a
        concatenated query cannot be written without noticing which function
        was reached for.
        """
        var text = c_string(sql)
        var res = self._lib.exec(self._handle, as_cstr(text))
        var held = len(text)
        _ = held
        self._raise_on_error(res, sql)
        self._lib.clear(res)

    def query(
        mut self, sql: String, params: Params, binary: Bool = False
    ) raises -> Result:
        """Run one parameterized statement and take the whole result.
        One statement only: `PQexecParams` refuses multiple, which is the
        same protection `m0-sqlite`'s `prepare` builds by hand. Parameters
        are `$1`, `$2`, … in the order they were added.
        """
        var text = c_string(sql)
        var arrays = ParamArrays(params)
        var res = self._lib.exec_params(
            self._handle,
            as_cstr(text),
            len(params),
            arrays.oids_addr(),
            arrays.values_addr(),
            arrays.lengths_addr(),
            arrays.formats_addr(),
            FORMAT_BINARY if binary else FORMAT_TEXT,
        )
        # Both the SQL buffer and the four arrays are named after the call.
        # `arrays` points into `params`, which the caller owns for longer
        # than this frame; these two lines are what say so to the compiler.
        var held = len(text) + len(arrays.values)
        _ = held
        self._raise_on_error(res, sql)
        return Result(res, self._lib.result_lib(), binary)

    def prepare(mut self, sql: String, oids: List[Int]) raises -> Prepared:
        """Prepare a statement on the server under a generated name.

        The name is this connection's own counter, so two prepares of the
        same SQL are two statements rather than a silent collision, and a
        name can never clash with one an application made itself unless it
        also uses the `m0_` prefix.

        The OIDs fix the parameter types now, which is the point: a prepared
        statement's plan depends on them, and passing a `Params` whose types
        disagree is caught here rather than by the server on every
        execution.
        """
        var name = "m0_" + String(self._next_statement)
        self._next_statement += 1
        var cname = c_string(name)
        var text = c_string(sql)
        var type_array = List[Int32](capacity=len(oids))
        for o in oids:
            type_array.append(Int32(o))
        var res = self._lib.prepare(
            self._handle,
            as_cstr(cname),
            as_cstr(text),
            len(oids),
            Int(type_array.unsafe_ptr()) if len(type_array) else 0,
)
        var held = len(cname) + len(text) + len(type_array)
        _ = held
        self._raise_on_error(res, sql)
        self._lib.clear(res)
        return Prepared(name^, sql, oids.copy())

    def query_prepared(
        mut self, statement: Prepared, params: Params, binary: Bool = False
    ) raises -> Result:
        """Execute a prepared statement.
        The parameter types are checked against the ones the statement was
        prepared with, before any round trip: a mismatch would otherwise be
        a server error on every execution, or — worse, where the OIDs are
        merely compatible — a different plan than the one that was prepared.
        """
        if len(params) != len(statement.oids):
            raise Error(
                "`" + statement.name + "` was prepared with "
                + String(len(statement.oids)) + " parameters and was given "
                + String(len(params)) + " [" + statement.sql + "]"
)
        for i in range(len(params)):
            var want = statement.oids[i]
            var got = params.oid_at(i)
            if want != got and want != OID_UNKNOWN and got != OID_UNKNOWN:
                raise Error(
                    "parameter $" + String(i + 1) + " of `" + statement.name
                    + "` was prepared as OID " + String(want)
                    + " and was given OID " + String(got)
                    + " [" + statement.sql + "]"
)
        var cname = c_string(statement.name)
        var arrays = ParamArrays(params)
        var res = self._lib.exec_prepared(
            self._handle,
            as_cstr(cname),
            len(params),
            arrays.values_addr(),
            arrays.lengths_addr(),
            arrays.formats_addr(),
            FORMAT_BINARY if binary else FORMAT_TEXT,
        )
        var held = len(cname) + len(arrays.values)
        _ = held
        self._raise_on_error(res, statement.sql)
        return Result(res, self._lib.result_lib(), binary)

    def close_prepared(mut self, statement: Prepared) raises:
        """Release a prepared statement on the server.

        `DEALLOCATE`, not `PQclosePrepared`, which needs libpq 17 and would
        raise this package's floor from 12 for a call most applications
        never make. A mount prepares its handful once and keeps them for the
        thread's life; this is for an application that prepares from user
        input and must not grow a statement per request.
        """
        self.execute("DEALLOCATE " + self.quote_identifier(statement.name))

    def quote_identifier(mut self, name: String) raises -> String:
        """Quote an identifier the way the SERVER would.

        `PQescapeIdentifier` knows the connection's encoding and the
        server's quoting rules, which a hand-rolled doubling of `"` does
        not. Used by `listen`, `unlisten` and `close_prepared`, the three
        places this package puts a name into SQL text — because a channel
        name is frequently application input and `LISTEN` takes no
        parameters.
        """
        var raw = c_string(name)
        var quoted = self._lib.escape_identifier(
            self._handle, as_cstr(raw), len(name.as_bytes())
)
        var held = len(raw)
        _ = held
        if quoted == 0:
            raise Error(
                "PQescapeIdentifier refused `" + name + "`: " + self.errmsg()
)
        var out = read_cstr(quoted)
        self._lib.freemem(quoted)
        return out^

    # --- Transactions ------------------------------------------------------

    def begin(mut self) raises:
        self.execute("BEGIN")

    def commit(mut self) raises:
        self.execute("COMMIT")

    def rollback(mut self) raises:
        self.execute("ROLLBACK")

    # --- LISTEN / NOTIFY ---------------------------------------------------

    def listen(mut self, channel: String) raises:
        """Ask the server to deliver `NOTIFY` on this channel to us.

        Recorded, so `reset` can restore it: a reconnected connection is a
        new session that is listening to nothing, and a listener that does
        not re-`LISTEN` goes quiet in a way that looks exactly like nobody
        publishing.
        """
        self.execute("LISTEN " + self.quote_identifier(channel))
        for existing in self._listening:
            if existing == channel:
                return
        self._listening.append(channel)

    def unlisten(mut self, channel: String) raises:
        self.execute("UNLISTEN " + self.quote_identifier(channel))
        var kept = List[String]()
        for existing in self._listening:
            if existing != channel:
                kept.append(existing)
        self._listening = kept^

    def notifies(mut self) raises -> Optional[Notification]:
        """The next notification already delivered to us, if any.

        Consumes whatever the socket holds first (`PQconsumeInput`), so this
        is complete rather than merely non-blocking: a caller polling this
        after a readable event gets every notification that arrived, one
        call at a time, until it answers None.

        The three public `PGnotify` fields are read by OFFSET — 0, 8, 16 on
        a 64-bit target — because the struct's fourth field is a list link
        libpq owns and Mojo cannot vary a struct's layout by target. The
        offsets are asserted against the real header by this package's own
        layout check, the way `m0-sqlite`'s virtual-table offsets are.
        """
        if self._lib.consume_input(self._handle) == 0:
            raise Error(
                describe("consumeInput", String(""), self.errmsg())
)
        var note = self._lib.notifies(self._handle)
        if note == 0:
            return None
        var relname = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=note
        )[]
        var pid = Int(
            Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=note + 8)[]
        )
        var extra = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=note + 16
        )[]
        var out = Notification(read_cstr(relname), pid, read_cstr(extra))
        # libpq allocated it; PQfreemem is the only correct free, because on
        # some platforms the library's allocator is not the caller's.
        self._lib.freemem(note)
        return out^
    def reset(mut self) raises:
        """Reconnect, and restore every channel this connection was listening to.

        The second half is the part that is easy to leave out and impossible
        to notice: `PQreset` opens a NEW backend session, which is listening
        to nothing, so a listener that reset without this would run forever
        delivering no notifications and logging no error.
        """
        self._lib.reset(self._handle)
        if self._lib.status(self._handle) != CONNECTION_OK:
            raise Error(
                "could not reconnect to " + self.url_for_logs + ": "
                + self.errmsg()
)
        var channels = self._listening.copy()
        self._listening = List[String]()
        for channel in channels:
            self.listen(channel)

    def close(mut self):
        """Finish early. Idempotent; `__deinit__` also finishes.

        Does not raise: `PQfinish` returns nothing and reports nothing, and
        there is no error a caller could act on after the fact.
        """
        if self._handle == 0:
            return
        self._lib.finish(self._handle)
        self._handle = 0

    # --- Errors ------------------------------------------------------------

    def _raise_on_error(mut self, res: Int, context: String) raises:
        """Raise unless the result is a successful one, then clear it.

        A NULL result means the connection itself failed, not the statement:
        there is no `PGresult` to read a SQLSTATE from, so the message comes
        from the connection. Every other failure carries its SQLSTATE, which
        is what `sqlstate()` recovers from the message.
        """
        if res == 0:
            raise Error(
                describe_in("exec", String(""), self.errmsg(), context)
            )
        var status = self._lib.result_status(res)
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
        ):
            return
        var state = read_cstr(
            self._lib.result_errfield(res, PG_DIAG_SQLSTATE)
)
        var message = String(read_cstr(self._lib.result_errmsg(res)).strip())
        self._lib.clear(res)
        raise Error(describe_in("exec", state, message, context))


# --- Constructors ----------------------------------------------------------


def open(url: String) raises -> Connection:
    """Connect with this package's server defaults applied.

    A connect timeout, `client_encoding=UTF8`, an application name, a
    statement timeout, and TCP keepalive timings with `tcp_user_timeout`
    so a dropped connection is noticed in about a minute — `url.mojo` says what each is for and merges rather
    than appends, so every one of them is overridable by naming it in the
    URL. The shape `m0-sqlite`'s `open` has: a constructor that makes
    promises a server wants, beside a bare one that makes none.
    """
    var lib = PgLib.open()
    return Connection(lib^, with_defaults(url))


def open_readonly(url: String) raises -> Connection:
    """`open`, plus a transaction default that refuses every write.

    The belt to a read-only ROLE's braces. The role is the guard that
    matters — it is what an audit reads — and this is what turns a mistake
    in its grants into an error on the connection that should not be
    writing, rather than a write that succeeds. SQLSTATE 25006.
    """
    var lib = PgLib.open()
    return Connection(lib^, _read_only_url(url))


def connect_with(var lib: PgLib, url: String) raises -> Connection:
    """`open`, for a caller that has already opened libpq.

    The listener uses this: it holds a `PgLib` for its own reasons and
    should not `dlopen` a second time to make a connection.
    """
    return Connection(lib^, with_defaults(url))
