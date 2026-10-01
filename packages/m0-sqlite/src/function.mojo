"""Scalar functions written in Mojo, running inside SQLite's query plan.

    from m0_sqlite import Args, Answer, ScalarFunction, open_memory

    struct AddN(ScalarFunction):
        comptime arity: Int = 1              # -1: any number of arguments
        comptime deterministic: Bool = True  # same arguments, same answer
        var n: Int

        def __init__(out self, n: Int):
            self.n = n

        def call(mut self, args: Args, mut answer: Answer) raises:
            answer.int(args.int(0) + self.n)

    var db = open_memory()
    db.create_function("add_n", AddN(5))
    print(db.query_scalar("SELECT add_n(1)"))   # 6

A registered function runs inside the statement, on the thread stepping it,
once for every row the plan reaches it at. That is its reason to exist: it
reads each value where SQLite already holds it (`Args.blob` is SQLite's own
bytes, never a copy), so a kernel over a large column costs the kernel and
not a copy out of the database first. Measured on a 100,000-row table of
384-float embeddings: a dot product registered here scanned it in 8.57 ms,
within 1 % of the same function written by hand against the C API (8.49 ms;
0.8 ns a call, most of it the `sqlite3_user_data` call state costs), and
twice as fast as sqlite-vec's `vec_distance_l2` (18.0 ms), which copies both
vectors on every call (docs/notes/functions-inside-the-query.md).

**A type, not a function value.** A C callback cannot be a closure, so each
registered function needs its own `abi("C")` entry point. `_x_scalar[F]` is
one generic trampoline, instantiated per implementing type, and
`_x_destroy[F]` its destructor. The instance is the function's state and its
destruction as one value; a function that needs no state is a struct with no
fields, so there is no second form for one (the argument that made
`PageShell` a trait, docs/notes/the-page-shell-becomes-a-trait.md). On Mojo
1.1.0 a struct with no fields still writes its `def __init__(out self): pass`.
The trait refines `Deinitable` because the instance is destroyed generically
— by SQLite's `xDestroy` — and on the error path of a refused registration.

**The instance is the function's state, and `call` may write it.** `call`
takes `mut self`: a scratch buffer for a kernel, a cache keyed on a constant
argument, a counter, live in the struct's own fields and are there for the
next call, a call that raised included. That is sound because of how SQLite
calls a function, not because anything here locks: there is one instance
per registration per connection; calls on a connection are one at a time
(by SQLite's mutex on a serialized connection, by this package's
one-connection-per-thread rule otherwise); `f(f(x))` evaluates the inner
call to completion and then the outer; and a replacement is refused while a
statement is active. So nothing else touches the instance while `call` runs.

The one way to break it is to make the call re-entrant: a function that
steps a statement of its OWN connection which calls the same function. On
Mojo 1.1 that is unsound at any size
(docs/notes/mut-arguments-and-raw-addresses.md): an instance of 256 bytes
or less is copied in to `call` and stored back when it returns, so the
inner call's writes would be overwritten by the outer's store, silently;
a larger one is passed as a pointer the compiler takes to be unaliased, so
the outer call may go on using what it read before the inner one wrote.
`Args` carries no connection for that reason; do not hand a function one of
its own. For the same reason nothing reaches an instance by address while
it is registered: its state is its fields, read and written through `self`.

**The type states its promises.** `arity` is what is registered, so SQLite
refuses a wrong call when the statement is prepared ("wrong number of
arguments to function add_n()"); `Args` still bounds-checks an index,
because a variadic function's code can reach past what a call passed.
`deterministic` lets the planner evaluate a call with constant arguments
once per statement rather than once per row. Both are `comptime` members,
so the promise sits beside the code that keeps it and a call site cannot
disagree with it.

**The schema never computes with a registered function: SQLite refuses it
there, at use.** Every registration carries `SQLITE_DIRECTONLY`, so SQLite
refuses the function wherever the database file's own schema would call it:
in a CHECK constraint, a generated column or an expression index when it is
created; in a stored view when the view is used, in a trigger when it
fires, and in a column DEFAULT when an INSERT takes it. Top-level SQL and
this connection's TEMP views and triggers may call it. So no index,
constraint or stored column ever holds a registered function's results, and
a database file handed over by someone else cannot reach application code
through its schema.

What the flag cannot refuse is the CREATE of a view, a trigger or a column
DEFAULT that NAMES the function: SQLite resolves those when they run, not
when they are stored. `CREATE TRIGGER ... BEGIN SELECT dot(NEW.x); END`
succeeds, the name is in the file from then on, and every write to that
table fails for every writer — "unsafe use of dot()" in the binary that
registered it, "no such function: dot" in the `sqlite3` shell, Django or a
backup script — until someone drops the trigger. A DEFAULT does the same to
every INSERT that takes it, a view to every read of it. The refusal makes
the mistake loud at its first use instead of working in one binary; it does
not make it impossible. Do not name a registered function in any of the
three.

Two floors keep the promise, because SQLite came to it in three steps. The
flag arrived in 3.30.0, refusing only triggers and views; the refusal in a
CHECK constraint, a generated column and an index is 3.31.0's
(`sqlite3ExprFunctionUsable`), so registration refuses a library older than
that. And until 3.50.0 the refusal in a CHECK constraint reached only a
function registered DETERMINISTIC: `resolve.c` marked a call as coming from
the schema on its deterministic branch alone, so a function that says
`deterministic = False` was accepted in a CHECK and run by every write
(measured on 3.45.1 and 3.46.1: the table is created, the INSERT calls the
function). So a type whose `deterministic` is False is refused on a library
older than 3.50.0, rather than registered where a schema could compute with
it (D59). The kernel this exists for is deterministic and registers on
either.

**How a callback reaches the library: one global word.** The virtual table
needs no global (O18): SQLite hands `pAux` straight to `xConnect`. A scalar
function gets its `pApp` only through `sqlite3_user_data(ctx)`, which is
itself a library call, and this package opens the library at run time. So
the entry points sit behind one `pop.global_alloc` word holding a copy of
the connection's table — m0-http's `global_slot.mojo` idiom, copied since
this package imports nothing, and the shape of a C extension's global
`sqlite3_api`. Four rules come with it:

  - **Published once, by compare-and-swap.** Pool threads build their
    handlers at once (D31), so two may register together; the loser frees
    its copy. The word never changes after that, which is what lets a
    callback read it with a plain load: registration returned before any
    statement could call the function, on this thread or on one the
    connection was handed to.
  - **Read back before the first registration**, through `_fn_table`, the
    accessor every callback uses. `pop.global_alloc` is `Pure`, so an
    inlined copy of the accessor would make a global of its own; the
    `@no_inline` on `_fn_table_slot` is what keeps one word, and a toolchain
    that stopped honouring it is a refused registration here rather than
    callbacks reading zero. A callback that did read zero could not even
    report it, reporting being a library call: it answers NULL.
  - **One libsqlite3 image.** Registering through a table that is not of
    the image the word holds is refused, naming both files: a callback of
    one image calling another image's entry points on its values is a
    crash in waiting. Compared by `SqliteFns.image`, never by path. The
    loader already holds this package to one image (`lib.mojo`,
    `pin_library`), so no `Connection` can bring a second; this is the
    backstop behind it, for a table built any other way.
  - **It is one of the package's two globals** (the pinned library's word
    in `lib.mojo` is the other), and it is never freed: a pinned library is
    never unloaded either, and the word must outlive every connection that
    can call through it.

**Ownership passes to SQLite at the call.** The instance moves into a heap
box whose address is `pApp`, and SQLite runs `_x_destroy[F]` on it exactly
once: when the function is replaced, when the connection is destroyed, and
— from inside `create_function_v2` itself — when registration is refused.
So `_register_function` never frees on failure; freeing again would be a
double free (the rule `vtab.mojo`'s `_register` states for
`create_module_v2`).

**"Destroyed" is not always `close()`.** This package closes with
`sqlite3_close_v2`, which is what lets a `Statement` outlive its
`Connection` (O2), and a connection closed while a statement of its own is
outstanding lives on until the LAST of them is finalized. Until then its
functions stay callable from those statements, and the instances are
destroyed at that last finalize, on whichever thread finalizes. With no
statement outstanding, `close()` destroys them before it returns. An
instance whose destructor must run at a known point wants its connection's
statements finalized before the close.

**A raise is the statement's error.** The trampoline catches whatever
`call` raises and hands its text to `sqlite3_result_error`, so `step`
raises it (`sqlite3_step failed: <text> (rc=1)`). The `try` is not a
convention: an `abi("C")` function cannot raise, so the compiler holds it.

What a function must not do: I/O. It runs inside a statement, on a pool
thread, and inside a write it holds the database's write lock; a network
call there stalls every writer, and a function any SQL can call is a door
into the application for whoever writes the SQL. Nor can it query its own
connection: `Args` carries none.
"""

