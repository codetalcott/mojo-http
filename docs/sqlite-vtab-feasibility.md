# Feasibility: a carray-style extension over Mojo memory

Measured 2026-08-13 against SQLite 3.45.1 and Mojo 1.0.0, x86-64 Linux.
Spike code: [`experiments/sqlite-vtab/`](../experiments/sqlite-vtab/).

## The question

Whether to port SQLite's `ext/misc/carray.c` and modify it to read Mojo struct
memory, so N values could be handed to a query without building N placeholders.

## Verdict

**Build the virtual table for bulk ingest. Do not build it for `IN` clauses.
Do not write any C, and do not model Mojo structs.**

Bulk ingest is a **2.96x** win and clears the bar. The `IN`-clause case — the
thing carray exists for — does not: it is 1.63–1.99x against rebuilt
placeholders but only **1.16–1.34x** against `json_each`, which is built into
SQLite and needs no new code at all. If the vtab gets built for ingest, the
`IN`-clause path comes along for free; it is not worth the machinery on its own.

Three premises in the original framing turned out to be wrong, and all three
make the work cheaper:

- **No C is needed.** `libsqlite3` exports `sqlite3_create_module_v2`,
  `declare_vtab`, `bind_pointer`, and `value_pointer`; Mojo 1.0 can supply
  C-callable function pointers. The module registers in-process on a live
  `Connection`. No C file, no loadable extension, no new build step, nothing
  new in CI. (`carray` itself is *not* compiled into the system libsqlite3 —
  `SELECT * FROM carray(0,0)` gives `no such table` — so vendoring it would
  have meant new native machinery either way.)
- **Do not model Mojo structs.** One bound pointer per column beats one strided
  pointer per struct. It sidesteps Mojo layout guarantees entirely and matches
  the parallel-`List` layout `CLAUDE.md` already mandates.
- **carray's headline benefit mostly is not there.** Its big win in Python
  bindings is avoiding per-value FFI trampolines. Mojo's `external_call` is a
  direct call, so that saving largely evaporates — which is why the `IN`-clause
  numbers are unremarkable and the ingest numbers are not.

## Numbers

`IN`-clause, against a 200k-row table, best of 20:

| N | rebuilt `IN (?,…)` | `json_each(?)` | Mojo vtab | vs placeholders | vs json_each |
|---:|---:|---:|---:|---:|---:|
| 10 | 6.93 µs | 4.53 µs | 3.47 µs | 1.99x | 1.30x |
| 100 | 45.4 µs | 35.0 µs | 26.2 µs | 1.74x | 1.34x |
| 1000 | 754 µs | 536 µs | 464 µs | 1.63x | 1.16x |

Bulk ingest, one transaction, best of 5:

| Rows | bind/step/reset loop | `INSERT … SELECT` over vtab | Speedup |
|---:|---:|---:|---:|
| 10,000 | 2.01 ms | 0.68 ms | **2.97x** |
| 200,000 | 42.2 ms | 14.3 ms | **2.96x** |

The ingest win is real because it collapses 3N `sqlite3_bind_*`/`step`/`reset`
calls plus N statement resets into a single `step` that pulls rows through
`xColumn`. The ratio holds flat across a 20x change in row count.

## The blocker, and how it was resolved

`sqlite3_bind_pointer` lends SQLite raw Mojo memory for the life of the
statement, and Mojo frees a value at its **last syntactic use** — which is
routinely *before* `step()` runs:

```mojo
bind_array(q, 1, data)
q.bind_int(2, len(data))   # last use of `data`; freed here
_ = q.step()               # SQLite reads freed memory
```

This does not crash. The allocator writes a freelist pointer into the block's
first word, so element 0 returns a heap address and every other element is
fine — it surfaced as a wrong `sum` beside a correct `count(*)`.

**A guard object does not fix this.** The guard would itself be destroyed at
its own last use, still before the step. Its destructor could unbind, turning
freed memory into an empty result — safe, but silently wrong, which is barely
an improvement.

