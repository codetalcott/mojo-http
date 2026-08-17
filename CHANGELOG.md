# Changelog

Notable changes to `mojo-http`. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/) with the standard pre-1.0 caveat: **minor
versions may break the API**.

## [Unreleased]

- `m0_http.WSHub` — the handler-side WebSocket registry: connected slots,
  per-slot outboxes, room broadcast, and cross-worker fan-out over the
  same `BroadcastBus` SSE uses (the bus is transport-agnostic;
  `sse_peer_frame` delivers encoded WebSocket frames as readily as SSE
  events). New `apps/ws_chat` demo — one room, every message reaching
  every socket across `M0_WORKERS` — and `poe smoke-chat`, which proves a
  message sent on one worker's socket arrives on the other worker's.

## [0.2.0] — 2026-08-17

- WebSockets (RFC 6455), server side: `websocket_upgrade` answers the
  opening handshake from an ordinary handler, the event loop parses frames
  (client masking enforced, fragments assembled, ping/pong and the close
  handshake answered in the loop), and complete messages arrive at the new
  `HTTPService.ws_message` hook — the ninth trait method, empty in handlers
  that never upgrade. Outbox, heartbeat (a protocol ping on the
  `M0_SSE_HEARTBEAT_MS` cadence), and disconnect plumbing are shared with
  SSE. Protocol violations answer with the RFC's close codes (1002/1009).
  New `apps/ws_echo` demo; `poe smoke-ws` proves the wire format against a
  from-scratch stdlib client. Also fixed in passing: a stale keep-alive
  idle timer could fire mid-stream and kill an SSE connection opened on a
  reused keep-alive connection.
- `m0_http.StaticFiles` — static file serving: a directory mounted under a
  URL prefix, with lexical path-traversal defense (decoded `..`/`.`/empty
  segments answer 404), extension-based content types, and ETag/`304`
  revalidation. The notes example serves `/static/` with it.
- `HTTPService.tick(now_ms)` — the application timer hook, fired every
  `M0_APP_TICK_MS` milliseconds (0 = off, the default) on the event loop's
  timer. Server-initiated pushes no longer need an inbound request; the
  counter demo gained a live uptime clock driven by it, ticking on one
  designated worker and reaching every worker's tabs over the broadcast
  bus. Breaking for handler authors: the trait gains an eighth method
  (empty `tick` in non-scheduling handlers).

## [0.1.0] — 2026-08-17

First release. Everything below is new.

### The server (`lightbug_http`, a maintained hard fork)

- HTTP/1.1 server, Linux (`epoll`) and macOS (`kqueue`), forked from
  lightbug_http v26.1.2 after upstream was archived — see [NOTICE](NOTICE)
  and [PROVENANCE.md](PROVENANCE.md).
- Non-blocking event loop: multiplexed keep-alive connections,
  header/body/idle timeouts, graceful shutdown that drains in-flight
  requests, opt-in Prometheus-format `/__metrics`.
- Request-parsing hardening: request smuggling (CL+TE, duplicate
  `Content-Length`, `chunked` not last), header-count and size caps,
  request-target normalization, chunked-size integer overflow — each guard
  pinned by a test verified to fail without it.
- SSE as a first-class server concern: per-slot outboxes with backpressure,
  `Last-Event-ID` redelivery suppression, heartbeats on idle streams
  (`M0_SSE_HEARTBEAT_MS`) that double as dead-subscriber detection.
- Cross-worker SSE fan-out: a pre-fork `BroadcastBus` (one datagram channel
  per worker) plus `SharedAtomics` event ids make `M0_WORKERS>1` and SSE
  compose; a broadcast on any worker reaches every worker's subscribers.
- `fcntl(F_SETFL)` fixed on ARM64 macOS (Darwin passes variadic arguments
  on the stack): `set_nonblocking` now actually works there, which is what
  lets two workers race on one shared listener without the loser blocking
  inside `accept()`.
- Outbound `Client`: GET/POST/any method with full response parsing —
  Content-Length with loud truncation detection, chunked, and
  close-delimited bodies.

### The framework (`m0-http`)

- Router with `:param` captures and real `405` + `Allow`.
- Content negotiation: `Accept` (quality factors, wildcards, `*/*` resolves
  to JSON), `Accept-Encoding` (codec-agnostic, RFC 9110 `identity`/`*`/q=0
  rules), `Accept-Language` (RFC 4647 matching, serve-something-over-406).
- Weak ETags (wyhash) with `304 Not Modified`, URL-keyed response cache.
- API-key auth with constant-time comparison, CORS hooks, health/readiness
  registry, JSON-lines access logging, `M0_`-prefixed env configuration.
- Multi-worker fork supervisor with crash respawn: workers accept from one
  shared pre-fork listener; a respawned worker takes over its predecessor's
  identity (index, bus channel).

### Datastar (`m0-datastar`)

- Datastar v1.0.2 wire format with zero dependencies (`consts`, `sse`), so
  frames are usable without the framework.
- `DatastarStream`: subscriptions, five broadcast shapes, `read_signals`,
  and `Last-Event-ID` replay from a bounded frame journal — including
  across restarts when the app persists the journal (the todo example
  does, in ~15 lines of SQLite).

### WSGI (`m0-wsgi`)

- Runs Django (or any WSGI app) on this server by embedding CPython. Bodies
  cross the boundary as raw addresses (Mojo 1.0 binds no `bytes` API), and
  per-request data avoids the toolchain's `PythonObject` reference leak by
  design — an RSS guard in CI keeps it that way. Prefork via `M0_WORKERS`,
  benchmarked at ~1.6–2.2x gunicorn's throughput on the same Django app.

### SQLite (`m0-sqlite`)

- Connections, statements, typed columns, transactions, bulk read-out —
  WAL by default, busy timeouts, honest error text. A sibling package that
  imports nothing else here. Measured guidance in
  [docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md).

### C ABI (`libm0core`)

- `poe build-ffi` emits `libm0core.so`/`.dylib` (FNV-1a, xxHash32,
  wyhash64, JSON escape) for Bun `dlopen`, N-API, or `ctypes`; release
  artifacts for Linux and macOS are attached to GitHub releases.

### Examples (`apps/`)

- `hello` — the whole server in one file.
- `notes_api` — the framework showcase: negotiation, ETags, problem+json,
  CORS, validation.
- `datastar_counter` — multi-tab live sync; the reference wiring for
  cross-worker fan-out and shared-memory state.
- `datastar_todo` — the flagship: HTML-over-SSE broadcasts, SQLite
  persistence, and SSE replay across restarts.
- `django_wsgi` — a real Django project served by the WSGI host.

[0.2.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.2.0
[0.1.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.1.0
