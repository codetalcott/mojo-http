# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

`mojo-http` — an HTTP/1.1 server and web framework for Mojo. Extracted from a
private monorepo; see [PROVENANCE.md](PROVENANCE.md).

```
m0-core     (zero deps)   hashing, JSON escape, JSON parse
└── m0-http               router, negotiation, ETag, cache, SSE, auth, CORS, health
    └── lightbug_http     the forked HTTP server (lives inside m0-http)
m0-datastar               Datastar wire format (zero deps) + server glue (m0-http)
m0-wsgi                   WSGI/ASGI gateway — embeds CPython, layers on m0-http
m0-sqlite   (zero deps)   SQLite bindings — a SIBLING, never nested
```

**Zero upward imports.** `m0-core` depends on nothing. `m0-http` uses exactly
three functions from `m0-core` (`wyhash64`, `format_hash64`,
`escape_json_string`). `m0-datastar` splits deliberately: `consts.mojo` and
`sse.mojo` import nothing outside themselves so the wire format is usable
without the framework — do not add an `m0_http` import to either — while
`stream.mojo` and `signals.mojo` are the server glue and may.

`m0-wsgi` is the **only** package that embeds CPython. Keep it that way: a
Python import in `m0-http` or `m0-core` would put libpython on the link line of
every build in the repo. Everything touching the interpreter lives in
`src/bridge.mojo`; the rest of the package works in Mojo types. The package
hosts **both protocols**: the shim detects WSGI vs ASGI at `set_app`
(`--protocol` forces it), and an ASGI app runs buffered on a persistent
per-bridge asyncio loop — the protocol dispatch lives entirely inside the
shim, so the per-request Mojo path is identical for both and the leak rules
below apply unchanged. Under the executor (the ASGI default) streaming
responses stream for real — see the executor bullet below for the three
load-bearing rules; only the buffered escape hatch still refuses an
infinite stream with its 10s watchdog (docs/WSGI_VS_ASGI.md §8), and that
refusal is not to be "fixed" by lengthening the grace.
Zero-config: with no topology flag or `M0_*` topology variable, `m0serve`
defaults to `--blocking-threads min(cores,8)` — an explicitly-set variable,
at any value, disables that (`AppConfig`'s `*_set` fields carry the
distinction; `resolve_blocking_threads` in `src/cli.mojo` is the one place
the default is decided). Two rules the
Mojo 1.0 interop imposes and that the code depends on:

- **`std.python` binds no `bytes` API and no latin-1 decoder — but the
  unbound C API is still reachable.** `Python().cpython()` has no
  `PyBytes_*` of any kind and no `PyUnicode_DecodeLatin1`, and
  `external_call` cannot reach them either: **libpython is not on the link
  line**, which is precisely why `CPython` is a struct of `dlopen`'d function
  pointers rather than a header. The way in is the stdlib's own mechanism —
  `ExternalFunction[name, type].load(cpy.lib.borrow())`, the same call it
  uses to populate its bindings. `bridge.mojo`'s `_PyBytes_AsString` and
  `_PyBytes_FromStringAndSize` are the worked examples — both request and
  response bodies cross that way; resolve once at construction, never per
  request.

  Prefer a bound function when one exists, and prefer a *checked* C function
  to a macro: `PyBytes_AsString` returns NULL on a non-`bytes` where
  `PyBytes_AS_STRING` would read wrong offsets (and macros are not symbols).
  Where a function genuinely cannot be reached, `environ.mojo` shows the
  other tactic: latin-1 text is encoded as UTF-8 in Mojo so
  `PyUnicode_DecodeUTF8` produces the same `str`. Do not "simplify" any body
  path to a `String` round trip; Mojo strings are UTF-8 and it corrupts every
  byte above 0x7F.