from std.atomic import Atomic
from std.collections.span import Span
from std.collections.string.string_span import _get_kgen_string
from std.ffi import c_int
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from .ffi import (
    MAX_C_INT,
    SQLITE_BLOB,
    SQLITE_NULL,
    SQLITE_OK,
    c_string,
    check_c_int_length,
    cstr_to_string,
    describe_in,
)
from .lib import SqliteFns, as_cstr, str_cstr

comptime SQLITE_MIN_FUNCTION_VERSION: Int = 3_031_000
"""SQLite 3.31.0, where `SQLITE_DIRECTONLY` came to refuse a function in a
CHECK constraint, a generated column and an index. 3.30.0 has the flag and
refuses only triggers and views with it, so a function registered there
could still be computed with by the schema; `Connection.create_function`
refuses a library older than this rather than register one."""

comptime SQLITE_MIN_MOVING_FUNCTION_VERSION: Int = 3_050_000
"""SQLite 3.50.0, where `SQLITE_DIRECTONLY` came to refuse a function that
is NOT deterministic in a CHECK constraint. Before it the constraint is
created and every write runs the function, so a type whose `deterministic`
is False is refused on an older library; a deterministic one needs only
`SQLITE_MIN_FUNCTION_VERSION`."""

comptime _SQLITE_UTF8: Int = 1
comptime _SQLITE_DETERMINISTIC: Int = 0x800
comptime _SQLITE_DIRECTONLY: Int = 0x80000

