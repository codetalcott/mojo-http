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
    `PgLib` therefore holds `_lib` as its first field, beside the table of
    pointers loaded from it (`PgFns`), and every caller keeps the `PgLib`
    alive for as long as it calls through it.

  - **Every `const char *` parameter is typed as a pointer, never as `Int`.**
    An `Int(buf.unsafe_ptr())` argument erases the origin, so the `List` it
    came from is dead before the call: libpq parsed a freed buffer three
    times out of three and connected to the wrong socket as the wrong user,
    reporting a plausible authentication failure. Typed
    `Pointer[UInt8, ImmutAnyOrigin]` and passed as
    `buf.unsafe_ptr().as_imm().as_unsafe_any_origin()` — bridge.mojo's own
    spelling — the buffer survived the call three times out of three.

  - **libpq is never unloaded while the process lives, and a reopen finds
    the image the first open pinned.** The first `PgLib` of an image
    re-opens it with `RTLD_NODELETE`, which marks it so that no `dlclose`
    ever unmaps it, and keeps that handle open for the life of the process
    (`pin_library`). Without the flag the library was unmapped when the
    LAST `PgLib` went — which is when the last `Connection` went, at its
    last use — and a `Result` read after that jumped into unloaded code:
    `var rows = db.query(...)` with no later mention of `db`, then
    `rows.text(0, 0)`, was a segmentation fault three runs out of three,
    and the same program with a second `PgLib` held alive for the run read
    the row correctly. The pin is what lets a `Result` hold a COPY of the
    table (`PgFns`, whole) rather than reach it through the connection's
    address, which a move or a destruction leaves dangling.
    The flag without the kept handle leaked on macOS (SPEC O24). There an
    image opened `RTLD_NODELETE` stays mapped after its last handle closes
    but leaves dyld's list, so the next open of the same path mapped a
    FRESH copy of libpq and of the eight libraries it brings: measured
    with Homebrew's build, a new image at every reopen. m0-sqlite found it
    (O23) and refuses a second image as well. This package does not: each
    image a process opens is pinned once, a second file's beside the
    first's (DECISIONS D49).
    The cost is one library's pages kept mapped by a process that already
    chose to load it.

Every handle is opened `RTLD_LOCAL` (`_open_flags`, `_pin_flags`), and that
is what makes a second libpq in the process sound, whoever loads it. With
this package's image in the loader's global scope, as `OwnedDLHandle`'s
default mode puts it, glibc binds the internal calls of any libpq loaded
later into this one, unless that build was linked `-Bsymbolic`. Measured on
Ubuntu 24.04 with its own libpq 16.15 opened first and psycopg-binary's
bundled 18.6 second: 70 of the second image's symbols bound into the
first, `PQconnectStart`, `PQconnectPoll` and `PQclear` among them, and a
connection attempt through the second crashed the process, three runs of
three, a `PGconn` built by one version walked by the other. With the first
image local, none bound and the attempt failed cleanly. The second library
need not be one this package opened: under `m0serve`, a Python application
on psycopg-binary loads its own after `--pg-listen` has loaded the
system's.
Nothing here needs the global scope: every entry point is looked up
through the handle.

Opaque handles (`PGconn *`, `PGresult *`, `PGnotify *`) travel as `Int`, as
`sqlite3 *` does in `m0-sqlite`: they are opaque to us, and an integer is
the honest representation. Only BUFFERS need the origin, because only
buffers are ours to keep alive.