- **`PythonObject` interop leaks a reference per call argument and per
  `__setitem__` value** (Mojo 1.0, measured; zero-argument calls, call
  results, `len()`, and `String(py=...)` are clean). Never add a
  per-request `PythonObject` call argument or dict/attr assignment to the
  bridge — it reintroduces an unbounded per-request leak that shows up as
  growing GC pauses, and `smoke-django`'s RSS guard will fail. Startup-only
  calls (`set_app`) are the deliberate, bounded exception.

  **The way around it is the raw C API, not avoidance.** `Python().cpython()`
  reaches `PyDict_New`, `PyDict_SetItem`, `PyUnicode_DecodeUTF8`,
  `PyTuple_New`/`SetItem` and `PyObject_CallObject`, which refcount
  explicitly and so are not the leaking path. The bridge builds each
  request's whole environ that way and hands it over as a stolen tuple
  slot — which is what let the environ stop being rebuilt in Python and
  took the bridge from 14.9 µs/request to 3.5. Two rules come with it:
  `PyDict_SetItem` does **not** steal, so every string built for it must be
  `Py_DecRef`'d after the store, and `PyTuple_SetItem` **does**, so the
  value must not be. Get either backwards and it is a leak or a
  double-free; `smoke-django`'s RSS guard is the instrument, and it must
  stay at 0 KB over 10k requests.
- **Mojo never acquires the GIL on its own** except when destroying a
  `PythonObject`; every other `std.python` call assumes the calling thread is
  *attached* (holds a Python thread state). There are two execution modes,
  mutually exclusive (`threads_conflict`), and each keeps that true its own
  way — plus a handler pool that composes with either:
  - **Prefork (`M0_WORKERS`, the default).** One thread per process, attached
    since `Py_Initialize` ran on it. `WorkerSupervisor` is wired in
    (`packages/m0-wsgi/m0serve.mojo`) and the rule it obeys is load-bearing:
    **fork before the first Python call, never after.** Mojo initializes the
    interpreter lazily, so each worker's own `WSGIApp` construction after
    `fork_all()` returns is that first call — keep it there.
  - **Threaded (`M0_THREADS`, free-threaded CPython only; `m0_wsgi.threaded`).**
    N event loops on N pthreads, one interpreter. The main thread initializes
    the interpreter and imports the app BEFORE spawning, then
    `PyEval_SaveThread`s and touches no Python until after `pthread_join`.
    Every serving thread `PyGILState_Ensure`s once for its lifetime, builds
    and destroys its handler (so its `WSGIApp` and bridge) inside that
    region, and **detaches around every blocking wait** — `DetachingBackend`
    wraps `backend.wait()`; a thread that blocks while attached stalls every
    other thread's stop-the-world. Never add a blocking call to the loop or
    a handler without that wrapper. A GIL-enabled interpreter refuses to
    start (exit 78) — never warns-and-runs. Per-thread, never shared across
    threads: `WSGIApp`/`PyBridge`, `SSERegistry`/`WSHub`, `ProvisionPool`,
    an m0-sqlite `Connection` (opened `NOMUTEX`). Shared mutable Python
    objects are the measured 0.7x cliff (`docs/WSGI_VS_ASGI.md` §5); keep
    per-request state thread-local. `print`/`log_access` from N threads can
    interleave — `x-thread` is on every response for that reason.
  - **The asyncio executor (`m0_wsgi.asgi_executor`; the ASGI default).**
    One Python thread per event loop runs the bridge's persistent asyncio
    loop, fed through the same `OffloadPool` the handler pool speaks — the
    loop parks and submits, `add_reader` on the submit fd turns slots into
    tasks, completions answer via `put_response`/`complete`. Rules:
    attach once for the thread's life like a pool thread, but park
    ATTACHED inside `run_until_complete` (CPython's selector releases the
    GIL there — that is the executor's detach); the Mojo loop still needs
    `DetachingBackend`; every Python object stays owned by the executor
    thread; the loop's fallback handler is built with `lifespan=False` so
    exactly one lifespan runs per loop; `spawn_asgi` crosses the scope
    C-API-only (PyList/PyTuple steal discipline — same rules as the
    environ build). Streaming responses ride a private per-loop chunk
    channel into the loop handler's `SSERegistry` under reserved channel
    names (leading 0x01 byte), and three rules there are load-bearing: a
    stream's **begin frame goes out before its head completion** (one
    FIFO channel is what makes a recycled slot safe -- never reorder
    them); chunks are **credit-gated** (64 KB window, acked by the loop's
    drains -- never emit without credit, and never switch the chunk or
    ack sends to a drop-on-EAGAIN policy); and comment heartbeats stay
    suppressed on ASGI streams (a chunk-split SSE event with a comment
    inside is corrupt). WebSocket scopes use the same seam — the held
    101 is only released behind its begin frame, outbound frames ride
    the chunk channel, inbound ones are tagged submit-channel datagrams
    — and a handshake the app never answers must resolve as a 403, never
    a leaked slot. The buffered escape hatch keeps its send()-side
    watchdog — do not "fix" it by lengthening the
    grace (docs/WSGI_VS_ASGI.md §8).
  - **The handler pool (`M0_BLOCKING_THREADS`, `--blocking-threads N`;
    `lightbug_http.offload` + `m0_wsgi.blocking_pool`).** Orthogonal to the
    two above, not a third alternative: it puts N handler threads behind
    *each* event loop, so `--workers W` is W processes of N and `--threads T`
    is T loops of N. The loop stops calling `HTTPService.func` and becomes an
    acceptor; that is what stops one slow view holding the keep-alive
    connections pinned to its loop (measured: p99 1.6 ms → ~194 ms without
    it, in **both** modes). Rules, all load-bearing:
    - **One pool per loop.** A job names a slot, and a slot indexes one loop's
      `ProvisionPool`. A pool shared between loops would answer the wrong
      connection.
    - **The loop must detach while it waits.** `DetachingBackend` is not
      optional here even under prefork: a loop attached inside
      `kevent`/`epoll_wait` keeps every pool thread out, which under a
      GIL-enabled interpreter is a deadlock rather than a slowdown.
    - **Pool threads detach around the blocking `recv` and attach per job**,
      and build and destroy their handler inside an outer attached region.
      Same discipline as a serving thread, same reason.
    - **A slot with a job in flight is untouchable and unrecyclable.** The
      idle and header sweeps skip it, the read path refuses it (clearing
      `slot_read_armed` so a pipelined request is not stranded by the edge it
      consumed), and a client that disconnects detaches the fd but leaves the
      provision borrowed — `_close_slot(..., release_provision=False)` — until
      the completion releases it.
    - **Refused with `--realtime`.** The streaming hooks run on the loop's
      handler; `func` would run against a pool thread's own registries.
    - Not refused on a GIL-enabled interpreter, unlike `--threads`: a waiting
      view releases the GIL, so the isolation is real there. That is the
      difference, and it is why the two refusals differ.

