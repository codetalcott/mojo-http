# Which language the executor shim should be in — decided 2026-09-05

> A design note from the engineering record, written before the shim was
> moved out of `bridge.mojo` into a file of its own
> (`packages/m0-wsgi/shim/m0_shim.py`). The question it answers was asked
> before the move was allowed: is Python the right implementation for what
> the shim does, or should the extraction have been a port?

## What the shim is

About 1,500 lines of Python, `exec`'d into a fresh namespace per
`PyBridge` (so per worker, per serving thread, per pool thread and per
executor). It holds five things:

1. **The WSGI protocol** — `start_response`, its `write()` callable, PEP
   3333's `close()`, and the decision of whether an unsized iterable
   streams or buffers (`_stream_this`, `wsgi_stream_next`).
2. **Detection** — `_detect`, `detect_spec`: is this object a WSGI callable
   or an ASGI one, unwrapping `functools.partial`, importing the module and
   keeping the traceback when the application fails to load.
3. **The asyncio executor** — one persistent loop (uvloop where installed),
   `spawn` creating a task per request, `_Cycle` as the request's
   `receive`/`send`, the lifespan, `run_forever` and its inverted twin.
4. **The streaming seam's bookkeeping** — the per-slot credit windows and
   the global one, the disconnect marks, the slot-ownership rules `poe
   test-shim` sabotage-proves, the WebSocket inbox and accept set, the
   datagram grammar of the submit and ack channels.
5. **The application-facing pub/sub object** — `_M0Broadcast`, at
   `scope["state"]["m0"]`, whose `subscribe` is an async iterator.

Everything else about a request is already Mojo, and has been moved there
one measured piece at a time ([executor-python-objects.md](executor-python-objects.md)):
the scope is built through the C API and handed over finished, the
response head is read through the C API without becoming `str`, WebSocket
frames are RFC 6455-encoded in `asgi_executor.mojo`, chunk frames and
completions are sent from Mojo, and every event the shim raises crosses
into Mojo through one `_port.dispatch` call (~70 ns).

## What only Python can do here

- **Own the loop and the application's coroutines.** `create_task`,
  `add_reader`, `run_forever` are calls on a Python loop object that may be
  uvloop's. Mojo can drive that loop only by calling into it; stepping the
  application's tasks itself would be `PyIter_Send`, which the roadmap
  refuses as version-fragile, and a native awaitable `send` was evaluated
  and found to have nothing to remove (the buffered `send` completes
  without a loop iteration as it is).
- **Be the awaitables the application awaits.** `receive` and `send` must
  be coroutine functions — Starlette awaits them from inside an anyio task
  group — and `start_response` must be a plain Python callable closing
  over per-request state. `PythonModuleBuilder` binds synchronous methods
  (that is what `ExecutorPort` is); it cannot produce a coroutine.
- **Wait as an `await`.** Every wait in the seam — a stream's credit, the
  global window, a disconnect, a WebSocket's inbox, lifespan startup — is
  an `await` on an `Event`, a `Future` or a `Queue`, so the executor's
  other tasks keep running and the selector releases the GIL. CLAUDE.md
  states the rule as "both waits live in the shim, where waiting is an
  await"; a Mojo wait on the executor thread would have to detach first
  and would still park the loop.
- **Keep every Python object on the executor thread.** The namespace is
  per bridge and every table in it is touched by one thread, which is how
  the measured 0.7x shared-object cliff
  ([wsgi-vs-asgi-history.md §5](wsgi-vs-asgi-history.md)) is avoided by
  construction rather than by locking.
- **Answer Python protocol questions.** `inspect.iscoroutinefunction`,
  `importlib` with the traceback, `isinstance(result, (bytes, list, ...))`,
  `getattr(result, "streaming")`, `iter()`/`next()` over the application's
  iterable, `close()` on it. Reachable from Mojo through the C API, every
  one, and startup-only or once-per-response, every one.
- **Be an object the application holds.** `_M0Broadcast` is handed to the
  application in its lifespan state; its `subscribe` returns an async
  iterator that `async for` drives. A Mojo-bound type could carry
  `publish` (a synchronous `os.write` per worker channel), but not the
  iterator, and `publish` is not on any request path.

## What is language-neutral, and what moving it would buy

Measured with `scripts/shim_parts.py`'s method — the shim driven through real
socketpairs by the same harness `poe test-shim` uses, a stand-in port, a
trivial application, CPython 3.13.6, Apple M4, idle — the bookkeeping a
Mojo port could take is:

