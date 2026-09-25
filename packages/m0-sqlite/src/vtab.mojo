"""An eponymous virtual table over Mojo-owned arrays.

Registers `m0_array(?)` on a connection, a table-valued function with a single
`value` column that streams a Mojo `List` without copying it:

    db.register_array_module()

    var ids = List[Int](length=3, fill=0)
    ...
    var q = db.prepare("SELECT sum(v) FROM t WHERE id IN "
                       "(SELECT value FROM m0_array(?1))")
    var out = List[Int]()
    _ = q.fetch_ints_over(0, 1, ids, out)

Its reason to exist is bulk ingest — `INSERT INTO t SELECT value FROM
m0_array(?1)` runs one `sqlite3_step` where the per-row loop runs 3N bind/step/
reset calls, measured at ~2.9x on 10k and 200k rows. Using it for `IN` clauses
is a side benefit and a much smaller one; `json_each` is within ~20% there and
needs none of this.

**No C and no loadable extension.** libsqlite3 already exports everything
needed, and Mojo can supply C-callable function pointers, so the module is
built here and registered in-process on a live connection.

**The callbacks reach the library without a global.** SQLite calls them from
C with no way to hand them a Mojo table, and the library is opened at run
time (`lib.mojo`), so the seven entry points they need travel in the buffer
SQLite already owns: `VtabLib.store` writes them as words after the
`sqlite3_module` (`A_LIB`), the same buffer is the `pAux` every `xConnect`
receives, `xConnect` keeps that address in the vtab's extra word (`V_AUX`),
and a cursor reaches it through its vtab (`C_VTAB`). Copies, sound because
the library is pinned for the life of the process.

Three things about the implementation are deliberate:

  - **The C structs are flat word buffers, not Mojo structs.** Same reasoning as
    `lightbug_http/c/epoll.mojo`: Mojo cannot vary a struct's fields by target,
    and a struct whose size is wrong by four bytes corrupts everything after the
    first row in silence. Every offset used here is asserted against the real
    headers by `test/verify_layout.c`, which `poe test-sqlite` runs — for the
    host triple — before any Mojo test, and which reads the numbers from THIS
    file: `scripts/vtab_layout.py` extracts every `comptime NAME: Int` here
    and compiles the C file with each as `-DM0_NAME`, so the assertion is
    header-against-Mojo rather than header-against-a-copy. (Until 2026-09 the
    C file carried its own literals and a wrong slot index here was invisible
    to it.) `poe sabotage-vtab` moves each constant in turn and insists the
    guard fails. Four 64-bit triples were swept by hand
    during the spike, with i386 as a negative control; see
    `docs/sqlite-vtab-feasibility.md`. Sweep a new target the same way before
    trusting it, because the gate only ever sees the machine it runs on.

  - **`iVersion` is 1 on purpose.** It bounds what SQLite reads from the module
    to slots 0 through 19 — through `xRename`, so twenty words — and the buffer
    is 25, which is what keeps it in range even against a future SQLite that
    appends fields. (`verify_layout.c` asserts the 25 covers today's header;
    the iVersion is what covers tomorrow's.)

  - **The pointer type tag is a `comptime` literal.** `sqlite3_bind_pointer`
    retains the tag pointer, so it must have static storage — a transient
    `c_string()` buffer would dangle.

Borrow safety is not this file's job; see `Statement.execute_over` and
`Statement.fetch_ints_over`, which are the only supported way to bind an
array and are shaped so the borrow cannot outlive the data.
"""

from std.ffi import c_int
from std.memory import Pointer

from .ffi import SQLITE_OK, SQLITE_NOMEM, SQLITE_CONSTRAINT, c_string
from .lib import FreeFn, SqliteLib, StmtLib, VtabLib, as_cstr

# --- Constraint operators (xBestIndex input, not a result code) -------------
comptime SQLITE_INDEX_CONSTRAINT_EQ: Int = 2

# The floor is 3.26.0, not 3.20.0. `sqlite3_bind_pointer` arrived in 3.20.0,
# but xBestIndex returning SQLITE_CONSTRAINT to mean "reject this plan" — which
# _x_best_index relies on to refuse a scan without its array — is only honoured
# from 3.26.0. On the versions between, that refusal fails the whole query, and
# not just for misuse: the planner may probe a plan in which the spec
# constraint is unusable, so legitimate joins would error too.
comptime SQLITE_MIN_VTAB_VERSION: Int = 3_026_000

