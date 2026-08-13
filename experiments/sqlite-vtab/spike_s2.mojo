"""S2: a minimal eponymous read-only virtual table, written entirely in Mojo.

`SELECT value FROM mojo_int64(?1, ?2)` streams a Mojo `List[Int]` bound with
sqlite3_bind_pointer. No C, no loadable extension — the sqlite3_module is a
flat word buffer of Mojo `abi("C")` function addresses handed to
sqlite3_create_module_v2 on a live connection.

The module struct is built as a flat buffer rather than a Mojo struct, matching
lightbug_http/c/epoll.mojo: a struct whose size is wrong by 4 bytes corrupts
everything downstream silently.
"""

from std.ffi import external_call, c_int
from std.memory import UnsafePointer

from src import open_memory, Connection, Statement
from src.ffi import c_string

comptime SQLITE_OK: Int = 0
comptime SQLITE_ERROR: Int = 1
comptime SQLITE_NOMEM: Int = 7
comptime SQLITE_CONSTRAINT: Int = 19
comptime SQLITE_INDEX_CONSTRAINT_EQ: Int = 2

# Static storage, verified stable: sqlite3_bind_pointer retains this string.
comptime PTR_TAG = "m0-int64"
comptime DECL_SQL = "CREATE TABLE x(value INTEGER, pointer HIDDEN, count HIDDEN)"

comptime WordPtr = UnsafePointer[Int, MutAnyOrigin]
comptime I32Ptr = UnsafePointer[Int32, MutAnyOrigin]
comptime U8Ptr = UnsafePointer[UInt8, MutAnyOrigin]
comptime F64Ptr = UnsafePointer[Float64, MutAnyOrigin]

# --- sqlite3_module slot indices (int iVersion + 24 function pointers) -------
comptime M_VERSION: Int = 0
comptime M_CREATE: Int = 1
comptime M_CONNECT: Int = 2
comptime M_BESTINDEX: Int = 3
comptime M_DISCONNECT: Int = 4
comptime M_DESTROY: Int = 5
comptime M_OPEN: Int = 6
comptime M_CLOSE: Int = 7
comptime M_FILTER: Int = 8
comptime M_NEXT: Int = 9
comptime M_EOF: Int = 10
comptime M_COLUMN: Int = 11
comptime M_ROWID: Int = 12
comptime M_SLOTS: Int = 25

# --- cursor layout (word-indexed): pVtab, data, count, i ---------------------
comptime C_VTAB: Int = 0
comptime C_DATA: Int = 1
comptime C_COUNT: Int = 2
comptime C_INDEX: Int = 3
comptime C_WORDS: Int = 4

# --- sqlite3_index_info, word-indexed on LP64 --------------------------------
#   0 nConstraint(int32)   1 aConstraint*      2 nOrderBy(int32)  3 aOrderBy*
#   4 aConstraintUsage*    5 idxNum(int32)     6 idxStr*
#   7 needToFreeIdxStr|orderByConsumed         8 estimatedCost(double)
comptime II_NCONSTRAINT: Int = 0
comptime II_ACONSTRAINT: Int = 1
comptime II_AUSAGE: Int = 4
comptime II_IDXNUM: Int = 5
comptime II_COST: Int = 8

comptime CONSTRAINT_STRIDE: Int = 12  # int iColumn; u8 op; u8 usable; int iTermOffset
comptime USAGE_STRIDE: Int = 8  # int argvIndex; u8 omit


comptime XConnectFn = def (
    Int, Int, c_int, Int, Int, Int
) thin abi("C") -> c_int
comptime XBestIndexFn = def (Int, Int) thin abi("C") -> c_int
comptime XVtabFn = def (Int) thin abi("C") -> c_int
comptime XOpenFn = def (Int, Int) thin abi("C") -> c_int
comptime XFilterFn = def (Int, c_int, Int, c_int, Int) thin abi("C") -> c_int
comptime XColumnFn = def (Int, Int, c_int) thin abi("C") -> c_int
comptime XRowidFn = def (Int, Int) thin abi("C") -> c_int


