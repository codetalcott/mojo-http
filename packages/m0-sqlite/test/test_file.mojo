"""File-backed database tests: WAL, persistence across reopen, read-only.

Separate from test_sqlite.mojo because these touch the filesystem. They matter
disproportionately: the NUL-termination bug that `c_string` exists to prevent
only ever manifested on a *path* argument, and only for some path lengths, so
an in-memory-only suite would never have caught it.
"""

from std.ffi import external_call, c_int
from std.memory import stack_allocation
from std.os import remove, mkdir, rmdir, path
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite
from std.time import perf_counter_ns

from src import (
    Connection,
    open,
    open_readonly,
    open_memory,
    open_serialized,
    error_code,
    MEMORY,
    DEFAULT_BUSY_TIMEOUT_MS,
    SQLITE_BUSY,
)


def _dir() -> String:
    """A scratch directory private to this test process.

    Keyed to the pid rather than fixed, because a fixed path is shared state
    that no amount of git isolation reaches: two sessions running `test-sqlite`
    from separate worktrees still meet in the same `/tmp` directory, and the
    second one's `_fresh` deletes databases the first is holding open. That is
    a real configuration here — remote sessions spawn into their own worktrees
    and can run concurrently.
    """
    return String("/tmp/m0-sqlite-test-") + String(
        Int(external_call["getpid", c_int]())
    )


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
    var dir = _dir()
    if not path.exists(dir):
        mkdir(dir)
    var p = dir + "/" + name + ".db"
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

    # Every third length from 1 to 40. The full sweep cost ~115s on a CI macOS
    # runner for no extra signal — allocation layout does not change character
    # between adjacent lengths.
    for n in range(1, 40, 3):
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


# --- Busy handling -----------------------------------------------------------
#
# Without a busy handler SQLite fails a contended write instantly. These pin
# down that a handler is installed and that it actually waits.

def test_open_installs_the_default_busy_timeout() raises:
    var p = _fresh("busydefault")
    var db = open(p)
    var q = db.prepare("PRAGMA busy_timeout")
    assert_true(q.step())
    assert_equal(q.column_int(0), DEFAULT_BUSY_TIMEOUT_MS)
    q.finalize()

    var ro = open_readonly(p)
    var q2 = ro.prepare("PRAGMA busy_timeout")
    assert_true(q2.step())
    assert_equal(q2.column_int(0), DEFAULT_BUSY_TIMEOUT_MS)
    q2.finalize()

    ro.close()
    db.close()
    _cleanup(p)


def test_busy_timeout_waits_before_giving_up() raises:
    """A contended write must wait out the timeout, not fail on contact.

    Bounded on both sides. A lower bound alone cannot tell a 300ms wait from a
    five-minute one, so a handler that ignored its limit — or a connection
    that quietly kept the 5s default — would read as a pass.
    """
    var p = _fresh("busywait")
    var writer = open(p)
    writer.execute("CREATE TABLE t (v INTEGER)")

    var other = open(p)
    other.busy_timeout(300)

    writer.begin_immediate()
    writer.execute("INSERT INTO t VALUES (1)")

    var t0 = perf_counter_ns()
    var code = -1
    try:
        other.execute("INSERT INTO t VALUES (2)")
    except e:
        code = error_code(String(e))
    var waited_ms = (perf_counter_ns() - t0) // 1_000_000

    writer.rollback()
    assert_equal(code, SQLITE_BUSY, "the contended write must report BUSY")
    assert_true(
        waited_ms >= 250,
        "expected a wait of about 300ms, waited " + String(waited_ms) + "ms",
    )
    # Generous, because CI runners stall: this is here to catch a wait that is
    # unbounded or still on the 5s default, not to time the handler.
    assert_true(
        waited_ms < 3000,
        "expected a wait of about 300ms, waited " + String(waited_ms) + "ms —"
        " the busy timeout is not being honoured",
    )

    # And the write succeeds once the lock is released.
    other.execute("INSERT INTO t VALUES (2)")
    var q = other.prepare("SELECT COUNT(*) FROM t")
    assert_true(q.step())
    assert_equal(q.column_int(0), 1)
    q.finalize()

    other.close()
    writer.close()
    _cleanup(p)


