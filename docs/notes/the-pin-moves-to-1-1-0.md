# The pin moves to Mojo 1.1.0 — 2026-09-18

Mojo 1.1.0 reached PyPI on 2026-09-17. It carries fixes for two things this
tree had built around: a `PythonObject` reference leak the WSGI bridge
routes every request away from, and a witness-table bug that shaped where
three separate pieces of the application layer live. This is the record of
moving the pin onto it.

## What was measured, and against what

A pin bump is a claim about a toolchain, so each claim below was measured on
1.1.0 **and** on 1.0.0 as the null case — the same probe file, run by each
venv's own `mojo`. A one-armed measurement is how the trait bug survived
three weeks with the wrong diagnosis (see
[a-trait-and-a-directory-name](a-trait-and-a-directory-name.md)).

**The `PythonObject` leak is gone.** 1000 operations, the refcount read
through `sys.getrefcount` and every measured object kept alive past the
read, because Mojo destroys a value at its last use and reads one low
otherwise:

| operation | 1.0.0 | 1.1.0 |
|---|---|---|
| positional call argument | +1001 | 0 |
| `__setitem__` value | +1001 | 0 |

The residual 1 on 1.0.0 is the reader's own argument, which leaks there too.
Upstream is modular/modular#6833, fixed 2026-08-11 — nine hours after the
1.0.0 wheel was uploaded, which is why no 1.0.0 carries it.

**A trait in a `.mojoc` can be conformed to again.** `poe
check-mojoc-trait` was written as a countdown and fired on the first run:
all four of its arms compile on 1.1.0, where two were refused on 1.0.0.
It is now a regression guard, and its failure message says what a
regression would cost.

## What broke, and what it cost

Five classes, 33 sites, all mechanical:

| class | sites | note |
|---|---|---|
| `Atomic[DType.int64]` -> `Atomic[Int64]` | 20 | ffi_exports, multiworker, accept_share, ring, offload, test_threads |
| `_CTimeSpec.tv_subsec` -> `tv_nsec` | 2 | static.mojo, reload.mojo |
| `Hasher.update` takes a `Span[UInt8]` | 2 | a `String` passes `.as_bytes()`; a lone `UInt8` is hashed by its own `__hash__` |
| `InlineArray` -> `Array` | 2 | `apps/ramp` and the demo mount; the name 1.1 ships |
| `unsafe_ptr` -> `ptr`, `as_c_string_slice` -> `as_c_string_span` | 7 lines | deprecations, and the warning ratchet's floor is 0 |

Two of those were found by a gate rather than by the survey, which is the
argument for running the whole sequence rather than `build-all`: the
`InlineArray` sites are in `apps/` and the demo mount, so only `build-apps`
reaches them, and `c/network.mojo`'s deprecation is on a path no
`precompile src` compiles.

Nothing in the tree needed a design change to compile, and `bench-core`'s
`run_benchmarks.mojo` is still broken in the same way it was (33 errors,
`Bencher.iter` and `bench_function` closure forms). It sits outside
`build-all` and `test-all` and stays there.

One thing that looks like a regression and is not: `build-ffi` emits `ld:
warning: object file ... was built for newer 'macOS' version (26.0) than
being linked (13.0)`. The 1.0.0 toolchain emits it identically, the dylib
still records `minos 13.0`, and the warning ratchet does not count it — it
matches only `<path>.mojo:<line>:<col>: warning:`.

## What the bump deliberately did not do

The fix satisfies the retiring condition of three standing decisions, and
none of them is retired here:

- **D12** — the page shell is a `thin` function rather than a `PageShell`
  trait.
- **D28** — the Mojo host lives in the fork, beside `mojo_pool.mojo`.
- **D7** — a frontend vocabulary's conformance lives inside `html.mojo`.

Each is a round of its own with its own gate, and a ledger row that says
`retired` while the code is unchanged is worse than one that says why it
still stands. Their retiring conditions now name the migration instead of
the toolchain, so the next session reads the remaining work rather than a
condition that has already been met.

## Still unknown

Whether 1.1.0 fixes the free-threaded `PyObject` header
(modular/modular#5726), which is what refuses an ASGI app on a
free-threaded build with exit 78. Answering it needs a 3.14t interpreter,
so it belongs to the weekly `py-canary` run rather than to this bump. The
Known issue's wording now says which toolchain it was measured on.
