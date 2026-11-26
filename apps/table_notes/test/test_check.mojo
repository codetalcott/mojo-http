"""The table notes app's check: a write no stamp saw starts every client
over (SPEC N57, DECISIONS D72).

A failure of the check is the quiet kind: a client keeps a title the table
no longer has, and nothing says so. So each test here is one that
`scripts/checked_page_sabotage.py` breaks the rule for and insists fails.
The states are built as the host builds them, `Notes(path, worker,
capacity)`, and driven through the methods the views call. A write no
trigger sees is made the way it leaves the file: the write, with the copy's
and the stamps' rows for it put back as they were, in one transaction, and
no schema change, which the check answers on its own. A restore is made by
CPython's backup API, in another process.

Run with `uv run poe test-apps`.
"""

from std.ffi import c_int, external_call
from std.os import mkdir, path, remove
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from m0_sqlite import Connection, open, raise_floor, stamp_floor, stamp_head
from table_notes.server import Notes, Seen, _changes, delta_frames


def _dir() -> String:
    return String("/tmp/m0-table-notes-check-") + String(Int(external_call["getpid", c_int]()))


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


def _seed(p: String, rows: Int) raises:
    var db = open(p)
    db.begin_immediate()
    for i in range(rows):
        var q = db.prepare("INSERT INTO notes (title) VALUES (?1)")
        q.bind_text(1, String("t-", i))
        _ = q.step()
        q.finalize()
    db.commit()


def _head(p: String) raises -> Int:
    var db = open(p)
    return stamp_head(db)


def _floor(p: String) raises -> Int:
    var db = open(p)
    return stamp_floor(db)


def _copy(p: String, id: Int) raises -> String:
    var db = open(p)
    var q = db.prepare("SELECT title FROM notes_seen WHERE id = ?1")
    q.bind_int(1, id)
    if not q.step():
        return String("<none>")
    return q.column_text(0)


def _bypass(p: String, sql: String, id: Int) raises:
    """Run `sql`, a write to row `id`, and leave the file as a connection
    with triggers turned off would: the copy's row and the stamps' rows for
    `id` are put back as they were, in the same transaction. Saved in TEMP
    tables, so the schema version does not move."""
    var db = open(p)
    db.execute("CREATE TEMP TABLE was_seen AS SELECT * FROM notes_seen WHERE 0")
    db.execute("CREATE TEMP TABLE was_changes AS SELECT * FROM m0_changes WHERE 0")
    db.execute("CREATE TEMP TABLE was_stamp AS SELECT * FROM m0_stamp WHERE 0")
    db.begin_immediate()
    db.execute(String(
        "INSERT INTO was_seen SELECT * FROM notes_seen WHERE id = ", id, ";",
        "INSERT INTO was_changes SELECT * FROM m0_changes WHERE tbl = 'notes' AND row = ", id, ";",
        "INSERT INTO was_stamp SELECT * FROM m0_stamp;",
    ))
    db.execute(sql)
    assert_true(db.changes() > 0, "the bypass wrote no row")
    db.execute(String(
        "DELETE FROM notes_seen WHERE id = ", id, ";",
        "INSERT INTO notes_seen SELECT * FROM was_seen;",
        "DELETE FROM m0_changes WHERE tbl = 'notes' AND row = ", id, ";",
        "INSERT INTO m0_changes SELECT * FROM was_changes;",
        "UPDATE m0_stamp SET seq = (SELECT seq FROM was_stamp),",
        " floor = (SELECT floor FROM was_stamp) WHERE id = 0;",
    ))
    db.commit()


def _retitle(p: String, id: Int, title: String) raises:
    _bypass(p, String("UPDATE notes SET title = '", title, "' WHERE id = ", id), id)


def _schema(p: String) raises -> Int:
    var db = open(p)
    var q = db.prepare("PRAGMA schema_version")
    _ = q.step()
    return q.column_int(0)


def _python(script: String, arg: String) -> Int:
    """`python3 -I -c script arg` by `system(3)`, never a fork: a child
    forked beside open connections inherits SQLite's lock tables for the
    file. Answers its exit status."""
    var cmd = String('python3 -I -c "', script, '" \'', arg, "'")
    var bytes = cmd.as_bytes()
    var buf = List[UInt8](capacity=len(bytes) + 1)
    for i in range(len(bytes)):
        buf.append(bytes[i])
    buf.append(0)
    var status = Int(external_call["system", c_int](buf.unsafe_ptr()))
    _ = buf
    return (status >> 8) & 0xFF


