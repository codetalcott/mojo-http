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
under the same staleness rule. NOT MET until a real application runs on
the layer, which is the honest reading of a layer proven by demos; standing
decisions about it are in [DECISIONS.md](DECISIONS.md).

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

- **A WSGI hold replays nothing on reconnect.** `M0-Hold: stream`
  subscribes to the loop's `SSERegistry`, whose `Last-Event-ID` handling is
  the redelivery filter alone (`event_id > last_event_id`): a reconnecting
  client is not re-sent what it has, and events published while it was gone
  are not delivered. Only `DatastarStream` keeps the bounded journal
  (SPEC I10). RUNNING.md and the m0pub docstring said "replay covers them"
  until 2026-09-17, and an application that believed it dropped its own
  catch-up path; desk keeps a poll beside the stream for this reason.

  **Closed by:** none — a bounded per-channel journal in the registry (the
  `DatastarStream` shape, sized in frames, restored by the application if
  it must survive a restart) would retire it, gated by a smoke that
  reconnects a WSGI hold with `Last-Event-ID` after a publish; whether to
  build it is an open decision, and until it is taken the docs say
  suppression only.

- **The Linux wheel misses RHEL 9 by one glibc minor.** The binary requires
  glibc 2.35 (the Mojo toolchain's output, not the build image's) and the
  wheel is tagged `manylinux_2_35`, which covers Ubuntu 22.04 and Debian 12
  but not RHEL 9 at 2.34. `pip` declines the wheel rather than installing
  one that crashes. Reaching 2.34 means building inside a `manylinux_2_34`
  container; deferred until a release needs the reach.

  **Closed by:** none — outside the server's own behaviour.

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

- **On macOS, a build made beside an installed MAX carries the parallel
  runtime.** `mojo build` there links `libAsyncRTMojoBindings` into every
  binary once `max-core` sits beside the compiler, whether or not the
  source imports `max.algorithm`; on Linux it links it only where named.
  Measured on CI (2026-09-25): the same demo-mount `bin/m0serve` bundled
  three runtime files in the MAX-free `apple-silicon` job and four after
  `uv sync --group max`. The refusals of E32 (the Mojo host, `M0_WORKERS`
  above 1) and E33 (m0serve, `--workers N` and `--reload`) read the loaded
  images, so on such a machine they fire for a binary that never calls
  `parallelize`. `M0_THREADS` serves the host's case and `--spawn-workers`
  m0serve's; the shipped `m0serve` wheel is built without MAX and is not
  affected.

  **Closed by:** none — a toolchain that links the runtime only where it
  is named, or a fact that can tell a loaded runtime from a used one,
  retires it. `smoke-serve-parallel-runtime`'s control phase reads the
  binary's own load commands, so the day the link disappears its macOS
  line changes from "refused at two workers" to "passes".

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
Mojo HTTP layer alone does <!-- num:hello-rps-k@1 -->209.5<!-- /num -->k rps/core on
`hello`, the executor does <!-- num:asgi-m0-rps-k@1 -->84.3<!-- /num -->k, uvicorn with
uvloop does <!-- num:asgi-uvloop-rps-k@1 -->85.3<!-- /num -->k and `uvicorn --loop asyncio`
does <!-- num:asgi-uvicorn-rps-k@1 -->60.3<!-- /num -->k. Everything between the first two
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
  `Accept`, `Accept-Encoding` (`negotiate_encoding`, codec-agnostic, for
  callers with precompressed variants) and `Accept-Language`
  (`negotiate_language`, RFC 4647 matching). The framework ships no
  compressor.

## Recently resolved

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
- [MiniLM on the Neural Engine, served — measured 2026-09-04](notes/coreml-embeddings.md)
- [Inbound WebSocket flow control — shipped 2026-08-31](notes/inbound-websocket-flow-control.md)
- [The drain does not read a request body in flight — resolved](notes/drain-and-request-bodies.md)

**Post-mortems**

- [A request body still arriving at SIGTERM held the drain to its deadline — resolved](notes/request-body-at-sigterm.md)
- [The WebSocket close path RSTing instead of FINning — resolved v0.15.1](notes/websocket-close-rst.md)
