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

The `build-apps` gate this section once called for now exists: `poe build-apps`
compiles every example to a temp directory, and CI runs it before the smoke
tests. The examples themselves are still outstanding.

### WSGI landed (spike)

`m0-wsgi` runs a real Django request/response cycle, asserted end to end by
`poe smoke-django`. The boundary crosses once per request, with `start_response`
implemented in an embedded Python shim rather than as a Mojo callable, and
bodies moved as raw addresses because Mojo 1.0's `std.python` binds no `bytes`
API at all.

Concurrency is prefork, and it exists now: `M0_WORKERS=N` makes
`apps/django_wsgi/server.mojo` fork N workers through `WorkerSupervisor`
*before* the first Python call — forking a live CPython is not safe, and Mojo
initializes the interpreter lazily, so each worker makes its own first Python
call by constructing its own `WSGIApp` after returning from `fork_all()`.
Workers accept from one listener bound before the fork (per-worker
`SO_REUSEPORT` binds do not distribute on macOS, and hash blindly on Linux)
and set `wsgi.multiprocess=True`.
`poe smoke-django` runs both shapes: single-worker for the bridge assertions,
then `M0_WORKERS=2` asserting that two overlapping slow requests complete in
~1x the view latency on two distinct worker pids.

Benchmarked against gunicorn (same Django project, same worker counts, wrk):
~1.4x gunicorn's throughput at 1–2 workers and ~1.7x at 4, with a keep-alive
latency caveat that matters — methodology and numbers in
[WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md).

## Known issues

- The C-ABI exports have no shared-object build task, so nothing yet produces
  the `.so`/`.dylib` that Bun's `dlopen` or N-API would load. `mojo build
  --emit shared-lib` cannot compile `src/ffi/exports.mojo` directly — its
  relative `from ..hashing import` is not resolvable from a top-level entry
  file — so this needs either an absolute-import shim or a restructure. The
  code itself is live and tested (`test_ffi_exports.mojo`); only the packaging
  step is missing.
- Content negotiation does not implement `Accept-Encoding`, `Accept-Language`,
  or `Vary`.
- The blocking `listen_and_serve` loop is unfair to concurrent keep-alive
  connections: it serves one accepted connection's requests exclusively until
  the idle timeout or `max_keepalive_requests` closes it, so other persistent
  connections queue for tens to hundreds of milliseconds (measured: p50
  ~245 µs but p99 ~140 ms under 16 keep-alive connections at 2 workers — see
  [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md)). `Connection: close` traffic is
  unaffected. The non-blocking event loop multiplexes and should not have
  this; moving the WSGI app onto it has not been tried.
- Every package's sources live in a directory named `src`, so `from src.x import`
  in a test binds to whichever `-I` root is searched first. `test-wsgi` puts its
  own package first for this reason; the other test tasks survive only because
  their module names happen not to collide. The m0-http tests added since
  (`test_config`, `test_log`, `test_lifecycle`) rely on that same luck.

## Recently resolved

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