# Static storage: sqlite3_bind_pointer retains this pointer, so it cannot be a
# transient buffer. A comptime literal is NUL-terminated with a stable address.
comptime ARRAY_TAG = "m0-sqlite-array"
comptime ARRAY_DECL = "CREATE TABLE x(value, spec HIDDEN)"
comptime ARRAY_NAME = "m0_array"

# --- Element kinds carried in the spec header -------------------------------
comptime KIND_INT: Int = 0
comptime KIND_FLOAT: Int = 1

comptime WordPtr = Pointer[Int, MutAnyOrigin]
comptime I32Ptr = Pointer[Int32, MutAnyOrigin]
comptime U8Ptr = Pointer[UInt8, MutAnyOrigin]
comptime F64Ptr = Pointer[Float64, MutAnyOrigin]

# --- sqlite3_module: int iVersion, then 24 callbacks ------------------------
comptime M_VERSION: Int = 0
comptime M_CONNECT: Int = 2
comptime M_BESTINDEX: Int = 3
comptime M_DISCONNECT: Int = 4
comptime M_OPEN: Int = 6
comptime M_CLOSE: Int = 7
comptime M_FILTER: Int = 8
comptime M_NEXT: Int = 9
comptime M_EOF: Int = 10
comptime M_COLUMN: Int = 11
comptime M_ROWID: Int = 12
comptime M_SLOTS: Int = 25

# --- The module buffer's tail: ours, past what SQLite reads -----------------
# `iVersion` bounds SQLite to the first M_SLOTS words; the seven library
# entry points the callbacks call sit after them (`VtabLib.store`), and
# the buffer is A_WORDS long. Mojo's own layout, not SQLite's.
comptime A_LIB: Int = 25
comptime A_WORDS: Int = 32

# --- sqlite3_vtab: {pModule, nRef, zErrMsg}; xConnect allocates this many --
# Word 3 is ours: the pAux address, which is where the entry points are.
comptime V_WORDS: Int = 4
comptime V_AUX: Int = 3

# --- The spec header, allocated per bind and freed by SQLite ----------------
# Passing {data, count, kind} through one pointer keeps the SQL down to a
# single `?`, and letting sqlite3_free be the bind destructor means the header
# has exactly SQLite's lifetime rather than one we have to police.
comptime S_DATA: Int = 0
comptime S_COUNT: Int = 1
comptime S_KIND: Int = 2
comptime S_WORDS: Int = 3

# --- Cursor: sqlite3_vtab_cursor is one word, ours follow -------------------
comptime C_VTAB: Int = 0
comptime C_DATA: Int = 1
comptime C_COUNT: Int = 2
comptime C_KIND: Int = 3
comptime C_INDEX: Int = 4
comptime C_WORDS: Int = 5

# --- sqlite3_index_info, word-indexed (see verify_layout.c) -----------------
comptime II_NCONSTRAINT: Int = 0
comptime II_ACONSTRAINT: Int = 1
comptime II_AUSAGE: Int = 4
comptime II_IDXNUM: Int = 5
comptime II_COST: Int = 8
# The two inner arrays, in BYTES: their fields are int and unsigned char, so
# these are byte offsets into a 12- and an 8-byte element, not word indices.
comptime CONSTRAINT_STRIDE: Int = 12
comptime CONSTRAINT_ICOLUMN: Int = 0
comptime CONSTRAINT_OP: Int = 4
comptime CONSTRAINT_USABLE: Int = 5
comptime USAGE_STRIDE: Int = 8
comptime USAGE_ARGVINDEX: Int = 0
comptime USAGE_OMIT: Int = 4

comptime XConnectFn = def (
    Int, Int, c_int, Int, Int, Int
) thin abi("C") -> c_int
comptime XBestIndexFn = def (Int, Int) thin abi("C") -> c_int
comptime XVtabFn = def (Int) thin abi("C") -> c_int
comptime XOpenFn = def (Int, Int) thin abi("C") -> c_int
comptime XFilterFn = def (Int, c_int, Int, c_int, Int) thin abi("C") -> c_int
comptime XColumnFn = def (Int, Int, c_int) thin abi("C") -> c_int
comptime XRowidFn = def (Int, Int) thin abi("C") -> c_int


@always_inline
def _words(addr: Int) -> WordPtr:
    return WordPtr(unsafe_from_address=addr)


# --- Module callbacks --------------------------------------------------------


