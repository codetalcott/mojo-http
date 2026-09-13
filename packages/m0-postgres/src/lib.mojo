"""`libpq`, reached by `dlopen` — the function table and the rules that keep it alive.

`m0-sqlite` links the system SQLite, because libsqlite3 sits in the dyld
shared cache on macOS and `external_call` resolves it for free. libpq is not
like that: Homebrew's is keg-only (`/opt/homebrew/lib/postgresql@17`), on no
default linker or loader path, and a bare `dlopen("libpq.5.dylib")` fails
naming nine directories it tried. Linking it would need a `-L` and an rpath
into a directory that exists on one machine — the defect `scripts/relocate.py`
exists to repair for libpython — and would put libpq on the link line of
every binary that imports this package, `bin/m0serve` and the wheel included.

So the library is opened at run time and every entry point resolved once,
through the stdlib's own mechanism: `ExternalFunction[name, type].load(
handle.borrow())`, which is how `std.python._cpython` populates its
bindings and how `m0-wsgi/src/bridge.mojo` reaches the two `PyBytes_*`
functions `CPython` leaves out. An absent library is then one raised error
naming the paths tried, rather than a link failure or a load-time abort.

**Three rules here are load-bearing, and all three were found by crashing.**
(`~/dev` probes, 2026-09-12; the write-ups are in this module's tests.)

  - **The handle and the pointers loaded from it live in ONE struct.** A
    loaded pointer carries no borrow of the handle it came from, so an
    `OwnedDLHandle` held anywhere else is `dlclose`d at its last mention —
    Mojo destroys a value at its last use — and the next call through any
    pointer jumps into unmapped memory. Measured both ways: the last
    `.load()` of a sequence aborted with `symbol not found` for a symbol
    `nm` showed present, and on a branch ending in `return` the first call
    after the handle's last use took `EXC_BAD_ACCESS`. This is the
    mechanism `OwnedDLHandle.get_function`'s own docstring warns about.
    `PgLib` therefore holds `_lib` as its first field and every caller
    keeps the `PgLib` alive for as long as it calls through it.

  - **Every `const char *` parameter is typed as a pointer, never as `Int`.**
    An `Int(buf.unsafe_ptr())` argument erases the origin, so the `List` it
    came from is dead before the call: libpq parsed a freed buffer three
    times out of three and connected to the wrong socket as the wrong user,
    reporting a plausible authentication failure. Typed
    `Pointer[UInt8, ImmutAnyOrigin]` and passed as
    `buf.unsafe_ptr().as_imm().as_unsafe_any_origin()` — bridge.mojo's own
    spelling — the buffer survived the call three times out of three.

  - **libpq is never unloaded while the process lives.** `PgLib.__init__`
    re-opens the image it was handed with `RTLD_NODELETE`, which marks it
    so that no `dlclose` ever unmaps it (`pin_library`). Without it the library was unmapped when the LAST
    `PgLib` went — which is when the last `Connection` went, at its last
    use — and a `Result` read after that jumped into unloaded code:
    `var rows = db.query(...)` with no later mention of `db`, then
    `rows.text(0, 0)`, was a segmentation fault three runs out of three,
    and the same program with a second `PgLib` held alive for the run read
    the row correctly. The pin is what lets the entry points a `Result`
    needs be COPIED out (`ResultLib`) rather than reached through the
    connection's address, which a move or a destruction leaves dangling.
    The cost is one library's pages kept mapped by a process that already
    chose to load it; nothing here ever reloads it, so nothing is lost.

Opaque handles (`PGconn *`, `PGresult *`, `PGnotify *`) travel as `Int`, as
`sqlite3 *` does in `m0-sqlite`: they are opaque to us, and an integer is
the honest representation. Only BUFFERS need the origin, because only
buffers are ours to keep alive.

`load` ABORTS the process on a missing symbol rather than raising, so every
symbol is probed with `check_symbol` first and a libpq too old to carry one
is an error naming the symbol.
"""

from std.collections.span import Span
from std.ffi import OwnedDLHandle, c_int
from std.memory import Pointer
from std.python._cpython import ExternalFunction
from std.sys import CompilationTarget
from std.os import getenv


comptime CStr = Pointer[UInt8, ImmutAnyOrigin]
"""A `const char *` argument: typed, so the buffer outlives the call."""

