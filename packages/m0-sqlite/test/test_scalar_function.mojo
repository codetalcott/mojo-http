"""Scalar functions written in Mojo (`function.mojo`): SPEC O19 to O22.

Each test holds one of the rules `function.mojo`'s docstring states — the
call and its errors (O19), the refusal that keeps a function out of the
database file (O20), who destroys the state and when (O21), and the one
global word every callback reaches the library through (O22) — and
`poe sabotage-sqlite-function` reverts each rule and insists the test that
claims it fails. Counters live at heap addresses the functions hold, since
`call` borrows its instance immutably: the same way a real function would
own a side channel, and the only way a test can watch SQLite call it.

What no test here can hold, and why: the 3.30.0 floor (every library this
runs against is newer), and the compare-and-swap that publishes the word
(no single-threaded test can tell it from a store). Both are in the source,
each with its reason.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.os import getenv, remove, setenv, unsetenv
from std.os.path import exists
from std.sys import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from src import (
    SQLITE_BLOB,
    SQLITE_BUSY,
    SQLITE_FLOAT,
    SQLITE_INTEGER,
    SQLITE_MISUSE,
    SQLITE_TEXT,
    Answer,
    Args,
    Connection,
    ScalarFunction,
    error_code,
    open_memory,
)
from src.function import _fn_table
from src.lib import default_search_path

comptime _Word = Pointer[Int, MutUntrackedOrigin]


def _counter() -> Int:
    """A zeroed heap word a function can count into, by address."""
    var c = unsafe_alloc[Int](count=1)
    c[] = 0
    return Int(c)


def _read(counter: Int) -> Int:
    return _Word(unsafe_from_address=counter)[]


def _error_of(db: Connection, sql: String) -> String:
    """The error one query raises, or "" when it answers."""
    try:
        _ = db.query_scalar(sql)
        return String("")
    except e:
        return String(e)


def _exec_error(db: Connection, sql: String) -> String:
    """The error one script raises, or "" when it runs."""
    try:
        db.execute(sql)
        return String("")
    except e:
        return String(e)


# --- The functions under test -------------------------------------------------


struct AddN(ScalarFunction):
    comptime arity: Int = 1
    comptime deterministic: Bool = True
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def call(self, args: Args, mut answer: Answer) raises:
        answer.int(args.int(0) + self.n)


struct Echo(ScalarFunction):
    """Answers its argument back, in the storage class it arrived as."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(self, args: Args, mut answer: Answer) raises:
        var t = args.type(0)
        if t == SQLITE_INTEGER:
            answer.int(args.int(0))
        elif t == SQLITE_FLOAT:
            answer.float(args.float(0))
        elif t == SQLITE_TEXT:
            answer.text(args.text(0))
        elif t == SQLITE_BLOB:
            answer.blob(args.blob(0))
        else:
            answer.null()


struct Kinds(ScalarFunction):
    """Any number of arguments: one letter for each one's storage class."""

    comptime arity: Int = -1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(self, args: Args, mut answer: Answer) raises:
        var s = String("")
        for i in range(len(args)):
            var t = args.type(i)
            if t == SQLITE_INTEGER:
                s += "I"
            elif t == SQLITE_FLOAT:
                s += "F"
            elif t == SQLITE_TEXT:
                s += "T"
            elif t == SQLITE_BLOB:
                s += "B"
            elif args.is_null(i):
                s += "N"
        answer.text(s)


struct ByteSum(ScalarFunction):
    """The sum of a blob's bytes, read in place."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(self, args: Args, mut answer: Answer) raises:
        var total = 0
        for b in args.blob(0):
            total += Int(b)
        answer.int(total)


struct Boom(ScalarFunction):
    comptime arity: Int = 0
    comptime deterministic: Bool = False

    def __init__(out self):
        pass

    def call(self, args: Args, mut answer: Answer) raises:
        raise Error("boom from mojo")


struct Reach(ScalarFunction):
    """Reads an argument its arity does not give it."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(self, args: Args, mut answer: Answer) raises:
        answer.int(args.int(1))


