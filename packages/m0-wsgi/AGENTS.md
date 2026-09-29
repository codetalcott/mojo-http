# m0-wsgi: rules for changing this package

The WSGI/ASGI gateway and the `m0serve` binary. The repository's
`CLAUDE.md` still applies; this page adds what is specific to the gateway:
embedding CPython, mounts and their lanes, and the execution modes with the
rules each depends on. The handler-pool rules also govern files outside
this directory — the fork's offload seam (`lightbug_http/offload.mojo`,
`lightbug_http/ring.mojo`, the event loop's pool and executor paths) and
`m0_http.mojo_pool` — so read this page before editing those too.

`m0-wsgi` is the **only** package that embeds CPython. Keep it that way: a
Python import in `m0-http` or `m0-core` would put libpython on the link line of
every build in the repo. Inside the package, `src/bridge.mojo` owns the
per-request interop — the environ build, the response read, every raw C API
call — and is the file to reach for first. The other `std.python` importers
are the modules that run Python on a thread of their own (`app`,
`asgi_executor`, `blocking_pool`, `response`, `threaded`, and `m0serve.mojo`),
because attaching, building a handler and destroying it there are theirs to
do — plus `handler.mojo`, whose only use is
`PyEval_SaveThread`/`PyEval_RestoreThread` around the detached waits in its
pool-thread streaming helpers; everything else works in Mojo types, and
keeping it that way is what bounds how many places the leak rules below
have to hold. The package
hosts **both protocols**: the shim detects WSGI vs ASGI at `set_app`
(`--protocol` forces it), and an ASGI app runs buffered on a persistent
per-bridge asyncio loop — the protocol dispatch lives entirely inside the
shim, so the per-request Mojo path is identical for both and the leak rules
below apply unchanged. Under the executor (the ASGI default) streaming
responses stream for real — see the executor bullet below for the three
load-bearing rules; only the buffered escape hatch still refuses an
infinite stream with its 10s watchdog (docs/notes/wsgi-vs-asgi-history.md §8), and that
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
`match_path_prefix`, so they cannot disagree — except on a MISS, where
`lane_for` answers lane 0 and nothing downstream of an executor or a Mojo
pool asks again, so a path no mount claims is answered in `serve_local`
(on the loop, through `before_request`, before a lane is chosen) against
`route_prefixes`, the WHOLE mount table: `mount_prefixes` holds only the
Python apps a handler built and would 404 every compiled mount (SPEC M21);
each worker builds **only
its own mount** (`only_mount`), or lifespans run once per mount per
thread; and pills are sent per lane at shutdown, because a thread parked
on lane 2 is not woken by a pill sent to lane 0. **Every lane needs a
thread, and a mount set that leaves one without is refused, never
served** (SPEC M20): a job submitted to a lane nobody parks on is never
taken and its slot is never swept, so the request hangs with a clean log.
Threads are dealt round-robin, one lane each, from `--blocking-threads` —
the WSGI pool over the WSGI lanes and one `MojoPool` per compiled kind
(`mojo`, `hold`) over its own — so zero config never deals fewer than the
lane count (`resolve_blocking_threads`), and an explicit `--blocking-threads`
that does is refused, never raised. A mount set with no inline shape — a
compiled mount, or an ASGI mount beside a WSGI one — keeps the default pool
under `--workers`/`--threads` when `--blocking-threads` is unset
(`pool_is_default`): `--workers N` turns the pool off to keep the inline
loop reachable, and those sets have no inline loop to keep. The compiled half is decidable from the flags and goes in
`flag_checks` (`src/checks.mojo`), which runs BEFORE the bind and the fork
and is the same list `--doctor` renders (in a worker it crash-looped to exit
1 under `--workers N`); the WSGI half needs detection and exits 78 in the
worker (`app_checks`, `wsgi_lanes_unserved`). A set of more than 126
mounts is refused before the bind too (`mount-lanes`, 78): a pool has wake
words for 126 lanes, and `add_lane` raised on the 127th after the bind. The inline loop is not a lane: with no pool and
no ASGI mount the loop's handler answers every WSGI mount itself, and a
compiled mount there used to fall through to the root application. **Several ASGI mounts
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
whose view gated the upgrade and to no other. Its inline twin is
`hold_app[slot]`: where the loop's own handler serves every WSGI mount
with no pool, it records the index in `apps` of the application whose view
approved the socket as it subscribes, so `_ws_forward` hands an inbound
message to that mount, at its own prefix, and never to `apps[0]` for being
first. One refusal remains:
`--realtime` on a server with no WSGI mount at all, which is asking for a
hold nothing could take. **`--threads` gets the same
lanes**: `_serve_one` and `_serve_offloaded` both lay them with
`wire_offload` and stop them with `join_offload`
(`src/offload_threads.mojo`), so N loops of
per-mount modes is N times the prefork shape — with two consequences to keep
straight. The executor's chunk channel takes `bus_read_fd`, so a threaded
loop's own bus channel rides `peer_bus_fd` (both drain identically; passing
neither is how `state["m0"]` silently goes missing). And `set_lane_notify`
sits on the `ThreadHandler` trait beside `set_asgi_notify`, because the
generic `_serve_one` body can only call what the trait names.

