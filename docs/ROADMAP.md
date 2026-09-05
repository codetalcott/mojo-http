# Roadmap

**This page is the project's state, kept short on purpose.** What the server
can do is [SPEC.md](SPEC.md), one row per capability with the gate that proves
it. What remains before 1.0 is computed, not written down:

```bash
uv run poe milestones
```

The reasoning behind the design -- what was built and measured, what was
refused and why, the post-mortems -- is the engineering record, kept as
[design notes](#design-notes) so this page can stay readable.


**Computed, not remembered.** `poe milestones` derives these from
[SPEC.md](SPEC.md); CI prints the report on every pull request. Before this
existed the direction of the work lived in one person's head and each
session reconstructed it — and the first thing computing it revealed was that
**1.0 is nine rows away**, which nobody had noticed.

Milestones derive from row STATUS rather than a per-row annotation. A
milestone column would mean editing 149 rows and keeping them right for
ever; these two definitions need no new data at all.

### beta — nothing in the tree ships without a gate

Every row is `verified`, `planned` or `out of scope`. In other words no row
is `implemented`, which is this sheet's word for "it is in the tree and no
gate is dedicated to it".

The ordering is evidence, not taste. Gating an `implemented` row has found a
real defect **four times out of four**: A4's close linger re-arming every
pass (a slot held for the life of the process), I16's close codes echoed
rather than validated, L17's inbound WebSocket messages dropped 2932 of
3000, and A11's `Expect: 100-continue` failing on both case and HTTP/1.0. So
the remaining `implemented` rows are simultaneously the finish line and the
highest-yield work available.

### 1.0 — beta, plus the planned rows resolved, plus a soak

1. Every row `verified` or `out of scope`. A `planned` row is resolved by
   being built OR by being moved to `out of scope` with a reason — deciding
   not to do something is a resolution, and the sheet already records
   refusals as first-class.
2. **A soak against real applications.**
   [REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md) is the instrument and it
   has earned the requirement: run once against three Django projects
   nobody here wrote, it found **four defects, three of which no in-repo app
   could have shown**. Every application in `apps/` was written to test this
   server, which is the right shape for a smoke suite and the wrong shape
   for "would this serve my application?". The soak is stale when it lags
   the tree by more than two minor versions.

   Its staleness is REPORTED and not gated, deliberately: nobody can re-run
   somebody else's Django projects inside the pull request that trips a
   gate, and a gate nobody can satisfy is a gate somebody disables. What is
   gated is the record being readable at all.
3. Known issues curated — each declaring what would retire it (below).

### The rot rules, which are gated

`poe check-milestones`, sabotage-proven like every other checker here.

Every entry under [Known issues](#known-issues) carries a **`Closed by:`**
line naming the SPEC rows whose `verified` would retire it, or `none` for
one no row can reach — an upstream bug, a toolchain gap, a platform floor.
An issue whose rows are all `verified` fails the build until it is moved to
Recently resolved.

That rule earned its place the day it was written. "Suspected race: the
WebSocket close path can RST instead of FIN" had been diagnosed and fixed in
v0.15.1 and gated by L15 and L16 — and was still listed as an open risk a
release later, because nothing retired it and nothing could. Anyone reading
the page would have believed the close path was unreliable.

## Known issues

- **The asyncio executor cannot run on free-threaded CPython.** The
  executor's `ExecutorPort` is a Python type built in-process with
  `PythonModuleBuilder`, and Mojo 1.0's stdlib lays `PyObject` out for the
  GIL build (a 16-byte header; a free-threaded build's is 32, `ob_tid` and
  the biased refcount ahead of `ob_type`), so `PyModule_Create` reads the
  module definition at the wrong offsets and segfaults in
  `PyUnicode_FromString` -- the 2026-09-02 py-canary failure, identical to
  the trace in modular/modular#5726 (open since January, still present in
  26.1). It is the build's layout, not the GIL's state: `PYTHON_GIL=1`
  does not help. Every WSGI path is fine there, because it only calls C
  functions on opaque pointers. Since 2026-09-02 the server REFUSES rather
  than crashes: an ASGI application on a free-threaded build exits 78
  naming the issue (`asgi_free_threading_refusal`), `--doctor` reports the
  same check, and under `--workers` the supervisor passes a worker's 78 up
  as the refusal it is instead of respawning it (E10). Consequence worth
  stating: an ASGI application cannot run under `--threads` on this
  toolchain at all, since that mode requires the build the executor
  cannot use. The pre-port pump (a `run_until_complete` per pass) would
  work there and could be restored behind the probe if anyone needs ASGI
  on 3.14t before upstream moves.

  **Closed by:** none — an upstream fix to the stdlib's `PyObject` layout
  (modular/modular#5726) retires it; the re-test is `smoke-django-realtime`
  phase 6 on 3.14t, which must then run the full mixed server (L18 keeps
  the refusal honest until then).

- **`mojo build` needs a C compiler on Linux and nothing says so.** It shells
  out for linking, so a minimal image (`python:*-slim` carries no compiler)
  fails with `unable to find suitable c compiler for linking`. CI never
  noticed because GitHub runners ship gcc. `build-essential` — or any cc —
  belongs beside `libsqlite3-dev` and `patchelf`.

  **Closed by:** none — no SPEC row can retire
  this; it is outside the server's own behaviour.

- **The Linux wheel misses RHEL 9 by one glibc minor.** Measured on CI, the
  binary requires glibc 2.35 and `scripts/wheel_tag.py` tags it
  `manylinux_2_35_x86_64` — which covers Ubuntu 22.04 and Debian 12 but not
  RHEL 9 and its rebuilds, which sit at 2.34. Worth noting the floor did NOT
  come from the build image (that runner is glibc 2.39): it is what the Mojo
  toolchain's own output requires, so building on an older image would not
  move it — confirmed independently on aarch64, where a Debian 13 container
  with glibc 2.41 also produced a `manylinux_2_35` wheel. Same floor, two
  architectures, two very different host glibcs. Reaching 2.34 means building inside a `manylinux_2_34` container.
  Deferred: it adds a container build to the release path for reach the
  first quiet 0.x does not need, and `pip` declines the wheel cleanly rather
  than installing something that crashes.
- Negotiation covers `Accept`, `Accept-Encoding` (`negotiate_encoding` —
  codec-agnostic, for callers with precompressed variants; the framework
  deliberately ships no compressor), and `Accept-Language`
  (`negotiate_language` — RFC 4647 matching, serve-something-over-406 per
  RFC 9110's advice). What remains deliberate: no automatic `Vary` tracking
  (the notes example sets it by hand) and no dynamic compression.

  **Closed by:** none — no SPEC row can retire
  this; it is outside the server's own behaviour.

- **Mojo 1.0's `PythonObject` interop leaks a reference per call argument and
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
  `unsafe_ptr` → `ptr` deprecations, and the 16 the baseline calls
  unfixable on 1.0.0 (`alloc` without a `Layout`, `ABI="C"`) persist.
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

  **Closed by:** none — no SPEC row can retire
  this; it is outside the server's own behaviour.

- **Scheduling stickiness: two forked workers, one shared listener, and
  eighty accepts in a row to the same worker — reproduced, and it is CPU
  placement, not load.** Seen once (2026-08-29, ubuntu CI runner, PR
  #168's first run): `smoke-reload`'s two-worker phase re-forked both
  workers onto the new module — both logged their loop start — and then
  every one of ten rounds of eight fresh connections was answered by
  worker 6522; the smoke wants to see both pids and failed. The first
  recorded failure of that step, and the CI re-run of the same job on the
  same head passed. The mechanism it looked like was right, the load
  theory attached to it was not, and the fix direction it named was
  backwards; all three measured 2026-09-02 in a Linux container (colima,
  4 vCPU, the 0.16.0 aarch64 wheel, `--workers 2`, the smoke's own probe
  of 10 rounds x 8 sequential connections) with
  `scripts/accept_placement.py`.

  The mechanism: `M0_WORKERS` forks after `listen`, so both workers share
  ONE listen socket, each registers it `EPOLLIN|EPOLLET` in its own epoll,
  and on a connection both wake and the first to reach `accept()` drains
  the backlog until EAGAIN while the other gets EAGAIN and parks. Which
  one is first is the scheduler's, and on a quiet 4-CPU box it is already
  the same one nine times in ten: 63–77 of 80 to one worker across 15
  unpinned runs, the smoke passing each time only because the minority
  worker surfaced in round 1–3. What makes it ten of ten is where the
  CLIENT runs. Workers pinned to CPUs 0 and 1 and the probe on CPU 1:
  80 of 80 to the worker on CPU 0, no round with both pids, in four runs
  of five (the fifth 79/1). Probe on CPU 2: 70–76 of 80. The worker that
  shares the client's CPU loses every time — the accept-queue wakeup runs
  inside the client's own `connect()` on its CPU, the worker with an idle
  CPU of its own is running before the client has blocked, and the
  co-located worker finds an empty backlog when it finally runs. Nothing
  pins tasks on a CI runner, but wake-affine placement can hold exactly
  that shape for the five seconds the probe lasts, and that is the
  sighting. Load is not the mechanism and tends to CURE it: everything on
  one CPU alternates 45/35 (one runqueue, CFS's vruntime picks the worker
  that has run less), and hogs beside either worker move the split toward
  even, not away from it. Concurrent connections do not fix it either
  (the burst is drained by whichever worker wakes first; 1–3 rounds of 10
  in most placements).

  `EPOLLEXCLUSIVE` is NOT the fix direction: in a pure-Python model of the
  accept path it sends 80 of 80 to one worker in every placement, quiet or
  loaded — it removes the very race that was giving the other worker its
  share. Per-worker `SO_REUSEPORT` listeners (bound after the fork, the
  kernel hashing connections across them) balance 40/40 to 46/34 in every
  placement and are the only shape that does. Not adopted on one CI
  failure: it changes the accept path of every prefork deployment, and a
  connection queued at a worker that dies is reset until the respawn
  rebinds — the shared socket is what makes the supervisor's respawn and
  `--reload` invisible to clients. Sequential one-shot connections from a
  single client are the smoke's shape, not a deployment's; keep-alive
  connections spread over time, and gunicorn's and nginx's prefork share
  the property.

  The smoke is asserting scheduler fairness (memory: "assert blocking, not
  fairness"), and loosening it to one pid would hide what it exists to
  see. The assertion that does not depend on fairness was measured on the
  same wheel under the reproducing placement: SIGSTOP the worker that
  answered, and the same probe is answered 80 of 80 by the other worker,
  promptly (5.5 s for ten rounds, all of it the probe's own sleeps); SIGCONT
  it, and SIGTERM exits 0 with no `crashed` or `respawned` line — the
  supervisor reaps with `WNOHANG` alone, so a stopped worker is neither a
  crash nor a respawn. `smoke-reload`'s two-worker phase now asserts it
  that way — stop the worker that answered, the other must serve the new
  body 8 of 8, and both pids must be the ones the supervisor logged as
  re-forked — and was sabotaged in both layers before it counted: with
  `kill -STOP` made a no-op it fails as "SIGSTOP did not take", and with
  `_reload` altered to leave the old worker 1 alive while logging it as
  re-forked (so only the stop layer can see it) it fails naming the old
  body that worker served. `accept_placement.py serve --stop-winner` is
  the same measurement bare. `SO_REUSEPORT` per worker stays the change to
  make to the server only if a deployment, not a probe, shows the
  imbalance mattering.

  **Closed by:** none — no SPEC row can retire
  this; it is outside the server's own behaviour.

## Planned

Rows in [SPEC.md](SPEC.md) marked `planned` name a heading here, and the
checker fails if one does not resolve. So this section is the whole list of
things that page promises: adding a `planned` row means writing down what it
means here first.

Nothing is `planned` today; everything the sheet promises is `verified` or
`out of scope`. The design notes for the last four things this section held,
all built since:

- [A conformance-suite tier](notes/conformance-suite-tier.md)
- [Structured CI results](notes/structured-ci-results.md)
- [Traceability: stable ids, then declared coverage](notes/traceability.md)
- [Proven once, unloaded: an inventory of the gates with that shape](notes/proven-once-unloaded.md)

## Not planned, and why

Recorded so they are not re-proposed. Each was considered against the one
number that frames this server's Python-hosting product: the Mojo HTTP
layer alone does 116k rps/core on `hello`, the executor does 61k, uvicorn
with uvloop does 82k and `uvicorn --loop asyncio` does 58k. Everything
between 116k and 61k is Python-side per-request work and the
loop↔executor handoff — so optimising the 116k layer buys nothing here.

- **io_uring as a third backend.** Linux-only, a whole event-loop
  implementation to maintain beside kqueue and epoll, and it optimises the
  layer that is not the bottleneck.
- **A SIMD timer wheel.** The loop already does a 1 Hz O(1024) sweep with
  no heap; there is no timer cost to remove.
- **SIMD request parsing.** Done — `lightbug_http/parsing.mojo`.
- **Native Mojo coroutines replacing asyncio Tasks.** The application is
  Python; its awaits are asyncio's. Replacing the executor's task
  machinery would mean reimplementing asyncio, not avoiding it.
- **Arenas / SoA allocation in the loop.** Evidence-gated rather than
  refused: profile `hello` first and pursue only if allocation is >15% of
  the layer's time. `mojo-framework/packages/m0-data` has an SoA arena to
  start from.

## Recently resolved

The two longest write-ups are design notes:

- **A request body still arriving at SIGTERM held the drain to its deadline** — resolved; the write-up is [A request body still arriving at SIGTERM held the drain to its deadline — resolved](notes/request-body-at-sigterm.md).
- **The WebSocket close path RSTing instead of FINning** — resolved v0.15.1; the write-up is [The WebSocket close path RSTing instead of FINning — resolved v0.15.1](notes/websocket-close-rst.md).



## Design notes

The engineering record: long-form, dated, kept as written. Each was a section
of this page until 2026-09-03, when the page became state-only.

**How it got here**

- [v0.1.0: the first release](notes/first-release.md)
- [The Django server aims](notes/django-server-aims.md)

**Built, and how** (the Django server work, in order)

- [Hold on a pool thread: the refusal that keeps `--realtime` off real applications](notes/hold-on-a-pool-thread.md)
- [Streamed WSGI bodies — shipped 2026-08-27](notes/streamed-wsgi-bodies.md)
- [Hardening the streaming seam — shipped 2026-08-27](notes/streaming-seam-hardening.md)
- [The WebSocket send window — shipped 2026-08-28](notes/websocket-send-window.md)
- [The loop inversion — in progress 2026-08-28](notes/loop-inversion.md)
- [The outbox sweep — taken, scoped (2026-08-29)](notes/outbox-sweep.md)
- [Pacing the pump's loop thread](notes/pump-pacing.md)
- [The Mojo handler pool — shipped 2026-08-28](notes/mojo-handler-pool.md)
- [The detached loop — shipped 2026-09-03](notes/detached-loop.md)
- [The executor's per-request Python work, and the C-API head read — shipped 2026-09-04](notes/executor-python-objects.md)
- [Mojo language capabilities, surveyed 2026-08-28](notes/mojo-language-capabilities.md)
- [Considered, not built: routes that carry a function](notes/routes-that-carry-a-function.md)

**The gates and the evidence**

- [A conformance-suite tier](notes/conformance-suite-tier.md)
- [Structured CI results](notes/structured-ci-results.md)
- [Traceability: stable ids, then declared coverage](notes/traceability.md)
- [Proven once, unloaded: an inventory of the gates with that shape](notes/proven-once-unloaded.md)

**Open questions, and questions since answered**

- [The desktop-Mac server, and what the wheel gives up to ship](notes/desktop-mac-server.md)
- [MiniLM on the Neural Engine, served — measured 2026-09-04](notes/coreml-embeddings.md)
- [Inbound WebSocket flow control — shipped 2026-08-31](notes/inbound-websocket-flow-control.md)
- [The drain does not read a request body in flight — resolved](notes/drain-and-request-bodies.md)

**Post-mortems**

- [A request body still arriving at SIGTERM held the drain to its deadline — resolved](notes/request-body-at-sigterm.md)
- [The WebSocket close path RSTing instead of FINning — resolved v0.15.1](notes/websocket-close-rst.md)
