"""Stamps: what `watch` records, in what order, and what it cannot see.

A writer (`open`) and a read-only connection beside it, as an application
holds them. Each test is one sentence of `stamps.mojo`'s docstring: the
ones under "what holds" are the contract a feed is built on, and the ones
under "what does not" are pinned so that a change in SQLite, or a fix
here, shows up as a failure and not as a surprise.
"""

from std.ffi import external_call, c_int
from std.os import remove, mkdir, path
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src import (
    Connection,
    open,
    open_readonly,
    install_stamps,
    watch,
    watched,
    stamp_head,
    stamp_of,
    stamp_floor,
    prune_stamps,
    cursor,
    advance,
    slowest_cursor,
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
    var dir = String("/tmp/m0-sqlite-stamps-") + String(
        Int(external_call["getpid", c_int]())
    )
    if not path.exists(dir):
        mkdir(dir)
    var p = dir + "/" + name + ".db"
    _cleanup(p)
    return p^


def _watched(p: String) raises -> Connection:
    """A writer over a fresh file with one watched table."""
    var db = open(p)
    db.execute(
        "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT,"
        + " slug TEXT UNIQUE, v INTEGER NOT NULL DEFAULT 0)"
    )
    install_stamps(db)
    watch(db, "notes")
    return db^


def _delta(db: Connection, since: Int) raises -> String:
    """`row:seq:born:gone` for each change of `notes` above `since`, in
    stamp order: the query a feed asks, without the join."""
    var q = db.prepare(
        "SELECT row, seq, born, gone FROM m0_changes"
        + " WHERE tbl = 'notes' AND seq > ?1 ORDER BY seq"
    )
    q.bind_int(1, since)
    var out = String("")
    while q.step():
        if out.byte_length() > 0:
            out += " "
        out += (
            String(q.column_int(0)) + ":" + String(q.column_int(1)) + ":"
            + String(q.column_int(2)) + ":" + String(q.column_int(3))
        )
    return out


def test_every_insert_update_and_delete_is_stamped_in_order() raises:
    """One entry per touched row, holding its last stamp and its birth.

    covers: O26
    """
    var p = _fresh("order")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a'), ('b'), ('c')")
    assert_equal(_delta(db, 0), "1:1:1:0 2:2:2:0 3:3:3:0")
    db.execute("UPDATE notes SET v = 20 WHERE id = 2")
    db.execute("DELETE FROM notes WHERE id = 1")
    # The update moved row 2's stamp and left its birth; the delete left a
    # tombstone. Asked from 3, a client is told of those two and no more.
    assert_equal(_delta(db, 3), "2:4:2:0 1:5:1:1")
    assert_equal(_delta(db, 5), "")
    assert_equal(stamp_head(db), 5)
    assert_equal(stamp_of(db, "notes"), 5)
    assert_equal(stamp_of(db, "elsewhere"), 0)
    # A statement that touches many rows stamps each.
    db.execute("UPDATE notes SET v = v + 1")
    assert_equal(_delta(db, 5), "2:6:2:0 3:7:3:0")
    _cleanup(p)


def test_a_rollback_takes_its_stamps_with_it() raises:
    var p = _fresh("rollback")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    db.begin()
    db.execute("UPDATE notes SET v = 9")
    db.execute("INSERT INTO notes (slug) VALUES ('b')")
    assert_equal(stamp_head(db), 3)
    db.rollback()
    assert_equal(stamp_head(db), 1)
    assert_equal(_delta(db, 0), "1:1:1:0")
    # And the numbers it took are given again: no gap a reader could wait on.
    db.execute("UPDATE notes SET v = 2")
    assert_equal(_delta(db, 1), "1:2:1:0")
    _cleanup(p)


def test_a_reader_beside_the_writer_sees_whole_commits() raises:
    """What a feed relies on: the rows above a stamp, read in one
    statement, are a whole number of transactions."""
    var p = _fresh("snapshot")
    var db = _watched(p)
    var reader = open_readonly(p)
    db.begin()
    db.execute("INSERT INTO notes (slug) VALUES ('a'), ('b')")
    assert_equal(stamp_head(reader), 0)
    assert_equal(_delta(reader, 0), "")
    db.commit()
    assert_equal(stamp_head(reader), 2)
    assert_equal(_delta(reader, 0), "1:1:1:0 2:2:2:0")
    # Inside a read transaction the head and the rows are one snapshot's.
    reader.begin()
    assert_equal(stamp_head(reader), 2)
    db.execute("UPDATE notes SET v = 1 WHERE id = 1")
    assert_equal(stamp_head(reader), 2)
    assert_equal(_delta(reader, 2), "")
    reader.commit()
    assert_equal(_delta(reader, 2), "1:3:1:0")
    _cleanup(p)


def test_born_tells_an_insert_from_an_update() raises:
    """A client at stamp N holds a row iff it was born at or below N."""
    var p = _fresh("born")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    db.execute("INSERT INTO notes (slug) VALUES ('b')")
    db.execute("UPDATE notes SET v = 1")
    # From 1: row 1 is held (born 1) and changed; row 2 is new (born 2).
    assert_equal(_delta(db, 1), "1:3:1:0 2:4:2:0")
    # A rowid moved is a death and a birth.
    db.execute("UPDATE notes SET id = 9 WHERE id = 2")
    assert_equal(_delta(db, 4), "2:5:2:1 9:6:6:0")
    # A rowid given again after its row was deleted is a new row.
    db.execute("DELETE FROM notes WHERE id = 9")
    db.execute("INSERT INTO notes (id, slug) VALUES (9, 'again')")
    assert_equal(_delta(db, 6), "9:8:8:0")
    _cleanup(p)


def test_a_row_older_than_the_watch_is_born_at_zero() raises:
    var p = _fresh("older")
    var db = open(p)
    db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, slug TEXT UNIQUE, v INTEGER DEFAULT 0)")
    db.execute("INSERT INTO notes (slug) VALUES ('old')")
    install_stamps(db)
    assert_false(watched(db, "notes"))
    watch(db, "notes")
    assert_true(watched(db, "notes"))
    # Not in any delta until it is written.
    assert_equal(_delta(db, 0), "")
    db.execute("UPDATE notes SET v = 2")
    assert_equal(_delta(db, 0), "1:1:0:0")
    _cleanup(p)


