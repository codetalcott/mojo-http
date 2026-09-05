# Mojo 1.0's PythonObject leak, and what the pin bump will hit

> A design note from the engineering record, moved out of ROADMAP.md's
> Known issues on 2026-09-05 and kept as written. The short form of the
> issue is [in the roadmap](../ROADMAP.md#known-issues).

**Mojo 1.0's `PythonObject` interop leaks a reference per call argument and
per `__setitem__` value.** Upstream toolchain bug, measured directly (a
dict passed to a no-op Python function 1000 times gains 1000 references).
`m0-wsgi` works around it by never letting a per-request Python object
cross through those operations. The environ is built through the raw C
API instead — `PyDict_SetItem`, `PyTuple_SetItem`, `PyObject_CallObject`,
which refcount explicitly — and the request body through a persistent
Python-side bytearray, because no C-API `bytes` binding exists (see
`bridge.mojo`). Any new bridge code must hold the same line, and the
workaround can be retired if a future toolchain fixes the leak (re-test
with `smoke-django`'s RSS guard, which must stay at 0 KB over 10k
requests).

**The fix has landed upstream, and 1.0.0 predates it.** It is
modular/modular issue #6833, fixed by commit `c9d5048575` ("[stdlib] Fix
PythonObject refcount leaks"): `__call__` and `__setitem__` took a
`Py_NewRef` of an already-owned `steal_data()` result, and the
non-stealing setters were handed owned references never released. The
fix was authored 2026-08-11, nine hours after the 1.0.0 wheel was
uploaded, reached public `main` on 2026-08-13, and is in every nightly
from `1.1.0.dev2026081405` on; no stable release carries it. Measured
directly on 2026-09-02 (1000 operations each, refcounts read through
zero-argument Python readers so the instrument cannot leak): on 1.0.0 a
positional argument, a method-call argument, a `__setitem__` value and a
`__setattr__` value each pin exactly one reference per operation, while
a keyword argument, a zero-argument call's result, `len()`,
`String(py=)` and a getitem key are clean; on `1.1.0.dev2026090205`
every row is zero. Retiring the workaround when the pin moves is
*optional*, not automatic — the raw C-API environ build is also the
14.9 µs → 3.5 µs path, so the leak rules stop being a correctness
constraint but the C API stays for speed. The RSS guard remains the
instrument either way, and on that nightly it reads 0 KB over 10k
requests with the bridge unchanged.

**What the pin bump will hit, verified by building the tree on
`1.1.0.dev2026090205` in an isolated copy** (the list first recorded
here from the release notes was three items short and one item stale):
`Atomic` is reparameterized on a value type (`Atomic[DType.int64]` →
`Atomic[Int64]`; 10 sites in `ffi_exports.mojo`, `multiworker.mojo` and
`test_threads.mojo`; neither spelling compiles on the other toolchain,
so it waits for the bump), `_CTimeSpec.tv_subsec` is renamed `tv_nsec`
(2 sites, `static.mojo` and `reload.mojo`; same, waits for the bump), and
`m0-core/run_benchmarks.mojo` loses the compile-time `Bench`/`Bencher`
closure forms (33 errors; `bench-core` is outside `build-all` and
`test-all`). Three more removals were applied ahead of time because
their replacements already compile on 1.0.0: `InlineArray` → `Array`,
`std.ffi._CPointer` → `OptionalPointer`, and `memcpy` → `unsafe_memcpy`
(the last surfaces only at `build-serve`, since `build-http`'s precompile
of `src/` never reaches the fork files that used it). `Pointer.mut_cast`
was listed here as deprecated at 2 sites; the tree only ever used
`unsafe_mut_cast`, which is the recommended spelling. With the two
remaining renames applied, `build-all`, all 1011 Mojo tests, every
Python-side check, `build-apps` and `build-serve` are green on that
nightly, and unique warnings move from 68 to 84 — the new ones are
`unsafe_ptr` → `ptr` deprecations, and the 16 the baseline then called
unfixable on 1.0.0 (`alloc` without a `Layout`, `ABI="C"`) persisted —
both were probed on 2026-09-05, both spellings work, and the baseline
is now 0.
`CompilationTarget.is_x86()` also changes meaning from "has SSE4" to "is
the x86 architecture" — which is the semantics `EPOLL_EVENT_WORDS` in
`c/epoll.mojo` always wanted, since epoll's packed event layout is a
fact about the architecture, not about SSE4; on the old meaning, a
baseline x86-64 build without SSE4.1 would have read 16-byte events on a
12-byte ABI. Uncaught exceptions also move to stderr; every smoke that
greps for `Traceback` captures `2>&1` logs, so none care.

**Two defects in the early-warning machinery, found the same day.**
`nightly-canary.yml` had failed on all three of its scheduled runs
(2026-08-18, 08-25, 09-01) on the `Atomic` break and never filed its
issue: `gh issue create --label nightly-breakage` failed because the
label did not exist. It exists now. And a child `uv run` re-syncs the
venv to `uv.lock` even under a parent `uv run --no-sync` (measured: the
child printed Mojo 1.0.0 and the venv stayed there), so the `uv run
mojo` inside `trailer_sabotage.py` — the `sabotage-trailers` step of
`test-all` — would have swapped a canary back to stable mid-run and
reported the next step's "precompiled file is newer than the compiler"
as a nightly break, the moment `build-all` first passed on a nightly.
The three sabotage scripts now run the venv's own `mojo`, the sibling of
the interpreter running them.
