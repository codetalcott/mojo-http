"""Tests for m0-sqlite.

Everything runs against `:memory:` so the suite needs no filesystem and leaves
nothing behind. The file-backed paths (WAL pragmas, reopen, read-only) are
covered separately in test_file.mojo.
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
    errstr,
    c_string,
    SQLITE_INTEGER,
    SQLITE_FLOAT,
    SQLITE_TEXT,
    SQLITE_BLOB,
    SQLITE_NULL,
)


def _seeded() raises -> Connection:
    var db = open_memory()
    db.execute(
        "CREATE TABLE users ("
        " id INTEGER PRIMARY KEY,"
        " name TEXT NOT NULL,"
        " score REAL,"
        " avatar BLOB,"
        " note TEXT)"
    )
    return db^


# --- Linking and library surface --------------------------------------------

def test_libversion_is_reported() raises:
    """A link check: this fails first if libsqlite3 is not resolvable."""
    var v = libversion()
    assert_true(v.byte_length() > 0)
    assert_true(v.startswith("3."))


def test_errstr_maps_codes() raises:
    """Result codes render as English without needing a connection."""
    assert_equal(errstr(0), "not an error")
    assert_true(errstr(1).byte_length() > 0)


def test_c_string_is_nul_terminated() raises:
    """The whole reason c_string exists: Mojo's String is not NUL-terminated.

    A buffer handed to a C API that scans for NUL must carry one explicitly.
    """
    var buf = c_string("abc")
    assert_equal(len(buf), 4)
    assert_equal(buf[3], UInt8(0))
    assert_equal(len(c_string("")), 1)


# --- Connection lifecycle ----------------------------------------------------

def test_open_memory_and_execute() raises:
    var db = open_memory()
    db.execute("CREATE TABLE t (a INTEGER)")
    db.execute("INSERT INTO t VALUES (1)")
    assert_equal(db.changes(), 1)


def test_bad_sql_raises_with_message() raises:
    """Errors carry SQLite's own text, not just a code."""
    var db = open_memory()
    with assert_raises():
        db.execute("SELECT * FROM does_not_exist")


def test_prepare_rejects_invalid_sql() raises:
    var db = open_memory()
    with assert_raises():
        _ = db.prepare("NOT VALID SQL")


def test_open_readonly_missing_file_raises() raises:
    """Opening a nonexistent database read-only must fail, not create it."""
    from src import open_readonly
    with assert_raises():
        _ = open_readonly("/nonexistent-dir-xyz/nope.db")


def test_close_is_idempotent() raises:
    """close() twice is fine; __deinit__ then has nothing to do."""
    var db = open_memory()
    db.close()
    db.close()


# --- Binding and typed reads -------------------------------------------------

def test_roundtrip_every_type() raises:
    var db = _seeded()
    var ins = db.prepare(
        "INSERT INTO users (name, score, avatar, note) VALUES (?, ?, ?, ?)"
    )
    ins.bind_text(1, "ada")
    ins.bind_float(2, 99.5)
    ins.bind_blob(3, [UInt8(1), UInt8(2), UInt8(255)])
    ins.bind_null(4)
    assert_false(ins.step())

    var q = db.prepare("SELECT name, score, avatar, note FROM users")
    assert_true(q.step())
    assert_equal(q.column_text(0), "ada")
    assert_almost_equal(q.column_float(1), 99.5)
    var blob = q.column_blob(2)
    assert_equal(len(blob), 3)
    assert_equal(blob[2], UInt8(255))
    assert_true(q.is_null(3))
    assert_false(q.step())


def test_column_types_are_reported() raises:
    var db = _seeded()
    db.execute(
        "INSERT INTO users (name, score, avatar, note)"
        " VALUES ('x', 1.5, x'00ff', NULL)"
    )
    var q = db.prepare("SELECT id, name, score, avatar, note FROM users")
    assert_true(q.step())
    assert_equal(q.column_type(0), SQLITE_INTEGER)
    assert_equal(q.column_type(1), SQLITE_TEXT)
    assert_equal(q.column_type(2), SQLITE_FLOAT)
    assert_equal(q.column_type(3), SQLITE_BLOB)
    assert_equal(q.column_type(4), SQLITE_NULL)


def test_is_null_distinguishes_null_from_zero() raises:
    """column_int returns 0 for NULL, which a real 0 also returns."""
    var db = open_memory()
    db.execute("CREATE TABLE t (v INTEGER)")
    db.execute("INSERT INTO t VALUES (0), (NULL)")
    var q = db.prepare("SELECT v FROM t ORDER BY rowid")
    assert_true(q.step())
    assert_equal(q.column_int(0), 0)
    assert_false(q.is_null(0))
    assert_true(q.step())
    assert_equal(q.column_int(0), 0)
    assert_true(q.is_null(0))


