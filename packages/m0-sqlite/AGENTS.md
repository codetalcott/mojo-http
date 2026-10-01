# m0-sqlite: rules for changing this package

SQLite bindings over libsqlite3, opened at run time. The repository's
`CLAUDE.md` still applies; this page adds what is specific to this package,
and `packages/m0-postgres/AGENTS.md` holds the three loader rules it took
from there. The third has a second half that was found here (one image,
below). m0-postgres has since taken the kept handle and not the refusal: a
second libpq is pinned beside the first (SPEC O24).

`m0-sqlite` imports nothing else here and, since 2026-09-25, links
**nothing**: libsqlite3 is opened with `dlopen` at run time (`src/lib.mojo`,
in `m0-postgres`'s shape and under its three rules — handle and pointers in
one struct, every entry point behind a method (all in one table,
`SqliteFns`, which a `Statement` copies whole), the image pinned
`RTLD_NODELETE` so a `Statement`'s copy of the table outlives the
`Connection` that loaded it), from `M0_LIBSQLITE3` or a search path, and
refused below 3.20.0, built without threads, or missing a symbol. So every
test in the package runs under `mojo run` on both platforms, `build-apps`
fails if `datastar_todo`'s binary names the library, and a `-Xlinker
-lsqlite3` anywhere in the tree is a regression (SPEC O17–O18, D49;
docs/notes/sqlite-at-run-time.md). The virtual-table callbacks reach the
table through words stored after the `sqlite3_module` in the buffer SQLite
hands back as `pAux` (`A_LIB`, `V_AUX`; `verify-vtab-layout` holds them).
`Connection` and `Statement` are `Movable` but not `Copyable` on purpose:
copying would duplicate a handle and the second destructor would
double-free. Do not add `Copyable`.

**One libsqlite3 image, the first one opened** (SPEC O23). The first
connection of a process pins its library and keeps that handle open for good
(on macOS the `RTLD_NODELETE` flag alone let a reopen map a fresh copy of
SQLite), and `open_library` refuses any library that is another image,
naming both files. Three rules come with it:

- **A refused library is never pinned, and never called after its handle
  goes.** `SqliteLib.__init__` asks a library everything — version, thread
  safety — BEFORE the first branch that can raise, then pins. On a raising
  path the handle closes as the branch begins, and unpinned, the library
  unloads with it: a call through its table from inside an error message is
  a call into unmapped memory. A test that builds a table straight from a
  handle keeps the handle's last mention after its last call (`_ = handle`).
- **Every handle is `RTLD_LOCAL`** (`_open_flags`, `_pin_flags`).
  `OwnedDLHandle`'s default is global, and an image in the global scope
  captures the internal calls of any libsqlite3 loaded after it: on
  Ubuntu's build the second copy then answers "no such vfs" to every open.
- **The package cannot see a copy it did not open.** CPython's `sqlite3`
  carries its own SQLite in the interpreters uv installs, so a Mojo mount on
  m0-sqlite beside a Python application on the stdlib backend is two copies
  in one process: sound only while they never open the same database file.
  Do not write "one SQLite per process" anywhere without that sentence.

`test/test_one_image.mojo` is a process of its own for this: a process is
held to its first library, so a test that needs a particular one cannot
share a process with tests that opened another. A test that sets
`M0_LIBSQLITE3` puts the old value back; it never unsets it.

**Scalar functions** (`src/function.mojo`, SPEC O19–O22, D58–D59;
docs/notes/functions-inside-the-query.md) are a type conforming to
`ScalarFunction`, registered per connection with `create_function`. Read
`function.mojo`'s docstring before changing one; the rules that cost the
most:

- **Every registration is `SQLITE_DIRECTONLY`** (D59), so the schema never
  computes with one: refused in a CHECK constraint, a generated column or an
  index at CREATE, in a stored view at use, in a trigger when it fires, in a
  column DEFAULT when an INSERT takes it. The flag does NOT refuse creating
  a view, a trigger or a DEFAULT that names the function, and such a trigger
  fails every write to its table from every program; never write that a
  function "stays out of the database file". Do not add a flag that relaxes
  it without D59's retiring condition.
- **Two version floors, and the second is per function.** 3.31.0 for all;
  3.50.0 for a type whose `deterministic` is False, because before it a
  CHECK constraint naming a non-deterministic function is created and RUN
  (the flag reached only the deterministic branch of `resolve.c`). So a
  fixture is deterministic unless non-determinism is the thing under test,
  or its test does not run on the Linux leg (Ubuntu 24.04 has 3.45.1); a
  function called over a column runs once per row either way. Before
  writing what the flag refuses, run the matrix on an old and a new library:
  both words of it were wrong once.
- **A callback reaches the library through one global word**, because a
  scalar function's user data comes back only through `sqlite3_user_data`,
  itself a library call. The virtual table needs none (`pAux` is handed to
  it); do not "simplify" it toward that shape.
- **`blob` is SQLite's own bytes, valid for the call**: zero-copy is the
  whole reason the feature exists. Never return a `List` there. **And
  `text` refuses a BLOB**, because reading one as text converts it in
  place: a blob the statement computed is reallocated and a span taken
  earlier dangles, and a bound one moves out from under it. An accessor
  that hands out a pointer and one that converts are never both allowed on
  one storage class. A new accessor goes on one side of that line.
- **An empty blob is a blob.** SQLite's pointer for one is NULL and
  `sqlite3_result_blob` answers SQL NULL for a NULL pointer, so `Args.blob`
  never hands that pointer out and `SqliteFns.result_blob` never hands one
  in. Each guard has its own assertion; with one, either hides the other.
- **Arity and determinism are the type's `comptime` members**, so a call
  site cannot disagree with the code that keeps them.
- **`call` takes `mut self`, and is never re-entered.** A function's state
  is its own fields. That is sound only because SQLite calls one instance
  one call at a time, so never give a function a way to run SQL on its own
  connection (`Args` carries none): on Mojo 1.1 a small instance is copied
  in and stored back, so an inner call's writes would be overwritten, and a
  large one is passed as a pointer taken to be unaliased. Unsound at any
  size. Nothing reaches a registered instance by address, either.

**The package has two globals**, each a `pop.global_alloc` word behind an
`@no_inline` accessor (m0-http's `src/global_slot.mojo` idiom, copied, since
this package imports nothing): `function.mojo`'s published table and
`lib.mojo`'s pinned image. The `@no_inline` is what keeps each to ONE word —
the op is `Pure`, so an inlined copy makes a word of its own — and each is
read back through its readers' accessor as it is written (the function
table before the first registration, the pin before the first connection),
which is what turns a toolchain that broke it into a refusal. Both words
point at a record written once and never freed, each holding the file it
came from so a refusal can name it. `poe sabotage-sqlite-function` reverts
each rule above by exact source lines; after editing an anchored line, run
it and re-point the anchor. Four kinds of rule report SKIPPED on a host
that cannot observe them (no second image, no library the loader can drop,
no build that binds through the global scope, no library older than
3.50.0), so read the last lines of a run, not its count.

Six m0-sqlite invariants that look like bugs and are not:

- **`reset` and `finalize` discard their result code.** SQLite returns the
  *previous* evaluation's error there, so raising on it makes recovery after a
  failed `step` impossible and turns cleanup into a second exception.
- **Every close path uses `close_v2`.** That is what lets a `Statement` outlive
  the `Connection` that made it, which Mojo's destroy-at-last-use makes routine.
  `sqlite3_close` would break it silently.
- **Error text is only trusted when `sqlite3_errcode` corroborates the code.**
  A closed connection answers `SQLITE_MISUSE` to everything, and reporting that
  would replace a true constraint error with a false one.
- **`create_function` never frees the state it was handed, even when the
  registration fails.** `create_function_v2` runs the destructor itself on a
  refusal, so a second free is a double free — and one the allocator does not
  report: the test that holds it keeps its counter's address past a freed
  block's free-list links, which is how its sabotage first went unseen.
- **A function's state is not destroyed by `close()` while a statement of
  that connection is outstanding.** `close_v2` again: the connection lives
  until the last such statement is finalized, the function answers until
  then, and the destructor runs at that finalize.
- **A refused registration is not always told in SQLite's words.**
  `SQLITE_MISUSE` leaves the connection's error state alone, so its message
  is the previous statement's; `_register_function` uses it only when the
  connection's code agrees, as `stmt_errmsg` does. And its `SQLITE_BUSY`
  (a replacement under an active statement) is not the retryable kind.

Performance findings, with numbers, are in
[docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md) — batch writes in a
transaction (46x), `mmap_size` (40% on large random reads), `json_each` for
variable-length `IN` lists, and why `carray()` is unavailable and would not take
a `List[Struct]` anyway.
