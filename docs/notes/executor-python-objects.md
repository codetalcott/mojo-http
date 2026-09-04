# The executor's per-request Python work, and the C-API head read — shipped 2026-09-04

> A design note from the engineering record: §4.3 of the fast-server
> comparison (Granian, Go's `net/http` and fasthttp, uWebSockets, uvloop,
> read at mechanism level), scoped to one branch. The detached loop
> ([detached-loop.md](detached-loop.md)) is the note before this one and
> the reason this one was next.

## Where it started

With the loop thread off the GIL, the ASGI executor at 256 connections did
157–161k rps on 1.83 cores and at 16 connections 100–109k on 1.6 — ahead of
a single uvicorn+uvloop process per core at saturation and behind it at low
concurrency, where the executor thread's own work per request is the
bound. That work was larger than it needed to be, and all of it sat in two
files: the shim in `bridge.mojo`, and `build_response` in `response.mojo`.

One request cost the executor thread, in Python:

1. `spawn()` assembling the scope — `dict(_scope_base)`, eight stores, an
   `encode` for `raw_path`, a `split` for `http_version`, a copy of the
   lifespan state — then `create_task`, two dict stores, two pops and a
   done-callback closure built per request.
2. `_serve_one_exec` allocating three nested closures (`receive`, `_emit`,
   `send`) and the seven lists they closed over.
3. On completion, `'%d %s' % (status, responses.get(status, ''))`, a
   latin-1 decode of every header name and value into fresh `str`s, and
   `b''.join(chunks)`.
4. `build_response` on the Mojo side iterating that list as
   `PythonObject`s — two `String(py=...)` per pair — and filling a
   `Headers` one store at a time.

Granian builds the scope in Rust and hands Python one object, its
per-request protocol object is one struct, and the head never becomes
`str`; uvicorn's `RequestResponseCycle` is one object with bound methods.
The WSGI half had been priced already (WSGI_PERFORMANCE.md, "The response
half"): reading the app's headers through `PythonObject` iteration was
1.27 µs of a six-header response's 3.30 on the box of the day, and the
`Headers()` plus six stores another 1.39. Nothing on the ASGI side had
been priced by part.

## The instrument first

`scripts/bench_bridge_parts.mojo` grew an ASGI half before anything was
changed: a six-header app, a stand-in port that records what
`ExecutorPort` would dispatch, the loop driven in batches of a thousand.
The rows split the executor's per-request work as `spawn` (the crossing,
the scope build, `create_task`), the task's run to its done-callback (the
app, both sends, the completion's dispatch), the shim's head decode timed
alone, and the head read on the Mojo side. Baseline, 20k iterations, Apple
M4, CPython 3.13.6 (GIL build):

| row | at the branch point |
|---|---:|
| ASGI spawn (scope + task) | 2.97 µs |
| ASGI task run → dispatch | 2.77 µs, of which the head decode 0.51 |
| WSGI `build_response`, 6 headers (the ASGI head took the same path) | 2.08 µs |
| WSGI `serve()` = run + response | 3.86 µs |

## Four commits, each measured before the next

**1. Read the response head through the C API.** `PyBridge.read_head`
walks the application's list with `PyObject_Length`, `PyList_GetItem` and
`PyTuple_GetItem` (borrowed, never DecRef'd — a DecRef on a borrowed
reference is a double free that surfaces later, elsewhere), reads a `str`
through `PyUnicode_AsUTF8AndSize` (the object's cached UTF-8, the same
text `String(py=...)` produced) and a `bytes` through `PyBytes_AsString`,
and sizes the `Headers` blob from a first pass over the same pointers.
The Set-Cookie dispatch and the CR/LF/NUL refusal run on the raw spans
before anything is copied. `build_response` keeps the WSGI signature;
`build_asgi_response` takes an `int` status and `(bytes, bytes)` pairs,
with the reason phrase from a Mojo table generated from CPython 3.13's
`http.client.responses`. Six-header `build_response` 2.08 → 1.00 µs, one
header 0.92 → 0.60, six plus two cookies 2.49 → 1.24; `serve()`
3.86 → 2.73 µs. Flat under wrk on the bare ASGI app, which returns one
header and whose head still crossed as `str` until the next commit.