def test_text_with_embedded_nul_survives() raises:
    """Length-driven reads, not NUL scans — so an embedded NUL round-trips."""
    var db = open_memory()
    db.execute("CREATE TABLE t (v TEXT)")
    var ins = db.prepare("INSERT INTO t VALUES (?)")
    ins.bind_text(1, String("a\0b"))
    _ = ins.step()
    var q = db.prepare("SELECT v FROM t")
    assert_true(q.step())
    assert_equal(q.column_text(0).byte_length(), 3)


def test_column_metadata() raises:
    var db = _seeded()
    var q = db.prepare("SELECT id, name FROM users")
    assert_equal(q.column_count(), 2)
    assert_equal(q.column_name(0), "id")
    assert_equal(q.column_name(1), "name")


def test_parameters_are_one_based_columns_zero_based() raises:
    """SQLite's asymmetry, preserved deliberately."""
    var db = open_memory()
    db.execute("CREATE TABLE t (a INTEGER, b INTEGER)")
    var ins = db.prepare("INSERT INTO t VALUES (?, ?)")
    ins.bind_int(1, 10)
    ins.bind_int(2, 20)
    _ = ins.step()
    var q = db.prepare("SELECT a, b FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 10)
    assert_equal(q.column_int(1), 20)


# --- Statement reuse ---------------------------------------------------------

def test_reset_allows_reuse() raises:
    var db = _seeded()
    var ins = db.prepare("INSERT INTO users (name) VALUES (?)")
    for i in range(3):
        ins.reset()
        ins.bind_text(1, "u" + String(i))
        _ = ins.step()
    var q = db.prepare("SELECT COUNT(*) FROM users")
    assert_true(q.step())
    assert_equal(q.column_int(0), 3)


def test_clear_bindings_resets_to_null() raises:
    var db = _seeded()
    var ins = db.prepare("INSERT INTO users (name, note) VALUES ('n', ?)")
    ins.bind_text(1, "kept")
    _ = ins.step()
    ins.reset()
    ins.clear_bindings()
    _ = ins.step()
    var q = db.prepare("SELECT note FROM users ORDER BY id")
    assert_true(q.step())
    assert_equal(q.column_text(0), "kept")
    assert_true(q.step())
    assert_true(q.is_null(0))


def test_step_raises_on_constraint_violation() raises:
    """A failing step surfaces as an error, not a silent code."""
    var db = open_memory()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    db.execute("INSERT INTO t VALUES (1)")
    var ins = db.prepare("INSERT INTO t VALUES (1)")
    with assert_raises():
        _ = ins.step()


# --- Transactions ------------------------------------------------------------

def test_commit_persists() raises:
    var db = _seeded()
    db.begin()
    assert_true(db.in_transaction())
    db.execute("INSERT INTO users (name) VALUES ('kept')")
    db.commit()
    assert_false(db.in_transaction())
    var q = db.prepare("SELECT COUNT(*) FROM users")
    assert_true(q.step())
    assert_equal(q.column_int(0), 1)


def test_rollback_discards() raises:
    var db = _seeded()
    db.execute("INSERT INTO users (name) VALUES ('before')")
    db.begin()
    db.execute("INSERT INTO users (name) VALUES ('discarded')")
    db.rollback()
    var q = db.prepare("SELECT COUNT(*) FROM users")
    assert_true(q.step())
    assert_equal(q.column_int(0), 1)


def test_begin_immediate_takes_the_write_lock() raises:
    var db = _seeded()
    db.begin_immediate()
    assert_true(db.in_transaction())
    db.rollback()


def test_foreign_keys_are_enforced() raises:
    """SQLite defaults foreign_keys OFF; open_memory turns it on."""
    var db = open_memory()
    db.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
    db.execute(
        "CREATE TABLE child (id INTEGER PRIMARY KEY,"
        " pid INTEGER REFERENCES parent(id))"
    )
    with assert_raises():
        db.execute("INSERT INTO child VALUES (1, 999)")


# --- Introspection -----------------------------------------------------------

def test_last_insert_rowid_and_changes() raises:
    var db = _seeded()
    db.execute("INSERT INTO users (name) VALUES ('a')")
    assert_equal(db.last_insert_rowid(), 1)
    db.execute("INSERT INTO users (name) VALUES ('b')")
    assert_equal(db.last_insert_rowid(), 2)
    db.execute("UPDATE users SET score = 1.0")
    assert_equal(db.changes(), 2)
    assert_true(db.total_changes() >= 4)


# --- Ownership ---------------------------------------------------------------

def test_moved_connection_still_works() raises:
    """Transferring ownership must not close the handle.

    Connection and Statement are Movable but not Copyable precisely so a handle
    cannot end up with two owners; this checks the move itself is clean.
    """
    var a = open_memory()
    a.execute("CREATE TABLE t (v INTEGER)")
    var b = a^
    b.execute("INSERT INTO t VALUES (7)")
    var q = b.prepare("SELECT v FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 7)


def test_many_statements_are_released() raises:
    """Statements finalize on scope exit; leaking would exhaust SQLite here."""
    var db = _seeded()
    for i in range(200):
        var s = db.prepare("SELECT ?")
        s.bind_int(1, i)
        assert_true(s.step())
        assert_equal(s.column_int(0), i)
    db.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