`m0-sqlite` imports nothing else here and links the system libsqlite3 — no link
flags on macOS, present-at-link on Linux. `Connection` and `Statement` are
`Movable` but not `Copyable` on purpose: copying would duplicate a handle and
the second destructor would double-free. Do not add `Copyable`.

Three m0-sqlite invariants that look like bugs and are not:

- **`reset` and `finalize` discard their result code.** SQLite returns the
  *previous* evaluation's error there, so raising on it makes recovery after a
  failed `step` impossible and turns cleanup into a second exception.
- **Every close path uses `close_v2`.** That is what lets a `Statement` outlive
  the `Connection` that made it, which Mojo's destroy-at-last-use makes routine.
  `sqlite3_close` would break it silently.
- **Error text is only trusted when `sqlite3_errcode` corroborates the code.**
  A closed connection answers `SQLITE_MISUSE` to everything, and reporting that
  would replace a true constraint error with a false one.

Performance findings, with numbers, are in
[docs/SQLITE_PERFORMANCE.md](docs/SQLITE_PERFORMANCE.md) — batch writes in a
transaction (46x), `mmap_size` (40% on large random reads), `json_each` for
variable-length `IN` lists, and why `carray()` is unavailable and would not take
a `List[Struct]` anyway.

There is one cycle, and it is intentional: `m0-http/src/{cors,signal,auth,
multiworker}.mojo` import from `lightbug_http`, and `lightbug_http/event_loop.mojo`
imports `m0_http.log`. Both sides live inside `packages/m0-http/`, so the cycle
never crosses a package boundary.