def _page_head(page: String) raises -> Int:
    """The stamp a page's script opens the feed from."""
    var at = page.find("?since=")
    assert_true(at >= 0, "the page carries no feed")
    var digits = String("")
    var b = page.as_bytes()
    var i = at + 7
    while i < len(b) and Int(b[i]) >= 48 and Int(b[i]) <= 57:
        digits += chr(Int(b[i]))
        i += 1
    return atol(digits)


def test_a_write_no_stamp_saw_raises_the_floor_over_every_client() raises:
    """A title changed with the triggers out of the way is found, and every
    client below the new floor is told to start over, by both routes.

    covers: N57
    """
    var p = _fresh("bypass")
    var n = Notes(p, 0, 64)
    _seed(p, 120)
    _ = n.first_page()
    var client = _head(p)
    _retitle(p, 5, "seen by no stamp")
    assert_equal(_head(p), client, "the bypass was stamped: the test proves nothing")
    assert_equal(_copy(p, 5), "t-4", "the bypass reached the copy: the test proves nothing")
    assert_equal(n.restores, 0)
    var page = n.first_page()
    assert_true("seen by no stamp" in page)
    assert_equal(n.mismatches, 1)
    assert_equal(n.raises, 2)
    assert_true(_floor(p) > client, "a client holding the old title is not below the floor")
    var r = open(p)
    r.begin()
    var answer = _changes(r, client)
    var to = client
    var event = delta_frames(r, client, to)
    r.commit()
    assert_true('"reset":true' in answer, answer)
    assert_true("event: resync" in event, event)
    _cleanup(p)


def test_stamped_writes_never_raise() raises:
    """Updates, inserts, deletes on the page, a key that moves and a bulk
    delete of 60 rows of the window: the copy moves with each, in its own
    transaction, so none is a difference.

    covers: N57
    """
    var p = _fresh("stamped")
    var n = Notes(p, 0, 64)
    _seed(p, 250)
    _ = n.first_page()
    var w = open(p)
    w.execute("DELETE FROM notes WHERE id IN (3, 7)")
    w.execute("UPDATE notes SET title = 'edited' WHERE id = 5")
    w.execute("INSERT INTO notes (title) VALUES ('new 1'), ('new 2')")
    w.execute("UPDATE notes SET id = 9000 WHERE id = 9")
    var page = n.first_page()
    assert_true("edited" in page and 'id="n3"' not in page and 'id="n9"' not in page)
    w.execute("DELETE FROM notes WHERE id BETWEEN 10 AND 69")
    _ = n.first_page()
    assert_equal(n.checks, 3, "the page was not checked each time: the test proves nothing")
    assert_equal(n.mismatches, 0)
    assert_equal(n.raises, 1, "a stamped write raised the floor")
    _cleanup(p)


def test_any_state_finds_a_bypass_a_state_it_never_was_served() raises:
    """The review's case (2026-11-26). State a serves a page after a
    stamped write; a write no stamp saw follows. State b, which kept
    nothing after the stamped write and served nobody, must find it: with a
    kept window it applied the stamp with the row's title now, the
    bypass's, and found nothing, while a never answered again.

    covers: N57
    """
    var p = _fresh("served")
    var a = Notes(p, 0, 64)
    var b = Notes(p, 1, 64)
    _seed(p, 120)
    _ = a.first_page()
    b.refresh()
    var w = open(p)
    w.execute("UPDATE notes SET title = 'stamped' WHERE id = 5")
    var page = a.first_page()
    assert_true(">stamped</a>" in page, "a did not serve the stamped title: the test proves nothing")
    var client = _page_head(page)
    _retitle(p, 5, "bypassed")
    b.refresh()
    assert_equal(b.mismatches, 1, "a state that served nobody did not find the bypass")
    assert_true(_floor(p) > client)
    _cleanup(p)


def test_a_raise_sets_the_copies_to_what_the_check_saw() raises:
    """After a raise the copy holds what was seen, so the next check finds
    nothing; a second bypass to the same row is a new difference.

    covers: N57
    """
    var p = _fresh("copies")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    _retitle(p, 5, "one")
    _ = n.first_page()
    assert_equal(n.mismatches, 1)
    assert_equal(_copy(p, 5), "one")
    var w = open(p)
    w.execute("UPDATE notes SET title = 'unrelated' WHERE id = 20")
    _ = n.first_page()
    assert_equal(n.mismatches, 1, "a difference already answered raised the floor again")
    _retitle(p, 5, "two")
    _ = n.first_page()
    assert_equal(n.mismatches, 2)
    _cleanup(p)


