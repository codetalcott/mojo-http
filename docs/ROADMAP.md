# Roadmap

## v0.1.0 (released)

- `m0-core` — hashing (FNV-1a, xxHash32, wyhash64), SIMD JSON escape, JSON field parser
- `m0-http` — router, content negotiation, weak ETags, response cache, SSE with
  backpressure and Last-Event-ID replay, auth, CORS, config, health, JSON-lines
  access logging, graceful shutdown, multi-worker fork supervisor
- `lightbug_http` — maintained hard fork (see [NOTICE](../NOTICE))
- `m0-datastar` — Datastar v1.0.2 wire format, plus `DatastarStream` and
  `read_signals` to drive it from the server
- `m0-wsgi` — WSGI host: embeds CPython and runs Django or any other WSGI
  application on this server. Layers on `m0-http`; the only package here that
  depends on a Python runtime.
- `m0-sqlite` — SQLite bindings: connections, statements, typed columns,
  transactions. A sibling package; imports nothing else here.

### SQLite landed (done)

Chosen over a bespoke store by a benchmark with byte-parity enforced before
timing: marginally faster on JSON and HTML, 50x faster on point lookup, slower
only on `vnd.siren+bin` where the incumbent read a pre-serialized file.

Deliberately **not** built: a statement cache (measured within noise at
realistic row counts, ~10% at N=50 — not worth the ownership complexity), and a
materialized `+bin` cache (the only design that introduces a staleness failure
mode, and the 76x it chases is serve-path only, with the rebuild cost simply
moving to every write). Revisit either if a profile ever demands it.

### Datastar is wired (done)

`SSERegistry.notify_frame` queues a pre-formatted frame verbatim (with
`NO_EVENT_ID` for unnumbered frames), `sse_response()` builds the stream-opening
response with the `Cache-Control` header everyone forgets, `DatastarStream`
owns subscriptions and broadcasts, and `read_signals()` covers the request half.
`apps/datastar_counter` demonstrates multi-tab sync and is asserted in CI by
`poe smoke-counter`, which fails if a frame is ever double-framed again.

## Also in v0.1.0

Everything below started as the v0.2 plan and landed before the first
release instead.

### Examples

- `apps/notes_api/` — **done.** What the framework adds over the bare server:
  `Router` with `:id` and a real 405 with `Allow`, content negotiation (the
  same note as JSON or HTML, `*/*` resolving to JSON), ETag + `304`,
  RFC 9457 `problem+json` on every error, CORS via one `after_response` hook,
  and `M0_PORT` via `AppConfig`. In-memory store, deliberately not a
  database. Every feature is asserted end to end by `poe smoke-notes`.
- `apps/datastar_todo/` — **done, now SQLite-backed.** The flagship: live
  multi-tab sync over SSE. Where the counter broadcasts a signal, this
  broadcasts *HTML* — every mutation renders `<section id="todos">` once and
  `patch_elements` morphs it into every connected tab — and its per-item
  actions are `Router` routes with `:id`. Todo text is HTML-escaped before
  broadcast (the alternative is distributed stored XSS). The list is rows in
  SQLite (`M0_DB`), the first composition of `m0-sqlite` with the server —
  in `apps/`, where packages compose; the package itself still imports
  nothing here. SSE replay across restarts landed on top of it (see below):
  the app logs each broadcast frame to an `events` table and restores it
  into the stream's journal at boot. Because it links libsqlite3, the app
  is built-then-run, never `mojo run` (the test-sqlite rule). `poe
  smoke-todo` asserts the wire format, that a killed-and-restarted server
  comes back with the same list, *and* that a `Last-Event-ID` reconnect is
  caught up across the restart;
  the browser half was verified with Playwright in two real tabs
  (re-run after the SQLite conversion), which is also how two latent
  Datastar-syntax bugs got caught: v1.0.2 has no `on-load` plugin
  (`data-init` opens the stream) and keyed attributes are colon-separated
  (`data-on:click`, `data-bind:draft`) — the hyphen forms fail silently.
  The counter shipped with both and is fixed alongside.

The `build-apps` gate this section once called for now exists: `poe build-apps`
compiles every example to a temp directory, and CI runs it before the smoke
tests.

### Cross-worker SSE fan-out (done)

`M0_WORKERS>1` and SSE are no longer mutually exclusive. The design keeps
the per-process registries and adds a `BroadcastBus`: one `SOCK_DGRAM`
socketpair channel per worker, created before the fork so every process
inherits every descriptor. A broadcasting worker queues locally and writes
one datagram per peer channel (datagrams because message boundaries survive
concurrent writers — a pipe only guarantees that up to PIPE_BUF); each
worker's event loop drains its own channel and hands frames to the handler
through `sse_peer_frame`, the seventh `HTTPService` method. Event ids come
from a `SharedAtomics` slot — an `mmap(MAP_SHARED|MAP_ANON)` page of
atomics, also pre-fork — so ids stay globally unique and the redelivery
filter keeps working; the journal inserts by id so replay works on every
worker even when peer frames arrive out of order (that ordering test was
verified load-bearing against append-only recording). Respawned workers
take over the dead worker's index, and with it its bus channel.

Delivery to a stalled peer is fire-and-forget (drop on full, matching
per-slot backpressure), and cross-worker ordering is best-effort: two
workers broadcasting concurrently can reach a subscriber in either order
and the filter keeps the newer id — exactly right for state-patch frames,
a documented caveat for increments. `apps/datastar_counter` is the
reference wiring (shared-memory count, X-Worker header), and
`poe smoke-counter` proves its streams span both workers before asserting
that a single POST reaches every stream.

### SSE replay across restarts (done)

`DatastarStream` now honours `Last-Event-ID`. Every broadcast is journaled
in-memory (bounded, default 64 frames, SoA parallel lists); a reconnecting
client — the header is what marks one; its absence marks a new consumer, who
gets no history — is caught up through `SSERegistry.queue_frame`, the
single-slot twin of `notify_frame` with the same delivery filter and
backpressure, so the replayed id also suppresses the same frame arriving
again off the live feed. Not `PatchJournal`: that stores *patches keyed by
ETag* for the HTTP cache story, the wrong shape for verbatim frame bytes.

The restart half is deliberately an application decision, because only the
app has durable storage: persist `(id, url, frame_for(id))` after each
broadcast, feed rows back through `restore()` at boot — which also seeds the
id counter, keeping ids monotonic across restarts, the property that makes a
pre-restart `Last-Event-ID` meaningful at all. An id *ahead* of the counter
(an incarnation whose history this process never had) is clamped, so a
non-persisting app degrades to resume-live instead of a muted stream — the
exact failure the old code avoided by ignoring the header entirely.
`apps/datastar_todo` wires it in ~15 lines and `poe smoke-todo` asserts a
reconnect across a real kill-and-restart replays the missed frame, skips the
already-seen one, and serves a fresh consumer no history.

### HTTP client (done, now with keep-alive)

`Client` in m0-http sends outbound HTTP/1.1: GET/POST/any method, request
bodies, headers, and full response parsing — Content-Length (with loud
truncation detection; the fork's `read_body` quietly accepts short bodies),
chunked, and close-delimited. Response boundaries are computed per message
(`classify_response`), which is what makes keep-alive possible: the
connection is kept warm and reused across requests to the same host and
port, with conservative retirement (Connection: close, HTTP/1.0,
close-delimited bodies, stray bytes past the boundary) and one retry on a
stale reused connection. `keep_alive=False` restores
one-connection-per-request. No TLS (terminate at a proxy, as everywhere
here) and no redirect following — a 3xx is a response, not an instruction.

Building it revived the fork's client-side connect path, which had rotted as
dead code — nullable addrinfo pointers, a `getaddrinfo` call glibc rejects,
an error wrap that never compiled (see [NOTICE](../NOTICE)). `poe
smoke-client` runs the first smoke where both ends of the wire are Mojo.

### WSGI landed (spike)

`m0-wsgi` runs a real Django request/response cycle, asserted end to end by
`poe smoke-django`. The boundary crosses once per request, with `start_response`
implemented in an embedded Python shim rather than as a Mojo callable, and
bodies moved as raw addresses because Mojo 1.0's `std.python` binds no `bytes`
API at all.

Concurrency is prefork, and it exists now: `M0_WORKERS=N` (or `m0serve
--workers N`) forks N workers through `WorkerSupervisor`
*before* the first Python call — forking a live CPython is not safe, and Mojo
initializes the interpreter lazily, so each worker makes its own first Python
call by constructing its own `WSGIApp` after returning from `fork_all()`.
Workers accept from one listener bound before the fork (per-worker
`SO_REUSEPORT` binds do not distribute on macOS, and hash blindly on Linux)
and set `wsgi.multiprocess=True`.
`poe smoke-django` runs both shapes: single-worker for the bridge assertions,
then `M0_WORKERS=2` asserting that two overlapping slow requests complete in
~1x the view latency on two distinct worker pids.

Workers serve through the non-blocking event loop — the blocking accept loop
drained one keep-alive connection exclusively, and the switch took its p99
from ~140 ms to ~5 ms while lifting throughput at every worker count.

Benchmarked against gunicorn (same Django project, same worker counts, wrk):
~1.6x gunicorn's throughput at 1–2 workers and ~2.2x at 4 under keep-alive,
with the remaining tail-latency caveat on close-per-request traffic —
methodology and numbers in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md).

### PEP 3333 conformance (done)