comptime _WordPtr = Pointer[Int, MutUntrackedOrigin]


struct _Published(Movable):
    """What the global word points at: the table every callback calls
    through, and the file it was loaded from, so the refusal of another
    image can name the one to keep. Written once and never freed."""

    var fns: SqliteFns
    var path: String

    def __init__(out self, fns: SqliteFns, path: String):
        self.fns = fns
        self.path = path


comptime _PublishedPtr = Pointer[_Published, MutUntrackedOrigin]


# --- The one global word ------------------------------------------------------


@no_inline
def _fn_table_slot() -> Pointer[Int, MutUntrackedOrigin]:
    """Return the word holding the published record's address, 0 until then.

    `@no_inline` IS LOAD-BEARING: `pop.global_alloc` is `Pure`, so every
    inlined copy of this accessor would make a global of its own, and the
    word the registration writes would not be the word the callbacks read.
    `_publish` reads it back to prove it is one word. m0-http's
    `src/global_slot.mojo` holds the measurement; this is a copy of that
    idiom, since this package imports nothing.
    """
    return {
        _mlir_value = __mlir_op.`pop.global_alloc`[
            name = _get_kgen_string["m0_sqlite_function_table"](),
            count = Int(1).__mlir_index__(),
            _type = Pointer[Int, MutUntrackedOrigin]._mlir_type,
            alignment = Int(8).__mlir_index__(),
        ]()
    }


