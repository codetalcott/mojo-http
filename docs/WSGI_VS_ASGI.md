# WSGI vs ASGI: the split, and how this stack steps around it

The obvious roadmap item after a conformance-tested WSGI host is an ASGI host.
This document is the case for not building one now. The short form: ASGI
answers two independent questions — *how does Python code overlap work in one
process* and *how does an application hold a connection open* — and this stack
has a better answer to each than adopting asyncio. Free-threaded CPython is
dissolving the first question; the server's native streaming already answers
the second, and the `apps/django_realtime` demo plus `poe py-canary` are the
evidence for both claims.

## 1. The split, precisely

WSGI (PEP 3333) is a synchronous call: the server invokes
`app(environ, start_response)` once per request and the application returns a
body. ASGI replaces the call with a long-lived coroutine holding `receive` and
`send` channels. Everything people adopt ASGI for falls out of one of three
consequences:

- **Concurrency.** A WSGI worker is occupied for a request's full wall-clock
  time. Under the GIL, threads don't buy CPU parallelism, so the historical
  scaling answers were processes (memory-expensive) or asyncio (which requires
  the async ecosystem). ASGI is how Django reaches asyncio.
- **Protocol surface.** WSGI has no wire for WebSockets and no way to hold a
  connection open except by pinning the worker that owns it. SSE under WSGI is
  an infinite iterable that occupies its worker forever. ASGI's channel model
  expresses both natively.
- **Django's own split.** Async views run *natively* only under ASGI. Django
  Channels — the WebSocket/consumer framework — requires ASGI, full stop.
  Note what is **not** on this list: merely *having* async views. asgiref's
  `AsyncToSync` runs an async view under WSGI by spinning an event loop per
  request — it works, and it yields zero concurrency benefit. An async
  codebase runs on m0-wsgi today; it just doesn't get anything for it.

## 2. What free-threading changes — and what it doesn't

Status as of August 2026: free-threaded CPython is an officially supported
build as of 3.14 (PEP 779, October 2025) — no longer experimental, not yet the
default. Single-threaded overhead is 5–10% (down from ~40% in the 3.13
experiment), memory baseline is +15–20%, and roughly half of the
most-downloaded packages with native wheels ship free-threaded variants.
**3.13t is a dead end**: it systematically immortalizes objects (a structural
leak), which is why Django's own CI dropped 3.13t and kept 3.14t.

