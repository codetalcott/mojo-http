# Roadmap

## v0.1 (current)

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

## v0.2 (planned)

### Examples

`apps/hello` is the only example. Add:

- `apps/notes_api/` — what the framework adds over the bare server: `Router`
  with `:id`, content negotiation, ETag + `304`, `problem+json`, CORS, config.
- `apps/datastar_todo/` — the flagship: live multi-tab sync over SSE.

Add a `build-apps` CI gate at the same time. Nothing currently compiles `apps/`,
and the examples are this repo's front door.

### WSGI landed (spike)

`m0-wsgi` runs a real Django request/response cycle, asserted end to end by
`poe smoke-django`. The boundary crosses once per request, with `start_response`
implemented in an embedded Python shim rather than as a Mojo callable, and
bodies moved as raw addresses because Mojo 1.0's `std.python` binds no `bytes`
API at all.

What it is not yet: concurrent. `HTTPService.func` runs the view on the event
loop, so this serves one request at a time per process. The next step is
prefork — which needs the `WorkerSupervisor` respawn bug below fixed first, and
each child constructing its own `WSGIApp` *after* `fork()`, since forking a live
CPython is not safe. No benchmark has been run; a throughput claim against
gunicorn would be premature until the concurrency story exists.

## Known issues

- `packages/m0-core/ffi/` is dead code. It sits beside `src/` rather than inside
  it, so `mojo precompile src` never compiles it, and its `from ..hashing import`
  cannot resolve from that location. Either move it under `src/` with a build
  task emitting a C-ABI shared object, or delete it.
- Content negotiation does not implement `Accept-Encoding`, `Accept-Language`,
  or `Vary`.
- `WorkerSupervisor` is never called from any app, and a respawned child returns
  `True` up through `_supervise` rather than to `fork_all`'s caller — so a
  respawned worker never reaches the server startup path. Blocks prefork, and
  therefore blocks concurrent WSGI.
- Every package's sources live in a directory named `src`, so `from src.x import`
  in a test binds to whichever `-I` root is searched first. `test-wsgi` puts its
  own package first for this reason; the other test tasks survive only because
  their module names happen not to collide.