`smoke-django` runs a third pass with `M0_WSGI_VALIDATE=1`, which wraps the
example's application in `wsgiref.validate` — the stdlib's own WSGI checker,
and the closest thing that exists to a conformance suite for a *server*. It
asserts on the environ this server builds rather than on what Django does with
it: every required key present and correctly typed, `Content-Type` and
`Content-Length` arriving *without* the `HTTP_` prefix while every other header
keeps it, `wsgi.input`/`wsgi.errors` implementing the required methods, and the
application's iterable closed exactly once. Violations raise out of the
application call and the event loop answers 500, so a conformance failure
cannot pass quietly. It is off by default because the wrapper copies the
environ and wraps `wsgi.input` on every request.

The pass carries its own canary. `/pep3333/canary` returns a body with no
`Content-Type`, which is an ordinary 200 unvalidated and a 500 under the
wrapper — without it, a misspelled variable name would downgrade the whole
pass into a second unvalidated run that always succeeds.

**Django's own test suite is not the tool for this.** Of its 1996 test files,
6 start a live HTTP server; the rest reach the application in-process through
`django.test.Client` and never open a socket. Repointing `tests/servers/` at
this server was scoped and rejected: only four of its assertions target the
wire, and the price is a pinned Django *source tree* in CI. The replacement is
a framework-neutral suite over a bare WSGI callable, plus a shared framework
contract that Django and Flask both run — see
[WSGI_CONFORMANCE.md](WSGI_CONFORMANCE.md).

## Next: the Django server aims

Where the WSGI work is headed, and what gates each step — the full analysis
with evidence is [WSGI_VS_ASGI.md](WSGI_VS_ASGI.md):

- **No ASGI host for now.** The realtime surface people adopt ASGI for is
  covered by the in-process GRIP pattern (`apps/django_realtime`, `take_hold`,
  `m0pub.py`), and it now covers **both** transports. A sync Django view
  gates an SSE subscription with `M0-Hold: stream` and a WebSocket with
  `M0-Hold: websocket` — it cannot emit the `101` itself, so it approves and
  the Mojo layer performs the handshake; inbound frames return to it as
  ordinary POSTs (`ws_message_request`). One publish reaches both transports
  on every worker, and events are numbered from a shared atomic
  (`m0_shared_fetch_add` over the C ABI), so `Last-Event-ID` and duplicate
  suppression work. `smoke-django-realtime` and `smoke-django-realtime-ws`
  pin all of it. An ASGI host remains a deliberate separate package,
  warranted only by a Channels- or async-framework-shaped workload.