def _words(addr: Int) -> WordPtr:
    return WordPtr(unsafe_from_address=addr)


# --- Module callbacks --------------------------------------------------------


def x_connect(
    db: Int, p_aux: Int, argc: c_int, argv: Int, pp_vtab: Int, pz_err: Int
) abi("C") -> c_int:
    var rc = Int(
        external_call["sqlite3_declare_vtab", c_int](
            db, DECL_SQL.unsafe_ptr()
        )
    )
    if rc != SQLITE_OK:
        return c_int(rc)

    # sqlite3_vtab is {pModule, nRef, zErrMsg}; allocate a zeroed 4 words.
    var p = Int(external_call["sqlite3_malloc64", Int](Int64(32)))
    if p == 0:
        return c_int(SQLITE_NOMEM)
    var w = _words(p)
    for i in range(4):
        w[unsafe_offset=i] = 0
    _words(pp_vtab)[unsafe_offset=0] = p
    return c_int(SQLITE_OK)


def x_disconnect(p_vtab: Int) abi("C") -> c_int:
    external_call["sqlite3_free", NoneType](p_vtab)
    return c_int(SQLITE_OK)


def x_best_index(p_vtab: Int, p_info: Int) abi("C") -> c_int:
    """Claim the hidden `pointer` and `count` columns as xFilter arguments."""
    var info = _words(p_info)
    var n = Int(I32Ptr(unsafe_from_address=p_info)[unsafe_offset=0])
    var a_constraint = info[unsafe_offset=II_ACONSTRAINT]
    var a_usage = info[unsafe_offset=II_AUSAGE]

    var ptr_slot = -1
    var cnt_slot = -1
    for i in range(n):
        var base = a_constraint + i * CONSTRAINT_STRIDE
        var i_column = Int(I32Ptr(unsafe_from_address=base)[unsafe_offset=0])
        var op = Int(U8Ptr(unsafe_from_address=base + 4)[unsafe_offset=0])
        var usable = Int(U8Ptr(unsafe_from_address=base + 5)[unsafe_offset=0])
        if usable == 0 or op != SQLITE_INDEX_CONSTRAINT_EQ:
            continue
        if i_column == 1:
            ptr_slot = i
        elif i_column == 2:
            cnt_slot = i

    var cost = F64Ptr(unsafe_from_address=p_info + II_COST * 8)
    var idx_num = I32Ptr(unsafe_from_address=p_info + II_IDXNUM * 8)

    if ptr_slot < 0 or cnt_slot < 0:
        # Unusable without both: make the planner avoid this path.
        idx_num[unsafe_offset=0] = Int32(0)
        cost[unsafe_offset=0] = 1.0e99
        return c_int(SQLITE_CONSTRAINT)

    var u_ptr = a_usage + ptr_slot * USAGE_STRIDE
    I32Ptr(unsafe_from_address=u_ptr)[unsafe_offset=0] = Int32(1)
    U8Ptr(unsafe_from_address=u_ptr + 4)[unsafe_offset=0] = UInt8(1)

    var u_cnt = a_usage + cnt_slot * USAGE_STRIDE
    I32Ptr(unsafe_from_address=u_cnt)[unsafe_offset=0] = Int32(2)
    U8Ptr(unsafe_from_address=u_cnt + 4)[unsafe_offset=0] = UInt8(1)

    idx_num[unsafe_offset=0] = Int32(1)
    cost[unsafe_offset=0] = 1.0
    return c_int(SQLITE_OK)


def x_open(p_vtab: Int, pp_cursor: Int) abi("C") -> c_int:
    var p = Int(external_call["sqlite3_malloc64", Int](Int64(C_WORDS * 8)))
    if p == 0:
        return c_int(SQLITE_NOMEM)
    var w = _words(p)
    for i in range(C_WORDS):
        w[unsafe_offset=i] = 0
    w[unsafe_offset=C_VTAB] = p_vtab
    _words(pp_cursor)[unsafe_offset=0] = p
    return c_int(SQLITE_OK)


def x_close(p_cursor: Int) abi("C") -> c_int:
    external_call["sqlite3_free", NoneType](p_cursor)
    return c_int(SQLITE_OK)


