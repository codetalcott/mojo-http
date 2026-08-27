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
four functions from `m0-core`: `wyhash64` and `format_hash64` in `etag.mojo`,
`escape_json_string` in `health.mojo`, `escape_json_string_into` in
`log.mojo`. `m0-datastar` splits deliberately: `consts.mojo` and
`sse.mojo` import nothing outside themselves so the wire format is usable
without the framework — do not add an `m0_http` import to either — while
`stream.mojo` and `signals.mojo` are the server glue and may.

`m0-wsgi` is the **only** package that embeds CPython. Keep it that way: a
Python import in `m0-http` or `m0-core` would put libpython on the link line of
every build in the repo. Inside the package, `src/bridge.mojo` owns the
per-request interop — the environ build, the response read, every raw C API
call — and is the file to reach for first. The other `std.python` importers
are the modules that run Python on a thread of their own (`app`,
`asgi_executor`, `blocking_pool`, `response`, `threaded`, and `m0serve.mojo`),
because attaching, building a handler and destroying it there are theirs to
do; everything else works in Mojo types, and keeping it that way is what
bounds how many places the leak rules below have to hold. The package
hosts **both protocols**: the shim detects WSGI vs ASGI at `set_app`
(`--protocol` forces it), and an ASGI app runs buffered on a persistent
per-bridge asyncio loop — the protocol dispatch lives entirely inside the
shim, so the per-request Mojo path is identical for both and the leak rules
below apply unchanged. Under the executor (the ASGI default) streaming
responses stream for real — see the executor bullet below for the three
load-bearing rules; only the buffered escape hatch still refuses an
infinite stream with its 10s watchdog (docs/WSGI_VS_ASGI.md §8), and that
refusal is not to be "fixed" by lengthening the grace.
`m0serve --mount PREFIX=SPEC` hosts **several applications in one
process**, routed by longest prefix (on segment boundaries, so `/app` never
swallows `/application`; the root mount is the empty prefix and needs no
special case). Each mount detects its own protocol and gets its own bridge
— free, because `PyBridge` already execs the shim into a fresh namespace
dict per instance. The prefix reaches both protocols through
`PyBridge.set_base` and **only** there, because they disagree about it:
WSGI gets `SCRIPT_NAME` with `PATH_INFO` trimmed to the remainder, ASGI
gets `root_path` with `path` left whole (Django's `ASGIHandler` strips it
itself). Backwards, every direct request still works and every generated
URL breaks — invisible until someone clicks something, which is why
`smoke-hybrid` compares `reverse()`/`url_for()` byte for byte.
`WSGIHandler.build` is the one place applications are constructed, so the
mounted and unmounted shapes cannot drift.

**Mounts get their own execution mode**: a submit **lane** per mount
(`OffloadPool.add_lane`, one `SOCK_DGRAM` pair each) means the loop's
`pool.submit(slot, path)` hands a job to the worker
that can run it — the asyncio executor for the ASGI mount, handler-pool
threads for the sync ones, dealt round-robin. Rules: **one `ProvisionPool`
per loop stays** (a slot indexes that loop's provisions); `lane i` is
`mount i` and both the lane and the handler's `app_for` ask the SAME
`match_path_prefix`, so they cannot disagree; each worker builds **only
its own mount** (`only_mount`), or lifespans run once per mount per
thread; and pills are sent per lane at shutdown, because a thread parked
on lane 2 is not woken by a pill sent to lane 0. **Several ASGI mounts
each get their own executor**: they share the ONE slot-addressed chunk
channel (a single `SOCK_DGRAM` queue is globally FIFO across writers, so
the recycled-slot argument survives), but each has its own drain-ack pair
(`enable_stream_ack`) with the loop routing acks by `slot_lane` — credit
sent to the wrong executor is not an error but a stream stalled forever,
which is why the smoke streams 256 KB (four credit windows) from two
executors concurrently. The reserved channel names carry the lane
(`\x01<kind>/<slot>/<lane>`) so disconnect tags and inbound WS messages
route to the owning executor by parsing the slot's own filter url.
**`--mount` composes with `--realtime`**: a WSGI mount's view takes an SSE
hold while an ASGI mount streams through its own executor, in one process
— which is what a mixed application needs, its pub/sub streams being
hold-shaped and its request-scoped generators executor-shaped. The loop
tells the two apart PER SLOT by lane (`OffloadPool.slot_is_executor`): a
held stream drained as an executor's would be chunk-framed, acked to an
executor that never issued the credit, and denied the comment heartbeat
that keeps it alive through a proxy. Sockets travel the same seam — the
`H` frame a pool thread sends carries its own LANE and the loop records
`hold_lane[slot]`, so an inbound frame is delivered back to the mount
whose view gated the upgrade and to no other. One refusal remains:
`--realtime` on a server with no WSGI mount at all, which is asking for a
hold nothing could take. **`--threads` gets the same
lanes**: `_serve_one` mirrors `_serve_offloaded` per loop, so N loops of
per-mount modes is N times the prefork shape — with two consequences to keep
straight. The executor's chunk channel takes `bus_read_fd`, so a threaded
loop's own bus channel rides `peer_bus_fd` (both drain identically; passing
neither is how `state["m0"]` silently goes missing). And `set_lane_notify`
sits on the `ThreadHandler` trait beside `set_asgi_notify`, because the
generic `_serve_one` body can only call what the trait names.