- **Free-threaded CPython is the successor to prefork, pending maturity.**
  `poe py-canary` swaps the venv onto 3.14t from the same lock and runs the
  whole WSGI suite; its first run (2026-08-21, macOS/arm64) passed every
  phase, with the RSS guard measuring *negative* growth (re-confirmed on
  3.14.7t). `poe py-thread-probe` answered the follow-on question:
  Mojo-spawned pthreads calling Python through `std.python` work on both
  builds and parallelize essentially perfectly on 3.14.7t (3.96x at 4
  threads), while loops over shared mutable Python objects invert to
  0.7-0.8x — a confirmed per-object-lock mechanism, and the design lesson:
  thread-local state scales, hot shared objects anti-scale. `poe
  py-thread-probe-stdpy` then showed the stdlib's own `CPython` bindings
  carry the attach/detach discipline with no `-lpython` on the link line.
  **The threaded mode shipped as Stage A — loop-per-thread**: `m0serve
  --threads N` runs N event loops on N pthreads in one process
  (`m0_wsgi.threaded`; `m0_http.threads` is the pthread substrate), each
  with its own handler and bridge, the event loop untouched, a GIL-enabled
  interpreter refused with exit 78. It retires the fork-after-init hazards
  and the per-worker RSS for anyone who opts in. Proven on **both**
  event-loop backends (`py-canary` phase D, 2026-08-23): kqueue on macOS and
  epoll on Linux, each with all four loops accepting — a listener dup'd into
  N epoll instances under `EPOLLET` wakes every one of them, so the
  `EPOLLEXCLUSIVE` contingency the design held in reserve is not needed. **Stage B shipped: `--blocking-threads N`.**
  The loop no longer calls `HTTPService.func`. It parses the request, parks
  it in `lightbug_http.offload`, submits a `SOCK_DGRAM` datagram naming the
  slot, and returns to `wait()`; one of N handler threads takes the job,
  calls its OWN handler (its own `WSGIApp`, bridge and shim namespace), parks
  the response, and pokes a completion channel the loop registers exactly as
  it registers `bus_read_fd` — from which the response re-enters the same
  `RESPONDING` write path every other response takes.
  `m0_wsgi.blocking_pool` is the thread side; the queue itself knows nothing
  about Python. Composes with both execution modes: one pool per loop, so
  `--workers W` is W processes of N threads and `--threads T` is T loops of
  N each. Stage A's benchmark row stands
  ([WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md), 3.14.7t): threads at
  throughput parity with prefork at ~60% of its RSS, ~3.5x gunicorn on the
  same interpreter.

  **What justified it, measured before it was built.** The `wrk` keep-alive
  run came first and could not settle it: p99 is 1.6–2.9 ms across both
  modes and both sizes, with one non-recurring excursion, in *prefork* of
  all places. But a hello route cannot produce the failure Stage B is half
  designed for, so the gate became a mixed-workload run — and that run is
  decisive ([WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md), 3.14.7t, two
  rounds).

  One slow view (`/slow?ms=200`) alongside fast traffic takes fast-request
  p99 from **1.6 ms to ~194 ms, a ~120x degradation**, while p50 does not
  move at all. That shape is the whole story: it is not general slowdown
  but a subset of connections stopped dead — with four loops and sixteen
  keep-alive connections, the ~4 pinned to the busy loop wait out the
  entire hold. **`--threads` is affected identically**, because a
  keep-alive connection belongs to the loop that accepted it in both modes;
  Stage A changed the process model, not the pinning. And **Granian's
  `--blocking-threads` — which *is* the Stage B architecture — is flat
  under the same load** (0.96 → 0.93 → 1.22 ms), which is what gave the
  design a working reference implementation.

  **Three departures from the design as sketched here**, each because the
  simpler thing turned out to be the safer thing:

  - No `HTTPResponse.deferred`. The loop already knows which slots it
    offloaded, so a flag on a type every handler constructs would carry no
    information the loop lacks.
  - The job storage is the pool's, not `ConnectionProvision.request`. The
    provision pool is a local of `run_event_loop`, and publishing its
    address to threads spawned before the loop starts is a lifetime hazard;
    caller-owned storage outlives the loop by construction.
  - No slot-generation array. A slot with a job in flight is never
    *recycled*: a client that half-closes or vanishes meanwhile is simply
    held — `peer_eof` marked, fd attached — and the completion answers
    through it or fails its send and closes. A generation counter detects
    that race; holding the slot removes it.

  The idle and header sweeps skip `PROCESSING`, the read path refuses to
  touch an offloaded slot (clearing `slot_read_armed` so a pipelined request
  arriving mid-flight is not stranded by the edge it consumed), and the
  shutdown path drains outstanding jobs before tearing connections down.
  `HTTPService` did not gain a method — `ThreadHandler` extends it, which is
  the seam.

  **What it does not do.** It is refused with `--realtime`: the streaming
  hooks run on the loop's handler and `func` would run against a pool
  thread's own registries. It does not make CPU-bound views concurrent under
  a GIL-enabled interpreter — it makes *waiting* views concurrent, which is
  what gunicorn's `--threads` does and what the workload actually is. And
  it is off by default, because a server whose views are all fast pays N
  threads for nothing.

  **The other finding, and it is the bigger number.** Splitting the Granian
  gap by layer (`scripts/bench_layer_split.sh`) shows it is almost entirely
  the **WSGI bridge**: `apps/hello` (zero Python) does 78.3k rps at 178 µs,
  the same HTTP layer through the bridge does 12.4k at 1.18 ms, and Granian
  through *its* bridge does 124.6k at 109 µs on the same 13-byte response.

  **Re-measured 2026-08-24, after five bridge changes** — and the conclusion
  above is now spent. Controls held (hello 0.99x, Granian 0.98x/0.99x);
  m0serve moved 3.94x at one worker and 2.91x at four. **At four workers
  m0serve is ahead of Granian, 101.9k against 98.5k**; at one worker the gap
  is **2.50x**, down from 4.31x. That remainder decomposes as 1.58x HTTP
  layer × 1.58x bridge — dead even — so there is no lopsided target left,
  and the HTTP layer is now worth as much as any further bridge work. Part
  of the four-worker result is Granian's own 19% loss from w1 to w4 on a
  four-performance-core box; m0serve scales 2.08x over the same step.
  The bridge costs ~1 ms per request because `bridge.mojo`'s shim rebuilds
  the environ in pure Python every time — ~28 string decodes for a
  twelve-header request — which is itself downstream of the
  `PythonObject` reference leak that forced the blob design. Building the
  environ in Mojo through the raw CPython C API (`PyDict_New`,
  `PyDict_SetItem`, reachable through `Python().cpython()` and
  compile-checked) sidesteps the leak and is where that ~10x lives.

  **Two doubts about that row, both since retired by measurement**
  ([WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md)). The 78.3k could have been a
  round-trip latency measurement rather than a ceiling — 16 connections at
  178 µs is ~90k — but a concurrency sweep settles it: throughput moves 3%
  from `-c16` to `-c256` while p50 rises 17x, which is queueing added to a
  saturated service rate and nothing else. And the recommendation to attack
  the shim was re-derived rather than trusted, since its previous version
  named the wrong sixth: the split reproduces at `handle()` = 12.1 µs of a
  14.2 µs round trip, **85% of what remains**, with all three Mojo-side
  parts together at 1.6 µs. The target is the right one.

  **Done.** The environ is built in Mojo through the C API now, and the same
  split says it worked: the bridge is **3.5 µs per request instead of 14.9,
  4.2x**, and one worker on `apps/wsgi_bare` serves **45.7k rps instead of
  28.9k, 1.57x**, p50 508 → 315 µs. `smoke-django`'s RSS guard still reports
  0 KB over 10k requests, which is what says the explicit refcounting is
  right. The blob and `serialize_request` are gone; the request *body* still
  crosses as bytes because Mojo 1.0 has no `PyBytes_*` binding at all. The
  Granian row above is deliberately not restated: it was measured on 3.14.7t
  and this pair on 3.13, and dividing across two interpreters would be
  arithmetic rather than measurement. Re-running `bench_layer_split.sh` on
  3.14.7t is what would move it.

  **What is left of the bridge is a different shape.** Of the 3.5 µs, 1.78 is
  the environ build and 0.65 the shim; **1.07 µs is getting the response body
  back out** (`body_bytes`). That is 31% of the bridge now, against 5%
  before, purely because everything around it shrank.

  That was first described as "a `len()`, a `body_addr()` crossing, then a
  byte-at-a-time copy" — a reading of the code. Measured, it was **one of the
  three**: the `len()` is 0.003 µs and the copy is noise, while
  `body_addr()` was **1.095 µs**, because that shim function built two
  `ctypes` objects per request.

  **Done, and not the way this entry predicted.** The recorded plan — a
  persistent `bytearray` whose address Mojo caches — rested on the premise
  that a `bytes` object is unreachable from Mojo. It is not. `external_call`
  cannot reach `PyBytes_*` because **libpython is not on the link line**, but
  the stdlib's own `ExternalFunction[name, type].load(cpy.lib.borrow())`
  can, and that is how `CPython` populates its own bindings. **The whole C
  API is reachable, not only the wrapped part** — a more useful fact than the
  optimisation it produced. `body_bytes` now runs no Python at all:
  **1.07 µs → 0.13 µs**, bridge **3.52 → 2.50 µs**, end to end **45,891 →
  48,852 rps (+6.7%)**, RSS guard still 0 KB. Cumulative against the
  pre-bridge-work baseline: **1.69x**.

  **The follow-on is done too:** the *request* body now becomes a real
  `bytes` via `PyBytes_FromStringAndSize` and rides to the shim as a stolen
  tuple slot; `io.BytesIO(bytes)` shares the buffer copy-on-write, so the
  path has ONE copy where the bytearray protocol had two. Staging a 1 KB
  body: **1.6 µs → 0.07 µs (~23x)**; POST e2e with a 1 KB body on
  `apps/wsgi_bare`'s `/input/read`: **42.1k → 47.3k rps (+12%)**, with GET
  unchanged. The shim's transfer bytearray, `buf_addr()` and the grow
  protocol are deleted — the last piece of the blob design — and the shim
  imports nothing but `io`.

  **And the environ build after it: 1.78 → 1.56 µs, bridge 2.35 µs.** The
  base entries live in a finished template dict and each request starts
  from `PyDict_Copy` (58 ns against 214 for the replay). The bigger result
  is negative: interning recurring header names/values loses — the intern
  cache's hit-path byte-compares (245 ns) cost more than the decodes they
  skip (180 ns; short-ASCII `DecodeUTF8` is 15 ns) — so it was never built.
  What remains is ~26 mandated `PyDict_SetItem`s and sixteen genuinely
  dynamic decodes: **the bridge is near its structural floor** — which the
  re-measurement on 3.14.7t then confirmed from the other side. **Done,
  and it moved the target twice.** First it showed the raw gap living in
  the HTTP layer, not the bridge; then CPU-normalizing the comparator
  (Granian's "1 worker" runs ~1.6–1.75 measured cores) showed the honest
  per-core HTTP gap was ~1.2x — and a profile-ranked allocation pass
  (Headers' packed index, move-not-copy response ctors, no `String(int)`
  per request; NOTICE has the numbers) closed it: the hello row now
  measures **~121k rps/core against Granian's ~101k**, with the bridge
  row at ~84k/core. Benchmark runs now leave dated,
  environment-stamped artifacts in `bench/results/` and the table in
  [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md) is rendered from the newest
  one (`poe render-bench-docs`, held current by `poe check-docs` in CI) —
  because this conclusion has now inverted twice on stale numbers, and a
  cited artifact ages visibly where a transcribed number ages silently.
- **Static files front the Django rows.** `StaticFiles` grew a
  `Cache-Control` policy (emitted on 200/206/304 — the validator response
  carries freshness too, per RFC 9110) and `apps/django_realtime` mounts it
  ahead of the bridge: asset requests are answered in Mojo and never enter
  Python, which is the WhiteNoise/nginx replacement claim,
  smoke-asserted (type, ETag revalidation, freshness, traversal 404). The
  **zero-copy `sendfile` step has landed.** `HTTPResponse` gained an
  fd-backed body beside `body_raw`, and both write paths transfer it with
  `sendfile(2)` — the event loop across readiness events, the blocking loop
  in a plain loop, because a response kind only one path understood would
  be a trap. `StaticFiles` no longer reads a file to serve it: `stat`
  supplies the size, and a hit hands the loop an open descriptor.
  Measured at **64 KB of RSS growth while serving 192 MB**, against
  ~200 MB when the same files are buffered — `poe smoke-sendfile` asserts
  both halves, plus a mid-file Range, a bodyless HEAD that keeps the real
  `Content-Length`, and the ETag round-trip.

  **The validator changed with it, deliberately.** It was a wyhash64 over
  the whole file, which a path that never reads the bytes cannot compute;
  it is now derived from size and mtime, as nginx and Apache do. The trade
  is that a rewrite preserving both is a cache *hit* the content hash would
  have caught. What did not change is what the tag claims: still weak, so
  `If-Range` remains unsatisfiable and a conditional range still falls back
  to the full representation. The descriptor is owned by the connection's
  provision from the moment the head is encoded and released on every
  close path, so a client that vanishes mid-transfer cannot leak it.
- **The uvicorn-shaped CLI exists.** `m0serve MODULE[:ATTR]` with `--host`,
  `--port`, `--workers`, `--app-dir`, `--static PREFIX=DIR`, `--max-body`,
  `--metrics` (`packages/m0-wsgi/m0serve.mojo`, `poe build-serve` →
  `bin/m0serve`). The three WSGI rows are Python-only projects served by that
  one binary; `smoke-serve` pins the exit codes, flag-over-env precedence,
  and the server tunings a command line can now reach. Flags are strict
  where `M0_*` is lenient.
- **The realtime machinery is behind `m0serve` flags.** `--realtime` carries
  what `apps/django_realtime/server.mojo` used to: the two `SSERegistry`s,
  `take_hold` on every application response, the WebSocket handshake the
  application cannot emit for itself, `ws_message_request` for inbound
  frames, and the pre-fork `BroadcastBus` + `SharedAtomics` with their
  environment exports (`M0_CORE_LIB` discovered rather than demanded).
  `--health-path` is separate and opt-in, because a pure row must not own a
  path the application might route. Under `--threads N` the bus is built on
  the main thread before spawning and each loop drains its own channel, so
  `m0pub.py` reaches N threads with the N `os.write`s it used to reach N
  processes — it never learns which it is talking to. No `apps/*/server.mojo`
  remains under a WSGI row.
- **Hot reload exists.** `m0serve --reload [--reload-dir DIR]` polls watched
  directories every 300 ms with `MtimeScanner` and, on a changed `.py`,
  stops the workers and forks replacements onto the new module. The flag
  forces a supervisor even at one worker and even under `--threads N`; the
  supervisor never touches Python, so fork-without-exec stays safe and the
  fork still precedes the first Python call. A reload reuses the existing
  `SIGTERM` → drain → `exit_worker()` path and is accounted separately from
  a crash, so it spends no respawn budget. It also sets
  `PYTHONDONTWRITEBYTECODE=1`: CPython validates a `.pyc` against source
  mtime in whole *seconds* plus size, so without it a same-second,
  same-length edit reloads into stale bytecode. The Mojo binary is never
  re-exec'd — a changed `.mojo` still needs a rebuild.
- **Can m0serve host FastHTML?** Asked 2026-08-24; **answered the same
  week: yes** — it was the case that justified the ASGI path
  ([WSGI_VS_ASGI.md](WSGI_VS_ASGI.md) §8). No adapter was needed: `m0serve`
  now detects ASGI applications and serves them with real
  await-concurrency, so `m0serve main:app --app-dir apps/fasthtml_demo`
  serves FastHTML pages today, its SSE `EventStream` **streams live**
  (Phase 3a), and `app.ws` **works** (Phase 3b) — the full FastHTML
  surface, zero-config, pinned by `poe smoke-fasthtml` (skipping where
  python-fasthtml is absent).
- **The ASGI gateway's next phase** (design in WSGI_VS_ASGI.md §8):
  Phase 2 — the per-loop asyncio executor over the unchanged
  `OffloadPool` — **shipped**: zero-config ASGI gets real
  await-concurrency and no handler pool, `bench-asgi` is the standing
  uvicorn gate. Mixed-tail — the executor's actual claim — passes; the
  hello-world row was re-measured under wrk 2026-08-25 and the deficit is
  real and **wakeup-bound, not CPU-bound** (0.72x while consuming 0.89
  cores: each request serializes loop → datagram → executor → datagram →
  loop, both threads idling between handoffs — artifact in
  `bench/results/`, analysis in WSGI_PERFORMANCE.md §"The ASGI executor
  vs uvicorn"). The throughput gate is recalibrated to ≥0.8x so it fails
  on mechanism regressions instead of on every run; **pump batching** is
  the recorded lever that would earn the threshold back up.
  Phase 3 — ASGI streaming and `websocket` scopes over the existing
  bus/registry transport — **shipped** in v0.9.0, which is the release
  that made FastHTML's whole surface work zero-config.
- **Mounts: several applications in one process.** `m0serve --mount
  PREFIX=SPEC` routes by longest prefix in Mojo before either application
  sees the request, each mount detecting its own protocol and getting its
  own bridge — **and each running in its own native execution mode**: the
  sync application on handler-pool threads, the async one on the asyncio
  executor, sharing one listener, one set of workers and one graceful
  shutdown. This is the hybrid advantage rather than a convenience:
  uvicorn, daphne and Granian each host exactly one callable, so mixing
  otherwise means two processes behind a proxy or a Python-side composite
  (Starlette `Mount` + `WSGIMiddleware`, which drops the sync app onto the
  event loop's threadpool).

  The mechanism is a submit **lane** per mount — the single `OffloadPool`
  submit channel became one `SOCK_DGRAM` pair each — so the loop hands a
  job to the worker that can run it. One `ProvisionPool` per loop stays,
  since a slot indexes that loop's provisions. Measured with four blocking
  2-second Django views holding every pool thread, the FastHTML mount
  answers at p50 1.3 ms / p99 2.8 ms (`docs/WSGI_VS_ASGI.md` §9,
  `apps/hybrid_mix`, `poe smoke-hybrid`).

  **Several ASGI mounts landed too**: one executor per ASGI mount, a
  shared slot-addressed chunk channel, and per-lane drain-ack pairs
  routed by `slot_lane` — pinned by streaming 256 KB (four credit
  windows) from two executors concurrently.

  **Per-mount modes now hold under `--threads` as well.** They were
  prefork-only because `_serve_one` added no lanes, and the mode was
  decided pessimistically on top of that: `use_asgi_executor` answers
  True if *any* mount is ASGI, so a mixed set put every mount — the sync
  ones included — on one executor. `_serve_one` now mirrors
  `_serve_offloaded`: a lane per mount, an executor per ASGI lane with
  its own drain-ack pair, pool threads dealt round-robin over the WSGI
  lanes, and pills per lane at shutdown. Two things came with it: the
  loop's `peer_bus_fd` reaches the threaded path (the executor's chunk
  channel had displaced its only bus fd, so `state["m0"]` could not have
  reached a threaded executor), and `ThreadHandler` gained
  `set_lane_notify` beside `set_asgi_notify` — the generic `_serve_one`
  body can only call what the trait names. `wsgi_lanes` and
  `asgi_mount_names` moved to `cli.mojo` so both execution modes deal the
  same lanes from one implementation. `smoke-hybrid` gained a `--threads
  2` phase asserting all of it (skipped off free-threaded CPython);
  measured p99 4.3 ms on the async mount under four blocking sync views,
  against a laneless build where it times out entirely.
- **Streamed responses no longer end their connection.** An ASGI stream on
  HTTP/1.1 now goes out `Transfer-Encoding: chunked` — each drain framed
  `size CRLF payload CRLF`, end-of-stream a `0 CRLF CRLF` terminator — and
  the connection returns to keep-alive. That was the most visible
  remaining divergence from uvicorn: close-delimiting works, but it costs
  the connection, so an SSE stream or a `StreamingHttpResponse` was
  followed by a reconnect. The encoder lives beside the decoder that was
  already in `lightbug_http/http/chunked.mojo` (the client's half), and the
  round-trip tests feed one to the other.

  Framing is refused wherever it would corrupt rather than differ:
  HTTP/1.0 has no chunked encoding, a HEAD carries no body, a 101 hands
  the connection to WebSocket framing. It is scoped to the executor's ASGI
  streams — a `--realtime` SSE stream is refused alongside the executor and
  does not end on its own anyway.

  Two accounting rules turned out to be load-bearing. The outbox drain
  reads `sse_is_streaming` **once** per pass, because the drain itself is
  what flips it and asking twice can straddle the transition — sending a
  terminator on a stream that has just queued more. And drain acks count
  **payload**, not wire bytes; a credit window replenished by the framing
  overhead grows without bound over a long stream, which is why
  `OffloadLoopState` carries `ack_payload`.

  `smoke-asgi` gained the assertion that actually proves it
  (`scripts/chunked_keepalive.py`): a raw socket, a hand-decoded chunked
  body compared byte for byte, then a **second request on the same
  connection**. Everything else about streaming passes with close-delimiting
  too, which is why that one assertion is the whole guard — verified
  load-bearing against a close-delimited build, where it fails on the
  missing header. The same probe pins the HTTP/1.0 refusal.
- **The executor's one recorded lever is pump batching**, and it is
  conditional, not planned. The evidence (2026-08-25, artifact in
  `bench/results/`): the executor loses the hello-world row at 0.72x
  under wrk while consuming **0.89 cores** — wakeup-bound, not CPU-bound,
  each request serializing loop → submit datagram → executor → completion
  datagram → loop with both threads idling between handoffs. Batching
  (drain several submit datagrams per executor wakeup, coalesce
  completions per loop pass) attacks that cost directly; more executor
  threads would only overlap it, at real complexity in the seam where a
  misrouted credit ack is a hung stream — which is why the earlier
  "N executors per pool" idea is demoted below it. Build it only if a
  tiny-fast-response workload ever matters (the mixed-tail gate — the
  executor's actual claim — already beats uvicorn); the load-bearing
  constraint is that the chunk channel's begin-frame-before-head FIFO
  ordering must survive any coalescing. The other old fix path, "measure
  under wrk", is done and falsified its own premise (the stdlib harness
  flattered the executor). Landing batching earns `bench-asgi`'s
  throughput gate back up from ≥0.8x.
- **Django ASGI parity is proven, not inferred.** `apps/django_asgi`
  runs Django's own `ASGIHandler` through the executor (`poe
  smoke-django-asgi`): async views overlap, `StreamingHttpResponse`
  streams live, sessions survive both directions — and `scope["client"]`
  is real. The fork's `accept()` had truncated the peer sockaddr with a
  4-byte addrlen since its lightbug days, so no request had ever carried
  a readable peer; `accept_with_peer` fixed that at the root and both
  protocols now see it (`REMOTE_ADDR` in the environ, `client` in the
  scope). The conformance bar matches the WSGI row's too: ASGI has no
  `wsgiref.validate`, so `apps/asgi_bare/bareapp/validate.py` is one,
  written from the ASGI 3 spec and run as `smoke-asgi`'s
  `M0_ASGI_VALIDATE=1` pass with its own engagement canary. Channels
  remains out of scope: it needs a channel layer and WebSocket
  subprotocol negotiation, neither of which this row smuggles in.
- **Cross-worker fan-out reaches ASGI applications.** `state["m0"]` is
  the Channels channel-layer shape with no Redis: publish rides m0pub's
  bus protocol (shared-atomic ids included), subscribe is an async
  iterator fed by frames the loop forwards to each executor over the
  submit channel. The executor's chunk channel had consumed the loop's
  one bus fd; a second registered fd (`peer_bus_fd`) answers that. The
  bus is now created unconditionally pre-fork — detection is post-fork,
  and a single worker's own subscribers ride its own channel. Pinned by
  `poe smoke-asgi-fanout`.
- **The release path.** Five gates, deliberately finite — when they are
  done the release is ready, and nothing off this list blocks it:

  1. **The install matrix, hardened by existing.** Scope the PyPI wheel,
     then publish a quiet, unannounced 0.x and dogfood it — publishing
     and announcing are separate acts, and install failures are only
     found by installing on machines that are not this one. The
     bundle-ffi lesson applies: an artifact tested only where it was
     built passes exactly where the defect cannot appear.

     Two corrections to what this entry used to assume. **The binary does
     not link libpython** — `std.python` `dlopen`s the interpreter from
     `python3` on PATH, so the wheel needs no ABI tag and one build per
     platform serves CPython 3.10–3.14 including free-threaded builds.
     And the `libm0core` bundle's rpath surgery was transferable, but it
     transferred a *bug*: both the checker and the bundler assumed
     `otool -L`'s first entry was the file's own install name, which is
     true of a dylib and false of `bin/m0serve`, so they agreed that a
     binary resolving the Mojo runtime through a developer's venv was
     self-contained. Fixed, self-tested, and written up in
     [FFI_DISTRIBUTION.md](FFI_DISTRIBUTION.md). The licensing analysis in
     [NOTICE](../NOTICE) did transfer, with one addition: the wheel is the
     first artifact that redistributes the lightbug fork in binary form,
     so its MIT notice has to travel with it.
  2. **A ten-minute quickstart that proves the headline.** The
     sync-Django realtime demo (`apps/django_realtime`: SSE + WebSocket
     fan-out from plain sync views, no Channels/Redis/second process) as
     a copy-paste path a newcomer — or an agent — completes and
     *verifies* end to end, the smoke idiom exposed as a user affordance.
  3. **A public benchmark page rendered from `bench/results/`** — same
     provenance discipline as the WSGI_PERFORMANCE table: every number
     cites a dated, environment-stamped artifact, cores measured,
     methodology caveats (P/E cores, within-run ratios) stated up front.
     **Written** ([BENCHMARKS.md](BENCHMARKS.md)): four generated regions
     across two documents, `render_bench_docs.py` drives both and
     `check-docs` fails on a hand-edited table. Two things it does
     deliberately. It states the losses — ~0.83x Granian per core on bare
     WSGI, 0.72x uvicorn on ASGI throughput — because the win it claims
     (fast-request tail) is only credible beside them, and because the
     positioning that quoted the zero-Python hello row against Granian's
     with-Python row was comparing unlike things. And it renders a *stated
     absence* for `mixed-workload` rather than omitting it: the pool's
     ~100x p99 improvement is the strongest claim here and the only one
     without an artifact. **Closed 2026-08-26**: that artifact exists, the
     WSGI layer split was re-run post-pin, and the page's prose was
     corrected by `check_bench_prose` naming all sixteen stale sentences.
     Two ASGI artifacts still predate the pin — provenance hygiene, not a
     correction in waiting, since the pin measured byte-identical.
  4. **Agent affordances**: an `llms.txt`; a `--doctor` / machine-readable
     startup diagnostic; error messages and refusals already explain
     themselves and name their fix — document that as a contract rather
     than leaving it as culture. **Done.** `llms.txt` and the
     CI-executed QUICKSTART shipped with 0.11.0; `--doctor` prints the
     configuration as JSON and exits with the code `m0serve` itself would
     use for the same arguments, which `poe smoke-doctor` holds true by
     running both over every refusal. The refusal contract is now stated in
     `llms.txt` rather than implied by the messages.
  5. **The public name, decided once.** `mojo` is Modular's mark;
     `m0serve`/`m0-*` keep distance. Check PyPI availability during the
     wheel spike and lock the name before anything is published under it
     — renames spend first impressions twice. **Done.** Name settled and
     claimed 2026-08-25; the first screen now leads with the realtime
     claim on all three surfaces that have one — README.md,
     `packaging/m0serve/README.md` (which is what PyPI renders, and was
     the one nothing was checking) and `llms.txt`. The gaps are on the
     first screen rather than in an issue: no TLS or HTTP/2, the platform
     floors, pre-1.0, and the benchmark losses stated with numbers.

  **Before 0.12.0**: exercise the server against real applications rather
  than only the ones written to test it — three local Django projects,
  staged from `--doctor` through a realtime retrofit. **Done** (2026-08-26;
  [REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md) is the record): four
  defects, each fixed with a guard that fails without it, three of which no
  in-repo application could have shown — and one finding about the shape
  of the server itself, which is the section below. The precedent held: the
  *one* earlier dogfooding session found the `--app-dir` shadowing bug,
  which this pass reconfirmed and which is now fixed.

  Sequencing: gate 1 first (it ages in the wild while the rest proceed);
  gates 2–4 in any order; announce only when all five are done. The
  README's first screen states the limits plainly (no TLS and no HTTP/2 —
  terminate at a proxy, gunicorn's answer; platform matrix is what the
  Mojo toolchain supports). Explicitly NOT release-blocking: pump
  batching, Channels compatibility, Windows, and any claim not backed by
  a smoke or an artifact.

  (ASGI/WSGI auto-detection shipped with the gateway — `--protocol`
  overrides it, and a bare `MODULE` discovers `MODULE.asgi:application`,
  `MODULE.wsgi:application`, `MODULE:app`, `MODULE.main:app` by
  convention.)

### Hold on a pool thread: the refusal that keeps `--realtime` off real applications

**Where this comes from.** Serving `textshelf`
([REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md), 2026-08-26) showed the
realtime mode is not deployable for the application class it exists for,
and the reason is a refusal this server makes on purpose: `--realtime`
refuses `--blocking-threads`, so a held-stream server runs its views on the
loop, and one slow view then stalls every held stream on that worker along
with every other request. Measured on textshelf with eight 1.5 s views in
flight (what an AI call or a typst render looks like to a server), fast-path
p50, plus what 200 held SSE streams cost:

| shape | fast path p50 | 200 held streams |
|---|---|---|
| `--realtime --workers 4` | **1 543 ms** | +2 MB RSS, no Python state, no DB connection |
| `--blocking-threads 4 --workers 4` | 0.3 ms | cannot hold |
| `--mount /=wsgi --mount /rt=asgi`, 4 × 4 | 0.7 ms | within noise; one Postgres connection each in production (their `psycopg.AsyncConnection` per subscriber, not ours) |
| daphne — their `fly.toml` | 4.9 ms | +94 MB |
| gunicorn, 2 workers — their `Dockerfile` | 6 015 ms | cannot hold |

One laptop, scratch SQLite, a 120-request burst at concurrency 16: relative
numbers, not a benchmark. Two things are true at once. **M0-Hold is by far
the cheapest way to hold a stream** — 2 MB per 200, no per-stream Python,
no per-stream database connection, and the retrofit that reaches it was
+52/−293 lines. And **choosing it costs the pool**, which is the fix for the
hostage pathology the README leads with. The feature the pool would protect
reintroduces the pathology the pool cures. Workers mitigate at N× RSS (491 MB
for four of textshelf), and only until the N+1th slow view.

The hybrid mount already gets an application like textshelf most of the way
with no code change — its existing async SSE views on the executor at `/rt`,
its sync bulk on the pool at `/`, 0.7 ms isolation, +6 MB for the second
mount (503 MB against 497) — and that is the recommendation today. What it
cannot do is combine the pool with M0-Hold, which is the shape textshelf
actually wants: four of its six SSE endpoints are pub/sub (subscribe, then
wait for events published elsewhere) and convert to a hold outright; the
other two (`ai/streaming.py`) are request-scoped generators, the view being
the producer, and belong on the executor. **Protocol is the wrong axis;
stream shape is the right one**, and one process should serve both shapes.

**1. `--realtime` with `--blocking-threads`.** The refusal's reason is
exact: `take_hold` runs inside `WSGIHandler.func`, which under the pool
runs on a pool thread against that thread's own `SSERegistry`/`WSHub`, while
the loop calls its hooks on the loop's handler. The executor solved the
identical problem, and its seam is the one to reuse: it does not subscribe
from the producing thread. It sends a reserved begin frame
(`\x01b/<slot>/<lane>`) that the *loop's* handler turns into a subscription
in `sse_peer_frame`, ordered ahead of the head completion. A pool thread in
realtime mode would do the same — decide with `take_hold` where it is, then
publish a new reserved kind (`h` for an SSE hold, `H` for a socket; payload
the channel and the request's `Last-Event-ID`) onto the loop's bus channel,
which every worker already has (created pre-fork; `m0pub` writes to it from
Python), and complete with `sse_streaming` set. The loop's handler
subscribes the slot in its own registries; the drain, the heartbeats, the
disconnect hooks and the bus fan-out do not change. The WebSocket half is
harder. The 101 must be computed from the original request, which the pool
thread has, so it performs the upgrade and completes with the 101 — the loop
already switches a slot to frame mode on that wire signal. But inbound
frames are today delivered by `ws_message` running the Django view **on the
loop thread**, and under a pool they must not; they need to reach a pool
thread as a tagged submit datagram the way the executor receives them
(`_TAG_WS_MESSAGE`), which the pool's `next_job` does not decode. Stage it:
SSE holds first, which is what textshelf's four pub/sub endpoints need and
what the numbers above are about; sockets second.

**2. `--realtime` with `--mount` — shipped 2026-08-26, and it came before
the socket half.** Re-measuring `textshelf` after stage 1 settled the order
([REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md), *Revisited*). Holds and
an ASGI mount in one process is what a mixed application needs, because
stream *shape* decides where an endpoint belongs: its four pub/sub
endpoints convert to holds, while `ai/streaming.py` is a request-scoped
generator whose view is the producer and which no hold can carry. That
application opens no WebSocket against its own server, so the socket half
buys it nothing. The refusal was broader than its reason — an inbound
WebSocket message was said to have no defensible destination among several
urlconfs, and an SSE hold has nothing inbound to deliver — so it first
narrowed to the socket half, and then (3) removed that too. What is refused
now is only `--realtime` on a server where no mount could take a hold.

**What it took was not the ordering work this entry expected.** The loop
already had the answer in `OffloadPool.slot_lane`, which `submit` stamps
with the mount a job went to, and a lane has a drain-ack pair exactly when
an executor serves it. So `slot_is_executor(slot)` replaced
`stream_active()` at the four places the loop decided what a streaming slot
was, and "is this an ASGI stream?" stopped being a question about the
server and became one about the slot. Getting it wrong is silent, which is
what `smoke-django-realtime` phase 6 exists to catch: a held stream drained
as an executor's is chunk-framed with a `Transfer-Encoding` it never asked
for, acked to an executor that never issued the credit, and denied the
comment heartbeat that keeps it alive through an idle proxy — while still
delivering, so nothing looks wrong until a proxy times the stream out. The
phase holds one stream of each kind on one loop and asserts the heartbeat
and the framing on the held one.

That makes the hybrid's proposition whole for a mixed application: holds
for its pub/sub streams, the executor for its generator streams, the pool
for everything else, one process.

**3. The socket half — shipped 2026-08-26.** A pool thread performs the 101
(the client's key is in the request it holds) and sends an `H` frame
carrying its own LANE; the loop records `hold_lane[slot]`, and an inbound
frame rides the submit channel back as a `TAG_WS_MESSAGE` datagram — the
executor's shape plus the channel, because a pool thread's registries are
empty and the name the socket joined with has to travel with the message.
`next_job` decodes both shapes off one channel, told apart by length (a job
is exactly 8 bytes, a message at least 12), into a caller-owned buffer so a
WebSocket's size is not charged to every request.

Two things were not obvious until they broke. **The pool question must be
asked before the executor one**: on a mixed mounted server `asgi_notify_fd`
is set for the ASGI mount, so asking that one first hands every socket's
message to an executor that never accepted the connection — which is what
happened, and what `smoke-django-realtime-ws` phase 4 now catches. And
**`NOT_POOL_HELD` cannot be -1**, because -1 is a real lane (the unmounted
pool); a sentinel a real lane can equal routes an executor's socket into a
pool. Phases 3 and 4 run the whole socket probe — handshake, fan-out, relay
through Django, channel isolation — against a pool and against mounts, and
phase 3 adds what the pool is for: the probe runs **+13 ms** behind two
1.5 s views, against its own ~4 s baseline.

With that, `--realtime` composes with everything it used to refuse, and the
`ws_message` limit the design doc recorded — the view runs on the loop
thread — is retired: under a pool it runs on a pool thread, on the mount
that gated the socket.

**What has to be established before (1) is built**, each a place the
design could be wrong:

- The begin-before-head ordering argument (`asgi_executor.mojo`,
  `stream_start`) is made for the chunk channel. A hold frame would ride
  the bus channel — a different descriptor, drained in a different branch
  of the same loop pass — and whether the same guarantee holds there has to
  be shown, not assumed: a subscription that lands after the head
  completion is a stream the loop closes as ended, the wrongful-early-close
  race the executor's ordering exists to prevent.
- `x-worker`, `Last-Event-ID` seeding (`request_last_event_id`) and the
  `/health` subscriber counts all assume the subscribe happens where the
  request is; each moves to the loop side, and `smoke-django-realtime` must
  not notice.
- Under `--threads`, each loop has its own pool and its own handler; the
  bus descriptor a pool thread writes to must be *its* loop's
  (`peer_bus_fd`), or the hold lands in another loop's registry against a
  slot that means nothing there.
- The `_health` docstring already concedes the premise — its counts are
  answered in Mojo because they "have to stay readable while a slow view
  has the interpreter busy" — which is the hostage problem stated from the
  inside. After (1) that sentence is about the pool, not about the loop.

**Stage 1 shipped (2026-08-26): SSE holds on pool threads.** `--realtime
--blocking-threads N` is accepted; a pool thread takes the hold and sends
it to the loop's registries as a reserved `h` frame on that loop's own bus
channel (`OffloadPool.hold_notify_fd` → `ThreadContext.hold_fd` →
`WSGIHandler.hold_notify_fd`; `sse_peer_frame` subscribes), before the
response completes. The ordering question resolved in the design's favour
without needing a same-pass guarantee: with no executor there is no
end-of-stream signal for the loop to misread, so a frame drained a pass
late is a stream that starts a pass late, and publishes are FIFO behind it.
That is also why the `--mount` refusal stays — an ASGI mount brings the
signal — and why a WebSocket hold under the pool is a 409 that says so,
until inbound messages can reach a pool thread. `smoke-django-realtime`
phase 5 pins it: two 1.5 s views in flight, a subscribe and a publish still
land well inside a second, heartbeats keep coming, a vanished client is
unsubscribed, SIGTERM exits 0. Under `--threads` each loop's pool writes to
its own loop's channel (`ThreadedServer.bus_write_fds`). Building it found
one more thing the refusal had been hiding: under a pool, `/health` was
answered by a pool thread's handler, whose registries are never the ones
being drained, so it reported zero subscribers while events were being
delivered. The loop's `before_request` now runs *before* the offload and
answers static mounts and the health path itself (`answers_local`) — it
used to run only on the queue-full fallback, so under a pool the hook had
never fired on the loop at all. Measured on textshelf after: fast-path p50
0.3 ms with eight slow views in flight, four streams held on pool threads
across three workers, all four delivered.

**Is it a significant advance?** For (1), yes, and by a distance: it is the
difference between the realtime claim being demonstrable and being
deployable. Every application with a slow view and a stream — which is
every application that wants a stream — currently has to choose between the
two things this server does best. (2) is worth doing only after (1) and is
the smaller: the executor mount already streams, so what it adds is the
cheaper hold and the sync-only codebase for the pub/sub half of a mixed
application. Neither is a rewrite. The mechanism, the channel, the
reserved-name dispatch and the lane record all exist; the work is one new
frame kind, one handler branch, one narrowed refusal, and the smokes that
prove the ordering.

### Streamed WSGI bodies — shipped 2026-08-27

The last buffered shape. A generator the application did not size —
Django's `StreamingHttpResponse`, the thing every Django SSE tutorial
returns — was joined whole by the shim, so a never-ending one never
answered and pinned its `--blocking-threads` thread until the bounded
join abandoned it ([REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md),
textshelf). It streams now, and nothing new was invented to do it: a pool
thread is a **second producer on the chunk channel the executor already
streams through** — `P` begin frame, `s` chunks, `e` end, the loop's own
framing and end-of-stream — and the loop's per-slot "is this a channel
stream?" question generalised from "the lane has an ack pair" to "the slot
has an ack fd" (`slot_channel_stream`). What buffers is decided in the
shim in order: an app `Content-Length` (every framework page — the rule
that keeps the wire byte-identical and every bench number unchanged), list
bodies, Django's `HttpResponse`, HEAD, bodiless statuses, `M0-Hold`. Only
pool threads stream; the loop's handler keeps joining.

An adversarial review of the first design found four defects before a
line was written, each now a rule in CLAUDE.md: the `isinstance` rule
would have chunk-streamed every Django page (`HttpResponse` is an
iterable); `slot_is_executor`'s unmounted shortcut would have turned every
`M0-Hold` on the default topology into a chunk-framed, heartbeat-less
stream the moment the channel existed (the chunk pair and the executor's
ack pair are separate switches now); "queue a chunk only if subscribed"
does not cover two writers on a recycled slot (every frame carries a
generation, executors included); and the loop cannot learn "aborted" from
one bool (the abort is a tagged datagram on the completion channel,
checked against the head's generation). Building it found two more:
`Int(Int32(UInt32(0xFFFFFFFF)))` is 4294967295 on Mojo 1.0, not -1, so
the disconnect ack never decoded until sign-extended by hand; and a
stream of small events never exhausts a 16 KB window, so credit alone
never made a thread look at the fd the disconnect arrives on — it polls
before every piece now. Both are pinned.

`smoke-wsgi-stream` is the guard: time-to-first-piece against a 600 ms
body, the hand-decoded chunked probe plus a second request on the same
connection, HTTP/1.0 close-delimited, `write()` inside the generator in
order, honest truncation on a raise, 16 concurrent 1 MB bodies byte-exact,
five abandoned never-ending streams on a four-thread pool, SIGTERM with a
live stream in under a second and with a sleeping generator named as the
straggler, `wsgiref.validate` on a pool, and Django's
`StreamingHttpResponse` reused connection and all.

Recorded follow-ups, not built: an iterator that carries its own
`Content-Length` (`FileResponse`) still buffers rather than streaming
with its declared length — identity framing for both producers; a framed
stream ignores the request's `Connection: close` at its end (pre-existing,
both producers); and the loop handler's frame dispatch is covered end to
end by the smoke rather than by a unit test, because it needs a
`WSGIApp` to construct.

## Open questions

### The desktop-Mac server, and what the wheel gives up to ship

**The hypothesis** (not yet tested): this server's strongest commercial
position may be as a *desktop* server — a Mac mini or Studio running an
application on hardware someone already owns — rather than as a Linux
container competing with Granian and uvicorn on rps. The reasoning is that
Mojo's reason to exist is compute, and a Mac's compute is unusual: unified
memory, a GPU on the same die, a neural engine, and from M4 the SME/SME2
matrix extension. A server that could reach those from a request handler
would be doing something no Python server can.

**The finding that complicates it, which is concrete and already in the
tree.** `poe build-serve` pins `--target-cpu` to the *oldest* Apple Silicon:

    Darwin-arm64) tcpu=apple-m1 ;;      # oldest Apple Silicon

That pin exists because it had to — the first release crashed with SIGILL
in a clean container, and the comment beside it records that this
developer's machine natively targets `apple-m4` with **+sme/+sme2**, which
no M1/M2/M3 has. So the honest answer to "does the PyPI wheel retain
M-series-specific capability?" is **no, deliberately**. One portable wheel
per platform and per-microarchitecture code generation are the same
tradeoff seen from two sides, and the release path currently takes
portability.

That is not an argument against the hypothesis. It is an argument that
**the current distribution shape and that hypothesis are in tension**, and
that the tension should be resolved deliberately rather than discovered.
The options, none costed yet:

- per-microarchitecture wheels (`apple-m1` / `apple-m4`), selected by
  `pip` — more release matrix, and `pip` has no microarch selector, so it
  would need a launcher or a source path
- runtime dispatch: one binary, feature-detected code paths — the usual
  answer, and the most work
- keep the wheel portable and treat accelerator work as an opt-in
  component built on the target machine

**What has to be established before any of that is worth costing**, because
the whole hypothesis rests on it:

1. **Can Mojo target the Apple GPU at all?** Not assumed either way here.
   This toolchain has no `gpu` module — `from gpu.host import DeviceContext`
   fails with "unable to locate module 'gpu'" — but this repo installs
   `mojo` alone rather than the full MAX package, so that is evidence about
   *our* install, not about Modular's support. Check the MAX documentation
   for Metal/Apple Silicon status before building anything on it.
2. **The neural engine is probably not reachable.** Apple exposes the ANE
   through CoreML and publishes no low-level API; a language targeting it
   directly would be doing something Apple does not document. Treat "tap
   the neural engine" as *via CoreML from Python*, which needs no Mojo at
   all, until shown otherwise.
3. **What would a request handler actually do with it?** The server's hot
   path is HTTP parsing and a CPython crossing; neither is matrix work.
   The win, if it exists, is in *application* code the server hosts — which
   makes this a story about `m0-core`/MAX rather than about the HTTP layer,
   and possibly a different product.
4. **Is the premise even load-bearing?** `has_accelerator()` returns True on
   this M4, but that is one bit and should not be over-read.

Recorded now because the packaging decision that forfeits M-series
capability was made for a good reason, is already shipped, and would
otherwise be invisible to whoever picks this hypothesis up.

## Known issues

- **`mojo build` needs a C compiler on Linux and nothing says so.** It shells
  out for linking, so a minimal image (`python:*-slim` carries no compiler)
  fails with `unable to find suitable c compiler for linking`. CI never
  noticed because GitHub runners ship gcc. `build-essential` — or any cc —
  belongs beside `libsqlite3-dev` and `patchelf`.
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
- **Suspected race: the WebSocket close path can RST instead of FIN.**
  Seen twice, both on macOS CI runners and never locally — most recently on
  PR #113, a change touching only `scripts/binfmt.py` and `release.yml`,
  which cannot reach the event loop. So it is a genuine intermittent rather
  than anything a diff introduced, and the second sighting is consistent
  with the first in every detail below. Seen first (2026-08-25, macOS CI
  runner, PR #107's first smoke run):
  `ws_probe.py` failed with `ConnectionResetError` at its final
  `sock.recv` — *after* the entire close handshake had verified (text and
  binary echoes, server close with code 1000, client echo sent). Only the
  FIN it was waiting for never came; a rerun of identical code passed,
  and `main` with the same server code had passed an hour earlier, so
  this is a timing window, not a determinism.

  The suspected mechanism: the loop closes the slot while the client's
  close-echo frame is still unread in the socket's receive buffer, and a
  socket closed with pending unread data sends RST rather than FIN — a
  window a slow runner widens. If it recurs, the fix direction is in the
  WS teardown path: consume (or drain) the peer's close echo before the
  final `close`, which pins the orderly-FIN contract the probe already
  asserts. Deliberately recorded rather than fixed on one occurrence —
  the repo's own rule is that a guard must be verified load-bearing, and
  a fix for a failure that cannot yet be reproduced cannot be. Loosening
  the probe to tolerate RST would be the wrong repair: the FIN is the
  contract worth keeping, and the probe is doing its job by noticing.
- ~~**Graceful shutdown always waits the full 5 s drain when idle keep-alive
  connections are open**~~ — **fixed.** It did, in every execution mode.
  Measured 2026-08-23 on 3.14.7t, SIGTERM to process exit, `apps/wsgi_bare`:

  | | idle | 8 idle keep-alive connections |
  |---|---:|---:|
  | `--workers 4` | 0.02 s | **5.02 s** |
  | `--threads 4` | 0.02 s | **5.02 s** |
  | `--threads 4 --blocking-threads 4` | 0.02 s | **5.02 s** |

  This retired the suspicion that `--threads` shuts down slowly: it does not,
  and neither does the pool. What was slow was the drain, identically
  everywhere, because `active_count` counts a connection that is merely *open*
  the same as one with a request in flight — so the loop waited out
  `DRAIN_TIMEOUT_NS` for connections that were already finished. It also
  explains the earlier observation that two `--threads 4` processes
  "outlived a SIGTERM + 5 s wait": they exited at 5.02 s, and a 5 s wait
  loses that race.

  The shutdown path now closes slots in `READING_HEADERS` whose receive
  buffer is empty — "between requests" — before it starts the drain clock.
  Such a connection could never have been served by the drain loop anyway:
  that loop dispatches `EVFILT_WRITE` only, so a request arriving during a
  drain is not read there. Re-measured on 3.13 with the same harness, which
  reproduces the 5.02 s before the change:

  | | idle | 8 idle keep-alive connections |
  |---|---:|---:|
  | `--workers 4` | 0.03 s | **5.02 → 0.03 s** |
  | `--blocking-threads 4` | 0.02 s | **5.02 → 0.03 s** |
  | default (one loop) | 0.02 s | **5.02 → 0.03 s** |

  The two halves of the contract are pinned separately, because this changes
  *which* connections are dropped at shutdown: `smoke-blocking-threads`
  already asserted that a request in flight at SIGTERM is answered rather
  than dropped, and `smoke-shutdown` gained a phase asserting that idle
  keep-alive connections no longer hold the drain open. That new phase was
  checked against the unfixed loop and fails there at 5.01 s, so it is a
  guard rather than a decoration. A slot mid-request, mid-response, or with a
  job in a pool thread is deliberately left alone.
- The blocking `listen_and_serve` loop serves one accepted keep-alive
  connection exclusively until timeout or the `max_keepalive_requests` cap
  (measured p99 ~140 ms under 16 persistent connections). No in-repo app
  uses it anymore — `apps/hello` moved to the non-blocking loop like
  everything else — but it remains in the fork for the simplest embeddings.

## Recently resolved

- ~~**`--app-dir` is appended to `sys.path`, not prepended**~~ — **fixed
  2026-08-26.** It appended where gunicorn, uvicorn and `runserver` all
  `sys.path.insert(0, ...)`, so an application module could be shadowed by
  an installed package of the same name — invisible until it happened, and
  then invisible again because the wrong module simply serves. Found by
  dogfooding the wheel against a real Django project, reconfirmed by the
  three-project pass (a probe reported `--app-dir` at `sys.path[5]`, after
  site-packages), and fixed with `prepend_to_path`, which also declines to
  move an entry already at the front. The deferral was about risk —
  changing import precedence can break an application that accidentally
  depends on the order — and what retired it was having three real Django
  projects to check against. `smoke-serve` puts a module named `django`
  under `--app-dir` in a venv where the real Django is installed and
  requires ours to win; sabotaged back to appending, it fails.

- **A bare `://` anywhere in a request target was read as a scheme**, and the
  request answered `400` before reaching the application. `URI.parse` decided
  "this is an absolute URI" by searching the whole target for `://`, so a
  query parameter carrying an unencoded URL (`/go?url=http://x`) was parsed
  as a URI whose scheme was `/go?url=http`. Clients that percent-encode —
  every browser form, every `urlencode` — never hit it, which is what kept it
  rare enough to live in a Known-issues list.

  `scheme_separator` replaces the search: the `://` counts only when
  everything before it is a scheme as RFC 3986 §3.1 defines one — ALPHA, then
  ALPHA / DIGIT / `+` / `-` / `.` — a character set that by construction
  cannot contain `/`, `?` or `#`. It is computed before the `ByteReader`
  borrows the string, because a second interior reference taken while the
  reader holds one invalidates it. `test_uri_scheme.mojo` covers both
  directions, and `smoke-wsgi` now sends its `/reentrant?url=` unencoded as
  well as encoded, so a real server proves it. In the fork, so it is in
  [NOTICE](../NOTICE) too.

- **Request cookies never reached a WSGI application.** The parser diverted
  `Cookie` out of the header map into `RequestCookieJar`; the WSGI environ is
  built by walking the header map, so `HTTP_COOKIE` was absent and
  `request.COOKIES` was always empty. Nothing errored — Django simply saw
  every visitor as having arrived with no cookies, which disables sessions,
  login, CSRF and messages at once and looks from the outside like a user
  who will not stay logged in.

  `Cookie` now stays in `headers` *and* feeds the jar, since the two readers
  want different things: a Mojo handler wants `req.cookies`, and a WSGI
  application wants the raw field to parse itself, which is what PEP 3333
  asks for. Several `Cookie` fields rejoin into one `"; "`-separated list
  rather than collapsing to the last, and because a parsed request now holds
  its cookies in both places, `encode`/`write_to` write the jar only when
  `headers` lacks the field so a re-encoded request still emits one.

  The jar itself was broken three ways and had no callers, which is why none
  of it had ever been noticed: it split on every `=` (truncating any base64
  value, so a real `sessionid` lost its tail), split across the whole field
  rather than per cookie (`a=1; b=2` became one cookie `a` holding `1; b`),
  and lowercased lookups against case-sensitive storage. Its own
  `parse_cookies` was dead — `HTTPRequest` hand-rolled a separate, buggier
  copy — and both now share one path.

  The example enables `django.contrib.sessions` on the signed-cookie backend
  to prove it, which keeps the "no database" rule: `poe smoke-django` now
  asserts a session counter advances across three requests, which it cannot
  do unless cookies survive in both directions.

- **Request bodies that needed a second `recv` timed out with 408.** Read
  interest was registered only while a connection sat in `READING_HEADERS`
  — the accept path's arming condition names that state explicitly, and
  the transition into `READING_BODY` armed the body *timer* and nothing
  else. Edge-triggered epoll then made the stall total rather than merely
  racy: the tail of the body was usually already in the socket buffer, and
  the edge that delivered it was spent, so no further event was owed.
  Every request whose body did not land inside the first 4KB staging read
  stalled until `body_read_timeout` answered 408, as did every request
  whose client flushed headers before the body at any size. Headers were
  never affected, which is what hid it: an incomplete header read leaves
  the state at `READING_HEADERS`, so that path armed correctly and 8KB of
  headers always worked.

  The fix re-registers on entering `READING_BODY` and after each
  incomplete body read, unconditionally — with `EPOLLET` a fresh
  `EPOLL_CTL_MOD` is what regenerates readiness for bytes that are pending
  but unread, so a `slot_read_armed` guard would have preserved half the
  bug. `poe smoke-django` now posts a 256KB binary body and a
  headers-flushed-first body and compares the echo byte for byte; the old
  assertions all used bodies small enough to arrive in the eager read,
  which is why CI stayed green through it.

- **Cross-worker WebSocket fan-out** (`m0_http.WSHub` + `apps/ws_chat`):
  the handler-side registry for WebSocket connections, riding the same
  `BroadcastBus` as SSE — the bus is transport-agnostic, and
  `sse_peer_frame` delivers encoded WS frames as readily as SSE events.
  One chat room across `M0_WORKERS`; `poe smoke-chat` proves a message
  sent on one worker's socket arrives on the other worker's over the bus,
  with the concurrent-burst spread and worker-reaping lessons from the
  counter smoke baked into the probe.

- **WebSockets** (RFC 6455, server side): `websocket_upgrade` answers the
  handshake from an ordinary handler, the event loop owns frame mode
  (client-masking enforcement, fragment assembly, ping/pong and close
  answered in the loop, protocol violations closed with 1002/1009), and
  complete messages arrive at the `ws_message` trait hook. The outbox,
  heartbeat, and disconnect plumbing are shared with SSE — a WS slot's
  heartbeat is a protocol ping. `apps/ws_echo` is the reference;
  `poe smoke-ws` proves the wire format with a from-scratch stdlib client.
  Deliberate limits, documented in `websocket.mojo`: no extensions
  (RSV bits refused), no subprotocol negotiation, no client-side
  WebSocket in `Client`. (UTF-8 validation of text payloads landed after
  the initial ship: invalid text closes 1007, validated on the assembled
  message.)
- **Static file serving** (`m0_http.StaticFiles`): a directory mounted
  under a URL prefix, composing what already existed — `compute_etag` +
  `If-None-Match` → 304, a deliberately small extension→type map, `None`
  for paths outside the mount so the handler's routing continues. The
  load-bearing part is refusal: the URL path arrives percent-decoded, so
  traversal is rejected lexically per segment (`..`, `.`, empty, backslash,
  NUL → 404, never 400 — a probe deserves no confirmation), verified
  against a real secret file planted outside the root and sabotage-checked.
  Symlinks inside the root are the filesystem owner's decision, documented.
  No listings; every hit reads and hashes — compose with
  `ResponseCache` if a profile ever asks. (Range served arrived later:
  `parse_range`, 206 with `Content-Range`, 416 on unsatisfiable, and
  `Accept-Ranges` on the 200; `If-Range` is deliberately never satisfied,
  because the ETag is weak and RFC 9110 requires a strong comparison.)
  The notes example serves
  `/static/` and `poe smoke-notes` asserts type, ETag, 304, and two
  traversal probes (`--path-as-is`, percent-encoded).

- **The application timer hook exists: `HTTPService.tick`.** The eighth
  trait method, fired every `app_tick_ms` (`M0_APP_TICK_MS`, 0 = off) by a
  loop-wide one-shot timer that re-arms on every firing — the same
  discipline the SSE heartbeat learned, for the same epoll reason. "A
  shared todo list is expressible; a clock is not" stopped being true: the
  counter demo now runs a live uptime clock, broadcast from `tick` with no
  inbound request involved, and it composes with everything that came
  before — the sub-second tick drives a 1s sub-schedule (the intended
  pattern), only worker 0 owns the clock under `M0_WORKERS>1`, and the
  other worker's tabs get it over the `BroadcastBus` (asserted by smoke and
  verified in four real tabs across two workers). One honest asymmetry,
  found by sabotage: a never-re-armed tick fires exactly once on kqueue —
  the smoke's lower bound catches that on the macOS runner — while on epoll
  the same bug storms the loop but the demo's sub-schedule masks it from
  frame counts; the heartbeat's storm guard pins that shape.

- **`set_nonblocking` was a silent no-op on ARM64 macOS — for the fork's
  whole life.** fcntl is variadic, and Darwin ARM64 passes variadic
  arguments on the stack while `external_call` passed them in registers, so
  F_SETFL never received its flags. Single-worker servers never noticed
  (kqueue readiness gates every recv/send, and backlog counts gate accept),
  which is exactly why it survived: the first thing that ever needed a
  *losing* accept to fail fast was two workers racing on one shared
  listener, where the loser blocked inside accept() and its event loop —
  bus channel included — wedged until the next connection arrived. The fix
  is a padded call: nine fixed arguments on Darwin put the flag argument on
  the stack exactly where the variadic callee's va_list reads it. No C
  shim, so `mojo run` keeps working; `is_nonblocking` (F_GETFL, which never
  had the bug) plus a regression test hold the ABI reasoning to account on
  the macOS runner, and the dead `fcntl_wrapper.c` from an earlier shim
  attempt is deleted.

- **SSE heartbeats now actually tick, and dead subscribers are reaped on
  every close path.** The heartbeat plumbing (`sse_heartbeat_ms`, a per-fd
  timer, `: heartbeat` comments) existed but had never fired in anger: both
  backends implement one-shot timers, and the firing path never re-armed. On
  kqueue that meant exactly one heartbeat per stream, ever; on epoll it was
  a *storm* — the fired timerfd is level-triggered and nothing read it, so
  every `epoll_wait` redelivered it, measured at ~1,000,000 heartbeats in
  6 seconds. The handler now re-arms on every firing (which on epoll also
  clears the timerfd's expiration count — the load-bearing side effect), and
  `poe smoke-counter` pins both failure modes with a lower and upper bound
  on beats observed at a 500ms cadence. Separately, only the polite
  recv→0 disconnect path notified `sse_slot_disconnected`; the EV_EOF path —
  how a killed client actually presents on Linux (`EPOLLRDHUP`) — and the
  failed-write paths did not, leaving stale registry subscriptions. The
  notification now lives in `_close_slot`, the one place every close goes
  through, and a heartbeat send failure closes the slot instead of leaving a
  zombie — heartbeats are the disconnect *detector* for clients that vanish
  without a FIN. The smoke asserts the counter's `/health` subscriber count
  returns to 0 after an impolite disconnect (verified load-bearing: the old
  code leaves it at 1). `M0_SSE_HEARTBEAT_MS` wires the cadence through
  `AppConfig` (default 15000, 0 disables), and both Datastar demo pages now
  open their streams with `retry: 'always'` so a dropped stream reconnects.

- **The `src` name-collision hazard was a misdiagnosis, now fixed at the
  root.** The old known issue said tests bind `from src.x import` to
  whichever `-I` root comes first and survive on module names not colliding.
  Measured against the toolchain, the real rule: a test file inside a
  `test/` marked with `__init__.mojo` binds its *own* package's `src`
  regardless of `-I` order; only without that marker does `-I` order decide —
  and m0-wsgi (plus m0-sqlite) were exactly the packages missing it, which
  is how `test-wsgi`'s ordering workaround and the over-generalized rule
  were born. Every `test/` now carries the marker (documented as
  load-bearing), every test task lists its package first anyway, and a
  deliberately colliding `src/which_package.mojo` sentinel plus
  `test_resolution.mojo` in every package turns any future erosion into a
  loud failure instead of silent cross-package misbinding.
- **The C-ABI exports now ship as a shared object.** `poe build-ffi` emits
  `packages/m0-core/libm0core.so` (`.dylib` on macOS) from
  `ffi_exports.mojo`, which moved back to the package root: a shared-lib
  entry file cannot use relative imports, `@export` symbols are only emitted
  from the entry module, and a re-exporting wrapper is rejected by the
  compiler — so the entry *is* the definition, importing the hashing
  internals absolutely. The old outside-`src/` rot risk is held off by
  `test_ffi_exports.mojo` compiling the module on every `test-core` run and
  by `poe smoke-ffi` (in CI, both runners) loading the emitted library
  through `ctypes` and asserting the public FNV-1a/xxHash32 vectors.
- **The WSGI bridge leaked ~2.3 KB per request**, which on a long-lived
  worker grew the CPython heap without bound and turned gen-2 GC into
  ~200 ms event-loop pauses — the real cause of the close-mode latency tail
  previously (wrongly) pinned on the accept path. Root cause is the
  `PythonObject` interop leak above; the bridge now crosses per-request data
  as a byte blob through leak-free operations only, the shim gained the
  PEP 3333-required `close()` on the application's result iterable, and
  `smoke-django` fails if 10k requests grow the worker's RSS by more than
  12 MB (verified to catch the old bridge at ~23 MB). Diagnosis narrative
  and clean numbers in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md).
- **The event loop's accept drain broke on any `accept()` error.** An
  `ECONNABORTED` from a client that gave up while queued ended the whole
  drain, and on an edge-triggered listen socket (both backends) the
  connections left behind are owed no new readiness edge until another
  connection arrives — stranding live clients behind a dead one under bursty
  load. Transient errors now skip and keep draining; only `EAGAIN` and
  resource-exhaustion errors end the drain.
- **`WorkerSupervisor` respawn returned to the wrong place.** A respawned
  child returned `True` up through `_supervise` and kept *supervising* instead
  of returning to `fork_all`'s caller, so it never reached server startup.
  `_try_respawn` now distinguishes parent from child, and the child unwinds
  out of `fork_all` exactly like an initially-forked worker. `test_respawn.mojo`
  proves it with real forks (the whole scenario isolated in a subprocess), and
  was verified load-bearing against the old code. `M0_WORKERS` is now wired
  into `apps/django_wsgi`.
- **`packages/m0-core/ffi/` was dead code** — outside `src/`, so `mojo
  precompile src` never compiled it. Moving it to `src/ffi/` revealed it had
  also gone stale against Mojo 1.0: `@export` rejects parametric functions, so
  the inferred pointer origins (`UnsafePointer[UInt8, _]`) had to be named.
  Now compiled, exported, and covered by tests asserting the exports agree with
  the pure-Mojo hash functions.
- **The fork's request-parsing hardening was untested.** `test_parsing.mojo`
  now pins every claim [NOTICE](../NOTICE) makes: request smuggling (CL+TE,
  duplicate `Content-Length`, `chunked` not last), the `Host` requirement, the
  header-count cap, request-target normalization, and chunked integer overflow.
  Each guard was verified load-bearing by disabling it and confirming the
  matching test fails — the overflow guard turned out to crash the process when
  removed, and an earlier version of that test passed either way.
- **m0-sqlite reliability pass** — busy timeouts, non-raising `reset`/`finalize`,
  real SQLite error text, single-statement `prepare`. See
  [SQLITE_PERFORMANCE.md](SQLITE_PERFORMANCE.md) for the measured optimization
  work that accompanied it.