`load` ABORTS the process on a missing symbol rather than raising, so every
entry point goes through `_checked`, which asks `check_symbol` first and
raises naming the symbol a libpq too old does not carry. Checking and
loading in one place is deliberate: they were two, and nothing held the
list of names in step with what was loaded.
"""

from std.atomic import Atomic
from std.collections.span import Span
from std.collections.string.string_span import _get_kgen_string
from std.ffi import OwnedDLHandle, c_int
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.python._cpython import ExternalFunction
from std.sys import CompilationTarget
from std.os import getenv

from .sqlstate import CHARACTER_NOT_IN_REPERTOIRE


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


def _open_flags() -> Int:
    """`RTLD_NOW | RTLD_LOCAL`, the mode every `PgLib` opens the library with.

    Local, and that is load-bearing on Linux (the module docstring): an
    image in the global scope captures the internal calls of any libpq
    loaded after it. `OwnedDLHandle`'s default is `RTLD_NOW | RTLD_GLOBAL`
    (`DEFAULT_RTLD`, printed: 258 on Linux, 10 on macOS), so the mode is
    spelled, and only its scope differs from what the package opened with
    before. `RTLD_LOCAL` is 0 in glibc's `dlfcn.h` and 4 in macOS's.
    """
    comptime if CompilationTarget.is_macos():
        return 2 | 4
    else:
        return 2


def _pin_flags() -> Int:
    """`RTLD_LAZY | RTLD_LOCAL | RTLD_NODELETE`, the mode the pin re-opens with.

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

    Local, for `_open_flags`' reason: a re-open that says `RTLD_GLOBAL`
    promotes an image opened local to the global scope, on both loaders
    (measured). The measurements above were taken with the global flag,
    which this mode carried until 2026-10-01.

    `RTLD_LAZY` rather than `RTLD_NOW`, because this is a RE-open of an image
    already loaded: `RTLD_NOW` would upgrade it to eager binding the first
    open never asked for, so a libpq with a transitive symbol resolvable only
    lazily would fail the pin and make `PgLib.open` raise on a host where the
    library works. Lazy asks for nothing the first open did not.

    `RTLD_NODELETE` is 0x1000 in glibc's `dlfcn.h` and 0x80 in macOS's, and
    both loaders promote an already-loaded image to it on a re-open.
    """
    comptime if CompilationTarget.is_macos():
        return 1 | 4 | 0x80
    else:
        return 1 | 0x1000


@no_inline
def _pinned_images_slot() -> Pointer[Int, MutUntrackedOrigin]:
    """Return the word holding the address of the newest `_Pinned` record, 0
    until the process first opens libpq.

    `@no_inline` IS LOAD-BEARING: `pop.global_alloc` is `Pure`, so an inlined
    copy of this accessor would make a word of its own (m0-http's
    `src/global_slot.mojo` holds the measurement; m0-sqlite's `lib.mojo`
    keeps its pin the same way), and a pin written through one copy would
    be invisible to a reader through another. `pin_library` reads the word
    back through `_pinned` to prove it is one.
    """
    return {
        _mlir_value = __mlir_op.`pop.global_alloc`[
            name = _get_kgen_string["m0_postgres_pinned_images"](),
            count = Int(1).__mlir_index__(),
            _type = Pointer[Int, MutUntrackedOrigin]._mlir_type,
            alignment = Int(8).__mlir_index__(),
        ]()
    }


@always_inline
def _pinned() -> Int:
    """The newest `_Pinned` record's address as every reader but the pin
    itself takes it: 0 before the first open."""
    return _pinned_images_slot()[]


struct _Pinned(Movable):
    """One libpq image this process has pinned, and the record pinned before
    it. Written once and never freed; `next` changes only before the record
    is published."""

    var image: Int
    """`PgFns.image` of the pinned library."""

    var next: Int
    """The address of the record pinned before this one, or 0."""

    def __init__(out self, image: Int, next: Int):
        self.image = image
        self.next = next


def _pinned_from(at: Int, image: Int) -> Bool:
    """Whether `image` is among the records from the one at `at` on."""
    var cursor = at
    while cursor != 0:
        ref record = Pointer[_Pinned, MutUntrackedOrigin](
            unsafe_from_address=cursor
        )[]
        if record.image == image:
            return True
        cursor = record.next
    return False


def is_pinned(image: Int) -> Bool:
    """Whether the libpq image `image` (`PgFns.image`) is pinned in this
    process: loaded for good, with a handle kept so a reopen finds it."""
    return _pinned_from(_pinned(), image)


def pinned_count() -> Int:
    """How many libpq images this process has pinned: one per library file
    it has opened, however many times it opened each."""
    var n = 0
    var cursor = _pinned()
    while cursor != 0:
        n += 1
        cursor = Pointer[_Pinned, MutUntrackedOrigin](
            unsafe_from_address=cursor
        )[].next
    return n


def pin_library(path: String, image: Int) raises:
    """Keep the library at `path`, whose image is `image`, loaded for the life
    of the process, and findable by the next open of the same file.

    The first call for an image pins it: a second `dlopen` of the image the
    caller already holds, flagged `RTLD_NODELETE`, which both glibc and dyld
    apply to an image that is already loaded, so that no `dlclose` unmaps
    it. Through `OwnedDLHandle` rather than a hand-declared `dlopen`,
    because the stdlib already declares that symbol and a second, different
    declaration does not compile. The module docstring's third rule says
    why the flag.

    That handle is then KEPT, never closed (SPEC O24). The flag was once
    thought to be all that remained of it, and on macOS it is not: an image
    opened `RTLD_NODELETE` stays mapped after its last `dlclose` but drops
    out of dyld's list, so the next `dlopen` of the same path maps a FRESH
    copy. A process whose last `PgLib` went and which then opened another —
    a connection per request, on one thread — mapped libpq again each time,
    with the libraries it brings. Measured with Homebrew's libpq: a new
    image at every reopen, one image with the handle kept. No libpq on
    macOS escapes it, none being in the dyld shared cache, and glibc keeps
    a `RTLD_NODELETE` object findable, which is why Linux never showed it.

    Every later call for a pinned image is a comparison and returns: one
    handle is kept per image, not one per `PgLib`. Images are compared by an
    entry point's address, never by path: two spellings of one file are one.

    A library that is ANOTHER image — a second libpq file — is pinned the
    same way, beside the first, and is not refused (DECISIONS D49).
    m0-sqlite refuses one because SQLite's file locks do not survive two
    copies of it; libpq has no such rule, so here the word names a list.

    Published by compare-and-swap, because pool threads open their first
    connections together; a thread that finds its image pinned by another
    meanwhile lets its own pin go, which unloads nothing while the winner's
    handle is open.
    """
    var word = Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=Int(_pinned_images_slot())
    )
    var head = Int(word[].load())
    if not _pinned_from(head, image):
        var pin: OwnedDLHandle
        try:
            pin = OwnedDLHandle(path, _pin_flags())
        except e:
            raise Error(
                "the library at " + path + " opened once and could not be"
                " pinned for the life of the process (" + String(e) + "); a"
                " result read after its connection closed would call into"
                " unloaded code"
            )
        var record = unsafe_alloc[_Pinned](count=1)
        record.unsafe_write(_Pinned(image, head))
        var published = False
        while not published:
            var expected = Int64(head)
            if word[].compare_exchange(expected, Int64(Int(record))):
                published = True
            else:
                # Another thread pinned something first: this image, and
                # the record is not needed, or another, and it goes behind.
                head = Int(expected)
                if _pinned_from(head, image):
                    break
                record[].next = head
        if published:
            # Never freed and never closed: the handle is the image's place
            # in the loader's list (O24).
            var kept = unsafe_alloc[OwnedDLHandle](count=1)
            kept.unsafe_write(pin^)
        else:
            record.unsafe_free()
    if not is_pinned(image):
        # Two causes, told apart by asking the word this function wrote
        # through: there and not through the readers' accessor is two
        # words; in neither is a pin that never recorded its image.
        if _pinned_from(Int(word[].load()), image):
            raise Error(
                "the libpq at " + path + " was pinned, and the pinned"
                " libraries' global word did not read back through the"
                " accessor its readers use: this toolchain gives"
                " pop.global_alloc more than one word, so nothing could tell"
                " which libraries are pinned; it is not opened"
            )
        raise Error(
            "the libpq at " + path + " is not among the pinned libraries"
            " after its pin: a table copied from it would call into code"
            " that can be unloaded; it is not opened"
        )


def _checked[
    name: StaticString, T: TrivialRegisterPassable
](ref handle: OwnedDLHandle, path: String) raises -> T:
    """Resolve one entry point, or raise naming the symbol that is missing.

    `ExternalFunction.load` ABORTS the process on a missing symbol -- it is
    statically non-raising, so a `try` around it is dead code the compiler
    says so about -- and a libpq too old, or a library that is not libpq at
    all, must be an error naming the symbol rather than a stack trace with
    no cause in it. `check_symbol` is the question that can be answered.

    Checking and loading in ONE place is the point. They used to be two: a
    `required_symbols()` list walked before any load, parallel to the
    declarations and to `PgLib`'s fields. Nothing held them in step -- the
    test that named that list asserted it was plausible, never that it
    matched what is loaded -- so a 33rd entry point added without its list
    entry passed every gate here and aborted on the first host whose libpq
    lacked it, which is the one failure the list existed to prevent.
    `test_a_symbol_the_library_lacks_is_an_error_naming_it` is what proves
    the refusal now, and reverting the check below makes it abort rather
    than fail.

    The cost of the merge is that a library missing a symbol is refused
    after the entry points before it have been loaded, where the list
    refused before any of them. Nothing escapes either way: the constructor
    raises, the pointers are register-passable with no destructors, and
    `path` and `_lib` are assigned last, so there is no table to half-own.

    Parameters:
        name: The symbol, taken from the declaration as `_PQx.name`.
        T: Its C signature, taken from the same declaration as `_PQx.type`.

    Args:
        handle: The open library. Borrowed; `load` takes no borrow of it,
            which is why `PgLib` holds it (the module docstring's first
            rule).
        path: Which file was opened, for the error.

    Returns:
        The entry point, as a `thin abi("C")` pointer to store in a field.

    Raises:
        If the library has no such symbol.
    """
    if not handle.check_symbol(name):
        raise Error(
            "the library at " + path + " has no symbol `" + String(name)
            + "` — this is either not libpq, or a libpq older than"
            + " 12.0, the oldest this package supports"
        )
    return ExternalFunction[name, T].load(handle.borrow())


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
    """An open libpq: the handle, which file it is, and every entry point.

    One struct on purpose: see the module docstring's first rule. The handle
    must outlive every call made through the pointers loaded from it, and
    the only way to say that in Mojo 1.0 — where a loaded pointer carries no
    borrow — is to give them the same lifetime: the table (`fns`) lives and
    moves with the handle. A `Connection` holds one and calls through
    `fns`; a `Result` holds a copy of `fns`, which the pin makes sound.

    Built once per thread and kept for that thread's life. Opening costs a
    `dlopen` and ~35 `dlsym`s; a call through a stored pointer costs a
    measured ≤1 ns, against ~100 ns for resolving the symbol per call, which
    is what `OwnedDLHandle.get_function` does.
    """

    var _lib: OwnedDLHandle
    """First field, and the reason this struct exists."""

    var path: String
    """Which file was opened — reported by `--doctor`, never guessed at."""

    var fns: PgFns
    """Every entry point, loaded from `_lib` and called through `PgFns`'s
    wrappers (the second rule)."""

    def __init__(out self, var handle: OwnedDLHandle, var path: String) raises:
        """Resolve every entry point from an already-open handle.

        Private in effect: `open` is the constructor callers use. The table
        checks every symbol before loading it (`PgFns.__init__`), and a
        library missing one is refused before anything of it is pinned: no
        table of it is kept, so its handle closing on the raise may unload
        it. The pin needs the table, since an image is told by an entry
        point's address, and comes before any field is assigned, so no
        `PgLib` exists whose library can be unmapped under it (the third
        rule).
        """
        var fns = PgFns(handle, path)
        pin_library(path, fns.image())
        self.fns = fns
        self.path = path^
        # Last, so the handle's own last mention is after every load above.
        self._lib = handle^

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
                handle = OwnedDLHandle(candidate, _open_flags())
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
            if lib.fns.isthreadsafe() == 0:
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

    def libversion(self) -> Int:
        """`PQlibVersion`, asked of the library itself, for a caller that
        holds no connection — `m0serve`'s `--pg-listen` checks among them."""
        return self.fns.libversion()

    def version_text(self) -> String:
        """`libpq`'s version as `major.minor`, from its integer form."""
        var v = self.libversion()
        return String(v // 10000) + "." + String(v % 10000)


struct PgFns(ImplicitlyCopyable, Movable):
    """Every libpq entry point this package calls, and the wrapper for each.

    The one place an entry point is added: its declaration above, then a
    field, a load and a wrapper here. `PgLib` holds this table beside the
    handle it was loaded from (the first rule), and a `Result` holds a COPY
    of it, whole. A `Result` used to reach its entry points through the
    address of its connection's `PgLib`, which dangles the moment that
    connection is moved or destroyed — and Mojo destroys a connection at its
    last use, so `var rows = db.query(...)` left `rows` reading a dead
    struct. A copy of the pointers needs nothing of the connection; the pin
    (the module docstring's third rule) is what keeps the code they point
    at mapped.

    Implicitly copyable, unlike `PgLib`, because it owns nothing: no handle,
    no buffer, only addresses into a library that is never unloaded. Its
    copy and its move are the compiler's; a struct of `thin` pointers needs
    none written.
    """

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

    def __init__(out self, ref handle: OwnedDLHandle, path: String) raises:
        """Resolve every entry point from `handle`, checking each first.

        Built by `PgLib.__init__`, first of all and while it still holds
        the handle: the pin reads this table. Every entry point goes through
        `_checked`, which asks `check_symbol` before loading, because `load`
        aborts the process on a missing one — a libpq too old, or a library
        that is not libpq at all, must be an error naming the symbol rather
        than a stack trace with no cause in it. One call per field, taking
        the symbol from the declaration it loads, so an entry point cannot
        be loaded without being checked.
        """
        self._libversion = _checked[
            _PQlibVersion.name, _PQlibVersion.type
        ](handle, path)
        self._isthreadsafe = _checked[
            _PQisthreadsafe.name, _PQisthreadsafe.type
        ](handle, path)
        self._connectdb = _checked[
            _PQconnectdb.name, _PQconnectdb.type
        ](handle, path)
        self._finish = _checked[_PQfinish.name, _PQfinish.type](handle, path)
        self._reset = _checked[_PQreset.name, _PQreset.type](handle, path)
        self._status = _checked[_PQstatus.name, _PQstatus.type](handle, path)
        self._transaction_status = _checked[
            _PQtransactionStatus.name, _PQtransactionStatus.type
        ](handle, path)
        self._errmsg = _checked[
            _PQerrorMessage.name, _PQerrorMessage.type
        ](handle, path)
        self._server_version = _checked[
            _PQserverVersion.name, _PQserverVersion.type
        ](handle, path)
        self._backend_pid = _checked[
            _PQbackendPID.name, _PQbackendPID.type
        ](handle, path)
        self._socket = _checked[_PQsocket.name, _PQsocket.type](handle, path)
        self._exec = _checked[_PQexec.name, _PQexec.type](handle, path)
        self._exec_params = _checked[
            _PQexecParams.name, _PQexecParams.type
        ](handle, path)
        self._prepare = _checked[
            _PQprepare.name, _PQprepare.type
        ](handle, path)
        self._exec_prepared = _checked[
            _PQexecPrepared.name, _PQexecPrepared.type
        ](handle, path)
        self._result_status = _checked[
            _PQresultStatus.name, _PQresultStatus.type
        ](handle, path)
        self._result_errmsg = _checked[
            _PQresultErrorMessage.name, _PQresultErrorMessage.type
        ](handle, path)
        self._result_errfield = _checked[
            _PQresultErrorField.name, _PQresultErrorField.type
        ](handle, path)
        self._ntuples = _checked[
            _PQntuples.name, _PQntuples.type
        ](handle, path)
        self._nfields = _checked[
            _PQnfields.name, _PQnfields.type
        ](handle, path)
        self._fname = _checked[_PQfname.name, _PQfname.type](handle, path)
        self._ftype = _checked[_PQftype.name, _PQftype.type](handle, path)
        self._fformat = _checked[
            _PQfformat.name, _PQfformat.type
        ](handle, path)
        self._getvalue = _checked[
            _PQgetvalue.name, _PQgetvalue.type
        ](handle, path)
        self._getlength = _checked[
            _PQgetlength.name, _PQgetlength.type
        ](handle, path)
        self._getisnull = _checked[
            _PQgetisnull.name, _PQgetisnull.type
        ](handle, path)
        self._cmd_tuples = _checked[
            _PQcmdTuples.name, _PQcmdTuples.type
        ](handle, path)
        self._clear = _checked[_PQclear.name, _PQclear.type](handle, path)
        self._consume_input = _checked[
            _PQconsumeInput.name, _PQconsumeInput.type
        ](handle, path)
        self._notifies = _checked[
            _PQnotifies.name, _PQnotifies.type
        ](handle, path)
        self._freemem = _checked[
            _PQfreemem.name, _PQfreemem.type
        ](handle, path)
        self._escape_identifier = _checked[
            _PQescapeIdentifier.name, _PQescapeIdentifier.type
        ](handle, path)

    def image(self) -> Int:
        """Which libpq image this table was loaded from, as an address.

        `PQlibVersion`'s, read and not called. One image answers the same
        address to every table loaded from it, under whatever name it was
        opened, and a second image — another build, or a copy of the file —
        answers another: what `pin_library` pins once each (O24).
        """
        return Pointer(to=self._libversion).unsafe_bitcast[Int]()[]

    def libversion(self) -> Int:
        """`PQlibVersion`."""
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
        """`PQtransactionStatus`."""
        return Int(self._transaction_status(conn))

    def errmsg(self, conn: Int) -> Int:
        """`PQerrorMessage`."""
        return Int(self._errmsg(conn))

    def server_version(self, conn: Int) -> Int:
        """`PQserverVersion`."""
        return Int(self._server_version(conn))

    def backend_pid(self, conn: Int) -> Int:
        """`PQbackendPID`."""
        return Int(self._backend_pid(conn))

    def socket(self, conn: Int) -> Int:
        """`PQsocket`."""
        return Int(self._socket(conn))

    def exec(self, conn: Int, query: CStr) -> Int:
        """`PQexec`."""
        return Int(self._exec(conn, query))

    def exec_params(self, conn: Int, command: CStr, n: Int, types: Int, values: Int, lengths: Int, formats: Int, result_format: Int) -> Int:
        """`PQexecParams`."""
        return Int(self._exec_params(conn, command, c_int(n), types, values, lengths, formats, c_int(result_format)))

    def prepare(self, conn: Int, name: CStr, query: CStr, n: Int, types: Int) -> Int:
        """`PQprepare`."""
        return Int(self._prepare(conn, name, query, c_int(n), types))

    def exec_prepared(self, conn: Int, name: CStr, n: Int, values: Int, lengths: Int, formats: Int, result_format: Int) -> Int:
        """`PQexecPrepared`."""
        return Int(self._exec_prepared(conn, name, c_int(n), values, lengths, formats, c_int(result_format)))

    def result_status(self, res: Int) -> Int:
        """`PQresultStatus`."""
        return Int(self._result_status(res))

    def result_errmsg(self, res: Int) -> Int:
        """`PQresultErrorMessage`."""
        return Int(self._result_errmsg(res))

    def result_errfield(self, res: Int, field: Int) -> Int:
        """`PQresultErrorField`."""
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
        """`PQcmdTuples`."""
        return Int(self._cmd_tuples(res))

    def clear(self, res: Int):
        """`PQclear`."""
        self._clear(res)

    def consume_input(self, conn: Int) -> Int:
        """`PQconsumeInput`."""
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


def refuse_nul(text: Span[UInt8, _], what: String) raises:
    """Raise if `text` holds a NUL byte, naming `what` and where, never the text.

    libpq reads what it takes without a length as a C string, so a NUL ends
    it there and nothing reports the rest was dropped: `SELECT 1`, a NUL
    and `; DROP TABLE t` runs `SELECT 1`, and a TEXT-format parameter is
    read with `strlen` whatever length it is handed. `PQescapeIdentifier`
    takes a length and stops at a NUL all the same. The state is the one
    the server gives a NUL inside text, so an application reads one answer
    wherever the NUL was caught. The text is not quoted: a connection
    string carries a password.
    """
    for i in range(len(text)):
        if text[i] == 0:
            raise Error(
                what + " carries a NUL byte at byte " + String(i)
                + ", and libpq, reading it as a C string, would end it there:"
                + " refused rather than sent cut short (sqlstate="
                + CHARACTER_NOT_IN_REPERTOIRE + ")"
            )


def c_text(s: String, what: String) raises -> List[UInt8]:
    """`c_string`, for text that must arrive whole or not at all.

    Every string this package hands libpq without a length goes through
    here: SQL, a statement name, a name to quote, a connection string.
    """
    refuse_nul(s.as_bytes(), what)
    return c_string(s)


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