| per operation | cost |
|---|---:|
| the event tuple, its `dispatch`, and arming the flush (`_exec_put`) | 54 ns |
| decoding one 8-byte job (`int.from_bytes`) | 55 ns |
| decoding a 16-slot batch datagram | 1.03 µs (65 ns per slot) |
| a datagram through the submit pair, send and `os.read` | 0.73 µs |
| a chunk's credit spend, three dict operations (streams only) | 75 ns |
| a whole buffered request on the Python side, loop overhead removed | 3.11 µs |

Two events cross per buffered request (the job in, the completion out),
so the language-neutral share is roughly 0.2 µs of tuple and decode plus
the amortised read — under 0.4 µs of a 3.1 µs Python side (the
instrumented figure in [executor-python-objects.md](executor-python-objects.md)
is 3.82 µs, which includes the crossing), and 4–5 % of the roughly 9 µs
of executor-thread time a request costs at 16 connections. The rest of
the Python side is `create_task`, the two `send`s, the done-callback and
the application's own awaits: asyncio's machinery, which no bookkeeping
move touches.

Candidate by candidate:

- **Reading the submit and ack datagrams in Mojo.** The `add_reader`
  callback would be a bound port method instead of `_on_submit`, so the
  per-datagram Python→Mojo call replaces the per-event one — no crossing
  added, one removed per job — and the `os.read` wrapper, the decode and
  the tuple go. Bound: the 0.2–0.4 µs above, most of a datagram's cost
  being the syscall either side pays. What it would cost is the thing
  `test-shim` is built on: the datagram grammar (`_TAG_*`, the batch
  shape, the ack clamp) is today exercised through real socketpairs with
  no Mojo in the process, and ten sabotages prove the rules bite. Moving
  the grammar behind the port moves it out of the deterministic guard and
  into the smokes. Not taken; if it ever is, a Mojo-side harness with the
  same sabotage discipline comes first.
- **The credit windows in Mojo.** `ExecutorState` already holds per-slot
  generations and the `lost` flags; the windows could join them. But a
  spend is three dict operations at 75 ns and a port call is ~70 ns before
  it does anything, and the WAIT stays a Python `await` on an `Event` that
  Mojo would then have to `set()` on every ack — a Mojo→Python call per
  ack where today there is none. More crossings, not fewer. No.
- **Frame encoding.** Already Mojo. What is left in Python is
  `_ws_frame_bytes`, three comparisons mirroring `encode_ws_frame`'s
  header size so credit is charged in the bytes the loop acks; a call to
  ask Mojo would cost more than the arithmetic.
- **Channel-name parsing.** The `_TAG_BUS_FRAME` decode is a slice and a
  `decode`, and the fan-out it feeds is `Queue.put_nowait` into
  per-connection asyncio queues, which is Python by nature. Pub/sub events
  are not on the request path.
- **`_scope_from_environ`.** The buffered escape hatch still rebuilds an
  ASGI scope from a WSGI environ in Python, sixty lines the executor path
  no longer needs because `_build_scope` builds the scope in Mojo. Sharing
  that with the escape hatch is a cleanup worth doing, not a performance
  change: the hatch is `--blocking-threads N` with an ASGI app, which
  nothing zero-config runs.
- **`spawn_ws`'s scope.** Per connection, deliberately Python
  (executor-python-objects.md records the choice).

## The two hard constraints, and which way they cut

- **The executor cannot exist on free-threaded CPython.** `ExecutorPort`
  is built with `PythonModuleBuilder`, which writes the GIL build's
  16-byte `PyObject` header where 3.14t's is 32 (modular/modular#5726;
  ROADMAP's known issue). Every function moved behind the port is a
  function that cannot run there, while the shim as Python does: the
  weekly canary execs it on 3.14t and its WSGI half serves. A port of the
  bookkeeping would widen the gap that issue tracks.
- **Hot shared mutable Python objects anti-scale below serial.** Neutral
  here: the shim's tables are per namespace and per thread, and
  `ExecutorState` is per thread by address. Either home keeps the
  structure; neither is an argument for moving.

## Verdict

Python stays, and the line is already where it should be. Python owns
the loop, the awaitables, the protocol questions and the ownership rules
the deterministic guard proves; Mojo owns bytes — the scope build, the
head read, frame encoding, the channel sends, completion batching. The
extraction therefore gives the shim what a Python program is owed and
nothing more: a `.py` file, an editor, pyflakes (which found the one
unused import on its first run), and a renderer that turns it back into
the Mojo string the binary embeds
([render_shim.py](../../scripts/render_shim.py); `poe render-shim`,
checked current by `check-docs`).

Two follow-ups are recorded rather than done: share `_build_scope` with
the buffered escape hatch, and — only behind a Mojo-side harness as
strict as `test-shim` — the datagram readers, for at most the 0.4 µs
measured above.