Django is converging on it from the other side. The test suite passes under
free-threading once asgiref ≥ 3.12 is installed; 3.14t entered Django's CI
matrix on 2026-07-15 (ticket #36983); and Sam Gross — the author of the nogil
work — is landing Django-side contention fixes (the `Field.creation_counter`
global, bounded `lru_cache` hot paths, `HttpHeaders` set lookups). This repo's
`uv.lock` already resolves the free-threading-capable pairing: Django 6.1 +
asgiref 3.12.1.

What the GIL's removal actually changes: **the concurrency argument for async
evaporates.** Sync thread-per-request code scales across cores in one process,
with shared memory, no colored functions, and no async ecosystem tax; early
community benchmarks have a plain thread pool beating ASGI-plus-threadpool by
3–4x on CPU-bound handlers, because the async machinery is overhead there.

What it does **not** change: the protocol surface. PEP 3333 still has no wire
for WebSockets and still holds a thread hostage per open SSE stream. A
thread-per-connection SSE deployment "works" at a few hundred subscribers and
then stops working. Channels still requires ASGI. Free-threading makes the
*worker model* question go away eventually; it does nothing for the
*long-lived connection* question.

So the hypothesis "GIL unlock makes ASGI unnecessary" is half right. The other
half needs a server that holds connections without spending a Python thread on
each — which is exactly what this server is.

## 3. What this stack already has

The two halves of an answer, in separate packages:

- **A conformance-tested sync WSGI host** (`packages/m0-wsgi`): PEP 3333
  validated by `wsgiref.validate` and a framework-neutral conformance suite
  ([WSGI_CONFORMANCE.md](WSGI_CONFORMANCE.md)), one request at a time per
  process, prefork workers, and a bridge whose per-request Python traffic is
  three zero-argument calls (the leak rule; `smoke-django` pins RSS growth —
  measured at 16KB over 10k requests against a 12MB allowance).
- **Native long-lived connections** (`packages/m0-http`): the event loop owns
  SSE and WebSocket slots directly — subscriber registry, per-slot outboxes,
  heartbeat timers, disconnect cleanup, and cross-worker fan-out over the
  `BroadcastBus` (one datagram socketpair per worker, inherited across the
  fork). Ten thousand idle subscribers cost the event loop, not ten thousand
  Python threads.

What this stack is *hostile* to is a classic ASGI host, for reasons that are
design invariants rather than gaps: the handler runs synchronously on the
event loop, the process is single-threaded, Mojo never acquires the GIL, and
the fork happens before the first Python call
([WSGI_CONFORMANCE.md](WSGI_CONFORMANCE.md), "A note on beyond Django"). ASGI
wants a Python event loop coexisting with the Mojo one. That remains a
separate package to be taken on deliberately — if it is ever needed at all.

## 4. The circumvention: in-process GRIP

The pattern is borrowed from Pushpin's GRIP protocol, the design behind
django-eventstream: a synchronous backend *instructs a realtime proxy* through
response headers, and publishes through a control channel. Fastly runs this as
a paid service; Centrifugo and uWSGI's offload engine are the same shape. Here
the "proxy" is the server the app is already embedded in, so the whole
pattern collapses into one process. `apps/django_realtime` is the working
demo; `poe smoke-django-realtime` and `poe smoke-django-realtime-ws` pin it
in CI, SSE and WebSockets respectively.

**Subscribing** is an ordinary Django view answering with two headers:

```python
response = HttpResponse(": connected\n\n", content_type="text/event-stream")
response["M0-Hold"] = "stream"
response["M0-Channel"] = channel
```

The view runs auth, sessions, anything — it is a normal request to Django.
`take_hold` (`packages/m0-wsgi/src/hold.mojo`) consumes the instruction
headers from the returned response, converts it into an SSE hold (the view's
body becomes the head of the stream), and the handler subscribes the
connection's slot to the channel. Under a server that has never heard of
these headers, the same view degrades to a short buffered response — the GRIP
property. The headers are M0-prefixed because this is GRIP-shaped, not
GRIP-compatible; wire-level GRIP (and with it django-eventstream) is possible
future work.

**Publishing** never enters Mojo at all. The server exports the bus's write
fds once, pre-fork, as `M0_BUS_WRITE_FDS`; `m0pub.py` (~40 lines, stdlib
only) frames the event and `os.write`s one datagram per worker — including
the publisher's own, whose event loop drains it into `sse_peer_frame` like
any peer frame. No PythonObject crosses the bridge, so the leak rule and the
RSS guard are untouched. A synchronous Django view can broadcast to
subscribers held by every worker in one line:

```python
m0pub.publish("news", "hello", event="message")
```

`smoke-django-realtime`'s phase 2 is the headline assertion: two SSE streams
pinned on two different workers, ONE `POST /publish` handled by sync Django,
and the frame arrives on both — WebSocket-era fan-out from WSGI-era
application code.

**WebSockets** are the same seam with one asymmetry. A view gates them
identically:

```python
response = HttpResponse("", content_type="text/plain")
response["M0-Hold"] = "websocket"
response["M0-Channel"] = channel
```

but its response cannot *become* the reply. A WebSocket handshake answers
`101 Switching Protocols` with a `Sec-WebSocket-Accept` derived from the
client's key, and a WSGI response is fully buffered and re-encoded before a
byte leaves the process — Django has no way to emit either. So it does not
try. It **approves** the upgrade, having run whatever auth it likes on a
request that reached it as a perfectly ordinary `GET`, and the Mojo handler
**performs** the handshake with `websocket_upgrade(req)` against the original
request. That split is the whole trick by which a synchronous framework
gates a protocol it cannot speak.

Inbound frames make the return trip as ordinary requests. `ws_message` fires
on the event loop with a complete message (fragments assembled, pings already
answered), `ws_message_request` gives it the shape of a `POST` — payload as
the body, channel/slot/opcode as `M0-`headers — and a plain synchronous view
handles it. This is Pushpin's WebSocket-over-HTTP, and the view is
unremarkable: it reads `request.body` and may do anything a view may do.

Outbound, both transports share one bus. The datagram carries a complete SSE
frame; a WebSocket subscriber needs the payload rather than the framing, so
delivery re-encodes per slot — `sse_data_payload` recovers exactly what a
browser's `EventSource` hands to `onmessage`, and `encode_ws_frame` wraps it.
One publish, one frame on the wire, and an `EventSource` client and a
WebSocket client on the same channel see byte-identical messages.
`smoke-django-realtime-ws` asserts precisely that, with four held connections
across two workers and one `POST /publish`.

**Event ids are numbered**, which is what makes `Last-Event-ID` mean
something. Each publish fetch-adds one `Int64` on the `MAP_SHARED` page the
server allocates before forking, so ids increase globally across every
worker; the number goes both into the datagram's id field and onto the wire
as an `id:` line. The registry's delivery filter (`event_id >
last_event_ids[slot]`) then declines to re-send what a reconnecting client
already has, and the SSE hold seeds that value from the request's
`Last-Event-ID` header. Python cannot do the fetch-and-add itself — there is
no atomic read-modify-write over a raw address in the stdlib, and a racy one
would hand two workers the same id — so `m0_shared_fetch_add` is exported
from m0-core's C ABI and called through `ctypes`, which never crosses the
WSGI bridge and so leaves the leak rule and the RSS guard untouched.

Honest limits, all documented at the source: one channel per connection
(`SSERegistry` stores one filter URL per slot); **suppression, not replay** —
a client resuming at id 12 is not re-sent event 12, but events 13..N are gone
unless it was connected, because catching up needs a journal
(`DatastarStream` has one, the raw registry does not); numbering degrades to
unnumbered frames when `M0_CORE_LIB`/`M0_SHARED_ID_ADDR` are absent, which is
what happens under any plain WSGI host; a WebSocket subscriber receives an
event's *data*, not its `event:` name, since a frame has no field for one;
bus frames cap at 64KB; fan-out is best-effort under backpressure, like the
bus itself; and a slow Django view still stalls its worker's event loop — the
hold pattern removes the *connection* cost from Python, not the *request*
cost, and that applies to a `ws_message` view exactly as it does to any
other.

## 5. The free-threading path for m0-wsgi itself

`poe py-canary` probes whether this stack can run on free-threaded CPython at
all: it swaps `.venv` onto 3.14t built from the *same* `uv.lock`, runs the
whole WSGI suite — unit tests, PEP 3333 conformance, Django and Flask
end-to-end, the RSS guard at a free-threading allowance, the realtime hybrid
— and restores the pin in an EXIT trap. `scripts/py_canary_probe.mojo`
reports, from inside the embedded interpreter, what nothing else can: whether
the build is free-threaded, whether the GIL is actually off, and whether the
bridge's load-bearing mechanics (exec'd shim, persistent bytearray, raw
ctypes address crossing) survive.

**First run (2026-08-21, macOS/arm64, CPython 3.14.2t): PASSED, every
phase.** Mojo 1.0's `std.python` loads `libpython3.14t.dylib` (via
`MOJO_PYTHON_LIBRARY`; plain PATH resolution also finds it once the venv is
swapped); the embedded interpreter reports the GIL genuinely off; the shim
mechanics pass; PEP 3333 conformance, forked workers, the Django and Flask
suites, and the realtime hybrid all run green under `PYTHON_GIL=0`. The RSS
guard's measured number is the striking one: **-3664KB over 10k requests** —
under free-threading the process *shrank* while serving (the pinned 3.13
build measures +16KB on the same loop). The zero-argument-call leak
discipline holds on a free-threaded build. One sharp edge worth recording:
`PYTHON_GIL=0` aborts *any* non-free-threaded CPython at startup — including
the `mojo` driver script itself when the pinned venv is still on PATH —
which is why the canary scopes that variable strictly to the swapped
environment.

**The multi-thread question is also measured** — `poe py-thread-probe`
(`scripts/py_thread_probe.mojo`) spawns raw pthreads from Mojo, has each
attach with `PyGILState_Ensure` (after the main thread's `PyEval_SaveThread`
— on a GIL build workers would otherwise block forever against the state
`Py_Initialize` left attached), and calls into the interpreter from every
thread, checking results. Its mode matrix varies exactly one thing at a
time — which layer makes the call, and where the loop's state lives — so an
anomaly can be attributed, not guessed at. Measured 2026-08-21/22 on an M4
(4P+6E), CPython 3.14.7t, baselines warmed (the first call pays bytecode
specialization; timing it as the baseline made workers look super-linear):

| Build | Mode — where the loop's state lives | Threads | Speedup |
| --- | --- | --- | --- |
| 3.13.7 | every variant | 4 | ~1.0x — works, serialized: the GIL signature |
| 3.14.7t | interop — function locals | 2 | ~2.1x |
| 3.14.7t | interop — function locals | 4 | **3.96x** |
| 3.14.7t | interop — function locals | 8 | 3.64x — E-core dilution past the 4 P-cores |
| 3.14.7t | rawfn — `PyRun_SimpleString`, function locals | 4 | 3.52x |
| 3.14.7t | raw — `PyRun_SimpleString`, `__main__` globals | 4 | **0.81x** |
| 3.14.7t | rawnames — same dict, per-thread distinct keys | 4 | 0.71x |
| 3.14.7t | sharedobj — interop closure mutating one shared list | 4 | 0.75x |
| either | naive — no `PyGILState_Ensure` | 4 | process dies; the discipline is load-bearing |

Three conclusions, each isolated by a pair of rows:

- **Mojo 1.0's interop layer is usable from foreign threads and
  parallelizes essentially perfectly** (3.96x on 4 threads) — "Mojo never
  acquires the GIL" is the bridge's current design choice, not a toolchain
  limit. Patch level matters: the identical run on 3.14.2t measured 2.75x,
  so free-threading contention fixes landing in 3.14.x patches are worth
  ~1.2x here all by themselves.
- **The anti-scaling mechanism is confirmed to be shared-object contention,
  located to the object.** The same `PyRun_SimpleString` path scores 3.52x
  when the loop's state lives in function locals and 0.81x when it lives in
  `__main__`'s dict; giving every thread its own *keys* in that one dict
  (0.71x) does not help — it is the dict's per-object lock (a `PyMutex`,
  taken via the critical-section API), not the keys. A closure hammering one
  shared list through the interop path (0.75x) shows the same cliff in the
  shape a shared cache or counter would take. Contended `PyMutex` acquires
  park threads and ping-pong cache lines, and cross-thread object traffic
  drops off biased refcounting's fast path — which is how "serialized"
  becomes "below serial".
- **Thread-*local* state parallelizes; hot shared mutable Python objects
  anti-scale below the serial baseline.** Per-request WSGI state is
  naturally thread-local — the right shape — and the shared-object cliff is
  precisely why Django's own free-threading contention work (the
  `Field.creation_counter` class of fix) matters to real throughput.

A third probe, `poe py-thread-probe-stdpy`, closes the last toolchain
question: the pinned stdlib's `Python().cpython()` exposes `PyEval_SaveThread`
/ `PyGILState_Ensure` on the dlopen'd handle, so the attach/detach discipline
needs **no libpython on the link line** — it runs under plain `mojo run`,
prints from its pthreads, and uses a parametric `def` as the start routine,
which is exactly the shape a threaded server spawns.

**The threaded mode exists: `m0serve --threads N` / `M0_THREADS=N`.** Stage
A of the design is loop-per-thread — Granian's free-threaded shape, "workers
are threads instead of separated processes" — and it is the shape that
needed *no change to the event loop*: every per-slot structure was already a
local of `run_event_loop`, so N threads calling it get N disjoint loops, and
each thread's own handler means its own `WSGIApp`, bridge and shim namespace,
which made the bridge's per-process singletons per-thread without touching
the bridge. `m0_wsgi.threaded` is the choreography the probes specified: main
initializes and imports before spawning, then detaches; every thread attaches
once, serves, and releases; `DetachingBackend` wraps the loop's one blocking
wait (the rule above, applied); a GIL-enabled interpreter refuses to start
with exit 78. Measured on 3.14.7t: four loops serve the conformance routes,
a request arriving while one thread sleeps in a view is answered by another
in under a millisecond, `/reentrant`'s call back into the server is answered
by a second *thread* instead of a second worker, and SIGTERM drains all four
cleanly. `smoke-threads` pins the guard on every CI runner and the mode on
the weekly canary (phase D).

What Stage A does **not** buy, stated plainly: per-request balancing. A
keep-alive connection stays pinned to the loop that accepted it, exactly as
under prefork, so the keep-alive p99 tail in
[WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md) is unchanged by it — and a slow
view stops every connection its loop holds, which the mixed-workload row in
that document measures at ~120x on fast-request p99, identically under
`--threads` and `--workers`.

**Stage B is that fix and it has shipped**: `--blocking-threads N`, an
acceptor loop feeding a pool of handler threads, which is Granian's inner
`--blocking-threads` shape. It is orthogonal to Stage A rather than a
successor — one pool per loop, so it composes with prefork and with threads
alike — and it is the one piece of this that pays off on a GIL-enabled
interpreter too, because a view waiting on a database or a socket releases
the GIL. [ROADMAP.md](ROADMAP.md) carries the design and the three places
the implementation departed from it. Shared Python state above the bridge
(Django's own caches — the contention Sam Gross is patching upstream) is the
scaling risk the free-threaded rows measure. The prize Stage A already pays
out:
one process, shared memory, no per-worker RSS duplication, no bus needed for
in-process fan-out, and the entire class of fork-after-init hazards (the
macOS `_scproxy`/objc abort, `exit_worker`, fork-before-first-Python-call)
gone for anyone who opts in.

## 6. Verdict

**Do not build an ASGI host now.**

- For *concurrency*: prefork workers cover today's parallelism; free-threaded
  threads are the credible successor, and the canary keeps that path measured
  as Mojo, CPython, and Django all move. An asyncio bridge would be the most
  complex of the three options and obsolete-on-arrival if threads land.
- For *realtime*: the hold/publish pattern gives sync Django the SSE **and
  WebSocket** surface people adopt ASGI for, on infrastructure this repo
  already maintains, with no Python event loop. WebSocket holds landed as an
  increment on the same seam — one new mode value and a synthetic request —
  which is the evidence for the claim, not a new architecture.
- Revisit only if a workload genuinely requires Django Channels' consumer
  model or an async-native framework (FastAPI/Starlette) — that is an "ASGI
  host as a separate package" decision, to be taken with the canary's
  findings in hand.

*(That condition fired in August 2026 — see §8 for the revisit and what was
actually built.)*

## 7. Where this fits the larger aims

Against the project's Django-server aims (hybrid gateway, static files, DX,
benchmarks), this work slots in as follows: the **"WSGI thread pool instead
of Gunicorn-style forks"** aim has landed in both of its halves —
`--threads N` for the loops (gated on exactly what `py-canary` measures, since
a native thread pool running Python is real parallelism only without the GIL,
so the canary is that half's standing go/no-go probe) and
`--blocking-threads N` for the handlers, which needs no such gate because the
parallelism it buys is *waiting*, not computing. The **"ASGI
bridge"** aim exists mostly to serve realtime and async codebases; the
hold/publish pattern covers the realtime half without it, narrowing the
bridge to genuinely-async codebases and making it deferrable. The
**static-files** aim is covered: `m0_http.StaticFiles` (ETags, ranges,
traversal-hardened) fronts the Django rows — `apps/django_realtime` serves
its assets from the Mojo layer with a `Cache-Control` policy, and those
requests never enter Python; only the zero-copy `sendfile` optimization
remains recorded (it needs event-loop support for fd-backed bodies).
The uvicorn-style CLI exists: `m0serve MODULE[:ATTR] --host --port
--workers --app-dir --static` is one built binary serving every WSGI row.
Auto-detection of ASGI vs WSGI applications, PyPI-wheel distribution, hot
reload, and the Granian benchmark suite are follow-ups recorded in
[ROADMAP.md](ROADMAP.md)'s orbit — none of them depend on the ASGI decision
made here.

## 8. The revisit (2026-08): the hybrid gateway

§6's revisit condition fired: an async-native framework became a real
workload — FastHTML (Starlette-based ASGI) — and with it the entry point's
recorded follow-ups (auto-detection, zero-config defaults) stopped being
deferrable. The decision taken is a **phased hybrid gateway inside
`m0-wsgi`**, not the separate asyncio host §3 warned about; each phase keeps
every invariant this document defends (fork before first Python, no
per-request `PythonObject` traffic, Mojo never acquiring the GIL, thread-local
Python state).

**Phase 1 — shipped: detection + the buffered ASGI bridge.**
`m0serve` detects WSGI vs ASGI from the application object at load
(coroutine-function duck typing, uvicorn/asgiref's rule; `--protocol`
overrides), and a bare `MODULE` also discovers `MODULE.asgi:application`,
`MODULE.wsgi:application`, `MODULE:app`, `MODULE.main:app` by convention. An
ASGI app runs on a persistent per-bridge asyncio loop, one request at a time
to completion (`run_until_complete`), with the scope built in the shim from
the same C-API environ and `send()` events buffered into the same
`(status, headers, body)` tuple the WSGI path returns — zero new Mojo code on
the per-request path, and `smoke-asgi`'s RSS guard measured **356 KB over 10k
requests** on day one. Lifespan runs at startup with uvicorn's "auto"
semantics (an app that errors on the scope doesn't speak it; an explicit
`startup.failed` refuses to serve). Two honest limits, both enforced loudly
rather than silently: a streaming response (`more_body=True`) that has not
finished in 10 s is answered with an explanatory 500 naming this section (an
infinite SSE/EventStream cannot ride a buffered bridge), and a second
`receive()` waits — uvicorn parity — so Starlette's streaming responses meet
that watchdog instead of returning accidentally-truncated 200s.
Zero-config also landed here: when no topology flag or `M0_*` topology
variable is given at all, `m0serve` starts `--blocking-threads
min(cores, 8)` by default (either protocol), so one slow view no longer
stalls the out-of-box server; `--realtime` keeps the single-loop shape, and
any explicit topology value — including `M0_BLOCKING_THREADS=0` — wins.

**Phase 2 — shipped: the per-loop asyncio executor.** Real
await-concurrency (uvicorn's shape) without a coexisting-loop architecture:
one Python thread per Mojo event loop runs a persistent asyncio loop, fed
through the **unchanged** `OffloadPool` — the loop parks the request and
submits the slot exactly as `--blocking-threads` does, the executor's
`loop.add_reader` on the submit fd turns each slot into a task, and task
completion answers through `put_response`/`complete`, which any producer
holding the pool address may drive (`m0_wsgi.asgi_executor`; the pump
batch-drains events so one `run_until_complete` enter/exit amortizes over
everything ready). Every Python object stays touched by exactly one thread
(the §5 cliff is avoided structurally), and on a GIL build the selector
inside `run_until_complete` releases the GIL, so the detached Mojo loop and
the executor interleave. ASGI no longer defaults to a pool — the executor
is its concurrency (`use_asgi_executor`; an explicit `--blocking-threads
N>0` keeps the buffered pool as the escape hatch) — and the banner says
`asgi-loop`. Measured on day one: **eight concurrent 1.5 s awaits complete
in 1.51 s on one loop with zero threads** (the buffered bridge takes 12 s),
the RSS guard stays flat — 20 KB to ~1.7 MB over 10k requests across runs,
allocator/arena noise (uvloop's included) rather than growth, against the
12 MB limit (the executor path crosses method/path/query/headers directly
through the C API — no environ, no CGI names, no Python-side
re-transform) — and exactly one lifespan runs per event loop (the loop's
fallback handler is built with `lifespan=False`).
The bench-asgi gate against uvicorn: the mixed slow/fast tail **passes**
(fast p99 2.87 ms vs 3.27 ms) and hello-world throughput stands at
0.88–0.94x across runs — the located remainder and its fix paths are
recorded in [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md) §"The ASGI executor
vs uvicorn". The executor opportunistically uses uvloop for its own loop
where installed, stdlib asyncio otherwise.

**Phase 3a — shipped: streaming ASGI responses.** An `http.response.body`
sequence with `more_body=True` now actually streams — FastHTML's
`EventStream`, Starlette's `StreamingResponse`, Datastar patch streams —
by reusing the §4 transport rather than building one. The executor
publishes response chunks as bus-shaped datagrams on a private per-loop
channel (`OffloadPool.enable_stream_channel`; the chunk pair's read end is
the loop's `bus_read_fd`, free since `--realtime` is refused for ASGI),
delivered through the existing `drain_bus_channel` → `sse_peer_frame`
path into the loop-owned `SSERegistry` under reserved channel names that
open with a control byte no HTTP header value can carry. The mechanics
that make it correct, each pinned by `smoke-asgi`:

- **Order is a FIFO property, not a hope.** A stream's begin frame is
  sent on the chunk channel *before* its head rides the completion
  channel, so the handler is subscribed before the loop ever drains the
  slot as a stream — and every frame of a stream sits between its begin
  and end on one FIFO channel, which is what makes a recycled slot safe:
  chunks that outlive their connection arrive unsubscribed and are
  dropped, never injected into the next request.
- **Backpressure is credit, not drops.** A second private pair carries
  drain acks loop→executor — `(slot, bytes)` after each fully flushed
  buffer — and the shim's `send()` awaits credit (64 KB window, 32 KB
  chunk split) before emitting. The registry's 64 KB drop threshold is
  therefore never reached, and a 100 MB stream behind a slow reader
  holds server RSS growth to ~2 MB.
- **End of stream is a close.** The head goes out without
  content-length, so the body is close-delimited; the handler
  unsubscribes after handing out the final bytes, and the loop — reading
  `sse_is_streaming`, the hook nothing had ever called — closes once
  they land. A disconnect tag on the submit channel resolves the app's
  `receive()` into `http.disconnect` and cancels its task, uvicorn's
  contract.
- **No comment heartbeats on ASGI streams**: an SSE event may span two
  chunks, and a `: heartbeat` between them corrupts the frame (the smoke
  splits a Datastar event mid-word under a 300 ms cadence and asserts
  byte-exactness). Dead clients are found by send failure and read-EOF.
  The buffered escape hatch (`--blocking-threads N` with ASGI) keeps its
  10 s watchdog refusal.

**Phase 3b — shipped: `websocket` scopes.** The same seam, and the same
correctness arguments. The executor probes each parked request with
`websocket_upgrade` (the loop's own validator); a handshake gets a
`websocket` scope, and the ready 101 is **held** until the application's
`websocket.accept` — the approve/perform split M0-Hold uses, because the
accept value comes from the original request's key. A begin frame anchors
the FIFO before the 101 completes (exactly as a stream's head), outbound
`websocket.send` frames are RFC 6455-encoded executor-side and ride the
chunk channel into the loop handler's `sockets` registry, and
`websocket.close` queues the close frame plus the end marker so the loop
closes after both land. Inbound messages the loop's parser assembled are
forwarded by `ws_message` as tagged submit-channel datagrams into
per-slot queues behind `receive()` (bounded by `max_message_size`, under
the channel's frame cap); 3a's disconnect tag doubles as
`websocket.disconnect` and cancels the task. An app that returns without
accepting — or that raised first — resolves its held 101 as a 403, so no
slot leaks. `smoke-asgi` drives a raw RFC 6455 probe (verified accept,
both echo directions, close(1000) through to the FIN, then an abrupt
vanish after the 101); `smoke-fasthtml` proves `app.ws` end to end.
**FastHTML's full surface — pages, SSE EventStream, WebSockets — now runs
on `m0serve` with zero configuration.**

The M0-Hold/GRIP path is untouched by all three phases and remains the
recommended realtime surface for synchronous WSGI codebases.

## 9. Mounts (2026-08): several applications, one process

The gateway answers "*which* protocol is this app?" The premise that
started it was messier: a codebase that is partly sync and partly async,
where the developer should not have to choose. Detection alone does not
settle that — it tells you which single server to run.

`m0serve --mount PREFIX=SPEC` hosts several applications in one process,
routed by longest prefix before either sees the request. Each mount
detects its own protocol (discovery included, so `--mount /=djangoproj`
finds `djangoproj.wsgi` exactly as a positional spec would) and gets its
own bridge — which costs nothing to arrange, because `PyBridge` already
`exec`s the shim into a **fresh namespace dict** per instance, so N apps
are N isolated shim states rather than N collisions.

**The prefix is the whole correctness story, and the two protocols
disagree about it.** WSGI wants `SCRIPT_NAME = prefix` with `PATH_INFO`
trimmed to the remainder; ASGI wants `root_path = prefix` with `path`
left **whole** — Django's `ASGIHandler` strips the prefix itself and hands
`request.path` the untrimmed value. Get it backwards and every direct
request still works while every *generated* URL is wrong, which is
invisible until someone clicks something. `PyBridge.set_base` is
therefore the one place either protocol learns the prefix, and
`smoke-hybrid` compares Django's `reverse()`, Flask's `url_for()` and both
frameworks' `request.path` byte for byte (verified load-bearing: with the
`PATH_INFO` trim disabled, the Flask mount stops routing at all).

A path no mount claims is a **404 answered in Mojo**, never entering
Python. Prefixes match on segment boundaries, so `/app` serves `/app` and
`/app/x` but never `/application`, and the root mount is the empty prefix
— which needs no special case, since every target starts with `/` and any
deeper mount outranks it.

**Stage 2: each mount in its own native execution mode.** The refusal of
mixed WSGI/ASGI mounts is gone, and with it the reason mounts were a
convenience rather than a capability. A submit **lane** — one `SOCK_DGRAM`
pair per mount — replaces the single submit channel, so the loop's
`pool.submit(slot, path)` hands a job to the worker that can actually run
it: the asyncio executor for the ASGI mount, handler-pool threads for the
sync ones, dealt round-robin across their lanes. One `ProvisionPool` per
loop **stays** (a slot indexes that loop's provisions, and a pool shared
between loops would answer the wrong connection); only the submit side
became per-mount. `match_path_prefix` in `offload.mojo` is the single
implementation of the matching rule, so the lane a job takes and the
application the handler picks cannot disagree.

Each worker builds **only its own mount's** application (`only_mount`) —
building the rest would run one lifespan per mount per thread for
applications it can never be handed.

Measured, and pinned by `smoke-hybrid`: with four blocking 2-second Django
views holding every pool thread, the FastHTML mount answers at **p50
1.3 ms, p99 2.8 ms**. Sharing one execution mode puts those in the seconds
— which is the same shape as the mixed-workload run that justified
`--blocking-threads` in the first place (§`WSGI_PERFORMANCE.md`).

**What is still refused, and why it is refused rather than guessed:**

- **A second ASGI mount.** Each executor needs its own streaming chunk
  channel and the loop has one `bus_read_fd`. Sharing it is possible —
  slots are unique per loop, so chunks are already addressed — but the
  drain **acks** are not, because credit belongs to the executor that owns
  the slot. That routing is the next piece of work, and serving a second
  async app without its streaming would be a quiet downgrade. Any number
  of WSGI mounts may sit beside the one ASGI mount.
- **`--mount` with `--realtime`.** M0-Hold subscribes a connection to
  registries the loop's handler owns, and an inbound WebSocket message is
  delivered back into ONE application's urlconf. Which mount should
  receive it has no defensible answer.
- **Per-mount modes under `--threads`.** The threaded path adds no lanes,
  so a mounted server there routes to lane 0 and every mount shares one
  mode — stage 1's behaviour, still correct, just without the advantage.

**Why this is the hybrid advantage rather than a convenience.** uvicorn
hosts one callable; daphne hosts one; Granian hosts one. Mixing otherwise
means two processes behind a reverse proxy, or composing in Python
(Starlette `Mount` + `WSGIMiddleware`, which drops the sync app onto the
event loop's threadpool and inherits every limit that implies). A sync
application and an async one sharing one listener, one set of workers and
one graceful shutdown while each keeps its own concurrency is the thing no
other server in this space does, and it is what pays for the complexity §8
spent.

## Sources

- PEP 703 (free-threading), PEP 779 (supported status):
  <https://peps.python.org/pep-0779/> — accepted for 3.14, October 2025.
- Free-threading status and ecosystem tracking:
  <https://py-free-threading.github.io/>
- Django ticket #36983 (free-threading support; 3.14t CI merged 2026-07-15,
  3.13t dropped over immortalization leaks):
  <https://code.djangoproject.com/ticket/36983>
- Django forum, "Improve free-threading performance" (Sam Gross's contention
  patches; test suite green under free-threading with asgiref 3.12):
  <https://forum.djangoproject.com/t/improve-free-threading-performance/44497>
- discuss.python.org, "What is the recommended web server architecture for
  free-threaded Python?" (sync thread pool vs ASGI benchmarks):
  <https://discuss.python.org/t/what-is-the-recommended-web-server-architecture-for-free-threaded-python-3-13/106314>
- GRIP protocol / Pushpin: <https://pushpin.org/docs/protocols/grip/> —
  django-eventstream is the Django binding:
  <https://github.com/fanout/django-eventstream>
- uWSGI, "Offloading Websockets and Server-Sent Events":
  <https://uwsgi-docs.readthedocs.io/en/latest/articles/OffloadingWebsocketsAndSSE.html>
- Mojo std.python + free-threaded libpython discovery:
  <https://github.com/modular/modular/issues/6366>
