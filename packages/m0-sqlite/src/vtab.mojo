"""An eponymous virtual table over Mojo-owned arrays.

Registers `m0_array(?)` on a connection, a table-valued function with a single
`value` column that streams a Mojo `List` without copying it:

    db.register_array_module()

    var ids = List[Int](length=3, fill=0)
    ...
    var q = db.prepare("SELECT sum(v) FROM t WHERE id IN "
                       "(SELECT value FROM m0_array(?1))")
    var out = List[Int]()
    _ = q.select_ints_over(0, 1, ids, out)

Its reason to exist is bulk ingest — `INSERT INTO t SELECT value FROM
m0_array(?1)` runs one `sqlite3_step` where the per-row loop runs 3N bind/step/
reset calls, measured at ~2.9x on 10k and 200k rows. Using it for `IN` clauses
is a side benefit and a much smaller one; `json_each` is within ~20% there and
needs none of this.

**No C and no loadable extension.** libsqlite3 already exports everything
needed, and Mojo can supply C-callable function pointers, so the module is
built here and registered in-process on a live connection.

Three things about the implementation are deliberate:

  - **The C structs are flat word buffers, not Mojo structs.** Same reasoning as
    `lightbug_http/c/epoll.mojo`: Mojo cannot vary a struct's fields by target,
    and a struct whose size is wrong by four bytes corrupts everything after the
    first row in silence. Every offset used here is asserted against the real
    headers, for four target triples, by `experiments/sqlite-vtab/verify_layout.c`.

  - **`iVersion` is 1 on purpose.** It bounds what SQLite reads from the module
    to the first 19 slots, so the 25-word buffer stays in range even against a
    future SQLite that appends fields.

  - **The pointer type tag is a `comptime` literal.** `sqlite3_bind_pointer`
    retains the tag pointer, so it must have static storage — a transient
    `c_string()` buffer would dangle.

Borrow safety is not this file's job; see `Statement.execute_over` and
`Statement.select_ints_over`, which are the only supported way to bind an
array and are shaped so the borrow cannot outlive the data.
"""

from std.ffi import external_call, c_int
from std.memory import UnsafePointer

from .ffi import SQLITE_OK, c_string

# --- Result codes used by the callbacks -------------------------------------
comptime SQLITE_NOMEM: Int = 7
comptime SQLITE_CONSTRAINT: Int = 19
comptime SQLITE_INDEX_CONSTRAINT_EQ: Int = 2

# Static storage: sqlite3_bind_pointer retains this pointer, so it cannot be a
# transient buffer. A comptime literal is NUL-terminated with a stable address.
comptime ARRAY_TAG = "m0-sqlite-array"
comptime ARRAY_DECL = "CREATE TABLE x(value, spec HIDDEN)"
comptime ARRAY_NAME = "m0_array"

# --- Element kinds carried in the spec header -------------------------------
comptime KIND_INT: Int = 0
comptime KIND_FLOAT: Int = 1

comptime WordPtr = UnsafePointer[Int, MutAnyOrigin]
comptime I32Ptr = UnsafePointer[Int32, MutAnyOrigin]
comptime U8Ptr = UnsafePointer[UInt8, MutAnyOrigin]
comptime F64Ptr = UnsafePointer[Float64, MutAnyOrigin]

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
comptime II_ACONSTRAINT: Int = 1
comptime II_AUSAGE: Int = 4
comptime II_IDXNUM: Int = 5
comptime II_COST: Int = 8
comptime CONSTRAINT_STRIDE: Int = 12
comptime USAGE_STRIDE: Int = 8

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


def _x_connect(
    db: Int, p_aux: Int, argc: c_int, argv: Int, pp_vtab: Int, pz_err: Int
) abi("C") -> c_int:
    var rc = Int(
        external_call["sqlite3_declare_vtab", c_int](db, ARRAY_DECL.unsafe_ptr())
    )
    if rc != SQLITE_OK:
        return c_int(rc)
    # sqlite3_vtab is {pModule, nRef, zErrMsg}; 4 zeroed words covers it.
    var p = Int(external_call["sqlite3_malloc64", Int](Int64(32)))
    if p == 0:
        return c_int(SQLITE_NOMEM)
    var w = _words(p)
    for i in range(4):
        w[unsafe_offset=i] = 0
    _words(pp_vtab)[unsafe_offset=0] = p
    return c_int(SQLITE_OK)


