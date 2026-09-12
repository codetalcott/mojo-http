"""The package against a real server.

**These tests FAIL without a server; they never skip.** A gate that exits 0
when its dependency is absent is green having tested nothing, which is the
shape `scripts/spec_sheet.py` refuses for a cited CI step and the shape this
file refuses for itself. The URL comes from `M0_PG_TEST_URL`, defaulting to
`postgres:///postgres` — a Unix socket to the local cluster as the current
user, which is what a developer machine and a CI service container both
provide.

Everything runs inside a schema named for this process, created at the start
and dropped at the end, so a run leaves nothing behind and two runs on one
cluster cannot collide.
"""

from std.collections.span import Span
from std.os import getenv
from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from src import (
    Connection,
    Params,
    Prepared,
    open,
    open_readonly,
)
from src.lib import PgLib
from src.sqlstate import (
    READ_ONLY_SQL_TRANSACTION,
    SYNTAX_ERROR,
    UNDEFINED_TABLE,
    UNIQUE_VIOLATION,
    sqlstate,
)
from src.wire import (
    OID_INT8,
    OID_TEXT,
    OID_TIMESTAMPTZ,
    unix_micros,
)


def _url() -> String:
    return getenv("M0_PG_TEST_URL", "postgres:///postgres")


def _db() raises -> Connection:
    """A connection with a scratch schema of its own, already current.

    The schema name carries the connection's backend pid, so parallel runs
    against one cluster do not meet. `search_path` is set to it alone, so an
    unqualified CREATE lands there and an unqualified SELECT cannot
    accidentally read a table of the same name in `public`.
    """
    var db = open(_url())
    var schema = "m0_test_" + String(db.backend_pid())
    db.execute("DROP SCHEMA IF EXISTS " + schema + " CASCADE")
    db.execute("CREATE SCHEMA " + schema)
    db.execute("SET search_path TO " + schema)
    return db^


def _drop(mut db: Connection) raises:
    var schema = "m0_test_" + String(db.backend_pid())
    db.execute("SET search_path TO public")
    db.execute("DROP SCHEMA IF EXISTS " + schema + " CASCADE")


# --- Connecting -------------------------------------------------------------


def test_the_library_opens_and_reports_its_version() raises:
    """A link check: this fails first when libpq cannot be found at all.

    covers: O10
    """
    var lib = PgLib.open()
    assert_true(Int(lib.libversion()) >= 120000)
    assert_true(lib.version_text().startswith("1"))
    assert_true(len(lib.path.as_bytes()) > 0)


def test_a_connection_reports_the_server_it_reached() raises:
    """What a live connection knows about its server.

    covers: O10
    """
    var db = _db()
    assert_true(db.healthy())
    assert_true(db.server_version() >= 120000)
    assert_true(db.backend_pid() > 0)
    assert_true(db.socket_fd() >= 0)
    _drop(db)


def test_a_bad_url_raises_with_the_password_masked() raises:
    """The failure path that must not print what it was given.

    A connection error is the string most likely to reach a log, an issue
    or a paste. libpq's own message never echoes the password; neither may
    this.

    covers: O12
    """
    var raised = False
    try:
        var _db = open(
            "postgres://m0_no_such_user:s3cret@127.0.0.1:1/m0_no_such_db"
            "?connect_timeout=2"
        )
    except e:
        raised = True
        assert_false("s3cret" in String(e))
        assert_true("***" in String(e))
    assert_true(raised)


# --- Queries ----------------------------------------------------------------


def test_a_parameter_is_bound_not_interpolated() raises:
    """The property the whole `Params` type exists for.

    The value carries a quote and a semicolon; if it were interpolated, the
    statement would not parse or would run two.

    covers: O10
    """
    var db = _db()
    var p = Params()
    p.text("o'brien; DROP TABLE x; --")
    var rows = db.query("SELECT $1::text", p)
    assert_equal(rows.rows, 1)
    assert_equal(rows.text(0, 0), "o'brien; DROP TABLE x; --")
    _drop(db)