`m0-core/ffi_exports.mojo` (package root, deliberately outside `src/`) holds
the C-ABI exports for foreign callers (Bun `dlopen`, N-API, `ctypes`); `poe
build-ffi` emits `libm0core.so`/`.dylib` from it, and `poe smoke-ffi` proves
the artifact through `ctypes` in CI. It must stay the shared-lib entry file —
relative imports don't compile there, and `@export` symbols are only emitted
from the entry module (its docstring records the dead ends). `@export` cannot
be applied to a parametric function, so the entry points name a concrete
pointer origin, and Mojo-side callers erase the origin explicitly — see
`test_ffi_exports.mojo`.

`m0-wsgi/m0serve.mojo` is the second package-root entry file, for the same
reasons: it is the `m0serve` CLI binary (`poe build-serve` → `bin/m0serve`),
`precompile src` must never see it, and it imports `m0_wsgi` through the
`.mojoc` rather than `src.*`. All four WSGI example apps — `django_realtime`
included, since `--realtime` moved its hold machinery into `WSGIHandler` —
are Python-only projects it serves; there is no `server.mojo` in them to
edit.

## The lightbug fork

`packages/m0-http/lightbug_http/` is a **hard fork**, not a vendored snapshot.
Upstream was archived 2026-05-12; there is nothing to rebase onto and nowhere to
send patches. Changes there are ordinary changes to this repo.

- Keep it isolated from framework code. Do not refactor it to match framework style.
- Record anything materially new in [NOTICE](NOTICE) — that file is a licensing
  record, not documentation.
- Do not "fix" the `m0_http.log` back-edge by inverting it.

## Commands

```bash
uv run poe                  # list every task
uv run poe build-all        # each package -> .mojoc, in dependency order
uv run poe test-all         # builds first, then runs all tests
uv run poe smoke-hello      # start hello, assert /health, stop
uv run poe smoke-counter    # assert an SSE broadcast reaches a live client
uv run poe smoke-shutdown   # SIGTERM drains; signalling the supervisor reaps workers
uv run poe smoke-blocking-threads  # a slow view must not stall what is behind it
uv run poe test-sqlite      # needs libsqlite3 on the system
uv run poe canary           # full suite against the Mojo nightly, then restore

# The warning ratchet. mojo has no per-warning suppression, so the residual
# warnings that cannot be fixed on the pinned toolchain are pinned to a count
# instead. CI tees build-all + test-all into one log and checks it; both are
# needed, because only test-all compiles test/ sources.
uv run poe check-warnings compile.log
uv run poe check-warnings compile.log --update   # after genuinely fixing some
```

One test file, without going through poe — the `-I` chain mirrors the package's
dependencies. `mojo` lives in `.venv`, so every invocation needs `uv run`
(or an activated venv):

```bash
uv run mojo run -I packages/m0-http -I packages/m0-core \
  packages/m0-http/test/test_router.mojo

# m0-sqlite is the exception: build, then run. Never `mojo run` — see below.
uv run mojo build -I packages/m0-sqlite -Xlinker -lsqlite3 \
  packages/m0-sqlite/test/test_sqlite.mojo -o /tmp/t && /tmp/t
```

Tests are `std.testing`: `test_*` functions in a `test_*.mojo`, dispatched by
`TestSuite.discover_tests[__functions_in_module()]().run()` in `main()`. Adding
a test means adding a function — there is no registration list to update.

