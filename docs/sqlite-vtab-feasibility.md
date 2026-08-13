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

## The blocker

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

Every binder in `m0-sqlite` today passes `SQLITE_TRANSIENT` precisely so no
Mojo buffer has to outlive a call (`ffi.mojo:44-47`). A pointer-binding API
breaks that invariant, and the failure is silent. **This needs a borrow the
type system enforces — not a documented convention — before it ships.** That is
the open design question, and it is the reason the spike lives in
`experiments/` rather than `packages/`.

## Also unverified

Everything above is x86-64 Linux. The struct offsets are LP64 assumptions
(`sqlite3_index_info` word indices, a 12-byte `sqlite3_index_constraint`, an
8-byte `sqlite3_index_constraint_usage`). They need checking on macOS/aarch64
before anyone trusts them — this repo has already been bitten once by an
x86-64-only struct layout (`lightbug_http/c/epoll.mojo:48-70`).

## Scope note

`m0-sqlite` advertises itself as "a thin, honest layer over the SQLite C API —
no ORM, no query builder, no connection pool" (`src/__init__.mojo:1-6`). A vtab
module would be the largest piece of native machinery in the repo. For
comparison, a statement cache measured at ~10% and was deliberately not built
(`README.md:152-154`). A 2.96x ingest win is well clear of that bar; a 1.2x
`IN`-clause win is not.