def _x_disconnect(p_vtab: Int) abi("C") -> c_int:
    external_call["sqlite3_free", NoneType](p_vtab)
    return c_int(SQLITE_OK)


def _x_best_index(p_vtab: Int, p_info: Int) abi("C") -> c_int:
    """Claim the hidden `spec` column as xFilter's argument."""
    var info = _words(p_info)
    var n = Int(I32Ptr(unsafe_from_address=p_info)[unsafe_offset=0])
    var a_constraint = info[unsafe_offset=II_ACONSTRAINT]
    var a_usage = info[unsafe_offset=II_AUSAGE]

    var spec_slot = -1
    for i in range(n):
        var base = a_constraint + i * CONSTRAINT_STRIDE
        var i_column = Int(I32Ptr(unsafe_from_address=base)[unsafe_offset=0])
        var op = Int(U8Ptr(unsafe_from_address=base + 4)[unsafe_offset=0])
        var usable = Int(U8Ptr(unsafe_from_address=base + 5)[unsafe_offset=0])
        if usable != 0 and op == SQLITE_INDEX_CONSTRAINT_EQ and i_column == 1:
            spec_slot = i

    var cost = F64Ptr(unsafe_from_address=p_info + II_COST * 8)
    var idx_num = I32Ptr(unsafe_from_address=p_info + II_IDXNUM * 8)

    if spec_slot < 0:
        # Without the spec there is nothing to scan; refuse the plan outright
        # rather than quietly returning an empty table.
        idx_num[unsafe_offset=0] = Int32(0)
        cost[unsafe_offset=0] = 1.0e99
        return c_int(SQLITE_CONSTRAINT)

    var u = a_usage + spec_slot * USAGE_STRIDE
    I32Ptr(unsafe_from_address=u)[unsafe_offset=0] = Int32(1)
    U8Ptr(unsafe_from_address=u + 4)[unsafe_offset=0] = UInt8(1)
    idx_num[unsafe_offset=0] = Int32(1)
    cost[unsafe_offset=0] = 1.0
    return c_int(SQLITE_OK)


def _x_open(p_vtab: Int, pp_cursor: Int) abi("C") -> c_int:
    var p = Int(external_call["sqlite3_malloc64", Int](Int64(C_WORDS * 8)))
    if p == 0:
        return c_int(SQLITE_NOMEM)
    var w = _words(p)
    for i in range(C_WORDS):
        w[unsafe_offset=i] = 0
    w[unsafe_offset=C_VTAB] = p_vtab
    _words(pp_cursor)[unsafe_offset=0] = p
    return c_int(SQLITE_OK)


def _x_close(p_cursor: Int) abi("C") -> c_int:
    external_call["sqlite3_free", NoneType](p_cursor)
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
    var spec = Int(
        external_call["sqlite3_value_pointer", Int](
            _words(argv)[unsafe_offset=0], ARRAY_TAG.unsafe_ptr()
        )
    )
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
    if Int(col) != 0:
        external_call["sqlite3_result_null", NoneType](ctx)
        return c_int(SQLITE_OK)

    var i = cur[unsafe_offset=C_INDEX]
    var base = cur[unsafe_offset=C_DATA]
    if cur[unsafe_offset=C_KIND] == KIND_FLOAT:
        var f = F64Ptr(unsafe_from_address=base)[unsafe_offset=i]
        external_call["sqlite3_result_double", NoneType](ctx, f)
    else:
        var v = _words(base)[unsafe_offset=i]
        external_call["sqlite3_result_int64", NoneType](ctx, Int64(v))
    return c_int(SQLITE_OK)


def _x_rowid(p_cursor: Int, p_rowid: Int) abi("C") -> c_int:
    _words(p_rowid)[unsafe_offset=0] = _words(p_cursor)[unsafe_offset=C_INDEX]
    return c_int(SQLITE_OK)


# --- Registration ------------------------------------------------------------