struct Count[det: Bool](ScalarFunction):
    """Counts its calls into a word, and answers its argument."""

    comptime arity: Int = 1
    comptime deterministic: Bool = Self.det
    var counter: Int

    def __init__(out self, counter: Int):
        self.counter = counter

    def call(self, args: Args, mut answer: Answer) raises:
        var c = _Word(unsafe_from_address=self.counter)
        c[] = c[] + 1
        answer.int(args.int(0))


struct Tracked(ScalarFunction):
    """Counts its own destruction into a word.

    The word's address sits past three words of padding, on purpose. An
    allocator keeps its free-list links in the first words of a freed block,
    so with the address there a second destruction of a freed instance —
    the double free O21 forbids — wrote through a link instead of counting,
    and the test passed with the rule broken (found by its sabotage). Past
    the links, the freed instance still holds the address, and a second
    destruction counts.
    """

    comptime arity: Int = 0
    comptime deterministic: Bool = True
    var _links: Int
    var _links_too: Int
    var _past_the_links: Int
    var counter: Int

    def __init__(out self, counter: Int):
        self._links = 0
        self._links_too = 0
        self._past_the_links = 0
        self.counter = counter

    def __deinit__(deinit self):
        var c = _Word(unsafe_from_address=self.counter)
        c[] = c[] + 1

    def call(self, args: Args, mut answer: Answer) raises:
        answer.int(7)


# --- O19: the call ------------------------------------------------------------


def test_a_function_answers_from_its_own_state() raises:
    """Two registrations of one type are two instances, each reached by its
    own calls through `sqlite3_user_data`.

    covers: O19
    """
    var db = open_memory()
    db.create_function("add_five", AddN(5))
    db.create_function("add_ten", AddN(10))
    assert_equal(db.query_scalar("SELECT add_five(1)"), "6")
    assert_equal(db.query_scalar("SELECT add_ten(add_five(1))"), "16")


def test_every_storage_class_goes_in_and_comes_back() raises:
    """Each class arrives as itself and is answered as itself: an integer, a
    double, text with a character outside ASCII, a blob holding every byte
    value (0x00 included, so nothing treats it as a C string), and NULL. A
    variadic function sees each argument's class.

    covers: O19
    """
    var db = open_memory()
    db.create_function("echo", Echo())
    db.create_function("kinds", Kinds())
    db.create_function("byte_sum", ByteSum())
    assert_equal(
        db.query_scalar("SELECT kinds(1, 2.5, 'x', x'00ff', NULL)"), "IFTBN"
    )
    assert_equal(db.query_scalar("SELECT kinds()"), "")

    var q = db.prepare("SELECT typeof(echo(?1)), echo(?1)")
    q.bind_int(1, -7)
    assert_true(q.step())
    assert_equal(q.column_text(0), "integer")
    assert_equal(q.column_int(1), -7)
    q.reset()
    q.bind_float(1, 2.5)
    assert_true(q.step())
    assert_equal(q.column_text(0), "real")
    assert_equal(q.column_float(1), 2.5)
    q.reset()
    q.bind_text(1, "héllo")
    assert_true(q.step())
    assert_equal(q.column_text(0), "text")
    assert_equal(q.column_text(1), "héllo")
    q.reset()
    var every = List[UInt8]()
    var expected_sum = 0
    for i in range(256):
        every.append(UInt8(i))
        expected_sum += i
    q.bind_blob(1, every)
    assert_true(q.step())
    assert_equal(q.column_text(0), "blob")
    var back = q.column_blob(1)
    assert_equal(len(back), 256)
    for i in range(256):
        assert_equal(Int(back[i]), i)
    q.reset()
    q.bind_null(1)
    assert_true(q.step())
    assert_equal(q.column_text(0), "null")
    q.finalize()

    var s = db.prepare("SELECT byte_sum(?1)")
    s.bind_blob(1, every)
    assert_true(s.step())
    assert_equal(s.column_int(0), expected_sum)
    s.finalize()
    assert_equal(db.query_scalar("SELECT byte_sum(x'')"), "0")


def test_a_raise_is_the_statements_error() raises:
    """What `call` raises fails the statement with its own text and
    SQLITE_ERROR, and the connection answers the next statement.

    covers: O19
    """
    var db = open_memory()
    db.create_function("boom", Boom())
    var e = _error_of(db, "SELECT boom()")
    assert_true("boom from mojo" in e, e)
    assert_equal(error_code(e), 1)
    assert_equal(db.query_scalar("SELECT 1"), "1")


