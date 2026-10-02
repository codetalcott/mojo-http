"""Stamps: the database remembers which rows changed, and in what order.

A change clock (`Connection.data_version`) says THAT something was
committed. A stamp says WHAT: `watch(db, "notes")` puts four triggers on
the table, and from then on every row inserted, updated or deleted there
has one row in `m0_changes` holding the number of its last change.

    install_stamps(db)
    watch(db, "notes")
    ...
    var q = reader.prepare(
        "SELECT c.row, c.seq, c.born, c.gone, n.title FROM m0_changes c"
        " LEFT JOIN notes n ON n.id = c.row"
        " WHERE c.tbl = 'notes' AND c.seq > ?1 ORDER BY c.seq"
    )

That query is the whole of a change feed's memory. Whoever asks it keeps
one number, the highest `seq` it was answered, and asks again from there:
a page, a process that derives something from the table, a client that
reconnects. Nothing in the server holds a copy of a row to compare with.

The two tables are a contract, since a program that is not Mojo reads
them with SQL:

    m0_changes(tbl, row, seq, born, gone)   PRIMARY KEY (tbl, row)
        seq    the stamp of the row's last change
        born   the stamp of the insert that made it; 0 for a row that was
               there before the watch
        gone   1 once it is deleted (a tombstone, until pruned)
    m0_stamp(id = 0, seq, floor)
        seq    the last stamp given: where a client with everything stands
        floor  tombstones at or below it were pruned
    m0_cursors(name, seq)
        seq    the last stamp a named stage has acted on

A stage -- a process or a thread that derives something from a table --
keeps its place in `m0_cursors` when its work is costly to repeat, so a
restart begins where it stopped: `advance` is written in the same
transaction as the stage's outputs, and so holds exactly when they do.
Its lag is a query, `(SELECT seq FROM m0_stamp) - seq`, and the slowest
cursor is the stamp pruning may reach without stranding a stage.

What holds, each pinned by `test_stamps.mojo` (and the last by the wire
gate of `apps/table_notes`, whose other program is CPython's SQLite):

- **Stamps are given in commit order and a rollback takes its stamps with
  it.** The counter is a row of the database, and SQLite has one writer.
- **One statement sees whole commits.** A reader that takes the changes
  above a stamp in one statement, or inside one read transaction, has a
  whole number of transactions. Its new stamp is the highest `seq` it
  read; `stamp_head` asked separately belongs to a later snapshot.
- **`born` tells an insert from an update without state.** A client at
  stamp N holds a row iff `born <= N` -- provided N is the head of a
  snapshot it has all of. So what is above a stamp is sent whole or not
  at all: cut at a stamp in the middle, a row born below the cut and
  changed above it is taken for one the client holds.
- **An update that moves the key is a death and a birth.**
- **A trigger fires for every program.** A write by another process, in
  another language, is stamped like this one's.

What does not, and is as deliberate (DECISIONS D63):

- **REPLACE deletes without a tombstone** when it displaces a row through
  a UNIQUE column (`INSERT OR REPLACE`, `UPDATE OR REPLACE`), unless the
  WRITING connection has `PRAGMA recursive_triggers = ON`: SQLite fires
  no delete trigger for it otherwise. A writer that uses REPLACE sets the
  pragma, in every program.
- **A table rebuilt by a migration (copy, drop, rename) loses its
  triggers** with no error. `watched` says so; ask it at startup and when
  `PRAGMA schema_version` moves.
- **An update that changes nothing is stamped.** A trigger cannot say "no
  column differs" without naming the columns. A program that recomputes
  more than changed compares before it writes.
- **A row that was there before the watch has no entry** until it is
  written. It is not in any delta, and is `born` 0 when it first appears:
  the changes above 0 are the whole table only for one watched from its
  first row.
- **Only a table whose key is the rowid** is watched: one column declared
  `INTEGER PRIMARY KEY`, in a table that is not WITHOUT ROWID. Any other
  rowid is renumbered by a VACUUM, and a stamp would name another row.
  `INTEGER PRIMARY KEY DESC` is not such a key (a quirk SQLite keeps),
  and is refused with the rest.

The triggers use no upsert, so a program on a SQLite older than 3.24 can
still open a watched file.
"""

