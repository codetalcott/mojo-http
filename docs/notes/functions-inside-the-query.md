# Functions inside the query — 2026-09-30

`m0-sqlite` can now register a Mojo type as a scalar SQL function on a
connection, and the function runs inside SQLite's query plan, reading each
value where SQLite already holds it. SPEC O19 to O22 are its rows, D58 and
D59 its decisions. Building it turned up a defect in the loader that came
before it: on macOS, a process that closed all its connections and opened
another was running a second copy of SQLite. That is SPEC O23, fixed in the
same change. Two reviews before it merged found eight claims on this page
that the code or SQLite did not keep; [the last
section](#what-the-review-found) says which, and the page now states what
was measured.

## The question

Where does a kernel over a large column run — a vector distance over a few
hundred floats a row — when the data lives in SQLite? A private experiment
measured the answer on 100,000 rows of 384-float embeddings, unit-normalised
so a dot product is the cosine, against the ways a standard stack does it.
Three numbers from it decided this change:

- A Mojo function registered into SQLite, reading the blob SQLite hands it
  without copying, scanned the table in 8.36 ms. sqlite-vec's
  `vec_distance_l2` took 18.0 ms on the same plan, and its
  `vec_distance_cosine` 40.4 ms. The gap is not the language: sqlite-vec
  copies both vectors into fresh heap blocks on every call (the constant
  query vector included), and a Mojo function doing exactly that work ran
  at parity with it, 0.95 to 1.03 times.
- What a row costs is SQLite's own machinery, 68 ns a row scanned against a
  kernel of 15 to 20. So a function earns its place inside the query only
  where it saves a copy out of the database, or where the plan itself must
  call it. A function that does a small thing to a small value costs a call
  and saves nothing.
- Served, the in-table path answered 2.0 times the requests of a uvicorn
  process computing in numpy where the filter kept 1 % of rows, at 14 MB
  of private memory. At broader filters a copy of the vectors in RAM was
  faster, which is the shape the layer would take for search; the function
  is the path for selective queries and for kernels that must see the row.

Getting there took the connection's raw handle and six entry points this
package did not load, resolved by hand, plus a global of its own. This
change makes that path the package's.

## What was built

```mojo
struct Dot(ScalarFunction):
    comptime arity: Int = 2
    comptime deterministic: Bool = True

    def __init__(out self):     # Mojo 1.1.0 wants it written, fields or none
        pass

    def call(mut self, args: Args, mut answer: Answer) raises:
        answer.float(dot_f32(args.blob(0), args.blob(1)))

db.create_function("dot", Dot())
```

`packages/m0-sqlite/src/function.mojo` holds it; its docstring states every
rule below, and `Connection.create_function` is the one entry. Eleven entry
points joined `SqliteFns`, the package's one table.

**A type, not a function value.** A C callback cannot be a closure, so each
registered function needs an `abi("C")` entry of its own. One generic
trampoline, `_x_scalar[F]`, is instantiated per implementing type, with a
generic destructor beside it. The instance is the function's state and its
destruction as one value; a function with no state is a struct with no
fields, which is why there is no second form for one — the argument that
made `PageShell` a trait
([the-page-shell-becomes-a-trait](the-page-shell-becomes-a-trait.md)),
again. Two facts of Mojo 1.1 came with it, both found by the
compiler: the trait refines `Deinitable`, because the instance is destroyed
generically and on the error path of a refused registration, and `Args`
conforms to `Sized` for `len(args)`.

**`call` takes `mut self`.** The first version borrowed the instance
immutably, which left a function with any state of its own — a scratch
buffer for a kernel, a cache keyed on a constant argument, a counter — no
sanctioned place to keep it, and the package's own tests reaching heap
words by raw address, the shape
[mut-arguments-and-raw-addresses](mut-arguments-and-raw-addresses.md) warns
about. The review asked for the decision before the API was public, since
changing it later breaks every implementer. It is sound by SQLite's
contract rather than by a lock: one instance per registration per
connection, calls on a connection one at a time, `f(f(x))` evaluated inner
then outer, and a replacement refused while a statement is active. Probed
before it was adopted, at `-O0` and at the default, under `mojo run` and
built: a counter and a list that reallocates keep what a call wrote across
200 rows, across statements, across a call that raised after writing, and
between the inner and outer call of one expression, for instances of 8
and 24 bytes (copied in and stored back on Mojo 1.1) and one of 328 (passed
by pointer). The one way to break it is a function that steps a statement of
its own connection which calls it again: the inner call's writes would be
overwritten by the outer's store-back. `Args` carries no connection, and a
function must not be handed one of its own.

**A call inside a call is refused.** "Must not" was all that held that
rule, and the public API alone breaks it: register a placeholder under the
name, `prepare("SELECT f(?)")` against it, then replace the placeholder
with an instance that holds the statement. Measured that way before the
guard, a counter that adds 1 on entry and 100 on exit answered 101 where a
sound call answers 202, for an instance of 16 bytes and one of 440 alike,
and a `List` field kept 2 of 4,100 appends. Nothing crashed, under `mojo
run`, built or under guard malloc, so the loss was silent. Now the
instance sits in a box beside one word (`_Guarded`): the trampoline sets
it for the length of `call`, and a call that finds it set fails its
statement with "a scalar function was called again while a call on it was
in progress". The outer call sees that as the error of the statement it
stepped, its own state is as it left it, and the word clears when the
outer call ends, a raise included. It is per instance, so a function that
steps a statement calling ANOTHER function is not refused, and two that
call each other are refused at the second entry of the first.

**The type states its promises**, as `comptime` members a call site cannot
disagree with. `arity` is registered, so SQLite refuses a wrong call when it
prepares the statement; `Args` still bounds-checks an index, since a
variadic function's code can reach past what a call passed. An arity
outside -1..32767 does not compile; inside it the library's build decides
(`SQLITE_MAX_FUNCTION_ARG` is 127 on Apple's and 1000 on Homebrew's), and a
registration above that is refused at run time. `deterministic` changes the
plan: a call with a constant argument over 100 rows ran once with the flag
and 100 times without.

**Arguments are SQLite's own values.** `blob` hands out a span over SQLite's
bytes, valid for the call — the whole point — and refuses anything but a
BLOB, since a vector arriving as text or a number is the caller's bug and
SQLite's conversion would rewrite the value in place. `text` refuses a BLOB
for the same reason seen from the other side: sqlite3.h says a
`sqlite3_value_blob` pointer "can be invalidated by a subsequent call to
sqlite3_value_text()". Measured on 3.46.1, 3.53.4 and 3.54.0 with a
function that takes the pointer, asks for the text and looks again, what
happens depends on who holds the bytes. A blob the statement computed
(`randomblob(4096)`) is reallocated to add a terminator, and the old bytes
are gone: a span taken a line earlier points at freed memory. A blob that
was BOUND gets a new buffer while the old pointer is still the binding's,
its bytes intact: the span is alive and no longer the value's. A blob with
room to spare, and one read off a table page, do not move, which is how the
first tests missed it. So the accessor that hands out a pointer and the
accessor that converts are disjoint, and nothing a function can call
converts a value under a span it holds. `int` and `float` convert as `Statement`'s column accessors do,
NULL reading as 0 and 0.0 where `CAST` would answer NULL. Answers copy
(`SQLITE_TRANSIENT`), and an empty blob is answered as a blob: SQLite's own
pointer for `x''` is NULL, and `sqlite3_result_blob` answers SQL NULL for a
NULL pointer whatever the length, so that pointer is neither handed out nor
handed back. A raise becomes `sqlite3_result_error`, so `step` raises the
function's own text; the `try` around the call is not a convention, because
an `abi("C")` function cannot raise and the compiler holds it.

## What the schema may not do with one (D59)

Every registration carries `SQLITE_DIRECTONLY`. Measured on Apple's 3.54.0
and Homebrew's 3.53.4, SQLite then refuses the function in a CHECK
constraint, a generated column and an expression index **when they are
created**, in a stored view **when it is used**, in a trigger **when it
fires** and in a column DEFAULT **when an INSERT takes it**; top-level SQL
and a TEMP view or trigger may call it. So the schema never computes with a
registered function — no index, constraint or stored column holds its
results — and a database handed over by someone else cannot reach
application code through its schema. Rules every writer must obey belong in
the schema as built-in SQL.

What the flag does not do is keep the NAME out of the file. SQLite resolves
a view, a trigger and a DEFAULT when they run, not when they are stored, so
`CREATE TRIGGER ... BEGIN SELECT f(NEW.x); END` succeeds, and from then on
every INSERT on that table fails, from every program: "unsafe use of f()"
in the connection that registered `f`, "no such function: f" in the
`sqlite3` shell, Django or a backup script. Reads still work, and any
writer can drop the trigger. One more turn, measured while writing the
test: after another connection drops it, the registering connection goes on
failing, because the refusal is raised while the INSERT is compiled against
the schema that connection already holds, before anything compares it with
the file; the next statement that does run rereads the schema and the
table is writable again. The flag makes the mistake loud at its first use.
It does not make it impossible, and the first draft of this page said it
did.

The flag arrived in SQLite 3.30.0, where it refused only triggers and
views; the refusal at CREATE of a constraint, a generated column or an
index is 3.31.0's (`sqlite3ExprFunctionUsable`). Registration refuses a
library older than 3.31.0 rather than trusting it.

A second floor, found by the second review. The same thirteen statements
run for a deterministic function and one that is not, on 3.45.1 (Ubuntu
24.04), 3.46.1, 3.53.4 and 3.54.0, agree everywhere but one cell: on the
two older libraries `CREATE TABLE c (x INTEGER CHECK (moving(x) > 0))`
succeeds for a function registered without the deterministic flag, and the
INSERT that follows runs it. Until 3.50.0 `resolve.c` marked a call as
coming from the schema only on its deterministic branch (the comment beside
it reads "Curiously, they can be used in a CHECK constraint"), so the flag
never saw that call; a generated column or an index refuses a
non-deterministic function on its own, and a view and a trigger were
refused at use either way. That one cell is the promise: a CHECK in a file
from elsewhere would have run an application's counter or clock. So a type
that says `deterministic = False` is refused on a library older than
3.50.0. It costs such a function Ubuntu 24.04's and Debian 12's system
SQLite; the kernel over a column this exists for is deterministic, and
registers there.

That is also the answer to which application concerns a function serves.
Auth keeps nothing at rest for SQL to check (D24, D25, D53), and the rows a
user may see are a bound parameter. Rendering and escaping belong to
`Fragment`, and a validator is a hash of the rendering cached by a change
clock. I/O inside a statement holds a pool thread, and inside a write the
database's write lock. None of them is a function; a kernel over a column
is.

## Who owns the state

The instance moves into a heap box whose address is the function's user
data, and from then on SQLite decides: it runs the destructor exactly once,
when the function is replaced, when the connection is destroyed, and — from
inside `create_function_v2` itself — when it refuses a registration.
Measured: a 256-byte name (`SQLITE_MISUSE`) and a replacement while a
statement is active (`SQLITE_BUSY`, "unable to delete/modify user-function
due to active statements") each destroy the new instance once. So the
package never frees on failure, the rule `vtab.mojo` already states for
`create_module_v2`.

"When the connection is destroyed" is `close()` only with no statement
outstanding. Every close here is `sqlite3_close_v2`, the call that lets a
`Statement` outlive its `Connection` (O2), and it leaves a connection that
still has a statement alive until the last one is finalized. Until then the
function answers from those statements, and the instance is destroyed at
that last finalize, on whichever thread finalizes. The same fact counts
against a commit hook, [further down](#the-two-callbacks-measured).

Two more things about a refusal. `SQLITE_BUSY` is the one code this package
otherwise means "retry" by, and for a replacement it is not retryable: the
statement in the way is the caller's own, and no wait clears it. And
`SQLITE_MISUSE` — a name over 255 bytes, an arity over the library's limit
— is returned without touching the connection's error state, so the
message SQLite holds is the PREVIOUS statement's: the refusal is told in
the code's own words unless the connection's code agrees, the rule
`stmt_errmsg` already keeps. A name that is empty or holds a NUL byte never
reaches SQLite at all, which would have registered a different function for
the second (Python's `sqlite3` says "embedded null character").

## One word, and why the virtual table needed none

`m0_array`'s callbacks reach the library without a global: SQLite hands
`pAux` straight to `xConnect`. A scalar function's user data comes back only
through `sqlite3_user_data(ctx)`, which is itself a call into the library
this package opens at run time — so the entry points sit behind one
`pop.global_alloc` word, as a C extension's do behind its global
`sqlite3_api`. The word holds a copy of the table and the file it came
from, published once per process by compare-and-swap (pool threads build
their handlers at once, D31), and read back through the callbacks' own
accessor before the first registration: removing `@no_inline` from the
accessor, the sabotage, gives the writer and the reader different words
("wrote 4521148416, read 0"), and the registration is refused instead of
every callback reading zero. A table of another libsqlite3 image may not
register, since a callback reaches one library; images are compared by an
entry point's address, never by path, and the refusal names the file to
keep. Since the loader came to refuse a second image itself (below), no
`Connection` can bring one, and this check is the backstop behind it. The
package has two such words now, this one and the loader's.
An application's conformance compiled against
`m0_sqlite.mojoc`, rather than the package's source, registers and answers
(`poe check-sqlite-function`), which is where a lost witness table (the D28
bug) or a word that did not survive the precompile would show.

## The defect it found: two copies of SQLite (O23)

The one-image check refused a registration on the SAME library in the
registration tests, run against Homebrew's build. The loader opened a new
image at every reopen: `sqlite3_libversion` 1.3 MB further along each time,
and dyld's image count back where it started after each close. The cause
was the pin. On macOS an image opened `RTLD_NODELETE` stays mapped after
its last `dlclose` — so the table copies a `Statement` holds kept working,
and O18 held — but drops out of dyld's list, and the next `dlopen` of the
same path maps a fresh copy. Measured directly: a plain open and close,
then an open, gave one image; a `RTLD_NODELETE` open and close, then an
open, gave two; a handle kept open gave one, however many opens followed.
Apple's library lives in the dyld shared cache, where no image is dropped,
and glibc keeps a `RTLD_NODELETE` object findable, which is why no gate
saw it.

Two copies of SQLite in one process is the corruption SQLite's own
documentation names ("How To Corrupt An SQLite Database File", 2.2.1): each
copy keeps its own list of open files, so a close through one drops the
POSIX locks the other holds on the same file. Here it took a statement
outliving every connection while a new one opened the same database — rare
in a server, routine in a script. `pin_library` now keeps one handle open
for the life of the process, named by a second word; the reopen then finds
the same image, and dyld's count stays put.

### One image, enforced, and the copy it cannot see

The first version of the fix kept a handle per image and went on opening
whatever library the next connection named, so "one image per process" was
true of a reopen and false of a process that changed `M0_LIBSQLITE3`, or
opened Apple's library and then Homebrew's. The row said more than the code
did. Now the first library a process opens is the only one this package
opens: `open_library` refuses a library whose image is not the pinned one,
naming both files, and refuses it before pinning it, so the refused library
unloads with its handle (the version floor and the thread-safety check moved
before the pin for the same reason, and everything asked of a library is
asked before the first branch that can close it — a call through its table
from inside the error message was a call into unmapped memory, found when a
test did exactly that).

What the package cannot refuse is a copy something else brought. One case
is routine: CPython's `sqlite3`. The interpreters uv installs carry their
own SQLite inside `_sqlite3`, with no libsqlite3 file for the loader to
share, so `m0serve` serving a Mojo mount on m0-sqlite beside a Django
application on the stdlib backend is two copies of SQLite in one process
whatever `M0_LIBSQLITE3` says. That is safe exactly as long as the two
never open the same database file. Where the interpreter links a libsqlite3
file (Debian's and Ubuntu's `python3` link the system's), this package
opening that same file gives one image.

For that copy, every handle is opened `RTLD_LOCAL`. `OwnedDLHandle`'s
default is `RTLD_GLOBAL`, and an image in the loader's global scope captures
the internal calls of any libsqlite3 loaded after it: on Ubuntu 24.04 (both
architectures, SQLite 3.45.1), a copy loaded beside a first image that was
global answered "no such vfs" to every open, its `sqlite3_initialize` having
resolved into the first image, and opened normally once the first was local.
Debian 12's build (3.40.1) opened either way, which is why a container on
Debian did not show what the Ubuntu runner did, and macOS's two-level
namespaces never bind that way.

## The sabotage that passed

`poe sabotage-sqlite-function` reverts each rule by an exact source line
and runs the test claiming it: DIRECTONLY, the arity, the index check, the
blob check, the deterministic flag, the error path, the refused
registration's ownership, `@no_inline`, the image check and the kept handle.
Its first run caught nine of ten. The miss was ownership: a second free of
a refused registration's box, and a second destruction read out of the
freed block, left the test green. The allocator keeps its free-list links
in the first words of a freed block, and the test function's counter
address sat there, so the second destruction incremented a link rather than
the counter, and the double free went unreported (macOS's allocator does
not check; `MallocScribble=1` did not help, the links being written over
the scribble). The fixture now holds the address past three words of
padding, the second destruction counts, and the sabotage is caught. Ten of
ten then; twenty-two rules after the reviews, since each thing they found
became a rule with a test that fails without it. Four kinds are observable
only on some hosts and report SKIPPED, never caught, elsewhere: the image
rules need a second image to load (a copy of the library on Linux,
Homebrew's build on macOS), the kept handle needs macOS with a library
backed by a file, the two `RTLD_LOCAL` rules need a build that binds
through the global scope, which the harness asks the host about with a
probe of its own, and the floor for a function that is not deterministic
needs a library older than 3.50.0.

The second miss was the same lesson. A zero-length blob is guarded twice,
where it is handed out and where it is handed back, and with either guard
reverted the other kept the first test green. Each has its own assertion
now: a function that checks the span it was given, and one that answers
from a span whose pointer really is NULL.

## What it costs

On the same 100,000 rows, `m0_cos` written by hand against the C API and
the same kernel behind `create_function`, alternating which runs first,
p50 over ten passes of 100 queries: 8.49 against 8.57 ms unfiltered, 0.8 ns
a call, about 1 % of the row; within the noise at 10 % and 1 % of rows.
The first version cost 1.3 ns a call more: the read of the word went
through two calls the inliner could not see through, and only the inner
one's `@no_inline` is load-bearing. What remains is mostly the
`sqlite3_user_data` call that state costs and the hand-written function did
not make.

The re-entry guard came later and costs about 0.6 ns a call: `SELECT
sum(add_n(x))` over 2,000,000 rows, best of 15 passes, two binaries
alternating over six rounds, 16.35 to 16.47 ns a row without it and 16.92
to 17.04 with it, every guarded run slower than every plain one. The same
query computing `x + 1` inline took 15.3 ns a row, so the call itself is
1.0 to 1.2 ns without the guard and 1.6 to 1.7 with it. The figures above
predate it.

That figure moves with the machine more than with the code. Measured again
after the review's changes, three binaries interleaved over three rounds —
the first version, the fixed one, and the fixed one with `mut self` — gave
1.6 to 2.5, 2.3 to 2.5 and 1.9 to 2.1 ns a call over the hand-written
function (8.03 to 8.11 ms against 8.25 to 8.31), and the binary that had
measured 0.8 measured 2.3 and 2.4 in the same session. So: one to three
percent of the row, the three indistinguishable, and no cost found for the
type check `text` gained, the record the word now points at, the empty-blob
guards, or the instance being written rather than read.

## What is not built

Each waits for an application that needs it:

- **Aggregates and window functions.** Per-group state lives in memory
  SQLite frees without running a Mojo destructor, and nothing here has
  checked whether `xFinal` runs when a statement is reset mid-group.
- **A function the schema may call** (`SQLITE_INNOCUOUS`): D59's retiring
  condition, an application that needs one in an index or a generated
  column.
- **A function that is not deterministic on a library older than 3.50.0**:
  D59's second retiring condition, added 2026-10-01. Then the choice is an
  opt-in by name with the hole documented, or pointing `M0_LIBSQLITE3` at
  a newer build.
- **Subtypes**, which matter only for interop with sqlite-vec's typed
  values; **auxiliary data** (a per-statement cache of something derived
  from a constant argument), once a function measures that preparation
  above a row's noise; **collations**, once a listing needs an order
  `BINARY` and `NOCASE` cannot give; removing a function, which replacement
  covers.
- **A deadline on a statement**, by SQLite's progress handler. Waits for a
  query on the layer whose worst case outlives its request, and will be
  built around a step, as the next section measures.

A commit hook counting a connection's own commits was on this list until
2026-10-01. A change clock does not need one, and it will not be built; the
next section has the measurement.

## The two callbacks, measured

The first version of this page listed two connection callbacks as waiting
for an application: a commit hook, so a change clock would count a
connection's own commits without the caller saying it wrote, and a progress
handler holding a request's deadline. Both were measured on 2026-10-01
against the registration work as merged, on Apple's 3.54.0 and Homebrew's
3.53.4, and on no Linux build. Neither is built. No row or gate holds what
follows; the gates land with the code that relies on it.

### A change clock needs no commit hook

`PRAGMA data_version` moves when another connection commits to the file and
stays put for a connection's own writes, on every statement below. The hook
was to supply those. A second connection to the same file, opened
read-only, sees the writer's commits as it sees anyone's. One writer in WAL
mode with a hook counting into a word, and one read-only connection, the
same on both libraries:

| statement on the writer | hook | read-only connection's `data_version` | `total_changes` |
|---|---|---|---|
| `CREATE TABLE` | +1 | moved | +0 |
| a read | +0 | same | +0 |
| `INSERT`, autocommit | +1 | moved | +1 |
| `BEGIN`, three `INSERT`s, `COMMIT` | +1 | moved | +3 |
| `BEGIN`, `INSERT`, `ROLLBACK` | +0 | same | +1 |
| `BEGIN IMMEDIATE; COMMIT`, nothing written | +1 | same | +0 |
| `UPDATE` matching no row | +1 | same | +0 |
| a TEMP table: create and insert | +2 | same | +1 |
| a write to an `ATTACH`ed file | +2 | same | +1 |
| `PRAGMA user_version = 7` | +1 | moved | +0 |
| `ALTER TABLE ADD COLUMN` | +1 | moved | +0 |
| `VACUUM` | +0 | moved | +0 |
| `PRAGMA wal_checkpoint(TRUNCATE)` | +0 | moved | +0 |
| a `PASSIVE` or `RESTART` checkpoint, an automatic one | +0 | same | +0 |

The read-only connection moved for every statement that changed the main
database file, and for one that did not, a checkpoint that truncates the
log. The hook counted four statements that changed nothing in that file and
did not count `VACUUM`, which can renumber the rowids of a table declared
without an `INTEGER PRIMARY KEY`. `sqlite3_total_changes` misses a schema
change and counts a row that was rolled back. A clock that moves once too
often costs a cache one render; a clock that stays put after a change
serves stale data.

A hook also has a lifetime the package cannot manage after the fact. Every
close here is `sqlite3_close_v2`, and a statement that outlives its
connection still commits through it and still fires its hook. Asked through
the closed handle, `sqlite3_commit_hook` answered 0 and removed nothing: the
next commit through the outliving statement fired the hook again. So the
word a hook counts into would have to be freed only after a removal made
before the close, and a write to it after that is visible only to an
allocator that traps one, which is how the ownership test here missed a
double free.

Two rules for whoever builds the clock:

- **Read it on a connection that does not write.** `open_readonly` makes
  that structural.
- **Fill the cache through that same connection.** With the writer holding
  a statement open while another connection committed, the writer's own
  `data_version` and its `count(*)` both stayed at the old snapshot, and the
  read-only connection's clock had already moved. A cache filled through
  one connection and stamped with the other's clock pairs an old rendering
  with a new clock value and does not render again. On one connection the
  clock moves when the snapshot does.

A poll costs 0.65 to 1.09 µs with the statement kept and 0.85 to 1.29 µs
through `query_scalar`. A read-only connection that has answered one pragma
holds 75 KB on Homebrew's build and 171 KB on Apple's, from 200 held open
at once.

An in-memory database has no second connection, so there a connection's own
writes are the whole clock. An application whose data must live in one is
what would bring the hook back, with the lifetime rule above.

### A deadline belongs to a step

A table of 2,000,000 rows, the handler called every 1,000 VM operations.
The overshoot is how far past its deadline a statement ran before
`SQLITE_INTERRUPT`: the worst of five deadlines placed along the unbounded
run, over two runs. Where a sort is involved two runs differ by up to three
times.

| statement | unbounded, Apple / Homebrew | worst overshoot, Apple / Homebrew |
|---|---|---|
| a recursive CTE of 2M steps | 166 / 187 ms | 32 µs / 21 µs |
| `SELECT sum(y) FROM big` | 39 / 39 ms | 31 µs / 21 µs |
| a nested-loop join | 0.8 / 0.9 ms | 42 µs / 35 µs |
| `SELECT count(*) FROM big` | 8.9 / 7.2 ms | never interrupted |
| `ORDER BY y LIMIT 1 OFFSET 1000000` | 0.79 / 3.2 s | 0.6 ms / 21 ms |
| `count(DISTINCT y)` | 0.64 / 1.4 s | 0.3 ms / 14 ms |
| `GROUP BY y`, to its 500,000th group | 0.43 / 0.49 s | 65 ms / 12 ms |
| `CREATE INDEX` | 0.58 / 0.64 s | 31 ms / 9 ms |

SQLite calls the handler between VM operations. A statement that loops
through the VM stops within tens of microseconds. A count with no `WHERE`
is one operation (`Count` in `EXPLAIN`) and ran to its end every time. The
sort under a `GROUP BY` is one too (`SorterSort`), and the statements that
sort or build an index overshot by milliseconds to tens of them.

Four more measurements decide the shape:

- **A deadline left on the connection interrupts the next statement.** With
  an expired handler still installed, a 5,000-row count on that connection
  raised `SQLITE_INTERRUPT`, while `SELECT 1` ran, being too short to reach
  the handler. Mojo has no `defer`, so a view that raises between setting a
  deadline and clearing it leaves that on a pool thread's connection for
  the next request.
- **Installing and removing the handler costs 3 to 4 ns a pair.** Around
  every step of a 500,000-row read a row went from 18–20 ns to 21–22. A
  handler every 1,000 operations is inside the noise, every 100 costs 1 to
  3 %, and every 10 costs 13 to 14 %.
- **An interrupted write takes its transaction with it.** An `INSERT ...
  SELECT` inside `BEGIN`, interrupted 20 ms in, left the connection outside
  any transaction and the row inserted before it gone.
- **A closed connection takes no handler and gives none up.** On a
  statement that outlived its connection, a handler installed before the
  close still fired, removing it through the closed handle did nothing, and
  one installed after the close was never called.

So the deadline will be given to a step: installed, stepped and removed
inside one call on the `Connection`, on the raising path too, with the
instant itself as the handler's argument, so nothing is left on the
connection between calls and there is no word to free. That call will
refuse a closed connection and a statement of another connection, since the
handler would cover neither, and a statement that is not read-only.

What it will not bound: a count with no `WHERE`; a sort, by the tens of
milliseconds above; a registered function's own `call`; and a wait for a
lock, which `busy_timeout` bounds (a write blocked under a 20 ms deadline
and a 300 ms `busy_timeout` came back after 340 to 380 ms with
`SQLITE_BUSY`). Readers under WAL do not wait on a writer.
`sqlite3_interrupt` from another thread is a different mechanism, not
measured here, and is what a client's disconnect would need; the pool
thread does not learn of a disconnect today.

## What the review found

A multi-agent review of the pull request, before it merged, verified
nineteen findings by probe or by the CI log. Six were claims this page, the
rows or the docstrings made that the code did not keep, and each is now a
test that fails without its fix:

- **A span from `blob` dangled after `text` on the same argument.** `text`
  refuses a BLOB.
- **A zero-length blob was answered as NULL.** Guarded where it is handed
  out and where it is handed back.
- **The version floor was 3.30.0**, where `SQLITE_DIRECTONLY` exists and
  does not yet refuse a CHECK constraint, a generated column or an index.
  3.31.0.
- **"Destroyed when the connection closes"** is the last finalize when a
  statement outlives the close, and the function answers until then.
- **"One image per process"** was neither enforced at open nor able to see
  CPython's own SQLite. Enforced for what this package opens; the copy it
  cannot see is written down where an operator reads O23.
- **"Never part of the database file"** was false for a trigger and a view,
  whose creation the flag does not refuse. The claim is now what the flag
  does: the schema never computes with the function, and a trigger naming
  it fails every writer until it is dropped.

One finding was a question rather than a defect: whether `call` should be
able to write its instance. It can now (`mut self`, above).

Then the fix round was itself reviewed, from a session that had not written
it, before it was pushed. It found no crash or race, and two more claims
SQLite does not keep, both in the section the first review had already
corrected once:

- **"The schema never computes with a registered function"** was false on
  SQLite 3.31.0 to 3.49 for a function that is not deterministic, which a
  CHECK constraint could name and run. Every test used a deterministic
  function. Such a function now needs 3.50.0.
- **A column DEFAULT** is a third thing whose creation the flag does not
  refuse, beside the view and the trigger.

And it corrected the first finding above: the blob that dangles is one the
statement computed. A bound one moves out from under the span and its old
bytes stay alive, which the first fix had described the other way round.

The smaller ones are in the code where they apply: a stale message on a
refused registration, names with a NUL byte, the arity's bounds, result
lengths past a C `int`, constructors over raw addresses that were public,
and tests that chose their second image by comparing path strings.