def test_install_and_watch_are_idempotent() raises:
    var p = _fresh("twice")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    install_stamps(db)
    watch(db, "notes")
    assert_equal(stamp_head(db), 1)
    db.execute("UPDATE notes SET v = 1")
    assert_equal(_delta(db, 1), "1:2:1:0")
    _cleanup(p)


def test_replace_through_a_unique_column_needs_the_writers_pragma() raises:
    """The trap: REPLACE deletes the row that held the unique value, and
    SQLite fires no delete trigger for it unless `recursive_triggers` is
    on for the connection that writes.

    covers: O27
    """
    var p = _fresh("replace")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    db.execute("INSERT OR REPLACE INTO notes (slug, v) VALUES ('a', 5)")
    # Row 1 is gone from the table and no tombstone says so.
    assert_equal(db.query_scalar("SELECT count(*) FROM notes WHERE id = 1"), "0")
    assert_equal(_delta(db, 1), "2:2:2:0")
    # UPDATE OR REPLACE displaces a row the same way.
    db.execute("INSERT INTO notes (slug) VALUES ('b')")
    db.execute("UPDATE OR REPLACE notes SET slug = 'a' WHERE id = 3")
    assert_equal(db.query_scalar("SELECT count(*) FROM notes WHERE id = 2"), "0")
    assert_equal(_delta(db, 2), "3:4:3:0")
    db.execute("PRAGMA recursive_triggers = ON")
    db.execute("INSERT OR REPLACE INTO notes (slug, v) VALUES ('a', 6)")
    assert_equal(_delta(db, 4), "3:5:3:1 4:6:6:0")
    db.execute("INSERT INTO notes (slug) VALUES ('c')")
    db.execute("UPDATE OR REPLACE notes SET slug = 'a' WHERE id = 5")
    assert_equal(_delta(db, 7), "4:8:6:1 5:9:7:0")
    _cleanup(p)