comptime MIN_LIBPQ_VERSION: Int = 120000
"""`libpq` 12.0, the floor.

Nothing here needs a newer entry point — `PQlibVersion` is ancient,
`PQresultErrorField` is from 7.4 — so the floor is set by what is still
supported upstream rather than by a symbol. Checked at open, where the
version is a number, rather than discovered later as a missing symbol.
"""

# --- Connection ------------------------------------------------------------
comptime CONNECTION_OK: Int = 0
comptime CONNECTION_BAD: Int = 1

# --- Result status (ExecStatusType) ----------------------------------------
comptime PGRES_EMPTY_QUERY: Int = 0
comptime PGRES_COMMAND_OK: Int = 1
comptime PGRES_TUPLES_OK: Int = 2
comptime PGRES_COPY_OUT: Int = 3
comptime PGRES_COPY_IN: Int = 4
comptime PGRES_BAD_RESPONSE: Int = 5
comptime PGRES_NONFATAL_ERROR: Int = 6
comptime PGRES_FATAL_ERROR: Int = 7

# --- Transaction status (PGTransactionStatusType) --------------------------
comptime PQTRANS_IDLE: Int = 0
comptime PQTRANS_ACTIVE: Int = 1
comptime PQTRANS_INTRANS: Int = 2
comptime PQTRANS_INERROR: Int = 3
comptime PQTRANS_UNKNOWN: Int = 4

comptime PG_DIAG_SQLSTATE: Int = 67
"""`'C'`. `PQresultErrorField` takes the diagnostic's character as an int."""

comptime PG_DIAG_MESSAGE_PRIMARY: Int = 77
"""`'M'`."""

comptime FORMAT_TEXT: Int = 0
comptime FORMAT_BINARY: Int = 1


# --- The C signatures ------------------------------------------------------
#
# Opaque handles as Int; buffers as CStr; void returns as None. Each is the
# declaration libpq-fe.h carries, transcribed — the comment above each is
# that line.

comptime _PQlibVersion = ExternalFunction[
    "PQlibVersion", def() thin abi("C") -> c_int
]
comptime _PQisthreadsafe = ExternalFunction[
    "PQisthreadsafe", def() thin abi("C") -> c_int
]
comptime _PQconnectdb = ExternalFunction[
    # PGconn *PQconnectdb(const char *conninfo)
    "PQconnectdb", def(CStr) thin abi("C") -> Int
]
comptime _PQfinish = ExternalFunction[
    "PQfinish", def(Int) thin abi("C") -> None
]
comptime _PQreset = ExternalFunction["PQreset", def(Int) thin abi("C") -> None]
comptime _PQstatus = ExternalFunction[
    "PQstatus", def(Int) thin abi("C") -> c_int
]
comptime _PQtransactionStatus = ExternalFunction[
    "PQtransactionStatus", def(Int) thin abi("C") -> c_int
]
comptime _PQerrorMessage = ExternalFunction[
    # char *PQerrorMessage(const PGconn *conn) — libpq's buffer, not ours
    "PQerrorMessage", def(Int) thin abi("C") -> Int
]
comptime _PQserverVersion = ExternalFunction[
    "PQserverVersion", def(Int) thin abi("C") -> c_int
]
comptime _PQbackendPID = ExternalFunction[
    "PQbackendPID", def(Int) thin abi("C") -> c_int
]
comptime _PQsocket = ExternalFunction[
    "PQsocket", def(Int) thin abi("C") -> c_int
]
comptime _PQexec = ExternalFunction[
    # PGresult *PQexec(PGconn *conn, const char *query)
    "PQexec", def(Int, CStr) thin abi("C") -> Int
]
comptime _PQexecParams = ExternalFunction[
    # PGresult *PQexecParams(PGconn *, const char *command, int nParams,
    #   const Oid *paramTypes, const char *const *paramValues,
    #   const int *paramLengths, const int *paramFormats, int resultFormat)
    "PQexecParams",
    def(Int, CStr, c_int, Int, Int, Int, Int, c_int) thin abi("C") -> Int,
]
comptime _PQprepare = ExternalFunction[
    # PGresult *PQprepare(PGconn *, const char *stmtName, const char *query,
    #   int nParams, const Oid *paramTypes)
    "PQprepare", def(Int, CStr, CStr, c_int, Int) thin abi("C") -> Int
]
comptime _PQexecPrepared = ExternalFunction[
    # PGresult *PQexecPrepared(PGconn *, const char *stmtName, int nParams,
    #   const char *const *paramValues, const int *paramLengths,
    #   const int *paramFormats, int resultFormat)
    "PQexecPrepared",
    def(Int, CStr, c_int, Int, Int, Int, c_int) thin abi("C") -> Int,
]
comptime _PQresultStatus = ExternalFunction[
    "PQresultStatus", def(Int) thin abi("C") -> c_int
]
comptime _PQresultErrorMessage = ExternalFunction[
    "PQresultErrorMessage", def(Int) thin abi("C") -> Int
]
comptime _PQresultErrorField = ExternalFunction[
    "PQresultErrorField", def(Int, c_int) thin abi("C") -> Int
]
comptime _PQntuples = ExternalFunction[
    "PQntuples", def(Int) thin abi("C") -> c_int
]
comptime _PQnfields = ExternalFunction[
    "PQnfields", def(Int) thin abi("C") -> c_int
]
comptime _PQfname = ExternalFunction[
    "PQfname", def(Int, c_int) thin abi("C") -> Int
]
comptime _PQftype = ExternalFunction[
    "PQftype", def(Int, c_int) thin abi("C") -> c_int
]
comptime _PQfformat = ExternalFunction[
    "PQfformat", def(Int, c_int) thin abi("C") -> c_int
]
comptime _PQgetvalue = ExternalFunction[
    "PQgetvalue", def(Int, c_int, c_int) thin abi("C") -> Int
]
comptime _PQgetlength = ExternalFunction[
    "PQgetlength", def(Int, c_int, c_int) thin abi("C") -> c_int
]
comptime _PQgetisnull = ExternalFunction[
    "PQgetisnull", def(Int, c_int, c_int) thin abi("C") -> c_int
]
comptime _PQcmdTuples = ExternalFunction[
    "PQcmdTuples", def(Int) thin abi("C") -> Int
]
comptime _PQclear = ExternalFunction["PQclear", def(Int) thin abi("C") -> None]
comptime _PQconsumeInput = ExternalFunction[
    "PQconsumeInput", def(Int) thin abi("C") -> c_int
]
comptime _PQnotifies = ExternalFunction[
    "PQnotifies", def(Int) thin abi("C") -> Int
]
comptime _PQfreemem = ExternalFunction[
    "PQfreemem", def(Int) thin abi("C") -> None
]
comptime _PQescapeIdentifier = ExternalFunction[
    # char *PQescapeIdentifier(PGconn *, const char *str, size_t len)
    "PQescapeIdentifier", def(Int, CStr, Int) thin abi("C") -> Int
]