from .conn import Connection

comptime STAMP_TABLES = """
CREATE TABLE IF NOT EXISTS m0_changes(
    tbl TEXT NOT NULL, row INTEGER NOT NULL,
    seq INTEGER NOT NULL, born INTEGER NOT NULL, gone INTEGER NOT NULL,
    PRIMARY KEY (tbl, row)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS m0_changes_seq ON m0_changes(tbl, seq);
CREATE TABLE IF NOT EXISTS m0_stamp(
    id INTEGER PRIMARY KEY CHECK (id = 0),
    seq INTEGER NOT NULL, floor INTEGER NOT NULL);
INSERT OR IGNORE INTO m0_stamp VALUES (0, 0, 0);
CREATE TABLE IF NOT EXISTS m0_cursors(name TEXT PRIMARY KEY, seq INTEGER NOT NULL);
"""

comptime _TICK = "UPDATE m0_stamp SET seq = seq + 1;"
comptime _NOW = "(SELECT seq FROM m0_stamp)"


def _is_identifier(name: String) -> Bool:
    """A table name `watch` will take: ASCII letters, digits and `_`, not
    opening with a digit, at most 64 bytes. It is quoted where it is
    spliced, so a keyword is a name like any other."""
    var b = name.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var alpha = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
        var digit = c >= 48 and c <= 57
        if not (alpha or (digit and i > 0)):
            return False
    return True


def _quoted(name: String) -> String:
    """`name` as a quoted SQL identifier."""
    return '"' + name.replace('"', '""') + '"'


def _stored_name(db: Connection, table: String) raises -> String:
    """The table's name as the schema spells it, or empty: SQLite matches
    names without regard to case, and a stamp is filed under one
    spelling."""
    if not _is_identifier(table):
        return String("")
    var q = db.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1 COLLATE NOCASE"
    )
    q.bind_text(1, table)
    if not q.step():
        return String("")
    return q.column_text(0)


def _entry(table: String, row: String) -> String:
    """Make sure the row has an entry. Neither an upsert, which a SQLite
    older than 3.24 cannot parse, nor `INSERT OR IGNORE`: the conflict
    clause of the statement that fired the trigger replaces the trigger's
    own, so under `UPDATE OR REPLACE` it would replace the entry and lose
    `born`, and under `INSERT OR FAIL` it would fail the write. An insert
    that cannot conflict has no clause to override."""
    return (
        " INSERT INTO m0_changes SELECT '" + table + "', " + row
        + ", 0, 0, 0 WHERE NOT EXISTS (SELECT 1 FROM m0_changes WHERE tbl = '"
        + table + "' AND row = " + row + "); UPDATE m0_changes SET "
    )


def _where(table: String, row: String) -> String:
    return " WHERE tbl = '" + table + "' AND row = " + row + ";"


def _born(table: String, row: String) -> String:
    """A row comes into being. A rowid given again after its row was
    deleted is a new row, born now."""
    return (
        _TICK + _entry(table, row) + "seq = " + _NOW + ", born = " + _NOW
        + ", gone = 0" + _where(table, row)
    )


def _touched(table: String, row: String) -> String:
    """A row changes. One older than the watch has no entry yet and is
    born at 0: every client has always held it."""
    return _TICK + _entry(table, row) + "seq = " + _NOW + _where(table, row)


def _gone(table: String, row: String) -> String:
    return _TICK + _entry(table, row) + "seq = " + _NOW + ", gone = 1" + _where(table, row)


def install_stamps(db: Connection) raises:
    """Create `m0_changes`, `m0_stamp` and `m0_cursors`. Idempotent; a
    write. A file installed before `m0_cursors` existed gains it."""
    db.execute(STAMP_TABLES)


