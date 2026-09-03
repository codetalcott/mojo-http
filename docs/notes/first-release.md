# v0.1.0: the first release

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

- `m0-core` — hashing (FNV-1a, xxHash32, wyhash64), SIMD JSON escape, JSON field parser
- `m0-http` — router, content negotiation, weak ETags, response cache, SSE with
  backpressure and Last-Event-ID replay, auth, CORS, config, health, JSON-lines
  access logging, graceful shutdown, multi-worker fork supervisor
- `lightbug_http` — maintained hard fork (see [NOTICE](../../NOTICE))
- `m0-datastar` — Datastar v1.0.2 wire format, plus `DatastarStream` and
  `read_signals` to drive it from the server
- `m0-wsgi` — WSGI host: embeds CPython and runs Django or any other WSGI
  application on this server. Layers on `m0-http`; the only package here that
  depends on a Python runtime.
- `m0-sqlite` — SQLite bindings: connections, statements, typed columns,
  transactions. A sibling package; imports nothing else here.


## Also in v0.1.0

Everything below started as the v0.2 plan and landed before the first
release instead.

## Examples

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

## Cross-worker SSE fan-out (done)

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

## SSE replay across restarts (done)

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

## HTTP client (done, now with keep-alive)

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
an error wrap that never compiled (see [NOTICE](../../NOTICE)). `poe
smoke-client` runs the first smoke where both ends of the wire are Mojo.

## WSGI landed (spike)

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
methodology and numbers in [WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md).

## PEP 3333 conformance (done)

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
[WSGI_CONFORMANCE.md](../WSGI_CONFORMANCE.md).