def x_filter(
    p_cursor: Int, idx_num: c_int, idx_str: Int, argc: c_int, argv: Int
) abi("C") -> c_int:
    var cur = _words(p_cursor)
    cur[unsafe_offset=C_INDEX] = 0
    cur[unsafe_offset=C_DATA] = 0
    cur[unsafe_offset=C_COUNT] = 0

    if Int(idx_num) != 1 or Int(argc) < 2:
        return c_int(SQLITE_OK)

    var vals = _words(argv)
    var data = Int(
        external_call["sqlite3_value_pointer", Int](
            vals[unsafe_offset=0], PTR_TAG.unsafe_ptr()
        )
    )
    var count = Int(
        external_call["sqlite3_value_int64", Int64](vals[unsafe_offset=1])
    )
    if data == 0 or count < 0:
        return c_int(SQLITE_OK)

    cur[unsafe_offset=C_DATA] = data
    cur[unsafe_offset=C_COUNT] = count
    return c_int(SQLITE_OK)


def x_next(p_cursor: Int) abi("C") -> c_int:
    var cur = _words(p_cursor)
    cur[unsafe_offset=C_INDEX] = cur[unsafe_offset=C_INDEX] + 1
    return c_int(SQLITE_OK)


def x_eof(p_cursor: Int) abi("C") -> c_int:
    var cur = _words(p_cursor)
    var done = cur[unsafe_offset=C_INDEX] >= cur[unsafe_offset=C_COUNT]
    return c_int(1) if done else c_int(0)


def x_column(p_cursor: Int, ctx: Int, col: c_int) abi("C") -> c_int:
    var cur = _words(p_cursor)
    if Int(col) == 0:
        var data = _words(cur[unsafe_offset=C_DATA])
        var v = data[unsafe_offset=cur[unsafe_offset=C_INDEX]]
        external_call["sqlite3_result_int64", NoneType](ctx, Int64(v))
    else:
        external_call["sqlite3_result_null", NoneType](ctx)
    return c_int(SQLITE_OK)


def x_rowid(p_cursor: Int, p_rowid: Int) abi("C") -> c_int:
    var cur = _words(p_cursor)
    _words(p_rowid)[unsafe_offset=0] = cur[unsafe_offset=C_INDEX]
    return c_int(SQLITE_OK)


# --- Registration ------------------------------------------------------------


def build_module() -> List[Int]:
    """The sqlite3_module as a flat word buffer. Must outlive the connection."""
    var m = List[Int](length=M_SLOTS, fill=0)
    var base = Int(m.unsafe_ptr())

    m[M_VERSION] = 1  # iVersion; xCreate stays 0 => eponymous-only

    UnsafePointer[XConnectFn, MutAnyOrigin](
        unsafe_from_address=base + M_CONNECT * 8
    )[unsafe_offset=0] = x_connect
    UnsafePointer[XBestIndexFn, MutAnyOrigin](
        unsafe_from_address=base + M_BESTINDEX * 8
    )[unsafe_offset=0] = x_best_index
    UnsafePointer[XVtabFn, MutAnyOrigin](
        unsafe_from_address=base + M_DISCONNECT * 8
    )[unsafe_offset=0] = x_disconnect
    UnsafePointer[XOpenFn, MutAnyOrigin](
        unsafe_from_address=base + M_OPEN * 8
    )[unsafe_offset=0] = x_open
    UnsafePointer[XVtabFn, MutAnyOrigin](
        unsafe_from_address=base + M_CLOSE * 8
    )[unsafe_offset=0] = x_close
    UnsafePointer[XFilterFn, MutAnyOrigin](
        unsafe_from_address=base + M_FILTER * 8
    )[unsafe_offset=0] = x_filter
    UnsafePointer[XVtabFn, MutAnyOrigin](
        unsafe_from_address=base + M_NEXT * 8
    )[unsafe_offset=0] = x_next
    UnsafePointer[XVtabFn, MutAnyOrigin](
        unsafe_from_address=base + M_EOF * 8
    )[unsafe_offset=0] = x_eof
    UnsafePointer[XColumnFn, MutAnyOrigin](
        unsafe_from_address=base + M_COLUMN * 8
    )[unsafe_offset=0] = x_column
    UnsafePointer[XRowidFn, MutAnyOrigin](
        unsafe_from_address=base + M_ROWID * 8
    )[unsafe_offset=0] = x_rowid

    return m^


