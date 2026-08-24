"""The asyncio executor: one Python thread per event loop, real
await-concurrency for ASGI applications.

The buffered bridge (Phase 1) runs one ASGI request at a time to
completion, so an app that awaits a database holds its handler exactly as
a blocking WSGI view does, and concurrency comes from workers or pool
threads. This file is Phase 2: the same `OffloadPool` the blocking pool
speaks — the loop parks a request and submits its slot as one datagram —
but the receiver is a single thread running the shim's persistent asyncio
loop. `loop.add_reader` on the submit fd turns each slot into a task, so
thousands of requests overlap wherever the application awaits (uvicorn's
shape), and each completion answers through `put_response`/`complete`,
which any producer holding the pool's address may drive. The event loop
gains no code and no Python; its slot invariants (sweeps skip offloaded
slots, a disconnect leaves the provision borrowed until the completion)
already cover a response that arrives later from *anywhere*.

The structure deliberately mirrors `blocking_pool.mojo` — a `ThreadSet(1)`
against an `OffloadPool`, `PyGILState_Ensure` once for the thread's life,
serve split from the pthread body so every `PythonObject` dies inside the
attached region — because that file's discipline is proven. What differs
is the pump: instead of detach → block in `recv` → attach → run one job,
this thread parks *attached* inside `run_until_complete`, which is where
CPython itself releases the GIL (the selector's `Py_BEGIN_ALLOW_THREADS`),
so on a GIL build the detached Mojo loop and this thread interleave and on
a free-threaded build they simply run. Every Python object — namespace,
loop, queue, tasks, scopes — is touched by exactly one thread, so the
measured shared-object cliff (docs/WSGI_VS_ASGI.md §5) is avoided
structurally, not carefully.

Streaming is still refused here (the Phase-1 watchdog rides along in
`_serve_one_buffered`): Phase 3 is the chunk transport, not this file.
"""

from std.python import Python, PythonObject

from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.http import HTTPResponse
from lightbug_http.http.common_response import InternalError
from lightbug_http.offload import OffloadPool

from m0_http import (
    ThreadSet, ThreadBlock, BLK_INDEX, BLK_USER, BLK_STATUS,
    STATUS_OK, STATUS_RAISED,
)

from .app import WSGIApp
from .blocking_pool import BLK_POOL
from .cli import ServeOptions
from .handler import WSGIHandler
from .response import build_response
from .thread_handler import ThreadContext


struct AsgiExecutor(Movable):
    """One executor thread against one loop's `OffloadPool`.

        var pool = OffloadPool(config.max_connections)
        var executor = AsgiExecutor()
        executor.start(pool.addr(), opts_addr)
        run_event_loop(..., offload_addr=pool.addr())   # DetachingBackend
        executor.stop_and_join(pool)                     # detached, see below

    `stop_and_join` sends exactly one poison pill, because there is
    exactly one receiver — the same count-is-structural rule as
    `BlockingPool.stop_and_join`, degenerate at N=1.
    """

    var _set: ThreadSet
    var _started: Bool

    def __init__(out self):
        self._set = ThreadSet(1)
        self._started = False

    def __init__(out self, *, deinit move: Self):
        self._set = move._set^
        self._started = move._started

    def start(mut self, pool_addr: Int, user: Int) raises:
        """Spawn the executor thread. `user` is the `ServeOptions` address."""
        var body = _executor_body
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        var block = self._set.block(0)
        block.set(BLK_USER, user)
        block.set(BLK_POOL, pool_addr)
        self._set.spawn(0, body_addr)
        self._started = True

    def stop_and_join(mut self, mut pool: OffloadPool) raises -> Int:
        """One pill, then join. Returns 1 if the thread did not end cleanly.

        BLOCKS — detach from the interpreter around it, exactly as with
        `BlockingPool.stop_and_join`: the executor must attach-and-run to
        drain its in-flight tasks, and it cannot while the joiner holds a
        thread state and sleeps in `pthread_join`.
        """
        if not self._started:
            return 0
        pool.stop(1)
        self._set.join_all()
        return 0 if self._set.status(0) == STATUS_OK else 1