def test_sqlite_holds_the_arity_and_args_holds_the_index() raises:
    """A call with the wrong count is refused when it is prepared, because
    the type's `arity` is what was registered. An index past what a call
    passed is an error, never a read past `argv`, and so is `blob` of
    anything but a blob.

    covers: O19
    """
    var db = open_memory()
    db.create_function("add_n", AddN(1))
    var e = _error_of(db, "SELECT add_n(1, 2)")
    assert_true("wrong number of arguments" in e, e)
    db.create_function("reach", Reach())
    e = _error_of(db, "SELECT reach(1)")
    assert_true("argument 2 of a call with 1" in e, e)
    db.create_function("byte_sum", ByteSum())
    e = _error_of(db, "SELECT byte_sum('text')")
    assert_true("argument 1 is not a blob" in e, e)


def test_a_deterministic_call_with_constant_arguments_runs_once() raises:
    """The planner evaluates a deterministic call with constant arguments
    once per statement, and anything else once per row: so the flag is
    registered, and a function that moves must say it is not deterministic.

    covers: O19
    """
    var db = open_memory()
    var det = _counter()
    var moving = _counter()
    db.create_function("det", Count[True](det))
    db.create_function("moving", Count[False](moving))
    comptime rows = (
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c"
        " WHERE x < 100) "
    )
    assert_equal(db.query_scalar(rows + "SELECT sum(det(1)) FROM c"), "100")
    assert_equal(db.query_scalar(rows + "SELECT sum(moving(1)) FROM c"), "100")
    assert_equal(_read(det), 1)
    assert_equal(_read(moving), 100)


# --- O20: never part of the database file -------------------------------------


def test_the_schema_cannot_call_a_registered_function() raises:
    """Nothing the database file stores may call a registered function, so a
    schema never needs this binary to be written: SQLite refuses a CHECK
    constraint, a generated column and an expression index when they are
    created, a stored view when it is used, a trigger when it fires. A TEMP
    view, which lives on this connection alone, may.

    covers: O20
    """
    var db = open_memory()
    db.create_function("f", AddN(1))
    assert_equal(db.query_scalar("SELECT f(1)"), "2")

    var e = _exec_error(db, "CREATE TABLE t_check (x INTEGER CHECK (f(x) > 0))")
    assert_true("unsafe use of f()" in e, "CHECK: " + e)
    e = _exec_error(db, "CREATE TABLE t_gen (x INTEGER, y AS (f(x)))")
    assert_true("unsafe use of f()" in e, "generated column: " + e)
    db.execute("CREATE TABLE t (x INTEGER)")
    e = _exec_error(db, "CREATE INDEX t_f ON t (f(x))")
    assert_true("unsafe use of f()" in e, "expression index: " + e)

    db.execute("CREATE VIEW v_stored AS SELECT f(1) AS x")
    e = _error_of(db, "SELECT x FROM v_stored")
    assert_true("unsafe use of f()" in e, "stored view: " + e)
    db.execute(
        "CREATE TRIGGER t_after AFTER INSERT ON t BEGIN SELECT f(NEW.x); END"
    )
    e = _exec_error(db, "INSERT INTO t VALUES (1)")
    assert_true("unsafe use of f()" in e, "trigger: " + e)

    db.execute("CREATE TEMP VIEW v_temp AS SELECT f(1) AS x")
    assert_equal(db.query_scalar("SELECT x FROM v_temp"), "2")


# --- O21: SQLite owns the state -----------------------------------------------