The 69 warnings the baseline records are not a backlog. 53 are doc-string
capitalisation lint on summaries that open with a real identifier (`fetch_add
on...`, `wants_html`, `q=0`, `text/*`) — capitalising them would corrupt the
name each documents. The other 16 warn about APIs Mojo 1.0.0 does not ship:
`alloc` without a `Layout` suggests an `unsafe_alloc` that does not exist, and
`ABI="C"` suggests an `abi("C")` that is not a declaration in any position.
Both are recorded in NOTICE and in `m0-core/ffi_exports.mojo`'s docstring. Do
not spend time on them; do keep the count from growing.

A `.mojoc` is locked to the exact compiler version that produced it. After any
toolchain change run `build-all`, or you get:

```
Mojo precompiled file is incompatible with the current version of the Mojo compiler
```

The VS Code LSP resolves cross-package imports through these same files, so
stale artifacts appear as unresolved imports in the editor. If *every* prelude
type (`String`, `List`, …) reports "unable to locate module 'std'", the LSP is
running a different Mojo than `uv.lock` pins — that is an editor problem, not a
code problem; check with the compiler before believing it.

**`uv run poe canary` does the whole nightly probe in one command** — swap,
`build-all` + `test-all`, then restore the pin and rebuild the `.mojoc`
artifacts, with the restore in an `EXIT` trap so it happens even when the
canary fails. It exits 0 if the nightly is clean, 1 if the nightly broke
something, and 2 if the environment could not be put back. Prefer it to
driving the steps by hand, because doing that has two traps:

**On a nightly, every task needs `--no-sync`.** `poe nightly-try` swaps the
venv's toolchain without touching `uv.lock`; a plain `uv run` re-syncs the venv
and silently puts you back on stable, so `uv run poe test-all` after
`nightly-try` reports a green *stable* run and the canary means nothing. Use
`uv run --no-sync poe <task>` until `poe nightly-restore`.

CI lives in `.github/workflows/test.yml` and is named `Tests`. Both
`dependabot-automerge.yml` and `label-automerge.yml` trigger on that exact
name, so renaming the workflow silently disables both. `test.yml` ignores
`*.md`, `docs/**` and `.claude/**` — a doc-only change runs nothing, and
therefore never reaches the auto-merge workflows either.

**`automerge` is a standing order.** A PR carrying that label merges itself as
soon as `Tests` passes for its current head commit. The label is the gate and
it is deliberately not a branch namespace: applying it needs write access, so
a session can open work autonomously but cannot land it. Add the label when
the work is meant to go in unattended; leave it off and the PR waits.

Never reach for `gh pr merge --auto` here. GitHub's auto-merge only waits when
a branch protection rule declares required status checks, and `main` is
unprotected — so `--auto` merges immediately, before CI runs, while looking
like it gated on CI.

## Imports resolve two ways

Inside a package's own `test/`, imports are `src.*` and compile the package's
source directly, so the package under test needs no rebuild. What makes that
binding safe is `test/__init__.mojo`: with it, a test file is part of its
package and its own `src` wins regardless of `-I` order; without it, the first
`-I` root's `src` wins instead — every package's `test_resolution.mojo` fails
loudly if that ever erodes. Keep the package under test first in `-I` lists
anyway; it is the convention the tasks follow.

Everywhere else — across packages, and from `apps/` — imports are `m0_*` and
resolve through the `.mojoc`. A change to `m0-core` is therefore invisible to
`m0-http` until `build-core` runs.

A `.mojoc` does not bundle its dependencies, so a consumer passes every `-I` in
the chain, and apps add `-I apps/` for their own sibling modules
(`datastar_counter.page`). The non-obvious case: `apps/hello/server.mojo`
imports only `lightbug_http` yet still needs `-I packages/m0-core`, because the
back-edge pulls it in — `event_loop.mojo` → `m0_http.log` →
`m0_core.json_escape`.

## The handler contract

