# Roadmap

## v0.1 (current)

- `m0-core` — hashing (FNV-1a, xxHash32, wyhash64), SIMD JSON escape, JSON field parser
- `m0-http` — router, content negotiation, weak ETags, response cache, SSE with
  backpressure and Last-Event-ID replay, auth, CORS, config, health, JSON-lines
  access logging, graceful shutdown, multi-worker fork supervisor
- `lightbug_http` — maintained hard fork (see [NOTICE](../NOTICE))
- `m0-datastar` — Datastar v1.0.2 SSE wire format

## v0.2 (planned)

### Wire Datastar to the server

`m0-datastar` ships the wire format but nothing drives it. It cannot currently
be connected to `SSERegistry` at all: `patch_elements()` returns a **complete**
SSE frame, while `SSERegistry.notify()` takes a payload and does its own
framing, so feeding one to the other double-frames the event. The two framers
also disagree on field order — `format_sse_event` emits `id:` before `event:`,
which is legal SSE, while the Datastar SDK spec mandates the reverse.

Needed:

- `SSERegistry.notify_frame(url, event_id, frame)` — queue a pre-formatted frame
  verbatim, still applying dedupe and `MAX_PENDING_BYTES` backpressure. Refactor
  `notify()` to delegate to it so backpressure lives in one place.
- `sse_response()` in `m0-http` — every SSE endpoint hand-rolls the same
  `HTTPResponse`, and they all omit `Cache-Control: no-cache`.
- `DatastarStream` in `m0-datastar` — owns a registry, wires the four
  `HTTPService` SSE hooks, exposes `patch_elements`/`patch_signals`/
  `execute_script`/`redirect_to`. Keep `consts.mojo` and `sse.mojo`
  dependency-free so the wire format stays standalone.
- `read_signals(req)` — Datastar's request half is entirely absent. Signals
  arrive as a `datastar` query parameter on GET and as the JSON body otherwise.

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