**2. Hand the ASGI head to Mojo untouched.** The `done` and `stream_start`
events carry the status as the `int` the application sent and its own
header list; the shim's format and decode are gone with the `http.client`
import that fed them. Task run → dispatch 2.77 → 2.15 µs. Under wrk,
arms alternated against the branch-point binary: c16 +3.7–3.8 %, c256
+2.8–3.9 %, on slightly fewer cores.

**3. Build the scope in Mojo and pass one object.** The bridge holds a
finished HTTP scope template beside its environ template (`type`, `asgi`,
`scheme`, `root_path`, `server`, `client: None`, built in `set_base` so a
mount's prefix and server pair are in it); `_build_scope` is `PyDict_Copy`
of it plus eight `PyDict_SetItem`s, each value released after the store,
and `spawn(slot, scope, body)` does nothing but create the task. The
WebSocket scope stays Python-built: a handshake is per connection. The
new `build_scope` row reads 0.47 µs and `spawn` 2.59 → 2.34: smaller than
the handoff's guess, because the Python-side stores were ~0.7 µs and most
of the C build is the twelve-pair headers list both shapes had to make.
Cumulative under wrk: c16 +6.0–6.5 %, c256 +5.0–5.2 %.

**4. One request object instead of three closures.** `_Cycle`, a class
with `__slots__` whose `receive`, `send` and `done` are bound methods,
replaces `_serve_one_exec`'s closures and the done-callback closure
`_task_done` built per request (the WebSocket path keeps a closure per
connection; both apply `_on_task_done`'s rule). `asyncio` is imported on
the rare branches that need it, so the buffered path touches it nowhere.
The ownership rules did not move — the streaming mark and the cancellable
stream task go on the slot's owner task, cleanup runs only if the
finishing task is the owner, `_task_gone` consults both marks — and
`test-shim`'s sabotage suite says so: the two patches whose guarded lines
moved were updated in the same commit and all ten still bite. The item
the handoff expected to be smaller than it looked was the largest single
step on the executor rows: spawn 2.34 → 1.97 µs, task run 2.17 → 1.85.

## What it adds up to

Per part, at the branch point and after the four commits:

| row | before | after |
|---|---:|---:|
| ASGI spawn (scope + task) | 2.97 µs | 1.97 µs |
| ASGI task run → dispatch | 2.77 µs | 1.85 µs |
| ASGI executor, Python side (the two above) | 5.74 µs | **3.82 µs** |
| ASGI head → `HTTPResponse`, Mojo side | 2.08 µs | 0.95 µs |
| WSGI `build_response`, 6 headers | 2.08 µs | 0.96 µs |
| WSGI `serve()` = run + response | 3.86 µs | 2.61 µs |

End to end, `bin/m0serve` at the branch point against the four commits,
one box, arms alternated within each configuration, two rounds of 8 s
under wrk on `apps/asgi_bare`, the executor on the venv's uvloop:

| configuration | branch point | after | change |
|---|---|---|---|
| ASGI executor, c16 | 102.9–107.9k rps @ 1.63–1.65 cores, p50 135–143 µs | **113.6–116.0k @ 1.59–1.60, p50 125–128 µs** | +7.5–10.4 % |
| ASGI executor, c256 | 157.3–159.4k @ 1.82–1.85, p50 1.47–1.48 ms | **169.0–169.5k @ 1.73–1.75, p50 1.43–1.44 ms** | +6.4–7.4 %, +12 % per core |

Bodies byte-identical, no log noise, RSS growth 0 KB over 10k requests on
both protocols. The handoff's expected value was +6–20 % on the ASGI rows;
this is the low end of it, and per part the bench says where the rest
would come from: the two Python rows are still 3.8 µs of the roughly
9 µs of executor-thread time a request costs at 16 connections, and what
is left in them is `create_task`, the two `send`s and the done-callback —
asyncio's own machinery, which only a native `send` or task stepping
would remove, and both are refused below.

## What this did not change

- The buffered ASGI escape hatch (`_run_asgi`) still returns the
  WSGI-shaped triple; `WSGIApp.serve` is untouched.
- The WebSocket scope and its done-callback are Python-built per
  connection.
- The datagram handoff (§4.2 of the comparison) is the next lever, not this
  one.
- No `PyEmptyAwaitable`-style native `send` and no `PyIter_Send` task
  stepping: the first has nothing to remove (the shim's `send` already
  completes without a loop iteration on the buffered path), the second is
  version-fragile and ROADMAP refuses it.
