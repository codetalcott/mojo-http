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
  `EPOLLEXCLUSIVE` contingency the design held in reserve is not needed. **Stage B, recorded:** per-
  request balancing and slow-view isolation need an acceptor loop feeding a
  Python thread pool with deferred responses — `HTTPResponse.deferred` (the
  `sse_streaming` precedent), the request parked in
  `ConnectionProvision.request` (a field that exists and is dead), a
  slot-generation array so a late completion for a recycled slot is dropped,
  `PROCESSING` surviving a loop pass (the idle/header sweeps must skip it),
  a `SOCK_DGRAM` socketpair as the work queue (kernel-locked, message
  boundaries) and another as the completion channel registered like
  `bus_read_fd`, workers blocking in `recv` *detached* and attaching per job,
  completion re-entering the existing `RESPONDING` write path exactly as the
  outbox drain does. ~8 touchpoints in `event_loop.mojo`. Stage A's
  benchmark row exists ([WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md), 3.14.7t):
  threads at throughput parity with prefork at ~60% of its RSS, ~3.5x
  gunicorn on the same interpreter.

  **The `wrk` run that was to gate Stage B has happened, and the answer is
  no-go.** Three rounds, keep-alive only, on 3.14.7t: keep-alive p99 is
  1.6–2.9 ms across both modes and both sizes, with one excursion in
  seventeen valid rows (`--workers 4`, 52 ms p99) that did not recur and
  that appeared in *prefork* — the mode that already has N accept queues,
  which is the opposite of what connection pinning predicts. Threads and
  prefork are indistinguishable on the tail and at throughput parity under
  a second tool.

  The reason is sharper than "the tail did not appear". Stage B is for
  per-request balancing **and slow-view isolation**, and a hello-route
  benchmark cannot exercise the second at all — there is never a slow
  request for a fast one to be stuck behind. So the gate is now a
  **mixed-workload run**: a deliberately slow view alongside fast ones on
  the same loop, measuring whether fast requests suffer behind slow ones.
  Until that exists and shows they do, the ~8 touchpoints stay unwritten.

  The same table's more actionable finding: **Granian 2.8.1 is 1.4–2.0x
  faster than either mode** on the same interpreter, serving a
  byte-identical response, with a tighter p99. Same process model as
  `--threads`, so the headroom is in the per-request path rather than the
  concurrency architecture — better-evidenced than Stage B, and cheaper.
- **Static files front the Django rows.** `StaticFiles` grew a
  `Cache-Control` policy (emitted on 200/206/304 — the validator response
  carries freshness too, per RFC 9110) and `apps/django_realtime` mounts it
  ahead of the bridge: asset requests are answered in Mojo and never enter
  Python, which is the WhiteNoise/nginx replacement claim,
  smoke-asserted (type, ETag revalidation, freshness, traversal 404). The
  zero-copy `sendfile` step remains recorded — it needs event-loop support
  for fd-backed response bodies, a deliberate change, not a tweak.
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
- **Recorded follow-ups, not yet scoped:** ASGI/WSGI auto-detection in
  the entry point;
  PyPI-wheel distribution (the binary links libpython and carries the Mojo
  runtime); a published benchmark suite against gunicorn/uvicorn/Granian.

## Known issues

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
  cross through those operations — requests are serialized into a persistent
  Python-side bytearray instead (see `bridge.mojo`). Any new bridge code must
  hold the same line, and the workaround can be retired if a future toolchain
  fixes the leak (re-test with `smoke-django`'s RSS guard).
- The blocking `listen_and_serve` loop serves one accepted keep-alive
  connection exclusively until timeout or the `max_keepalive_requests` cap
  (measured p99 ~140 ms under 16 persistent connections). No in-repo app
  uses it anymore — `apps/hello` moved to the non-blocking loop like
  everything else — but it remains in the fork for the simplest embeddings.

## Recently resolved

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
  No Range, no listings; every hit reads and hashes — compose with
  `ResponseCache` if a profile ever asks. The notes example serves
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
