"""Scalar functions written in Mojo (`function.mojo`): SPEC O19 to O22.

Each test holds one of the rules `function.mojo`'s docstring states — the
call and its errors (O19), what the schema may not do with a function and
what it still can (O20), who destroys the state and when (O21), and the one
global word every callback reaches the library through (O22) — and
`poe sabotage-sqlite-function` reverts each rule and insists the test that
claims it fails. A function's own state lives in its fields (`Tally`). The
counters the tests READ live at heap addresses the functions hold instead:
SQLite owns the instance, so a word outside it is the only way a test can
watch SQLite call it, or destroy it.

What no test here can hold, and why: the 3.31.0 floor (every library this
runs against is newer), the compare-and-swap that publishes the word (no
single-threaded test can tell it from a store), and the bound on `arity`
(a type outside it does not compile, so there is nothing to run). Each is
in the source with its reason. The refusal of a second libsqlite3 image
needs a process of its own, and is `test_one_image.mojo`.
"""

from std.collections.span import Span
from std.ffi import c_int, external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.os import getenv, remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from src import (
    SQLITE_BLOB,
    SQLITE_BUSY,
    SQLITE_FLOAT,
    SQLITE_INTEGER,
    SQLITE_MISUSE,
    SQLITE_OPEN_CREATE,
    SQLITE_OPEN_READWRITE,
    SQLITE_TEXT,
    Answer,
    Args,
    Connection,
    ScalarFunction,
    error_code,
    open_memory,
)
from src.function import _fn_table

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


def _scratch_db(name: String) raises -> String:
    """A database file of this process's own, absent: keyed to the pid, since
    two sessions' runs meet in one `$TMPDIR` (`test_file.mojo`'s reason)."""
    var path = (
        getenv("TMPDIR", "/tmp") + "/m0-sqlite-fn-"
        + String(Int(external_call["getpid", c_int]())) + "-" + name + ".db"
    )
    if exists(path):
        remove(path)
    return path


# --- The functions under test -------------------------------------------------


struct AddN(ScalarFunction):
    comptime arity: Int = 1
    comptime deterministic: Bool = True
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def call(mut self, args: Args, mut answer: Answer) raises:
        answer.int(args.int(0) + self.n)


struct Tally(ScalarFunction):
    """Keeps its state in its own fields: how many calls it has answered,
    and every argument it has seen, in a list that reallocates as it grows.
    Answers the sum of what it has seen, and raises on a negative argument
    AFTER recording it."""

    comptime arity: Int = 1
    comptime deterministic: Bool = False
    var calls: Int
    var seen: List[Int]

    def __init__(out self):
        self.calls = 0
        self.seen = List[Int]()

    def call(mut self, args: Args, mut answer: Answer) raises:
        self.calls += 1
        var v = args.int(0)
        self.seen.append(v)
        if v < 0:
            raise Error("negative after " + String(self.calls) + " calls")
        var total = 0
        for x in self.seen:
            total += x
        answer.int(total)


struct Echo(ScalarFunction):
    """Answers its argument back, in the storage class it arrived as."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
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

    def call(mut self, args: Args, mut answer: Answer) raises:
        var s = String("")
        for i in range(len(args)):
            # `is_null` first, so it answers both ways.
            if args.is_null(i):
                s += "N"
                continue
            var t = args.type(i)
            if t == SQLITE_INTEGER:
                s += "I"
            elif t == SQLITE_FLOAT:
                s += "F"
            elif t == SQLITE_TEXT:
                s += "T"
            elif t == SQLITE_BLOB:
                s += "B"
        answer.text(s)


struct ByteSum(ScalarFunction):
    """The sum of a blob's bytes, read in place."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        var total = 0
        for b in args.blob(0):
            total += Int(b)
        answer.int(total)


struct BlobThenText(ScalarFunction):
    """Takes its argument's bytes in place, then asks for the same argument
    as text: the order that left the span dangling."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        var bytes = args.blob(0)
        var s = args.text(0)
        answer.int(len(bytes) + len(s.as_bytes()))


struct Steady(ScalarFunction):
    """Answers 1 when its blob argument's bytes are where `blob` first found
    them, and what they were, after every other accessor has read it."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        var first = args.blob(0)
        var at = Int(first.unsafe_ptr())
        var before = 0
        for b in first:
            before += Int(b)
        var kind = args.type(0)
        var null = args.is_null(0)
        _ = args.int(0)
        _ = args.float(0)
        var again = args.blob(0)
        var after = 0
        for b in first:
            after += Int(b)
        var steady = (
            kind == SQLITE_BLOB
            and not null
            and Int(again.unsafe_ptr()) == at
            and len(again) == len(first)
            and after == before
        )
        answer.int(1 if steady else 0)