def test_a_writers_conflict_clause_does_not_reach_the_entry() raises:
    """SQLite applies the OR clause of the statement that fires a trigger
    to the statements inside it. The entry is written so that there is
    nothing for it to apply to."""
    var p = _fresh("clauses")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    db.execute("UPDATE OR REPLACE notes SET v = 1 WHERE id = 1")
    db.execute("UPDATE OR IGNORE notes SET v = 2 WHERE id = 1")
    db.execute("UPDATE OR FAIL notes SET v = 3 WHERE id = 1")
    db.execute("UPDATE OR ABORT notes SET v = 4 WHERE id = 1")
    db.execute("UPDATE OR ROLLBACK notes SET v = 5 WHERE id = 1")
    # Five updates, each stamped, and the row is still the one born at 1.
    assert_equal(_delta(db, 1), "1:6:1:0")
    db.execute("INSERT OR FAIL INTO notes (slug) VALUES ('b')")
    db.execute("INSERT OR IGNORE INTO notes (slug) VALUES ('c')")
    db.execute("INSERT OR IGNORE INTO notes (slug) VALUES ('c')")
    db.execute("DELETE FROM notes WHERE id = 2")
    db.execute("INSERT OR ABORT INTO notes (id, slug) VALUES (2, 'again')")
    assert_equal(_delta(db, 6), "3:8:8:0 2:10:10:0")
    _cleanup(p)


def test_a_rebuilt_table_is_no_longer_watched() raises:
    """A migration that copies, drops and renames takes the triggers with
    it and raises nothing; `watched` is how an application finds out."""
    var p = _fresh("rebuilt")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    db.execute(
        "CREATE TABLE n2 (id INTEGER PRIMARY KEY AUTOINCREMENT, slug TEXT UNIQUE,"
        + " v INTEGER NOT NULL DEFAULT 0, w INTEGER);"
        + "INSERT INTO n2 (id, slug, v) SELECT id, slug, v FROM notes;"
        + "DROP TABLE notes; ALTER TABLE n2 RENAME TO notes;"
    )
    assert_false(watched(db, "notes"))
    db.execute("UPDATE notes SET v = 2")
    assert_equal(stamp_head(db), 1)
    watch(db, "notes")
    assert_true(watched(db, "notes"))
    db.execute("UPDATE notes SET v = 3")
    assert_equal(_delta(db, 1), "1:2:1:0")
    _cleanup(p)


def test_an_update_that_changes_nothing_is_stamped() raises:
    var p = _fresh("same")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug, v) VALUES ('a', 1)")
    db.execute("UPDATE notes SET v = 1")
    assert_equal(_delta(db, 1), "1:2:1:0")
    # An UPDATE that matches no row is not.
    db.execute("UPDATE notes SET v = 1 WHERE id = 99")
    assert_equal(stamp_head(db), 2)
    _cleanup(p)


def test_pruning_forgets_tombstones_and_never_a_stamp() raises:
    var p = _fresh("prune")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a'), ('b'), ('c')")
    db.execute("DELETE FROM notes WHERE id = 1")
    db.execute("DELETE FROM notes WHERE id = 3")
    assert_equal(stamp_head(db), 5)
    assert_equal(stamp_floor(db), 0)
    assert_equal(prune_stamps(db, 4), 1)
    assert_equal(stamp_floor(db), 4)
    # The tombstone above the floor stays; the live row keeps its entry.
    assert_equal(_delta(db, 0), "2:2:2:0 3:5:3:1")
    assert_equal(prune_stamps(db, 5), 1)
    # The table's own clock went back with its last tombstone: it is
    # compared for equality. The counter did not, so no stamp is reused.
    assert_equal(stamp_of(db, "notes"), 2)
    assert_equal(stamp_head(db), 5)
    db.execute("INSERT INTO notes (slug) VALUES ('d')")
    assert_equal(stamp_head(db), 6)
    # A floor never goes down, and never passes the head: a floor above
    # it would tell every client to start over until the counter caught up.
    assert_equal(prune_stamps(db, 1), 0)
    assert_equal(stamp_floor(db), 5)
    assert_equal(prune_stamps(db, 1000), 0)
    assert_equal(stamp_floor(db), 6)
    _cleanup(p)


def test_pruning_is_a_transaction_of_its_own() raises:
    var p = _fresh("prune_txn")
    var db = _watched(p)
    db.begin()
    var refused = False
    try:
        _ = prune_stamps(db, 1)
    except:
        refused = True
    assert_true(refused, "prune_stamps ran inside a transaction")
    db.rollback()
    # A prune that raises leaves no transaction open behind it.
    var bare = open(_fresh("prune_bare"))
    refused = False
    try:
        _ = prune_stamps(bare, 1)
    except:
        refused = True
    assert_true(refused)
    assert_false(bare.in_transaction())
    _cleanup(p)