@always_inline
def _fn_table() -> Int:
    """The published record's address (a `_Published`) as every callback
    reads it: 0 until the first registration in the process.

    Inlined, and that is safe: the word is `_fn_table_slot`'s, which is not.
    A second call per row here cost 1.3 ns of an 84 ns row on vecscan's
    scan, measured."""
    return _fn_table_slot()[]


def _publish(fns: SqliteFns, path: String) raises -> Int:
    """Publish the table the callbacks call through, once per process, and
    return the published record's address.

    Compare-and-swap, because two pool threads may register at once; the
    loser frees its record and takes the winner's. Then two checks, each of
    which a callback could not make for itself: that the word reads back
    through the callbacks' own accessor, and that the published table and
    `fns` come from one libsqlite3 image.
    """
    var word = _fn_table_slot()
    var slot = Pointer[Atomic[Int64], MutUntrackedOrigin](unsafe_from_address=Int(word))
    var current = Int(slot[].load())
    if current == 0:
        var record = unsafe_alloc[_Published](count=1)
        record.unsafe_write(_Published(fns, path))
        var expected = Int64(0)
        if slot[].compare_exchange(expected, Int64(Int(record))):
            current = Int(record)
        else:
            # The loser's record owns its copy of the path and nothing else.
            _ = record.unsafe_take_pointee()
            record.unsafe_free()
            current = Int(expected)
    if _fn_table() != current:
        raise Error(
            "the function table's global word did not read back through the"
            " accessor the callbacks use (wrote "
            + String(current)
            + ", read "
            + String(_fn_table())
            + "): this toolchain gives pop.global_alloc more than one word,"
            " so no callback could reach the library; nothing is registered"
        )
    ref published = _PublishedPtr(unsafe_from_address=current)[]
    if published.fns.image() != fns.image():
        raise Error(
            "this connection's libsqlite3 (" + path + ", "
            + fns.libversion() + ") is not the image this process's"
            " functions were first registered against (" + published.path
            + ", " + published.fns.libversion() + "): a callback reaches ONE"
            " library, so every connection that registers a function must"
            " open the same one (set M0_LIBSQLITE3 to " + published.path
            + " once, before the first connection)"
        )
    return current


# --- The call ---------------------------------------------------------------


