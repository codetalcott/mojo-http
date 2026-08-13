"""Tests for the bulk read-out API: memcpy blob reads and SoA column fetches.

Everything runs against `:memory:`. The blob cases here are the regression
guard for the `unsafe_memcpy` rewrite of `column_blob` — the old per-byte loop
could not get a length wrong, a memcpy can.
"""

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
    TestSuite,
)

from src import Connection, Statement, open_memory


def _blob(n: Int, seed: Int) -> List[UInt8]:
    """A byte pattern that is not all-zero and differs per seed."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 7 + seed) & 0xFF))
    return out^


def _with_blobs(rows: Int, size: Int) raises -> Connection:
    var db = open_memory()
    db.execute("CREATE TABLE b (id INTEGER PRIMARY KEY, v BLOB)")
    var ins = db.prepare("INSERT INTO b (id, v) VALUES (?, ?)")
    for i in range(rows):
        ins.reset()
        ins.bind_int(1, i)
        ins.bind_blob(2, _blob(size, i))
        _ = ins.step()
    return db^


# --- column_blob --------------------------------------------------------------

def test_blob_roundtrips_byte_for_byte() raises:
    """A memcpy read must reproduce the source pattern exactly."""
    var db = _with_blobs(1, 64)
    var q = db.prepare("SELECT v FROM b")
    assert_true(q.step())
    var got = q.column_blob(0)
    var want = _blob(64, 0)
    assert_equal(len(got), 64)
    for i in range(64):
        assert_equal(got[i], want[i])


def test_blob_with_embedded_nuls_survives() raises:
    """Length-driven, so a NUL byte is data rather than a terminator."""
    var db = open_memory()
    db.execute("CREATE TABLE t (v BLOB)")
    var payload = List[UInt8](capacity=5)
    payload.append(1)
    payload.append(0)
    payload.append(2)
    payload.append(0)
    payload.append(3)
    var ins = db.prepare("INSERT INTO t VALUES (?)")
    ins.bind_blob(1, payload)
    _ = ins.step()

    var q = db.prepare("SELECT v FROM t")
    assert_true(q.step())
    var got = q.column_blob(0)
    assert_equal(len(got), 5)
    assert_equal(got[1], 0)
    assert_equal(got[3], 0)
    assert_equal(got[4], 3)


def test_empty_and_null_blobs_read_as_empty() raises:
    """Both yield an empty list; `is_null` is what tells them apart."""
    var db = open_memory()
    db.execute("CREATE TABLE t (v BLOB)")
    db.execute("INSERT INTO t VALUES (x'')")
    db.execute("INSERT INTO t VALUES (NULL)")

    var q = db.prepare("SELECT v FROM t")
    assert_true(q.step())
    assert_equal(len(q.column_blob(0)), 0)
    assert_false(q.is_null(0))

    assert_true(q.step())
    assert_equal(len(q.column_blob(0)), 0)
    assert_true(q.is_null(0))


def test_large_blob_roundtrips() raises:
    """Past any plausible inline threshold, so the pointer is to spilled data."""
    var db = _with_blobs(1, 100_000)
    var q = db.prepare("SELECT v FROM b")
    assert_true(q.step())
    var got = q.column_blob(0)
    assert_equal(len(got), 100_000)
    assert_equal(got[0], UInt8(0))
    assert_equal(got[99_999], UInt8((99_999 * 7) & 0xFF))


# --- column_blob_into ---------------------------------------------------------

def test_blob_into_reuses_one_buffer() raises:
    """The buffer is resized to each row's exact length, never left stale."""
    var db = open_memory()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")
    var ins = db.prepare("INSERT INTO t (id, v) VALUES (?, ?)")
    ins.bind_int(1, 1)
    ins.bind_blob(2, _blob(32, 1))
    _ = ins.step()
    ins.reset()
    ins.bind_int(1, 2)
    ins.bind_blob(2, _blob(8, 2))
    _ = ins.step()

    var buf = List[UInt8]()
    var q = db.prepare("SELECT v FROM t ORDER BY id")

    assert_true(q.step())
    assert_equal(q.column_blob_into(0, buf), 32)
    assert_equal(len(buf), 32)

    # Shrinking row: no tail from the previous, longer row may survive.
    assert_true(q.step())
    assert_equal(q.column_blob_into(0, buf), 8)
    assert_equal(len(buf), 8)
    var want = _blob(8, 2)
    for i in range(8):
        assert_equal(buf[i], want[i])


def test_blob_into_matches_column_blob() raises:
    var db = _with_blobs(1, 257)
    var q = db.prepare("SELECT v, v FROM b")
    assert_true(q.step())
    var owned = q.column_blob(0)
    var buf = List[UInt8]()
    assert_equal(q.column_blob_into(1, buf), len(owned))
    for i in range(len(owned)):
        assert_equal(buf[i], owned[i])


def test_blob_into_clears_on_null() raises:
    var db = open_memory()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")
    db.execute("INSERT INTO t VALUES (1, x'AABBCC')")
    db.execute("INSERT INTO t VALUES (2, NULL)")

    var buf = List[UInt8]()
    var q = db.prepare("SELECT v FROM t ORDER BY id")
    assert_true(q.step())
    assert_equal(q.column_blob_into(0, buf), 3)
    assert_true(q.step())
    assert_equal(q.column_blob_into(0, buf), 0)
    assert_equal(len(buf), 0)


# --- SoA fetches --------------------------------------------------------------

