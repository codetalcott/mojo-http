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

from std.collections import Optional

from lightbug_http.broadcast import encode_bus_frame
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPResponse
from lightbug_http.http.common_response import InternalError
from lightbug_http.offload import OffloadPool
from lightbug_http.utils.owning_list import OwningList
from lightbug_http.websocket import (
    websocket_upgrade, encode_ws_frame,
    WS_OP_TEXT, WS_OP_BINARY, WS_OP_CLOSE,
)

from m0_http.sse.format import NO_EVENT_ID

from m0_http import (
    ThreadSet, ThreadBlock, BLK_INDEX, BLK_USER, BLK_STATUS,
    STATUS_OK, STATUS_RAISED,
)

from .app import WSGIApp
from .blocking_pool import BLK_POOL
from m0_http import BLK_LANE
from .cli import ServeOptions
from .handler import WSGIHandler, asgi_stream_url
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
    var _lane: Int
    """The submit lane this executor reads, so `stop_and_join` poisons the
    channel the thread is actually parked on."""

    def __init__(out self):
        self._set = ThreadSet(1)
        self._started = False
        self._lane = -1

    def __init__(out self, *, deinit move: Self):
        self._set = move._set^
        self._started = move._started
        self._lane = move._lane

    def start(mut self, pool_addr: Int, user: Int, lane: Int = -1) raises:
        """Spawn the executor thread. `user` is the `ServeOptions` address.

        `lane` is the submit lane this executor reads and the mount it
        serves — under `--mount` a sync application's pool threads are
        parked on other lanes at the same time, and a job must reach the
        worker that can actually run it. -1 is the unmounted server.
        """
        var body = _executor_body
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        var block = self._set.block(0)
        block.set(BLK_USER, user)
        block.set(BLK_POOL, pool_addr)
        block.set(BLK_LANE, lane)
        self._lane = lane
        self._set.spawn(0, body_addr)
        self._started = True

    def stop_and_join(mut self, mut pool: OffloadPool) raises -> Int:
        """One pill on THIS executor's lane, then join.

        Returns 1 if the thread did not end cleanly.

        BLOCKS — detach from the interpreter around it, exactly as with
        `BlockingPool.stop_and_join`: the executor must attach-and-run to
        drain its in-flight tasks, and it cannot while the joiner holds a
        thread state and sleeps in `pthread_join`.

        **The lane is load-bearing.** Under `--mount` this thread sleeps on
        its own mount's submit channel, and a pill sent to lane 0 goes to
        the pool threads instead — `next_job` has no timeout, so the
        executor never wakes and this join hangs forever rather than
        failing. That is exactly what a mounted server's SIGTERM did before
        this line named the lane.
        """
        if not self._started:
            return 0
        pool.stop(1, self._lane if self._lane > 0 else 0)
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
    var lane = block.get(BLK_LANE)

    # This thread's own app, and THE lifespan for this loop: the module was
    # imported before this thread existed, so this is a sys.modules hit
    # plus a fresh shim namespace — the same economics as a pool thread's
    # handler. The event loop's fallback handler was built with
    # `lifespan=False`, so exactly one lifespan runs per event loop.
    #
    # Under `--mount` this builds ONLY the mount on this executor's lane
    # (`only_mount`), for the reason a pool thread does: the sync mounts'
    # applications belong to the pool threads, and building them here would
    # run their lifespans a second time. `thread_index` stays -1 either way
    # — one executor is not a pool, and stamping `x-thread: 0` on every
    # response would claim it is.
    var handler = WSGIHandler.build(
        opts[],
        multiprocess=opts[].workers > 1,
        multithread=False,
        lifespan=True,
        only_mount=lane,
    ) if len(opts[].mount_prefixes) > 0 else WSGIHandler.for_options(
        WSGIApp(
            opts[].module,
            server_name=opts[].host,
            server_port=String(opts[].port),
            attribute=opts[].attribute,
            multiprocess=opts[].workers > 1,
            multithread=False,
            protocol="asgi",
            lifespan=True,
        ),
        opts[],
    )

    # The shim's loop reads the submit channel itself from here on. The fd
    # must be non-blocking: `add_reader` fires level-ish per readability,
    # and the drain-until-EAGAIN read inside the shim must never park the
    # whole loop in a blocking `read`. The ack fd (streaming credit) was
    # made non-blocking by `enable_stream_channel`, in the wiring, before
    # this thread existed.
    set_nonblocking(FileDescriptor(pool.submit_read_fd(lane)))
    handler.apps[0]._bridge.executor_init(
        pool.submit_read_fd(lane), pool.stream_ack_read
    )

    # Parallel to the slots: what `after_response` needs after the request
    # itself has crossed into Python, and — for a WebSocket handshake —
    # the ready 101 held until the application's `websocket.accept` comes
    # back. Only ever touched by this thread.
    var methods = List[String](capacity=pool.capacity)
    var paths = List[String](capacity=pool.capacity)
    var pending_101 = OwningList[Optional[HTTPResponse]](capacity=pool.capacity)
    for _ in range(pool.capacity):
        methods.append(String(""))
        paths.append(String(""))
        pending_101.append(None)

    var stopping = False
    while True:
        # Parked attached, inside the shim loop's selector — which is where
        # CPython releases the GIL — while every spawned task progresses.
        var events = handler.apps[0]._bridge.wait_events()
        _pump_events(pool, handler, events, methods, paths, pending_101, stopping)
        if stopping:
            break

    # The pill is FIFO behind every submitted job, so nothing new arrives:
    # run the in-flight tasks to completion, answer their events, then run
    # lifespan shutdown and let the destructors fire in this scope.
    handler.apps[0]._bridge.finish_executor()
    var leftover = handler.apps[0]._bridge.drain_events_nowait()
    var ignored = False
    _pump_events(pool, handler, leftover, methods, paths, pending_101, ignored)
    handler.shutdown()