def test_a_stamped_write_after_the_check_keeps_its_copy() raises:
    """The copies are set after the raise, in a transaction of their own.
    A stamped write in between made the copy agree with its row, and is
    left alone: the copy is set only where it is still what the check read.

    covers: N57
    """
    var p = _fresh("between")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    _retitle(p, 5, "seen")
    var differ = List[Seen]()
    differ.append(Seen(5, True, String("seen"), True, String("t-4")))
    var w = open(p)
    w.execute("UPDATE notes SET title = 'stamped since' WHERE id = 5")
    n.writer.begin_immediate()
    n._set_copies(differ)
    n.writer.commit()
    assert_equal(_copy(p, 5), "stamped since", "a stamped write's copy was overwritten")
    _cleanup(p)


def test_a_bypass_after_the_check_is_not_taken_into_the_copy() raises:
    """The copy is set to the title the check saw, not to the table's now:
    a second write no stamp saw, between the check and the copy, is still
    a difference afterwards.

    covers: N57
    """
    var p = _fresh("taken")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    _retitle(p, 5, "seen")
    var differ = List[Seen]()
    differ.append(Seen(5, True, String("seen"), True, String("t-4")))
    _retitle(p, 5, "after")
    n.writer.begin_immediate()
    n._set_copies(differ)
    n.writer.commit()
    assert_equal(_copy(p, 5), "seen")
    _ = n.first_page()
    assert_equal(n.mismatches, 1, "the second bypass was taken into the copy")
    _cleanup(p)


def test_a_bypassed_insert_stays_a_difference_after_a_stamped_edit() raises:
    """A row a bypass inserted has no copy, and a stamped edit of it (its
    body) must not make one: the update trigger only updates a copy that
    is there (review, 2026-11-26).

    covers: N57
    """
    var p = _fresh("insert_edit")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    _bypass(p, "INSERT INTO notes (id, title) VALUES (500, 'unstamped')", 500)
    var w = open(p)
    w.execute("UPDATE notes SET body = 'edited' WHERE id = 500")
    assert_equal(_copy(p, 500), "<none>", "the edit made the missing copy")
    _ = n.first_page()
    assert_equal(n.mismatches, 1)
    _cleanup(p)


def test_a_bypassed_delete_stays_a_difference_after_its_id_comes_back() raises:
    """A row a bypass deleted keeps its copy, and a stamped insert under the
    same id must not overwrite it: the insert trigger only makes a copy
    that is missing (review, 2026-11-26).

    covers: N57
    """
    var p = _fresh("delete_back")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    _bypass(p, "DELETE FROM notes WHERE id = 5", 5)
    var w = open(p)
    w.execute("INSERT INTO notes (id, title) VALUES (5, 'back again')")
    assert_equal(_copy(p, 5), "t-4", "the insert overwrote the copy a bypass left")
    _ = n.first_page()
    assert_equal(n.mismatches, 1)
    _cleanup(p)


def test_a_title_stored_as_bytes_is_answered_once() raises:
    """Another program may store a title as a BLOB, and the copy trigger
    copies it as one. After a bypass the copy is set by comparing bytes:
    compared as TEXT it would never match, and every check would raise
    the floor again (review, 2026-11-26).

    covers: N57
    """
    var p = _fresh("bytes")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    var w = open(p)
    w.execute("INSERT INTO notes (id, title) VALUES (300, CAST('bytes' AS BLOB))")
    _ = n.first_page()
    assert_equal(n.mismatches, 0, "a title stored as bytes read as a difference")
    _retitle(p, 300, "retitled")
    _ = n.first_page()
    assert_equal(n.mismatches, 1)
    w.execute("UPDATE notes SET title = 'unrelated' WHERE id = 20")
    _ = n.first_page()
    assert_equal(n.mismatches, 1, "the copy of a title stored as bytes was never set")
    _cleanup(p)


