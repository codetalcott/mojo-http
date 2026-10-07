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
gate dedicated to it". Gating an `implemented` row has found a real defect
four times out of four (A4, I16, L17, A11), so those rows are both the
finish line and the highest-yield work.

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
under the same staleness rule. MET on 2026-10-02 by `unotes`, written
outside the tree by this repository's owner to exercise the layer: the
record says what that does and does not show, an independent author's
application among the second. Standing decisions about the layer are in
[DECISIONS.md](DECISIONS.md).

`poe check-milestones` gates the rot: every known issue carries a
`Closed by:` line naming SPEC rows or `none`, and an issue whose rows are
all `verified` fails the build until it is moved to Recently resolved. The
soak's staleness is reported rather than gated, because nobody can re-run
somebody else's Django projects inside the pull request that trips it.

## Known issues

- **The asyncio executor cannot run on free-threaded CPython.** Mojo's
  stdlib lays `PyObject` out for the GIL build (measured on 1.0.0 and not
  re-measured since the pin moved to 1.1.0; the weekly `py-canary` run is
  what answers it), so the executor's
  in-process Python type (`ExecutorPort`) segfaults on a free-threaded
  build (modular/modular#5726). The server refuses instead of crashing: an
  ASGI application on such a build exits 78, `--doctor` reports the same
  check, and under `--workers` the supervisor passes the 78 up. So an ASGI
  application cannot run under `--threads` on this toolchain. WSGI is
  unaffected.

  **Closed by:** none — an upstream fix to the `PyObject` layout retires
  it; the re-test is `smoke-django-realtime` phase 6 on 3.14t, with L18
  keeping the refusal honest until then. Retiring it also means turning
  `smoke-mounts-threads`' pinned ASGI refusal back into a served ASGI mount
  beside the WSGI ones (SPEC M23), the mixed phase `smoke-hybrid` carried
  as phase 3t until 2026-09-14.

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

  Past the notation, a number can differ too, because Mojo 1.1's `Float64`
  printing and parsing are not correctly rounded (the next entry): binary
  `text()` of `6.0146505155939864e16` is `6.014650515593986e+16`, a
  neighbouring double, and text mode's `float()` can differ from binary
  `float()`, which decodes exactly. `Float32` printing has the same
  defect, which is why `float4` is not rendered through it. SPEC O11
  claims only the types that agree.

  **Closed by:** none — a design round retires it: a calendar and the
  session's `TimeZone` for timestamps, `float4out` and `float8out`'s
  notation and a correctly rounded printer and parser for floats, and
  `bytea_output` for `bytea`. An application that reads these types in
  binary mode is what would schedule it; until then, read them in text
  mode.

- **Mojo 1.1's `Float64` printing and parsing are not correctly rounded.**
  Every miss is one unit in the last place, in both directions. Printing:
  stepping through the bit patterns of every exponent, 23 of 75,388
  doubles printed as text naming a neighbouring double, all between about
  2e16 and 6e19, where about one random double in twenty misses; `String()`
  of `2.0502092240948628e16` is `2.050209224094863e+16`. Parsing: the
  shortest forms of 47 of 60,000 random doubles parsed to a neighbour, at
  magnitudes from 1e-295 to 1e22, and 55 of another 60,000, most between
  1e16 and 1e22 and a few from 1e-297 to 1e276;
  `Float64("2.3914322253667574e+17")` is one below the double it names.
  Measured on Mojo 1.1.0 against CPython's correctly rounded `float()` and
  `repr()`.

  Two readers here parse with it. m0-postgres's text-mode `float()` parses
  the server's shortest form, so it and binary `float()`, which decodes
  the bits exactly, answered different doubles for 7 of 3,000 random
  `float8` rows in one run and 2 of 3,000 in another. m0-core's
  `parse_json_number` reads a JSON number the same way, one below on
  `2.3914322253667574e+17`. Printing matters where printed text is read
  back as a number, as binary `text()` of a `float8` is (the entry above).

  **Closed by:** none — an upstream defect. A Mojo release whose
  conversions round correctly retires it, and
  `scripts/probes/float64_rounding_probe.mojo` is the re-test after a
  toolchain bump: it exits 1 while its known misses still miss, and a
  clean exit is the cue to sweep again. If an application needs exact
  round trips before then, an in-tree correctly rounded parser and printer
  would retire it for the readers here.

## Planned

A `planned` row in [SPEC.md](SPEC.md) names a heading here, and the checker
fails if it does not resolve. **Nothing is planned**: the server's last two
rows (L25 and L26, from serving FastHTML's own examples beside uvicorn)
shipped on 2026-09-23, and the application layer's last (N13, sessions and
CSRF behind a login) on 2026-09-12. A row added here names the application
that pulls it, the gate that will verify it, and the [decision](DECISIONS.md)
it retires, before it is built.

What stands between the application layer and its milestone is no longer
a row but the soak: an application outside `apps/` running on `Views` and
`Fragment`, recorded in [REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md).

The last entries, all built:

- [A login on the notes app — shipped 2026-09-12](notes/a-login-on-the-notes-app.md)
- [A Datastar form, end to end — shipped 2026-09-12](notes/a-datastar-form-end-to-end.md)
- [An SSE hold from a Mojo mount — shipped 2026-09-11](notes/hold-from-a-mojo-mount.md)
- [Accept sharing: workers sharing a listener share its connections](notes/accept-sharing.md)
- [A conformance-suite tier](notes/conformance-suite-tier.md)
- [Structured CI results](notes/structured-ci-results.md)
- [Traceability: stable ids, then declared coverage](notes/traceability.md)
- [Proven once, unloaded: an inventory of the gates with that shape](notes/proven-once-unloaded.md)

## Not planned, and why

Recorded so they are not re-proposed. The number that frames each: the
Mojo HTTP layer alone does <!-- num:hello-rps-k@1 -->229.1<!-- /num -->k rps/core on
`hello`, the executor does <!-- num:asgi-m0-rps-k@1 -->85.8<!-- /num -->k, uvicorn with
uvloop does <!-- num:asgi-uvloop-rps-k@1 -->85.0<!-- /num -->k and `uvicorn --loop asyncio`
does <!-- num:asgi-uvicorn-rps-k@1 -->58.9<!-- /num -->k. Everything between the first two
figures is Python-side per-request work and the loop-to-executor handoff, so
optimising the HTTP layer buys nothing here.

- **io_uring as a third backend.** Linux-only, a whole event-loop
  implementation to maintain beside kqueue and epoll, and it optimises the
  layer that is not the bottleneck.
- **A SIMD timer wheel.** The loop already does a 1 Hz O(1024) sweep with
  no heap; there is no timer cost to remove.
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
  called were removed on 2026-09-29 (DECISIONS D54). The framework ships no
  compressor.

## Recently resolved

- **A WSGI hold replayed nothing on reconnect** (`M0-Hold: stream` subscribed to a registry whose `Last-Event-ID` handling was the redelivery filter alone, so every application kept a poll beside the stream) — resolved 2026-10-06 (I33, D65): each loop journals the last `--replay-frames` published frames and a reconnecting hold is caught up from it, all or nothing, with one unnumbered `m0-gap` event where the journal cannot supply what was missed, and an id from a previous incarnation clamped rather than left to starve the client. The write-up is [A hold that replays — 2026-10-06](notes/a-hold-that-replays.md).
- <!-- observed: asgi_bare and wsgi_bare under m0serve, curl, 2026-09-23; FastHTML's examples under m0serve 1.5.x and uvicorn, 2026-09-22 (REAL_APP_VALIDATION.md) -->**Two ASGI loading and scope differences from uvicorn** (a request whose chunked body the loop decoded reached the application with both `transfer-encoding: chunked` and a `content-length`, and a GET with a `content-length: 0` and a `connection: keep-alive` its client never sent; a module calling `asyncio.create_task` at import, FastHTML's first official example, failed to load with a bare `RuntimeError: no running event loop`) — resolved 2026-09-23 by L25 and L26. A parsed request carries the headers its client sent: the outgoing constructor it used to be built through no longer fills in a length, a `Connection` and a `Host`, and a de-chunked body is described by its length with its `chunked` coding removed. The WSGI environ follows, mapping the same headers. The import is refused by name, with the fix, a lifespan startup handler, from the server, `--doctor` and discovery alike; uvicorn refuses the same module without `--reload`. Both conformance steps read the scope and the environ back, and the ASGI step loads the module.
- <!-- observed: asgi_bare and wsgi_bare under m0serve at da6de53, raw sockets, 2026-09-23; FastHTML's examples under m0serve 1.5.x and uvicorn, 2026-09-22 (REAL_APP_VALIDATION.md) -->**The gateway rewrote parts of an application's response head** (a redirect, a 204 and FastHTML's default 404 page went out as `application/octet-stream`, a `FileResponse` HEAD as `content-length: 0`, and every 204 and 304 with `content-length: 0`, a native one included) — resolved 2026-09-23 by A21 and K12: the gateway relays the head as sent, adding only the framing that is the server's — a buffered body's measured length, and on a HEAD the application's own — and the event loop drops a length and a body from every 1xx and 204, whoever set them, keeping only a 304's own length. Found beside them and fixed with them (L27): a HEAD to a streaming ASGI route was streamed like a GET, and the loop wrote the whole body after the head, 10,000 of 10,000 bytes, where a keep-alive client reads its next response; a HEAD to a hold or a native SSE route was held as the stream a GET opens, the same way. `scripts/head_probe.py` reads each head in both conformance steps, and a request after it on the same connection.
- <!-- observed: FastHTML's `xtermjs` example under m0serve 1.5.x and uvicorn, 2026-09-22 (REAL_APP_VALIDATION.md) -->**A process the application started inherited the server's sockets** (FastHTML's terminal example took 10 s to close a WebSocket, because the shell it had started held the connection) — resolved 2026-09-23 by G16: every descriptor the server creates is close-on-exec, atomically on Linux and by a second call straight after on macOS; the spawned-worker hand-off keeps exactly the descriptors the new image adopts across its own exec, where it used to keep them across every exec in every mode; and `m0pub` writes only to a bus it can see, never into a child's own file on an inherited number. `smoke-exec-inherit` requires a child started with `close_fds=False` to hold nothing of the server's in six shapes.
- **`mojo build` needs a C compiler on Linux and nothing said so** (a `python:*-slim` image failed with `unable to find suitable c compiler for linking`, after the whole compile) — resolved 2026-09-20 for an application built with the `m0` CLI (N25): `m0 build` and `m0 doctor` check before running the compiler and name the fix, `apt-get install build-essential` or the platform's own. The check is not the one first planned, on two measured counts: mojo 1.1.0 looks for the literal name `cc` and nothing else, so a machine with `gcc` and no `cc` is refused by name, and a `cc` that exists and cannot link (gcc without `libc6-dev`) is caught by linking a one-line program. Inside this repository nothing changes — `mojo build` by hand still says what it said, and `deploy/mojo/Dockerfile` installs `build-essential`. The write-up is [The m0 wheel: source, an exact pair, and a CLI that refuses — 2026-09-20](notes/the-m0-wheel.md).
- **Mojo 1.0's `PythonObject` interop leaked a reference per call argument and per `__setitem__` value** — resolved 2026-09-18 by moving the pin to Mojo 1.1.0, which carries the upstream fix (modular/modular#6833). Measured in this tree against 1.0.0 as the null case: +1001 references per 1000 operations before, 0 after. The bridge keeps its raw C API environ build, which was always the faster path as well as the safe one, so nothing about the request path changes; what changes is that a per-request `PythonObject` argument is now a performance preference rather than a correctness constraint. The write-up is [The pin moves to Mojo 1.1.0 — 2026-09-18](notes/the-pin-moves-to-1-1-0.md).
- **The Mojo host's drain and its producer join ran in sequence** — resolved 2026-09-17 with the pool lane (E26, D31): the loop stamps the producer's stop word as its drain begins and both joins count from that stamp, so a request in flight at SIGTERM beside a step past its bound leaves inside one bound. The premise as first recorded was wrong in one detail — the drain ends a HELD stream at once, so what stretches it is a request in flight, not a stream — and the gate holds a request of a few seconds instead. The write-up is [The ramp test: lanes in the host, one module on two hosts — 2026-09-17](notes/the-ramp-test.md).
- **Sessions and CSRF behind a login** (N13) — built 2026-09-12: a stateless signed cookie and a CSRF token derived from its tag, on `apps/fragment_notes` with one user; `m0_http.session` beside `grant.mojo`, forged and admitted on the wire by a CPython issuer, five rules sabotage-proven. D15 retired; D24 and D25 record what it deliberately is not. The write-up is [A login on the notes app — shipped 2026-09-12](notes/a-login-on-the-notes-app.md).
- **A Datastar form, end to end** (N12) — built 2026-09-12: the todo demo's rename form, `form(req)` on the other side, a smoke on the wire and a Chromium run that recorded what the pinned bundle sends; D21 confirmed. The write-up is [A Datastar form, end to end — shipped 2026-09-12](notes/a-datastar-form-end-to-end.md).
- **Prefork workers did not share a listener's connections** (the same worker won 32 of 32 on macOS and 23–31 of 32 on Linux, so `--workers 2` served a keep-alive load at one worker's throughput) — resolved by E16, the accept-sharing hand-off; the write-up is [Accept sharing — shipped 2026-09-05](notes/accept-sharing.md).
- **A request body still arriving at SIGTERM held the drain to its deadline** — resolved; the write-up is [A request body still arriving at SIGTERM held the drain to its deadline — resolved](notes/request-body-at-sigterm.md).
- **The WebSocket close path RSTing instead of FINning** — resolved v0.15.1; the write-up is [The WebSocket close path RSTing instead of FINning — resolved v0.15.1](notes/websocket-close-rst.md).

## Design notes

The engineering record: long-form, dated, kept as written.

**How it got here**

- [v0.1.0: the first release](notes/first-release.md)
- [The Django server aims](notes/django-server-aims.md)

**Built, and how** (the Django server work, in order)

- [Hold on a pool thread: the refusal that keeps `--realtime` off real applications](notes/hold-on-a-pool-thread.md)
- [Streamed WSGI bodies — shipped 2026-08-27](notes/streamed-wsgi-bodies.md)
- [Hardening the streaming seam — shipped 2026-08-27](notes/streaming-seam-hardening.md)
- [The WebSocket send window — shipped 2026-08-28](notes/websocket-send-window.md)
- [The loop inversion — in progress 2026-08-28](notes/loop-inversion.md)
- [Where the loop inversion wins, on a constrained box — 2026-09-08](notes/inversion-on-a-constrained-box.md)
- [Do the benchmark page's conclusions hold on Linux? — 2026-09-08](notes/the-conclusions-on-linux.md)
- [The outbox sweep — taken, scoped (2026-08-29)](notes/outbox-sweep.md)
- [Pacing the pump's loop thread](notes/pump-pacing.md)
- [The Mojo handler pool — shipped 2026-08-28](notes/mojo-handler-pool.md)
- [The detached loop — shipped 2026-09-03](notes/detached-loop.md)
- [The executor's per-request Python work, and the C-API head read — shipped 2026-09-04](notes/executor-python-objects.md)
- [Accept sharing: workers sharing a listener share its connections — shipped 2026-09-05](notes/accept-sharing.md)
- [Scheduling stickiness: which worker wins the accept race is CPU placement, not load](notes/accept-placement.md)
- [Mojo language capabilities, surveyed 2026-08-28](notes/mojo-language-capabilities.md)
- [Considered, not built: routes that carry a function](notes/routes-that-carry-a-function.md)
- [Periodic work off the event loop — shipped 2026-09-14](notes/periodic-work-off-the-loop.md)

**The gates and the evidence**

- [A conformance-suite tier](notes/conformance-suite-tier.md)
- [Structured CI results](notes/structured-ci-results.md)
- [Traceability: stable ids, then declared coverage](notes/traceability.md)
- [Proven once, unloaded: an inventory of the gates with that shape](notes/proven-once-unloaded.md)

**Open questions, and questions since answered**

- [The desktop-Mac server, and what the wheel gives up to ship](notes/desktop-mac-server.md)
- [Mojo 1.0's PythonObject leak, and what the pin bump will hit — answered by the bump](notes/pythonobject-leak-and-the-pin-bump.md)
- [The pin moves to Mojo 1.1.0 — 2026-09-18](notes/the-pin-moves-to-1-1-0.md)
- [The host leaves the fork — 2026-09-18](notes/the-host-leaves-the-fork.md)
- [The page shell becomes a trait — 2026-09-18](notes/the-page-shell-becomes-a-trait.md)
- [A vocabulary an application defines — 2026-09-18](notes/a-vocabulary-an-application-defines.md)
- [Loops on threads — 2026-09-18](notes/loops-on-threads.md)
- [Threads first for m0 applications — 2026-09-25](notes/threads-first-for-m0-apps.md)
- [The demo in its own image — 2026-09-18](notes/the-demo-in-its-own-image.md)
- [Flags and a doctor for the host — 2026-09-19](notes/flags-and-a-doctor-for-the-host.md)
- [The m0 wheel: source, an exact pair, and a CLI that refuses — 2026-09-20](notes/the-m0-wheel.md)
- [The scaffold: two templates that compile where they lie — 2026-09-20](notes/the-scaffold.md)
- [`m0 dev`, `m0 image`, and a release nobody has run — 2026-09-20](notes/dev-image-and-a-release.md)
- [The Mojo stack's pages, and a front door CI walks through — 2026-09-20](notes/the-mojo-stack-pages.md)
- [The scaffold's upgrade path — 2026-09-27](notes/the-scaffold-upgrade-path.md)
- [A login in the layer — 2026-09-27](notes/a-login-in-the-layer.md)
- [A resource over a table — 2026-10-02](notes/a-resource-over-a-table.md)
- [A database that remembers what changed — 2026-10-02](notes/a-database-that-remembers-what-changed.md)
- [MiniLM on the Neural Engine, served — measured 2026-09-04](notes/coreml-embeddings.md)
- [Inbound WebSocket flow control — shipped 2026-08-31](notes/inbound-websocket-flow-control.md)
- [The drain does not read a request body in flight — resolved](notes/drain-and-request-bodies.md)

**Post-mortems**

- [A request body still arriving at SIGTERM held the drain to its deadline — resolved](notes/request-body-at-sigterm.md)
- [The WebSocket close path RSTing instead of FINning — resolved v0.15.1](notes/websocket-close-rst.md)