Zero-config: with no topology flag or `M0_*` topology variable, a WSGI
`m0serve` defaults to `--blocking-threads min(cores,8)`, so one slow view does
not stall every connection out of the box. It is **not** a blanket default: a
zero-config ASGI app gets NO pool, because it gets the asyncio executor instead
and its concurrency is the application's own awaits. An unmounted `--realtime`
is NOT an exception any more: it gets the WSGI pool, because a hold taken on a
pool thread is forwarded to the loop's registries for SSE and WebSockets alike,
and a realtime app is where one slow view costs the most. It answered 0 through
1.4.0 — the single loop the demo's smokes were written against — which put the
Quickstart's every view on the loop; the smokes that ran that shape now run
pooled, and `smoke-app-threads` spells the single loop as `--realtime
--blocking-threads 0`. A mounted server is decided per mount, and any WSGI
mount needs a pool whatever the others are — those threads are the only workers
parked on its lane. An explicitly-set variable, at any value, disables all of
it (`ServeOptions`'s `*_set` fields carry the distinction, mirrored on
`AppConfig`; `resolve_blocking_threads` in `src/cli.mojo` is the one place the
default is decided) — except that a mount set which cannot run inline keeps the
default unless `--blocking-threads` itself is set (`pool_is_default`, SPEC
M20). Three rules the pinned interop imposes and that the code depends on:

- **`std.python` binds no `bytes` API and no latin-1 decoder — but the
  unbound C API is still reachable.** (Re-probed on the 1.1.0 pin: neither
  `PyBytes_AsString` nor `PyUnicode_DecodeLatin1` is an attribute of
  `CPython`.) `Python().cpython()` has no
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
- **The per-request path is the raw C API, and the reason is now speed
  rather than a leak.** Through Mojo 1.0 a `PythonObject` call argument or
  `__setitem__` value leaked a reference each (measured; zero-argument
  calls, call results, `len()` and `String(py=...)` were clean), so the
  bridge's shape was a correctness requirement. Mojo 1.1.0 carries the
  upstream fix (modular/modular#6833) and the pin moved on 2026-09-18:
  measured in this tree against 1.0.0 as the null case, 1000 operations
  leak 1001 references there and 0 here. What survives is the
  measurement that made the C API worth it anyway — 14.9 µs/request to
  3.5 — so the rule stands as a performance rule: do not put a
  per-request `PythonObject` call argument or dict/attr assignment in the
  bridge, and keep `smoke-django`'s RSS guard at 0 KB over 10k requests,
  which now watches the steal discipline below rather than the toolchain.
  Startup-only calls (`set_app`) were the bounded exception and are now
  simply cheap.

  **The way in is the raw C API.** `Python().cpython()`
  reaches `PyDict_New`, `PyDict_SetItem`, `PyUnicode_DecodeUTF8`,
  `PyTuple_New`/`SetItem` and `PyObject_CallObject`, which refcount
  explicitly and cost no `PythonObject` round trip. The bridge builds each
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
    since `Py_Initialize` ran on it. With no handler pool that thread calls
    the application inline, so it stays attached while it works and
    **detaches around every wait** (`DetachingBackend` without
    `set_loop_detached`, in `main`'s inline branch): it used to block in
    `kevent`/`epoll` holding the GIL, and a thread the application started
    — an agent turn publishing progress, an `asyncio.run` in a
    `threading.Thread` — ran only when a request happened to run Python
    (#310; 1 tick in 1.5 s idle where 150 were due, under `--realtime`,
    `--blocking-threads 0` and `--workers 2` alike). `poe
    smoke-app-threads` (SPEC E20) is the gate. `WorkerSupervisor` is wired in
    (`packages/m0-wsgi/m0serve.mojo`) and the rule it obeys is load-bearing:
    **fork before the first Python call, never after.** Mojo initializes the
    interpreter lazily, so each worker's own `WSGIApp` construction after
    `fork_all()` returns is that first call — keep it there.
    **`--spawn-workers` is the escape from the fork rule's other half**
    (platform runtimes are off limits after `fork()` without `exec`): the
    child still forks, then `execv`s this binary with
    `M0_WORKER_INDEX`/`M0_WORKER_SPAWNED` set, and `main` runs again from
    the top as a worker that binds nothing — it adopts the listener
    (`M0_LISTEN_FD`), the bus socketpairs (`M0_BUS_READ_FDS`/
    `M0_BUS_WRITE_FDS`) and the shared page (`M0_SHARED_ID_FD`; an
    anonymous mapping dies at exec) by fd
    number, and re-exports `M0_SHARED_ID_ADDR` for its own address before
    Python starts -- `m0_http.prefork` makes, exports and adopts all three,
    for the Mojo host as much as for `m0serve` (SPEC E24). The page is
    file-backed in EVERY mode since #322, and
    carries a magic word in slot 2 (`SHARED_PAGE_MAGIC`): a child process
    an application starts execs too, and `m0pub` numbers only from a page
    it has verified -- mapped from `M0_SHARED_ID_FD`, or at an address the
    kernel reports readable (a pipe `write`, never `mincore`, which
    succeeds for unmapped addresses on macOS) -- because an inherited
    address was a SIGSEGV on Linux and a silent write into the child's own
    memory on macOS. `m0pub.child_fds()` is what a child is handed, as
    `pass_fds`: every descriptor the server creates is close-on-exec
    (SPEC G16), so nothing of the server's reaches an exec'd child any
    other way, and m0pub writes only to a bus fd whose device and inode
    match `M0_BUS_WRITE_IDS`, which `prefork_bus` exports beside the
    numbers. The spawn's own exec keeps exactly the fds
    `spawn_inherited_env` names: `_exec_if_spawning` clears the flag in
    the forked child just before `execv`, and the new image sets it again
    on each one as it adopts it. A descriptor a future spawned worker must
    inherit goes in that list, or its adoption fails loudly.
    Core ML cannot run in a forked child at all
    (docs/notes/coreml-embeddings.md), which is what this exists for.
    Neither can MAX's parallel runtime, and that one is refused rather
    than crashed: a Mojo mount that calls `parallelize` links
    `libAsyncRTMojoBindings`, and `--workers N` above 1 or `--reload`
    (a supervisor over even one worker, forked) exits 2 before the bind
    naming `--spawn-workers`, `--doctor` failing the same check
    (`workers-vs-parallel-runtime`; `parallel_runtime_forked` in `cli.mojo`
    is the one predicate both read, in `pg_listen_forked`'s shape, both
    asking `forks_without_exec`, its truth table pinned by
    `test_cli.mojo`; SPEC E33, D51,
    `smoke-serve-parallel-runtime`). The fact is
    `m0_http.parallel_runtime_linked`, the function the Mojo host reads
    for E32, so the shipped `bin/m0serve` passes the check unlinked.
    Measured with the refusal removed: `/par/ser` answered from the
    forked worker, `/par/par` never, and the pool thread it took was
    abandoned at the drain's 5 s bound
    (docs/notes/m0serve-and-the-runtime-a-fork-cannot-carry.md). On
    macOS the toolchain links that library into EVERY build made beside
    an installed `max-core`, source or no source (CI, 2026-09-25: the
    demo-mount `bin/m0serve` bundled three runtime files without MAX and
    four with it; Linux three either way), so there every binary reads
    as linked and both refusals fire for a MAX-free one — a ROADMAP
    Known issue; the gate's control reads the file's load commands and
    holds the doctor to them rather than assuming. `mojo run` is the same
    trap on Linux (measured 2026-09-26): the program runs inside the
    compiler's process, which maps the runtime once `max-core` is synced,
    so a JIT'd program reads as linked whatever it imports. A test that
    asks the host a question about workers therefore supplies the fact
    (`parallel_runtime=`) or follows it, never assumes it —
    `test_host.mojo` assumed it and failed with the group synced — and a
    smoke that `mojo run`s a host app at two workers exits 78 there.
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
    objects are the measured 0.7x cliff (`docs/notes/wsgi-vs-asgi-history.md` §5); keep
    per-request state thread-local. `print`/`log_access` from N threads can
    interleave — `x-thread` is on every response for that reason.
  - **The asyncio executor (`m0_wsgi.asgi_executor`; the ASGI default).**
    One Python thread per event loop runs the bridge's persistent asyncio
    loop, fed through the same `OffloadPool` the handler pool speaks — the
    loop parks and submits, `add_reader` on the submit fd turns slots into
    tasks, completions answer via `put_response`/`complete`. Rules:
    attach once for the thread's life like a pool thread, but park
    ATTACHED inside `run_until_complete` (CPython's selector releases the
    GIL there — that is the executor's detach); **the executor cannot run
    on a free-threaded build** — `PythonModuleBuilder` writes `PyObject`
    with the GIL build's 16-byte header and 3.14t's is 32
    (modular/modular#5726), so `m0serve` refuses an ASGI app there with
    exit 78 (`asgi_free_threading_refusal`; ROADMAP Known issues) and an
    ASGI app under `--threads` is impossible on this toolchain; the Mojo loop holds no thread state (the pool bullet's rule); every Python object stays owned by the executor
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
    chunk-split SSE event with a comment inside is corrupt). Every stream
    frame carries its stream's GENERATION in the bus frame's id and an
    app that raises after its head sends `stream_abort`, not
    `stream_end` — the rules are spelled out under the pool bullet below,
    because a pool thread is now the channel's second producer and both
    obey them. WebSocket scopes use the same seam — the held
    101 is only released behind its begin frame, outbound frames ride
    the chunk channel, inbound ones are tagged submit-channel datagrams
    — and a handshake the app never answers must resolve as a 403, never
    a leaked slot. An app's close is ONE datagram, its Close frame inside
    the `x` end marker (`ws_close_frame`): sent as a `w` and then an `x`,
    the loop wrote the Close before it knew the socket was ending, and a
    peer reply read in between was echoed as a second Close (CI, twice;
    never under load, only when the executor lost its CPU between the
    sends). A HEAD never streams, and neither does a 1xx, 204 or 304:
    `_Cycle.send` answers one at its first streamed body with its head
    alone and drops the rest (SPEC L27), because the loop frames none of
    them and wrote that body raw where a keep-alive connection's next
    response begins (10,000 of 10,000 bytes, measured). The loop sends no
    disconnect for an answer, so the early answer tells the application
    itself: it resolves the slot's disconnect future, which wakes a
    receive() parked before the first body (Starlette's, Django's), and an
    application that parked none is cancelled after `_HEAD_GRACE`.
    Unstopped, an endless body ran for the life of the process. The
    loop's `_finish_response` holds the same line for a hold or a native
    stream opened on a HEAD. The buffered escape hatch keeps its send()-side
    watchdog — do not "fix" it by lengthening the
    grace (docs/notes/wsgi-vs-asgi-history.md §8). **The pump is batched in both directions**, because the
    hello-world deficit was wakeup-bound, not CPU-bound (0.72x uvicorn at
    0.89 cores; batching is worth +5% at 16 connections, where a
    pass batches ~3 submits, and +19% at 256): the loop BUFFERS its submits to an executor lane during a
    pass and sends them at the bottom of it as one `TAG_JOB_BATCH`
    datagram (`[4][slot i64] x n`, length ≡ 1 mod 8 — no plain job is, and
    the tag separates it from every other shape; a single slot still goes
    as the legacy 8-byte job), and the executor QUEUES its completions
    over a pump pass and pokes the loop once (`complete_many`, `k` bare
    8-byte slots in one datagram; the blocking pool's `complete` is the
    `k = 1` case). Three rules keep the streaming seam's order intact: a
    begin frame (`b`/`B`) still goes out immediately and its head is
    queued behind it; every NON-begin chunk frame (`s`/`e`/`w`/`x`) is
    preceded by a flush of the queued completions, so a chunk can never
    overtake a completion it used to follow; and a buffered submit is
    never left across a `wait` — `_flush_submits` runs at the bottom of
    every pass, before the shutdown drain parks, and once more before
    `run_event_loop` returns so the pill stays FIFO behind every job.
    What a batch cannot carry runs INLINE (`_run_inline`, the queue-full
    tail `submit`'s False always meant); "leave it buffered and retry" is
    not an option, because a buffered slot is invisible to everything that
    reads `offloaded` as "a worker owns it". Pool lanes are never batched —
    one thread takes one job — and `next_job` says so loudly if a batch
    ever reaches one. **Python calls INTO Mojo for every event, and the
    executor thread never leaves `run_forever`.** `ExecutorPort`
    (`asgi_executor.mojo`) is a Python type built with
    `PythonModuleBuilder` inside the interpreter this binary embeds — no
    shared library, no `PyInit_`, no ctypes; a call costs ~70 ns — and set
    into the shim as `_port` before the submit reader exists. Every event
    the shim used to queue for a Mojo pass (`('job', slot)`, `('done',
    ...)`, `stream_*`, `ws_*`) is `_port.dispatch(ev)`, handled at once on
    the executor thread inside the loop iteration that produced it; the
    Mojo side of the thread is *build the handler, build the port, park in
    one `run_forever`, flush, shut down*. A `run_until_complete` per pass
    cost 38 µs on stdlib asyncio and 64 on uvloop — the shape uvloop is
    built not to pay — and is gone. Completions are parked as before and
    poked to the loop once per loop iteration by `_port.flush`, which the
    shim schedules with `call_soon` on the first event of an iteration:
    batching without a batch buffer, uvicorn's write-coalescing shape.
    Three rules: the port's methods run ATTACHED with the GIL, exactly
    where the pass used to run, so a send that may block detaches first
    (`_send_chunk_frame`, `_flush_completions`) and the seam's ordering
    (begin frame before its head is parked; a flush before every
    non-begin chunk frame) is inside `dispatch`, unchanged; the bound
    type holds four integers and reaches its tables through
    `ExecutorState` by address, because `add_type` wraps `__repr__`
    through a `Writable` the compiler DERIVES from the fields (an
    explicit `write_to` does not stop it, and the derivation recurses into
    element types — `HTTPResponse`'s cookie jar holds a `Dict`, which is
    not `Writable`, so no container of responses can be a field); and
    the pill only sets `stopping` — the shim then runs the
    in-flight tasks (their events dispatch as they finish), bounded:
    sockets are cancelled after `_WS_DRAIN_GRACE`, everything else after
    `_HTTP_DRAIN_GRACE` (3 s), and a task that swallows its cancellation
    is named and left behind (SPEC D11) — then it stops the loop, so the
    executor's final flush and lifespan shutdown run after `run_forever`
    returns. Two rules: the drain starts ONCE (`_exec_draining`; a second
    pill, or the inverted tick, must not start another whose stop lands
    inside lifespan shutdown), and once it has stopped the loop nothing
    reaches the port (`_exec_closed`) — the Mojo side frees its executor
    state as `run_forever` returns, and lifespan shutdown steps the loop
    again, so a task left behind that answered then was a segmentation
    fault. `smoke-asgi`'s outlive-the-drain and background-forever phases
    and its 10k-request RSS guard pin the shape.
    **Under `M0_INVERTED` the port runs the loop's passes, and never one
    inside another** (SPEC L31). The backend keeps ONE event buffer, which
    the outer pass is still walking by index, and a pass accepts
    connections: a wait inside a pass overwrote the events the outer one
    had not reached (a new connection's accept, and on epoll a keep-alive
    request, never reported again), and an event it still held could name
    a descriptor a new connection had since been given. An eager task
    factory puts a task's first step inside the pass that read its
    request, so a `dispatch` can be inside a pass. That is why a full
    chunk channel is handed to the loop's handler (`_deliver_bus_frames`,
    in channel order) and never made room in by running a pass, and why
    the port refuses loop work (a pass, a drain step, a flush's
    completions) while some is on the stack and names it in the log. The
    flag is `ExecutorState.in_pass`, reached by address: the port and the
    backend are copied into each call and stored back, so a flag on
    either would be invisible to the nested call and erased by the outer.
    `scripts/nested_pass_probe.py` builds that batch in the inverted
    `smoke-asgi`.
    **A slot's per-slot state in the shim belongs to the slot's CURRENT
    task** (`_exec_slot_task`), never to the slot: the loop recycles a
    slot the instant it closes a connection, and the previous task is
    still alive for an iteration or two (its cancellation lands at its
    next await, its done-callback an iteration later), so a stale task
    finishing late used to wipe the live task's credit window and event,
    and a disconnect left on the SLOT made the successor cancel its own
    stream and skip its end signal — a subscribed stream with no producer,
    which the client sees as a 30 s stall with a clean server log. Rules:
    cleanup runs only if the finishing task is the owner; a disconnect is
    stamped on the owning task (`_m0_disconnected`) and the old
    connection's in-flight bytes are refunded to the global window right
    there; a socket's accept and its own close are ITS OWN (closure state
    in `_serve_one_ws`, never keyed by slot — read by slot they were the
    next client's), and after its own close it may send nothing and
    `receive()` answers the disconnect; the loop tags EVERY connection an
    executor produced (`exec_lane`, recorded at the `b`/`B` begin frame,
    because an app's own close and `_end_socket` unsubscribe before the
    connection ends, and routed by that lane because the unsubscribe
    erased the channel name); every "am I gone" check asks
    `_task_gone(owner)` about the task that owns the connection a send
    ADDRESSES (stamped, or finished), never the caller's — `send` and
    `receive` are closures an application calls from any task, and judged by
    the caller a gone client's kept `send` wrote into the next client on its
    recycled slot (FastAPI's documented chat room delivered a departed
    client's messages to a stranger) while a disconnect hook's sends to live
    sockets were refused
    (SPEC L20); a send to a gone socket raises `ClientDisconnected`, one to
    a gone stream is a yielding no-op; a WebSocket is told of its client's
    departure through `receive()` and never cancelled for it — FastAPI's
    `except WebSocketDisconnect:` cleanup runs only if the task survives —
    so the drain gives in-flight tasks `_WS_DRAIN_GRACE` and then cancels
    the sockets still running (L21); a response is answered at its FINAL
    body, not when the application returns, because Starlette runs
    background tasks after it inside the same call (L22), and a late
    exception goes to the log alone — and once it is over a send answers
    nothing (a leftover task answered the slot's NEXT request) and
    `receive()` says `http.disconnect` at once; and
    the STREAMING mark and the cancellable stream task go on the slot's
    owner (`_exec_slot_task[slot]`), never `asyncio.current_task()` —
    Starlette (so FastAPI and FastHTML) produces a `StreamingResponse`
    body inside an anyio task group, so `send` arrives from a child task,
    and marking the child left one `TypeError` traceback in the log per
    streamed response while the body itself arrived intact. Found
    on CI's macOS smoke (1 in 2), reproduced 8 of 11 runs under twelve
    CPU hogs — `chunked_keepalive.py`'s HTTP/1.0 probe closes after the
    head and the keep-alive stream that follows lands on the same slot —
    and traced to this ordering; 0 of 6 under six hogs (the plain build: 4 of 5) after.
    **Two guards hold it, and the split is deliberate.** `poe test-shim`
    is deterministic and IS in CI (inside `test-all`): the shim is a
    Python file, `packages/m0-wsgi/shim/m0_shim.py`, rendered by
    `scripts/render_shim.py` into the Mojo constant `SHIM_SOURCE`
    (`src/shim_source.mojo`, generated and committed; `check-docs` fails
    when it is stale, and the same check proves the literal decodes back
    to the file byte for byte), so `scripts/shim_ownership.py` reads the
    file, execs it, and drives it through real
    socketpairs exactly as the loop does — no server, no Mojo, no
    threads. Four of its six tests fail on the pre-fix shim, and
    `--sabotage` reverts each rule in the source and insists
    the suite fails for every one, so a renamed or deleted guard line is
    itself a failure. Edit the `.py`, run `poe render-shim`, commit both;
    `poe lint-shim` is pyflakes over it, which is why it is a file at
    all (docs/notes/shim-language.md says why it stays Python). `poe stress-asgi` is the timing half and is
    deliberately NOT in CI (round 5 of 15 on the broken build, 45 of 45
    on this one) — shared runners cannot reproduce this reliably, which
    is exactly why CI passed with the bug live; it is a pre-release step
    (docs/RELEASING.md). Each of its rounds runs `chunked_keepalive.py`
    and then `ws_probe.py`, so the WebSocket handshake lands on the slot
    the streamed connection just released, and the whole thing runs
    twice — on the pump and under `M0_INVERTED=1`, which the mode
    asserts from the banner rather than trusting the variable. The
    WebSocket half is not decorative: with the `websocket.send` credit
    gate reverted the streamed rounds passed 30 of 30 and the WS round
    failed on the first. **Every frame this seam cannot place is
    terminal and named** — the result of `_send_chunk_frame` is never
    discarded, and neither is `queue_frame`'s refusal in the loop
    handler's `s`/`w` branches. Each was measured both ways: a dropped
    begin frame served a clean EMPTY 200, a dropped end frame hung the
    client to its own timeout against a silent log, and a refused
    WebSocket frame delivered 430,693 of 1,638,400 bytes under a clean
    close frame. The recoveries differ because the shapes do: a begin
    that never lands must not be followed by a streaming head (500,
    close, and a disconnect tag to this executor's own lane, since the
    loop never saw a stream and will send none); anything after the head
    aborts, so the client sees truncation rather than a short body under
    a clean ending; and the loop-side refusal ends a WebSocket through
    `asgi_done` rather than `abort_stream`, because a socket's outbox is
    unframed and those queued bytes are real. **An abort now reaches a
    socket at all**: the loop's abort path gated on `slot_sse`, which a
    held 101 never sets, so aborting one was a silent no-op — it reads
    `slot_sse or slot_ws`, and a 101 records its generation AFTER the
    non-stream branch's `clear_stream`, which was wiping it. Give-up is
    claimed ONCE per stream
    (`ExecutorState.lost`, `WSGIHandler.stream_lost`): the producer does
    not learn its connection is gone until the loop closes it, so one
    flooding socket announced itself 336 times before. And a **drain ack
    is clamped to the window, never merely added** — an ack names a slot
    and carries no generation, so one for the stream that just ended can
    land after the next stream on that slot has seeded its window whole,
    and `credit + in flight == the window` is the invariant that keeps N
    streams from over-committing the one chunk channel they share.
    **`websocket.send` is credit-gated too**, on the same window, seeded
    at `websocket.accept` and awaited in the shim's `send` — without it an
    app faster than its client filled the loop's 64 KB outbox and the
    frames it then refused were messages the peer could not know it had
    missed (430,693 of 1,638,400 bytes under a clean close). The loop was
    already acking a socket's drained bytes (a WS slot on an executor lane
    answers `slot_channel_stream`); only the window to credit them to was
    missing. Charge ENCODED frame bytes, never payload bytes —
    `_ws_frame_bytes` mirrors `encode_ws_frame`'s unmasked 2/4/10-byte
    header, and charging the payload drifts by that header on every
    message, threefold on one-byte sends. A message over
    `MAX_PENDING_BYTES` is still refused by the outbox (its cap bounds one
    frame as well as the queue), and a `--realtime` hold on a WSGI lane
    has no window because the loop does not ack those sockets; `_ws_spend`
    returns uncharged there rather than pretending to gate.
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
    - **The loop holds NO thread state while it serves** (`_serve_offloaded`
      releases it once before `run_event_loop` and restores it once after;
      `DetachingBackend` told `set_loop_detached` is a plain wait). It used
      to re-attach after every wait, and was measured blocked in that
      `PyEval_RestoreThread` 36–45 % of wall time under load — GIL-bound,
      not I/O-bound, so its parsing and writing never overlapped the
      Python threads' work; detached, the executor and pool rows ran
      +50–100 % (docs/notes/detached-loop.md). The one place the loop runs
      Python is the inline fallback, and `WSGIHandler.func` attaches for
      itself there (`attach_in_func`); nothing else on the loop's handler
      may touch a `PythonObject`. `M0_LOOP_ATTACHED=1` is the A/B knob.
    - **Pool threads detach around the blocking `recv` and attach per job**,
      and build and destroy their handler inside an outer attached region.
      Same discipline as a serving thread, same reason. **A thread that has
      held its run for a millisecond and drops the GIL while another pool
      thread is parked waiting for it yields until that thread has
      attached** (`_yield_turn`, `TURN_SLICE_NS`, two atomic counters at
      `BLK_TURN_ADDR`): with the loop no longer a GIL waiter on every pass,
      nothing else forces CPython's 5 ms switch, and a thread that finishes
      a job otherwise re-takes the GIL before the thread it signalled runs —
      a fast-route max of seconds under a CPU-bound view with four threads.
      Counters, not a token queue: one token left the GIL idle while the
      next taker woke from the kernel, and N−1 tokens gave no order once
      some threads were asleep inside views. A slice, not every job: a
      hand-off is a thread switch, 15 % of a 200 µs view's throughput when
      paid per job. A view that blocks holds nothing; a pool of one has no
      barrier. `poe probe-pool-fairness` (SPEC E11) is the gate, on every
      pull request on Linux in the `pool-fairness` job and on the reference
      Mac before a release, and `M0_POOL_TURN=0` is its negative arm. It
      judges ORDER, requests passed over by later ones, never latency: a
      pause of the whole process delays every connection at once and passes
      nobody over, and the latency bounds it judged first sat near both a
      fair run's max and the old shapes' figures
      (docs/notes/fairness-judged-by-order.md). **And inside its slice a thread does not drop the GIL
      at all while a job is queued** (`OffloadPool.try_next_job`, which
      never waits, so it may be called attached; SPEC E34,
      docs/notes/a-slice-keeps-the-gil.md): each drop between jobs woke a
      parked waiter that found the GIL re-taken and queued again BEHIND
      the others, so the slice's hand-off went back to the thread that had
      just held it — two threads alternating while two starved, 0.3–1.6 s
      at a time on 4-vCPU Linux, which the pre-release run first took for
      a VM's noise. Never pop the next job by dropping and re-taking the
      GIL on a pool thread. `M0_POOL_TURN_KEEP=0` is the A/B knob, and the
      probe's keep arm, which must starve a waiter, on every pull request.
      The probe's load is chosen for that arm: with the rule off, each drop
      inside a slice sends the waiter it woke to the back, so who starves
      depends on how many jobs a 1 ms slice holds against how many threads
      wait. A 0.65 ms view against five threads starves two of them on every
      machine measured, where the first load's 0.3 ms view sat on the
      boundary between three jobs and four, and each machine's own overhead
      decided whether it starved (docs/notes/fairness-judged-by-order.md).
      Change the view or the thread count only with that count in hand; the
      fair arm records a request's share of the GIL against the window's
      1 ms edge.
    - **Jobs and completions ride in-memory rings; the socketpairs carry
      only wakes and payloads** (`lightbug_http/ring.mojo`; the protocol
      is `offload.mojo`'s module docstring; the measurement is
      docs/notes/pool-ring-handoff.md). The rule is an ORDER on each
      side. A pool thread whose ring is empty spins `POOL_SPIN_NS`, then
      counts itself parked, re-checks the ring, and only then blocks in
      `recv`; `submit` pushes, then reads that count, and pokes the lane
      only if it is non-zero. The loop raises its own flag before
      `backend.wait` and re-checks the completion ring after raising it
      (`_wait_for_events`); `complete` pushes, then reads the flag, and
      pokes the completion channel only if it is set. Announce, re-check,
      block — and push, read, poke — every step sequentially consistent:
      reorder either sequence and a wake is lost, which is a request
      answered a second late or a pill never read. Pills, inbound
      WebSocket messages, stream aborts and every executor datagram still
      ride the sockets, and reach a thread that never runs dry through its
      non-blocking poll once per `POOL_DGRAM_POLL_NS`. The loop's flag
      starts SET and the inversion's driver never clears it, so that path
      keeps the datagram per completion it always had. Worth +16 % rps at
      16 connections and +19 % at 256 on bare WSGI with one handler
      thread: the loop's per-request cost went from 7.5 µs to 6.3 at c16
      and 5.3 at c256, tokio's figure. The pool thread shows MORE CPU than
      its work afterwards, because a spin is a core spent not paying a park
      and a wake per job. `M0_POOL_RING=0` is the A/B knob.
    - **The wake is elastic: one thread until a job has waited**
      (docs/notes/elastic-pool.md; the rules are the "elastic" section
      of `offload.mojo`'s docstring). The zero-config pool of eight
      served a trivial view at 0.67x the one-thread rate on 1.6x the
      cores, because a burst was taken by every thread awake and they
      serialized on the GIL with an OS wake per hand-off. Now only ONE
      idle thread per lane spins and the rest park at once; `submit`
      wakes nobody while any thread of the lane is busy or spinning (it
      takes the job sooner than a wake could land) and exactly one when
      every thread is parked; and a ring that holds a job and has NOT
      been drained for `POOL_WAKE_AGE_NS` (200 µs) is behind a slow
      view, so the LOOP wakes a parked sibling for it — `wake_aged`,
      once per pass, with `_wait_for_events` capped at
      `POOL_WAKE_WAIT_MS` while any job is pending. Progress, not age,
      and the ring's pop counter is the signal: a ring 256 deep behind
      one thread has a head a millisecond old and moving every 4 µs, and
      waking for its age put eight threads on the GIL for a queue one
      thread drains faster (0.90x at 256 connections, 400 such wakes a
      run) — and watching for the same job at the head is no better
      there, a pass being longer than `T` at that concurrency. A pop
      count that moved since the loop last looked is a lane being
      drained, however deep, and is left alone; one that did not has
      waited since the later of its head's push and the last look that
      saw it move. **Without a GIL the pool is parallel instead**
      (`OffloadPool.set_parallel`, set by `_serve_offloaded` from
      `probe_free_threading` and by the threaded mode unconditionally;
      `M0_POOL_PARALLEL` is its knob): `submit` wakes a parked thread
      whenever there is one and the stall check counts from the push,
      because a parked thread beside a queued job is an idle core there,
      not a GIL waiter — measured on 3.14t, where the GIL rules held the
      fast route's p99 at 8–10 ms under slow views against 2–4 with eager
      wakes, and neither variant of the stall check moved it. **A Mojo or
      hold mount's lane is GIL-free on any interpreter**
      (`set_lane_gil_free`, marked by `wire_offload`): its stall check
      counts from the push against the idle spin
      (`POOL_FREE_WAKE_AGE_NS`, 10 µs), but its `submit` stays elastic —
      the progress rule held a Mojo compute route to one of four threads
      (15k rps against 42k), and eager wakes cost the trivial probe 21 %
      (SPEC M25). The single
      spinner and the wake by name on each thread's own channel apply
      either way. That check replaced the chained wake (`_chain_wake`, a
      thread that took a job poking a sibling for the rest; kept for the
      knob-off arm) and closes the hole it filled — a woken thread's
      socket poll eating a sibling's wake, a hold registering 1.5 s late
      on Linux CI — every pass instead of once. **Each pool thread parks
      on a wake channel of its OWN and the loop wakes the one that parked
      LAST** (`register_thread`, `_wake_registered`): with N receivers
      blocked on one socket macOS wakes all of them (one datagram into
      eight costs 59 µs of CPU against 3 into one, measured) and Linux
      wakes the oldest, round-robin — either way a cold thread and a
      cold interpreter thread state per job, and the rest of the gap.
      Pills go to those channels (`stop`), and a `TAG_WS_MESSAGE` on the
      lane socket is followed by a wake to a parked thread, which polls
      the socket first thing. What must not change: announce, re-check,
      block on the pool side and push, read, poke on the loop side —
      every transition into spinning or parking re-checks the ring AFTER
      announcing itself, which is what lets `submit` read three counters
      non-atomically and skip the wake. `M0_POOL_ELASTIC=0` is the A/B
      knob (every idle thread spins, every push into a parked lane pokes
      the lane socket, the chain), `M0_POOL_WAKE_AGE_US` the threshold
      for measurement, and `M0_POOL_DEBUG=1` prints each lane's wake
      counts by site at shutdown — the instrument that told a cascade of
      aged wakes (27 in 11 s) from the 132k idle wakes that were the cost.
      **Every pool that serves a lane obeys these rules, not only the WSGI
      one**: `MojoPool` threads register, pass their id to `next_job` and
      unregister, and `wire_offload` reserves records for every pool
      before starting any (`reserve_threads` sizes on its first call).
      **Both pools register in `start`, on the spawning thread, never in
      the thread body**: `stop` pills registered threads by name and the
      rest on the lane socket, so a thread that registered after a racing
      `stop` parked on its own channel with its pill on a socket it no
      longer reads, and the join waited out its 5 s bound
      (`test_blocking_pool.mojo`, `test_mojo_pool.mojo`). A
      pool that skips registering reads as all-parked, wakes on nearly
      every push, and gets slower as it grows — the Mojo mount's did, 202k
      wakes and a fifth of its throughput at eight threads (SPEC M22).
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
      subscription. The order is the LOOP's to keep, not the kernel's:
      `_complete_one` drains both bus channels before finishing any
      streaming head or 101 a completion delivered, and the frame — sent
      before the completion — is in its socket by then, so the
      subscription precedes the head deterministically. It used to rest on
      the completion being an event in the same batch as the frame's
      readiness; with the ring a completion is not an event. (For a hold
      the old order was already harmless — the outbox sweep closes an
      unsubscribed flagged slot only for an executor's stream — so this
      is hardening; the Linux failure the ring's first CI run produced in
      smoke-django-realtime phase 5 was a lost pool wake, the chained
      wake in the ring bullet above.)
      An ASGI mount does bring an end-of-stream signal, but the loop reads
      it per slot and only for slots an executor produced. A WebSocket hold
      works here too: the pool thread performs the 101 (the client's key is
      in the request it holds) and sends an `H` frame, and the inbound half
      rides the submit channel back as a `TAG_WS_MESSAGE` datagram — the
      executor's shape plus the CHANNEL, because a pool thread's own
      registries are empty. `ws_message` asks the pool question FIRST: on a
      mixed mounted server `asgi_notify_fd` is set for the ASGI mount, and
      asking that one first hands every socket's message to an executor
      that never accepted the connection (docs/notes/hold-on-a-pool-thread.md).
    - **A pool thread streams an unsized WSGI iterable, as a second
      producer on the executor's chunk channel.** The shim decides
      (`_lazily_produced` in `shim/m0_shim.py`): an app-supplied
      `Content-Length`, a list/tuple/bytes body, a Django `HttpResponse`
      (`streaming is False`), a bodiless status or an `M0-Hold` header all
      buffer as before — which is what keeps every framework page
      byte-identical on the wire; anything else streams, and only where
      `set_stream_capable` was set: pool threads with a chunk fd, never
      the loop's own handler. A HEAD to what would stream is answered at
      the body's first item and the body closed (SPEC K13): joined, a
      body that never ends never answered and held its thread for good.
      The rules that make it safe, each pinned by `smoke-wsgi-stream`:
      - The thread registers its OWN ack pair per slot
        (`OffloadPool.set_slot_ack_fd`, BEFORE its `P` begin frame, whose
        send publishes the write) and keeps the pair for the process's
        life (its fd number rides in the frame); the LOOP clears it at
        accept and where the stream ends (`OffloadLoopState.clear_stream`)
        — a stale entry would make a later `M0-Hold` on that slot look like
        a channel stream, the phase-6 silent-wrong.
      - Begin before head, exactly the executor's order — and the loop now
        drains the chunk channel inline before finishing any channel-stream
        head, so the argument no longer rests on kernel ready-list order.
        The head carries an EMPTY body: `_finish_response` writes
        `body_raw` before any `size CRLF`, so a first chunk there would go
        out unframed.
      - Stop-and-wait credit (`STREAM_PIECE`), with a NON-BLOCKING ack poll
        before every piece: a stream of small events never exhausts the
        window, and the disconnect — `(slot, -1)` on the thread's own pair,
        sent by `sse_slot_disconnected` for a `P` url — rides the same fd.
        `Int(Int32(UInt32(0xFFFFFFFF)))` is 4294967295 on this toolchain,
        which is why `_i32` exists.
      - Every frame carries its stream's generation (`stream_gen_seed`:
        executors `lane + 1`, pool threads `1024 + index` — disjoint ranges,
        no shared counter) and the loop handler drops an `s`/`e`/`w`/`x`
        whose generation is not the subscription's. A slot freed by one
        producer and re-subscribed by another has no FIFO between the two
        writers; this is the hole one channel cannot close.
      - A generator that raises after its head sends `TAG_STREAM_ABORT`
        on the completion channel; the loop handles aborts AFTER that
        batch's completions (an abort follows its own head on that FIFO,
        and the head is what makes the slot a stream with a generation to
        check against `HTTPResponse.stream_gen`), flushes what the producer
        managed to send, and closes without a terminator.
      - `enable_stream_channel` creates the chunk pair alone;
        `stream_active()` still means "an executor exists"
        (`enable_base_stream_ack`) and `slot_is_executor` stays lane-only.
        `slot_channel_stream` is the per-slot question the loop's four
        stream decisions ask; the drain-ack gate asks `chunk_active()`.
    - **A generator that blocks without yielding holds its pool thread
      until it yields, and the client leaving does not wake it.** The
      disconnect rides the thread's own ack pair and is read at the next
      piece, so a body asleep in `LISTEN/NOTIFY` for its 30 s idle timeout
      keeps its thread for those 30 s after the client is gone -- and
      eight such clients are the whole zero-config pool. Measured on
      textshelf under `config.wsgi` (docs/REAL_APP_VALIDATION.md, 2026-09
      finding 2): an abandon population stalled every other request to its
      timeout inside four seconds, while the same workload on the executor
      was clean. Nothing here can interrupt a generator from outside; the
      rule is a deployment one -- SSE views whose generators sleep run on
      the executor or as `--realtime` holds, never on pool threads -- and
      the bound below is about shutdown, not service.
    - **The shutdown join is bounded, and leaving is correct.** A response
      that never ends -- a generator that never yields again -- holds its
      pool thread for the life of the process, and `pthread_join` has no
      timeout. `stop_and_join(pool, JOIN_TIMEOUT_NS)`
      waits the same 5 s the drain gets (`ThreadSet.join_within` polls each
      thread's status slot, which a body writes last), then the process
      `_exit`s naming what it abandoned. Nothing here can unwind Python on
      another thread, so waiting longer only makes SIGTERM a no-op until
      `docker stop` sends SIGKILL.
    - Not refused on a GIL-enabled interpreter, unlike `--threads`: a waiting
      view releases the GIL, so the isolation is real there.