def test_watch_refuses_what_it_cannot_name_rows_in() raises:
    """A refusal, where watching would stamp the wrong row or fail every
    write: `new.rowid` is resolved when a trigger FIRES, so a WITHOUT
    ROWID table watched by rowid would refuse every later INSERT, from
    every program."""
    var p = _fresh("refused")
    var db = _watched(p)
    db.execute("CREATE TABLE loose (k TEXT, v TEXT)")
    db.execute("CREATE TABLE keyed (k TEXT PRIMARY KEY, v TEXT)")
    db.execute("CREATE TABLE pair (a INTEGER, b INTEGER, PRIMARY KEY (a, b))")
    db.execute("CREATE TABLE norowid (id INTEGER PRIMARY KEY, v TEXT) WITHOUT ROWID")
    # Not a rowid alias: a quirk SQLite keeps for compatibility.
    db.execute("CREATE TABLE descending (id INTEGER PRIMARY KEY DESC, v TEXT)")
    db.execute("CREATE TABLE inty (id INT PRIMARY KEY, v TEXT)")
    db.execute("CREATE VIEW seen AS SELECT * FROM notes")
    var names = [
        "notes; DROP TABLE notes", "no such", "", "9lives", "missing",
        "loose", "keyed", "pair", "norowid", "descending", "inty", "seen",
        "m0_stamp", "m0_changes", "sqlite_master",
    ]
    for name in names:
        var refused = False
        try:
            watch(db, name)
        except:
            refused = True
        assert_true(refused, "watch accepted: " + name)
        assert_false(watched(db, name))
    assert_equal(db.query_scalar("SELECT count(*) FROM notes"), "0")
    # Refused, so still writable.
    db.execute("INSERT INTO norowid VALUES (1, 'x')")
    _cleanup(p)


def test_a_table_is_filed_under_the_name_the_schema_spells() raises:
    """SQLite matches names without regard to case; a stamp is filed
    under one spelling, whichever the caller used."""
    var p = _fresh("names")
    var db = _watched(p)
    watch(db, "NOTES")
    assert_true(watched(db, "Notes"))
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    assert_equal(stamp_head(db), 1)
    assert_equal(stamp_of(db, "notes"), 1)
    assert_equal(db.query_scalar("SELECT group_concat(DISTINCT tbl) FROM m0_changes"), "notes")
    # A keyword is a name like any other, and a column called `rowid`
    # is not the row's name: the key is used by its own.
    db.execute('CREATE TABLE "order" (id INTEGER PRIMARY KEY, rowid TEXT)')
    watch(db, "order")
    db.execute("INSERT INTO \"order\" (id, rowid) VALUES (7, 'x')")
    db.execute("DELETE FROM \"order\"")
    assert_equal(
        db.query_scalar("SELECT row || ':' || gone FROM m0_changes WHERE tbl = 'order'"),
        "7:1",
    )
    # A key declared at the table's end, descending, IS the rowid.
    db.execute("CREATE TABLE late (v TEXT, id INTEGER, PRIMARY KEY (id DESC))")
    watch(db, "late")
    db.execute("INSERT INTO late (id) VALUES (40)")
    assert_equal(db.query_scalar("SELECT row FROM m0_changes WHERE tbl = 'late'"), "40")
    _cleanup(p)


def test_two_watched_tables_share_one_sequence() raises:
    """One counter for the database, so one number places a client among
    the changes of every table it follows."""
    var p = _fresh("two")
    var db = _watched(p)
    db.execute("CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT)")
    watch(db, "tags")
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    db.execute("INSERT INTO tags (name) VALUES ('x')")
    db.execute("UPDATE notes SET v = 1")
    assert_equal(stamp_head(db), 3)
    assert_equal(stamp_of(db, "notes"), 3)
    assert_equal(stamp_of(db, "tags"), 2)
    assert_equal(
        db.query_scalar("SELECT group_concat(tbl || row || '@' || seq, ' ') FROM (SELECT * FROM m0_changes ORDER BY seq)"),
        "tags1@2 notes1@3",
    )
    _cleanup(p)


