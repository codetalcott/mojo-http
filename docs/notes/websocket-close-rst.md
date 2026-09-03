# The WebSocket close path RSTing instead of FINning — resolved v0.15.1

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

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
  [NOTICE](../../NOTICE) too.

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
  and clean numbers in [WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md).
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
  now pins every claim [NOTICE](../../NOTICE) makes: request smuggling (CL+TE,
  duplicate `Content-Length`, `chunked` not last), the `Host` requirement, the
  header-count cap, request-target normalization, and chunked integer overflow.
  Each guard was verified load-bearing by disabling it and confirming the
  matching test fails — the overflow guard turned out to crash the process when
  removed, and an earlier version of that test passed either way.
- **m0-sqlite reliability pass** — busy timeouts, non-raising `reset`/`finalize`,
  real SQLite error text, single-statement `prepare`. See
  [SQLITE_PERFORMANCE.md](../SQLITE_PERFORMANCE.md) for the measured optimization
  work that accompanied it.
