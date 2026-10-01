"""Scalar functions written in Mojo, running inside SQLite's query plan.

    from m0_sqlite import Args, Answer, ScalarFunction, open_memory

    struct AddN(ScalarFunction):
        comptime arity: Int = 1              # -1: any number of arguments
        comptime deterministic: Bool = True  # same arguments, same answer
        var n: Int

        def __init__(out self, n: Int):
            self.n = n

        def call(self, args: Args, mut answer: Answer) raises:
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
fields, so there is no second form for one (D12's argument for `PageShell`).
The trait refines `Deinitable` because the instance is destroyed generically
— by SQLite's `xDestroy` — and on the error path of a refused registration.

**The type states its promises.** `arity` is what is registered, so SQLite
refuses a wrong call when the statement is prepared ("wrong number of
arguments to function add_n()"); `Args` still bounds-checks an index,
because a variadic function's code can reach past what a call passed.
`deterministic` lets the planner evaluate a call with constant arguments
once per statement rather than once per row. Both are `comptime` members,
so the promise sits beside the code that keeps it and a call site cannot
disagree with it.

**A registered function never becomes part of the database file.** Every
registration carries `SQLITE_DIRECTONLY`, so SQLite refuses the function in
anything the file stores: a CHECK constraint, a generated column or an
expression index when it is created, a view when it is used, a trigger when
it fires. Top-level SQL and this connection's TEMP views may call it. A
schema that called an m0 function would be writable only by the binary
that registered it — the `sqlite3` shell, a migration, a backup through
`VACUUM INTO` would all fail — and a database file handed over by someone
else could reach application code through its triggers. The flag arrived in
SQLite 3.30.0, so registration refuses an older library rather than
registering a function the schema could call (D59).

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
  - **One libsqlite3 image per process.** Registering on a connection whose
    library is not the one the word holds is refused, naming both: a
    callback of one image calling another image's entry points on its
    values is a crash in waiting. Compared by `SqliteFns.image`, never by
    path.
  - **It is the package's only global**, and it is never freed: a pinned
    library is never unloaded either, and the word must outlive every
    connection that can call through it.

**Ownership passes to SQLite at the call.** The instance moves into a heap
box whose address is `pApp`, and SQLite runs `_x_destroy[F]` on it exactly
once: when the function is replaced, when the connection closes, and —
from inside `create_function_v2` itself — when registration is refused. So
`_register_function` never frees on failure; freeing again would be a
double free (the rule `vtab.mojo`'s `_register` states for
`create_module_v2`).

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
    SQLITE_BLOB,
    SQLITE_NULL,
    SQLITE_OK,
    c_string,
    cstr_to_string,
    describe_in,
)
from .lib import SqliteFns, as_cstr, str_cstr

comptime SQLITE_MIN_FUNCTION_VERSION: Int = 3_030_000
"""SQLite 3.30.0, where `SQLITE_DIRECTONLY` arrived. A library older than
that cannot keep the promise that a registered function stays out of the
schema, so `Connection.create_function` refuses it rather than registering
a function the schema could call."""

comptime _SQLITE_UTF8: Int = 1
comptime _SQLITE_DETERMINISTIC: Int = 0x800
comptime _SQLITE_DIRECTONLY: Int = 0x80000

comptime _FnsPtr = Pointer[SqliteFns, MutUntrackedOrigin]
comptime _WordPtr = Pointer[Int, MutUntrackedOrigin]


# --- The one global word ------------------------------------------------------


@no_inline
def _fn_table_slot() -> Pointer[Int, MutUntrackedOrigin]:
    """Return the word holding the published table's address, 0 until then.

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
    """The published table's address as every callback reads it: 0 until the
    first registration in the process.

    Inlined, and that is safe: the word is `_fn_table_slot`'s, which is not.
    A second call per row here cost 1.3 ns of an 84 ns row on vecscan's
    scan, measured."""
    return _fn_table_slot()[]


