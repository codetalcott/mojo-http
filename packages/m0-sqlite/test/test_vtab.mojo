"""Tests for `m0_array(?)` and the borrow-enforced array parameters.

The correctness tests matter less here than the safety ones. Binding a raw Mojo
pointer to SQLite fails *silently* when it fails — a freed `List` reads back
with a freelist pointer in word 0 and correct data everywhere else — so several
of these exist to make that specific corruption impossible to reintroduce
unnoticed.
"""

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
    assert_raises,
    TestSuite,
)

from src import (
    Connection,
    Statement,
    open_memory,
    libversion,
    error_code,
    SQLITE_RANGE,
)
from src.ffi import libversion_number


def _db() raises -> Connection:
    var db = open_memory()
    db.register_array_module()
    return db^


def _seeded(rows: Int) raises -> Connection:
    var db = _db()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
    db.begin()
    var ins = db.prepare("INSERT INTO t VALUES (?, ?)")
    for i in range(rows):
        ins.reset()
        ins.bind_int(1, i)
        ins.bind_int(2, i * 2)
        _ = ins.step()
    _ = ins^
    db.commit()
    return db^


def _seq(n: Int, mul: Int) -> List[Int]:
    var out = List[Int](length=n, fill=0)
    for i in range(n):
        out[i] = i * mul
    return out^


# --- Registration -------------------------------------------------------------

def test_module_is_not_registered_by_default() raises:
    """Opt-in per connection — an unregistered connection must not see it."""
    var db = open_memory()
    with assert_raises():
        _ = db.prepare("SELECT value FROM m0_array(?1)")


def test_version_guard_admits_this_build() raises:
    """The guard must pass on any SQLite new enough to run these tests.

    Asserts a floor rather than an exact version: pinning one would turn a
    contributor's newer (or older-but-adequate) libsqlite3 into a spurious
    failure, which is the opposite of what the guard is for. The interesting
    case — an actual pre-3.26 build — cannot be exercised here without a
    second libsqlite3 to link against.
    """
    var n = libversion_number()
    assert_true(n >= 3_026_000)
    # Sanity-check the encoding itself, so a bogus reading cannot satisfy the
    # floor by accident: major*1000000 + minor*1000 + patch.
    var major = n // 1_000_000
    assert_true(major >= 3)
    assert_true((n // 1000) % 1000 < 1000)
    assert_equal(String(major) + ".", libversion()[byte=0:2])


def test_register_is_idempotent() raises:
    var db = open_memory()
    db.register_array_module()
    db.register_array_module()
    var q = db.prepare("SELECT value FROM m0_array(?1)")
    var data = _seq(3, 5)
    var out = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, data, out), 3)
    assert_equal(out[2], 10)


def test_closing_a_connection_with_the_module_is_clean() raises:
    """The module buffer is SQLite-owned; closing must not double-free it."""
    for _ in range(20):
        var db = _db()
        var q = db.prepare("SELECT count(*) FROM m0_array(?1)")
        var data = _seq(4, 1)
        var out = List[Int]()
        _ = q.fetch_ints_over(0, 1, data, out)
        db.close()


# --- Reading through the vtab -------------------------------------------------

def test_scan_returns_the_array() raises:
    var db = _db()
    var q = db.prepare("SELECT value FROM m0_array(?1)")
    var data = _seq(5, 10)
    var out = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, data, out), 5)
    for i in range(5):
        assert_equal(out[i], i * 10)


def test_empty_array_yields_no_rows() raises:
    var db = _db()
    var q = db.prepare("SELECT value FROM m0_array(?1)")
    var data = List[Int]()
    var out = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, data, out), 0)
    assert_equal(len(out), 0)


def test_large_array_scans_intact() raises:
    """Past any allocator size class, and long enough to catch a stride error."""
    var db = _db()
    var q = db.prepare("SELECT value FROM m0_array(?1)")
    var data = _seq(50_000, 3)
    var out = List[Int](capacity=50_000)
    assert_equal(q.fetch_ints_over(0, 1, data, out), 50_000)
    assert_equal(out[0], 0)
    assert_equal(out[49_999], 149_997)
    var mismatches = 0
    for i in range(50_000):
        if out[i] != i * 3:
            mismatches += 1
    assert_equal(mismatches, 0)


