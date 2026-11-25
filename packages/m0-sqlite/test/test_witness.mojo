"""The table witness: whether any page of some tables was written (SPEC O32).

One writer (`open`, WAL), one read-only reader standing for a view that
renders, and a `TableWitness` over `notes` (or `notes` and `tags`). Each
round is what a cached view does on a moved clock: `look`, render in a read
transaction, `settle`. The claims are about the answer each look gives for
what the writer did since the last settle.
"""

from std.collections import List
from std.ffi import external_call, c_int
from std.os import remove, mkdir, path
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src import (
    Connection,
    open,
    open_readonly,
    TableWitness,
    UNCHANGED,
    CHANGED,
    UNKNOWN,
    WAL_INDEX_VERSION,
    parse_wal_index_header,
    frame_page,
)


def _dir() -> String:
    return String("/tmp/m0-sqlite-witness-") + String(Int(external_call["getpid", c_int]()))


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


def _name(answer: Int) -> String:
    if answer == UNCHANGED:
        return "UNCHANGED"
    if answer == CHANGED:
        return "CHANGED"
    return "UNKNOWN"


struct Fixture(Movable):
    """A writer, a reader and a witness over one file, past the first look."""

    var w: Connection
    var r: Connection
    var witness: TableWitness

    def __init__(out self, p: String, var tables: List[String]) raises:
        self.w = open(p)
        self.w.execute(
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL);"
            " CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);"
            " CREATE TABLE other (x INTEGER)"
        )
        self.w.execute("BEGIN")
        var ins = self.w.prepare("INSERT INTO notes (title) VALUES (?1)")
        for i in range(200):
            ins.bind_text(1, String("note ", i))
            _ = ins.step()
            ins.reset()
        _ = ins^
        self.w.execute("COMMIT")
        self.w.execute("INSERT INTO other VALUES (0); INSERT INTO tags (name) VALUES ('t')")
        self.r = open_readonly(p)
        self.witness = TableWitness(p, tables^)
        var first = self.witness.look()
        assert_equal(_name(first), "UNKNOWN", "a first look is UNKNOWN")
        self.render()
        self.witness.settle()

    def render(mut self) raises:
        """A rendering's read transaction."""
        self.r.begin()
        _ = self.r.query_scalar("SELECT count(*) FROM notes")
        self.r.commit()

    def round(mut self) raises -> Int:
        """What a cached view does on a moved clock: look, render, settle."""
        var answer = self.witness.look()
        self.render()
        self.witness.settle()
        return answer


def _expect(mut f: Fixture, want: Int, what: String) raises:
    var got = f.round()
    assert_equal(_name(got), _name(want), what + " (last UNKNOWN: " + f.witness.last_unknown() + ")")


def test_a_commit_to_another_table_is_unchanged() raises:
    """Nothing written, or written only to tables the witness does not hold,
    is UNCHANGED: the kept rendering stands with no SQL.

    covers: O32
    """
    var p = _fresh("other")
    var f = Fixture(p, ["notes"])
    _expect(f, UNCHANGED, "nothing was written")
    f.w.execute("INSERT INTO other VALUES (1)")
    _expect(f, UNCHANGED, "an insert into another table")
    f.w.execute("UPDATE other SET x = 2")
    _expect(f, UNCHANGED, "an update of another table")
    f.w.execute("UPDATE tags SET name = 'u'")
    _expect(f, UNCHANGED, "an update of a table not watched")
    _ = f^
    _cleanup(p)


def test_the_tables_own_writes_are_never_unchanged() raises:
    """An update of a row is CHANGED; an insert and a delete are CHANGED or,
    when they move a page between owners, UNKNOWN. Never UNCHANGED.

    covers: O32
    """
    var p = _fresh("own")
    var f = Fixture(p, ["notes"])
    f.w.execute("UPDATE notes SET title = 'changed' WHERE id = 7")
    _expect(f, CHANGED, "an update of a watched row")
    f.w.execute("DELETE FROM notes WHERE id = 8")
    assert_true(f.round() != UNCHANGED, "a delete was UNCHANGED")
    f.w.execute("INSERT INTO notes (title) VALUES ('new')")
    assert_true(f.round() != UNCHANGED, "an insert was UNCHANGED")
    f.w.execute("BEGIN; UPDATE notes SET title = 'a' WHERE id = 1; INSERT INTO other VALUES (9); COMMIT")
    _expect(f, CHANGED, "one transaction writing a watched table and another")
    _ = f^
    _cleanup(p)


