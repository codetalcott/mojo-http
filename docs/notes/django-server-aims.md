# The Django server aims

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

Where the WSGI work is headed, and what gates each step — the full analysis
with evidence is [the design record](wsgi-vs-asgi-history.md):

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
  ([WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md), 3.14.7t): threads at
  throughput parity with prefork at ~60% of its RSS, ~3.5x gunicorn on the
  same interpreter.

  **What justified it, measured before it was built.** The `wrk` keep-alive
  run came first and could not settle it: p99 is 1.6–2.9 ms across both
  modes and both sizes, with one non-recurring excursion, in *prefork* of
  all places. But a hello route cannot produce the failure Stage B is half
  designed for, so the gate became a mixed-workload run — and that run is
  decisive ([WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md), 3.14.7t, two
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
  ([WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md)). The 78.3k could have been a
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
  [WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md) is rendered from the newest
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
  ([the design record](wsgi-vs-asgi-history.md) §8). No adapter was needed: `m0serve`
  now detects ASGI applications and serves them with real
  await-concurrency, so `m0serve main:app --app-dir apps/fasthtml_demo`
  serves FastHTML pages today, its SSE `EventStream` **streams live**
  (Phase 3a), and `app.ws` **works** (Phase 3b) — the full FastHTML
  surface, zero-config, pinned by `poe smoke-fasthtml` (skipping where
  python-fasthtml is absent).
- **The ASGI gateway's next phase** (design in the design record §8):
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
  answers at p50 1.3 ms / p99 2.8 ms (`docs/notes/wsgi-vs-asgi-history.md` §9,
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
  [WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md). Why 16 connections gain so
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
     [FFI_DISTRIBUTION.md](../FFI_DISTRIBUTION.md). The licensing analysis in
     [NOTICE](../../NOTICE) did transfer, with one addition: the wheel is the
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
     **Written** ([BENCHMARKS.md](../BENCHMARKS.md)): four generated regions
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
  [REAL_APP_VALIDATION.md](../REAL_APP_VALIDATION.md) is the record): four
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