def test_every_parameter_type_round_trips() raises:
    """Each binding method, written and read back.

    covers: O10
    """
    var db = _db()
    db.execute(
        "CREATE TABLE t (id bigint, score double precision,"
        " flag boolean, name text, blob bytea)"
    )
    var p = Params()
    p.int(-9007199254740993)
    p.float(0.5)
    p.bool(True)
    p.text("ada")
    var raw = List[UInt8]()
    raw.append(0)
    raw.append(0x80)
    raw.append(0xFF)
    p.bytes(Span(raw))
    _ = db.query(
        "INSERT INTO t (id, score, flag, name, blob)"
        " VALUES ($1, $2, $3, $4, $5)",
        p,
    )
    var rows = db.query(
        "SELECT id, score, flag, name, blob FROM t", Params()
    )
    assert_equal(rows.rows, 1)
    assert_equal(rows.int(0, 0), -9007199254740993)
    assert_almost_equal(rows.float(0, 1), 0.5)
    assert_true(rows.bool(0, 2))
    assert_equal(rows.text(0, 3), "ada")
    var back = db.query("SELECT blob FROM t", Params(), binary=True)
    var bytes = back.bytes(0, 0)
    assert_equal(len(bytes), 3)
    assert_equal(Int(bytes[1]), 0x80)
    assert_equal(Int(bytes[2]), 0xFF)
    _drop(db)


def test_null_is_distinguishable_from_an_empty_value() raises:
    """Both have length 0 and both read as "" in text mode.

    covers: O10
    """
    var db = _db()
    db.execute("CREATE TABLE t (a text, b text)")
    var p = Params()
    p.null()
    p.text("")
    _ = db.query("INSERT INTO t (a, b) VALUES ($1, $2)", p)
    var rows = db.query("SELECT a, b FROM t", Params())
    assert_true(rows.is_null(0, 0))
    assert_false(rows.is_null(0, 1))
    assert_equal(rows.text(0, 1), "")
    _drop(db)


def test_binary_and_text_results_agree() raises:
    """The same query both ways, read the same.

    The result format is one choice for the whole query, so this is what
    makes `binary=True` a performance decision rather than a semantic one.

    covers: O11
    """
    var db = _db()
    var sql = String(
        "SELECT 42::int8, 2.5::float8, true, 'ada'::text,"
        " '12345678-9abc-def0-1234-56789abcdef0'::uuid,"
        " '{\"a\": 1}'::jsonb"
    )
    var as_text = db.query(sql, Params())
    var as_binary = db.query(sql, Params(), binary=True)
    for c in range(as_text.cols):
        assert_equal(as_binary.oid(c), as_text.oid(c))
    assert_equal(as_binary.text(0, 0), as_text.text(0, 0))
    assert_equal(as_binary.int(0, 0), 42)
    assert_equal(as_text.int(0, 0), 42)
    assert_almost_equal(as_binary.float(0, 1), 2.5)
    assert_true(as_binary.bool(0, 2))
    assert_equal(as_binary.text(0, 3), "ada")
    assert_equal(as_binary.text(0, 4), as_text.text(0, 4))
    # jsonb's binary form carries a version byte the text form does not;
    # the decoder strips it, so the two agree.
    assert_true("\"a\"" in as_binary.text(0, 5))
    _drop(db)


def test_a_binary_type_with_no_decoder_names_the_way_out() raises:
    """`numeric` is text-only on purpose, and says so.

    covers: O11
    """
    var db = _db()
    var rows = db.query("SELECT 2.50::numeric", Params(), binary=True)
    with assert_raises(contains="text mode"):
        _ = rows.text(0, 0)
    # And the same column in text mode is simply the number.
    var text_rows = db.query("SELECT 2.50::numeric", Params())
    assert_equal(text_rows.text(0, 0), "2.50")
    _drop(db)


