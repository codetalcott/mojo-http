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

Three m0-sqlite invariants that look like bugs and are not:

- **`reset` and `finalize` discard their result code.** SQLite returns the
  *previous* evaluation's error there, so raising on it makes recovery after a
  failed `step` impossible and turns cleanup into a second exception.
- **Every close path uses `close_v2`.** That is what lets a `Statement` outlive
  the `Connection` that made it, which Mojo's destroy-at-last-use makes routine.
  `sqlite3_close` would break it silently.
- **Error text is only trusted when `sqlite3_errcode` corroborates the code.**
  A closed connection answers `SQLITE_MISUSE` to everything, and reporting that
  would replace a true constraint error with a false one.

Performance findings, with numbers, are in
[docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md) — batch writes in a
transaction (46x), `mmap_size` (40% on large random reads), `json_each` for
variable-length `IN` lists, and why `carray()` is unavailable and would not take
a `List[Struct]` anyway.