Zero-config: with no topology flag or `M0_*` topology variable, a WSGI
`m0serve` defaults to `--blocking-threads min(cores,8)`, so one slow view does
not stall every connection out of the box. It is **not** a blanket default: a
zero-config ASGI app gets NO pool, because it gets the asyncio executor
instead and its concurrency is the application's own awaits; an unmounted
`--realtime` gets none either, because the single-loop shape is what the demo
and its smokes assume. A mounted server is decided per mount, and any WSGI
mount needs a pool whatever the others are — those threads are the only
workers parked on its lane. An explicitly-set variable, at any value, disables
all of it (`ServeOptions`'s `*_set` fields carry the distinction, mirrored on
`AppConfig`; `resolve_blocking_threads` in `src/cli.mojo` is the one place the
default is decided). Three rules the Mojo 1.0 interop imposes and that the
code depends on:

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

  One header never makes the trip: `Proxy`, which CGI's mechanical mapping
  would turn into `HTTP_PROXY` — the variable outbound HTTP clients read
  to choose a proxy (httpoxy). `header_is_excluded` in `environ.mojo` drops
  it, and deliberately drops nothing else: `X-Forwarded-*` is load-bearing
  behind a real proxy, and this server never consults it itself
  (`REMOTE_ADDR` is the socket peer, `wsgi.url_scheme` is config).
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
    them); chunks are **credit-gated twice** -- 64 KB per stream AND
    `_ASGI_TOTAL_WINDOW` across every stream on the executor, because the
    chunk channel is ONE shared socket pair and N per-stream windows
    over-commit it (12 concurrent Django `FileResponse`s were enough:
    dropped datagrams, short bodies under clean terminators, a wedged
    executor). Both waits live in the shim, where waiting is an `await`.
    The Mojo side may wait too but **only detached** --
    `_send_chunk_frame` releases the thread state first, because the
    executor is attached there and would otherwise hold the GIL against
    the loop that drains the channel. No send site may treat a full
    channel as "skip this frame": a dropped chunk is a truncated body,
    and the budget alone cannot prevent one, the channel's capacity being
    a kernel property (a budget that never overflowed on macOS overflowed
    on Linux, where each datagram's whole `skb` is charged to the
    receiver). The loop's `ack_stream` may not block for the same reason, so it
    reports failure and the loop retries the owed credit
    (`OffloadLoopState.ack_owed`) -- a lost ack is a window that never
    refills. And comment heartbeats stay suppressed on ASGI streams (a
    chunk-split SSE event with a comment inside is corrupt). WebSocket scopes use the same seam — the held
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
      consumed), and a client that half-closes or vanishes mid-job keeps its
      fd attached with `peer_eof` marked — the completion answers through
      it, and a peer that is really gone surfaces as the failed send there.
      (The old behaviour detached the fd, which dropped the response the
      pool thread was about to complete — the offloaded shape of the
      half-close bug.)
    - **Composes with `--realtime` by forwarding, never by subscribing.**
      The streaming hooks run on the loop's handler, so a pool thread must
      never subscribe its own registries — nothing drains them. On a pool
      thread (`hold_notify_fd >= 0`) `WSGIHandler.func` takes the hold and
      sends it as a reserved `h` frame on THIS loop's bus channel before
      the response completes; the loop handler's `sse_peer_frame` makes the
      subscription. Safe without a same-pass guarantee because the frame
      is sent BEFORE the completion, so any pass whose event batch holds
      the completion holds the frame too, and the outbox drain runs at the
      bottom of the pass — after every event, in whatever order they came.
      An ASGI mount does bring an end-of-stream signal, but the loop reads
      it per slot and only for slots an executor produced. A WebSocket hold
      works here too: the pool thread performs the 101 (the client's key is
      in the request it holds) and sends an `H` frame, and the inbound half
      rides the submit channel back as a `TAG_WS_MESSAGE` datagram — the
      executor's shape plus the CHANNEL, because a pool thread's own
      registries are empty. `ws_message` asks the pool question FIRST: on a
      mixed mounted server `asgi_notify_fd` is set for the ASGI mount, and
      asking that one first hands every socket's message to an executor
      that never accepted the connection (docs/ROADMAP.md, "Hold on a pool
      thread").
    - **The shutdown join is bounded, and leaving is correct.** A response
      that never ends -- a `StreamingHttpResponse` served under WSGI, which
      buffers it -- holds its pool thread for the life of the process, and
      `pthread_join` has no timeout. `stop_and_join(pool, JOIN_TIMEOUT_NS)`
      waits the same 5 s the drain gets (`ThreadSet.join_within` polls each
      thread's status slot, which a body writes last), then the process
      `_exit`s naming what it abandoned. Nothing here can unwind Python on
      another thread, so waiting longer only makes SIGTERM a no-op until
      `docker stop` sends SIGKILL.
    - Not refused on a GIL-enabled interpreter, unlike `--threads`: a waiting
      view releases the GIL, so the isolation is real there.

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

There is one cycle, and it is intentional: files throughout `m0-http/src/`
import from `lightbug_http` — `cors`, `signal`, `auth` and `multiworker` among
them — and `lightbug_http/event_loop.mojo` imports `m0_http.log`. Both sides
live inside `packages/m0-http/`, so the cycle never crosses a package
boundary.

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

Holds are described here from the server side only. The **application**
contract — a sync view approving a connection with `M0-Hold`/`M0-Channel`
headers, `m0pub.publish()`, inbound WebSocket messages arriving as a plain
POST — is [QUICKSTART.md](QUICKSTART.md), which is executable: `poe
smoke-quickstart` runs its fenced blocks against the tree's own wheel, so
editing it can break CI.

`packaging/m0serve/` builds the `pip install m0serve` wheel and holds the
repo's **only** `[build-system]`: one in the root would make `uv sync` build
the repo, which needs `bin/m0serve`, which needs the venv `uv sync` is
creating. Wheels only (an sdist cannot build without the toolchain),
`dependencies` deliberately empty, platform tag measured from the binary
rather than declared. `poe smoke-wheel` proves the lot outside the tree.

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

# The doc-fact ratchet, same philosophy for prose: numbers with a machine
# source (this file's warning counts, smoke coverage in test.yml, the
# generated bench table in WSGI_PERFORMANCE.md) are CI-checked against it.
# Benchmark runs leave environment-stamped artifacts in bench/results/;
# the doc table renders from the newest one.
uv run poe check-docs         # fails naming the drifted fact
uv run poe render-bench-docs  # after committing a new bench artifact
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

The 68 warnings the baseline records are not a backlog. 52 are doc-string
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
driving the steps by hand, which has a trap:

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

**`main` is protected by a ruleset**: pull request required (0 approvals),
no force push, no deletion, no bypass actor — so branch first, or the push is
rejected with `GH013`. It declares **no required status checks, deliberately**:
by the `paths-ignore` above a doc-only PR produces no `Tests` run at all, and
a required check that never reports would leave every such PR unmergeable.

**`automerge` is a standing order.** A PR carrying that label merges itself as
soon as `Tests` passes for its current head commit. The label is the gate and
it is deliberately not a branch namespace: applying it needs write access, so
a session can open work autonomously but cannot land it. Add the label when
the work is meant to go in unattended; leave it off and the PR waits.

Never reach for `gh pr merge --auto` here. Repository auto-merge is disabled,
so it errors — and it would not gate on CI even if enabled, because
auto-merge waits only on required status checks and the ruleset declares
none. The label is the mechanism.

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
defaults: `func`, `before_request` (called on the LOOP before a request
is offloaded to a pool thread — what answers it there never becomes a
job; `WSGIHandler` answers static mounts and the health path this way),
`after_response`, four SSE hooks —
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
`slot_id` at `-1` and refuses every `sse_streaming` response and every `101`
with the server's own `409` (`gate_streaming_response`).
Slots index the registry directly, so a stream's capacity
(`DatastarStream(1024)`) must be at least the server's max connections.
A WebSocket upgrade is signalled on the wire, not by a flag: the loop
switches a slot to frame mode when the handler's response is
`101` + `Upgrade: websocket` (what `websocket_upgrade` builds). The
heartbeat timer is shared: on the `sse_heartbeat_ms` cadence an SSE slot
gets a `: heartbeat` comment and a WS slot gets a protocol ping.

## Runtime constraints

Properties of the design, not defects to fix in passing:

- **ASGI apps get cross-worker pub/sub as `scope["state"]["m0"]`.**
  `publish(channel, payload)` is m0pub's bus protocol from Python
  (one datagram per worker channel, shared-atomic ids, best-effort);
  `subscribe(channel)` is an async iterator, executor mode only — the
  loop forwards GRIP-named bus frames to each executor as tag-3 submit
  datagrams and the shim fans them out to per-connection asyncio queues
  (drop-oldest at 256). The loop grew a second bus fd (`peer_bus_fd`)
  because the executor's chunk channel consumes `bus_read_fd`; same
  codec, same drain, same `sse_peer_frame` entry. The bus + `SharedAtomics`
  + env exports are created unconditionally pre-fork — protocol
  detection is post-fork, and a single worker's own subscribers ride its
  own channel (there is deliberately no separate local-delivery path).
- **A channel name opening with `\x01` is RESERVED, and every publish
  boundary refuses one.** That namespace is how the executor and pool
  threads address a connection SLOT on the loop (`\x01<kind>/<slot>[/<lane>]`
  — queue these bytes into its stream, unsubscribe it, re-point it), and
  `WSGIHandler.sse_peer_frame` acts on it before looking at any
  subscription. An application's channel is frequently user input, and
  `%01` in a form body decodes to a real control byte, so the separation
  is enforced where an untrusted name crosses in: `channel_is_reserved`
  in `broadcast.mojo` guards `publish_to_channels`, and the shim's
  `_M0Broadcast.publish` and both copies of `m0pub.publish_frame` spell
  the same rule. Internal senders bypass those helpers — they build
  `encode_bus_frame` datagrams directly — which is what makes refusing at
  the boundary sufficient. It was previously argued that an HTTP header
  cannot carry a control byte and so a collision was impossible; that
  covers the `M0-Channel` header alone, and an unauthenticated POST
  reached another client's SSE stream through `publish()`.
- **`/ws/message` is the server's path, not the application's.** Under
  `--realtime` an inbound WebSocket frame is delivered as a synthetic
  `POST` there, carrying `M0-Channel`/`M0-Slot`/`M0-Opcode`; the view must
  be CSRF-exempt to accept it. A request for that path that arrived over
  the wire is therefore answered 404 in `serve_local`, so only the
  synthetic one (built in-process, bypassing `serve_local`) reaches the
  app. Without the reservation the CSRF exemption and the trusted headers
  were available to anyone who could POST.
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
  crash.
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
- **A response header carrying CR, LF or NUL is dropped, not transmitted.**
  `write_latin1_to` emits `name: value\r\n` with no inspection, so a value
  an application built out of user input could end the header block and
  add headers, or a body, of its own. `has_control_bytes` in
  `response.mojo` refuses the header (and empties an injected status
  reason phrase, which frameworks that validate header pairs still leave
  alone). Dropping rather than raising: the application has already run
  and its body is real.
- **An application's `Set-Cookie` goes to the wire verbatim.** A `Cookie`
  is what the server builds for itself; a line a WSGI/ASGI application
  returned IS the header, and `ResponseCookieJar.add_raw` transmits it
  unparsed — subject only to the CR/LF refusal above. Round-tripping it through `Cookie.from_set_header` +
  `build_header_value` silently dropped `expires` (the `Expiration` stub
  parses nothing), `SameSite` (lowercase-only match), everything after the
  first `=` in a value, and any unmodelled attribute — on every Django
  session and CSRF cookie of every app. Do not "normalise" that path.
- **The two backends do not have the same trigger semantics, and every read
  path must satisfy the stricter one.** `add_read` is `EV_ADD` on kqueue —
  no `EV_CLEAR`, so connection reads are LEVEL triggered and a partial drain
  is simply reported again — while epoll registers `EPOLLIN | EPOLLET`,
  where bytes already in the socket buffer when the edge fired produce no
  further edge. (`add_read_listen` differs the other way: both edge
  triggered. A write registration replaces the read registration on epoll
  and not on kqueue, which is what `slot_read_armed` tracks.)

  So each platform forgives a different mistake, and macOS will pass without
  the re-arm that Linux requires. `_handle_read_headers` performs exactly
  ONE `recv` of `recv_staging.capacity()` (4096) per call and did not re-arm
  while headers were incomplete: a request bigger than the eager read at
  accept plus one edge — 8192 bytes exactly, measured — stalled on Linux
  until the header timeout answered 408, while macOS served any size. 8 KB
  of request headers is a large cookie jar or a JWT, not an attack. The body
  path had the fix already, with a comment giving this exact reason; it just
  had not been extended to headers. `poe smoke-large-request` pins it.
- **`EV_EOF` on a read event means "no more request bytes", not "connection
  over".** A client may half-close (`shutdown(SHUT_WR)`) to say it has sent
  the whole request and still be waiting to read the answer, so the loop
  finishes the buffered request and only turns off keep-alive; a stream
  still closes, having no request left to answer, and a request that is
  still INCOMPLETE closes at once (`peer_eof`) rather than waiting out the
  header timeout. Closing there discarded a response already written, which
  the client sees as an RST and a lost answer.

  **The two backends used to disagree here, and that is why this was
  invisible in CI**: kqueue sets `EV_EOF` on the read filter for a
  half-close (data may still be pending), while epoll only reports it
  because `add_read` registers `EPOLLRDHUP` — which it originally did not,
  so on Linux a half-close was an ordinary readable event that the header
  path happened to handle. Measured before the fix, 30 requests per shape:
  macOS lost 24-30 of 30 on GET, Content-Length and chunked alike; Linux
  lost none — and conversely a half-closed INCOMPLETE request released its
  slot at once on macOS while Linux held it the full 10 s to the header
  timeout's 408. Registering `EPOLLRDHUP` was once recorded here as a
  deliberate non-change "adding an event source per connection"; that was
  wrong on its own terms — it is one more bit in the existing
  registration, delivering events only when a peer actually half-closes —
  and both platforms now behave identically. `poe smoke-half-close` pins
  the answered response AND the prompt release. One consumer of the flag
  is subtle: `_handle_read_headers` reuses `bytes_read = 0` as its
  EAGAIN-with-buffered-data sentinel, so "the peer really hit EOF" travels
  as `recv_eof`/`peer_eof`, never as a zero byte count — collapsing the
  two closed every request that was partial at an EAGAIN pass.
- **Pipelined requests are answered from the buffer, not from events**
  (RFC 9112 §9.3). The bytes of request N+1 arrive in the same read that
  completes request N and get no readiness event of their own — the edge
  that carried them is spent on epoll, and the socket buffer kqueue's
  level trigger watches no longer holds them. Three pieces make the tail
  answered rather than silently dropped, which is what every release
  through v0.12.0 did: `request_end` stamps where the answered request
  ends (at parse for Content-Length, at completion for chunked — whose
  completion paths now PRESERVE the bytes past the terminator instead of
  resizing them away); the keep-alive reset keeps the tail
  (`prepare_for_new_request(keep_pipelined=True)` — passed ONLY by the
  keep-alive resets, so accept and close still clear whole and one
  client's tail can never leak into another connection's first request);
  and `_drain_pipelined` re-parses the preserved buffer after every
  completed response, one request per iteration. It is iterative on
  purpose (recursing through the handler chain nests a call stack per
  request) and unbounded on purpose (the send buffer is the real bound:
  an iteration whose response cannot go out whole leaves the slot
  RESPONDING and exits). The blocking path has the same fix in its own
  shape — it parses preserved bytes before blocking on a socket that may
  never speak again. `poe smoke-pipelining` pins all of it.
- **A chunked request body ends where RFC 9112 says it ends**, because the
  request decoder is built with `consume_trailer = True`. Without it the
  decode completed at `0\r\n` and the terminating `\r\n` every conforming
  client sends stayed in the receive buffer — and closing a socket with
  unread data queued makes the kernel send RST rather than FIN, discarding
  the response already written. On `Connection: close` that is a response
  the client never sees: measured at up to 53% of chunked requests, and
  100% when the client paced its writes. Keep-alive hid it by never
  closing. The cost of the rule is that a client which omits the final
  CRLF now waits for it, as it would for any truncated body.
- **A chunked body is bounded twice: decoded size AND raw bytes consumed.**
  `max_request_body_size` caps what the application receives; twice that
  caps what the connection cost, read from the decoder's `_total_read`.
  Framing is consumed and dropped as it is decoded, so the first bound
  alone leaves the raw stream limited only by the ratio guard — which
  allows roughly three times the body limit in chunk-extension bytes
  before it fires. The cost is that a body whose framing outweighs its
  payload several times over (1 MB in 3-byte chunks is 3.6 MB on the wire)
  now answers 413, which is what it is.
- **A chunked request body is decoded incrementally, by ONE decoder per
  connection.** `ConnectionProvision.chunk_decoder` is fed only the bytes
  that just arrived and carries its chunk state across reads; the buffer is
  `[headers][decoded][raw tail]` and `pending_bytes` says where the next
  batch lands. Do not rebuild it per read event, which is what it used to
  do: that re-copied and re-scanned the whole body every time, making a
  chunked body O(N^2) on the loop thread (1 MB 0.15 s, 2 MB 0.61 s, 3 MB
  1.37 s, dribbled in 1 KB segments; 0.003/0.004/0.006 s after), and it
  reset `_total_overhead` so the decoder's own abuse-ratio guard could
  never trip.
- **A body the server accepts must fit its receive buffer.** The
  per-connection cap is `ServerConfig.recv_buffer_limit()` — headers plus
  body allowance, floored by `recv_buffer_max` — never the bare field,
  which was a second, lower ceiling that `--max-body` did not raise and
  that refused oversized bodies as `400` where the body cap sends `413`.
- Configuration is env vars, all `M0_`-prefixed: `M0_HOST`, `M0_PORT`,
  `M0_BASE_URL`, `M0_API_KEY`, `M0_WORKERS`, `M0_THREADS` (mutually
  exclusive with `M0_WORKERS>1`; free-threaded CPython only),
  `M0_BLOCKING_THREADS` (handler threads per loop; composes with either of
  those and with `--realtime`), `M0_ACCESS_LOG`, `M0_SSE_HEARTBEAT_MS`,
  `M0_APP_TICK_MS`. `m0serve` layers flags on top (flag > env > default) and
  is strict where the env loader is lenient. `--doctor` prints the whole
  resolved configuration as JSON and starts nothing; its contract is that
  it **exits with the code `m0serve` would exit with for the same
  arguments**, which is held true by `smoke-doctor` running both and
  comparing — the doctor mirrors `main`'s check order rather than sharing
  its control flow, so a check that moves in `main` must move in
  `_run_doctor` too.

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