def _rowid_key(db: Connection, table: String) raises -> String:
    """The column that is `table`'s rowid, or empty when it has none: one
    primary-key column declared INTEGER and no index kept for the key.
    WITHOUT ROWID and `INTEGER PRIMARY KEY DESC` both keep one."""
    var q = db.prepare(
        "SELECT count(*), sum(upper(type) = 'INTEGER'), max(name),"
        + " (SELECT count(*) FROM pragma_index_list(?1) WHERE origin = 'pk')"
        + " FROM pragma_table_info(?1) WHERE pk > 0"
    )
    q.bind_text(1, table)
    _ = q.step()
    if q.column_int(0) != 1 or q.column_int(1) != 1 or q.column_int(3) != 0:
        return String("")
    return q.column_text(2)


def watch(db: Connection, table: String) raises:
    """Stamp every later insert, update and delete of `table`.

    Idempotent, and a write. Wants `install_stamps` first. The name is
    matched as SQLite matches it, without regard to case, and filed as
    the schema spells it. Raises for a name that is not a plain
    identifier, for a table that is not there, for one of this module's
    own, and for one whose key is not its rowid.
    """
    var t = _stored_name(db, table)
    if t.byte_length() == 0:
        raise Error("watch: no table with the plain name: " + table)
    if t.lower().startswith("m0_") or t.lower().startswith("sqlite_"):
        raise Error("watch: " + t + " is not an application's table")
    var key = _rowid_key(db, t)
    if key.byte_length() == 0:
        raise Error("watch: " + t + " has no INTEGER PRIMARY KEY that is its rowid")
    # The key by its own name, never `rowid`: a column may be called that.
    var new = "new." + _quoted(key)
    var old = "old." + _quoted(key)
    var on = " ON " + _quoted(t)
    db.execute(
        'CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_ai" AFTER INSERT' + on
        + " BEGIN " + _born(t, new) + " END;"
        + 'CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_au" AFTER UPDATE' + on
        + " WHEN " + old + " = " + new + " BEGIN " + _touched(t, new) + " END;"
        + 'CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_am" AFTER UPDATE' + on
        + " WHEN " + old + " <> " + new + " BEGIN " + _gone(t, old)
        + " " + _born(t, new) + " END;"
        + 'CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_ad" AFTER DELETE' + on
        + " BEGIN " + _gone(t, old) + " END;"
    )


def watched(db: Connection, table: String) raises -> Bool:
    """Whether all four triggers are on `table`. False after a migration
    rebuilt it; `watch` again puts them back, and the rows changed in
    between were not stamped."""
    var t = _stored_name(db, table)
    if t.byte_length() == 0:
        return False
    var q = db.prepare(
        "SELECT count(*) FROM sqlite_master WHERE type = 'trigger'"
        + " AND tbl_name = ?1 AND name IN (?2, ?3, ?4, ?5)"
    )
    q.bind_text(1, t)
    q.bind_text(2, "m0_" + t + "_ai")
    q.bind_text(3, "m0_" + t + "_au")
    q.bind_text(4, "m0_" + t + "_am")
    q.bind_text(5, "m0_" + t + "_ad")
    _ = q.step()
    return q.column_int(0) == 4


def stamp_head(db: Connection) raises -> Int:
    """The last stamp given to any watched table."""
    var q = db.prepare("SELECT seq FROM m0_stamp WHERE id = 0")
    _ = q.step()
    return q.column_int(0)


def stamp_of(db: Connection, table: String) raises -> Int:
    """The highest stamp among `table`'s rows, 0 when none is stamped: a
    clock for one table, where `data_version` is the database's. It can
    go DOWN when the tombstone that held it is pruned, so compare it for
    equality and never for order. `table` is spelled as the schema
    spells it, which is how `watch` filed it: this is asked on every
    clock move, and is one index lookup."""
    var q = db.prepare("SELECT coalesce(max(seq), 0) FROM m0_changes WHERE tbl = ?1")
    q.bind_text(1, table)
    _ = q.step()
    return q.column_int(0)