def _lib_of_aux(p_aux: Int) -> VtabLib:
    """The entry points `_build_module` stored after the module."""
    return VtabLib.load(p_aux + A_LIB * 8)


def _lib_of_vtab(p_vtab: Int) -> VtabLib:
    """The same, through the pAux address `_x_connect` kept in the vtab."""
    return _lib_of_aux(_words(p_vtab)[unsafe_offset=V_AUX])


def _lib_of_cursor(p_cursor: Int) -> VtabLib:
    """The same, through the cursor's vtab."""
    return _lib_of_vtab(_words(p_cursor)[unsafe_offset=C_VTAB])


def _x_connect(
    db: Int, p_aux: Int, argc: c_int, argv: Int, pp_vtab: Int, pz_err: Int
) abi("C") -> c_int:
    var lib = _lib_of_aux(p_aux)
    var decl = c_string(ARRAY_DECL)
    var rc = lib.declare_vtab(db, as_cstr(decl))
    _ = decl
    if rc != SQLITE_OK:
        return c_int(rc)
    # sqlite3_vtab is {pModule, nRef, zErrMsg}; V_WORDS zeroed words cover it,
    # and the fourth is ours: where the entry points are.
    var p = lib.malloc64(V_WORDS * 8)
    if p == 0:
        return c_int(SQLITE_NOMEM)
    var w = _words(p)
    for i in range(V_WORDS):
        w[unsafe_offset=i] = 0
    w[unsafe_offset=V_AUX] = p_aux
    _words(pp_vtab)[unsafe_offset=0] = p
    return c_int(SQLITE_OK)


def _x_disconnect(p_vtab: Int) abi("C") -> c_int:
    _lib_of_vtab(p_vtab).free(p_vtab)
    return c_int(SQLITE_OK)


def _x_best_index(p_vtab: Int, p_info: Int) abi("C") -> c_int:
    """Claim the hidden `spec` column as xFilter's argument."""
    var info = _words(p_info)
    var n = Int(
        I32Ptr(unsafe_from_address=p_info + II_NCONSTRAINT * 8)[unsafe_offset=0]
    )
    var a_constraint = info[unsafe_offset=II_ACONSTRAINT]
    var a_usage = info[unsafe_offset=II_AUSAGE]

    var spec_slot = -1
    for i in range(n):
        var base = a_constraint + i * CONSTRAINT_STRIDE
        var i_column = Int(
            I32Ptr(unsafe_from_address=base + CONSTRAINT_ICOLUMN)[unsafe_offset=0]
        )
        var op = Int(
            U8Ptr(unsafe_from_address=base + CONSTRAINT_OP)[unsafe_offset=0]
        )
        var usable = Int(
            U8Ptr(unsafe_from_address=base + CONSTRAINT_USABLE)[unsafe_offset=0]
        )
        if usable != 0 and op == SQLITE_INDEX_CONSTRAINT_EQ and i_column == 1:
            spec_slot = i
            break  # one hidden column, so the first usable match is the one

    var cost = F64Ptr(unsafe_from_address=p_info + II_COST * 8)
    var idx_num = I32Ptr(unsafe_from_address=p_info + II_IDXNUM * 8)

    if spec_slot < 0:
        # Without the spec there is nothing to scan; refuse the plan outright
        # rather than quietly returning an empty table. SQLITE_CONSTRAINT is
        # honoured as "reject this plan" from 3.26.0 — see
        # SQLITE_MIN_VTAB_VERSION.
        idx_num[unsafe_offset=0] = Int32(0)
        cost[unsafe_offset=0] = 1.0e99
        return c_int(SQLITE_CONSTRAINT)

    var u = a_usage + spec_slot * USAGE_STRIDE
    I32Ptr(unsafe_from_address=u + USAGE_ARGVINDEX)[unsafe_offset=0] = Int32(1)
    U8Ptr(unsafe_from_address=u + USAGE_OMIT)[unsafe_offset=0] = UInt8(1)
    idx_num[unsafe_offset=0] = Int32(1)
    # A flat estimate, and deliberately so: the array length lives behind the
    # bound pointer, which xBestIndex cannot read — planning happens before
    # any value is available. `estimatedRows` is left at the 25 SQLite fills
    # in. So the planner sizes a 50k-element array the same as a 3-element
    # one, which is wrong in the join case and irrelevant in the case that
    # justifies this module: `INSERT INTO t SELECT ... FROM m0_array(?1)`
    # joins nothing. Reading the length at plan time needs
    # sqlite3_vtab_rhs_value (3.38+), above this module's 3.26 floor.
    cost[unsafe_offset=0] = 1.0
    return c_int(SQLITE_OK)


