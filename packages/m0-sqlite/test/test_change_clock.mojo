"""The change clock: what moves `Connection.data_version`, and for whom.

One writer (`open`, WAL) and one read-only connection to the same file
(`open_readonly`). The claim is the reader's column: it moves for every
statement that changes the main database file and for none that does not,
while the writer's own answer never moves for what the writer did. That
is why a cache is keyed by a reader's clock and needs no commit hook
(DECISIONS D60): the reader sees this process's commits like anyone
else's.

The one move with no change behind it is a `wal_checkpoint(TRUNCATE)`,
pinned here too, since it is why a validator hashes what was rendered
rather than carrying this number.
"""

from std.ffi import external_call, c_int
from std.os import remove, mkdir, path
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src import Connection, open, open_readonly


def _dir() -> String:
    return String("/tmp/m0-sqlite-clock-") + String(
        Int(external_call["getpid", c_int]())
    )


def _cleanup(db_path: String):
    for suffix in [String(""), String("-wal"), String("-shm"), String("-journal")]:
        var p = db_path + suffix
        if path.exists(p):
            try:
                remove(p)
            except:
                pass


def _fresh(name: String) raises -> String:
    var dir = _dir()
    if not path.exists(dir):
        mkdir(dir)
    var p = dir + "/" + name + ".db"
    _cleanup(p)
    return p^


struct Pair(Movable):
    """A writer and a reader over one file, and the clocks last read."""

    var w: Connection
    var r: Connection
    var w_seen: Int
    var r_seen: Int

    def __init__(out self, p: String) raises:
        self.w = open(p)
        self.w.execute("CREATE TABLE seed (x INTEGER)")
        self.r = open_readonly(p)
        self.w_seen = self.w.data_version()
        self.r_seen = self.r.data_version()

    def reader_moved(mut self) raises -> Bool:
        var now = self.r.data_version()
        var moved = now != self.r_seen
        self.r_seen = now
        return moved

    def writer_moved(mut self) raises -> Bool:
        var now = self.w.data_version()
        var moved = now != self.w_seen
        self.w_seen = now
        return moved


def _moves(mut c: Pair, sql: String) raises:
    """`sql` on the writer moves the reader's clock and not the writer's."""
    c.w.execute(sql)
    assert_true(c.reader_moved(), "the reader's clock stood still after: " + sql)
    assert_false(c.writer_moved(), "the writer's own clock moved after: " + sql)


def _stands(mut c: Pair, sql: String) raises:
    """`sql` on the writer moves neither clock."""
    c.w.execute(sql)
    assert_false(c.reader_moved(), "the reader's clock moved after: " + sql)
    assert_false(c.writer_moved(), "the writer's own clock moved after: " + sql)


def test_a_reader_sees_every_change_the_writer_commits() raises:
    """Every statement that changes the main file moves the reader's
    clock, and none of them the writer's own.

    covers: O25
    """
    var p = _fresh("moves")
    var c = Pair(p)
    _moves(c, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    _moves(c, "INSERT INTO t (v) VALUES ('a')")
    _moves(
        c,
        "BEGIN; INSERT INTO t (v) VALUES ('b'); INSERT INTO t (v) VALUES ('c');"
        " INSERT INTO t (v) VALUES ('d'); COMMIT",
    )
    _moves(c, "UPDATE t SET v = 'z' WHERE id = 1")
    _moves(c, "PRAGMA user_version = 7")
    _moves(c, "ALTER TABLE t ADD COLUMN extra TEXT")
    _moves(c, "DELETE FROM t")
    # A VACUUM can renumber the rowids of a table with no INTEGER PRIMARY
    # KEY, and a commit hook does not fire for it.
    _moves(c, "VACUUM")
    c.r.close()
    c.w.close()
    _cleanup(p)


def test_a_reader_stands_still_for_what_changed_nothing() raises:
    var p = _fresh("stands")
    var c = Pair(p)
    c.w.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    c.w.execute("INSERT INTO t (v) VALUES ('a')")
    _ = c.reader_moved()

    _ = c.w.query_scalar("SELECT count(*) FROM t")
    assert_false(c.reader_moved(), "a read moved the reader's clock")
    _stands(c, "BEGIN; INSERT INTO t (v) VALUES ('gone'); ROLLBACK")
    # The four a commit hook counts and the file never saw.
    _stands(c, "BEGIN IMMEDIATE; COMMIT")
    _stands(c, "UPDATE t SET v = 'q' WHERE id = 999")
    _stands(c, "CREATE TEMP TABLE scratch (x INTEGER); INSERT INTO scratch VALUES (1)")
    var other = _fresh("attached")
    c.w.execute("ATTACH DATABASE '" + other + "' AS side")
    _ = c.reader_moved()
    _stands(c, "CREATE TABLE side.s (x INTEGER); INSERT INTO side.s VALUES (1)")
    c.w.execute("DETACH DATABASE side")
    # Refused by the primary key: nothing was committed.
    var refused = False
    try:
        c.w.execute("INSERT INTO t (id, v) VALUES (1, 'dup')")
    except:
        refused = True
    assert_true(refused)
    assert_false(c.reader_moved(), "a refused INSERT moved the reader's clock")
    c.r.close()
    c.w.close()
    _cleanup(p)
    _cleanup(other)


def test_a_truncating_checkpoint_moves_the_clock_and_changes_nothing() raises:
    """The clock's one false move, and why the validator is a hash."""
    var p = _fresh("checkpoint")
    var c = Pair(p)
    c.w.execute("CREATE TABLE t (v TEXT)")
    c.w.execute("INSERT INTO t VALUES ('a')")
    _ = c.reader_moved()
    _stands(c, "PRAGMA wal_checkpoint(PASSIVE)")
    var before = c.r.query_scalar("SELECT group_concat(v) FROM t")
    c.w.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    assert_true(c.reader_moved(), "a TRUNCATE checkpoint no longer moves the clock")
    assert_equal(c.r.query_scalar("SELECT group_concat(v) FROM t"), before)
    c.r.close()
    c.w.close()
    _cleanup(p)


def test_a_writer_sees_another_connections_commit() raises:
    var p = _fresh("other")
    var c = Pair(p)
    var second = open(p)
    second.execute("INSERT INTO seed VALUES (1)")
    assert_true(c.writer_moved(), "another connection's commit did not move the writer's clock")
    assert_true(c.reader_moved())
    second.close()
    c.r.close()
    c.w.close()
    _cleanup(p)


def test_a_clock_moves_with_its_own_snapshot() raises:
    """A connection holding a read open keeps its snapshot and its clock,
    so a rendering and the value it is stamped with cannot disagree when
    both come from one connection."""
    var p = _fresh("snapshot")
    var c = Pair(p)
    c.w.execute("CREATE TABLE t (v TEXT)")
    c.w.execute("INSERT INTO t VALUES ('a')")
    c.w.execute("INSERT INTO t VALUES ('b')")
    _ = c.reader_moved()

    var held = c.r.prepare("SELECT v FROM t ORDER BY rowid")
    assert_true(held.step())
    c.w.execute("INSERT INTO t VALUES ('c')")
    assert_false(c.reader_moved(), "the clock moved under an open read")
    assert_equal(c.r.query_scalar("SELECT count(*) FROM t"), "2")
    held.finalize()
    assert_true(c.reader_moved(), "the clock did not move once the read ended")
    assert_equal(c.r.query_scalar("SELECT count(*) FROM t"), "3")
    c.r.close()
    c.w.close()
    _cleanup(p)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