def test_busy_timeout_can_be_cleared() raises:
    """A non-positive value restores SQLite's fail-immediately default."""
    var p = _fresh("busyclear")
    var writer = open(p)
    writer.execute("CREATE TABLE t (v INTEGER)")

    var other = open(p)
    other.busy_timeout(0)
    writer.begin_immediate()
    writer.execute("INSERT INTO t VALUES (1)")

    var t0 = perf_counter_ns()
    with assert_raises():
        other.execute("INSERT INTO t VALUES (2)")
    var waited_ms = (perf_counter_ns() - t0) // 1_000_000

    writer.rollback()
    assert_true(
        waited_ms < 100, "expected no wait, waited " + String(waited_ms) + "ms"
    )
    other.close()
    writer.close()
    _cleanup(p)


def test_mmap_size_is_opt_in() raises:
    """`open()` must not enable mmap; asking for it must work.

    Not a default because mmap turns a disk error into a SIGBUS — see
    docs/SQLITE_PERFORMANCE.md.
    """
    var p = _fresh("mmap")
    var db = open(p)
    assert_equal(db.query_scalar("PRAGMA mmap_size"), "0")

    db.mmap_size(67108864)
    var got = Int(db.query_scalar("PRAGMA mmap_size"))
    assert_true(got > 0, "mmap_size did not take")
    db.close()
    _cleanup(p)


def test_open_applies_wal() raises:
    """The success path: open() promises WAL and SQLite agrees."""
    var p = _fresh("walok")
    var db = open(p)
    assert_equal(db.query_scalar("PRAGMA journal_mode"), "wal")
    db.close()
    _cleanup(p)


def test_open_reports_wal_it_could_not_apply() raises:
    """The failure path, which this test used to skip while claiming to cover.

    `PRAGMA journal_mode=WAL` can fail quietly — it answers with the mode
    actually in force, and a database that cannot do WAL stays on a rollback
    journal and reports something else. Discarding that row would mean open()
    promising reader/writer concurrency while delivering a lock that
    serializes them.

    `:memory:` is the reachable case: it answers "memory", and it is reachable
    by accident too, since `MEMORY` is exported right next to `open`. The
    error must name the mode SQLite actually reported, or the next person
    debugs a concurrency problem instead of reading a message.

    covers: O1
    """
    var message = String("")
    try:
        var _db = open(MEMORY)
    except e:
        message = String(e)
    assert_true(
        "journal_mode=WAL was not applied" in message,
        "open() accepted a database that cannot do WAL: " + message,
    )
    assert_true(
        "'memory'" in message,
        "the error did not report the mode SQLite gave: " + message,
    )


# --- open_serialized ----------------------------------------------------------

def test_open_serialized_round_trips() raises:
    """The only constructor whose flag set differs, and it had no test at all.

    What this pins is that the flags still assemble into a working connection
    and that it gets the same pragmas as `open`. It cannot pin that
    FULLMUTEX took effect — that would need two threads writing through one
    Connection, which this package tells you not to do and Mojo gives no
    portable way to arrange here. A typo in the flag constant is the failure
    this catches, and it was previously invisible.
    """
    var p = _fresh("serialized")
    var db = open_serialized(p)
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    var ins = db.prepare("INSERT INTO t (v) VALUES (?)")
    ins.bind_text(1, "threadsafe")
    _ = ins.step()
    ins.finalize()

    assert_equal(db.query_scalar("PRAGMA journal_mode"), "wal")
    assert_equal(
        Int(db.query_scalar("PRAGMA busy_timeout")), DEFAULT_BUSY_TIMEOUT_MS
    )
    assert_equal(db.query_scalar("PRAGMA foreign_keys"), "1")
    assert_equal(db.query_scalar("SELECT v FROM t"), "threadsafe")
    db.close()

    # And the file it wrote is an ordinary database to everyone else.
    var ro = open_readonly(p)
    assert_equal(ro.query_scalar("SELECT v FROM t"), "threadsafe")
    ro.close()
    _cleanup(p)


