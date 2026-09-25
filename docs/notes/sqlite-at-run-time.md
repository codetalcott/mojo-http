# m0-sqlite at run time — 2026-09-25

Until this round `m0-sqlite` reached SQLite through `external_call`, which
put libsqlite3 on the link line of every binary that used it: no flag on
macOS, where the dyld shared cache resolves it, and `-Xlinker -lsqlite3`
plus `libsqlite3-dev` on Linux. Two things wanted that gone, and the same
change answers both. SPEC O17 and O18 are the rows; D49 is the decision.

## The question

The `m0` wheel ships five source trees and no storage package, and the
first application on the layer avoided a database because of it: `unotes`
exported its SQLite corpus to JSON lines and read that (its soak log's
finding 1). `m0 build` takes no link flags (D40), so shipping the package
as it stood would have shipped one an application could not link. And
`m0 test` is `mojo run`, which resolves symbols only from libraries already
in its process — on Linux, `mojo run` of the package's own test failed with
`JIT session error: Symbols not found: [sqlite3_column_text, …]`, and every
test here was built and run instead.

A declared link list on `m0 build` was the alternative. It would have fixed
the build and left every test that touches the database failing under
`m0 test`, and it would have opened D40's closed command line for one
package. Loading the library at run time fixes both, and the repository
already had the shape: `m0-postgres` opens libpq that way.

## What was built

`packages/m0-sqlite/src/lib.mojo`, in `m0-postgres/src/lib.mojo`'s shape
and under its three rules, each of which m0-postgres found by crashing:

- **The handle and the pointers loaded from it live in ONE struct.**
  `SqliteLib` holds the `OwnedDLHandle` and every entry point this package
  uses — 41 of them, each loaded through `_checked`, which asks
  `check_symbol` before `load` because `load` aborts the process on a
  missing symbol. A libsqlite3 too old, or a library that is not
  libsqlite3, is an error naming the symbol and the path.
- **A `thin` pointer field is called only from a method beside it.** Every
  entry point is private behind a wrapper; nothing outside `lib.mojo`
  calls one.
- **The library is never unloaded once opened.** `SqliteLib.__init__`
  re-opens the image `RTLD_NODELETE` (`pin_library`), so no `dlclose`
  unmaps it. That is what makes it sound for a `Statement` to hold a copy
  of the entry points it calls (`StmtLib`) and outlive the `Connection`
  that loaded them — which is routine, since Mojo destroys a connection at
  its last use, often the `prepare()` itself (O2).

Each `Connection` opens its own table (`open_library`: `M0_LIBSQLITE3`,
else a search path that tries the bare name first, then the places a
package manager puts one; an absent library is one error naming every path
tried). The floor is 3.20.0, where `sqlite3_bind_pointer` arrived, and the
library must have been built thread-safe, since the package opens one
connection per thread. `Statement` takes its `StmtLib` at `prepare`.
`ffi.mojo` is the pure half now — constants, C-string helpers, the one
shape every error takes — and calls nothing; `describe` takes its fallback
text from the caller, which has a table to ask.

**The virtual-table callbacks reach the library without a global.** SQLite
calls `xConnect`, `xFilter`, `xColumn` and the rest from C with no way to
hand them a Mojo table, so the seven entry points they need travel in the
buffer SQLite already owns: `VtabLib.store` writes them as words after the
`sqlite3_module` (`A_LIB`, past what `iVersion` lets SQLite read), that
buffer is the `pAux` every `xConnect` receives, `xConnect` keeps the
address in the vtab's fourth word (`V_AUX`, within the `V_WORDS` the C
layout guard holds to `sizeof(sqlite3_vtab)`), and a cursor reaches it
through its vtab. The destructor SQLite is handed for the module and for
each array spec is `sqlite3_free` itself, the loaded pointer, where it used
to be a Mojo shim calling `external_call`.

## What it cost, measured

- One indirect call per C call. `bench_sqlite.mojo`'s rows are the
  instrument and were at parity before this landed; the bench itself was
  ported to the table.
- A `dlopen` and the symbol lookups per connection, once per thread.
- `test_file.mojo` forks twelve process pairs. Built and run it takes 388 s
  on this container's four cores; under `mojo run` 529 s, the fork of a
  compiler-sized process costing the rest. It stays built, for that cost
  and nothing else; the other six test files run under `mojo run`.

## The pin, proven the way it was found

`test_lib.mojo:test_a_statement_outlives_every_handle_of_the_library`
closes and drops a connection — the only `OwnedDLHandle` the library was
opened through — and then steps the statement through its copies. With the
pin removed from `SqliteLib.__init__` and nothing else in the process
holding the library, the `dlclose` unmaps it and the same test dies of a
segmentation fault at its first `step` (Linux, 2026-09-25, this round's
own run). A dangling call is a fault, not an exception, so the test asserts
the shape that works in the position the broken one fails in, and the
sabotage is recorded here rather than automated: on macOS the dyld shared
cache keeps the library mapped whatever the handle does, so the arm has one
platform.

## What is gated

- `test_lib.mojo`, seven tests: the search path and floor, a table moved
  through a function, the outlive above, a missing symbol named, a path
  that is not a library named (outright and through `M0_LIBSQLITE3`, which
  is what a `Connection` sees), the C library refused by its first missing
  symbol.
- `build-apps`, inside `test-all`, builds `apps/datastar_todo` — the
  package's one consumer — and fails if its binary names libsqlite3 in a
  `NEEDED` entry or a load command. An `external_call["sqlite3_…"]` put
  back anywhere in the package would reappear there.
- `verify-vtab-layout` holds the three new constants as Mojo's own layout
  (`A_LIB`, `A_WORDS`, `V_AUX`), beside the offsets it still asserts
  against `sqlite3.h`; `sabotage-vtab` moves each of those as before.

## What follows

The `m0` wheel gains the `m0_sqlite` and `m0_postgres` trees — listed in
its build hook and again in `smoke-m0-wheel`, which is the guard — the
`live` template persists to SQLite in `datastar_todo`'s shape, and the
runtime image gains libsqlite3. That is the next round, with MAX
(docs/notes/threads-first-for-m0-apps.md), since both touch the wheel and
its checks.