def _publish(fns: SqliteFns, path: String) raises -> Int:
    """Publish the table the callbacks call through, once per process, and
    return its address.

    Compare-and-swap, because two pool threads may register at once; the
    loser frees its copy and takes the winner's. Then two checks, each of
    which a callback could not make for itself: that the word reads back
    through the callbacks' own accessor, and that the published table and
    `fns` come from one libsqlite3 image.
    """
    var word = _fn_table_slot()
    var slot = Pointer[Atomic[Int64], MutUntrackedOrigin](unsafe_from_address=Int(word))
    var current = Int(slot[].load())
    if current == 0:
        var copy = unsafe_alloc[SqliteFns](count=1)
        copy.unsafe_write(fns)
        var expected = Int64(0)
        if slot[].compare_exchange(expected, Int64(Int(copy))):
            current = Int(copy)
        else:
            # A table owns nothing, so freeing the copy destroys nothing.
            copy.unsafe_free()
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
    ref published = _FnsPtr(unsafe_from_address=current)[]
    if published.image() != fns.image():
        raise Error(
            "this connection's libsqlite3 (" + path + ", "
            + fns.libversion() + ") is not the image this process's"
            " functions were first registered against (" + published.libversion()
            + "): a callback reaches ONE library, so every connection that"
            " registers a function must open the same one (set M0_LIBSQLITE3"
            " once, before the first connection)"
        )
    return current


# --- The call ---------------------------------------------------------------


struct Args(Sized):
    """The arguments of one call: SQLite's own values, readable while it runs.

    Indexed from 0. Each accessor reads the value as SQLite converts it —
    `int` of a text answers what `CAST(x AS INTEGER)` would, `text` of NULL
    answers "" — except `blob`, which refuses anything but a BLOB. Read
    `type` first when the storage class matters. Valid only inside `call`:
    the values, and the bytes `blob` hands out, belong to the statement.
    """

    var _t: Int
    var _argc: Int
    var _argv: Int

    def __init__(out self, t: Int, argc: Int, argv: Int):
        """Wrap the `argc`/`argv` SQLite passed; `t` is the published table."""
        self._t = t
        self._argc = argc
        self._argv = argv

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
        """The storage class argument `i` arrived as: `SQLITE_INTEGER`,
        `SQLITE_FLOAT`, `SQLITE_TEXT`, `SQLITE_BLOB` or `SQLITE_NULL`.

        Ask before any other accessor reads it: a conversion can change what
        a later `type` answers (sqlite3.h, `sqlite3_value_type`)."""
        return _FnsPtr(unsafe_from_address=self._t)[].value_type(self._value(i))

    def is_null(self, i: Int) raises -> Bool:
        """Whether argument `i` is NULL."""
        return self.type(i) == SQLITE_NULL

    def int(self, i: Int) raises -> Int:
        """Argument `i` as an integer, converted as SQLite converts it."""
        return _FnsPtr(unsafe_from_address=self._t)[].value_int64(self._value(i))

    def float(self, i: Int) raises -> Float64:
        """Argument `i` as a double, converted as SQLite converts it."""
        return _FnsPtr(unsafe_from_address=self._t)[].value_double(self._value(i))

    def text(self, i: Int) raises -> String:
        """Argument `i` as text, copied; NULL reads as "" (see `is_null`).

        The pointer is asked for before the length, sqlite3.h's order, so the
        length measures the text form. The bytes are taken as they are, as
        `Statement.column_text` takes them: SQLite does not check that TEXT
        is valid UTF-8.
        """
        ref fns = _FnsPtr(unsafe_from_address=self._t)[]
        var v = self._value(i)
        var p = fns.value_text(v)
        return cstr_to_string(p, fns.value_bytes(v))

    def blob(self, i: Int) raises -> Span[UInt8, origin_of(self)]:
        """Argument `i`'s bytes where SQLite holds them: no copy.

        That is the whole win for a kernel over a large column. The span is
        valid for this call and no longer. Anything but a BLOB is refused
        rather than converted: a vector arriving as text or a number is the
        caller's bug, and SQLite's conversion would rewrite the value in
        place. The pointer is asked for before the length, sqlite3.h's order.
        A blob sits wherever its record put it in the page, so a kernel loads
        it with alignment 1.
        """
        ref fns = _FnsPtr(unsafe_from_address=self._t)[]
        var v = self._value(i)
        if fns.value_type(v) != SQLITE_BLOB:
            raise Error("argument " + String(i + 1) + " is not a blob")
        var p = Int(fns.value_blob(v))
        return Span[UInt8, origin_of(self)](
            unsafe_ptr=Pointer[UInt8, origin_of(self)](unsafe_from_address=p),
            length=fns.value_bytes(v),
        )