def _pin_flags() -> Int:
    """`RTLD_LAZY | RTLD_GLOBAL | RTLD_NODELETE`, the mode the pin re-opens with.

    **A binding mode is not optional, and leaving it out broke Linux.**
    glibc's `dlopen` refuses a mode carrying neither `RTLD_LAZY` (1) nor
    `RTLD_NOW` (2): measured against `libpq.so.5` in a `bookworm` container,
    `RTLD_GLOBAL | RTLD_NODELETE` (256 | 0x1000) fails with
    `invalid mode for dlopen(): Invalid argument`, while both
    `1 | 256 | 0x1000` and `2 | 256 | 0x1000` open and keep the image mapped
    after every handle is closed. macOS is lenient where glibc is not, so a
    mode missing it passes every local run and fails only the Linux job —
    which is exactly what happened, and why the flags are written here as a
    measurement rather than as a guess at another module's default.

    `RTLD_LAZY` rather than `RTLD_NOW`, because this is a RE-open of an image
    already loaded: `RTLD_NOW` would upgrade it to eager binding the first
    open never asked for, so a libpq with a transitive symbol resolvable only
    lazily would fail the pin and make `PgLib.open` raise on a host where the
    library works. Lazy asks for nothing the first open did not.

    The stdlib's own default is deliberately not named here. `std` ships as a
    `.mojoc` with no source, so any claim about it is unverifiable from this
    tree — and a wrong one was how the missing binding mode got in.
    `RTLD_NODELETE` is 0x1000 in glibc's `dlfcn.h` and 0x80 in macOS's, and
    both loaders promote an already-loaded image to it on a re-open.
    """
    comptime if CompilationTarget.is_macos():
        return 1 | 8 | 0x80
    else:
        return 1 | 256 | 0x1000


