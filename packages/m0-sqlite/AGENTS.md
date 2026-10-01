# m0-sqlite: rules for changing this package

SQLite bindings over libsqlite3, opened at run time. The repository's
`CLAUDE.md` still applies; this page adds what is specific to this package,
and `packages/m0-postgres/AGENTS.md` holds the three loader rules it shares.

`m0-sqlite` imports nothing else here and, since 2026-09-25, links
**nothing**: libsqlite3 is opened with `dlopen` at run time (`src/lib.mojo`,
in `m0-postgres`'s shape and under its three rules — handle and pointers in
one struct, every entry point behind a method (all in one table,
`SqliteFns`, which a `Statement` copies whole), the image pinned
`RTLD_NODELETE` so a `Statement`'s copy of the table outlives the
`Connection` that loaded it, and one handle to it kept open for the life of
the process so every connection gets the SAME image (O23: on macOS the flag
alone let a reopen map a fresh copy of SQLite)), from `M0_LIBSQLITE3` or a
search path, and
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

**Scalar functions** (`src/function.mojo`, SPEC O19–O22, D58–D59;
docs/notes/functions-inside-the-query.md) are a type conforming to
`ScalarFunction`, registered per connection with `create_function`. Read
`function.mojo`'s docstring before changing one; the rules that cost the
most:

- **Every registration is `SQLITE_DIRECTONLY`** (D59), so nothing the
  database file stores may call it. Do not add a flag that relaxes it
  without D59's retiring condition.
- **A callback reaches the library through one global word**, because a
  scalar function's user data comes back only through `sqlite3_user_data`,
  itself a library call. The virtual table needs none (`pAux` is handed to
  it); do not "simplify" it toward that shape.
- **`blob` is SQLite's own bytes, valid for the call**: zero-copy is the
  whole reason the feature exists. Never return a `List` there.
- **Arity and determinism are the type's `comptime` members**, so a call
  site cannot disagree with the code that keeps them.

**The package has two globals**, each a `pop.global_alloc` word behind an
`@no_inline` accessor (m0-http's `src/global_slot.mojo` idiom, copied, since
this package imports nothing): `function.mojo`'s published table and
`lib.mojo`'s pinned image. The `@no_inline` is load-bearing on both — the op
is `Pure`, so an inlined copy makes a word of its own — and the function
table is read back through the callbacks' accessor before the first
registration, which is what turns a toolchain that broke it into a refusal.
Both words are written once and never freed. `poe sabotage-sqlite-function`
reverts each rule above, the image check and the kept handle by exact source
lines; after editing an anchored line, run it and re-point the anchor.

Four m0-sqlite invariants that look like bugs and are not:

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

Performance findings, with numbers, are in
[docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md) — batch writes in a
transaction (46x), `mmap_size` (40% on large random reads), `json_each` for
variable-length `IN` lists, and why `carray()` is unavailable and would not take
a `List[Struct]` anyway.