def _x_open(p_vtab: Int, pp_cursor: Int) abi("C") -> c_int:
    var p = _lib_of_vtab(p_vtab).malloc64(C_WORDS * 8)
    if p == 0:
        return c_int(SQLITE_NOMEM)
    var w = _words(p)
    for i in range(C_WORDS):
        w[unsafe_offset=i] = 0
    w[unsafe_offset=C_VTAB] = p_vtab
    _words(pp_cursor)[unsafe_offset=0] = p
    return c_int(SQLITE_OK)


def _x_close(p_cursor: Int) abi("C") -> c_int:
    _lib_of_cursor(p_cursor).free(p_cursor)
    return c_int(SQLITE_OK)


def _x_filter(
    p_cursor: Int, idx_num: c_int, idx_str: Int, argc: c_int, argv: Int
) abi("C") -> c_int:
    var cur = _words(p_cursor)
    cur[unsafe_offset=C_INDEX] = 0
    cur[unsafe_offset=C_DATA] = 0
    cur[unsafe_offset=C_COUNT] = 0
    cur[unsafe_offset=C_KIND] = KIND_INT

    if Int(idx_num) != 1 or Int(argc) < 1:
        return c_int(SQLITE_OK)

    # NULL unless this value was set by bind_pointer with a matching tag, so a
    # stray integer parameter cannot be reinterpreted as an address.
    var tag = c_string(ARRAY_TAG)
    var spec = _lib_of_cursor(p_cursor).value_pointer(
        _words(argv)[unsafe_offset=0], as_cstr(tag)
    )
    _ = tag
    if spec == 0:
        return c_int(SQLITE_OK)

    var s = _words(spec)
    var count = s[unsafe_offset=S_COUNT]
    if count <= 0:
        return c_int(SQLITE_OK)
    cur[unsafe_offset=C_DATA] = s[unsafe_offset=S_DATA]
    cur[unsafe_offset=C_COUNT] = count
    cur[unsafe_offset=C_KIND] = s[unsafe_offset=S_KIND]
    return c_int(SQLITE_OK)


def _x_next(p_cursor: Int) abi("C") -> c_int:
    var cur = _words(p_cursor)
    cur[unsafe_offset=C_INDEX] = cur[unsafe_offset=C_INDEX] + 1
    return c_int(SQLITE_OK)


def _x_eof(p_cursor: Int) abi("C") -> c_int:
    var cur = _words(p_cursor)
    var done = cur[unsafe_offset=C_INDEX] >= cur[unsafe_offset=C_COUNT]
    return c_int(1) if done else c_int(0)


def _x_column(p_cursor: Int, ctx: Int, col: c_int) abi("C") -> c_int:
    var cur = _words(p_cursor)
    var lib = _lib_of_cursor(p_cursor)
    if Int(col) != 0:
        lib.result_null(ctx)
        return c_int(SQLITE_OK)

    var i = cur[unsafe_offset=C_INDEX]
    var base = cur[unsafe_offset=C_DATA]
    if cur[unsafe_offset=C_KIND] == KIND_FLOAT:
        var f = F64Ptr(unsafe_from_address=base)[unsafe_offset=i]
        lib.result_double(ctx, f)
    else:
        var v = _words(base)[unsafe_offset=i]
        lib.result_int64(ctx, v)
    return c_int(SQLITE_OK)


def _x_rowid(p_cursor: Int, p_rowid: Int) abi("C") -> c_int:
    _words(p_rowid)[unsafe_offset=0] = _words(p_cursor)[unsafe_offset=C_INDEX]
    return c_int(SQLITE_OK)


# --- Registration ------------------------------------------------------------