def pin_library(path: String) raises:
    """Keep the library at `path` loaded for the life of the process.

    A second `dlopen` of the image the caller already holds, flagged
    `RTLD_NODELETE`, which both glibc and dyld apply to an image that is
    already loaded: from then on no `dlclose` unmaps it, this handle's own
    included — so the handle is let go at once, and what remains is the
    flag. Through `OwnedDLHandle` rather than a hand-declared `dlopen`,
    because the stdlib already declares that symbol and a second, different
    declaration does not compile. The module docstring's third rule says
    why this exists.
    """
    try:
        var pin = OwnedDLHandle(path, _pin_flags())
        _ = pin.check_symbol("PQlibVersion")
    except e:
        raise Error(
            "the library at " + path + " opened once and could not be"
            " pinned for the life of the process (" + String(e) + "); a"
            " result read after its connection closed would call into"
            " unloaded code"
        )


def default_search_path() -> List[String]:
    """Where to look for libpq when `M0_LIBPQ` does not say.

    Bare names first: on a distribution that ships `libpq5`, or in a
    container built to have it, the loader finds it by name and the rest of
    this list never runs. Then the places a package manager puts a keg-only
    or versioned build, newest first. The whole list appears in the error
    when none of them opens, because "libpq not found" without the paths
    tried is the least actionable message a server can print.
    """
    var out = List[String]()

    comptime if CompilationTarget.is_macos():
        out.append("libpq.5.dylib")
        out.append("/opt/homebrew/opt/libpq/lib/libpq.5.dylib")
        for v in ["18", "17", "16", "15", "14"]:
            out.append("/opt/homebrew/lib/postgresql@" + v + "/libpq.5.dylib")
            out.append("/usr/local/lib/postgresql@" + v + "/libpq.5.dylib")
        out.append("/usr/local/opt/libpq/lib/libpq.5.dylib")
        out.append("/usr/local/lib/libpq.5.dylib")
        out.append("/Library/PostgreSQL/17/lib/libpq.5.dylib")
        out.append("/Library/PostgreSQL/16/lib/libpq.5.dylib")
    else:
        out.append("libpq.so.5")
        out.append("/usr/lib/x86_64-linux-gnu/libpq.so.5")
        out.append("/usr/lib/aarch64-linux-gnu/libpq.so.5")
        out.append("/usr/lib64/libpq.so.5")
        out.append("/usr/local/pgsql/lib/libpq.so.5")
    return out^