def test_a_stage_keeps_its_place_with_its_outputs() raises:
    """A stage's cursor is written in the transaction that writes what
    it derived, so the two hold or fail together.

    covers: O28
    """
    var p = _fresh("cursor")
    var db = _watched(p)
    db.execute("CREATE TABLE lengths (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)")
    assert_equal(cursor(db, "lengths"), 0)
    db.execute("INSERT INTO notes (slug) VALUES ('ab'), ('cde')")
    # The stage: rows above its place, outputs and place in one transaction.
    db.begin_immediate()
    db.execute(
        "INSERT INTO lengths SELECT n.id, length(n.slug) FROM m0_changes c"
        " JOIN notes n ON n.id = c.row WHERE c.tbl = 'notes' AND c.seq > 0"
    )
    advance(db, "lengths", 2)
    db.commit()
    assert_equal(cursor(db, "lengths"), 2)
    assert_equal(db.query_scalar("SELECT sum(n) FROM lengths"), "5")
    # A stage that fails after its outputs loses its place with them.
    db.execute("UPDATE notes SET slug = 'abcd' WHERE id = 1")
    db.begin_immediate()
    db.execute("UPDATE lengths SET n = 4 WHERE id = 1")
    advance(db, "lengths", 3)
    db.rollback()
    assert_equal(cursor(db, "lengths"), 2)
    assert_equal(db.query_scalar("SELECT n FROM lengths WHERE id = 1"), "2")
    # Lag is a query.
    assert_equal(
        db.query_scalar("SELECT (SELECT seq FROM m0_stamp) - seq FROM m0_cursors WHERE name = 'lengths'"),
        "1",
    )
    # A reader beside the writer sees the place and the outputs move at once.
    var reader = open_readonly(p)
    var both = "SELECT (SELECT seq FROM m0_cursors WHERE name = 'lengths') || ':' || (SELECT n FROM lengths WHERE id = 1)"
    db.begin_immediate()
    db.execute("UPDATE lengths SET n = 4 WHERE id = 1")
    advance(db, "lengths", 3)
    assert_equal(reader.query_scalar(both), "2:2")
    db.commit()
    assert_equal(reader.query_scalar(both), "3:4")
    _cleanup(p)


def test_a_cursor_does_not_go_back_or_past_the_head() raises:
    var p = _fresh("cursor_back")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a'), ('b'), ('c'), ('d'), ('e')")
    advance(db, "s", 0)
    advance(db, "s", 5)
    advance(db, "s", 5)
    for bad in [4, 6, -1]:
        var refused = False
        try:
            advance(db, "s", bad)
        except:
            refused = True
        assert_true(refused, "advance took " + String(bad))
    assert_equal(cursor(db, "s"), 5)
    # The check is in the statement that writes: a second writer on the
    # same name that got ahead in between is not undone. Two connections
    # in autocommit, where a check-then-write would have a window.
    var other = open(p)
    advance(other, "s", 5)
    db.execute("INSERT INTO notes (slug) VALUES ('f'), ('g')")
    advance(other, "s", 7)
    var refused = False
    try:
        advance(db, "s", 6)
    except:
        refused = True
    assert_true(refused)
    assert_equal(cursor(db, "s"), 7)
    # Starting over is deleting the row.
    db.execute("DELETE FROM m0_cursors WHERE name = 's'")
    assert_equal(cursor(db, "s"), 0)
    _cleanup(p)


def test_the_slowest_cursor_is_the_safe_prune_point() raises:
    var p = _fresh("slowest")
    var db = _watched(p)
    db.execute("INSERT INTO notes (slug) VALUES ('a'), ('b'), ('c')")
    db.execute("DELETE FROM notes WHERE id = 1")
    db.execute("DELETE FROM notes WHERE id = 2")
    # No stage: the head, and everything may go.
    assert_equal(slowest_cursor(db), 5)
    advance(db, "quick", 5)
    advance(db, "slow", 3)
    assert_equal(slowest_cursor(db), 3)
    # Pruning there keeps the tombstone the slow stage has not seen.
    assert_equal(prune_stamps(db, slowest_cursor(db)), 0)
    db.execute("DELETE FROM notes WHERE id = 3")
    advance(db, "slow", 6)
    assert_equal(slowest_cursor(db), 5)
    assert_equal(prune_stamps(db, slowest_cursor(db)), 2)
    assert_equal(_delta(db, 0), "3:6:3:1")
    _cleanup(p)


def test_a_file_installed_before_cursors_gains_them() raises:
    var p = _fresh("older_install")
    var db = _watched(p)
    db.execute("DROP TABLE m0_cursors")
    install_stamps(db)
    db.execute("INSERT INTO notes (slug) VALUES ('a')")
    advance(db, "s", 1)
    assert_equal(cursor(db, "s"), 1)
    _cleanup(p)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