def test_what_moves_pages_between_owners_is_unknown() raises:
    """Growth, a schema change and VACUUM write page 1, where a page changes
    hands; a finished checkpoint lets the next writer reset the log. Each is
    UNKNOWN, maps the pages again, and the look after it stands on the new map.

    covers: O32
    """
    var p = _fresh("owners")
    var f = Fixture(p, ["notes"])
    f.w.execute("BEGIN")
    var ins = f.w.prepare("INSERT INTO other VALUES (?1)")
    for i in range(2000):
        ins.bind_int(1, i)
        _ = ins.step()
        ins.reset()
    _ = ins^
    f.w.execute("COMMIT")
    _expect(f, UNKNOWN, "growth of another table")
    assert_true("page 1" in f.witness.last_unknown(), "growth: " + f.witness.last_unknown())
    _expect(f, UNCHANGED, "nothing after the remap")

    f.w.execute("CREATE TABLE later (a INTEGER)")
    _expect(f, UNKNOWN, "a schema change")
    _expect(f, UNCHANGED, "nothing after the schema change")

    _ = f.w.query_scalar("PRAGMA wal_checkpoint(TRUNCATE)")
    f.w.execute("UPDATE other SET x = 7 WHERE rowid = 1")
    _expect(f, UNKNOWN, "a write after a truncating checkpoint")
    assert_true("reset" in f.witness.last_unknown(), "the reset: " + f.witness.last_unknown())
    f.w.execute("UPDATE notes SET title = 'after the reset' WHERE id = 2")
    _expect(f, CHANGED, "a watched update in the new log")

    f.w.execute("VACUUM")
    _expect(f, UNKNOWN, "VACUUM")
    f.w.execute("UPDATE notes SET title = 'after vacuum' WHERE id = 3")
    _expect(f, CHANGED, "a watched update after VACUUM, on the new map")
    _ = f^
    _cleanup(p)


def test_a_commit_the_rendering_does_not_hold_is_looked_at_next() raises:
    """The order: `look` reads the log's position before the read transaction,
    and `settle` takes THAT position, never a later one.

    A commit between the look and the read is in the rendering, and the next
    look says CHANGED anyway: one rendering too many, never one too few. A
    commit after the rendering's snapshot is not in it, and the next look
    must say CHANGED. A `settle` that read the position afresh would cover
    that commit, and the kept rendering would lack it until the table
    changed again.

    covers: O32
    """
    var p = _fresh("order")
    var f = Fixture(p, ["notes"])
    _expect(f, UNCHANGED, "nothing was written")

    # Between the look and the read transaction.
    var answer = f.witness.look()
    assert_equal(_name(answer), "UNCHANGED", "the look before the commit")
    f.w.execute("UPDATE notes SET title = 'between' WHERE id = 3")
    f.render()
    f.witness.settle()
    _expect(f, CHANGED, "a commit made after look() and before the read")

    # After the rendering's snapshot, before settle.
    answer = f.witness.look()
    assert_equal(_name(answer), "UNCHANGED", "the look before the second commit")
    f.r.begin()
    var seen = f.r.query_scalar("SELECT title FROM notes WHERE id = 4")
    f.w.execute("UPDATE notes SET title = 'after the snapshot' WHERE id = 4")
    var still = f.r.query_scalar("SELECT title FROM notes WHERE id = 4")
    f.r.commit()
    assert_equal(still, seen, "the rendering's snapshot held still")
    f.witness.settle()
    _expect(f, CHANGED, "a commit the rendering did not hold")
    _ = f^
    _cleanup(p)