def register(mut db: Connection, mut module: List[Int]) raises:
    var name = c_string("mojo_int64")
    var rc = Int(
        external_call["sqlite3_create_module_v2", c_int](
            db._handle,
            name.unsafe_ptr(),
            Int(module.unsafe_ptr()),
            Int(0),
            Int(0),
        )
    )
    if rc != SQLITE_OK:
        raise Error("create_module_v2 failed rc=" + String(rc))


def bind_array(mut stmt: Statement, index: Int, mut data: List[Int]) raises:
    """Hand SQLite a borrowed view of `data`. It must outlive the statement."""
    var rc = Int(
        external_call["sqlite3_bind_pointer", c_int](
            stmt._handle,
            c_int(index),
            Int(data.unsafe_ptr()),
            PTR_TAG.unsafe_ptr(),
            Int(0),
        )
    )
    if rc != SQLITE_OK:
        raise Error("bind_pointer failed rc=" + String(rc))


def main() raises:
    var module = build_module()
    var db = open_memory()
    register(db, module)
    print("module registered")

    var data = List[Int](length=5, fill=0)
    for i in range(5):
        data[i] = (i + 1) * 10

    # 1. plain scan
    var q = db.prepare("SELECT value FROM mojo_int64(?1, ?2)")
    bind_array(q, 1, data)
    q.bind_int(2, len(data))
    var got = List[Int]()
    _ = q.fetch_ints(0, got)
    print("scan ->", len(got), "rows")
    var ok = len(got) == 5
    for i in range(len(got)):
        if got[i] != (i + 1) * 10:
            ok = False
    print("values correct:", ok)
    if not ok:
        raise Error("WRONG values")

    # 2. aggregate over the vtab
    var q2 = db.prepare("SELECT sum(value), count(*) FROM mojo_int64(?1, ?2)")
    bind_array(q2, 1, data)
    q2.bind_int(2, len(data))
    _ = q2.step()
    var sum2 = q2.column_int(0)
    var cnt2 = q2.column_int(1)
    _ = len(data)  # keep-alive: the bound buffer must outlive the step
    print("sum =", sum2, "count =", cnt2, "(want 150 5)")
    if sum2 != 150 or cnt2 != 5:
        raise Error("WRONG aggregate")

    # 3. the carray use case: IN over a real table
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
    db.begin()
    var ins = db.prepare("INSERT INTO t VALUES (?, ?)")
    for i in range(100):
        ins.reset()
        ins.bind_int(1, i)
        ins.bind_int(2, i * 2)
        _ = ins.step()
    _ = ins^
    db.commit()

    var ids = List[Int](length=3, fill=0)
    ids[0] = 5
    ids[1] = 7
    ids[2] = 9
    var q3 = db.prepare(
        "SELECT sum(v) FROM t WHERE id IN (SELECT value FROM mojo_int64(?1, ?2))"
    )
    bind_array(q3, 1, ids)
    q3.bind_int(2, len(ids))
    _ = q3.step()
    var sum3 = q3.column_int(0)
    _ = len(ids)  # keep-alive
    print("IN-clause sum =", sum3, "(want 42)")
    if sum3 != 42:
        raise Error("WRONG IN result")

    # 4. reuse the same prepared statement with a different array
    var more = List[Int](length=2, fill=0)
    more[0] = 1
    more[1] = 2
    q3.reset()
    bind_array(q3, 1, more)
    q3.bind_int(2, len(more))
    _ = q3.step()
    var sum4 = q3.column_int(0)
    _ = len(more)  # keep-alive
    print("reused stmt sum =", sum4, "(want 6)")
    if sum4 != 6:
        raise Error("WRONG reuse result")

    print("S2 PASS")