`HTTPService` (`lightbug_http/service.mojo`) has nine methods and no
defaults: `func`, `before_request`, `after_response`, four SSE hooks —
`sse_drain_slot`, `sse_is_streaming`, `sse_slot_disconnected`,
`sse_peer_frame` (frames arriving over the cross-worker `BroadcastBus`; empty
in non-streaming handlers) — `tick`, the application timer hook (fires
every `app_tick_ms` when configured; runs ON the event loop thread, so keep
it quick), and `ws_message`, which receives complete WebSocket messages
(fragments assembled, control frames already answered by the loop). The
`sse_*` names are historical: the outbox drain and the disconnect hook serve
WebSocket slots identically — a WS handler queues `encode_ws_frame(...)`
bytes and returns them from `sse_drain_slot`. A handler that streams
nothing and schedules nothing returns the empty defaults. Adding a method
to the trait breaks every handler in the repo at once: every app under
`apps/`, plus the five demo services inside `service.mojo` itself, plus the
example in README.md.

**SSE and WebSockets require `listen_and_serve_nonblocking`,** not
`listen_and_serve`. Only the non-blocking event loop assigns `req.slot_id`,
drains the outbox, and parses WebSocket frames; the plain accept loop leaves
`slot_id` at `-1` and every stream open answers `409`.
Slots index the registry directly, so a stream's capacity
(`DatastarStream(1024)`) must be at least the server's max connections.
A WebSocket upgrade is signalled on the wire, not by a flag: the loop
switches a slot to frame mode when the handler's response is
`101` + `Upgrade: websocket` (what `websocket_upgrade` builds). The
heartbeat timer is shared: on the `sse_heartbeat_ms` cadence an SSE slot
gets a `: heartbeat` comment and a WS slot gets a protocol ping.

## Runtime constraints

Properties of the design, not defects to fix in passing:

- **SSE fan-out is per-process unless the app joins the `BroadcastBus`.**
  `M0_WORKERS>1` forks, and each worker gets its own subscriber registry; a
  broadcast reaches other workers' subscribers only when everything shared is
  created *before* the fork (listener, `BroadcastBus`, `SharedAtomics` id
  slot) and each worker wires `enable_bus` + `bus_read_fd` +
  `sse_peer_frame` → `deliver_peer`. `apps/datastar_counter` is the
  reference; partial wiring fails quietly (publishing without draining just
  fills peer channels). Cross-worker ordering is best-effort — the
  redelivery filter keeps the newer of two racing ids. The bus itself is
  transport-agnostic: `WSHub` (`src/ws.mojo`) rides it for WebSocket
  fan-out the same way (`apps/ws_chat` is that reference), with
  `sse_peer_frame` carrying encoded WS frames instead of SSE events.
