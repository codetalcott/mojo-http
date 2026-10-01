# Functions inside the query — 2026-09-30

`m0-sqlite` can now register a Mojo type as a scalar SQL function on a
connection, and the function runs inside SQLite's query plan, reading each
value where SQLite already holds it. SPEC O19 to O22 are its rows, D58 and
D59 its decisions. Building it turned up a defect in the loader that came
before it: on macOS, a process that closed all its connections and opened
another was running a second copy of SQLite. That is SPEC O23, fixed in the
same change.

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

    def call(self, args: Args, mut answer: Answer) raises:
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
fields, which is why there is no second form for one — D12's argument for
`PageShell`, again. Two facts of Mojo 1.1 came with it, both found by the
compiler: the trait refines `Deinitable`, because the instance is destroyed
generically and on the error path of a refused registration, and `Args`
conforms to `Sized` for `len(args)`.

**The type states its promises**, as `comptime` members a call site cannot
disagree with. `arity` is registered, so SQLite refuses a wrong call when it
prepares the statement; `Args` still bounds-checks an index, since a
variadic function's code can reach past what a call passed. `deterministic`
changes the plan: a call with a constant argument over 100 rows ran once
with the flag and 100 times without.

**Arguments are SQLite's own values.** `blob` hands out a span over SQLite's
bytes, valid for the call — the whole point — and refuses anything but a
BLOB, since a vector arriving as text or a number is the caller's bug and
SQLite's conversion would rewrite the value in place. The other accessors
convert as `Statement`'s column accessors do. Answers copy
(`SQLITE_TRANSIENT`). A raise becomes `sqlite3_result_error`, so `step`
raises the function's own text; the `try` around the call is not a
convention, because an `abi("C")` function cannot raise and the compiler
holds it.

## Never part of the database file (D59)

Every registration carries `SQLITE_DIRECTONLY`. Measured on Apple's 3.54.0
and Homebrew's 3.53.4, SQLite then refuses the function in a CHECK
constraint, a generated column and an expression index **when they are
created**, in a stored view when it is used, and in a trigger when it
fires; top-level SQL and a TEMP view may call it. A schema that called an m0
function would be writable only by the binary that registered it — the
`sqlite3` shell, a migration, a `VACUUM INTO` backup would all fail — and a
database handed over by someone else could reach application code through
its triggers. Rules every writer must obey belong in the schema as built-in
SQL. The flag arrived in SQLite 3.30.0, so registration refuses an older
library rather than trusting it.

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
when the function is replaced, when the connection closes, and — from inside
`create_function_v2` itself — when it refuses a registration. Measured: a
256-byte name (`SQLITE_MISUSE`) and a replacement while a statement is
active (`SQLITE_BUSY`, "unable to delete/modify user-function due to active
statements") each destroy the new instance once. So the package never frees
on failure, the rule `vtab.mojo` already states for `create_module_v2`.

## One word, and why the virtual table needed none

`m0_array`'s callbacks reach the library without a global: SQLite hands
`pAux` straight to `xConnect`. A scalar function's user data comes back only
through `sqlite3_user_data(ctx)`, which is itself a call into the library
this package opens at run time — so the entry points sit behind one
`pop.global_alloc` word, as a C extension's do behind its global
`sqlite3_api`. The word holds a copy of the table, published once per
process by compare-and-swap (pool threads build their handlers at once,
D31), and read back through the callbacks' own accessor before the first
registration: removing `@no_inline` from the accessor, the sabotage, gives
the writer and the reader different words ("wrote 4521148416, read 0"),
and the registration is refused instead of every callback reading zero.
A connection whose libsqlite3 is another image may not register, since a
callback reaches one library; images are compared by an entry point's
address, never by path. An application's conformance compiled against
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
for the life of the process, once per image, named by a second word; the
reopen then finds the same image, and dyld's count stays put.

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
ten; the image rule is observable only where a second image can be loaded
(a copy of the library on Linux, Homebrew's build on macOS), and the
kept-handle rule only on macOS with a library backed by a file, so on a
runner without one they report SKIPPED, never caught.

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

## What is not built

Each waits for an application that needs it:

- **Aggregates and window functions.** Per-group state lives in memory
  SQLite frees without running a Mojo destructor, and nothing here has
  checked whether `xFinal` runs when a statement is reset mid-group.
- **A function the schema may call** (`SQLITE_INNOCUOUS`): D59's retiring
  condition, an application that needs one in an index or a generated
  column.
- **Subtypes**, which matter only for interop with sqlite-vec's typed
  values; **auxiliary data** (a per-statement cache of something derived
  from a constant argument), once a function measures that preparation
  above a row's noise; **collations**, once a listing needs an order
  `BINARY` and `NOCASE` cannot give; removing a function, which replacement
  covers.
- **A commit hook** that counts a connection's own commits, so a change
  clock stops depending on the caller remembering to say it wrote. Building
  it has one trap the registration work already measured: a `Statement`
  that outlives its `Connection` still commits on the connection
  `close_v2` leaves behind, and still fires that connection's hook, so the
  hook must be removed before the close.
- **A progress handler** that interrupts a statement past its request's
  deadline: measured, a 20 ms deadline stopped a 2M-row scan at 20.0 ms
  with `SQLITE_INTERRUPT`, the connection answered the next statement, and
  a handler every 1,000 operations cost nothing the noise let through.
  Waits for a query on the layer whose worst case outlives its request.
