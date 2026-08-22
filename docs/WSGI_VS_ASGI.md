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

The canary and the probes together do **not** make m0-wsgi multithreaded; they
bound the design work. What remains is engineering, not discovery: the
bridge's per-process singletons (one transfer bytearray, one `_body` global,
"state attached to main forever") must become per-thread, and shared Python
state above the bridge (Django's own caches — the contention Sam Gross is
patching upstream) is the scaling risk to measure. One rule to carry into
that design: a thread that blocks on a raw OS mutex *while attached to the
interpreter* stalls every thread's stop-the-world pauses — blocking waits on
the Mojo side must either detach first or use `PyMutex` (public C API since
3.14), which parks cooperatively. The prize is unchanged:
threads would eventually *replace* `M0_WORKERS` forking — one process, shared
memory, no per-worker RSS duplication, no bus needed for fan-out, and the
entire class of fork-after-init hazards (the macOS `_scproxy`/objc abort,
`exit_worker`, fork-before-first-Python-call) simply disappears. That is the
"WSGI thread pool" future; the canary plus this probe are its go/no-go gate,
and both currently say go.

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

## 7. Where this fits the larger aims

Against the project's Django-server aims (hybrid gateway, static files, DX,
benchmarks), this work slots in as follows: the **"WSGI thread pool instead
of Gunicorn-style forks"** aim is gated on exactly what `py-canary` measures
— a native thread pool running Python is real parallelism only without the
GIL, so the canary is that aim's standing go/no-go probe. The **"ASGI
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