What does fix it is shape. The array is passed as an **argument to the call
that also finishes the statement**, so it is alive for the whole call by
construction and there is nothing for a caller to hold correctly:

```mojo
db.register_array_module()
var ins = db.prepare("INSERT INTO t SELECT value FROM m0_array(?1)")
ins.execute_over(1, values)     # binds, steps to completion, unbinds
```

The binding is dropped before returning, so a later `step` on the same
statement sees an empty table rather than a stale pointer. The cost is that
these calls do not compose with incremental stepping — the right way round for
bulk ingest, which was the case worth having.

Shipped in `packages/m0-sqlite/src/vtab.mojo` with `Statement.execute_over` and
`Statement.fetch_ints_over`, opt-in per connection via
`Connection.register_array_module`, covered by 20 tests. The single-column
`IN`-clause path came along for free, as predicted; it is still not the reason
to use this.

## Portability of the struct offsets — checked

The spike treats four SQLite structs as flat word buffers, so its correctness
rests on offsets the Mojo compiler cannot see. Those are now re-derived from the
real headers via `offsetof` and asserted at compile time in
[`packages/m0-sqlite/test/verify_layout.c`](../packages/m0-sqlite/test/verify_layout.c)
(moved there from `experiments/` once it became a build gate — `poe test-sqlite`
now runs it for the host triple before any Mojo test):

| Target | Result |
|---|---|
| `x86_64-linux-gnu` | pass |
| `aarch64-linux-gnu` | pass |
| `arm64-apple-macos` | pass |
| `aarch64-unknown-linux-musl` | pass |
| `i386-linux-gnu` | **fails, as intended** |

Every offset is identical across the three 64-bit targets — `sqlite3_module`
slots, the `sqlite3_index_info` word indices, the 12-byte
`sqlite3_index_constraint`, the 8-byte `sqlite3_index_constraint_usage`, and the
one-word `sqlite3_vtab_cursor`. That is the expected outcome (all the fields are
naturally aligned and LP64 is LP64), but it is the kind of thing this repo has
been burned assuming: `lightbug_http/c/epoll.mojo:48-70` documents a layout that
was right on x86-64 and silently corrupted every event on aarch64.

Two controls establish the check is not vacuous. The i386 build fails on the
pointer-width and module-slot assertions, and `long double` measures 16 bytes on
`x86_64-linux-gnu` but 8 on `arm64-apple-macos` — so clang really is applying
per-target ABI rules during semantic analysis, not reusing the host's.

The Mojo side also cross-compiles: `mojo build --target-triple
aarch64-unknown-linux-gnu --emit object` on `spike_s2.mojo` produces a valid
aarch64 ELF object.

## Still unverified

- **Execution on aarch64.** No qemu-user and no aarch64 runner here, so the
  layout is proven but the runtime is not. Specifically untested: whether Mojo's
  `abi("C")` lowering is correct under AAPCS, and how the vtab interacts with
  macOS's system SQLite (which already diverges from Linux's on
  `sqlite3_step` past `SQLITE_DONE` — see `stmt.mojo`). The related open Mojo
  bug modular/modular#6567 is SysV-specific and concerns by-value aggregates;
  every callback here passes only pointers and ints, so it should not apply, but
  the AAPCS equivalent has not been exercised.
- **macOS's own `sqlite3.h`.** The `arm64-apple-macos` check compiled against
  the Linux SQLite 3.45.1 headers installed here, since no macOS SDK is present.
  It validates the ABI rules, not Apple's header text.

## Scope note

`m0-sqlite` advertises itself as "a thin, honest layer over the SQLite C API —
no ORM, no query builder, no connection pool" (`src/__init__.mojo:1-6`). A vtab
module would be the largest piece of native machinery in the repo. For
comparison, a statement cache measured at ~10% and was deliberately not built
(`README.md:152-154`). A 2.96x ingest win is well clear of that bar; a 1.2x
`IN`-clause win is not.
