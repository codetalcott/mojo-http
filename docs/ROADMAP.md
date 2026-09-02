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
  flattered the executor). Built — below.

  **Built 2026-08-27, and what it returns depends on how many
  connections are open: +5% at 16, +7% at 64, +19% at 256 —
  where the executor passes `uvicorn --loop asyncio` (1.10x; 0.85x
  against uvicorn with uvloop).** Both directions are batched: the loop
  buffers a pass's submits to an executor lane and sends them as one
  `TAG_JOB_BATCH` datagram at the bottom of the pass, and the executor
  queues a pump pass's completions and pokes the loop once
  (`complete_many`), with the begin-before-head order kept by flushing
  queued completions before every non-begin chunk frame. Measured in one
  session with `scripts/bench_asgi_wrk.sh` (the script the
  `asgi-wrk-hello` artifact never had), the uvicorn rows re-measured in
  every run as the drift control; the concurrency table and its
  artifacts (`bench/results/asgi-wrk-conns-*.json`) are in
  [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md). Why 16 connections gain so
  little is a number the record now carries: **a pass batches three
  submits on average there** (counted; batches of sixteen occurred 18
  times in 60,000) — keep-alive connections are not in lockstep, each
  sends its next request as its own response lands, so the wakeup
  amortisation is ~3x; at 256 the groups are large and it is real. The
  benchmark page keeps `-c16` as its row because that is the standing
  configuration; the honest summary is that the executor's deficit on
  that row is handoff *latency* at low concurrency, not throughput.
  Three more things the same session settled, recorded on the same page:
  the executor under uvloop is a wash (−3% at 16 connections, +4% at
  256), because the pump leaves the loop every pass and uvloop is built
  to be entered once — a `run_until_complete` pass costs 64 µs there
  against 38 on stdlib asyncio; the pass itself is the next lever, a
  `run_forever` + `stop()` shape costing 17 µs against 38, measured as a
  shim-only prototype at +16% at 16 connections and +18% at 64 on top of
  batching (0.90x and 1.17x `uvicorn --loop asyncio`) and landed the same
  day with the one rule the seam's shutdown paths demand — a stop is
  armed only while the pump itself is parked, never inside
  `finish_executor`'s post-pill gather, which it would otherwise end early
  and skip the application's lifespan shutdown (`smoke-asgi`'s
  outlive-the-drain phase pins it, sabotage-verified against the
  unguarded prototype) — and then inverted outright: `ExecutorPort`, a
  Python type built in-process with `PythonModuleBuilder`, lets the shim
  call INTO Mojo for every event, so the executor thread parks in one
  `run_forever` for its life and the per-pass cost is gone (+1%
  more at 16 connections on asyncio; on uvloop, which the old shape could
  not use, 1.05x the asyncio comparator on the standing row);
  and `bench-asgi`'s stdlib harness now reads the executor at 1.4x
  uvicorn where wrk reads 0.7–1.1x — it measures its own client — so its
  throughput gate is retired (the ratio is printed as information; the
  mixed-tail gate, the executor's actual claim, stays) and the wrk
  artifacts are the record.
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
  6. **Discoverability.** The pages are good and GitHub is the only place
     that indexes them; the repository and the PyPI project both point
     nowhere but back at GitHub. **Built 2026-09-02**: a documentation
     site rendered from the tree's own pages by `scripts/docsite.py` and
     served by m0serve through `--static` (`apps/site` behind it for the
     slash redirect and the 404), with `llms.txt` and `llms-full.txt` at
     the root, a Markdown twin beside every page, a sitemap, canonical
     links and JSON-LD, and titles written for the question a reader
     types rather than the file's name. `poe smoke-site` proves the
     served shape (F13); the link check runs on doc-only pull requests.
     The deployment is built too (2026-09-02, `deploy/site/`): the domain
     is `m0serve.dev`, registered; the host is Fly.io, one always-on
     256 MB shared machine in `iad`, chosen over a VPS after Hetzner's
     2026 repricing left its US plans at ten times the cost for CPU a
     2.5 MB site cannot use; the image is the M11 container shape with
     the site copied in, proven from the tree's wheel by `poe
     smoke-site-image` (F14), and `deploy-site.yml` deploys after each
     release pinning that release's wheel. The first public deploy waits
     on the next release, because the site's redirect and 404 need the
     static mount's fall-through that 0.16.0 lacks. Still open, and each
     a launch task: the live two-tab demo beside the docs (a separate Fly
     app on a subdomain), and the off-site half -- the homepage field on
     GitHub (once the site is live; PyPI's Documentation link rides the
     next release), djangopackages, the Modular forum.

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

### Hardening the streaming seam — shipped 2026-08-27

0.14.0 shipped a fix for a hang that had been live all day: the shim keyed
a connection slot's executor state — credit window, event, disconnect mark
— by SLOT, while the loop recycles a slot the instant it closes a
connection, so a client that closed one stream and opened another on the
same slot could leave the loop holding a subscription with no producer.
The client saw a 30 s stall against a clean server log. It reproduced 8 of
11 `smoke-asgi` runs under twelve CPU hogs and **vanished under every
instrumentation that added a timer**.

What that left behind was a gap, not a bug: the fix was verified by an
ad-hoc reproducer in a scratchpad, so nothing in CI or `poe` would catch a
re-introduction — which breaks this repo's own rule that every guard is
sabotage-verified. And it was one instance of a shape, not a one-off: the
same seam had five more paths where a failure was *discarded* rather than
reported.

**The guards.** Two, because the failure has two natures.

`poe test-shim` is the deterministic half, and IS in CI. The shim is a
Python program inside a Mojo string, so `scripts/shim_ownership.py`
extracts `SHIM_SOURCE`, `exec`s it, hands it a real asyncio loop and a
socketpair per channel, and drives it exactly as the Mojo loop does —
8-byte job datagrams, 9-byte disconnect tags, 8-byte drain acks — with a
stand-in `_port` that records every event and spawns on `('job', slot)`,
which is what `ExecutorPort._dispatch` does. No server, no Mojo, no
interpreter embedding, no threads. Six tests, one per rule; on the shim
reverted to its pre-fix shape, four of the six fail. `--sabotage` (what
the poe task runs) reverts each rule in the extracted source in turn and
insists the suite fails for every one — the sabotage rule made permanent
instead of remembered, and a patch that no longer applies is itself a
failure, because that means a guarded line was renamed or deleted.

`poe stress-asgi` is the timing half, and is deliberately NOT in CI:
`chunked_keepalive.py` N times under CPU hogs, whose HTTP/1.0 probe closes
after its head so the keep-alive stream behind it lands on the same slot.
On the reverted build it failed on round 5 of 15 under 20 hogs, with a
silent server log; on `main`, 45 of 45 across three runs. Shared runners
are already loaded and cannot reproduce this reliably, which is exactly
why CI passed with the bug live — so it is a pre-release check
([RELEASING.md](RELEASING.md)), not a gate.

**The other five paths, all the same shape.** A frame the streaming seam
could not place was discarded at five of six sites. Each is now terminal
and named, and each was measured both ways by forcing the failure:

| path | before | after |
|---|---|---|
| `b` stream begin dropped | a clean, **empty 200**; the log names only a downstream `KeyError` | 500 + close in 11 ms, one named line, the app's task cancelled through its own disconnect tag |
| `e` stream end dropped | the client hangs to its own timeout (12 s, curl exit 28); log silent | bytes delivered, then a close with no terminator (exit 18) in 13 ms, one named line |
| `s` chunk refused by the outbox | a 12 s hang, log silent | abort — truncation the client can see — one named line |
| `w` WebSocket frame refused | 430,693 of 1,638,400 bytes delivered under a **clean close frame**; log silent | 61,689 bytes then an abrupt close (1006), one named line |
| a stale drain ack | credits a recycled slot's new stream, over-committing the one shared chunk channel | clamped to the window |

The `w` case is the reachable one and was reproduced with an ordinary
client: an ASGI app sending 400 × 4 KB with no pause, and a peer that
completes the handshake and then stalls two seconds. `websocket.send` was
not credit-gated at all — unlike a response chunk, which is gated twice —
so the outbox filled. **That gap is now closed** (see below), which turns
the loud failure back into a working one; the tear-down stays as the last
resort. The `s` case is unreachable by construction today
(a stream may have at most one 64 KB window of un-acked bytes outstanding,
bytes are acked only once they have left the outbox, and the window equals
`MAX_PENDING_BYTES`); it is guarded because that invariant is implicit and
one constant away from breaking, and because being wrong about it silently
costs a stream that stalls for ever.

**A WebSocket could not be aborted at all**, which the measurements found
rather than the reading: the loop's abort path gates on `slot_sse`, and a
held 101 never sets it — `websocket_upgrade` builds an ordinary response —
so `abort_stream` on a socket was a silent no-op. Verified by isolating it:
with an outbound frame forced to fail, the socket closes immediately when
the abort knows about sockets and is still open eight seconds later when it
does not. Two lines in `event_loop.mojo` fix it — the gate reads
`slot_sse or slot_ws`, and a 101 records its generation in
`OffloadLoopState.stream_gen` AFTER the non-stream branch's `clear_stream`,
which was wiping it (the first attempt set it in the upgrade branch and the
abort was still dropped, on the generation check instead). Recorded in
NOTICE. The loop-side refusal (`queue_frame`) does not use it: a socket's
outbox is unframed, so `asgi_done` flushes what is queued and the loop's
`ended and not framed` branch closes — which is better, because those bytes
are real. And the tear-down has to be claimed once per stream: the producer
does not learn its connection is gone until the loop closes it, so one
flooding socket announced itself 336 times before `stream_lost` made it
once.

**Generation-tagged acks: considered, not built.** The real fix for a
stale ack is to carry the stream's generation in the ack datagram, as
every chunk frame already does. The clamp is exact for the damage that
matters — `credit + in flight == the window` is the invariant, and `min()`
keeps it true — and the residual is a transient over-credit of the global
budget that cancels itself on the next real ack (the refund is capped by
the slot's own in-flight count). Widening the ack wire format touches
`ack_stream`, the loop's owed-credit retry, the pool thread's stop-and-wait
poll and the shim's reader; it is worth doing when one of those changes
for another reason, not on its own.

### The WebSocket send window — shipped 2026-08-28

The one path above that an ordinary application reaches, made to work
rather than merely to fail honestly. `websocket.send` had no window: an
app faster than its client filled the loop's 64 KB per-slot outbox and
every frame past it was dropped — 430,693 of 1,638,400 bytes under a
clean close frame. It waits for drain credit now, exactly as `_emit` does
for a streaming HTTP response, and the same flood arrives whole:
**1,640,193 bytes on the wire, byte for byte** (400 × 4 KB payload plus
4-byte headers, the handshake and the close frame).

Almost nothing new was built. The loop was *already* acking a socket's
drained bytes — a WS slot on an executor lane answers
`slot_channel_stream`, so the outbox drain's `ack_stream` fires — and the
shim was discarding those acks, because `_exec_credits[slot]` is only ever
seeded at HTTP stream start. Seeding it at `websocket.accept` and awaiting
it in `send` is the whole change.

One thing had to be got right: credit is charged in **encoded frame
bytes**, not payload bytes, because encoded frames are what the outbox
holds and what the loop acks back. Charging the payload drifts by the
header on every message — threefold on one-byte sends, which is exactly
the traffic that reaches a 64 KB cap first. `_ws_frame_bytes` mirrors
`encode_ws_frame`'s unmasked 2/4/10-byte header.

Guarded twice, sabotage-proven both ways. `apps/asgi_bare` has a
`/ws/flood` route and `ws_probe.py` a phase that stalls two seconds and
then asserts the exact frame and byte counts, so `smoke-asgi` carries it
in CI; ungated it reports "15 of 400 frames (61440 of 1638400 bytes)
arrived". And `shim_ownership.py` pins the arithmetic with no server at
all: one window of 65536 bytes holds exactly 15 frames of 4100, credit for
eight releases exactly eight more. Two sabotage entries — the `await`
removed, and the window never seeded — each fail that test.

Two limits it does not lift, both loud rather than silent now: a single
message larger than `MAX_PENDING_BYTES` is refused by the outbox, whose
cap bounds one frame as well as the queue; and a `--realtime` hold on a
WSGI lane gets no window, the loop not acking those sockets. Neither is
new, and `_ws_spend` returns without charging where there is no window
rather than pretending to gate.

### Not planned, and why

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

### The loop inversion — in progress 2026-08-28

The handoff's item 1: run the Mojo loop's pass as a callback inside the
executor's `run_forever`, on one thread, so a request goes parse → app →
response with no datagram and no cross-thread wake. At c16 the pump batches
about one submit per pass, so every request pays two wakes today; removing
them is the whole bet, and the gate is unchanged — ≥1.0x
`uvicorn --loop asyncio` at c16 on stdlib asyncio, both loops measured, RSS
0 KB over 10k requests, `stress-asgi` N of N.

Landed so far, each a verbatim move with zero behaviour change:
`run_event_loop` is `prepare_loop` → `LoopState` + a `while` over
`_run_pass` / `_run_shutdown`. Established on the way: asyncio's
`KqueueSelector` fires `add_reader` on a kqueue fd (spiked live);
`backend.wait(0)` is a real non-blocking poll; field-projected `ref`
bindings of one `mut` struct pass exclusivity as separate `mut` arguments.

**Built and measured, first cut (2026-08-28, `M0_INVERTED=1`).** Correct
under every gate: `smoke-asgi` with 0 KB RSS, fan-out, Django ASGI,
FastHTML, `stress-asgi` 30/30 — on kqueue, and on **epoll** too, verified
in a Linux container before CI (`scripts/epoll_inverted_check.sh` under
colima, linux/aarch64: the smoke with 0 KB RSS, the recycled-slot probe,
`stress-asgi` 30/30 under 8 hogs). Two single-thread traps found and fixed on
the way — a producer waiting for the loop to drain the chunk channel was
waiting for itself (`_place_frame` runs a pass instead), and a direct job
overtook the slot's disconnect tag on the FIFO submit channel and stamped
the new task (`notify_disconnect` goes direct). Both showed as the
recycled-slot probe timing out with a clean log.

The bet was half right. Same session, uvloop executor, c16, two samples of
three rounds: inverted **59.1–59.6k rps at 0.87–0.88 cores** (p50 263 µs),
pump **62.6–63.1k at 0.98** (p50 237 µs), uvicorn asyncio ~57.5k and
uvicorn uvloop ~82.4k at ~0.99. The wakes were ~1 µs of CPU each and are
gone — that is the −11% of cores — but the pump's two threads were also
overlapping Mojo parse/write with Python app work, and at c16 wrk is a
closed loop (16 ÷ p50 is the rps), so +27 µs of serialized latency per
request is −6% rps. Per core the inversion is +5% (~67.6k vs ~64.5k
rps/core); against uvicorn asyncio it is 1.03x on uvloop. On stdlib asyncio
— the gate's own row, executor on the system Python 3.13 with no uvloop —
inverted **~54.0k at 0.89 cores** and pump **~53.4k at 0.99** against
uvicorn asyncio ~57.6k: +1% rps at −10% CPU, **+12% per core**, and BOTH
arms at 0.93x uvicorn asyncio, so the gate (≥1.0x at c16 on stdlib
asyncio) is met by neither. Artifacts, both arms and both loops:
`bench/results/inverted-ab/`. The default stays the pump. What would change the verdict is not fewer
wakes but less serialized work per request — the 2.05 µs parse and the
per-pass 1,024-slot outbox sweep were the two named levers — or a
workload where CPU, not closed-loop latency, is the bound.

**The parse lever, taken 2026-08-29, moved the gate's row for both arms
— and cleared it for both.** Same session, one binary per parser, the
executor on the system Python 3.13 with no uvloop (the gate's own row),
c16, medians of three, uvicorn asyncio re-measured beside every arm
(`bench/results/parse-lever-ab/`):

| executor | old parser | new parser |
|---|---|---|
| pump, stdlib asyncio | 55.7k @0.96 cores — 0.96x uvicorn asyncio (58.1k) | **60.1k @0.97 — 1.03x** (58.4k) |
| inverted, stdlib asyncio | 54.5k @0.89 — 0.93x (58.7k) | **59.7k @0.88 — 1.01x** (59.0k), 67.9k/core |
| pump, uvloop | 63.2k @0.97 — 0.77x uvicorn uvloop (81.9k) | **69.1k @1.00 — 0.83x** (83.4k) |
| inverted, uvloop | 60.2k @0.88 — 0.72x (83.7k) | **66.4k @0.86 — 0.79x** (84.0k), 77.2k/core |

The parser is the same 1.1 µs cheaper under all four, and on a closed-loop
client that is +8–9% rps on the pump and +10% on the inversion, on either
loop. What the lever did NOT change is the inversion's standing against
the pump: on throughput it is within noise on stdlib asyncio (59.7k
against 60.1k) and −4% on uvloop (66.4k against 69.1k), and per core it
keeps +9% and +12% (77.2k/core on uvloop is 0.92x uvicorn-uvloop's, where
its rps is 0.79x). So the ROADMAP gate as written — ≥1.0x `uvicorn --loop
asyncio` at c16 on stdlib asyncio — is now met by the pump on its own,
and the inversion's remaining claim is CPU, not rps. Whether that claim is
worth making it the default is the 0.15.0 question; the numbers are filed
either way. (The outbox sweep, the other named lever, was taken later the
same day — "The outbox sweep", below.)

**Evaluated the same day, and the answer is no — not for 0.15.0.** Two
more measurements settled it. At **c256** (uvloop executor, pump →
inverted → pump back to back on an otherwise idle machine, comparators
within 0.5% across all three arms; the `-c256-` artifacts in
`parse-lever-ab/`) the per-core edge is gone: pump 88.1k @1.02 and 87.3k
@1.02 around inverted 85.5k @0.99 — −2.5% rps, +0.6% per core, tails
identical. The +12% per core at c16 is the ~0.1 core of cross-thread
handoff the pump pays at light load, and its batching amortizes exactly
that away where CPU becomes the bound; the edge does not buy capacity.
(A first c256 run had put the inversion at 73k in one round with a
23 ms p99; the drift-control rows showed a 13% dent in the comparator
during that arm — another session on the machine — and the clean rerun
had no such round.) And the shutdown limitation above is a regression
the pump does not have. What the inversion honestly is on these numbers:
an efficiency mode for low-concurrency, tail-sensitive deployments —
−14% CPU and a better p90/p99 at c16, a worse p50, nothing at
saturation, one topology — not a throughput default. The bar for ever
promoting it: design item 6 with a smoke that pins the in-flight
shutdown case, and a saturation workload showing a gain, which no
measurement yet does. (The outbox sweep, the other named lever, was
taken the same day — the next entry — and is worth +4.6% to the
inversion at c16; it does not change this reading.)

### The outbox sweep — taken, scoped (2026-08-29)

The second lever the inversion entry named. Every pass swept all 1,024
slots for a streaming one to drain, and the miss path — two flag loads
per slot, none set — measured **1.2–1.3 µs per pass** in isolation, on a
pass that carries one or two requests at low concurrency. The ceiling,
with the sweep skipped outright (`bench/results/outbox-sweep/`,
comparators within the clean band on every arm): hello **+3.5%** at c16
and +2% at c64, the inverted executor **+4.1%** at c16 — and the pump
**−2.9% rps at +6% CPU** at c16, ±0 at c256. That last row is the
finding: under the pump the microsecond was accidental pacing. A loop
thread that returns to `wait` a microsecond sooner finds fewer events,
batches fewer submits, and the executor thread takes more wakes per
request; at c256 the batches are large regardless and it makes no
difference either way.

So the gate is scoped. `OffloadLoopState.streaming_hint` is an upper
bound on the flagged slots — raised by the two sites that set a stream
flag (both in `_finish_response`), recounted by the sweep itself, never
touched by the many sites that clear one, so an under-count (a stream
nothing drains) cannot happen and an over-count costs one sweep — and
the sweep runs only while it is non-zero. EXCEPT when the pool says
`sweeps_every_pass`, which the pump wiring sets and nothing else does:
its loop keeps the per-pass sweep, and the reason is written on the
field. Realized (same day, comparators clean): hello **152.3k → 157.4k
at c16 (+3.3%, +5.5% per core)**, +1.3% at c64; the inverted executor
**59.3k → 62.0k (+4.6%)**, 69.6k/core; the pump 60.0k → 59.7k @0.98,
parity within noise, as intended. Guards:
the streaming smokes, sabotaged three ways — never sweep (counter and ws
fail), the SSE site not raising the hint (counter fails, ws passes), the
WS site not raising it (ws fails, counter passes).

### Pacing the pump's loop thread

What the sweep measurement exposed: at c16 the pump's throughput depends
on how long its loop thread spends per pass, in a way that an accidental
1.2 µs improved by 3%. An *explicit* pause before flushing a partial
batch — spin N ns, optionally re-poll once and fold the new events'
submits into the same datagram — is the deliberate form of that, and
tunable where the sweep was not.

**Measured the same day, as an experiment patch, and recorded rather
than built** (`bench/results/outbox-sweep/pacing/`, fourteen arms, pump,
c16, stdlib asyncio, uvicorn asyncio within 58.3–59.3k on every one):

| pump's loop thread, per pass | rps @ cores |
|---|---|
| the sweep (today) | 59.95k @0.97 |
| no sweep, no pause | 58.70k @1.01 |
| spin 500 / 1000 / 2000 / 4000 ns **before a partial flush only** | 58.6–59.0k @0.97–1.01 |
| the same, then `wait(0)` and fold the new events into the pass | 58.9–59.3k @**1.05** |
| spin 1200 / 2000 ns **on every pass** | **60.04k / 60.13k @0.97** |
| the same, with the re-poll | 55.6–55.8k @**1.08** |

Two things settled. The sweep's effect is a delay on *every* pass —
including the completion-only passes that write responses and park —
not on the pass that has submits to flush: pausing only before a
partial flush is too late, because by then the batch is whatever the
previous `wait` returned, while a pause after writing responses lets
the clients' next requests arrive before the loop parks. An explicit
per-pass spin of 1.2–2 µs reproduces the sweep to within noise, and no
longer pause improves on it. And the re-poll is simply worse: a nested
pass costs the loop thread more than a merged batch saves the executor.
So the pump keeps its pacing through the sweep it already runs, which
is neither prettier nor uglier than a spin and needs no knob; the
finding is that ~2% at c16 (and nothing at c256) is what per-pass
latency on the pump's loop thread is worth, and that it is already
collected.

The design, so it is not re-derived:

- **Scope:** unmounted single-executor ASGI only — the benchmark shape.
  Every other topology stays on the pump. Behind `M0_INVERTED=1` until the
  gate passes, so the A/B is one environment variable.
- **Submit:** a defaulted `HTTPService` hook (`direct_job(slot) -> Bool`,
  default False — Phase 1 made adding one non-breaking). The loop still
  parks the request; on an executor lane it asks the handler first and
  sends the datagram only when it declines. `WSGIHandler` in inverted mode
  answers by running the port's job branch, factored into one function
  shared with the port.
- **Complete:** the port keeps parking responses; its per-iteration
  `_flush` calls `service_direct_completions[T,B](handler, backend, st,
  slots)` — the per-slot body of `_service_completions` — instead of a
  datagram. The port grows the loop state's and backend's addresses; the
  backend is the platform one, no `DetachingBackend`, because `wait(0)`
  never blocks attached.
- **The ordering rule that makes it safe:** a stream's begin frame rides
  the chunk channel and is drained by a PASS, while its head is a direct
  completion. `_flush` therefore runs a pass first and completions second,
  or a head could precede its own begin frame — the recycled-slot hazard
  the 0.14.1 rules exist for. Deterministic on one thread.
- **Driver:** `add_reader(kq_fd, _on_mojo)` → `port.pass_()`, plus a 1 Hz
  `call_later` for the idle sweep, the date cache and the heartbeats,
  which assume a wake per second. Acks and credit unchanged.
- **Shutdown — designed, not built, and deliberately skipped
  (2026-08-29):** `_run_shutdown`'s drain waits in `backend.wait`, which
  inside an asyncio callback blocks the very tasks it waits for. The
  design was to poll the drain from `call_later` passes until
  `active_count == 0` or the 5 s budget, then `loop.stop()`. The first
  cut runs the drain as it is, blocking, and the consequence is measured:
  with a 1.5 s request mid-await at SIGTERM the pump answers it at
  1.50 s, the inversion at **5.30 s** — the drain deadline, after which
  the shim runs the in-flight tasks to completion and the response goes
  out. Not dropped, but any stop grace under ~6 s drops it. The
  reshaping is half a day (split `_run_shutdown` into prepare / step /
  finish as `run_event_loop` was split, drive the step from a
  `call_later` cadence) and buys that only under the flag, which nothing
  runs in production; it is the inversion's promotion bar, not 0.15.0
  work. Until then an inverted server wants a stop grace of 10 s or more
  (`docker stop`'s default), and the comment beside the flag in
  `m0serve.mojo` says so.

### The Mojo handler pool — shipped 2026-08-28

The offload pool, for handlers written in Mojo. Planned as a kill-criterion
spike: if a slow Mojo handler did not strand the connections behind it the
way a slow Python view does, the branch was to be deleted and this entry was
to say why. It stranded them harder — a Mojo handler blocks the single loop
thread outright, so at two 400 ms blockers the fast route's **p50** was
405 ms, not merely its p99 — and the pool of 4 held 0.2–0.3 ms throughout
(three runs; the loop-only collapse is definitionally expected, the pooled
row's complete recovery is the result). `lightbug_http/mojo_pool.mojo`:
`MojoPool` + `PoolHandler` (`make`/`shutdown` — two methods against
`ThreadHandler`'s eleven, the other nine being WSGI streaming and mounts),
over the same `OffloadPool`/`ThreadSet` machinery, minus the four
attach/detach sites that were the only Python in the WSGI pool's thread body.

Boundaries, stated where they were decided:

- **Blocking handlers only.** `asyncrt`'s `TaskGroup` parallelises CPU work
  inside one handler at 3.6x with no plumbing; the pool exists for threads
  parked in a syscall. The spike's `/slow` is `usleep`, not a spin, so the
  measurement cannot conflate the two.
- **Streaming from a pool thread is a 409**, matching the blocking loop's
  `gate_streaming_response` refusal: the loop drains its own handler's
  registries, and a stream begun on a pool thread has no producer.
- **The saturation boundary is in the probe's own table** (blockers >
  threads), so the pooled row is shown degrading where it must rather than
  implying N threads are magic. Measured at 6 blockers on 4 threads
  (`bench/results/pool-probe-20260828T175956Z.json`): the pool's fast-route
  p99 is ~one blocking duration (404 ms, p50 31.8 ms) while the bare loop's
  is the queue's sum (2026 ms, p50 2022 ms) — saturation degrades a pooled
  server linearly, not catastrophically.
- **Untested, recorded not dropped:** composition with `M0_WORKERS` prefork
  (the Python table says prefork alone does not fix stranding — same
  mechanism here, unmeasured); the per-mount `lanes` plumbing has no
  consumer yet.

Guards: `test_mojo_pool` in `test-http`; `smoke-pool` in CI (thread
attribution, saturation, clean SIGTERM); `sabotage-pool` in CI on Linux —
the one-pill-per-thread rule is invisible on macOS, where closing the
submit channel wakes a blocked `recv` (`OffloadPool.stop`'s documented
20-minute-CI-timeout lesson); `probe-pool` pre-release (RELEASING.md).
Sabotage earned its keep before landing: it caught the per-thread-handler
test asserting completions without ever checking the handler indices
differed.

### Mojo language capabilities, surveyed 2026-08-28

A pass over what the tree uses of the language, prompted by "are we fully
tapping Mojo?". The short answer is yes wherever it was measured to pay —
SoA span-based headers (+72%, the largest single win here), SIMD parsing, an
allocation-free router, 14 `comptime if` platform specialisations, the raw
C API at the Python boundary, `ExecutorPort` at ~70 ns. What was missing was
expressiveness, and `HTTPService`'s default bodies and `m0_http.reply` are
that gap closed. The rest is recorded here.

- **More SIMD in the request path.** Was refused by our own profile — 31 of
  35 stack samples in `__libc_send` (SERVER_PERFORMANCE.md) — and the
  instrument that entry asked for, once built, disagreed with the profile.
  `scripts/bench_http_parts.mojo` (2026-08-28) put `parse_request_headers`
  at **two thirds** of the user-space request: the profile's verdict was
  drawn at 50k rps and the server now does 116k, so a cost that was
  invisible in loopback noise is a quarter of every request. The
  span-based `HTTPHeader` that fell out of it took the parse from 2.52 to
  2.05 µs (−12% on the whole user-space request). What remained — the
  byte-at-a-time scanner tail below 64 bytes, twelve `set_bytes` appends,
  three linear RFC checks — was recorded as the next lever, and **taken
  2026-08-29: the parse is 0.86 µs and the user-space request 1.97 µs
  (−40%)**. The instrument, split one level further, said the lever was
  not where the entry above put it: half the parse was the wrapper's blob
  build, 0.3 µs was the offsets array's fill (66 ns measured alone, where
  the compiler elides it), and the SIMD scanners were spending their time
  in a scalar walk over the lanes of a chunk they had already matched —
  9.4 ns per chunk against 0.8 for a `select` of `iota`. The story is in
  SERVER_PERFORMANCE.md; the lesson for this list is that a part measured
  in isolation can be a fifth of its cost in context, and the instrument
  has to be split until the number stops moving. What remains is 0.86 µs
  against a 5.3 µs syscall floor no parser can touch; the per-byte token
  check was measured against a bit table and is a wash. `escape_html`,
  `chunked.mojo`'s copy loops and `Headers._name_matches` are still
  scalar and, per the same instrument's lookup rows (30–70 ns each), still
  not worth it.
- **`simdwidthof` / SIMD width portability.** Every one of the 18 SIMD sites
  hardcodes 64/16/8/4 lanes and `simdwidthof` appears nowhere. Moot for the
  shipped artifact regardless: `build-serve` pins `--target-cpu apple-m1`,
  so the wheel already forfeits newer width. Related to the desktop-Mac open
  question below, not separable from it.
- **GPU / MAX.** Established and declined. Mojo 1.0 moved the accelerator
  APIs out of the stdlib into the `max` package, which this repo does not
  pin — `from gpu.host import DeviceContext` fails here, and that is now a
  fact about the language's packaging rather than about our install. Linking
  MAX into an HTTP server to serve a request is a different product; the
  open question below is where that belongs if it belongs anywhere.
- **Native async Mojo handlers (an `async def` handler on a Mojo reactor).**
  Distinct from the coroutine entry above, and refused for a different
  reason than "the language cannot". It can, partly — measured 2026-08-28,
  not assumed:

  `std.runtime.asyncrt` **exists on the pinned 1.0.0** and exports
  `TaskGroup`, `create_task`, `Task`, `TaskGroupContext` and
  `parallelism_level` (4 on this M4). It works, and it is genuinely
  multi-threaded: four CPU-bound `async def`s in a `TaskGroup` ran **3.6x**
  faster than the same work serially. `create_task(coro).wait()` from a sync
  `main` is fine — but `Task(coro).wait()`, the spelling recorded elsewhere
  as segfaulting, still crashes, so the constructor is the trap, not
  async-from-sync. The module also ships `RaisingTask` /
  `create_raising_task`, which is the pair that would matter here:
  `HTTPService.func` is the one method that `raises`, so a handler task
  cannot use plain `create_task`.

  **What it is not is a reactor.** There is no awaitable I/O: no `sleep`, no
  `block_on`, nothing that takes a file descriptor. A blocking syscall inside
  a task occupies a runtime worker. Sixteen tasks each blocking 200 ms took
  **816 ms**, against 800 ms predicted for a 4-worker pool and 200 ms for a
  reactor — so this is a work-stealing compute pool, and connection
  concurrency is exactly the thing it cannot give us. Anything reactor-shaped
  is still ours to write and maintain, for handlers that today block a pool
  thread perfectly well. Gate it on a real application that needs it.

  The positive half is worth keeping in view: `asyncrt` is the right tool for
  **CPU fan-out inside one handler** — a Mojo handler doing real computation
  can parallelise it with no pool, no threads of our own and no `--blocking-
  threads`. That also sharpens what the handler pool is *for*: blocking, not
  computing. Which is why the pool spike's kill criterion measures a handler
  that blocks.
- **`std.base64` / `std.hashlib` for the WebSocket handshake.**
  `websocket.mojo:24-27` already argues the hand-rolled SHA-1 and base64:
  one hash of one short string per connection open, and nothing else in the
  repo needs either. Recorded so the argument is not re-run.

### Considered, not built: routes that carry a function

`Router.match` returns an `Int` and the caller dispatches on it, which is why
three of five Mojo apps skip the router and hand-write `if path == …`.
Route-to-function **is** reachable on Mojo 1.0 — verified by spike, not
assumed. The spelling is `thin`: a closure trait (`def (X) raises -> Y`) is
an `AnyTrait`, refused as a `List` element and refused outright as a struct
field, but `def (X) thin raises -> Y` is a concrete type that lists and
struct fields both take, including generically —
`List[def (mut Self.T, ...) thin raises -> HTTPResponse]` inside a
`struct RouteTable[T]` dispatches and mutates `T` correctly.

What stopped it is a type cycle, not the language. Every Mojo app in this
tree keeps its state in the handler and the handler owns the router, so
`RouteTable[NotesHandler]` as a field of `NotesHandler` is infinitely
recursive. The fix is to split app state into a type the handler owns
alongside the table — a real design, and a real rewrite of the showcase app.
Building the table before an app wants it would add an API with zero call
sites, which is the condition `auth.mojo` and `response_cache.mojo` are
already in. Build it with the first app that asks; the spelling above is the
part that was unknown.

## Milestones: beta and 1.0

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


## Planned

Rows in [SPEC.md](SPEC.md) marked `planned` name a heading here, and the
checker fails if one does not resolve. So this section is the whole list of
things that page promises: adding a `planned` row means writing down what it
means here first.

### A conformance-suite tier

The server is pinned by hand-written probes against the RFC text -- `smoke-ws`
speaks RFC 6455 from stdlib sockets, `test_parsing.mojo` covers the smuggling
shapes directly -- and by no external suite on any cadence. A parser fuzzer
over the request decoder is the cheap half of this tier: the decoder is
already a pure function over bytes with its own unit suite, so the harness is
small (G13).

**Autobahn|Testsuite was RUN, on 2026-08-30, before deciding to wire it.**
The handoff asked for that deliberately: `fe26113` is the commit before
v0.15.1's fix, a build with a known, fully characterised RFC 6455 §5.5.1
violation, so the suite could be asked whether it catches a bug we already
had. **It does not.** Same pure-echo ASGI app, same client, two builds:

| build | section 7 (close handling), 37 cases |
|---|---|
| `fe26113` pre-fix, known violation | 24 OK, 3 informational, 10 FAILED |
| `f2d098b` post-fix, the shipped fix | 24 OK, 3 informational, 10 FAILED |

Identical case for case: 7.5.1, 7.9.1-7.9.9. The reason is structural, and it
is the useful part of the result: **Autobahn's fuzzing client always
initiates the close itself.** The bug was on the APP-initiated path -- the
server sends Close first and must then wait to receive one -- and no
conformance client can make a server's application close first. That is a
region of RFC 6455 an external suite cannot reach, which is a better argument
for `ws_probe.py`'s close-order phase (64 concurrent app-initiated closes)
than the one written when it was built.

So the earlier claim here -- that "the browsers and `websockets` all publish
517/517, so the bar is unambiguous and the result is comparable" -- was wrong
twice over, and is withdrawn. The comparison is not like for like (6 of the
failures below are a documented cap, not a defect), and a green suite would
not have meant what it was being cited to mean.

It is still worth having, for what it DID find — and one of the two causes
below has since been fixed on the strength of it. **Measured before the fix**,
outside the performance section, it scored **230 of 247**:

| section | cases | OK | non-strict | informational | FAILED |
|---|---|---|---|---|---|
| 1, framing | 16 | 10 | 0 | 0 | 6 |
| 2-5, pings, opcodes, fragmentation | 48 | 41 | 7 | 0 | 0 |
| 6, UTF-8 handling | 145 | 141 | 4 | 0 | 0 |
| 7, close handling | 37 | 24 | 0 | 3 | 10 |
| 10, auto-fragmentation | 1 | 0 | 0 | 0 | 1 |

Sections 12 and 13 are excluded (no `permessage-deflate`, I14). Section 9 is
performance and was sampled rather than run: 9.1.\*/9.2.\* failed 12 of 12,
for the same reason as section 1 below. All 17 failures reduce to two causes:

- **Close codes were echoed, not validated** (10 cases: 7.5.1, 7.9.1-7.9.9).
  A Close carrying 0, 999, 1004, 1005, 1006, 1016, 1100, 2000 or 2999 came
  back with that same code, where RFC 6455 §7.4.1 wants the connection failed
  with 1002 and 7.5.1 wants 1007 for a reason that is not valid UTF-8. The
  contradiction is sharpest at 1006: "abnormal closure" describes the ABSENCE
  of a close frame, so a close frame carrying it cannot be honest, and the
  server answered it with its own 1006. **Fixed** —
  `close_code_is_valid_from_peer` in `websocket.mojo` validates the code and
  the reason's UTF-8 before the echo, and I16 is `verified` on unit tests
  either side of the line (a refusal that refuses everything fails
  `test_legal_close_codes_are_still_echoed`). **Section 7 went 24 OK / 3
  informational / 10 FAILED to 34 / 3 / 0**, with sections 1-6 unmoved.
  Note what this was NOT: text frames validated UTF-8 correctly all along,
  which is what section 6's 145 clean cases say and what I5 already claimed.
- **The 64 KB outbox cap** (7 cases: 1.1.6-1.1.8, 1.2.6-1.2.8, 10.1.1, plus
  all of section 9). `MAX_PENDING_BYTES` bounds one frame as well as the
  queue, so a message at or above 64 KB ends the connection instead of being
  echoed. Deliberate and documented; recorded as I17 so the failures are not
  re-diagnosed as a bug each time the suite is run.

With I16 fixed the score outside the performance section is **240 of 247**,
and **every remaining failure is I17's cap** — which makes the next run of
this suite unusually cheap to read: anything that is not a >=64 KB payload is
new.

**Where it should live, if wired: pre-release, not `Tests`.** It needs Docker
and roughly ten minutes, CI is already ~25 minutes, and its unique value --
close-code validation -- is a defect that will be fixed once rather than a
regression that recurs. `docs/RELEASING.md` beside `stress-asgi` is the fit.
One practical finding for whoever does it: running every section in ONE pass
wedged at case 6.21.6 and never recovered, while the same server ran all 145
of section 6 cleanly when section 6 was run alone. Section 1's >=64 KB cases
end their connections, and the next case lands on the recycled slot; a
single-pass run therefore understates the server, and the harness has to
drive the sections separately.

**Wired, 2026-09-01** (SPEC I13): `poe autobahn` runs
`scripts/autobahn_runner.py` -- sections driven separately as above, 9/12/13
excluded, the image pinned to `25.10.1` (digest-identical to the one the
baseline was measured with, which is what lets the per-section case counts
be asserted exactly). The server is the runner's own pure-echo ASGI app,
because `asgi_bare`'s `/ws` prefix-echoes text for its probe's benefit and
Autobahn's byte-identity cases would score that as failures. The comparison
runs both directions -- a failure outside I17's seven is new and red, and
one of the seven *passing* is red too, the cap having moved out from under
the sheet -- and the comparator's `--selftest` runs before anything is
believed. The wired run reproduced the baseline exactly (226 OK, 11
non-strict, 3 informational, I17's 7 FAILED), and reverting I16's
close-code validation was caught as nine named new failures (7.9.1-7.9.9)
on the first section-7 run.

PortSwigger's desync scanner and h2spec are NOT this tier, and no longer
promise to be: they were one `planned` row (B8) citing this heading, which
contradicted the refusal two sections above it on the same page. They are now
two refusals of their own -- **B8** for h2spec, which needs HTTP/2 (A18, and
C7 refuses downstream of it), and **B9** for the desync scanner, which probes a
proxy/server PAIR for disagreement about framing and so has nothing to compare
against a server with no proxy in front of it. The smuggling rows stay
unit-tested (B1-B7), and fuzzing the decoder itself is the second half of this
tier (G13).

### Structured CI results

**The CI half shipped 2026-08-30.** `scripts/emit.py` appends each measurement
to `$M0_RESULTS` as one JSON line; the smoke job renders them into the run
summary with a headroom column and uploads `ci-results-<os>`. Five sites are
instrumented: the WSGI and ASGI RSS guards, the pool's fast-request latency in
both modes, and sendfile's RSS delta. The recorder never fails and is a no-op
without `$M0_RESULTS`, and `check_ci_measurements_are_collected` refuses the
four ways the wiring can lapse silently.

It paid for itself on the first run. `sendfile.rss_growth_kb` measures **48 KB
against a 16384 KB limit** -- a guard roughly 340x looser than the thing it
guards, which would pass a regression that buffered 8 MB. That is the blind
spot SPEC.md names in the abstract ("a gate runs, not that it is correct"),
now with a number on it. Deliberately NOT tightened yet: one sample from one
machine is not a basis for moving a CI threshold, and gathering the runs first
is the entire reason for recording them.

**The serving side landed too** (SPEC F5): `/__metrics` now renders a
request-latency histogram beside the counters — six log-spaced `le` bounds
(100µs to 1s, then +Inf), integer-only and O(1) on the loop thread, sampled
in `_after_send` from the same clock the access log reads. Per-loop like
every other metric; the scraper aggregates. The serve smoke's metrics phase
checks coherence (bounds, cumulative monotonicity, `+Inf` == `_count`, a
count covering its own requests) through `scripts/histogram_check.py`, whose
selftest runs in the same phase so its "OK" cannot mean "checks nothing".

### Traceability: stable ids, then declared coverage

[SPEC.md](SPEC.md) is a requirements traceability matrix -- the standard
artifact in safety-critical software, whose defining property is that it traces
BOTH ways: every capability to its evidence, and every piece of evidence back
to a capability. That second direction is the half most homegrown versions omit
and the half this one has, over two closed sets (the CI steps in `test.yml`,
the flags `cli.mojo` accepts).

It also has a structural weakness, and the 2026-08-30 audit is the evidence.
The sheet asserts things ABOUT tests, from outside them. The established
tools -- shtracer, TRLC, and every RTM that survives contact with a real
codebase -- put the tag IN the test and generate the matrix. Every defect that
audit found is a symptom of the direction:

- six rows cited a gate that asserted something else, which cannot happen when
  the assertion declares its own coverage;
- two sabotages broke because they quoted a row that was legitimately
  re-pointed, because rows are keyed by prose;
- "the checker cannot read a test's meaning", stated on the page as a limit, is
  not a law -- it is a consequence of authoring the claim away from the
  assertion.

#### Phase 1 -- stable ids (done 2026-08-30)

Every row carries a permanent id, `<section letter><number>`, in its own
column. Ids are assigned once, never renumbered, and never reused: a deleted
row's id is retired rather than recycled, so an id in an old commit, an issue
or a conversation still means what it meant. Prose becomes freely editable,
which it should be -- and the sabotages key on ids, which is what stops them
breaking every time a capability is reworded.

Enforced: an id on every row, unique, and its letter matching its section. NOT
enforced, and left as a convention with the reason written down: never reusing
a retired id, which cannot be checked without carrying a ledger that is itself
a second source of truth to keep in step.

#### Phase 2 -- declared coverage, not asserted citation

Invert the direction. A gate declares what it covers, next to the assertion,
written by the person who knows what was asserted:

- Mojo tests: a `covers: A7` line in the test's docstring, greppable.
- Smokes: `emit.py --covers A7`, which means coverage is RECORDED BY A REAL RUN
  rather than claimed statically. The emitter for this already exists.

`check_spec_sheet` then collapses from nine rules about the shape of a citation
to two: every `verified` row was covered by a real run, and every declared id
exists. The class of defect the audit spent its time on stops being possible.

**Done, 2026-09-01** (SPEC F12), in one migration rather than incrementally
-- it was fully scriptable, which the incremental plan had underestimated:
every one of the 119 `verified (every PR)` rows now declares its coverage in
its gate (a `covers:` docstring line in the cited test for the 39 unit-cited
rows, a `scripts/emit.py --covers` call in what the cited step runs for the
80 step-cited ones -- also recorded by the real run through `$M0_RESULTS`,
where the summary renders them as a tally). Two new rules run in
`check_spec_sheet`: every declared id names a row that exists, and every
gated row's declaration AGREES with its citation -- declared only elsewhere
is the mis-citation the audit spent its time on, now a red build. Four new
sabotages revert them.

One refinement to what this section predicted, recorded rather than papered
over: the nine citation-shape rules did NOT collapse to two. They guard
properties a declaration cannot -- the cadence is real, the cited step
carries no `if:`, and the two closed sets (every smoke step cited by some
row, every CLI flag named by one) hold in both directions -- so they stay,
with the declaration rules beside them. Weekly and pre-release rows keep
declared-static citations, their runs being absent from PR CI; the checker
exempts exactly those cadences and the rollup says so.

The argument this section made for the change held: a test added next month
that quietly drifts from its row is now a disagreement between a declaration
and a citation, which is a named failure rather than nothing.

### Proven once, unloaded: an inventory of the gates with that shape

The v0.15.1 bug came from a shape rather than an oversight: **proven once, by
a smoke, and stressed not at all.** The measure of how little that guarantees
is exact. Reverting the `websocket.send` credit gate was caught on round 1 by
the extended `stress-asgi`, and passed the old chunked-only gate 30 of 30
under 8 hogs.

This is the inventory that shape asked for, taken 2026-08-30 by reading each
gate rather than by assuming from its name. Two of the three candidates turn
out to be better covered than the handoff that proposed them said; the third
is a real gap, and it is not the one that looked biggest.

**A verdict of "this one does not need it, because X" is a result.** It is
recorded here so it is not re-proposed.

#### `--realtime` holds on a pool thread — was a real gap; now gated and MEASURED

**No gate anywhere takes more than one hold at a time.** `smoke-django-realtime`
opens two concurrent SSE subscribers; `smoke-django-realtime-ws` opens three
concurrent sockets, and its pool phase runs the whole probe behind two 1.5 s
views. But `realtime_probe.py` handshakes SEQUENTIALLY — every `handshake()`
completes before the next begins — so with four pool threads configured, the
number of holds in flight at once is one.

What contention would exercise, and the reason it is worth doing: a hold taken
on a pool thread travels to the loop as a reserved `h`/`H` frame on **one
`SOCK_DGRAM` bus channel per loop**, and N pool threads are N producers on it.
That is the same "one shared socket pair, N producers" shape whose per-stream
windows over-committed the ASGI chunk channel — twelve concurrent Django
`FileResponse`s were enough there — and the bus channel has no budget at all.
Its documented policy is fire-and-forget: a publish that meets a full buffer is
DROPPED on EAGAIN (`broadcast.mojo`), and a hold frame that meets one becomes a
503 (`handler.mojo`, deliberately, "a client holding a dead stream").

Both are documented, deliberate degradations, so the honest claim was never
"there is a race" — it was that **the threshold was unmeasured**. Nobody knew
how many concurrent holds, or how heavy a publish rate beside them, turns a
working server into one issuing 503s and silently losing broadcasts.

**Measured 2026-08-31, and the threshold is not reachable.**
`apps/django_realtime/hold_contention_probe.py` releases N subscribers off a
barrier so their hold frames reach the loop inside one window, waits for the
subscriptions to settle, then publishes into all of them:

| concurrent holds | pool threads | holds granted | publishes delivered |
|---|---|---|---|
| 4, 16, 32, 64, 128 | 4 | all | 100% |
| 64, 256, 512 | 16 | all | 100% |
| 512, fifty messages back to back | 16 | all | 100% (25 600 of 25 600) |

Nothing was refused and nothing was lost at any width up to 512 — against a
default `max_connections` of 1024, so this is half the server's whole capacity
— nor with the publish gap removed entirely, which is what pressures each
connection's outbox rather than the bus channel. Raising the pool from 4 to 16
producers changed nothing either. **The feared degradation does not occur
within the range this server can serve**, and that is the deliverable the
inventory asked for.

**The negative is only worth as much as the instrument**, so the probe's
self-test is part of the gate rather than a convenience: a bad token must read
as zero holds granted, and a publish to a channel nobody holds must read as
zero delivery. Both steer the real path rather than a special one, and
`smoke-realtime-holds` runs the self-test BEFORE the measurement — a clean
result from a counter that cannot register a failure would be worse than no
gate, because it would be believed. The gate itself asserts a floor (32 holds,
100% delivery) well inside what was measured, so it is a regression check
rather than a capacity test that reddens on a loaded runner. Row I18.

**One thing the probe cannot see, so the gate asserts it separately.** 32
concurrent holds pass IDENTICALLY with `--blocking-threads 0` — measured —
because taking them on the loop works too. The width alone therefore says
nothing about which path was entered, and a row claiming "from a pool" on that
evidence would be claiming a path the gate stops entering the moment the flag
is dropped. So `smoke-realtime-holds` greps the server's own BANNER for
`blocking-threads=4`, which is `stress-asgi`'s rule (assert the mode from the
banner, never from the variable) applied to a configuration instead of a loop
mode. Sabotage-verified by removing the flag: the smoke fails naming the
banner, not the holds.

#### Mounts — adequately covered; do not re-propose

`smoke-hybrid` is not the single-shot gate its name suggests. Phase 3 streams
**256 KB concurrently from two ASGI mounts on two executors** — four credit
windows each, which is exactly the misrouted-ack failure the shared chunk
channel can produce — and then disconnects a client mid-stream on one mount and
requires the other to survive. Phase 3t repeats the whole thing under
`--threads`. Beside it, `hybrid_isolation.py` runs **four concurrent blocking
sync-mount views** and takes twelve samples against the async mount, reporting
its headroom on every run.

That is contention, on the seam that matters (per-lane credit, per-lane ack
routing), at a width chosen for the failure. No gap found.

#### The handler pool — adequately covered; do not re-propose

`smoke-pool` runs **six concurrent blocking requests** and requires them to
spread across threads. `smoke-blocking-threads` puts two 1.5 s views in flight
and measures a fast request behind them, then abandons four in-flight requests
mid-job and requires every slot back. `sabotage-pool` reverts each `mojo_pool`
rule. `probe-pool` is the pre-release timing gate for the same path.

The one shape none of them has is slot RECYCLING under contention, which is
what produced the executor's slot-ownership bug — but that bug's home was the
shim's per-slot state, which pool threads do not have, and `stress-asgi`
already lands a WebSocket handshake on a slot a streamed connection just
released. Not worth a second gate on this argument alone.

#### What the inventory cost, and what it bought

Item 1 of the same handoff — gating the idle timeout — found a live bug in
under an hour: the WebSocket close linger re-armed on every loop pass, so the
bound v0.15.1 relies on did not exist and a peer that never answered Close held
its slot for the life of the process. That is the case FOR this kind of work.
This inventory is the case for doing it by reading first: two of the three
candidates named in the same handoff did not need it, and building for them
would have produced gates that could not fail.

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

### Inbound WebSocket flow control — shipped 2026-08-31

The outbound direction was credit-gated (`websocket.send` awaits its window)
and the inbound direction had no backpressure of any kind. Once the
executor's submit channel filled, `WSGIHandler.ws_message` discarded each
further message with a log line the client can never see -- the same "a full
channel means skip this frame" mistake the chunk channel's own rule forbids,
in the direction nobody had written a rule for. **2932 of 3000 lost** at
4 KB.

**The two directions were coupled, which is why the threshold was so low.**
The echo app awaits `send` inside its `receive` loop, so a client that stops
reading blocks that send on its OUTBOUND window -- which stops the app
calling `receive`, which stops the executor draining the channel that
INBOUND messages ride. The outbound backpressure produced the inbound loss,
and only one of the two directions was allowed to say "wait".

Both may now. The fix is the outbound design in mirror image, plus the one
piece a mirror does not give you:

- **A window, granted by the consumer.** `WS_IN_WINDOW` (64 KB) bounds the
  unacked datagram bytes the loop may have in flight toward one socket's
  `receive()` queue. The shim acks CUMULATIVELY as the application actually
  consumes -- a running total, not a delta, so an ack frame the chunk
  channel has to drop heals at the next consume instead of costing credit
  for ever. That is why this is the one frame on the seam that may be
  dropped without an abort.
- **Read suspension, which is what makes it real backpressure.** A handler
  that cannot forward returns False from the new `ws_message_take` hook, and
  the loop takes the slot off the read set. The socket's receive buffer
  fills, TCP advertises a zero window, and the CLIENT stops sending. Nothing
  else in the design propagates past the process boundary.
- **A parked queue, bounded by ONE `recv`.** Parsing is all-or-nothing: a
  single 4 KB read can yield many complete messages and the window can run
  out partway through. The remainder is parked and replayed in order. It can
  never grow past what one `recv_staging` produced, because no further bytes
  are read -- bounded by the receive buffer, not by the client's send rate,
  which is the property that makes it safe.

`take_ws_resumes` names the drained slots once per pass and the loop re-arms
their reads. Both new trait methods carry defaults (`ws_message_take`
forwards to `ws_message`), so every handler that is not the WSGI one is
untouched.

**A pool-held socket gets the same treatment for free**: its channel refusal
parks and suspends identically. It has no window, because pool threads send
no consumption acks -- the per-pass retry in `take_ws_resumes` is what
drains it.

**The gate's shape was chosen by measuring the wrong one first**, and this
is the part worth remembering. A client that reads CONCURRENTLY loses
nothing on the BROKEN build -- 3000 of 3000 echoed, zero drop lines -- so
the obvious "send a lot and count the echoes" test passes on the defect it
was written for. `scripts/ws_inbound_loss_probe.py` therefore sends WITHOUT
reading until the socket stops taking bytes (phase A), then reads and sends
together and requires every message (phase B). Phase A stalls on BOTH builds
-- socket buffers fill either way, 380 KB broken against 360 KB fixed -- so
it is a precondition, not the assertion. Phase B is the discriminator:

| build | phase A stall | phase B echoed | lost | drop lines |
|---|---|---|---|---|
| pre-fix | 380 KB / 93 msgs | 68 | **2932** | 2932 |
| fixed | 360 KB / 88 msgs | **3000** | **0** | 0 |

Verified by running the gate against a rebuilt pre-fix binary: exit 1,
naming the dropped messages. Holds at 8000 x 4 KB, 3000 x 16 KB and
20 000 x 64 B -- the last being the parked queue's hardest case, many
complete messages out of one read.

**And it uncovered an older bug, which is the part worth reading.** The first
Linux CI run of the new gate stalled -- 3 of 3000 echoed, and NO drops, so the
backpressure was working and the socket simply never resumed. Two fixes were
needed and only the first was mine:

- `slot_read_armed` is an INVARIANT every re-arm site in the loop consults,
  and suspending without updating it left the flag lying. On kqueue read and
  write are independent filters so nothing noticed; on epoll they share ONE
  registration, so the outbox drain's `add_write_oneshot` MODs the read
  interest away and nothing restores it. Setting the flag is not enough
  either: `_after_send`'s WebSocket branch re-arms on exactly `not armed`, so
  the socket's own echo would undo the suspension it had just asked for --
  and with it the parked queue's bound. Hence `WSState.inbound_suspended`: a
  DELIBERATE suspension, distinguishable from an incidental one.
- **The WebSocket read path took ONE `recv` per event and never re-armed** --
  A13's defect, in the one path nothing had ever sent a large inbound burst
  to. The body path has carried the fix and the reason for a long time ("a
  body larger than the staging buffer leaves bytes pending that will never
  raise another edge on their own"); this path was simply never asked.
  kqueue's level trigger hides it entirely. On epoll the edge is spent, and
  the stall needs the client to STOP SENDING -- which is precisely what
  inbound backpressure is for, so the feature exposed the bug that had been
  waiting for it. Re-armed only on a FULL staging buffer, so an ordinary
  small-message socket pays no extra syscall. Row I19.

Verified by building Linux/aarch64 in a container and running the gate there:
3 of 3000 before, 3000 of 3000 after, same tree. The first hypothesis (the
invariant alone) was wrong and the container said so -- macOS passed every
version of this, including the two broken ones.

**One consequence worth stating plainly.** A client that sends without ever
reading, against an app that echoes, now BLOCKS instead of losing data. That
is the correct end of a deadlock every echo server has -- uvicorn included
-- and the old behaviour only avoided it by discarding the client's
messages.

### The drain does not read a request body in flight — resolved

Found by the soak driver's uploads population on color-separation
(2026-09-02): with 9.7 MB multipart uploads in flight, every SIGTERM drain
took exactly its 5 s budget, and the bisection put it on uploads alone.
Measured directly with `scripts/drain_upload_probe.py`: a 10 MB POST with
5 MB delivered when SIGTERM lands and the rest sent a second later was
never read — `_run_shutdown`'s loop dispatched `EVFILT_WRITE` only, by
design ("nothing new is read during the drain") — so the client was reset
at 5.03 s and the process exited at 5.09 s. Half of `docker stop`'s
patience spent on a request that would have completed in milliseconds;
gunicorn's graceful timeout keeps reading. The request-side twin of the
response-side defect `drain_inflight_probe.py` pins: that one held the
drain for a connection already *answered*, this one for a request not yet
*received*. The same write-only loop had a second consequence nothing had
measured: a response too large for one `send` was cut at its first write
readiness, because that branch closed the slot instead of sending the
rest.

**The fix is to stop re-implementing the loop.** The drain now runs
ordinary `_run_pass` passes for its budget: mid-request bodies are read,
responses are written whole, pool completions and bus frames are
serviced, buffered submits flushed. The listener is already closed so a
pass accepts nothing, and `_close_between_requests` after every pass is
what bounds it: a connection with no request in progress is closed, so
only bytes the client had already sent are ever served. The shutdown pipe
is deregistered first — its byte is never read, so a registered pipe
stays readable and every pass would break at it. Gated by SPEC D9
(`smoke-drain-upload`, both shapes, two-sided); sabotaged by restoring the
old loop, which the probe reports as the reset at 5.03 s and the exit at
5.09 s. Measured after: answered whole and exited at 1.08 s, the extra
second being the probe's own delay before sending the rest of the body.

## Known issues

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


## Recently resolved

### A request body still arriving at SIGTERM held the drain to its deadline — resolved

The drain loop read nothing new, so a half-received upload was neither
completed nor closed until the 5 s budget expired: the client was reset
and the process exited at 5.09 s. Found by the soak driver's uploads
population on color-separation, reproduced bare by
`scripts/drain_upload_probe.py`, fixed by running ordinary loop passes
during the drain (see "The drain does not read a request body in flight"
above). Gated by D9, every PR, in both execution shapes.

### The WebSocket close path RSTing instead of FINning — resolved v0.15.1

Listed as a suspected race for two sightings, both on macOS CI and never
locally. It was not a flake: RFC 6455 §5.5.1 requires the endpoint that
sends Close to WAIT to receive one, and the loop closed as soon as its own
Close frame drained, so the peer's reply reached a socket that was already
gone and TCP answered with an RST. Diagnosed and fixed in v0.15.1, and
v0.16.0 fixed the BOUND on the wait that fix depends on. Gated by L15 (64
concurrent app-initiated closes, every one a clean FIN) and L16 (the wait is
bounded, so a peer that never replies cannot hold its slot).

It stayed on this list for a release after it was fixed, because nothing
retired it and nothing could. That is why `scripts/milestones.py` now
requires every entry here to declare what would close it.

- ~~**A WebSocket close races the peer's close reply, and loses as an RST**~~
  — **fixed 2026-08-30.** When an application sent `websocket.close(1000)`
  the loop wrote its Close frame and closed the TCP connection in the same
  pass, before a reply could exist. The peer's Close then arrived at a socket
  that was gone, TCP answered with an RST, and that reset flushed the peer's
  receive queue — taking our FIN with it and, for a client far enough behind,
  the Close frame itself. Against the `websockets` library at 200 concurrent
  closes: 167 clean `code=1000`, **33 `ConnectionClosedError: no close frame
  received or sent`** — the application's own close destroyed in transit.

  Two hypotheses were tested and one was wrong, which is why both are
  written down. The first was that the reply was sitting unread at close
  time and that closing with unread data queued is what turns a FIN into an
  RST; draining the receive buffer immediately before `close` changed
  nothing (98 of 100 still reset). What settled it was the client that sends
  **nothing** back: 100 of 100 clean FINs. The server was never losing a
  race to read — it was closing before there was anything to read, and the
  reset was provoked by the reply hitting a closed socket.

  The fix is RFC 6455 §5.5.1's order: having sent Close, wait to RECEIVE
  one, then close. `WSState.closing` marks the wait; the three stream-ended
  close sites and `_after_send`'s `should_close` branch set a 2 s deadline
  in `slot_idle_deadline` and leave the read armed, so the peer's Close
  closes the slot and the existing idle sweep reaps a peer that never
  replies. It needs no new state: a WebSocket's idle deadline is otherwise
  0, so a non-zero one IS the linger. With idle timeouts switched off there
  is nothing to bound the wait, so that configuration keeps the old
  behaviour rather than leaking a slot.

  Measured after: 0 of 20, 50, 100 and 200 concurrent closes reset, and the
  `websockets` library sees 200 of 200 clean `code=1000`. `ws_probe.py`
  gained a close-order phase — 64 concurrent app-initiated closes, every one
  required to end in a clean FIN — which is `smoke-asgi` on every PR and
  `stress-asgi` every round; against the unfixed server it reports 2 of 64.
  Concurrency is load-bearing in that guard: one close at a time passes on
  the broken server, which is how this hid through two investigations.

- ~~**The WebSocket path is not stressed**~~ — **closed 2026-08-30.**
  `poe stress-asgi` drove `chunked_keepalive.py` and nothing else, so the
  pre-release timing gate never touched the WebSocket seam — and the CI flake
  of 2026-08-30 (macOS, `M0_INVERTED=1`, a connection reset in
  `apps/asgi_bare/ws_probe.py`) landed in exactly the combination that left
  uncovered: the WS path, the loop inversion and sustained contention
  together. A flake by every check available — first in twelve runs, a rerun
  of the identical commit green on both platforms — but the precedent cuts the
  wrong way, since the slot-ownership race is on record as having passed CI
  while live and this gate exists because of it.

  **The gate now covers it.** Each round runs `chunked_keepalive.py` and then
  `ws_probe.py`, so the WebSocket handshake lands on the slot the streamed
  connection just released — the recycled-slot shape the streamed half already
  had, with a held 101 on the successor instead of another stream — and the
  whole loop runs twice, on the pump and under `M0_INVERTED=1`. Three details
  are load-bearing rather than incidental:

  - **Two modes, two ports.** `SO_REUSEPORT` means a restart that overlaps its
    predecessor binds anyway and silently splits the connections, and the
    inverted server's drain deadline is 5 s, so the overlap is not
    hypothetical.
  - **The inverted mode asserts the banner**, rather than trusting that
    exporting the variable did anything. The inversion is gated on a topology
    (unmounted, pool-free, no `--realtime`); if that gate ever moves, the
    variable is ignored in silence and the mode proves the pump a second time
    while reporting itself as the inverted one.
  - **The server runs at `smoke-asgi`'s 300 ms heartbeat**, not the default,
    because the run that failed had it: a WS slot gets a protocol PING on that
    cadence, so the flood phase's two-second stall has a timer-driven second
    writer queueing into the same outbox the application is filling.

  **Sabotaged both ways, and the coverage gap is measured rather than
  argued.** Reverting the `websocket.send` credit gate (`_ws_spend` returning
  before it waits) fails the new gate on round 1 with an exact count — 15 of
  400 frames, 61,440 of 1,638,400 bytes — and **passed the old chunked-only
  gate 30 of 30 under 8 hogs**. Making `M0_INVERTED` never match is caught by
  the banner assert before a round runs.

  **The flake reproduced — on this change's own CI run — and it is a real
  server bug.** It did NOT reproduce locally: three runs on macOS arm64 (10
  cores, CPython 3.13), 150 rounds per mode, 300 WebSocket probe runs, all
  green. What cracked it was the probe's new phase stamp, which named the
  phase on the first CI failure after it existed: **the app-initiated close
  handshake**, not the flood phase everyone had been looking at. See
  "A WebSocket close races the peer's close reply" above, now resolved.

  The local negative is still worth its numbers, because it says what this
  gate can and cannot do. The gate DOES drive the failing path — every round
  runs the close handshake — so this is not a coverage gap a further widening
  would close. It is the machine: ten fast cores where CI's macOS runner is
  three shared virtualized ones, and the server wins the race every time here.
  `scripts/epoll_inverted_check.sh` picks the new coverage up for free on
  Linux the next time it runs.

  **The probe's own diagnosis was thinner than the failure deserved**, and was
  improved on the way past. The CI traceback named a line in `recv_exact`, a
  helper four phases share, so the log said which call reset and not which
  phase was being proven; and `ConnectionResetError` is not `EOFError`, so the
  flood phase's careful "N of 400 frames arrived" diagnosis is skipped
  entirely when the close arrives as an RST rather than a FIN — which is what
  the kernel sends for a socket closed with bytes still queued. `ws_probe.py`
  now stamps a phase and reports an `OSError` as a finding carrying it. This
  changes nothing about what passes; it changes what the next failure says,
  and `poe stress-asgi` drives this probe hundreds of times a run, where a
  round number alone would not be enough.

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