def stamp_floor(db: Connection) raises -> Int:
    """The stamp at or below which tombstones were pruned. A client that
    stands lower may hold rows whose deletion is no longer recorded: it
    is told to start over, not handed a delta. Read it in the snapshot
    the delta is read in."""
    var q = db.prepare("SELECT floor FROM m0_stamp WHERE id = 0")
    _ = q.step()
    return q.column_int(0)


def prune_stamps(db: Connection, below: Int) raises -> Int:
    """Forget tombstones stamped at or below `below` and raise the floor
    to it, in one transaction of its own: called inside another it
    raises, and a raise leaves none open. `below` past the last stamp
    given means that stamp, so a floor is never above the head. Answers
    how many were forgotten. Rows that live keep their entries: `born` is
    read from them."""
    db.begin_immediate()
    try:
        var to = min(below, stamp_head(db))
        var d = db.prepare("DELETE FROM m0_changes WHERE gone = 1 AND seq <= ?1")
        d.bind_int(1, to)
        _ = d.step()
        var n = db.changes()
        d.finalize()
        var f = db.prepare("UPDATE m0_stamp SET floor = max(floor, ?1) WHERE id = 0")
        f.bind_int(1, to)
        _ = f.step()
        f.finalize()
        db.commit()
        return n
    except e:
        db.rollback()
        raise e^


def cursor(db: Connection, name: String) raises -> Int:
    """Where the stage called `name` stopped: the last stamp it acted on,
    0 for a stage with no place yet."""
    var q = db.prepare("SELECT seq FROM m0_cursors WHERE name = ?1")
    q.bind_text(1, name)
    if not q.step():
        return 0
    return q.column_int(0)


def advance(db: Connection, name: String, seq: Int) raises:
    """Record that `name` has acted on everything up to `seq`.

    Call it inside the `begin_immediate` transaction that writes the
    stage's outputs, so the place holds exactly when they do: a crash
    between the two is impossible, and a restart repeats nothing and
    skips nothing. It opens no transaction of its own, on purpose, and a
    refusal leaves the caller's open, outputs written: roll it back.

    A cursor does not go back, and does not pass the head: a `seq` below
    the cursor or above the last stamp given is refused, in the one
    statement that writes, so two writers racing on one name cannot
    undo each other. A stage registers before its first read with
    `advance(db, name, 0)`, or `slowest_cursor` cannot protect it; one
    that starts over deletes its row and its outputs; one that finds its
    cursor below `stamp_floor` at startup was pruned past, and starts
    over.
    """
    # The check travels with the write. OR REPLACE rather than an
    # upsert: the package's floor is SQLite 3.20.
    var u = db.prepare(
        "INSERT OR REPLACE INTO m0_cursors SELECT ?1, ?2 WHERE ?2 >= 0"
        + " AND ?2 >= coalesce((SELECT seq FROM m0_cursors WHERE name = ?1), 0)"
        + " AND ?2 <= (SELECT seq FROM m0_stamp)"
    )
    u.bind_text(1, name)
    u.bind_int(2, seq)
    _ = u.step()
    if db.changes() == 0:
        raise Error(
            "advance: " + name + " is at " + String(cursor(db, name)) + " and the head at "
            + String(stamp_head(db)) + "; " + String(seq) + " is not a place between them"
        )


def slowest_cursor(db: Connection) raises -> Int:
    """The place of the stage furthest behind, or the head when no stage
    has a place: the stamp `prune_stamps` may be given without taking a
    deletion from under a registered stage. A client that keeps its own
    place and is not registered -- a browser -- is told to start over
    instead (`stamp_floor`). A stage that is retired deletes its row, or
    pruning stops at its place for good; the lag query names it."""
    var q = db.prepare(
        "SELECT coalesce((SELECT min(seq) FROM m0_cursors), (SELECT seq FROM m0_stamp))"
    )
    _ = q.step()
    return q.column_int(0)