struct Answer:
    """What one call answers: NULL until a method sets it, and the last one set
    is the answer. Text and blobs are copied by SQLite before the method
    returns (`SQLITE_TRANSIENT`), so any buffer may be handed over."""

    var _t: Int
    var _ctx: Int

    def __init__(out self, t: Int, ctx: Int):
        """Wrap the `sqlite3_context *` SQLite passed; `t` is the published table."""
        self._t = t
        self._ctx = ctx

    def null(mut self):
        """Answer NULL."""
        _FnsPtr(unsafe_from_address=self._t)[].result_null(self._ctx)

    def int(mut self, value: Int):
        """Answer an integer."""
        _FnsPtr(unsafe_from_address=self._t)[].result_int64(self._ctx, value)

    def float(mut self, value: Float64):
        """Answer a double."""
        _FnsPtr(unsafe_from_address=self._t)[].result_double(self._ctx, value)

    def text(mut self, value: String):
        """Answer text."""
        _FnsPtr(unsafe_from_address=self._t)[].result_text(
            self._ctx, str_cstr(value), len(value.as_bytes())
        )

    def blob(mut self, value: Span[UInt8, _]):
        """Answer a blob."""
        _FnsPtr(unsafe_from_address=self._t)[].result_blob(
            self._ctx,
            value.unsafe_ptr().as_imm().as_unsafe_any_origin(),
            len(value),
        )


trait ScalarFunction(Movable, Deinitable):
    """A scalar SQL function written in Mojo, for `Connection.create_function`.

    The instance is the function's state; SQLite owns it from registration
    and destroys it when the function is replaced or the connection closes.
    """

    comptime arity: Int
    """How many arguments a call takes, or -1 for any number: registered, so
    SQLite refuses a call with another count when it prepares the statement."""

    comptime deterministic: Bool
    """True when the same arguments always give the same answer and the call
    has no effect but its answer. The planner then evaluates a call with
    constant arguments once per statement; a function that reads a clock, a
    counter or anything else that moves must say False."""

    def call(self, args: Args, mut answer: Answer) raises:
        """Answer one call. A raise fails the statement with its text."""
        ...


# --- What SQLite calls ------------------------------------------------------


def _x_scalar[F: ScalarFunction](ctx: Int, argc: c_int, argv: Int) abi("C"):
    """SQLite's `xFunc` for every function `F` implements: find the table and
    the instance, and answer the call, a raise becoming the statement's error.
    """
    var t = _fn_table()
    if t == 0:
        # Unreachable once a registration has read the word back, and there
        # is nothing to report with: reporting is a library call. NULL.
        return
    ref fns = _FnsPtr(unsafe_from_address=t)[]
    ref impl = Pointer[F, MutUntrackedOrigin](
        unsafe_from_address=fns.user_data(ctx)
    )[]
    var answer = Answer(t, ctx)
    try:
        impl.call(Args(t, Int(argc), argv), answer)
    except e:
        var message = String(e)
        fns.result_error(ctx, str_cstr(message), len(message.as_bytes()))
        _ = message


def _x_destroy[F: ScalarFunction](p: Int) abi("C"):
    """SQLite's `xDestroy`: run the instance's destructor and free its box.

    SQLite calls it exactly once per registration — on replacement, at close,
    and from inside `create_function_v2` when it refuses one.
    """
    var box = Pointer[F, MutUntrackedOrigin](unsafe_from_address=p)
    _ = box.unsafe_take_pointee()
    box.unsafe_free()


def _register_function[
    F: ScalarFunction
](fns: SqliteFns, path: String, db: Int, name: String, var impl: F) raises:
    """Register `impl` as `name` on the connection `db`, whose library is at
    `path`. See `Connection.create_function`."""
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
        raise Error(
            describe_in(
                "create_function_v2",
                rc,
                fns.errmsg(db),
                name,
                fns.errstr(rc),
            )
        )
