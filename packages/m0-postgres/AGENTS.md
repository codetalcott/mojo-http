# m0-postgres: rules for changing this package

PostgreSQL bindings over libpq, opened at run time. The repository's
`CLAUDE.md` still applies; this page adds what is specific to this package.

`m0-postgres` imports nothing else here and links **nothing**: libpq is opened
with `dlopen` at run time, so no binary in this repo carries a libpq dependency
and a server that never names a database needs no library present. Three rules
there were each found by crashing, and all three are in `lib.mojo`'s docstring:

- **The handle and the pointers loaded from it live in ONE struct.** A loaded
  `thin` pointer carries no borrow, so an `OwnedDLHandle` held anywhere else is
  `dlclose`d at its last mention and the next call jumps into unmapped memory.
- **A `thin` pointer FIELD cannot be called as `table.field()` from outside the
  struct that holds it.** The pointer is identical by address before and after a
  move, and calling it that way faults while the same call from a method beside
  it answers correctly — so every entry point is private behind a wrapper
  method, all of them in ONE table (`PgFns`: field, load and wrapper side by
  side), which `PgLib` holds beside the handle and a `Result` copies whole, so
  an entry point is added there and nowhere else. `test_lib.mojo` asserts that
  shape in the position the broken one failed in. A dangling call is a segmentation fault, not an exception, which is
  why the rule is written down as well as tested.
- **libpq is never unloaded once opened, and a reopen finds the image the
  first open pinned.** The first `PgLib` of an image re-opens it with
  `RTLD_NODELETE` (`pin_library`), so no `dlclose` unmaps it, and KEEPS that
  handle for the life of the process. Without the pin, the last `Connection`
  going — at its last use, routinely the query itself — unloaded the library,
  and `rows.text(0, 0)` on the result was a segmentation fault three runs out
  of three. The pin is what makes it sound for `Result` to hold a COPY of the
  entry-point table (`PgFns`); reaching it through the connection's address
  instead faulted even with the pin, because a destroyed or moved connection
  leaves that address pointing at nothing. Without the kept handle the flag
  alone leaked on macOS, where an image opened `RTLD_NODELETE` leaves dyld's
  list at its last close and the next open maps a fresh copy (SPEC O24;
  docs/notes/libpq-keeps-its-handle.md). m0-sqlite's pin, the model, also
  refuses a second image. This one does NOT, on purpose: that refusal exists
  for SQLite's file locks, nothing in libpq forbids two copies in a process,
  and each image opened is pinned once, on a list (DECISIONS D49). Do not
  add the refusal without a measured fault.

The pin's word is a `pop.global_alloc` behind a `@no_inline` accessor, read
back as it is written (m0-sqlite's idiom, copied, since this package imports
nothing). `test/test_pin.mojo` holds it and needs libpq but no server:
`poe test-postgres-pin` runs it in CI's macOS job, the one platform that can
lose the kept handle, and `poe test-postgres-server` on Linux.
`poe sabotage-postgres-pin` reverts its four rules by exact source lines;
after editing an anchored line, run it and re-point the anchor. Its kept-handle
rule reports SKIPPED on Linux, so read the last lines of a run, not its count.

Also unlike m0-sqlite: a `Result` is a VALUE, not a cursor — libpq hands back a
complete result that owns its memory, so it can outlive its query and the
`Connection` that ran it (SPEC O16) — and a
`Prepared` is a name plus its parameter OIDs rather than a handle, because a
server-side statement dies with its connection and a borrowing form is not
spellable on this toolchain. Text results are the default and `binary=True` is
per-query, because libpq's result format is one choice for the whole query.

Its tests split, and the split is the point: `test-postgres` is pure (wire
formats, URL defaults and redaction, SQLSTATE) and runs inside `test-all` on
every leg, while `test-postgres-server` needs a server and does not — `test-all`'s
contract is what a checkout can run with the toolchain and the system libraries.
`test-postgres-pin` sits between them: libpq, no server.
CI runs the server half in a Linux-only job with a service container, because
GitHub's service containers require a Linux runner; `docs/RELEASING.md` names
the macOS arm. Those tests FAIL without a server and never skip.