def _executor_serve(block: ThreadBlock) raises:
    """The executor thread's whole life, inside its attached region.

    Separate from `_executor_body` so the handler — and every
    `PythonObject` it owns, the asyncio loop included — is destroyed when
    this scope ends, before the thread state is released.
    """
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_POOL)
    )[]
    var opts = Pointer[ServeOptions, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )

    # This thread's own app, and THE lifespan for this loop: the module was
    # imported before this thread existed, so this is a sys.modules hit
    # plus a fresh shim namespace — the same economics as a pool thread's
    # handler. The event loop's fallback handler was built with
    # `lifespan=False`, so exactly one lifespan runs per event loop.
    var app = WSGIApp(
        opts[].module,
        server_name=opts[].host,
        server_port=String(opts[].port),
        attribute=opts[].attribute,
        multiprocess=opts[].workers > 1,
        multithread=False,
        protocol="asgi",
        lifespan=True,
    )
    # `for_options` rather than `make`: the mounts and health path are the
    # options', but `thread_index` stays -1 — one executor is not a pool,
    # and stamping `x-thread: 0` on every response would claim it is.
    var handler = WSGIHandler.for_options(app^, opts[])

    # The shim's loop reads the submit channel itself from here on. The fd
    # must be non-blocking: `add_reader` fires level-ish per readability,
    # and the drain-until-EAGAIN read inside the shim must never park the
    # whole loop in a blocking `read`.
    set_nonblocking(FileDescriptor(pool.submit_read))
    handler.app._bridge.executor_init(pool.submit_read)

    # Parallel to the slots: what `after_response` needs after the request
    # itself has crossed into Python. Only ever touched by this thread.
    var methods = List[String](capacity=pool.capacity)
    var paths = List[String](capacity=pool.capacity)
    for _ in range(pool.capacity):
        methods.append(String(""))
        paths.append(String(""))

    var stopping = False
    while True:
        # Parked attached, inside the shim loop's selector — which is where
        # CPython releases the GIL — while every spawned task progresses.
        var events = handler.app._bridge.wait_events()
        _pump_events(pool, handler, events, methods, paths, stopping)
        if stopping:
            break

    # The pill is FIFO behind every submitted job, so nothing new arrives:
    # run the in-flight tasks to completion, answer their events, then run
    # lifespan shutdown and let the destructors fire in this scope.
    handler.app._bridge.finish_executor()
    var leftover = handler.app._bridge.drain_events_nowait()
    var ignored = False
    _pump_events(pool, handler, leftover, methods, paths, ignored)
    handler.shutdown()


def _pump_events(
    mut pool: OffloadPool,
    mut handler: WSGIHandler,
    events: PythonObject,
    mut methods: List[String],
    mut paths: List[String],
    mut stopping: Bool,
) raises:
    """Answer one batch of shim events.

    `('job', slot)` parks nothing here: static mounts and the health path
    are answered immediately in Mojo (they must stay readable while the
    application is busy), everything else becomes a task via `spawn_asgi`.
    `('done', ...)`/`('err', ...)` park the response and poke the
    completion channel — park THEN poke, the same happens-before edge the
    blocking pool documents. A `('job', -1)` is the pill: it only sets
    `stopping`, because completions later in the same batch still need
    answering.
    """
    for i in range(len(events)):
        var ev = events[i]
        var kind = String(py=ev[0])
        var slot = Int(py=ev[1])
        if kind == "job":
            if slot < 0:
                stopping = True
                continue
            var request = pool.take_request(slot)
            methods[slot] = request.method
            paths[slot] = request.uri.path
            var early = handler.before_request(request)
            if early:
                var response = early.take()
                handler.after_response(methods[slot], paths[slot], response)
                pool.put_response(slot, response^, False)
                pool.complete(slot)
                continue
            var local = handler.serve_local(request)
            if local:
                var response = local.take()
                handler.after_response(methods[slot], paths[slot], response)
                pool.put_response(slot, response^, False)
                pool.complete(slot)
                continue
            try:
                handler.app._bridge.spawn_asgi(slot, request)
            except:
                # The spawn itself failed (environ build, task creation):
                # same policy as a raising handler — 500 and a closed
                # connection, because what it left behind is unknown.
                var response = InternalError()
                handler.after_response(methods[slot], paths[slot], response)
                pool.put_response(slot, response^, True)
                pool.complete(slot)
        elif kind == "done":
            var response: HTTPResponse
            var raised = False
            try:
                response = build_response(
                    handler.app._bridge, String(py=ev[2]), ev[3], ev[4]
                )
            except:
                response = InternalError()
                raised = True
            handler.after_response(methods[slot], paths[slot], response)
            pool.put_response(slot, response^, raised)
            pool.complete(slot)
        elif kind == "err":
            print(
                "asgi-executor: request raised: " + String(py=ev[2]),
                flush=True,
            )
            var response = InternalError()
            handler.after_response(methods[slot], paths[slot], response)
            pool.put_response(slot, response^, True)
            pool.complete(slot)


def _executor_body(arg: Int) -> Int:
    """pthread start routine: attach, serve, release, report."""
    var block = ThreadBlock(arg)
    ref cpy = Python().cpython()
    var gs = cpy.PyGILState_Ensure()
    var status = STATUS_RAISED
    try:
        _executor_serve(block)
        status = STATUS_OK
    except e:
        print("asgi-executor raised: " + String(e), flush=True)
    cpy.PyGILState_Release(gs)
    block.set(BLK_STATUS, status)
    return 0