struct PgLib(Movable):
    """An open libpq and every entry point this package uses.

    One struct on purpose: see the module docstring's first rule. The handle
    must outlive every call made through the pointers beside it, and the
    only way to say that in Mojo 1.0 — where a loaded pointer carries no
    borrow — is to give them the same lifetime.

    Built once per thread and kept for that thread's life. Opening costs a
    `dlopen` and ~35 `dlsym`s; a call through a stored pointer costs a
    measured ≤1 ns, against ~100 ns for resolving the symbol per call, which
    is what `OwnedDLHandle.get_function` does.
    """

    var _lib: OwnedDLHandle
    """First field, and the reason this struct exists."""

    var path: String
    """Which file was opened — reported by `--doctor`, never guessed at."""

    var _libversion: _PQlibVersion.type
    var _isthreadsafe: _PQisthreadsafe.type
    var _connectdb: _PQconnectdb.type
    var _finish: _PQfinish.type
    var _reset: _PQreset.type
    var _status: _PQstatus.type
    var _transaction_status: _PQtransactionStatus.type
    var _errmsg: _PQerrorMessage.type
    var _server_version: _PQserverVersion.type
    var _backend_pid: _PQbackendPID.type
    var _socket: _PQsocket.type
    var _exec: _PQexec.type
    var _exec_params: _PQexecParams.type
    var _prepare: _PQprepare.type
    var _exec_prepared: _PQexecPrepared.type
    var _result_status: _PQresultStatus.type
    var _result_errmsg: _PQresultErrorMessage.type
    var _result_errfield: _PQresultErrorField.type
    var _ntuples: _PQntuples.type
    var _nfields: _PQnfields.type
    var _fname: _PQfname.type
    var _ftype: _PQftype.type
    var _fformat: _PQfformat.type
    var _getvalue: _PQgetvalue.type
    var _getlength: _PQgetlength.type
    var _getisnull: _PQgetisnull.type
    var _cmd_tuples: _PQcmdTuples.type
    var _clear: _PQclear.type
    var _consume_input: _PQconsumeInput.type
    var _notifies: _PQnotifies.type
    var _freemem: _PQfreemem.type
    var _escape_identifier: _PQescapeIdentifier.type
    """Every entry point, private.

    Private because a `thin` pointer FIELD cannot be called as
    `value.field()` from outside the struct that holds it — measured on
    this toolchain: the same pointer, identical by address before and
    after, jumps into unmapped memory called that way and answers
    correctly called from a method beside it. So each one gets a wrapper
    below, which is where every call in this package goes.
    """

    def __init__(out self, var handle: OwnedDLHandle, var path: String) raises:
        """Resolve every entry point from an already-open handle.

        Private in effect: `open` is the constructor callers use. Every
        symbol is checked before it is loaded, because `load` aborts the
        process on a missing one — a libpq too old, or a library that is not
        libpq at all, must be an error naming the symbol rather than a
        stack trace with no cause in it.
        """
        # First, so no path out of this constructor leaves a table whose
        # library can be unmapped under it (the third rule).
        pin_library(path)
        for name in required_symbols():
            if not handle.check_symbol(name):
                raise Error(
                    "the library at " + path + " has no symbol `" + name
                    + "` — this is either not libpq, or a libpq older than"
                    + " 12.0, the oldest this package supports"
                )
        self._libversion = _PQlibVersion.load(handle.borrow())
        self._isthreadsafe = _PQisthreadsafe.load(handle.borrow())
        self._connectdb = _PQconnectdb.load(handle.borrow())
        self._finish = _PQfinish.load(handle.borrow())
        self._reset = _PQreset.load(handle.borrow())
        self._status = _PQstatus.load(handle.borrow())
        self._transaction_status = _PQtransactionStatus.load(handle.borrow())
        self._errmsg = _PQerrorMessage.load(handle.borrow())
        self._server_version = _PQserverVersion.load(handle.borrow())
        self._backend_pid = _PQbackendPID.load(handle.borrow())
        self._socket = _PQsocket.load(handle.borrow())
        self._exec = _PQexec.load(handle.borrow())
        self._exec_params = _PQexecParams.load(handle.borrow())
        self._prepare = _PQprepare.load(handle.borrow())
        self._exec_prepared = _PQexecPrepared.load(handle.borrow())
        self._result_status = _PQresultStatus.load(handle.borrow())
        self._result_errmsg = _PQresultErrorMessage.load(handle.borrow())
        self._result_errfield = _PQresultErrorField.load(handle.borrow())
        self._ntuples = _PQntuples.load(handle.borrow())
        self._nfields = _PQnfields.load(handle.borrow())
        self._fname = _PQfname.load(handle.borrow())
        self._ftype = _PQftype.load(handle.borrow())
        self._fformat = _PQfformat.load(handle.borrow())
        self._getvalue = _PQgetvalue.load(handle.borrow())
        self._getlength = _PQgetlength.load(handle.borrow())
        self._getisnull = _PQgetisnull.load(handle.borrow())
        self._cmd_tuples = _PQcmdTuples.load(handle.borrow())
        self._clear = _PQclear.load(handle.borrow())
        self._consume_input = _PQconsumeInput.load(handle.borrow())
        self._notifies = _PQnotifies.load(handle.borrow())
        self._freemem = _PQfreemem.load(handle.borrow())
        self._escape_identifier = _PQescapeIdentifier.load(handle.borrow())
        self.path = path^
        # Last, so the handle's own last mention is after every load above.
        self._lib = handle^

    def __init__(out self, *, deinit move: Self):
        self._lib = move._lib^
        self.path = move.path^
        self._libversion = move._libversion
        self._isthreadsafe = move._isthreadsafe
        self._connectdb = move._connectdb
        self._finish = move._finish
        self._reset = move._reset
        self._status = move._status
        self._transaction_status = move._transaction_status
        self._errmsg = move._errmsg
        self._server_version = move._server_version
        self._backend_pid = move._backend_pid
        self._socket = move._socket
        self._exec = move._exec
        self._exec_params = move._exec_params
        self._prepare = move._prepare
        self._exec_prepared = move._exec_prepared
        self._result_status = move._result_status
        self._result_errmsg = move._result_errmsg
        self._result_errfield = move._result_errfield
        self._ntuples = move._ntuples
        self._nfields = move._nfields
        self._fname = move._fname
        self._ftype = move._ftype
        self._fformat = move._fformat
        self._getvalue = move._getvalue
        self._getlength = move._getlength
        self._getisnull = move._getisnull
        self._cmd_tuples = move._cmd_tuples
        self._clear = move._clear
        self._consume_input = move._consume_input
        self._notifies = move._notifies
        self._freemem = move._freemem
        self._escape_identifier = move._escape_identifier

    def libversion(self) -> Int:
        """`PQlibversion`."""
        return Int(self._libversion())

    def isthreadsafe(self) -> Int:
        """`PQisthreadsafe`."""
        return Int(self._isthreadsafe())

    def connectdb(self, conninfo: CStr) -> Int:
        """`PQconnectdb`."""
        return Int(self._connectdb(conninfo))

    def finish(self, conn: Int):
        """`PQfinish`."""
        self._finish(conn)

    def reset(self, conn: Int):
        """`PQreset`."""
        self._reset(conn)

    def status(self, conn: Int) -> Int:
        """`PQstatus`."""
        return Int(self._status(conn))

    def transaction_status(self, conn: Int) -> Int:
        """`PQtransaction_status`."""
        return Int(self._transaction_status(conn))

    def errmsg(self, conn: Int) -> Int:
        """`PQerrmsg`."""
        return Int(self._errmsg(conn))

    def server_version(self, conn: Int) -> Int:
        """`PQserver_version`."""
        return Int(self._server_version(conn))

    def backend_pid(self, conn: Int) -> Int:
        """`PQbackend_pid`."""
        return Int(self._backend_pid(conn))

    def socket(self, conn: Int) -> Int:
        """`PQsocket`."""
        return Int(self._socket(conn))

    def exec(self, conn: Int, query: CStr) -> Int:
        """`PQexec`."""
        return Int(self._exec(conn, query))

    def exec_params(self, conn: Int, command: CStr, n: Int, types: Int, values: Int, lengths: Int, formats: Int, result_format: Int) -> Int:
        """`PQexec_params`."""
        return Int(self._exec_params(conn, command, c_int(n), types, values, lengths, formats, c_int(result_format)))

    def prepare(self, conn: Int, name: CStr, query: CStr, n: Int, types: Int) -> Int:
        """`PQprepare`."""
        return Int(self._prepare(conn, name, query, c_int(n), types))

    def exec_prepared(self, conn: Int, name: CStr, n: Int, values: Int, lengths: Int, formats: Int, result_format: Int) -> Int:
        """`PQexec_prepared`."""
        return Int(self._exec_prepared(conn, name, c_int(n), values, lengths, formats, c_int(result_format)))

    def result_status(self, res: Int) -> Int:
        """`PQresult_status`."""
        return Int(self._result_status(res))

    def result_errmsg(self, res: Int) -> Int:
        """`PQresult_errmsg`."""
        return Int(self._result_errmsg(res))

    def result_errfield(self, res: Int, field: Int) -> Int:
        """`PQresult_errfield`."""
        return Int(self._result_errfield(res, c_int(field)))

    def ntuples(self, res: Int) -> Int:
        """`PQntuples`."""
        return Int(self._ntuples(res))

    def nfields(self, res: Int) -> Int:
        """`PQnfields`."""
        return Int(self._nfields(res))

    def fname(self, res: Int, col: Int) -> Int:
        """`PQfname`."""
        return Int(self._fname(res, c_int(col)))

    def ftype(self, res: Int, col: Int) -> Int:
        """`PQftype`."""
        return Int(self._ftype(res, c_int(col)))

    def fformat(self, res: Int, col: Int) -> Int:
        """`PQfformat`."""
        return Int(self._fformat(res, c_int(col)))

    def getvalue(self, res: Int, row: Int, col: Int) -> Int:
        """`PQgetvalue`."""
        return Int(self._getvalue(res, c_int(row), c_int(col)))

    def getlength(self, res: Int, row: Int, col: Int) -> Int:
        """`PQgetlength`."""
        return Int(self._getlength(res, c_int(row), c_int(col)))

    def getisnull(self, res: Int, row: Int, col: Int) -> Int:
        """`PQgetisnull`."""
        return Int(self._getisnull(res, c_int(row), c_int(col)))

    def cmd_tuples(self, res: Int) -> Int:
        """`PQcmd_tuples`."""
        return Int(self._cmd_tuples(res))

    def clear(self, res: Int):
        """`PQclear`."""
        self._clear(res)

    def consume_input(self, conn: Int) -> Int:
        """`PQconsume_input`."""
        return Int(self._consume_input(conn))

    def notifies(self, conn: Int) -> Int:
        """`PQnotifies`."""
        return Int(self._notifies(conn))

    def freemem(self, ptr: Int):
        """`PQfreemem`."""
        self._freemem(ptr)

    def escape_identifier(self, conn: Int, text: CStr, length: Int) -> Int:
        """`PQescapeIdentifier`."""
        return Int(self._escape_identifier(conn, text, length))

    def result_lib(self) -> ResultLib:
        """The entry points a `Result` calls, copied out of this table.

        A copy is sound because of the third rule: the library these
        pointers came from is pinned for the life of the process, so they
        stay valid after this `PgLib` — and the `Connection` holding it —
        is gone.
        """
        return ResultLib(
            self._result_status,
            self._ntuples,
            self._nfields,
            self._fname,
            self._ftype,
            self._getvalue,
            self._getlength,
            self._getisnull,
            self._cmd_tuples,
            self._clear,
        )

    @staticmethod
    def open(path: String = "") raises -> Self:
        """Open libpq: `path`, else `M0_LIBPQ`, else the search path.

        The version floor and libpq's own thread-safety flag are checked
        here, where both are one call and the answer can name the library
        that failed. A libpq built without thread safety would be a data
        race per pool thread rather than an error, so it is refused.
        """
        var tried = List[String]()
        var candidates = List[String]()
        if path:
            candidates.append(path)
        else:
            var from_env = getenv("M0_LIBPQ", "")
            if from_env:
                candidates.append(from_env)
            else:
                candidates = default_search_path()

        for candidate in candidates:
            var handle: OwnedDLHandle
            try:
                handle = OwnedDLHandle(candidate)
            except:
                tried.append(candidate)
                continue
            var lib = Self(handle^, candidate)
            var have = lib.libversion()
            if have < MIN_LIBPQ_VERSION:
                raise Error(
                    "the libpq at " + candidate + " is version "
                    + String(have) + ", older than the "
                    + String(MIN_LIBPQ_VERSION) + " this package requires"
                )
            if lib.isthreadsafe() == 0:
                raise Error(
                    "the libpq at " + candidate + " was built without thread"
                    + " safety, and this package opens one connection per"
                    + " thread"
                )
            return lib^

        var names = String("")
        for i in range(len(tried)):
            names += ("\n  " if i else "") + tried[i]
        raise Error(
            "libpq could not be opened. Set M0_LIBPQ to the library file, or"
            + " install one where it can be found. Tried:\n  " + names
        )

    def version_text(self) -> String:
        """`libpq`'s version as `major.minor`, from its integer form."""
        var v = self.libversion()
        return String(v // 10000) + "." + String(v % 10000)


struct ResultLib(ImplicitlyCopyable, Movable):
    """The ten entry points a `Result` needs, held by value.

    A `Result` used to reach them through the address of its connection's
    `PgLib`, which dangles the moment that connection is moved or destroyed
    — and Mojo destroys a connection at its last use, so
    `var rows = db.query(...)` left `rows` reading a dead struct. A copy
    of the pointers needs nothing of the connection; the pin (the module
    docstring's third rule) is what keeps the code they point at mapped.

    Implicitly copyable, unlike `PgLib`, because it owns nothing: no handle, no
    buffer, only addresses into a library that is never unloaded.

    The fields are private and every call goes through a method beside
    them, for the same reason `PgLib`'s are: a `thin` pointer field called
    as `value.field()` from outside its struct faults.
    """

    var _result_status: _PQresultStatus.type
    var _ntuples: _PQntuples.type
    var _nfields: _PQnfields.type
    var _fname: _PQfname.type
    var _ftype: _PQftype.type
    var _getvalue: _PQgetvalue.type
    var _getlength: _PQgetlength.type
    var _getisnull: _PQgetisnull.type
    var _cmd_tuples: _PQcmdTuples.type
    var _clear: _PQclear.type

    def __init__(
        out self,
        result_status: _PQresultStatus.type,
        ntuples: _PQntuples.type,
        nfields: _PQnfields.type,
        fname: _PQfname.type,
        ftype: _PQftype.type,
        getvalue: _PQgetvalue.type,
        getlength: _PQgetlength.type,
        getisnull: _PQgetisnull.type,
        cmd_tuples: _PQcmdTuples.type,
        clear: _PQclear.type,
    ):
        """Built by `PgLib.result_lib`, which is where the pointers live."""
        self._result_status = result_status
        self._ntuples = ntuples
        self._nfields = nfields
        self._fname = fname
        self._ftype = ftype
        self._getvalue = getvalue
        self._getlength = getlength
        self._getisnull = getisnull
        self._cmd_tuples = cmd_tuples
        self._clear = clear

    def result_status(self, res: Int) -> Int:
        """`PQresultStatus`."""
        return Int(self._result_status(res))

    def ntuples(self, res: Int) -> Int:
        """`PQntuples`."""
        return Int(self._ntuples(res))

    def nfields(self, res: Int) -> Int:
        """`PQnfields`."""
        return Int(self._nfields(res))

    def fname(self, res: Int, col: Int) -> Int:
        """`PQfname`."""
        return Int(self._fname(res, c_int(col)))

    def ftype(self, res: Int, col: Int) -> Int:
        """`PQftype`."""
        return Int(self._ftype(res, c_int(col)))

    def getvalue(self, res: Int, row: Int, col: Int) -> Int:
        """`PQgetvalue`."""
        return Int(self._getvalue(res, c_int(row), c_int(col)))

    def getlength(self, res: Int, row: Int, col: Int) -> Int:
        """`PQgetlength`."""
        return Int(self._getlength(res, c_int(row), c_int(col)))

    def getisnull(self, res: Int, row: Int, col: Int) -> Int:
        """`PQgetisnull`."""
        return Int(self._getisnull(res, c_int(row), c_int(col)))

    def cmd_tuples(self, res: Int) -> Int:
        """`PQcmdTuples`."""
        return Int(self._cmd_tuples(res))

    def clear(self, res: Int):
        """`PQclear`."""
        self._clear(res)


def required_symbols() -> List[String]:
    """Every symbol `PgLib` loads, checked before any of them is loaded.

    A function rather than a `comptime` array because a comptime `Array`
    does not materialize into a runtime loop on this toolchain; the point —
    one place to edit, checked before the process can abort inside a
    `load` — is unchanged.
    """
    return [
        "PQlibVersion",
        "PQisthreadsafe",
        "PQconnectdb",
        "PQfinish",
        "PQreset",
        "PQstatus",
        "PQtransactionStatus",
        "PQerrorMessage",
        "PQserverVersion",
        "PQbackendPID",
        "PQsocket",
        "PQexec",
        "PQexecParams",
        "PQprepare",
        "PQexecPrepared",
        "PQresultStatus",
        "PQresultErrorMessage",
        "PQresultErrorField",
        "PQntuples",
        "PQnfields",
        "PQfname",
        "PQftype",
        "PQfformat",
        "PQgetvalue",
        "PQgetlength",
        "PQgetisnull",
        "PQcmdTuples",
        "PQclear",
        "PQconsumeInput",
        "PQnotifies",
        "PQfreemem",
        "PQescapeIdentifier",
    ]


# --- C string helpers ------------------------------------------------------


def c_string(s: String) -> List[UInt8]:
    """Copy a String into an explicitly NUL-terminated byte buffer.

    Mojo's `String` does not guarantee a NUL terminator, and every libpq
    entry point that takes text takes it NUL-terminated with no length.
    Same function, same reason, as `m0-sqlite`'s.

    The result must be kept alive across the call — that is the second rule
    in this module's docstring — which is why every caller here binds it to
    a named `var` and passes `.unsafe_ptr()` off that name.
    """
    var out = List[UInt8](capacity=len(s.as_bytes()) + 1)
    for b in s.as_bytes():
        out.append(b)
    out.append(0)
    return out^


def as_cstr(ref buf: List[UInt8]) -> CStr:
    """A typed `const char *` over a buffer the caller holds.

    The spelling `bridge.mojo` uses for the same purpose. Typed rather than
    `Int(...)`: an integer argument erases the origin and the buffer is
    freed before the call.
    """
    return buf.unsafe_ptr().as_imm().as_unsafe_any_origin()


def read_cstr(addr: Int) -> String:
    """A String from a NUL-terminated C string libpq owns.

    Answers "" for NULL rather than dereferencing it: several accessors
    return NULL for an out-of-range index or under OOM, and a Mojo 1.0
    pointer carries no nullability, so nothing upstream would notice.
    """
    if addr == 0:
        return String("")
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var n = 0
    while p[unsafe_offset=n] != 0:
        n += 1
    if n == 0:
        return String("")
    return String(unsafe_from_utf8=Span(unsafe_ptr=p, length=n))