struct EmptyFrom[null: Bool](ScalarFunction):
    """Answers 1 when an empty blob arrives as an empty span whose pointer is
    not SQLite's NULL. With `null`, answers a zero-length blob from a span
    whose pointer is its integer argument: 0 makes the span C hands over
    for no bytes, which Mojo will not let a constant spell."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        comptime if Self.null:
            answer.blob(
                Span[UInt8, MutAnyOrigin](
                    unsafe_ptr=Pointer[UInt8, MutAnyOrigin](
                        unsafe_from_address=args.int(0)
                    ),
                    length=0,
                )
            )
        else:
            var bytes = args.blob(0)
            answer.int(1 if len(bytes) == 0 and Int(bytes.unsafe_ptr()) != 0 else 0)


struct Wide[n: Int](ScalarFunction):
    """A function of `n` arguments, for the arities a library refuses."""

    comptime arity: Int = Self.n
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        answer.int(len(args))


struct Boom(ScalarFunction):
    comptime arity: Int = 0
    comptime deterministic: Bool = False

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        raise Error("boom from mojo")


struct Reach(ScalarFunction):
    """Reads an argument its arity does not give it."""

    comptime arity: Int = 1
    comptime deterministic: Bool = True

    def __init__(out self):
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        answer.int(args.int(1))


struct Count[det: Bool](ScalarFunction):
    """Counts its calls into a word, and answers its argument."""

    comptime arity: Int = 1
    comptime deterministic: Bool = Self.det
    var counter: Int

    def __init__(out self, counter: Int):
        self.counter = counter

    def call(mut self, args: Args, mut answer: Answer) raises:
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

    def call(mut self, args: Args, mut answer: Answer) raises:
        answer.int(7)


struct Witness(ScalarFunction):
    """Counts its calls into one word and its destruction into another, and
    is never deterministic, so every row calls it. Both addresses sit past
    the allocator's links, for `Tracked`'s reason."""

    comptime arity: Int = 0
    comptime deterministic: Bool = False
    var _links: Int
    var _links_too: Int
    var _past_the_links: Int
    var calls: Int
    var destroyed: Int

    def __init__(out self, calls: Int, destroyed: Int):
        self._links = 0
        self._links_too = 0
        self._past_the_links = 0
        self.calls = calls
        self.destroyed = destroyed

    def __deinit__(deinit self):
        var c = _Word(unsafe_from_address=self.destroyed)
        c[] = c[] + 1

    def call(mut self, args: Args, mut answer: Answer) raises:
        var c = _Word(unsafe_from_address=self.calls)
        c[] = c[] + 1
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


def test_a_function_keeps_what_it_writes_to_itself() raises:
    """`call` takes `mut self`, and what it writes to its own fields is there
    for the next call: across the rows of one statement, across statements,
    across a list that reallocated, across a call that raised (what it wrote
    before raising stays written), and between an inner and an outer call of
    one expression. The trampoline hands `call` the instance SQLite holds,
    never a copy of it.

    covers: O19
    """
    var db = open_memory()
    db.create_function("tally", Tally())
    comptime rows = (
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c"
        " WHERE x < 200) "
    )
    assert_equal(db.query_scalar(rows + "SELECT max(tally(x)) FROM c"), "20100")
    var e = _error_of(db, "SELECT tally(-5)")
    assert_true("negative after 201 calls" in e, e)
    assert_equal(db.query_scalar("SELECT tally(0)"), "20095", "the raise lost its write")
    assert_equal(db.query_scalar("SELECT tally(tally(0) * 0 + 7)"), "20102")


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
    # An empty text is text, not NULL: "" alone cannot say which it was.
    assert_equal(db.query_scalar("SELECT typeof(kinds())"), "text")

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


def test_an_empty_blob_is_answered_as_a_blob() raises:
    """A zero-length blob goes in as an empty span and comes back as a
    zero-length BLOB, never as NULL. SQLite's own pointer for one is NULL
    (`sqlite3_value_blob` of `x''`), and `sqlite3_result_blob` answers NULL
    for a NULL pointer whatever the length. Two guards, each tested alone:
    `Args.blob` never hands the NULL out, and an answer of no bytes never
    hands one in, whatever span it was given. Then the two together: a
    literal, `zeroblob(0)`, one that was bound, and one stored in a column
    that refuses NULL.

    covers: O19
    """
    var db = open_memory()
    db.create_function("echo", Echo())
    db.create_function("byte_sum", ByteSum())
    db.create_function("arrives_empty", EmptyFrom[False]())
    db.create_function("answers_from_null", EmptyFrom[True]())
    assert_equal(db.query_scalar("SELECT arrives_empty(x'')"), "1")
    assert_equal(db.query_scalar("SELECT typeof(answers_from_null(0))"), "blob")
    assert_equal(db.query_scalar("SELECT typeof(echo(x''))"), "blob")
    assert_equal(db.query_scalar("SELECT length(echo(x''))"), "0")
    assert_equal(db.query_scalar("SELECT typeof(echo(zeroblob(0)))"), "blob")
    assert_equal(db.query_scalar("SELECT byte_sum(x'')"), "0")

    var q = db.prepare("SELECT typeof(echo(?1)), echo(?1) IS NULL")
    q.bind_blob(1, List[UInt8]())
    assert_true(q.step())
    assert_equal(q.column_text(0), "blob")
    assert_equal(q.column_int(1), 0)
    q.finalize()

    db.execute("CREATE TABLE b (v BLOB NOT NULL)")
    assert_equal(_exec_error(db, "INSERT INTO b VALUES (echo(x''))"), "")
    assert_equal(db.query_scalar("SELECT typeof(v) || length(v) FROM b"), "blob0")


def test_a_blob_span_stays_good_because_text_refuses_a_blob() raises:
    """`blob` hands out SQLite's own bytes, and nothing a function can then
    do moves them. Reading a BOUND blob as text reallocates it to add a
    terminator (sqlite3.h says a `sqlite3_value_blob` pointer "can be
    invalidated by a subsequent call to sqlite3_value_text()"), which left
    a span from `blob` pointing at freed memory, so `text` refuses a BLOB
    as `blob` refuses everything else. A blob read off a table page does
    not move, so the argument here is bound. Every other accessor leaves
    the bytes where they were.

    covers: O19
    """
    var db = open_memory()
    db.create_function("blob_then_text", BlobThenText())
    db.create_function("steady", Steady())
    var bytes = List[UInt8]()
    for i in range(4096):
        bytes.append(UInt8(i % 251))

    var q = db.prepare("SELECT blob_then_text(?1)")
    q.bind_blob(1, bytes)
    var refused = String("")
    try:
        _ = q.step()
    except e:
        refused = String(e)
    q.finalize()
    assert_true("argument 1 is a blob, which text() does not convert" in refused, refused)

    var s = db.prepare("SELECT steady(?1)")
    s.bind_blob(1, bytes)
    assert_true(s.step())
    assert_equal(s.column_int(0), 1, "an accessor moved a blob's bytes")
    s.finalize()

    # Text is still text to both: `text` of a number converts, `blob` of
    # anything but a blob does not.
    db.create_function("echo", Echo())
    assert_equal(db.query_scalar("SELECT echo('plain')"), "plain")
    var e = _error_of(db, "SELECT steady('text')")
    assert_true("argument 1 is not a blob" in e, e)


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
    """The schema never computes with a registered function: SQLite refuses
    one in a CHECK constraint, a generated column and an expression index
    when they are created, in a stored view when it is used, and in a
    trigger when it fires. Creating the view and the trigger is NOT refused
    (their bodies resolve when they run), which is what the next test is
    about. A TEMP view, which lives on this connection alone, may call it.

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


def test_a_trigger_naming_a_function_locks_its_table_for_every_writer() raises:
    """What `SQLITE_DIRECTONLY` cannot refuse: the CREATE of a trigger that
    names a registered function. The name is then in the database file, and
    every write to that table fails, from every program: "unsafe use" in
    the connection that registered the function, "no such function" in one
    that never heard of it — the `sqlite3` shell, a migration, a backup
    script. Reads still work, and dropping the trigger, which any writer
    can do, is what ends it. The flag makes the mistake loud at its first
    use; it does not make it impossible.

    covers: O20
    """
    var path = _scratch_db("trigger")
    var db = Connection(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    db.create_function("f", AddN(1))
    db.execute("CREATE TABLE t (x INTEGER)")
    db.execute("INSERT INTO t VALUES (1)")
    assert_equal(
        _exec_error(
            db, "CREATE TRIGGER t_after AFTER INSERT ON t BEGIN SELECT f(NEW.x); END"
        ),
        "",
        "creating the trigger is not refused",
    )
    var e = _exec_error(db, "INSERT INTO t VALUES (2)")
    assert_true("unsafe use of f()" in e, "the registering connection: " + e)

    # Another program: the same file, and no function.
    var other = Connection(path, SQLITE_OPEN_READWRITE)
    e = _exec_error(other, "INSERT INTO t VALUES (3)")
    assert_true("no such function: f" in e, "a connection without it: " + e)
    assert_equal(other.query_scalar("SELECT count(*) FROM t"), "1", "reads work")

    other.execute("DROP TRIGGER t_after")
    assert_equal(_exec_error(other, "INSERT INTO t VALUES (4)"), "")
    # The registering connection still holds the schema it read before the
    # drop, and the refusal is raised while the INSERT is compiled against
    # that copy, before anything compares it with the file: it stays locked
    # out until a statement that does run notices the schema changed.
    e = _exec_error(db, "INSERT INTO t VALUES (5)")
    assert_true("unsafe use of f()" in e, "before its schema is reread: " + e)
    assert_equal(db.query_scalar("SELECT count(*) FROM t"), "2")
    assert_equal(_exec_error(db, "INSERT INTO t VALUES (5)"), "")
    assert_equal(db.query_scalar("SELECT count(*) FROM t"), "3")
    other.close()
    db.close()
    remove(path)


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


def test_the_state_lives_until_the_last_statement_is_finalized() raises:
    """"Destroyed when the connection closes" is exact only with no statement
    outstanding. Every close here is `sqlite3_close_v2`, so a connection
    closed under a statement of its own lives on until that statement is
    finalized: the function still answers from it after `close()`, and the
    instance is destroyed at the finalize, not before.

    covers: O21
    """
    var calls = _counter()
    var destroyed = _counter()
    var db = open_memory()
    db.create_function("w", Witness(calls, destroyed))
    var q = db.prepare("SELECT w() UNION ALL SELECT w() UNION ALL SELECT w()")
    assert_true(q.step())
    assert_equal(_read(calls), 1)

    db.close()
    assert_equal(_read(destroyed), 0, "close() under a statement destroys nothing yet")
    assert_true(q.step())
    assert_equal(q.column_int(0), 7)
    assert_equal(_read(calls), 2, "the function answers after close()")
    assert_equal(_read(destroyed), 0)

    q.finalize()
    assert_equal(_read(destroyed), 1, "the last finalize destroys it")


def test_a_refusal_before_sqlite_and_a_refusal_in_its_own_words() raises:
    """A name SQLite would misread never reaches it: an empty one, and one
    holding a NUL byte, which a C string would end at, registering a
    different function. Each is refused naming the cause, and the instance
    is destroyed the ordinary way. A refusal SQLite makes without touching
    the connection's error state — `SQLITE_MISUSE`, for a name over 255
    bytes or an arity over the library's limit — is reported by its code's
    own text, never by the message the PREVIOUS statement left on the
    connection, and names the arity it registered.

    covers: O21
    """
    var n = _counter()
    var db = open_memory()
    var refused = String("")
    try:
        db.create_function("", Tracked(n))
    except e:
        refused = String(e)
    assert_true("the name is empty" in refused, refused)
    assert_equal(_read(n), 1, "refused before SQLite saw it, destroyed once")

    var bytes = List[UInt8]()
    bytes.append(97)
    bytes.append(98)
    bytes.append(0)
    bytes.append(99)
    var with_nul = String(unsafe_from_utf8=Span(bytes))
    refused = String("")
    try:
        db.create_function(with_nul, Tracked(n))
    except e:
        refused = String(e)
    assert_true("embedded null character" in refused, refused)
    assert_equal(_read(n), 2)
    var e = _error_of(db, "SELECT ab()")
    assert_true("no such function: ab" in e, "the name's head was registered: " + e)

    # Leave a message on the connection, then be refused without one.
    e = _error_of(db, "SELECT * FROM no_such_table")
    assert_true("no such table" in e, e)
    var long_name = String("")
    for _ in range(256):
        long_name += "x"
    refused = String("")
    try:
        db.create_function(long_name, Tracked(n))
    except e2:
        refused = String(e2)
    assert_equal(error_code(refused), SQLITE_MISUSE, refused)
    assert_false("no such table" in refused, "a stale message: " + refused)
    assert_true("misuse" in refused, refused)
    assert_equal(_read(n), 3)

    refused = String("")
    try:
        db.create_function("wide", Wide[32767]())
    except e3:
        refused = String(e3)
    assert_equal(error_code(refused), SQLITE_MISUSE, refused)
    assert_true("wide, arity 32767" in refused, refused)
    assert_false("no such table" in refused, "a stale message: " + refused)


# --- O22: one word, one library -------------------------------------------------


def test_one_word_reaches_every_connection() raises:
    """Every connection's functions answer through the one published table,
    which outlives the connection that published it and is never published
    again: a registration finds the word as an earlier one left it.

    covers: O22
    """
    var before = _fn_table()
    var first = open_memory()
    first.create_function("add_one", AddN(1))
    var table = _fn_table()
    assert_true(table != 0)
    if before != 0:
        assert_equal(table, before, "an earlier test's word was replaced")
    var second = open_memory()
    second.create_function("add_two", AddN(2))
    assert_equal(_fn_table(), table, "published once")
    assert_equal(first.query_scalar("SELECT add_one(1)"), "2")
    first.close()
    _ = first^
    assert_equal(second.query_scalar("SELECT add_two(1)"), "3")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