def test_a_timestamp_decodes_to_the_instant_the_server_means() raises:
    """The 2000 epoch, checked against the server's own arithmetic.

    covers: O11
    """
    var db = _db()
    var rows = db.query(
        "SELECT '2026-09-12 12:00:00+00'::timestamptz,"
        " extract(epoch FROM '2026-09-12 12:00:00+00'::timestamptz)::int8",
        Params(),
        binary=True,
    )
    assert_equal(rows.oid(0), OID_TIMESTAMPTZ)
    var micros = unix_micros(rows.int(0, 0))
    assert_equal(micros // 1000000, rows.int(0, 1))
    _drop(db)


def test_columns_are_addressable_by_name() raises:
    """By index and by the name the query gave.

    covers: O10
    """
    var db = _db()
    var rows = db.query("SELECT 1 AS one, 2 AS two", Params())
    assert_equal(rows.name(0), "one")
    assert_equal(rows.column("two"), 1)
    with assert_raises(contains="no column named"):
        _ = rows.column("three")
    _drop(db)


def test_out_of_range_reads_raise_rather_than_answering() raises:
    """`PQgetvalue` past the end returns NULL, which reads as "".

    The same defect `m0-sqlite`'s column readers exist to refuse.

    covers: O10
    """
    var db = _db()
    var rows = db.query("SELECT 1", Params())
    with assert_raises(contains="out of range"):
        _ = rows.text(0, 5)
    with assert_raises(contains="out of range"):
        _ = rows.text(5, 0)
    with assert_raises(contains="out of range"):
        _ = rows.text(0, -1)
    _drop(db)


def test_command_rows_counts_what_a_write_changed() raises:
    """What an INSERT or DELETE reports.

    covers: O10
    """
    var db = _db()
    db.execute("CREATE TABLE t (id int)")
    var p = Params()
    p.int(1)
    var inserted = db.query("INSERT INTO t VALUES ($1), ($1), ($1)", p)
    assert_equal(inserted.command_rows(), 3)
    var deleted = db.query("DELETE FROM t WHERE id = $1", p)
    assert_equal(deleted.command_rows(), 3)
    _drop(db)


# --- Errors -----------------------------------------------------------------


def test_an_error_carries_its_sqlstate_and_the_sql() raises:
    """A failed statement names its state and leaves the connection usable.

    covers: O12
    """
    var db = _db()
    var message = String("")
    try:
        _ = db.query("SELECT * FROM m0_no_such_table", Params())
    except e:
        message = String(e)
    assert_equal(sqlstate(message), UNDEFINED_TABLE)
    assert_true("m0_no_such_table" in message)
    # And the connection is still usable: a failed statement is not a failed
    # connection.
    assert_true(db.healthy())
    assert_equal(db.query("SELECT 1", Params()).int(0, 0), 1)
    _drop(db)


def test_a_constraint_violation_is_reported_as_one() raises:
    """The code an application branches on to answer 409 rather than 500.

    covers: O12
    """
    var db = _db()
    db.execute("CREATE TABLE t (name text PRIMARY KEY)")
    var p = Params()
    p.text("ada")
    _ = db.query("INSERT INTO t VALUES ($1)", p)
    var message = String("")
    try:
        _ = db.query("INSERT INTO t VALUES ($1)", p)
    except e:
        message = String(e)
    assert_equal(sqlstate(message), UNIQUE_VIOLATION)
    _drop(db)


def test_a_syntax_error_names_its_state_too() raises:
    """SQL that does not parse is class 42 like the rest.

    covers: O12
    """
    var db = _db()
    var message = String("")
    try:
        db.execute("SELECT FROM WHERE")
    except e:
        message = String(e)
    assert_equal(sqlstate(message), SYNTAX_ERROR)
    _drop(db)


# --- Transactions -----------------------------------------------------------


def test_a_rollback_discards_and_a_commit_persists() raises:
    """The two endings of an explicit transaction.

    covers: O10
    """
    var db = _db()
    db.execute("CREATE TABLE t (id int)")
    db.begin()
    _ = db.query("INSERT INTO t VALUES (1)", Params())
    assert_true(db.in_transaction())
    db.rollback()
    assert_false(db.in_transaction())
    assert_equal(db.query("SELECT count(*) FROM t", Params()).int(0, 0), 0)

    db.begin()
    _ = db.query("INSERT INTO t VALUES (2)", Params())
    db.commit()
    assert_equal(db.query("SELECT count(*) FROM t", Params()).int(0, 0), 1)
    _drop(db)


def test_a_failed_transaction_still_reads_as_open() raises:
    """INERROR is open: it holds its locks until ROLLBACK.

    Reporting it as "not in a transaction" is how a connection gets handed
    back to a pool still holding them.

    covers: O10
    """
    var db = _db()
    db.begin()
    try:
        db.execute("SELECT * FROM m0_no_such_table")
    except:
        pass
    assert_true(db.in_transaction())
    db.rollback()
    assert_false(db.in_transaction())
    _drop(db)


# --- Prepared statements ----------------------------------------------------


def test_a_prepared_statement_runs_with_its_own_parameters() raises:
    """Prepared once, executed repeatedly, then deallocated.

    covers: O10
    """
    var db = _db()
    db.execute("CREATE TABLE t (id bigint, name text)")
    var oids = List[Int]()
    oids.append(OID_INT8)
    oids.append(OID_TEXT)
    var insert = db.prepare("INSERT INTO t VALUES ($1, $2)", oids)
    for i in range(3):
        var p = Params()
        p.int(i)
        p.text("row " + String(i))
        _ = db.query_prepared(insert, p)
    var rows = db.query("SELECT id, name FROM t ORDER BY id", Params())
    assert_equal(rows.rows, 3)
    assert_equal(rows.text(2, 1), "row 2")
    db.close_prepared(insert)
    # Deallocated: using it again is the server's error, not a silent reuse.
    var p2 = Params()
    p2.int(9)
    p2.text("late")
    with assert_raises():
        _ = db.query_prepared(insert, p2)
    _drop(db)


def test_a_prepared_statement_checks_its_parameters_before_the_round_trip() raises:
    """A plan depends on its parameter types, so a mismatch is caught here.

    covers: O10
    """
    var db = _db()
    var oids = List[Int]()
    oids.append(OID_INT8)
    var one = db.prepare("SELECT $1::int8", oids)

    var too_many = Params()
    too_many.int(1)
    too_many.int(2)
    with assert_raises(contains="was prepared with 1 parameters"):
        _ = db.query_prepared(one, too_many)

    var wrong_type = Params()
    wrong_type.text("1")
    with assert_raises(contains="was prepared as OID"):
        _ = db.query_prepared(one, wrong_type)
    _drop(db)


# --- Read-only connections --------------------------------------------------


def test_a_read_only_connection_refuses_a_write() raises:
    """The belt to a read-only role's braces.

    covers: O13
    """
    var setup = _db()
    setup.execute("CREATE TABLE t (id int)")
    var schema = "m0_test_" + String(setup.backend_pid())

    var reader = open_readonly(_url())
    reader.execute("SET search_path TO " + schema)
    # Reading is fine.
    assert_equal(reader.query("SELECT count(*) FROM t", Params()).int(0, 0), 0)
    var message = String("")
    try:
        reader.execute("INSERT INTO t VALUES (1)")
    except e:
        message = String(e)
    assert_equal(sqlstate(message), READ_ONLY_SQL_TRANSACTION)
    _drop(setup)


# --- Identifiers ------------------------------------------------------------


def test_an_identifier_is_quoted_by_the_server_not_by_hand() raises:
    """`LISTEN` and `DEALLOCATE` take no parameters, so a name goes in as text.

    covers: O14
    """
    var db = _db()
    assert_equal(db.quote_identifier("plain"), '"plain"')
    assert_equal(db.quote_identifier('has"quote'), '"has""quote"')
    assert_equal(db.quote_identifier("has space"), '"has space"')
    _drop(db)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