def _build_module(lib: SqliteLib) raises -> Int:
    """Allocate and fill the sqlite3_module, and the entry points after it.
    Returns its address.

    SQLite-allocated rather than a Mojo `List` so its lifetime can be handed to
    SQLite: the same address is passed as `pAux` with `sqlite3_free` as the
    destructor, so it is released when the module is dropped at connection
    close. A Mojo-owned buffer would have to outlive the `Connection`, which is
    exactly the kind of bookkeeping this package should not be asking for.
    The seven entry points the callbacks call ride in the same buffer, past
    the words SQLite reads (`A_LIB`), which is how a callback invoked from C
    finds the library without a global.
    """
    var m = lib.malloc64(A_WORDS * 8)
    if m == 0:
        raise Error("sqlite3_malloc64 failed for the vtab module")
    var w = _words(m)
    for i in range(A_WORDS):
        w[unsafe_offset=i] = 0
    lib.vtab_lib().store(m + A_LIB * 8)

    # iVersion=1: bounds SQLite's reads to the first 19 slots.
    w[unsafe_offset=M_VERSION] = 1
    # xCreate stays NULL, which is what makes the table eponymous-only.

    Pointer[XConnectFn, MutAnyOrigin](
        unsafe_from_address=m + M_CONNECT * 8
    )[unsafe_offset=0] = _x_connect
    Pointer[XBestIndexFn, MutAnyOrigin](
        unsafe_from_address=m + M_BESTINDEX * 8
    )[unsafe_offset=0] = _x_best_index
    Pointer[XVtabFn, MutAnyOrigin](
        unsafe_from_address=m + M_DISCONNECT * 8
    )[unsafe_offset=0] = _x_disconnect
    Pointer[XOpenFn, MutAnyOrigin](unsafe_from_address=m + M_OPEN * 8)[
        unsafe_offset=0
    ] = _x_open
    Pointer[XVtabFn, MutAnyOrigin](unsafe_from_address=m + M_CLOSE * 8)[
        unsafe_offset=0
    ] = _x_close
    Pointer[XFilterFn, MutAnyOrigin](
        unsafe_from_address=m + M_FILTER * 8
    )[unsafe_offset=0] = _x_filter
    Pointer[XVtabFn, MutAnyOrigin](unsafe_from_address=m + M_NEXT * 8)[
        unsafe_offset=0
    ] = _x_next
    Pointer[XVtabFn, MutAnyOrigin](unsafe_from_address=m + M_EOF * 8)[
        unsafe_offset=0
    ] = _x_eof
    Pointer[XColumnFn, MutAnyOrigin](
        unsafe_from_address=m + M_COLUMN * 8
    )[unsafe_offset=0] = _x_column
    Pointer[XRowidFn, MutAnyOrigin](unsafe_from_address=m + M_ROWID * 8)[
        unsafe_offset=0
    ] = _x_rowid

    return m


def _register(lib: SqliteLib, db_handle: Int) raises:
    """Register `m0_array` on a connection. See `Connection.register_array_module`."""
    var m = _build_module(lib)
    var name = c_string(ARRAY_NAME)
    # pAux is the module buffer itself, with sqlite3_free itself — the
    # library's own pointer, not a Mojo shim — as the destructor, so SQLite
    # owns the allocation from here and releases it when the module is
    # dropped.
    var rc = lib.create_module_v2(db_handle, as_cstr(name), m, m, lib.free_fn())
    _ = name
    if rc != SQLITE_OK:
        # No free here: create_module_v2 invokes the destructor on failure too
        # (documented in sqlite3.h), and pAux is the module buffer itself, so
        # SQLite has already released `m`. Freeing it again would double-free.
        raise Error("sqlite3_create_module_v2 failed (rc=" + String(rc) + ")")


# --- Spec headers, used by the Statement borrow helpers ----------------------


def _bind_spec(
    lib: StmtLib, stmt_handle: Int, param: Int, data: Int, count: Int, kind: Int
) raises:
    """Bind a {data, count, kind} header to `param` as a tagged pointer.

    The header is SQLite-allocated and freed by the bind destructor, so it needs
    no Mojo-side lifetime. The array it points at is the dangerous part — that
    is what the `*_over` helpers exist to keep alive.
    """
    var p = lib.malloc64(S_WORDS * 8)
    if p == 0:
        raise Error("sqlite3_malloc64 failed for an array spec")
    var w = _words(p)
    w[unsafe_offset=S_DATA] = data
    w[unsafe_offset=S_COUNT] = count
    w[unsafe_offset=S_KIND] = kind

    var tag = c_string(ARRAY_TAG)
    var rc = lib.bind_pointer(stmt_handle, param, p, as_cstr(tag), lib.free_fn())
    _ = tag
    if rc != SQLITE_OK:
        # No free here: bind_pointer runs the destructor even when the bind
        # fails — measured on 3.51.0 for both SQLITE_RANGE and SQLITE_MISUSE,
        # and sqlite3.h documents the same for the blob/text binders. SQLite
        # has already released the spec; freeing it again would double-free.
        raise Error("sqlite3_bind_pointer failed (rc=" + String(rc) + ")")