def _build_module() raises -> Int:
    """Allocate and fill the sqlite3_module. Returns its address.

    SQLite-allocated rather than a Mojo `List` so its lifetime can be handed to
    SQLite: the same address is passed as `pAux` with `sqlite3_free` as the
    destructor, so it is released when the module is dropped at connection
    close. A Mojo-owned buffer would have to outlive the `Connection`, which is
    exactly the kind of bookkeeping this package should not be asking for.
    """
    var m = Int(external_call["sqlite3_malloc64", Int](Int64(M_SLOTS * 8)))
    if m == 0:
        raise Error("sqlite3_malloc64 failed for the vtab module")
    var w = _words(m)
    for i in range(M_SLOTS):
        w[unsafe_offset=i] = 0

    # iVersion=1: bounds SQLite's reads to the first 19 slots.
    w[unsafe_offset=M_VERSION] = 1
    # xCreate stays NULL, which is what makes the table eponymous-only.

    UnsafePointer[XConnectFn, MutAnyOrigin](
        unsafe_from_address=m + M_CONNECT * 8
    )[unsafe_offset=0] = _x_connect
    UnsafePointer[XBestIndexFn, MutAnyOrigin](
        unsafe_from_address=m + M_BESTINDEX * 8
    )[unsafe_offset=0] = _x_best_index
    UnsafePointer[XVtabFn, MutAnyOrigin](
        unsafe_from_address=m + M_DISCONNECT * 8
    )[unsafe_offset=0] = _x_disconnect
    UnsafePointer[XOpenFn, MutAnyOrigin](unsafe_from_address=m + M_OPEN * 8)[
        unsafe_offset=0
    ] = _x_open
    UnsafePointer[XVtabFn, MutAnyOrigin](unsafe_from_address=m + M_CLOSE * 8)[
        unsafe_offset=0
    ] = _x_close
    UnsafePointer[XFilterFn, MutAnyOrigin](
        unsafe_from_address=m + M_FILTER * 8
    )[unsafe_offset=0] = _x_filter
    UnsafePointer[XVtabFn, MutAnyOrigin](unsafe_from_address=m + M_NEXT * 8)[
        unsafe_offset=0
    ] = _x_next
    UnsafePointer[XVtabFn, MutAnyOrigin](unsafe_from_address=m + M_EOF * 8)[
        unsafe_offset=0
    ] = _x_eof
    UnsafePointer[XColumnFn, MutAnyOrigin](
        unsafe_from_address=m + M_COLUMN * 8
    )[unsafe_offset=0] = _x_column
    UnsafePointer[XRowidFn, MutAnyOrigin](unsafe_from_address=m + M_ROWID * 8)[
        unsafe_offset=0
    ] = _x_rowid

    return m


comptime FreeFn = def (Int) thin abi("C") -> None


def _free_shim(p: Int) abi("C") -> None:
    """Destructor handed to SQLite for buffers it should own."""
    external_call["sqlite3_free", NoneType](p)


def _register(db_handle: Int) raises:
    """Register `m0_array` on a connection. See `Connection.register_array_module`."""
    var m = _build_module()
    var name = c_string(ARRAY_NAME)
    var destroy: FreeFn = _free_shim
    # pAux is the module buffer itself, with a free destructor, so SQLite owns
    # the allocation from here and releases it when the module is dropped.
    var rc = Int(
        external_call["sqlite3_create_module_v2", c_int](
            db_handle, name.unsafe_ptr(), m, m, destroy
        )
    )
    if rc != SQLITE_OK:
        external_call["sqlite3_free", NoneType](m)
        raise Error("sqlite3_create_module_v2 failed (rc=" + String(rc) + ")")


# --- Spec headers, used by the Statement borrow helpers ----------------------


def _bind_spec(
    stmt_handle: Int, param: Int, data: Int, count: Int, kind: Int
) raises:
    """Bind a {data, count, kind} header to `param` as a tagged pointer.

    The header is SQLite-allocated and freed by the bind destructor, so it needs
    no Mojo-side lifetime. The array it points at is the dangerous part — that
    is what the `*_over` helpers exist to keep alive.
    """
    var p = Int(external_call["sqlite3_malloc64", Int](Int64(S_WORDS * 8)))
    if p == 0:
        raise Error("sqlite3_malloc64 failed for an array spec")
    var w = _words(p)
    w[unsafe_offset=S_DATA] = data
    w[unsafe_offset=S_COUNT] = count
    w[unsafe_offset=S_KIND] = kind

    var destroy: FreeFn = _free_shim
    var rc = Int(
        external_call["sqlite3_bind_pointer", c_int](
            stmt_handle, c_int(param), p, ARRAY_TAG.unsafe_ptr(), destroy
        )
    )
    if rc != SQLITE_OK:
        # bind_pointer only runs the destructor on success.
        external_call["sqlite3_free", NoneType](p)
        raise Error("sqlite3_bind_pointer failed (rc=" + String(rc) + ")")