def test_in_clause_over_a_real_table() raises:
    var db = _seeded(100)
    var ids = List[Int](length=3, fill=0)
    ids[0] = 5
    ids[1] = 7
    ids[2] = 9
    var q = db.prepare(
        "SELECT sum(v) FROM t WHERE id IN (SELECT value FROM m0_array(?1))"
    )
    var out = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, ids, out), 1)
    assert_equal(out[0], 42)


def test_statement_reuse_with_a_different_array() raises:
    var db = _seeded(100)
    var q = db.prepare(
        "SELECT sum(v) FROM t WHERE id IN (SELECT value FROM m0_array(?1))"
    )
    var a = List[Int](length=2, fill=0)
    a[0] = 1
    a[1] = 2
    var out_a = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, a, out_a), 1)
    assert_equal(out_a[0], 6)

    var b = List[Int](length=3, fill=0)
    b[0] = 10
    b[1] = 11
    b[2] = 12
    var out_b = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, b, out_b), 1)
    assert_equal(out_b[0], 66)


# --- Ingest -------------------------------------------------------------------

def test_ingest_inserts_every_row() raises:
    var db = _db()
    db.execute("CREATE TABLE t (v INTEGER)")
    var data = _seq(1000, 7)
    var ins = db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
    ins.execute_over(1, data)
    assert_equal(db.changes(), 1000)

    var q = db.prepare("SELECT count(*), sum(v), min(v), max(v) FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 1000)
    assert_equal(q.column_int(1), 999 * 1000 // 2 * 7)
    assert_equal(q.column_int(2), 0)
    assert_equal(q.column_int(3), 999 * 7)


def test_ingest_matches_the_per_row_loop_exactly() raises:
    """The whole point is that this is the same insert, only faster."""
    var data = _seq(500, 13)

    var loop_db = open_memory()
    loop_db.execute("CREATE TABLE t (v INTEGER)")
    loop_db.begin()
    var ins = loop_db.prepare("INSERT INTO t VALUES (?)")
    for i in range(len(data)):
        ins.reset()
        ins.bind_int(1, data[i])
        _ = ins.step()
    _ = ins^
    loop_db.commit()

    var vt_db = _db()
    vt_db.execute("CREATE TABLE t (v INTEGER)")
    var vins = vt_db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
    vins.execute_over(1, data)

    var q1 = loop_db.prepare("SELECT v FROM t ORDER BY rowid")
    var a = List[Int]()
    _ = q1.fetch_ints(0, a)
    var q2 = vt_db.prepare("SELECT v FROM t ORDER BY rowid")
    var b = List[Int]()
    _ = q2.fetch_ints(0, b)

    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(a[i], b[i])


def test_ingest_into_a_multi_column_table() raises:
    """Derived columns work; only the array column comes from Mojo."""
    var db = _db()
    db.execute("CREATE TABLE t (v INTEGER, doubled INTEGER, tag TEXT)")
    var data = _seq(10, 4)
    var ins = db.prepare(
        "INSERT INTO t SELECT value, value * 2, 'x' FROM m0_array(?1)"
    )
    ins.execute_over(1, data)
    assert_equal(db.changes(), 10)

    var q = db.prepare("SELECT sum(doubled) FROM t WHERE tag = 'x'")
    assert_true(q.step())
    assert_equal(q.column_int(0), 9 * 10 // 2 * 4 * 2)


def test_ingest_empty_array_inserts_nothing() raises:
    var db = _db()
    db.execute("CREATE TABLE t (v INTEGER)")
    var data = List[Int]()
    var ins = db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
    ins.execute_over(1, data)
    var q = db.prepare("SELECT count(*) FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 0)


def test_ingest_reuses_one_statement() raises:
    var db = _db()
    db.execute("CREATE TABLE t (v INTEGER)")
    var ins = db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
    var a = _seq(3, 1)
    var b = _seq(4, 100)
    ins.execute_over(1, a)
    ins.execute_over(1, b)

    var q = db.prepare("SELECT count(*) FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 7)


# --- Floats -------------------------------------------------------------------

def test_float_arrays_roundtrip() raises:
    var db = _db()
    db.execute("CREATE TABLE t (v REAL)")
    var data = List[Float64](length=4, fill=0.0)
    for i in range(4):
        data[i] = Float64(i) * 1.5
    var ins = db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
    ins.execute_over(1, data)
    assert_equal(db.changes(), 4)

    var q = db.prepare("SELECT sum(v) FROM t")
    assert_true(q.step())
    assert_almost_equal(q.column_float(0), 9.0)


def test_float_and_int_arrays_do_not_alias() raises:
    """The kind tag has to travel with the pointer, not be inferred."""
    var db = _db()
    var ints = _seq(3, 1000)
    var q = db.prepare("SELECT value FROM m0_array(?1)")
    var out = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, ints, out), 3)
    assert_equal(out[1], 1000)

    db.execute("CREATE TABLE f (v REAL)")
    var floats = List[Float64](length=3, fill=2.5)
    var ins = db.prepare("INSERT INTO f SELECT value FROM m0_array(?1)")
    ins.execute_over(1, floats)
    var qf = db.prepare("SELECT sum(v) FROM f")
    assert_true(qf.step())
    assert_almost_equal(qf.column_float(0), 7.5)


# --- Safety -------------------------------------------------------------------

def test_untagged_parameter_is_not_read_as_a_pointer() raises:
    """A plain integer in the spec slot must not be dereferenced.

    `sqlite3_value_pointer` returns NULL unless the value was bound with a
    matching tag, which is what stops a stray parameter from being treated as
    an address. Without that check this test would segfault rather than fail.
    """
    var db = _db()
    var q = db.prepare("SELECT count(*) FROM m0_array(?1)")
    q.bind_int(1, 0x4141414141)
    assert_true(q.step())
    assert_equal(q.column_int(0), 0)


def test_null_parameter_yields_no_rows() raises:
    var db = _db()
    var q = db.prepare("SELECT count(*) FROM m0_array(?1)")
    q.bind_null(1)
    assert_true(q.step())
    assert_equal(q.column_int(0), 0)


def test_borrow_is_dropped_after_the_call() raises:
    """A step after the helper returns must not reach the old array.

    This is the guarantee that makes the shape safe rather than merely
    convenient: the helper unbinds before returning, so even a caller who
    re-steps the statement by hand sees an empty table instead of freed memory.
    """
    var db = _db()
    var q = db.prepare("SELECT count(*) FROM m0_array(?1)")
    var data = _seq(6, 2)
    var out = List[Int]()
    assert_equal(q.fetch_ints_over(0, 1, data, out), 1)
    assert_equal(out[0], 6)

    q.reset()
    assert_true(q.step())
    assert_equal(q.column_int(0), 0)


def test_array_survives_allocation_churn_during_the_scan() raises:
    """Regression guard for the freed-buffer bug.

    The failure mode this protects against is silent: a freed `List` reads back
    with a freelist pointer in word 0 and intact data everywhere else, so it
    shows up as one wrong element rather than a crash. Element 0 is checked
    explicitly because that is the one that lied.
    """
    var db = _seeded(200)
    var ids = _seq(64, 1)
    var out = List[Int]()
    var q = db.prepare(
        "SELECT value FROM m0_array(?1) ORDER BY value"
    )
    assert_equal(q.fetch_ints_over(0, 1, ids, out), 64)
    assert_equal(out[0], 0)
    for i in range(64):
        assert_equal(out[i], i)


def test_out_of_range_parameter_raises_cleanly() raises:
    """SQLITE_RANGE from bind_pointer must surface as an error, not corrupt.

    Regression guard for a double free: bind_pointer runs the spec destructor
    even when the bind *fails*, so the failure path must not free the spec a
    second time. The double free itself is silent heap corruption this test
    cannot reliably observe — what it pins is the contract: a clean raise
    carrying SQLITE_RANGE, and a statement that still works afterwards.
    """
    var db = _db()
    var q = db.prepare("SELECT count(*) FROM m0_array(?1)")
    var data = _seq(3, 1)
    var out = List[Int]()

    var code = -1
    try:
        _ = q.fetch_ints_over(0, 2, data, out)  # the statement has one param
    except e:
        code = error_code(String(e))
    assert_equal(code, SQLITE_RANGE)

    # The failed bind must not poison the statement.
    assert_equal(q.fetch_ints_over(0, 1, data, out), 1)
    assert_equal(out[0], 3)


def test_repeated_binds_do_not_leak_the_spec() raises:
    """Each bind replaces the previous, whose destructor frees its header."""
    var db = _db()
    var q = db.prepare("SELECT count(*) FROM m0_array(?1)")
    var data = _seq(3, 1)
    for _ in range(2000):
        var out = List[Int]()
        assert_equal(q.fetch_ints_over(0, 1, data, out), 1)
        assert_equal(out[0], 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