def test_open_serialized_reports_wal_it_could_not_apply() raises:
    """Same promise as open(), so the same failure must surface."""
    var message = String("")
    try:
        var _db = open_serialized(MEMORY)
    except e:
        message = String(e)
    assert_true(
        "journal_mode=WAL was not applied" in message,
        "open_serialized() accepted a database that cannot do WAL: " + message,
    )


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


def _open_and_exit(db_path: String):
    """A forked child's whole life: `open` the shared file, then `_exit` 0 on
    success or 1 on a raise. `_exit`, never a return: the child is a copy of
    the test runner and must not run its teardown."""
    var code = 0
    try:
        var db = open(db_path)
        db.execute("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY)")
        db.close()
    except:
        code = 1
    _ = external_call["_exit", c_int](c_int(code))


def _wait_exit(pid: Int) -> Int:
    """`waitpid` and the child's exit code, or MINUS the signal that killed
    it. The signal's number is the finding: the one time a pair failed on a
    CI runner both children had died of a signal, which is not the lock
    this test is about (a loser there exits 1), and a bare -1 could not say
    which -- SIGTRAP from a runtime teardown, SIGKILL from the host and
    SIGSEGV are three different bugs."""
    var status = stack_allocation[1, c_int]()
    status[unsafe_offset=0] = 0
    _ = external_call["waitpid", c_int](c_int(pid), status, c_int(0))
    var raw = Int(status[unsafe_offset=0])
    if raw & 0x7F != 0:
        return -(raw & 0x7F)
    return (raw >> 8) & 0xFF


def _describe_exit(code: Int) -> String:
    if code < 0:
        return String("killed by signal ", -code)
    return String("exit ", code)


def test_a_signalled_child_is_reported_by_its_signal() raises:
    """The null case for `_wait_exit`: a child killed by SIGKILL reads as -9,
    never as an exit code and never as a bare -1. Without this the helper's
    signal branch is only ever exercised by the failure it exists to explain."""
    var pid = Int(external_call["fork", c_int]())
    if pid == 0:
        _ = external_call["raise", c_int](c_int(9))
        _ = external_call["_exit", c_int](c_int(0))
    assert_equal(_wait_exit(pid), -9)
    assert_equal(_describe_exit(-9), "killed by signal 9")
    assert_equal(_describe_exit(1), "exit 1")


def test_two_processes_open_one_fresh_database() raises:
    """Two processes opening the same FRESH file at once must both succeed.

    The shape of two forked `m0serve` or Mojo-host workers building their
    handlers: each `open`s the one database, and the first switches it out
    of the rollback journal while the second is doing the same. SQLite
    answers the loser's `PRAGMA journal_mode=WAL` with "database is locked"
    at once, without consulting the busy handler `open` set a line earlier
    -- measured as 29 of 30 two-worker starts of `apps/datastar_todo`
    refused, once the host stopped hiding it behind a crash and a respawn
    (SPEC E25). Twelve pairs here, because one pair loses the race about
    half the time on an M4 and the point is that no pair may.

    covers: O1
    """
    var p = _fresh("concurrent-open")
    for round in range(12):
        _cleanup(p)
        var a = Int(external_call["fork", c_int]())
        if a == 0:
            _open_and_exit(p)
        var b = Int(external_call["fork", c_int]())
        if b == 0:
            _open_and_exit(p)
        var ra = _wait_exit(a)
        var rb = _wait_exit(b)
        assert_equal(
            ra + rb, 0,
            String(
                "round ", round, ": a concurrent open failed (",
                _describe_exit(ra), ", ", _describe_exit(rb), ")",
            ),
        )
    _cleanup(p)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
    # Remove the per-process scratch directory. Deliberately after run(), so a
    # failing suite leaves its databases behind to inspect.
    var dir = _dir()
    if path.exists(dir):
        try:
            rmdir(dir)
        except:
            pass
