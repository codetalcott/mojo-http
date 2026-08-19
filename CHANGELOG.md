# Changelog

Notable changes to `mojo-http`. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/) with the standard pre-1.0 caveat: **minor
versions may break the API**.

## [Unreleased]

### Fixed

- **Request cookies never reached a WSGI application.** The request parser
  diverted `Cookie` out of the header map into `RequestCookieJar`, and the
  WSGI environ is built by walking the header map — so `HTTP_COOKIE` was
  absent and `request.COOKIES` was always empty. Every Django session,
  login, CSRF check and message silently behaved as though the visitor had
  arrived with no cookies at all. `Cookie` now stays in `headers` as well as
  feeding the jar, and several `Cookie` fields are rejoined into one
  `"; "`-separated list (RFC 6265 §5.4) rather than collapsing to the last
  one. `Set-Cookie` on a *request* is no longer folded into the request's
  own cookies — it is a response field, and treating it as one invented a
  cookie the client never sent.

  Because a parsed request now carries its cookies in both places, `encode`
  and `write_to` write the jar only when `headers` does not already carry
  the field, so re-encoding a parsed request still emits one `Cookie`.

- **`RequestCookieJar` mis-parsed values, and its lookups did not match its
  storage.** Pairs were split on every `=` rather than the first, so any
  value containing one was truncated at the first segment — base64 pads with
  `=`, so a Django `sessionid` routinely lost its tail. Splitting also ran
  over the whole field instead of per cookie, so `a=1; b=2` parsed as one
  cookie `a` holding `1; b`. A pair with no `=` was stored under the empty
  name instead of being ignored (RFC 6265 §5.2). And `__getitem__`
  lowercased the key while stores, `__contains__` and `to_header` did not,
  so a jar holding `sessionId` answered nothing to any spelling; cookie
  names are case-sensitive (RFC 6265 §4.1.1) and are now treated that way
  throughout. The jar's own `parse_cookies` was dead code — `HTTPRequest`
  hand-rolled a separate, buggier copy — and both now share one path.

- **A request body that could not be read in one `recv` never completed.**
  The event loop registered read interest only while a connection was in
  `READING_HEADERS`; once headers parsed and the state moved to
  `READING_BODY`, nothing armed `EVFILT_READ` again. Since epoll is
  edge-triggered, body bytes already waiting in the socket buffer raised no
  further edge either, so the connection stalled until `body_read_timeout`
  answered `408`. Both the transition into `READING_BODY` and each
  incomplete body read now re-register read interest.

  This hit every request whose body did not arrive inside the first 4KB
  staging read — any POST or PUT over ~4KB, and any request at all whose
  client flushed headers before the body, regardless of size. It affected
  every app in the repo, not just the WSGI host: Django form posts, file
  uploads and JSON APIs all timed out. `poe smoke-django` now posts a 256KB
  binary body and a header-flushed-first body to `/echo` and compares the
  echo byte for byte.

### Changed

- The Django example enables `django.contrib.sessions` on the signed-cookie
  backend, so it still needs no database. `poe smoke-django` asserts request
  cookies reach a view intact (including a value containing `=`), that split
  `Cookie` fields rejoin, that a cookieless request stays cookieless, and
  that a session counter advances across three requests.

## [0.3.0] — 2026-08-18

- WebSocket text messages are now validated as UTF-8 (RFC 6455 §8.1) on
  the assembled message — a multi-byte character split across fragments is
  fine; an invalid sequence closes with 1007. Binary frames still carry
  any bytes.
- `StaticFiles` honours single byte ranges (RFC 9110 §14): `bytes=a-b`,
  `bytes=a-`, and `bytes=-suffix` answer `206` + `Content-Range`;
  parseable-but-past-the-end answers `416` with `bytes */total`; multiple
  ranges and other units are ignored (full `200`, as the RFC permits).
  `Accept-Ranges: bytes` is advertised; `If-Range` deliberately never
  matches (weak ETags, strong comparison required) and falls back to the
  full representation.
- `apps/hello` (and the README example) now use the non-blocking event
  loop — the blocking accept loop remains in the fork but has no in-repo
  app consumers left.
- `Client` keep-alive: response boundaries are now computed
  (`classify_response` — Content-Length, chunked terminal chunk + trailers,
  bodiless statuses, HEAD) instead of inferred from EOF, and the connection
  is kept warm and reused across requests to the same host and port. Reuse
  rules are conservative (a `Connection: close` response, an HTTP/1.0 peer,
  a close-delimited body, or stray bytes past the boundary all retire the
  connection); a reused connection that dies before yielding a single
  response byte is retried once on a fresh dial. `keep_alive=False`
  restores one-connection-per-request. `connections_opened` reports dials;
  the smoke asserts a six-request conversation (HEAD included) rides one
  connection. Breaking: `request`/`get`/`post` now take `mut self`.
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

[0.3.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.3.0
[0.2.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.2.0
[0.1.0]: https://github.com/codetalcott/mojo-http/releases/tag/v0.1.0