def test_two_tables_are_watched_together() raises:
    """A witness over several tables answers for any of them.

    covers: O32
    """
    var p = _fresh("two")
    var tables: List[String] = ["notes", "tags"]
    var f = Fixture(p, tables^)
    f.w.execute("UPDATE tags SET name = 'v'")
    _expect(f, CHANGED, "an update of the second table")
    f.w.execute("UPDATE other SET x = 5")
    _expect(f, UNCHANGED, "an update of neither")
    f.w.execute("UPDATE notes SET title = 'n' WHERE id = 5")
    _expect(f, CHANGED, "an update of the first table")
    _ = f^
    _cleanup(p)


def test_the_witness_keeps_its_files_when_every_other_connection_closes() raises:
    """SQLite deletes `-wal` and `-shm` at the last close. The witness's own
    connection is never that one, so the files it reads stay the database's.

    covers: O32
    """
    var p = _fresh("files")
    var f = Fixture(p, ["notes"])
    f.w.close()
    f.r.close()
    assert_true(path.exists(p + "-wal"), "-wal deleted under the witness")
    assert_true(path.exists(p + "-shm"), "-shm deleted under the witness")
    var w2 = open(p)
    w2.execute("UPDATE notes SET title = 'later' WHERE id = 1")
    assert_equal(_name(f.witness.look()), "CHANGED", "a write by a connection opened later")
    w2.close()
    _ = f^
    _cleanup(p)


def test_a_database_without_a_wal_index_is_unknown() raises:
    """A rollback-journal database has no `-shm`: every look is UNKNOWN,
    which renders every time, as the clock alone would.

    covers: O32
    """
    var p = _fresh("journal")
    var w = open(p)
    w.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT)")
    _ = w.query_scalar("PRAGMA journal_mode = DELETE")
    var witness = TableWitness(p, ["notes"])
    assert_equal(_name(witness.look()), "UNKNOWN", "a first look")
    assert_true("-shm" in witness.last_unknown(), "the reason: " + witness.last_unknown())
    witness.settle()
    w.execute("INSERT INTO notes (title) VALUES ('x')")
    assert_equal(_name(witness.look()), "UNKNOWN", "a later look")
    witness.settle()
    w.close()
    _ = witness^
    _cleanup(p)


def test_a_table_is_named_as_sqlite_names_it() raises:
    """A name is matched without regard to case, as SQLite matches it, so
    `"Notes"` watches `notes`. `dbstat` matches names exactly, and a name left
    as given would map no pages and answer UNCHANGED for every write. A name
    no table answers to is UNKNOWN at every look, naming itself.

    covers: O32
    """
    var p = _fresh("names")
    var f = Fixture(p, ["Notes"])
    f.w.execute("UPDATE notes SET title = 'by another case' WHERE id = 6")
    _expect(f, CHANGED, "a write to notes, watched as Notes")
    var lost = TableWitness(p, ["nope"])
    _ = lost.look()
    lost.settle()
    f.w.execute("UPDATE notes SET title = 'unseen' WHERE id = 7")
    assert_equal(_name(lost.look()), "UNKNOWN", "a witness over a table that is not there")
    assert_true("nope" in lost.last_unknown(), "the reason does not name the table: " + lost.last_unknown())
    lost.settle()
    assert_equal(_name(lost.look()), "UNKNOWN", "a later look over a table that is not there")
    _ = lost^
    _ = f^
    _cleanup(p)


def test_a_table_with_no_pages_is_no_map() raises:
    """A virtual table is a table with no b-tree of its own, so `dbstat` lists
    no pages under its name. A map of nothing would answer UNCHANGED for every
    write, so the witness answers UNKNOWN.

    covers: O32
    """
    var p = _fresh("virtual")
    var f = Fixture(p, ["notes"])
    f.w.execute("CREATE VIRTUAL TABLE spatial USING rtree(id, x0, x1)")
    var w = TableWitness(p, ["spatial"])
    _ = w.look()
    w.settle()
    f.w.execute("INSERT INTO spatial VALUES (1, 0.0, 1.0)")
    assert_equal(_name(w.look()), "UNKNOWN", "a write to a virtual table")
    assert_true("no pages" in w.last_unknown(), "the reason: " + w.last_unknown())
    _ = w^
    _ = f^
    _cleanup(p)


