# Roadmap

## v0.1 (current)

- `m0-core` — hashing (FNV-1a, xxHash32, wyhash64), SIMD JSON escape, JSON field parser
- `m0-http` — router, content negotiation, weak ETags, response cache, SSE with
  backpressure and Last-Event-ID replay, auth, CORS, config, health, JSON-lines
  access logging, graceful shutdown, multi-worker fork supervisor
- `lightbug_http` — maintained hard fork (see [NOTICE](../NOTICE))
- `m0-datastar` — Datastar v1.0.2 wire format, plus `DatastarStream` and
  `read_signals` to drive it from the server

### Datastar is wired (done)

`SSERegistry.notify_frame` queues a pre-formatted frame verbatim (with
`NO_EVENT_ID` for unnumbered frames), `sse_response()` builds the stream-opening
response with the `Cache-Control` header everyone forgets, `DatastarStream`
owns subscriptions and broadcasts, and `read_signals()` covers the request half.
`apps/datastar_counter` demonstrates multi-tab sync and is asserted in CI by
`poe smoke-counter`, which fails if a frame is ever double-framed again.

## v0.2 (planned)

### `m0-sqlite`

A SQLite storage adapter, as a **sibling** package — never nested under
`m0-http` or `m0-datastar`. Each package precompiles to its own `.mojoc` and
resolves siblings by `-I ../m0-xxx/`, so nesting would break the convention, and
coupling a database to a wire-format adapter is the kind of entanglement this
repo was split out to avoid.

Not started here. Prototype C-API bindings exist in the private monorepo
(`external_call` against libsqlite3, opaque `Int` handles because Mojo 1.0
pointers are non-null, explicit close/finalize with no `__del__` to avoid
double-free on copy). Open questions: Linux linking (`-Xlinker -lsqlite3`;
macOS resolves through the dyld shared cache with no link flags), and the
threading model against `WorkerSupervisor`'s fork model.

### Examples

`apps/hello` is the only example. Add:

- `apps/notes_api/` — what the framework adds over the bare server: `Router`
  with `:id`, content negotiation, ETag + `304`, `problem+json`, CORS, config.
- `apps/datastar_todo/` — the flagship: live multi-tab sync over SSE.

Add a `build-apps` CI gate at the same time. Nothing currently compiles `apps/`,
and the examples are this repo's front door.

## Known issues

- `packages/m0-core/ffi/` is dead code. It sits beside `src/` rather than inside
  it, so `mojo precompile src` never compiles it, and its `from ..hashing import`
  cannot resolve from that location. Either move it under `src/` with a build
  task emitting a C-ABI shared object, or delete it.
- Content negotiation does not implement `Accept-Encoding`, `Accept-Language`,
  or `Vary`.
