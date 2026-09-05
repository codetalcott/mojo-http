# Roadmap

The project's state. What the server does is [SPEC.md](SPEC.md), one row per
capability with the gate that proves it. What remains before 1.0 is
computed:

```bash
uv run poe milestones
```

The reasoning behind the design is in the [design notes](#design-notes).

## Milestones

Both derive from row status in SPEC.md; no row carries a milestone of its
own.

**beta**: no row is `implemented`, the sheet's word for "in the tree with no
gate dedicated to it". Gating an `implemented` row has found a real defect
four times out of four (A4, I16, L17, A11), so those rows are both the
finish line and the highest-yield work.

**1.0**: beta, plus every `planned` row built or moved to `out of scope`
with a reason, plus a soak against real applications
([REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md)) no more than two minor
versions behind the tree, plus each known issue below naming what retires
it.

`poe check-milestones` gates the rot: every known issue carries a
`Closed by:` line naming SPEC rows or `none`, and an issue whose rows are
all `verified` fails the build until it is moved to Recently resolved. The
soak's staleness is reported rather than gated, because nobody can re-run
somebody else's Django projects inside the pull request that trips it.

## Known issues

- **The asyncio executor cannot run on free-threaded CPython.** Mojo 1.0's
  stdlib lays `PyObject` out for the GIL build, so the executor's
  in-process Python type (`ExecutorPort`) segfaults on a free-threaded
  build (modular/modular#5726). The server refuses instead of crashing: an
  ASGI application on such a build exits 78, `--doctor` reports the same
  check, and under `--workers` the supervisor passes the 78 up. So an ASGI
  application cannot run under `--threads` on this toolchain. WSGI is
  unaffected.

  **Closed by:** none — an upstream fix to the `PyObject` layout retires
  it; the re-test is `smoke-django-realtime` phase 6 on 3.14t, with L18
  keeping the refusal honest until then.

- **`mojo build` needs a C compiler on Linux and nothing says so.** It
  shells out for linking; a `python:*-slim` image fails with `unable to
  find suitable c compiler for linking`. Install `build-essential` beside
  `libsqlite3-dev` and `patchelf`.

  **Closed by:** none — outside the server's own behaviour.

- **The Linux wheel misses RHEL 9 by one glibc minor.** The binary requires
  glibc 2.35 (the Mojo toolchain's output, not the build image's) and the
  wheel is tagged `manylinux_2_35`, which covers Ubuntu 22.04 and Debian 12
  but not RHEL 9 at 2.34. `pip` declines the wheel rather than installing
  one that crashes. Reaching 2.34 means building inside a `manylinux_2_34`
  container; deferred until a release needs the reach.

  **Closed by:** none — outside the server's own behaviour.

- **Mojo 1.0's `PythonObject` interop leaks a reference per call argument
  and per `__setitem__` value.** The bridge works around it by building the
  environ through the raw C API and never passing a per-request object
  through those operations; `smoke-django`'s RSS guard (0 KB over 10k
  requests) is the instrument. The fix is upstream (modular/modular#6833),
  in every nightly from `1.1.0.dev2026081405` and in no stable release.
  What the pin bump will hit, measured by building the tree on a nightly,
  is in [the note](notes/pythonobject-leak-and-the-pin-bump.md).

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

## Planned

A `planned` row in [SPEC.md](SPEC.md) names a heading here, and the checker
fails if it does not resolve. Nothing is planned at the moment. The last
five entries, all built:

- [Accept sharing: workers sharing a listener share its connections](notes/accept-sharing.md)
- [A conformance-suite tier](notes/conformance-suite-tier.md)
- [Structured CI results](notes/structured-ci-results.md)
- [Traceability: stable ids, then declared coverage](notes/traceability.md)
- [Proven once, unloaded: an inventory of the gates with that shape](notes/proven-once-unloaded.md)

## Not planned, and why

Recorded so they are not re-proposed. The number that frames each: the
Mojo HTTP layer alone does 116k rps/core on `hello`, the executor does
61k, uvicorn with uvloop does 82k and `uvicorn --loop asyncio` does 58k.
Everything between 116k and 61k is Python-side per-request work and the
loop-to-executor handoff, so optimising the 116k layer buys nothing here.

- **io_uring as a third backend.** Linux-only, a whole event-loop
  implementation to maintain beside kqueue and epoll, and it optimises the
  layer that is not the bottleneck.
- **A SIMD timer wheel.** The loop already does a 1 Hz O(1024) sweep with
  no heap; there is no timer cost to remove.
- **SIMD request parsing.** Done: `lightbug_http/parsing.mojo`.
- **Native Mojo coroutines replacing asyncio Tasks.** The application is
  Python; its awaits are asyncio's. Replacing the executor's task
  machinery would mean reimplementing asyncio, not avoiding it.
- **Arenas / SoA allocation in the loop.** Evidence-gated rather than
  refused: profile `hello` first and pursue only if allocation is over 15%
  of the layer's time. `mojo-framework/packages/m0-data` has an SoA arena
  to start from.
- **Automatic `Vary` tracking and dynamic compression.** Negotiation covers
  `Accept`, `Accept-Encoding` (`negotiate_encoding`, codec-agnostic, for
  callers with precompressed variants) and `Accept-Language`
  (`negotiate_language`, RFC 4647 matching). The framework ships no
  compressor.

## Recently resolved

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
- [The outbox sweep — taken, scoped (2026-08-29)](notes/outbox-sweep.md)
- [Pacing the pump's loop thread](notes/pump-pacing.md)
- [The Mojo handler pool — shipped 2026-08-28](notes/mojo-handler-pool.md)
- [The detached loop — shipped 2026-09-03](notes/detached-loop.md)
- [The executor's per-request Python work, and the C-API head read — shipped 2026-09-04](notes/executor-python-objects.md)
- [Accept sharing: workers sharing a listener share its connections — shipped 2026-09-05](notes/accept-sharing.md)
- [Scheduling stickiness: which worker wins the accept race is CPU placement, not load](notes/accept-placement.md)
- [Mojo language capabilities, surveyed 2026-08-28](notes/mojo-language-capabilities.md)
- [Considered, not built: routes that carry a function](notes/routes-that-carry-a-function.md)

**The gates and the evidence**

- [A conformance-suite tier](notes/conformance-suite-tier.md)
- [Structured CI results](notes/structured-ci-results.md)
- [Traceability: stable ids, then declared coverage](notes/traceability.md)
- [Proven once, unloaded: an inventory of the gates with that shape](notes/proven-once-unloaded.md)

**Open questions, and questions since answered**

- [The desktop-Mac server, and what the wheel gives up to ship](notes/desktop-mac-server.md)
- [Mojo 1.0's PythonObject leak, and what the pin bump will hit](notes/pythonobject-leak-and-the-pin-bump.md)
- [MiniLM on the Neural Engine, served — measured 2026-09-04](notes/coreml-embeddings.md)
- [Inbound WebSocket flow control — shipped 2026-08-31](notes/inbound-websocket-flow-control.md)
- [The drain does not read a request body in flight — resolved](notes/drain-and-request-bodies.md)

**Post-mortems**

- [A request body still arriving at SIGTERM held the drain to its deadline — resolved](notes/request-body-at-sigterm.md)
- [The WebSocket close path RSTing instead of FINning — resolved v0.15.1](notes/websocket-close-rst.md)
