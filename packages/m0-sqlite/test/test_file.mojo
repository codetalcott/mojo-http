"""File-backed database tests: WAL, persistence across reopen, read-only.

Separate from test_sqlite.mojo because these touch the filesystem. They matter
disproportionately: the NUL-termination bug that `c_string` exists to prevent
only ever manifested on a *path* argument, and only for some path lengths, so
an in-memory-only suite would never have caught it.
"""

from std.os import remove, mkdir, path
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from src import Connection, open, open_readonly, open_memory


comptime DIR = "/tmp/m0-sqlite-test"


def _cleanup(db_path: String):
    """Remove the database and any WAL sidecars it left behind."""
    for suffix in [String(""), String("-wal"), String("-shm"), String("-journal")]:
        var p = db_path + suffix
        if path.exists(p):
            try:
                remove(p)
            except:
                pass


def _fresh(name: String) raises -> String:
    """A clean database path under a directory that already exists."""
    if not path.exists(DIR):
        mkdir(DIR)
    var p = String(DIR) + "/" + name + ".db"
    _cleanup(p)
    return p^


def test_create_write_reopen() raises:
    """Data must survive closing and reopening the file."""
    var p = _fresh("roundtrip")
    var db = open(p)
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    var ins = db.prepare("INSERT INTO t (v) VALUES (?)")
    ins.bind_text(1, "persisted")
    _ = ins.step()
    ins.finalize()
    db.close()

    var again = open(p)
    var q = again.prepare("SELECT v FROM t")
    assert_true(q.step())
    assert_equal(q.column_text(0), "persisted")
    q.finalize()
    again.close()
    _cleanup(p)


def test_wal_mode_is_actually_set() raises:
    """WAL is promised by open(); confirm SQLite agrees, not just the pragma."""
    var p = _fresh("walmode")
    var db = open(p)
    var q = db.prepare("PRAGMA journal_mode")
    assert_true(q.step())
    assert_equal(q.column_text(0), "wal")
    q.finalize()
    db.close()
    _cleanup(p)


def test_readonly_rejects_writes() raises:
    var p = _fresh("ro")
    var db = open(p)
    db.execute("CREATE TABLE t (v INTEGER)")
    db.execute("INSERT INTO t VALUES (1)")
    db.close()

    var ro = open_readonly(p)
    var q = ro.prepare("SELECT COUNT(*) FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 1)
    q.finalize()
    with assert_raises():
        ro.execute("INSERT INTO t VALUES (2)")
    ro.close()
    _cleanup(p)


def test_paths_of_many_lengths_open_cleanly() raises:
    """The regression guard for the NUL-termination bug.

    Whether a stray NUL happened to follow a String's last byte depended on
    allocation layout, so the original failure appeared at some path lengths and
    not others. Sweeping lengths is the only way to catch a relapse.

    Opens with raw flags rather than `open()` on purpose: the pragmas that
    `open()` applies — `journal_mode=WAL` especially — cost an fsync each, which
    turned this sweep into two minutes. The bug is in how the *path* is
    marshalled, and that is exercised just as well without them.
    """
    from src import SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE

    for n in range(1, 40):
        var name = String("p")
        for _ in range(n):
            name += "x"
        var p = _fresh(name)
        var db = Connection(p, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        db.execute("PRAGMA synchronous=OFF")
        db.execute("CREATE TABLE t (v INTEGER)")
        db.execute("INSERT INTO t VALUES (42)")
        var q = db.prepare("SELECT v FROM t")
        assert_true(q.step())
        assert_equal(q.column_int(0), 42)
        q.finalize()
        db.close()
        _cleanup(p)


def test_two_connections_see_each_other() raises:
    """WAL lets a reader and a writer hold the same file concurrently."""
    var p = _fresh("concurrent")
    var w = open(p)
    w.execute("CREATE TABLE t (v INTEGER)")
    w.execute("INSERT INTO t VALUES (1)")

    var r = open_readonly(p)
    var q = r.prepare("SELECT COUNT(*) FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 1)
    q.finalize()

    w.execute("INSERT INTO t VALUES (2)")
    var q2 = r.prepare("SELECT COUNT(*) FROM t")
    assert_true(q2.step())
    assert_equal(q2.column_int(0), 2)
    q2.finalize()

    r.close()
    w.close()
    _cleanup(p)


def test_transaction_rollback_survives_reopen() raises:
    """A rolled-back write must not be on disk after reopening."""
    var p = _fresh("rollback")
    var db = open(p)
    db.execute("CREATE TABLE t (v INTEGER)")
    db.begin()
    db.execute("INSERT INTO t VALUES (99)")
    db.rollback()
    db.close()

    var again = open(p)
    var q = again.prepare("SELECT COUNT(*) FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 0)
    q.finalize()
    again.close()
    _cleanup(p)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