def test_sqlite_destroys_the_state_exactly_once() raises:
    """From the call on, the instance is SQLite's: destroyed once when it is
    replaced, once when a registration is refused — by `create_function_v2`
    itself, which is why the package never frees on failure — and once at
    close. A registration refused before it reaches SQLite (a closed
    connection) destroys it the ordinary way.

    covers: O21
    """
    var n = _counter()
    var db = open_memory()
    db.create_function("t", Tracked(n))
    assert_equal(db.query_scalar("SELECT t()"), "7")
    assert_equal(_read(n), 0)

    db.create_function("t", Tracked(n))
    assert_equal(_read(n), 1, "a replaced instance is destroyed")

    var long_name = String("")
    for _ in range(256):
        long_name += "x"
    var refused = String("")
    try:
        db.create_function(long_name, Tracked(n))
    except e:
        refused = String(e)
    assert_equal(error_code(refused), SQLITE_MISUSE, refused)
    assert_equal(_read(n), 2, "a refused instance is destroyed once")

    var q = db.prepare("SELECT t() UNION ALL SELECT t()")
    assert_true(q.step())
    refused = String("")
    try:
        db.create_function("t", Tracked(n))
    except e:
        refused = String(e)
    assert_equal(error_code(refused), SQLITE_BUSY, refused)
    assert_true("active statements" in refused, refused)
    assert_equal(_read(n), 3, "refused under an active statement, destroyed once")
    q.reset()
    q.finalize()
    assert_equal(db.query_scalar("SELECT t()"), "7", "the first survives")

    db.close()
    assert_equal(_read(n), 4, "close destroys what is registered")
    refused = String("")
    try:
        db.create_function("t", Tracked(n))
    except e:
        refused = String(e)
    assert_true("closed connection" in refused, refused)
    assert_equal(_read(n), 5, "refused before SQLite saw it, destroyed once")


# --- O22: one word, one library -------------------------------------------------


def test_one_word_reaches_every_connection() raises:
    """Every connection's functions answer through the one published table,
    which outlives the connection that published it.

    covers: O22
    """
    var first = open_memory()
    first.create_function("add_one", AddN(1))
    var table = _fn_table()
    assert_true(table != 0)
    var second = open_memory()
    second.create_function("add_two", AddN(2))
    assert_equal(_fn_table(), table, "published once")
    assert_equal(first.query_scalar("SELECT add_one(1)"), "2")
    first.close()
    _ = first^
    assert_equal(second.query_scalar("SELECT add_two(1)"), "3")


def _second_image(current: String) raises -> String:
    """A libsqlite3 file that is not the image at `current`, or "" when there
    is none.

    Linux: a copy of the system library. A copy is a second image, because
    the loader identifies an object by its file, and a path with a slash
    never matches a loaded object's soname. macOS: whichever of Apple's and
    Homebrew's builds is not in use. Apple's lives in the dyld shared cache
    and has no file to copy, so without Homebrew's there is no second image.
    """
    comptime if CompilationTarget.is_macos():
        var brew = String("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib")
        if not exists(brew):
            return String("")
        return String("/usr/lib/libsqlite3.dylib") if current == brew else brew
    else:
        for p in default_search_path():
            if p.startswith("/") and exists(p):
                var copy = getenv("TMPDIR", "/tmp") + "/m0-sqlite-second-image.so"
                var data: List[UInt8]
                with open(p, "r") as f:
                    data = f.read_bytes()
                with open(copy, "w") as f:
                    f.write_bytes(Span(data))
                return copy
        return String("")


def test_a_second_libsqlite3_image_is_refused() raises:
    """A callback reaches one library, so a connection opened on another
    image may not register: its values would be read by the first image's
    entry points. Refused at registration, naming the connection's library.
    Where no second image exists (macOS without Homebrew's SQLite) this says
    so and asserts only the first half.

    covers: O22
    """
    var db = open_memory()
    db.create_function("add_one", AddN(1))
    var other = _second_image(db.library_path())
    if not other:
        print("    (no second libsqlite3 image here; the refusal is not exercised)")
        return
    var before = getenv("M0_LIBSQLITE3", "")
    _ = setenv("M0_LIBSQLITE3", other)
    var opened = String("")
    var refused = String("")
    try:
        var elsewhere = open_memory()
        opened = elsewhere.library_path()
        elsewhere.create_function("add_one", AddN(1))
    except e:
        refused = String(e)
    # Put the environment back before any assertion can end the test: the
    # tests after this one open the process's own library.
    if before:
        _ = setenv("M0_LIBSQLITE3", before)
    else:
        _ = unsetenv("M0_LIBSQLITE3")
    if other.endswith("m0-sqlite-second-image.so"):
        remove(other)
    assert_equal(opened, other, refused)
    assert_true("is not the image" in refused, refused)
    assert_true(other in refused, refused)
    assert_equal(db.query_scalar("SELECT add_one(1)"), "2")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