struct Args(Sized):
    """The arguments of one call: SQLite's own values, readable while it runs.

    Indexed from 0. `int`, `float` and `text` read the value as SQLite
    converts it — `int` of a text answers what `CAST(x AS INTEGER)` would —
    with one difference from `CAST`: NULL reads as 0, 0.0 and "" where
    `CAST` answers NULL, as `Statement`'s column accessors do, so ask
    `is_null` when that matters. The two accessors that touch bytes are
    disjoint: `blob` refuses anything but a BLOB, and `text` refuses a BLOB.
    Valid only inside `call`: the values, and the bytes `blob` hands out,
    belong to the statement.
    """

    var _t: Int
    var _argc: Int
    var _argv: Int

    def __init__(out self, *, _table: Int, _argc: Int, _argv: Int):
        """The trampoline's (`_x_scalar`), and nobody else's: the published
        record's address and the `argc`/`argv` SQLite passed for one call.
        All three are raw addresses read without a check, so an `Args`
        built from anything else is a wild read."""
        self._t = _table
        self._argc = _argc
        self._argv = _argv

    def __len__(self) -> Int:
        """How many arguments this call passed."""
        return self._argc

    def _value(self, i: Int) raises -> Int:
        """The `sqlite3_value *` at `i`, or an error: an index past what the
        call passed is never read, since `argv` holds exactly `argc`."""
        if i < 0 or i >= self._argc:
            raise Error(
                "argument " + String(i + 1) + " of a call with "
                + String(self._argc)
            )
        return _WordPtr(unsafe_from_address=self._argv)[unsafe_offset=i]

    def type(self, i: Int) raises -> Int:
        """Argument `i`'s storage class as it is NOW: `SQLITE_INTEGER`,
        `SQLITE_FLOAT`, `SQLITE_TEXT`, `SQLITE_BLOB` or `SQLITE_NULL`.

        The class the argument arrived as only until something converts it
        (sqlite3.h, `sqlite3_value_type`). Nothing in this struct does —
        `text` of a number adds a text form and leaves the class, and the
        one conversion that would change it, a BLOB read as text, is
        refused — but the contract is SQLite's, so ask before reading."""
        return _PublishedPtr(unsafe_from_address=self._t)[].fns.value_type(
            self._value(i)
        )

    def is_null(self, i: Int) raises -> Bool:
        """Whether argument `i` is NULL."""
        return self.type(i) == SQLITE_NULL

    def int(self, i: Int) raises -> Int:
        """Argument `i` as an integer, converted as SQLite converts it.
        Answers 0 for NULL, where `CAST` answers NULL — see `is_null`."""
        return _PublishedPtr(unsafe_from_address=self._t)[].fns.value_int64(
            self._value(i)
        )

    def float(self, i: Int) raises -> Float64:
        """Argument `i` as a double, converted as SQLite converts it.
        Answers 0.0 for NULL, where `CAST` answers NULL — see `is_null`."""
        return _PublishedPtr(unsafe_from_address=self._t)[].fns.value_double(
            self._value(i)
        )

    def text(self, i: Int) raises -> String:
        """Argument `i` as text, copied; NULL reads as "" (see `is_null`).

        A BLOB is refused, as `blob` refuses everything else: reading one
        as text converts the value in place, which can free the bytes a
        span from `blob` points at (see there). For a blob's bytes as a `String`,
        copy the span. The pointer is asked for before the length,
        sqlite3.h's order, so the length measures the text form. The bytes
        are taken as they are, as `Statement.column_text` takes them: SQLite
        does not check that TEXT is valid UTF-8.
        """
        ref fns = _PublishedPtr(unsafe_from_address=self._t)[].fns
        var v = self._value(i)
        if fns.value_type(v) == SQLITE_BLOB:
            raise Error(
                "argument " + String(i + 1) + " is a blob, which text() does"
                " not convert; read it with blob()"
            )
        var p = fns.value_text(v)
        return cstr_to_string(p, fns.value_bytes(v))

    def blob(self, i: Int) raises -> Span[UInt8, origin_of(self)]:
        """Argument `i`'s bytes where SQLite holds them: no copy.

        That is the whole win for a kernel over a large column. The span is
        valid for this call and no longer. Anything but a BLOB is refused
        rather than converted: a vector arriving as text or a number is the
        caller's bug, and SQLite's conversion would rewrite the value in
        place. A blob sits wherever its record put it in the page, so a
        kernel loads it with alignment 1. A zero-length blob is an empty
        span.

        The span stays the value's own bytes for the whole call because
        nothing here can convert it. sqlite3.h: a `sqlite3_value_blob`
        pointer "can be invalidated by a subsequent call to
        sqlite3_value_bytes(), sqlite3_value_bytes16(),
        sqlite3_value_text(), or sqlite3_value_text16()". Measured, on
        3.46.1, 3.53.4 and 3.54.0, what `sqlite3_value_text` does to a blob
        depends on who holds its bytes. One the statement computed
        (`randomblob(4096)`) is reallocated to add a terminator, and a span
        taken before it points at freed memory. One that was BOUND gets a
        new buffer while the span goes on pointing at the binding's, alive
        but no longer the value's. One with room to spare, and one read off
        a table page, do not move, which is how this goes unseen. So `text`
        refuses a BLOB, and the length is asked for here, once, straight
        after the pointer and on a value already a blob, where it converts
        nothing.
        """
        ref fns = _PublishedPtr(unsafe_from_address=self._t)[].fns
        var v = self._value(i)
        if fns.value_type(v) != SQLITE_BLOB:
            raise Error("argument " + String(i + 1) + " is not a blob")
        var p = Int(fns.value_blob(v))
        var n = fns.value_bytes(v)
        if n <= 0:
            # SQLite's pointer for a zero-length blob is NULL, which a Mojo
            # pointer is never meant to be: an empty span of its own.
            return Span[UInt8, origin_of(self)]()
        return Span[UInt8, origin_of(self)](
            unsafe_ptr=Pointer[UInt8, origin_of(self)](unsafe_from_address=p),
            length=n,
        )