def test_a_live_restore_is_found_after_the_head_climbs_back() raises:
    """A backup restored onto the running file puts rows, copies and counter
    back together, and stamped writes can carry the head past where it
    stood before any thread checks. The schema version, which the backup
    API moves and no stamped write moves back, still says so (review,
    2026-11-26).

    covers: N57
    """
    var p = _fresh("live_restore")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    assert_equal(
        _python("import sqlite3,sys; sqlite3.connect(sys.argv[1]).backup(sqlite3.connect(sys.argv[1] + '.bak'))", p), 0,
        "the backup failed",
    )
    var w = open(p)
    w.execute("UPDATE notes SET title = 'after the backup' WHERE id IN (1, 2, 3)")
    var page = n.first_page()
    assert_true("after the backup" in page)
    var client = _page_head(page)
    var before = _schema(p)
    assert_equal(
        _python("import sqlite3,sys; sqlite3.connect(sys.argv[1] + '.bak').backup(sqlite3.connect(sys.argv[1], timeout=5))", p), 0,
        "the restore failed",
    )
    assert_true(_schema(p) != before, "the restore did not move the schema version: the test proves nothing")
    w.execute("UPDATE notes SET title = 'climbing' WHERE id BETWEEN 30 AND 40")
    assert_true(_head(p) > client, "the head did not climb back past the client: the test proves nothing")
    _ = n.first_page()
    assert_equal(n.restores, 1, "a restore the head climbed back past was missed")
    assert_true(_floor(p) > client)
    _cleanup(p)
    _cleanup(p + ".bak")


def test_a_counter_that_went_back_raises_the_floor() raises:
    """A restore puts the rows, their copies and the counter back together,
    so nothing differs: the head below the highest one this state has read
    is what says so.

    covers: N57
    """
    var p = _fresh("restore")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    var client = _head(p)
    var w = open(p)
    w.execute("UPDATE m0_stamp SET seq = seq - 30 WHERE id = 0")
    _ = n.first_page()
    assert_equal(n.restores, 1)
    assert_true(_floor(p) > client, "a client from before the restore is not below the floor")
    _cleanup(p)


def test_the_feed_and_the_changes_answer_check_first() raises:
    """Both live routes check before they answer, each in its own snapshot.

    covers: N57
    """
    var p = _fresh("routes")
    var a = Notes(p, 0, 64)
    var b = Notes(p, 1, 64)
    _seed(p, 60)
    a.refresh()
    var since = _head(p)
    _ = b.answer_changes(since)
    _retitle(p, 5, "seen by no stamp")
    a.refresh()
    assert_equal(a.mismatches, 1, "the feed's tick did not check")
    _retitle(p, 6, "seen by no stamp either")
    _ = b.answer_changes(_head(p))
    assert_equal(b.mismatches, 1, "/notes/changes did not check")
    _cleanup(p)


def test_a_raise_that_fails_loses_nothing() raises:
    """Another writer holds the lock, so the raise fails and so does the
    answer. Nothing is settled and no copy is set, so the next answer finds
    the same difference and raises.

    covers: N57
    """
    var p = _fresh("busy")
    var n = Notes(p, 0, 64)
    n.writer.busy_timeout(200)
    _seed(p, 60)
    _ = n.first_page()
    var client = _head(p)
    _retitle(p, 5, "seen")
    var holder = open(p)
    holder.begin_immediate()
    var failed = False
    try:
        _ = n.first_page()
    except:
        failed = True
    holder.rollback()
    assert_true(failed, "the raise did not wait on the lock: the test proves nothing")
    assert_equal(n.raises, 1)
    _ = n.first_page()
    assert_equal(n.raises, 2, "a difference found while the lock was held was lost")
    assert_true(_floor(p) > client)
    _cleanup(p)


def test_every_state_raises_the_floor_once_as_it_starts() raises:
    """A restore made while no server ran puts everything back together: a
    state that starts puts every client from before below the floor.

    covers: N57
    """
    var p = _fresh("startup")
    var a = Notes(p, 0, 64)
    assert_equal(a.raises, 1)
    assert_equal(_floor(p), _head(p))
    _seed(p, 10)
    var client = _head(p)
    var b = Notes(p, 1, 64)
    assert_equal(b.raises, 1)
    assert_true(_floor(p) > client)
    _cleanup(p)


def test_a_floor_raised_elsewhere_renders_the_page_again() raises:
    """Another thread's raise moves the head and writes neither table: the
    page is rendered again under the new head, so its feed does not open
    below the floor.

    covers: N57
    """
    var p = _fresh("elsewhere")
    var n = Notes(p, 0, 64)
    _seed(p, 60)
    _ = n.first_page()
    var w = open(p)
    var head = raise_floor(w)
    var page = n.first_page()
    assert_equal(_page_head(page), head, "the kept page still carries a head below the floor")
    assert_equal(n.mismatches, 0)
    _cleanup(p)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