- **Server-initiated work goes through the `tick` hook** (`M0_APP_TICK_MS`,
  0 = off). It runs ON the event loop thread — a slow tick stalls every
  connection — and handlers with slower cadences sub-schedule off `now_ms`
  (see the counter's uptime clock). Under `M0_WORKERS>1` every worker
  ticks; an app that must act once per interval designates an owner (the
  counter uses worker 0) and lets the bus carry the result. All loop
  timers (tick, SSE heartbeat) are one-shot on both backends, so the
  firing handler re-arms FIRST — on epoll the re-arm is also what clears
  the fired timerfd's readability, and skipping it is a level-triggered
  event storm.
- **Graceful shutdown is opt-in, and armed after the fork.**
  `install_shutdown_signals()` returns the fd to pass as `shutdown_read_fd`;
  its handler writes one byte to that pipe and nothing else. Dispositions and
  fds are both inherited across `fork()`, so a pre-fork install points every
  worker at the supervisor's pipe, which nothing watches — each worker arms
  itself once `fork_all()` returns, and the supervisor arms a different
  handler (`kill` each child) from inside `fork_all`, which is what makes
  `docker stop` on the supervisor alone reap the workers. **A forked worker
  must end with `exit_worker()`, never by returning from `main`**: the
  runtime's teardown calls into libdispatch, which is unusable after a fork
  without exec, and the worker dies with a SIGTRAP the supervisor reads as a
  crash. Nothing reached that path until workers learned to drain.
- **After `fork()` without `exec`, platform runtimes are off limits — including
  from application code.** The `exit_worker()` rule above is one instance; the
  general form bites WSGI apps directly. On macOS `urlopen` consults the system
  proxy through `_scproxy`, which calls into CoreFoundation, and Objective-C
  aborts the process rather than run in a forked child: under `M0_WORKERS>1` the
  worker dies with SIGKILL and the supervisor respawns it, so it reads as a
  dropped connection and a churning worker, not a crash. `M0_WORKERS=1` runs the
  identical code cleanly, which is what makes it look like a load bug. Use
  `http.client.HTTPConnection` (no proxy lookup) — `apps/wsgi_bare`'s
  `/reentrant` route is the worked example and `poe smoke-wsgi` pins it.
- **Mojo has no global `var`, but it does have `pop.global_alloc`.** A POSIX
  handler gets no user-data pointer, so `src/global_slot.mojo` reaches an
  internal MLIR op for what C spells `static`. `@no_inline` on the accessors
  is load-bearing (the op is `Pure`, so each inlined copy makes its own
  global), the slots are private to m0-http so writer and reader share one
  emission, and fork copies them rather than sharing — cross-process state is
  `SharedAtomics`, not this. If the op ever stops working nothing is
  installed and the default signal behaviour stands, because a handler over a
  dead slot would swallow SIGTERM; `shutdown_signals_active()` reports which
  happened and `test_lifecycle.mojo` asserts it.
- Configuration is env vars, all `M0_`-prefixed: `M0_HOST`, `M0_PORT`,
  `M0_BASE_URL`, `M0_API_KEY`, `M0_WORKERS`, `M0_THREADS` (mutually
  exclusive with `M0_WORKERS>1`; free-threaded CPython only),
  `M0_BLOCKING_THREADS` (handler threads per loop; composes with either of
  those, refused with `--realtime`), `M0_ACCESS_LOG`, `M0_SSE_HEARTBEAT_MS`,
  `M0_APP_TICK_MS`. `m0serve` layers flags on top (flag > env > default) and
  is strict where the env loader is lenient.

## Mojo 1.0 patterns

This project targets **Mojo 1.0** (pinned in `uv.lock`).

1. **`comptime` constants** — replaces deprecated `alias` for compile-time values
2. **No `@value` decorator** — removed in 26.3; structs auto-derive copy/move
3. **Explicit `__init__`** — memberwise init must be written explicitly
4. **`from std.` imports** — implicit stdlib imports deprecated
5. **`String.as_bytes()`** — `s[i]` indexing removed; use `s.as_bytes()[i]` or `s[byte=i]`
6. **`Writable` over `Stringable`** — always add `write_to` when migrating
7. **`Variant` for tagged unions** — `from std.utils.variant import Variant`
8. **`Optional[T]`** — requires `ImplicitlyCopyable`
9. **Parallel arrays (SoA)** — used to work around `ImplicitlyCopyable` constraints
   on `List[Struct]`. Prefer parallel `List` fields over `List[Struct]`; this is
   why `SSERegistry` and `PatchJournal` look the way they do.

## Design principles

- **Functional core / imperative shell** — pure logic in Mojo, I/O at the edges.
- **Content negotiation stays format-agnostic.** `AcceptResult` knows the four
  standard media types; everything else is a caller-supplied vendor type. Do not
  add a vendor media type to `content_negotiation.mojo` — that is exactly the
  coupling this repo was split out to remove.
- **`*/*` resolves to JSON only**, and vendor types must be named exactly. A
  plain `curl` sends `Accept: */*`; it should not receive an opaque binary.

## Mojo reference (fetch on demand)

- Changelog: https://docs.modular.com/mojo/changelog
- Ownership: https://docs.modular.com/mojo/manual/values/ownership
- Structs: https://docs.modular.com/mojo/manual/structs/
- Traits: https://docs.modular.com/mojo/manual/traits
- Collections: https://docs.modular.com/mojo/std/collections/