struct Answer:
    """What one call answers: NULL until a method sets it, and the last one set
    is the answer. Text and blobs are copied by SQLite before the method
    returns (`SQLITE_TRANSIENT`), so any buffer may be handed over. An empty
    text or blob is answered as that, never as NULL."""

    var _t: Int
    var _ctx: Int

    def __init__(out self, *, _table: Int, _ctx: Int):
        """The trampoline's (`_x_scalar`), and nobody else's: the published
        record's address and the `sqlite3_context *` SQLite passed for one
        call. Both are raw addresses, so an `Answer` built from anything
        else is a wild call."""
        self._t = _table
        self._ctx = _ctx

    def null(mut self):
        """Answer NULL."""
        _PublishedPtr(unsafe_from_address=self._t)[].fns.result_null(self._ctx)

    def int(mut self, value: Int):
        """Answer an integer."""
        _PublishedPtr(unsafe_from_address=self._t)[].fns.result_int64(
            self._ctx, value
        )

    def float(mut self, value: Float64):
        """Answer a double."""
        _PublishedPtr(unsafe_from_address=self._t)[].fns.result_double(
            self._ctx, value
        )

    def text(mut self, value: String) raises:
        """Answer text. Raises past `MAX_C_INT` bytes, the limit of the C
        `int` SQLite takes the length as."""
        var n = len(value.as_bytes())
        check_c_int_length("result_text", n)
        _PublishedPtr(unsafe_from_address=self._t)[].fns.result_text(
            self._ctx, str_cstr(value), n
        )

    def blob(mut self, value: Span[UInt8, _]) raises:
        """Answer a blob; an empty span answers a zero-length blob. Raises
        past `MAX_C_INT` bytes, as `text`."""
        check_c_int_length("result_blob", len(value))
        _PublishedPtr(unsafe_from_address=self._t)[].fns.result_blob(
            self._ctx,
            value.unsafe_ptr().as_imm().as_unsafe_any_origin(),
            len(value),
        )


trait ScalarFunction(Movable, Deinitable):
    """A scalar SQL function written in Mojo, for `Connection.create_function`.

    The instance is the function's state, which `call` may write; SQLite
    owns it from registration and destroys it when the function is replaced
    or the connection is destroyed — at `close()`, or at the last finalize
    of a statement that outlived it (the module docstring).
    """

    comptime arity: Int
    """How many arguments a call takes, or -1 for any number: registered, so
    SQLite refuses a call with another count when it prepares the statement.

    Anything outside -1..32767 does not compile. Inside it, the library's
    build decides: `SQLITE_MAX_FUNCTION_ARG` is 127 on Apple's build and
    1000 on Homebrew's, and a registration above it is refused at run time
    (`SQLITE_MISUSE`), so an arity over 127 is build-dependent."""

    comptime deterministic: Bool
    """True when the same arguments always give the same answer and the call
    has no effect but its answer. The planner then evaluates a call with
    constant arguments once per statement; a function that reads a clock, a
    counter or anything else that moves must say False. One that says False
    needs SQLite 3.50.0 (`SQLITE_MIN_MOVING_FUNCTION_VERSION`): an older
    library would let a CHECK constraint call it."""

    def call(mut self, args: Args, mut answer: Answer) raises:
        """Answer one call. A raise fails the statement with its text, and
        what the call wrote to `self` before raising stays written. Never
        re-entered: see the module docstring for the one way to arrange
        that, and why not to."""
        ...


# --- What SQLite calls ------------------------------------------------------