def _numbers(rows: Int) raises -> Connection:
    var db = open_memory()
    db.execute("CREATE TABLE n (i INTEGER, f REAL, s TEXT)")
    var ins = db.prepare("INSERT INTO n VALUES (?, ?, ?)")
    for k in range(rows):
        ins.reset()
        ins.bind_int(1, k)
        ins.bind_float(2, Float64(k) * 1.5)
        ins.bind_text(3, "row" + String(k))
        _ = ins.step()
    return db^


def test_fetch_ints_reads_every_row() raises:
    var db = _numbers(100)
    var q = db.prepare("SELECT i FROM n ORDER BY i")
    var out = List[Int](capacity=100)
    assert_equal(q.fetch_ints(0, out), 100)
    assert_equal(len(out), 100)
    assert_equal(out[0], 0)
    assert_equal(out[99], 99)


def test_fetch_floats_and_texts() raises:
    var db = _numbers(10)
    var qf = db.prepare("SELECT f FROM n ORDER BY i")
    var floats = List[Float64]()
    assert_equal(qf.fetch_floats(0, floats), 10)
    assert_almost_equal(floats[4], 6.0)

    var qs = db.prepare("SELECT s FROM n ORDER BY i")
    var texts = List[String]()
    assert_equal(qs.fetch_texts(0, texts), 10)
    assert_equal(texts[0], "row0")
    assert_equal(texts[9], "row9")


def test_fetch_respects_max_rows_and_resumes() raises:
    """A capped fetch leaves the cursor mid-scan so the next call continues."""
    var db = _numbers(10)
    var q = db.prepare("SELECT i FROM n ORDER BY i")
    var out = List[Int]()

    assert_equal(q.fetch_ints(0, out, max_rows=4), 4)
    assert_equal(len(out), 4)
    assert_equal(out[3], 3)

    assert_equal(q.fetch_ints(0, out, max_rows=4), 4)
    assert_equal(out[4], 4)
    assert_equal(out[7], 7)

    # A short read — fewer than the cap — is how exhaustion is signalled.
    assert_equal(q.fetch_ints(0, out, max_rows=4), 2)
    assert_equal(len(out), 10)
    assert_equal(out[9], 9)


def test_fetching_past_exhaustion_is_never_a_quiet_zero() raises:
    """Nobody may write `while fetch(...) > 0` — stop on the short read.

    Stepping past SQLITE_DONE is not portable, and CI proved it: Linux's
    libsqlite3 auto-resets and re-runs the query, while macOS's returns
    SQLITE_MISUSE, which `step` raises. So this asserts only what holds on
    both — it is never the quiet 0 that would make a `> 0` loop look correct.
    """
    var db = _numbers(3)
    var q = db.prepare("SELECT i FROM n ORDER BY i")
    var out = List[Int]()

    # A short read: 3 < 4, so this call consumed SQLITE_DONE.
    assert_equal(q.fetch_ints(0, out, max_rows=4), 3)

    var again = 0
    var raised = False
    try:
        again = q.fetch_ints(0, out, max_rows=4)
    except:
        raised = True  # SQLITE_MISUSE on this platform

    if not raised:
        # Restarted from the top rather than reporting the end.
        assert_equal(again, 3)
        assert_equal(out[3], 0)


def test_capped_fetch_resumes_and_then_reports_the_end() raises:
    """A call that stops on the cap has not seen DONE, so this stays portable."""
    var db = _numbers(3)
    var q = db.prepare("SELECT i FROM n ORDER BY i")
    var out = List[Int]()
    assert_equal(q.fetch_ints(0, out, max_rows=3), 3)
    assert_equal(q.fetch_ints(0, out, max_rows=3), 0)
    assert_equal(len(out), 3)


def test_fetch_on_empty_result_appends_nothing() raises:
    var db = _numbers(3)
    var q = db.prepare("SELECT i FROM n WHERE i > 100")
    var out = List[Int]()
    assert_equal(q.fetch_ints(0, out), 0)
    assert_equal(len(out), 0)


def test_fetch_max_rows_zero_reads_nothing() raises:
    var db = _numbers(3)
    var q = db.prepare("SELECT i FROM n")
    var out = List[Int]()
    assert_equal(q.fetch_ints(0, out, max_rows=0), 0)
    assert_equal(len(out), 0)


def test_fetch_appends_to_a_non_empty_list() raises:
    """Append semantics, not replace — so several queries can fill one column."""
    var db = _numbers(3)
    var out = List[Int]()
    out.append(-1)
    var q = db.prepare("SELECT i FROM n ORDER BY i")
    assert_equal(q.fetch_ints(0, out), 3)
    assert_equal(len(out), 4)
    assert_equal(out[0], -1)
    assert_equal(out[1], 0)


def test_fetch_after_reset_rereads() raises:
    var db = _numbers(5)
    var q = db.prepare("SELECT i FROM n ORDER BY i")
    var a = List[Int]()
    assert_equal(q.fetch_ints(0, a), 5)
    q.reset()
    var b = List[Int]()
    assert_equal(q.fetch_ints(0, b), 5)
    for i in range(5):
        assert_equal(a[i], b[i])


def test_fetch_ints_matches_the_manual_loop() raises:
    """The bulk path must agree with the per-row path it is shorthand for."""
    var db = _numbers(64)
    var manual = List[Int]()
    var q1 = db.prepare("SELECT i FROM n ORDER BY i DESC")
    while q1.step():
        manual.append(q1.column_int(0))

    var bulk = List[Int]()
    var q2 = db.prepare("SELECT i FROM n ORDER BY i DESC")
    assert_equal(q2.fetch_ints(0, bulk), len(manual))
    for i in range(len(manual)):
        assert_equal(bulk[i], manual[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