def test_a_value_rewritten_in_its_overflow_pages_is_changed() raises:
    """A row too large for its page keeps the rest in overflow pages, which are
    the table's too. A same-size rewrite of a large value writes only those
    pages, leaving the row's leaf as it was, and is CHANGED.

    covers: O32
    """
    var p = _fresh("overflow")
    var f = Fixture(p, ["notes"])
    var big = String()
    for _ in range(4000):
        big += "abcdefghij"
    f.w.execute("UPDATE notes SET title = '" + big + "' WHERE id = 10")
    _ = f.round()
    var other = String()
    for _ in range(4000):
        other += "jihgfedcba"
    f.w.execute("UPDATE notes SET title = '" + other + "' WHERE id = 10")
    _expect(f, CHANGED, "a same-size rewrite of a value in overflow pages")
    _ = f^
    _cleanup(p)


def _header(version: Int, init: Int, size: Int, max_frame: Int, salt: List[UInt8]) -> List[UInt8]:
    var h = List[UInt8](length=96, fill=0)
    for i in range(4):
        h[i] = UInt8((version >> (8 * i)) & 0xFF)
    h[12] = UInt8(init)
    h[14] = UInt8(size & 0xFF)
    h[15] = UInt8((size >> 8) & 0xFF)
    for i in range(4):
        h[16 + i] = UInt8((max_frame >> (8 * i)) & 0xFF)
    for i in range(8):
        h[32 + i] = salt[i]
    for i in range(48):
        h[48 + i] = h[i]
    return h^


def test_the_wal_index_header_is_read_as_sqlite_writes_it() raises:
    """SQLite's walformat.html §2.1: two 48-byte copies, native-endian fields, the
    salts the WAL header's own bytes. Copies that disagree are a write in
    progress; another version, or an index not yet initialized, is a header
    this does not read.

    covers: O32
    """
    var salt: List[UInt8] = [0xF6, 0x49, 0x53, 0xA8, 0x23, 0x57, 0x9C, 0xC4]
    var h = _header(WAL_INDEX_VERSION, 1, 4096, 27, salt)
    var p = parse_wal_index_header(Span(h))
    assert_equal(p.state, 0)
    assert_equal(p.max_frame, 27)
    assert_equal(p.page_size, 4096)

    var big = _header(WAL_INDEX_VERSION, 1, 1, 3, salt)
    assert_equal(parse_wal_index_header(Span(big)).page_size, 65536, "a size of 1 is 64 KiB")

    var torn = _header(WAL_INDEX_VERSION, 1, 4096, 27, salt)
    torn[48 + 16] = 28
    assert_equal(parse_wal_index_header(Span(torn)).state, 1, "copies that disagree")

    var other = _header(WAL_INDEX_VERSION + 1, 1, 4096, 27, salt)
    assert_equal(parse_wal_index_header(Span(other)).state, 2, "another wal-index version")
    var uninit = _header(WAL_INDEX_VERSION, 0, 4096, 27, salt)
    assert_equal(parse_wal_index_header(Span(uninit)).state, 2, "an index not initialized")
    var short = List[UInt8](length=40, fill=0)
    assert_equal(parse_wal_index_header(Span(short)).state, 2, "a short header")

    # A frame header: page number big-endian, then the commit size, then the
    # salts as the WAL header has them.
    var frame = List[UInt8](length=24, fill=0)
    frame[2] = 0x01
    frame[3] = 0x02
    for i in range(8):
        frame[8 + i] = salt[i]
    assert_equal(frame_page(Span(frame), p.salt), 258)
    frame[8] = 0x00
    assert_equal(frame_page(Span(frame), p.salt), -1, "a frame of another generation")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