def _x_scalar[F: ScalarFunction](ctx: Int, argc: c_int, argv: Int) abi("C"):
    """SQLite's `xFunc` for every function `F` implements: find the table and
    the instance, and answer the call, a raise becoming the statement's error.

    `impl` is a reference into the box SQLite holds, never a copy: `call`
    writes the function's state through it.
    """
    var t = _fn_table()
    if t == 0:
        # Unreachable once a registration has read the word back, and there
        # is nothing to report with: reporting is a library call. NULL.
        return
    ref fns = _PublishedPtr(unsafe_from_address=t)[].fns
    ref impl = Pointer[F, MutUntrackedOrigin](
        unsafe_from_address=fns.user_data(ctx)
    )[]
    var answer = Answer(_table=t, _ctx=ctx)
    try:
        impl.call(Args(_table=t, _argc=Int(argc), _argv=argv), answer)
    except e:
        var message = String(e)
        # Clamped, not checked: there is nowhere left to raise to, and a
        # length that wrapped negative would mean "scan to the first NUL".
        fns.result_error(ctx, str_cstr(message), min(len(message.as_bytes()), MAX_C_INT))
        _ = message


def _x_destroy[F: ScalarFunction](p: Int) abi("C"):
    """SQLite's `xDestroy`: run the instance's destructor and free its box.

    SQLite calls it exactly once per registration — on replacement, when the
    connection is destroyed (its close, or the last finalize of a statement
    that outlived the close), and from inside `create_function_v2` when it
    refuses one.
    """
    var box = Pointer[F, MutUntrackedOrigin](unsafe_from_address=p)
    _ = box.unsafe_take_pointee()
    box.unsafe_free()


def _register_function[
    F: ScalarFunction
](fns: SqliteFns, path: String, db: Int, name: String, var impl: F) raises:
    """Register `impl` as `name` on the connection `db`, whose library is at
    `path`. See `Connection.create_function`."""
    comptime assert F.arity >= -1 and F.arity <= 32767, (
        "a ScalarFunction's arity is -1, for any number of arguments, or 0 to"
        " 32767"
    )
    # Refused before SQLite sees the name: `c_string` would end it at the
    # first NUL and register a different function, and an empty name is one
    # no SQL can call.
    var name_bytes = name.as_bytes()
    if len(name_bytes) == 0:
        raise Error("create_function: the name is empty")
    for i in range(len(name_bytes)):
        if name_bytes[i] == 0:
            raise Error(
                "create_function: the name has an embedded null character"
                " (at byte " + String(i) + ")"
            )
    _ = _publish(fns, path)
    var box = unsafe_alloc[F](count=1)
    box.unsafe_write(impl^)
    var flags = _SQLITE_UTF8 | _SQLITE_DIRECTONLY
    comptime if F.deterministic:
        flags |= _SQLITE_DETERMINISTIC
    var cname = c_string(name)
    var rc = fns.create_function_v2(
        db, as_cstr(cname), F.arity, flags, Int(box), _x_scalar[F], _x_destroy[F]
    )
    _ = cname
    if rc != SQLITE_OK:
        # No free here: create_function_v2 runs xDestroy on a refusal too
        # (sqlite3.h), so the box is already gone; freeing it again would be
        # a double free. Measured: a 256-byte name (SQLITE_MISUSE) and a
        # replacement under an active statement (SQLITE_BUSY) each destroy
        # the new instance exactly once.
        #
        # The connection's message only when its own code agrees with `rc`,
        # as `stmt_errmsg` reads it: a refusal that never reached the
        # connection's error state (SQLITE_MISUSE for the name or the arity)
        # leaves the PREVIOUS statement's message there.
        var detail = String("")
        if fns.errcode(db) == rc:
            detail = fns.errmsg(db)
        raise Error(
            describe_in(
                "create_function_v2",
                rc,
                detail,
                name + ", arity " + String(F.arity),
                fns.errstr(rc),
            )
        )
