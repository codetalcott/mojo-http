# Why m0serve has two execution modes

One server, two ways of running Python, chosen by the protocol of the
application it is given. This page says what each mode is, why one would not
do, and where each one has a cliff. Which flags to pass is in
[Running m0serve](RUNNING.md); the dated design essay with the measurements
behind every claim here is [the design record](notes/wsgi-vs-asgi-history.md).

## The two modes

| | WSGI application (Django, Flask) | ASGI application (FastHTML, Starlette, Django ASGI) |
|---|---|---|
| how the app is called | one synchronous call per request | one long-lived coroutine with `receive` and `send` |
| what runs by default | one event loop and a pool of `min(cores, 8)` handler threads | one event loop and an asyncio executor |
| where overlap comes from | threads waiting on I/O; `--workers` processes for CPU | the app's own `await`s; `--workers` processes for CPU |
| a slow view | holds its handler thread; the loop keeps serving | blocks the loop unless it awaits, as under uvicorn |
| realtime | `--realtime`: a view approves a held SSE stream or WebSocket with two headers, `m0pub.publish` reaches every subscriber | native: the app streams its own response or takes a `websocket` scope |
| several apps in one process | `--mount`, on the pool | `--mount`, each ASGI mount on its own executor |

In both modes the Mojo event loop owns the sockets: accepting, parsing,
framing, timeouts, backpressure, static files and the health path never enter
Python. Only the step that runs the application differs.

## Why not one mode

WSGI and ASGI answer the same question, how a request reaches Python code,
in incompatible ways. A synchronous view cannot run *on* an event loop without
a thread pool underneath it, which is what `WSGIMiddleware` in Starlette does
and why it inherits every limit of the loop's thread pool. A coroutine cannot
run without an event loop at all. So each protocol gets the runtime it was
designed for, and the server in front of both is the same.

The alternative most servers take is to host one protocol and tell the other
to bring its own process. That is what makes mixing a sync Django app with an
async FastHTML app mean two servers behind a reverse proxy everywhere else,
and one `m0serve --mount` here.

## What the WSGI mode is for

**A pool, not a loop per request.** A WSGI worker is busy for a request's
whole wall-clock time. Running views on the event loop thread would let one
slow view stall every keep-alive connection behind it; running them on a pool
of handler threads behind the loop keeps a slow view's cost to its own thread.
This is the default because it is the difference between a p99 measured in
milliseconds and one measured in the length of the slowest view
([the slow-view isolation benchmark](BENCHMARKS.md)).

**Held connections without a pinned worker.** WSGI has no wire for
WebSockets, and an SSE stream under WSGI is an infinite iterable that occupies
its worker for as long as the client stays. m0serve moves the held connection
to the event loop: the view runs to completion, approves the hold with
`M0-Hold` and `M0-Channel`, and returns; the loop keeps the socket, delivers
what `m0pub.publish` sends, and closes it when the client leaves. That is the
headline capability, and it is why WSGI is first-class here rather than a
legacy path. Under gunicorn the same headers are ignored and the view degrades
to a short plain response.

**Parallelism.** `--workers N` forks N processes, the answer that works under
the GIL. On free-threaded CPython, `--threads N` runs N event loops in one
process with one interpreter, each loop with its own pool; the weekly canary
proves that path on 3.14t.

## What the ASGI mode is for

**The application's own concurrency.** An ASGI app expects to overlap
requests wherever it awaits, to stream a response as it produces it, and to
hold a WebSocket as a coroutine. The executor is a persistent asyncio loop per
event loop, fed by the Mojo loop and answering back through it; streaming
responses stream for real, `websocket` scopes work, and the framework's whole
surface runs unmodified. The Mojo loop still owns framing and flow control:
every stream is credit-gated so a fast producer cannot overrun a slow client
or the channel between the two threads.

**A buffered fallback.** `--blocking-threads N` with an ASGI app selects the
older buffered path, one request at a time to completion on a pool thread. It
exists as an escape hatch and refuses an infinite stream rather than hold a
thread forever.

**One limit, from the toolchain.** The executor is a Python type built
in-process, and Mojo 1.0's Python bindings lay that type out for the
GIL build. On a free-threaded CPython the server refuses an ASGI app with
exit 78 rather than crash, so ASGI under `--threads` does not exist on this
toolchain ([the known issue](ROADMAP.md#known-issues)).

## Free-threading, briefly

Free-threaded CPython removes the reason most people reached for async in
the first place: sync thread-per-request code scales across cores in one
process, with shared memory and no async ecosystem to adopt. It does not
change the protocol surface. PEP 3333 still has no wire for WebSockets, so
the hold contract stays the way a sync app gets realtime, on either kind of
interpreter.

## The cliffs

- **Shared mutable Python objects across threads** are the measured cliff of
  the threaded mode: per-request state must stay thread-local (the record's
  §5 has the numbers).
- **A generator that sleeps holds its pool thread** until it yields again,
  and the client leaving does not wake it. SSE views whose generators sleep
  belong on the executor or as `--realtime` holds, never on pool threads.
- **A slow view under ASGI blocks the loop** unless it awaits. That is ASGI's
  nature, not m0serve's; the pool is the WSGI answer to the same problem.
- **The buffered ASGI path refuses infinite streams** by design.

## Choosing

With no flags, the protocol chooses correctly for the common case. Reach for
`--workers` when you have cores to use, `--realtime` when sync views should
hold connections, `--mount` when two applications belong in one process, and
`--threads` only on a free-threaded interpreter with a WSGI app. The flag
table and the reasoning for each are in [Running m0serve](RUNNING.md#which-mode).