def _pump_events(
    mut pool: OffloadPool,
    mut handler: WSGIHandler,
    events: PythonObject,
    mut methods: List[String],
    mut paths: List[String],
    mut pending_101: OwningList[Optional[HTTPResponse]],
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
            # A WebSocket handshake gets a `websocket` scope. The 101 the
            # loop's validator built is held here — the application
            # APPROVES with websocket.accept, this thread PERFORMS, the
            # same split as M0-Hold, for the same reason: the accept value
            # comes from the original request's key.
            var upgrade = websocket_upgrade(request)
            if upgrade:
                var probe = upgrade.take()
                if probe.status_code != 101:
                    # Malformed or wrong-version handshake: 400/426 verbatim.
                    handler.after_response(methods[slot], paths[slot], probe)
                    pool.put_response(slot, probe^, False)
                    pool.complete(slot)
                    continue
                pending_101[slot] = probe^
                try:
                    handler.apps[0]._bridge.spawn_asgi_ws(slot, request)
                except:
                    pending_101[slot] = None
                    var response = InternalError()
                    handler.after_response(methods[slot], paths[slot], response)
                    pool.put_response(slot, response^, True)
                    pool.complete(slot)
                continue
            try:
                handler.apps[0]._bridge.spawn_asgi(slot, request)
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
                    handler.apps[0]._bridge, String(py=ev[2]), ev[3], ev[4]
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
        elif kind == "stream_start":
            # ORDER IS THE CORRECTNESS HERE. The begin frame goes out on
            # the chunk channel BEFORE the head completion: its send
            # syscall returns before the completion's begins, so any loop
            # pass that can see the head can already see the begin — the
            # handler is subscribed before the slot ever shows up
            # streaming in a drain pass, which is what makes
            # "not subscribed" an unambiguous end-of-stream signal and
            # closes the wrongful-early-close race. It also anchors the
            # FIFO that keeps a recycled slot safe: every frame of this
            # stream sits between its begin and its end on one channel.
            var begin = List[UInt8]()
            var begin_frame = encode_bus_frame(
                asgi_stream_url(String("b"), slot), NO_EVENT_ID, Span(begin)
            )
            pool.send_stream_chunk(Span(begin_frame))
            # The head: an ordinary completion whose response is marked
            # streaming — _finish_response pops content-length, keeps the
            # connection, and flips the slot into streaming state once the
            # head is on the wire. From here this slot's bytes travel ONLY
            # as chunk frames; the completion channel is done with it.
            var response: HTTPResponse
            var raised = False
            try:
                response = build_response(
                    handler.apps[0]._bridge, String(py=ev[2]), ev[3], ev[4]
                )
                response.sse_streaming = True
            except:
                response = InternalError()
                raised = True
            handler.after_response(methods[slot], paths[slot], response)
            pool.put_response(slot, response^, raised)
            pool.complete(slot)
        elif kind == "stream_chunk":
            # Park-then-poke does not apply here: the chunk's bytes ride
            # IN the datagram, so the send is both the publish and the
            # happens-before edge. Retried, never dropped — a lost chunk
            # is a corrupt body.
            var chunk = handler.apps[0]._bridge.body_bytes(ev[2])
            var frame = encode_bus_frame(
                asgi_stream_url(String("s"), slot), NO_EVENT_ID, Span(chunk)
            )
            pool.send_stream_chunk(Span(frame))
        elif kind == "stream_end":
            var empty = List[UInt8]()
            var frame = encode_bus_frame(
                asgi_stream_url(String("e"), slot), NO_EVENT_ID, Span(empty)
            )
            pool.send_stream_chunk(Span(frame))
        elif kind == "stream_note":
            print(
                "asgi-executor: stream raised after its head: "
                + String(py=ev[2]),
                flush=True,
            )
        elif kind == "ws_accept":
            # Begin frame before the 101 — the same FIFO anchor as a
            # stream's head, for the sockets registry this time.
            if pending_101[slot]:
                var begin = List[UInt8]()
                var begin_frame = encode_bus_frame(
                    asgi_stream_url(String("B"), slot), NO_EVENT_ID,
                    Span(begin),
                )
                pool.send_stream_chunk(Span(begin_frame))
                var held = pending_101[slot].take()
                handler.after_response(methods[slot], paths[slot], held)
                pool.put_response(slot, held^, False)
                pool.complete(slot)
        elif kind == "ws_reject":
            # The application refused (or never answered) the handshake.
            if pending_101[slot]:
                _ = pending_101[slot].take()
                var response = _ws_forbidden()
                handler.after_response(methods[slot], paths[slot], response)
                pool.put_response(slot, response^, False)
                pool.complete(slot)
        elif kind == "ws_send":
            var opcode = Int(py=ev[2])
            var payload = handler.apps[0]._bridge.body_bytes(ev[3])
            var frame_bytes = encode_ws_frame(
                WS_OP_TEXT if opcode == 1 else WS_OP_BINARY, Span(payload)
            )
            var frame = encode_bus_frame(
                asgi_stream_url(String("w"), slot), NO_EVENT_ID,
                Span(frame_bytes),
            )
            pool.send_stream_chunk(Span(frame))
        elif kind == "ws_close":
            # A close frame with the app's code, then the end marker that
            # lets the loop close after it lands.
            var code = Int(py=ev[2])
            var close_body = List[UInt8]()
            close_body.append(UInt8((code >> 8) & 0xFF))
            close_body.append(UInt8(code & 0xFF))
            var close_frame = encode_ws_frame(WS_OP_CLOSE, Span(close_body))
            var f1 = encode_bus_frame(
                asgi_stream_url(String("w"), slot), NO_EVENT_ID,
                Span(close_frame),
            )
            pool.send_stream_chunk(Span(f1))
            var empty = List[UInt8]()
            var f2 = encode_bus_frame(
                asgi_stream_url(String("x"), slot), NO_EVENT_ID, Span(empty)
            )
            pool.send_stream_chunk(Span(f2))


def _ws_forbidden() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String(
            '{"error":"the application refused the WebSocket handshake"}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=403,
        status_text="Forbidden",
    )


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
