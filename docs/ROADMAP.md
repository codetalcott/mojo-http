# Roadmap

The project's state. What the server does is [SPEC.md](SPEC.md), one row per
capability with the gate that proves it. The milestones below are
computed rather than remembered, and 1.0 has shipped, so what this reports
now is whether the conditions it was taken on still hold:

```bash
uv run poe milestones
```

The reasoning behind the design is in the [design notes](#design-notes).

## Milestones

Three derive from row status in SPEC.md; no row carries a milestone of its
own.

**beta**: no row is `implemented`, the sheet's word for "in the tree with no
gate dedicated to it".

**1.0**: beta, plus every `planned` row outside section N built or moved
to `out of scope` with a reason, plus a soak against real applications
([REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md)) no more than two minor
versions behind the tree, plus each known issue below naming what retires
it. Section N is left out because 1.0 shipped before the section existed;
its rows are the next milestone's.

**the application layer**: no section-N row `implemented`, every section-N
`planned` row built or moved to `out of scope` with a reason, and a soak on
the layer — an application outside `apps/` running on `Views` or
`Fragment`, recorded in
[REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md#the-application-layer)
under the same staleness rule. MET on 2026-10-02 by `unotes`, which this
repository's owner wrote outside the tree to exercise the layer. The
record says what that shows and what it does not; an application by an
independent author is among what it does not. Standing decisions about the layer are in
[DECISIONS.md](DECISIONS.md).

`poe check-milestones` gates the rot: every known issue carries a
`Closed by:` line naming SPEC rows or `none`, and an issue whose rows are
all `verified` fails the build until it is moved to Recently resolved. The
soak's staleness is reported rather than gated, because nobody can re-run
somebody else's Django projects inside the pull request that trips it.

## Known issues

- **The asyncio executor cannot run on free-threaded CPython.** Mojo's
  stdlib lays `PyObject` out for the GIL build, so the executor's
  in-process Python type (`ExecutorPort`) segfaults on a free-threaded
  build (modular/modular#5726, open). Measured on 1.0.0, and on 1.1.0 and
  1.2.0 under 3.14.7t on 2026-10-22: building the module crashes in
  `_PyModule_CreateInitialized`; Modular's `main` the same day still
  declares the two-field header. The server refuses instead of crashing: an
  ASGI application on such a build exits 78, `--doctor` reports the same
  check, and under `--workers` the supervisor passes the 78 up. So an ASGI
  application cannot run under `--threads` on this toolchain. WSGI is
  unaffected.

  **Closed by:** none — an upstream fix to the `PyObject` layout retires
  it. The refusal comes before the type is built, so no smoke can see the
  fix: `scripts/probes/free_threaded_module_probe.mojo` under a 3.14t
  `libpython` is the re-test after a toolchain bump, and a clean exit is
  the cue to lift the refusal and run `smoke-django-realtime` phase 6 on
  3.14t, with L18 keeping the refusal honest until then. Retiring it also means turning
  `smoke-mounts-threads`' pinned ASGI refusal back into a served ASGI mount
  beside the WSGI ones (SPEC M23).

- **The Linux wheel misses RHEL 9 by one glibc minor.** The wheel is tagged
  `manylinux_2_35`, which covers Ubuntu 22.04 and Debian 12 but not RHEL 9
  at 2.34; `pip` declines it rather than installing one that crashes. The
  floor is set by the Mojo runtime the wheel bundles, not by the build
  host: measured on the 1.11.0 wheels, `_bin/m0serve` itself needs only
  `GLIBC_2.34`, `libAsyncRTRuntimeGlobals.so` needs `__rseq_size@GLIBC_2.35`
  and `libKGENCompilerRTShared.so` needs
  `std::condition_variable::wait@GLIBCXX_3.4.30`, GCC 12's libstdc++, which
  RHEL 9 does not ship. So building inside a `manylinux_2_34` container,
  the closer this issue once named, would neither lower the tag nor make
  the wheel run there — and the pinned compiler itself fails to start in
  that container on the same symbol
  ([the measurement](notes/the-floor-is-the-runtime.md)).

  **Closed by:** none — the toolchain's runtime. It retires itself the
  release whose wheel's `libAsyncRTRuntimeGlobals.so` needs nothing above
  `GLIBC_2.34` and whose `libKGENCompilerRTShared.so` nothing above
  `GLIBCXX_3.4.29`: `wheel_tag.py` then measures `manylinux_2_34` on its
  own and names the file that set it in the build log, and the release's
  consume job installs on a 2.34 host.

- **Under `--workers`, which worker wins an accept is CPU placement, not
  load.** Two workers sharing one listener: the worker on the client's own
  CPU loses every accept race, measured 80 of 80 with the probe pinned
  beside it. Accept sharing (E16) hands connections to the least-loaded
  sibling, so a deployment sees the hand-off rather than the race, and
  `smoke-reload`'s two-worker phase asserts failover with SIGSTOP rather
  than fairness. Per-worker
  `SO_REUSEPORT` listeners balance in every placement and are not adopted,
  because a connection queued at a worker that dies is reset until the
  respawn rebinds. The measurements are in
  [the note](notes/accept-placement.md).

  **Closed by:** none — outside the server's own behaviour.

- **Beside an installed MAX, the parallel runtime is loaded where nothing
  names it: in every macOS build, and under `mojo run` on Linux too.**
  `mojo build` on macOS links `libAsyncRTMojoBindings` into every binary
  once `max-core` sits beside the compiler, whether or not the source
  imports `max.algorithm`; on Linux it links it only where named.
  Measured on CI (2026-09-25): the same demo-mount `bin/m0serve` bundled
  three runtime files in the MAX-free `apple-silicon` job and four after
  `uv sync --group max`. `mojo run` builds no binary: the program runs
  inside the compiler's process, which maps the runtime once `max-core` is
  installed, so there `parallel_runtime_linked()` answers true for any
  source — measured on Linux on 2026-09-26, where the same source built
  answers false (macOS's builds read as linked already). The refusals of
  E32 (the Mojo host, `M0_WORKERS` above 1) and E33 (m0serve, `--workers
  N` and `--reload`) read the loaded images, so on such a machine they
  fire for a binary, or a `mojo run`, that never calls `parallelize`.
  `M0_THREADS` serves the host's case and `--spawn-workers` m0serve's; the
  shipped `m0serve` wheel is built without MAX and is not affected.

  What a contributor with the `max` group synced meets: every `mojo run`
  of a host application above one worker exits 78 — `smoke-shutdown`,
  `smoke-counter` and `smoke-sim-loop` each start one at two workers, and
  pass with the group unsynced, as CI runs them (it syncs the group for
  its two MAX steps alone). The unit tests do not depend on the venv:
  `test_host.mojo` and `test_host_flags.mojo` supply the fact wherever a
  verdict is about something else, and follow it where they gather it —
  `test_host.mojo` assumed it absent until the 2026-09-26 pre-release run,
  where `sabotage-host`'s baseline failed on two tests with the group that
  its `parallel` arm needs.

  **Closed by:** none — a toolchain that links the runtime only where it
  is named and a `mojo run` that maps it only for a program that imports
  it, or a fact that can tell a loaded runtime from a used one, retires
  it. `smoke-serve-parallel-runtime`'s control phase reads the binary's
  own load commands, so the day the link disappears its macOS line changes
  from "refused at two workers" to "passes"; the `mojo run` half is
  re-tested by syncing the group and `mojo run`ning a program that prints
  `parallel_runtime_linked()`.

- **m0-postgres reads `timestamp`, `timestamptz`, `bytea` and `float4`
  differently in binary mode.** `binary=True` is one choice for the whole
  query, and for these types it changes what the readers return. Measured
  on 2026-09-28 against Postgres 17, the session in America/New_York:

  - `timestamp` and `timestamptz`: text mode's `text()` is the server's
    rendering (`2026-09-12 12:00:00`, and for a `timestamptz` the session's
    zone, `2026-09-12 08:00:00-04`); binary `text()` is the count of
    microseconds from 2000-01-01 (`842529600000000`), and binary `int()`
    answers that count where text mode raises.
  - `bytea`: text mode's `text()` is the escape `\x0080ff` and `bytes()`
    that escape's ASCII; binary `bytes()` is the raw bytes, and binary
    `text()` a `String` holding them unchecked, so not necessarily UTF-8
    (the hazard SPEC G14 describes).
  - `float4`: binary widens to a double, so `text()` and `float()` read
    `0.10000000149011612` where text mode reads `0.1`.
  - `float8`, and `float4` with it: binary `text()` is Mojo's notation, not
    the server's `float8out` or `float4out`: `100000.0`, `-0.0`, `inf` and
    `nan` where text mode has `100000`, `-0`, `Infinity` and `NaN`.

  Past the notation, a number can differ too, because Mojo's `Float64`
  printing is not correctly rounded (the next entry): binary `text()` of
  `6.0146505155939864e16` is `6.014650515593986e+16`, a neighbouring
  double. Through Mojo 1.1.0 the parser was not either, so text mode's
  `float()` could differ from binary `float()`, which decodes exactly;
  from 1.2.0 it reads the server's shortest form as the double it names.
  `Float32` printing has the same defect, so `float4` is not rendered
  through it. SPEC O11 claims only the types that agree.

  **Closed by:** none — a design round retires it: a calendar and the
  session's `TimeZone` for timestamps, `float4out` and `float8out`'s
  notation and a correctly rounded printer for floats, and
  `bytea_output` for `bytea`. An application that reads these types in
  binary mode is what would schedule it; until then, read them in text
  mode.

- **Mojo's `Float64` printing is not correctly rounded.** Every miss is
  one unit in the last place. Stepping through the bit patterns of every
  exponent, 23 of 75,388 doubles printed as text naming a neighbouring
  double, all between about 2e16 and 6e19, where about one random double
  in twenty misses; `String()` of `2.0502092240948628e16` is
  `2.050209224094863e+16`. Measured on Mojo 1.1.0 against CPython's
  correctly rounded `repr()`; the probe's five printing cases still miss
  on 1.2.0.

  Parsing missed too through 1.1.0 and does not from 1.2.0: the shortest
  forms of 120,000 doubles, 60,000 random bit patterns and 60,000 between
  1e15 and 1e23, each parse to the double they name, where 1.1.0 parsed
  41 and 3,401 of the same decimals to a neighbour
  ([the pin moves to 1.2.0](notes/the-pin-moves-to-1-2-0.md)). So the two
  readers that parse with it, m0-postgres's text-mode `float()` and
  m0-core's `parse_json_number`, read what they are given:
  `2.3914322253667574e+17`, one below on 1.1.0, is exact. Printing matters
  where printed text is read back as a number, as binary `text()` of a
  `float8` is (the entry above).

  **Closed by:** none — an upstream defect. A Mojo release whose printer
  rounds correctly retires it, and
  `scripts/probes/float64_rounding_probe.mojo` is the re-test after a
  toolchain bump: it exits 1 while its known misses still miss, and a
  clean exit is the cue to sweep again. If an application needs exact
  round trips before then, an in-tree correctly rounded printer would
  retire it for the readers here.

## Planned

A `planned` row in [SPEC.md](SPEC.md) names a heading here, and the checker
fails if it does not resolve. **Nothing is planned.** A row added here
names the application that pulls it, the gate that will verify it, and the
[decision](DECISIONS.md) it retires, before it is built.

## Not planned, and why

Recorded so they are not re-proposed. The number that frames each: the
Mojo HTTP layer alone does <!-- num:hello-rps-k@1 -->231.2<!-- /num -->k rps/core on
`hello`, the executor does <!-- num:asgi-m0-rps-k@1 -->84.6<!-- /num -->k, uvicorn with
uvloop does <!-- num:asgi-uvloop-rps-k@1 -->85.5<!-- /num -->k and `uvicorn --loop asyncio`
does <!-- num:asgi-uvicorn-rps-k@1 -->59.2<!-- /num -->k. Everything between the first two
figures is Python-side per-request work and the loop-to-executor handoff, so
optimising the HTTP layer buys nothing here.

- **io_uring as a third backend.** Linux-only, a whole event-loop
  implementation to maintain beside kqueue and epoll, and it optimises the
  layer that is not the bottleneck.
- **A SIMD timer wheel.** The loop already sweeps its slots once a second
  (1024 by default) with no heap; there is no timer cost to remove.
- **SIMD request parsing.** Done: `lightbug_http/http/parsing.mojo`.
- **Native Mojo coroutines replacing asyncio Tasks.** The application is
  Python; its awaits are asyncio's. Replacing the executor's task
  machinery would mean reimplementing asyncio, not avoiding it.
- <!-- observed: a threshold this entry sets for itself, not a measurement -->**Arenas / SoA allocation in the loop.** Evidence-gated rather than
  refused: profile `hello` first and pursue only if allocation is over 15%
  of the layer's time. `mojo-framework/packages/m0-data` has an SoA arena
  to start from.
- **Automatic `Vary` tracking and dynamic compression.** Negotiation covers
  `Accept`; the `Accept-Encoding` and `Accept-Language` negotiators nothing
  called were removed on 2026-09-29 (DECISIONS D54). The framework ships one
  compressor, for streams (D69, SPEC I45): a proxy compresses buffered
  responses, and the deploy target's leaves a stream alone.

## Recently resolved

Nothing yet in the 1.18.0 train. An issue resolved in an earlier train is
in the [changelog](../CHANGELOG.md) under the release that resolved it,
and in its note where it has one.

## Design notes

The design notes are [indexed here](notes/).
