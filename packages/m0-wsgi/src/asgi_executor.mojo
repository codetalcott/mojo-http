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
from std.python.bindings import PythonModuleBuilder
from std.io.write import Writable, Writer
from std.time import sleep

from std.collections import Optional

from lightbug_http.broadcast import encode_bus_frame
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.http import HTTPResponse
from lightbug_http.http.common_response import InternalError
from lightbug_http.offload import OffloadPool, stream_gen_seed, COMPLETE_BATCH_MAX
from lightbug_http.event_loop import (
    LoopState,
    prepare_loop,
    run_pass_once,
    service_direct_completions,
    _run_shutdown,
)
from lightbug_http.server_config import ServerConfig
from lightbug_http.event_loop_backend import EventLoopBackend
from std.sys.info import CompilationTarget
from std.io import FileDescriptor
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
from .handler import WSGIHandler, asgi_stream_url, _send_disconnect_tag
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
    var _lanes: List[Int]
    """Each executor thread's submit lane, so `stop_and_join` poisons the
    channel that thread is actually parked on. One entry for the unmounted
    server; one per ASGI mount otherwise."""
    var stragglers: Int
    """Executors `stop_and_join` gave up waiting for — still inside the
    application when its budget ran out, left running and unjoined."""

    def __init__(out self, count: Int = 1):
        self._set = ThreadSet(count if count > 0 else 1)
        self._started = False
        self._lanes = List[Int]()
        self.stragglers = 0

    def __init__(out self, *, deinit move: Self):
        self._set = move._set^
        self._started = move._started
        self._lanes = move._lanes^
        self.stragglers = move.stragglers

    def start(
        mut self, pool_addr: Int, user: Int, var lanes: List[Int]
    ) raises:
        """Spawn one executor thread per lane in `lanes`.

        `user` is the `ServeOptions` address. A lane is the submit channel
        that executor reads and the mount it serves — under `--mount` a
        sync application's pool threads are parked on other lanes at the
        same time, and a job must reach the worker that can actually run
        it. `[-1]` is the unmounted server: one executor, the base
        channels. Each executor owns its own bridge, asyncio loop,
        lifespan and drain-ack fd; they share only the chunk channel,
        whose datagrams are slot-addressed.
        """
        var body = _executor_body
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        if len(lanes) == 0:
            lanes.append(-1)
        self._lanes = lanes^
        for i in range(len(self._lanes)):
            var block = self._set.block(i)
            block.set(BLK_USER, user)
            block.set(BLK_POOL, pool_addr)
            block.set(BLK_LANE, self._lanes[i])
            self._set.spawn(i, body_addr)
        self._started = True

    def stop_and_join(mut self, mut pool: OffloadPool, timeout_ns: Int = -1) raises -> Int:
        """One pill per executor, each on ITS OWN lane, then join.

        Returns the count of threads that did not end cleanly. With
        `timeout_ns >= 0` the join is bounded, as `BlockingPool`'s is: an
        executor whose loop never comes back (a task awaiting a chunk credit
        that will never arrive, docs/REAL_APP_VALIDATION.md) is counted in
        `stragglers` and left behind rather than waited for forever.

        BLOCKS — detach from the interpreter around it, exactly as with
        `BlockingPool.stop_and_join`: an executor must attach-and-run to
        drain its in-flight tasks, and it cannot while the joiner holds a
        thread state and sleeps in `pthread_join`.

        **The lanes are load-bearing.** Under `--mount` each executor
        sleeps on its own mount's submit channel, and a pill sent to lane
        0 goes to the pool threads instead — `next_job` has no timeout, so
        the executor never wakes and this join hangs forever rather than
        failing. That is exactly what a mounted server's SIGTERM did
        before the pills named their lanes.
        """
        if not self._started:
            return 0
        for i in range(len(self._lanes)):
            var lane = self._lanes[i]
            pool.stop(1, lane if lane > 0 else 0)
        if timeout_ns >= 0:
            self.stragglers = self._set.join_within(timeout_ns)
        else:
            self._set.join_all()
        var failed = 0
        for i in range(len(self._lanes)):
            if self._set.status(i) != STATUS_OK:
                failed += 1
        return failed


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

    # The executor's side of the pump, as a Python type the shim calls
    # into (`_port.dispatch`, `_port.flush`); the loop below is entered
    # ONCE. The type is built here rather than at import so each executor
    # thread (one per ASGI mount) gets its own, bound to its own pool
    # address and handler; the module object only has to outlive the
    # instance, and it does -- both are locals of this frame.
    var native = _ensure_port_type()
    var state = ExecutorState(lane, pool.capacity)
    # Addresses the way `OffloadPool.addr` takes its own: a Pointer to the
    # value, read back through a Pointer to that pointer.
    var handler_ptr = Pointer(to=handler)
    var state_ptr = Pointer(to=state)
    var port_obj = PythonObject(
        alloc=ExecutorPort(
            block.get(BLK_POOL),
            Pointer(to=handler_ptr).unsafe_bitcast[Int]()[],
            Pointer(to=state_ptr).unsafe_bitcast[Int]()[],
            lane,
        )
    )
    # The port goes in before the submit reader exists: from
    # `executor_init` on, a readable submit channel produces events.
    handler.apps[0]._bridge.set_port(port_obj)

    # The shim's loop reads the submit channel itself from here on. The fd
    # must be non-blocking: `add_reader` fires level-ish per readability,
    # and the drain-until-EAGAIN read inside the shim must never park the
    # whole loop in a blocking `read`. The ack fd (streaming credit) was
    # made non-blocking by `enable_stream_channel`, in the wiring, before
    # this thread existed.
    set_nonblocking(FileDescriptor(pool.submit_read_fd(lane)))
    if lane >= 0:
        set_nonblocking(FileDescriptor(pool.ack_read_fd(lane)))
    handler.apps[0]._bridge.executor_init(
        pool.submit_read_fd(lane), pool.ack_read_fd(lane)
    )

    # Parked attached, inside the loop's selector -- which is where CPython
    # releases the GIL -- for the thread's whole life; every event is
    # handled by the port from inside the loop. Returns after the pill,
    # once the shim has run the in-flight tasks to completion and stopped
    # the loop.
    handler.apps[0]._bridge.run_forever()
    # Anything parked after the last scheduled flush, then lifespan
    # shutdown and the destructors, in this scope.
    _flush_completions(pool, state.pending_done)
    handler.shutdown()
    _ = native
    _ = port_obj



def _ensure_port_type() raises -> PythonObject:
    """Build the `m0native` module and the `ExecutorPort` Python type, ONCE
    per process.

    The stdlib keeps one Python type object per Mojo type for the whole
    process and refuses a second ("Error building multiple Python type
    objects bound to Mojo type ..."), and there is one executor thread per
    ASGI mount and per `--threads` loop, each of which arrives here. The
    first to arrive builds; every later one hits that refusal and simply
    goes on -- `PythonObject(alloc=ExecutorPort(...))` finds the type in
    the same registry. Both run attached, so the registration is complete
    before a second thread can see it. Any other error is real and is
    raised. Returns the module (an empty `PythonObject` when this thread
    did not build it); the caller keeps it alive beside the port.
    """
    try:
        var builder = PythonModuleBuilder("m0native")
        _ = builder.add_type[ExecutorPort]("ExecutorPort").def_method[
            ExecutorPort.dispatch
        ]("dispatch").def_method[ExecutorPort.flush]("flush").def_method[
            ExecutorPort.pass_
        ]("pass_")
        return builder.finalize()
    except e:
        if String(e).find("multiple Python type objects") < 0:
            raise e
        return PythonObject(None)


struct ExecutorState(Movable):
    """The executor's per-slot tables, owned by `_executor_serve`'s frame
    and reached by the port by address.

    Kept OUT of `ExecutorPort` on purpose: `PythonModuleBuilder.add_type`
    wraps `__repr__` through a `Writable` the compiler DERIVES from the
    fields — an explicit `write_to` on the type does not stop it — and an
    `OwningList[Optional[HTTPResponse]]` cannot be derived. Four integers
    can. Parallel to the slots: what `after_response` needs after the
    request itself has crossed into Python, the ready 101 held for a
    WebSocket handshake until the application's `websocket.accept` comes
    back, each stream's generation, and the completions parked since the
    last flush. Only ever touched by this thread.
    """

    var methods: List[String]
    var paths: List[String]
    var pending_101: OwningList[Optional[HTTPResponse]]
    var gens: List[Int]
    var lost: List[Bool]
    """Per slot: this stream lost a frame the chunk channel would not take,
    and has been torn down. Every later frame of it is pointless — and
    expensive, because `_send_chunk_frame` waits ~5 s before giving up —
    so they are skipped rather than retried one by one. Cleared where a
    slot starts a new stream, which is the only place it can be true of
    the previous one."""

    var next_gen: Int
    var pending_done: List[Int]
    var stopping: Bool

    def __init__(out self, lane: Int, capacity: Int):
        self.methods = List[String](capacity=capacity)
        self.paths = List[String](capacity=capacity)
        self.pending_101 = OwningList[Optional[HTTPResponse]](capacity=capacity)
        self.gens = List[Int](capacity=capacity)
        self.lost = List[Bool](capacity=capacity)
        for _ in range(capacity):
            self.methods.append(String(""))
            self.paths.append(String(""))
            self.pending_101.append(None)
            self.gens.append(0)
            self.lost.append(False)
        # This executor's generations are disjoint from every other
        # producer's by construction (`stream_gen_seed`).
        self.next_gen = stream_gen_seed(lane + 1)
        self.pending_done = List[Int](capacity=COMPLETE_BATCH_MAX)
        self.stopping = False


struct ExecutorPort(Movable, Writable):
    """The executor's side of the pump, as a Python type Python calls INTO.

    Built by `PythonModuleBuilder` inside the interpreter this binary
    embeds -- no shared library, no `PyInit_`, no ctypes; a call costs
    ~70 ns -- and handed to the shim as `_port`. Every event the shim used
    to queue for a Mojo pass (`('job', slot)`, `('done', ...)`,
    `stream_*`, `ws_*`) is now `_port.dispatch(ev)`, handled at once on
    this thread inside the loop iteration that produced it, and the loop
    never stops: the executor thread parks in ONE `run_forever` for its
    whole life instead of a `run_until_complete` per pass (38 us on
    stdlib asyncio, 64 on uvloop -- the shape uvloop is built not to
    pay). Completions park as before and are poked to the loop once per
    loop iteration by `flush`, which the shim schedules with `call_soon`
    on the first event of an iteration -- batching without a batch
    buffer, uvicorn's write-coalescing shape.

    Runs attached, on the executor thread, with the GIL held -- exactly
    where the pass used to run -- so every rule of that code holds
    unchanged: a send that may block detaches first (`_send_chunk_frame`,
    `_flush_completions`), a begin frame goes out before its head is
    queued, and every non-begin chunk frame is preceded by a flush of the
    queued completions. Holds the loop's `OffloadPool` and this thread's
    handler by ADDRESS: both are locals of `_executor_serve`, alive for
    as long as `run_forever` runs.
    """

    var pool_addr: Int
    var handler_addr: Int
    var state_addr: Int
    var lane: Int
    var loop_addr: Int
    """Inverted mode only: the `LoopState` this port drives, by address."""
    var backend_addr: Int
    """Inverted mode only: the platform backend (`KqueueBackend` on macOS,
    `EpollBackend` on Linux — never a `DetachingBackend`, there is nothing
    to detach from when the wait is `wait(0)`), by address."""
    var inverted: Int
    """1 when this port drives the event loop itself (`M0_INVERTED`), 0 on
    the pump. An Int, not a Bool: the bound type's fields must be ones the
    compiler can derive a `Writable` for."""

    def __init__(
        out self, pool_addr: Int, handler_addr: Int, state_addr: Int, lane: Int,
        loop_addr: Int = 0, backend_addr: Int = 0, inverted: Int = 0,
    ):
        self.pool_addr = pool_addr
        self.handler_addr = handler_addr
        self.state_addr = state_addr
        self.lane = lane
        self.loop_addr = loop_addr
        self.backend_addr = backend_addr
        self.inverted = inverted

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("ExecutorPort(lane=", self.lane, ", inverted=", self.inverted, ")")

    @staticmethod
    def pass_(py_self: PythonObject) raises -> PythonObject:
        """`_port.pass_()`: one non-blocking pass of the event loop, on this
        thread. Inverted mode only. True once the shutdown pipe has fired
        and the drain has run."""
        var port = py_self.downcast_value_ptr[ExecutorPort]()
        return PythonObject(port[]._pass())

    def _pass(mut self) raises -> Bool:
        comptime if CompilationTarget.is_macos():
            from lightbug_http.c.kqueue_backend import KqueueBackend
            return self._pass_with[KqueueBackend]()
        else:
            from lightbug_http.c.epoll_backend import EpollBackend
            return self._pass_with[EpollBackend]()

    def _pass_with[B: EventLoopBackend](mut self) raises -> Bool:
        ref handler = Pointer[WSGIHandler, MutUntrackedOrigin](
            unsafe_from_address=self.handler_addr
        )[]
        ref st = Pointer[LoopState, MutUntrackedOrigin](
            unsafe_from_address=self.loop_addr
        )[]
        ref xs = Pointer[ExecutorState, MutUntrackedOrigin](
            unsafe_from_address=self.state_addr
        )[]
        ref backend = Pointer[B, MutUntrackedOrigin](
            unsafe_from_address=self.backend_addr
        )[]
        if xs.stopping:
            return True
        var shutdown = run_pass_once(handler, backend, st)
        if shutdown:
            # First cut: the drain as it is, blocking inside this callback
            # for at most its 5 s budget. The reshaped, polled drain is the
            # design's item 6 and follows.
            _run_shutdown(handler, backend, st)
            xs.stopping = True
        return shutdown

    def _place_frame(mut self, mut pool: OffloadPool, frame: Span[Byte, _]) -> Bool:
        """Place one chunk datagram: `_send_chunk_frame` on the pump, or the
        pump-the-loop-yourself version under inversion.

        `_send_chunk_frame` waits DETACHED for the event loop to drain the
        channel, which on the pump is another thread. Inverted, the loop is
        THIS thread, and that wait is a self-deadlock until its 5 s give-up
        — which the ASGI smoke found on its first inverted run as a 237 KB
        stream that stopped mid-body (the three-piece one just before it
        fit the channel and passed). The shim suspends only on credit, 64 KB
        per stream, and a Unix datagram pair holds far less than that, so
        the producer fills it synchronously. The answer is the design's own
        argument taken one step further: the producer is the loop, so when
        the channel is full it runs a pass — drain, write, ack — and retries.
        Bounded like the original: past that the client is not reading and
        the outbox is what is full, which no pass can help.
        """
        if self.inverted == 0:
            return _send_chunk_frame(pool, frame)
        comptime if CompilationTarget.is_macos():
            from lightbug_http.c.kqueue_backend import KqueueBackend
            return self._place_frame_with[KqueueBackend](pool, frame)
        else:
            from lightbug_http.c.epoll_backend import EpollBackend
            return self._place_frame_with[EpollBackend](pool, frame)

    def _place_frame_with[B: EventLoopBackend](
        mut self, mut pool: OffloadPool, frame: Span[Byte, _]
    ) -> Bool:
        if pool.send_stream_chunk(frame):
            return True
        for _ in range(25000):
            try:
                _ = self._pass_with[B]()
            except e:
                print("inverted executor: pass inside a frame wait raised: " + String(e), flush=True)
                return False
            if pool.send_stream_chunk(frame):
                return True
            sleep(0.0002)
        return False

    def _flush_inverted[B: EventLoopBackend](mut self, mut st: ExecutorState) raises:
        # A PASS first, then the completions — a streamed response's begin
        # frame rides the chunk channel and is drained by the pass, so a
        # head completed before it would precede its own begin frame, the
        # recycled-slot hazard the streaming rules exist for. On one thread
        # the order is the order of these two calls.
        _ = self._pass_with[B]()
        if len(st.pending_done) == 0:
            return
        ref handler = Pointer[WSGIHandler, MutUntrackedOrigin](
            unsafe_from_address=self.handler_addr
        )[]
        ref loop = Pointer[LoopState, MutUntrackedOrigin](
            unsafe_from_address=self.loop_addr
        )[]
        ref backend = Pointer[B, MutUntrackedOrigin](
            unsafe_from_address=self.backend_addr
        )[]
        var slots = st.pending_done.copy()
        st.pending_done.clear()
        service_direct_completions(handler, backend, loop, slots)

    @staticmethod
    def dispatch(py_self: PythonObject, ev: PythonObject) raises -> PythonObject:
        """`_port.dispatch(ev)`: handle one event now. True after the pill."""
        var port = py_self.downcast_value_ptr[ExecutorPort]()
        return PythonObject(port[]._dispatch(ev))

    @staticmethod
    def flush(py_self: PythonObject) raises -> PythonObject:
        """`_port.flush()`: poke the loop for every completion parked since
        the last flush -- once per loop iteration, scheduled by the shim."""
        var port = py_self.downcast_value_ptr[ExecutorPort]()
        port[]._flush()
        return PythonObject(None)

    def _flush(mut self):
        ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
            unsafe_from_address=self.pool_addr
        )[]
        ref st = Pointer[ExecutorState, MutUntrackedOrigin](
            unsafe_from_address=self.state_addr
        )[]
        if self.inverted == 0:
            _flush_completions(pool, st.pending_done)
            return
        # Inverted: no datagram; see `_flush_inverted` for the ordering.
        comptime if CompilationTarget.is_macos():
            from lightbug_http.c.kqueue_backend import KqueueBackend
            try:
                self._flush_inverted[KqueueBackend](st)
            except e:
                print("inverted executor: flush raised: " + String(e), flush=True)
        else:
            from lightbug_http.c.epoll_backend import EpollBackend
            try:
                self._flush_inverted[EpollBackend](st)
            except e:
                print("inverted executor: flush raised: " + String(e), flush=True)

    def _dispatch(mut self, ev: PythonObject) raises -> Bool:
        """One event of the shim's, in the order the pass used to see it.

        ORDER, spelled out, because it is the correctness of the streaming
        seam. A stream's begin frame (`b`/`B`) goes out on the chunk
        channel immediately, and its head completion is parked behind it:
        begin still precedes head by construction. Every NON-begin chunk
        frame (`s`, `e`, `w`, `x`) is preceded by a flush of the parked
        completions, so no chunk can ever overtake the head -- or any
        completion -- it used to follow. A `('job', -1)` is the pill: it
        only sets `stopping` and reports it; the shim finishes the
        in-flight tasks (their events arrive here as they complete) and
        stops the loop.
        """
        ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
            unsafe_from_address=self.pool_addr
        )[]
        ref handler = Pointer[WSGIHandler, MutUntrackedOrigin](
            unsafe_from_address=self.handler_addr
        )[]
        ref st = Pointer[ExecutorState, MutUntrackedOrigin](
            unsafe_from_address=self.state_addr
        )[]
        var kind = String(py=ev[0])
        var slot = Int(py=ev[1])
        if kind == "job":
            return dispatch_job(pool, handler, st, self.lane, slot)
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
            handler.after_response(st.methods[slot], st.paths[slot], response)
            pool.put_response(slot, response^, raised)
            _queue_completion(pool, st.pending_done, slot)
        elif kind == "err":
            print(
                "asgi-executor: request raised: " + String(py=ev[2]),
                flush=True,
            )
            var response = InternalError()
            handler.after_response(st.methods[slot], st.paths[slot], response)
            pool.put_response(slot, response^, True)
            _queue_completion(pool, st.pending_done, slot)
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
            st.gens[slot] = st.next_gen
            st.next_gen += 1
            st.lost[slot] = False
            var begin = List[UInt8]()
            var begin_frame = encode_bus_frame(
                asgi_stream_url(String("b"), slot, self.lane), st.gens[slot], Span(begin)
            )
            if not self._place_frame(pool, Span(begin_frame)):
                # The begin never landed, so the loop will never subscribe
                # this slot -- and a streaming head on an unsubscribed slot
                # is read as a stream that ended before it began: an empty
                # 200 under a clean terminator, while the application goes
                # on producing into a channel nobody is listening to until
                # its credit runs out and it awaits forever, holding its
                # share of the global window for the life of the process.
                # So the head does NOT go out as a stream. 500 and close,
                # and the task is told the connection is gone through the
                # same disconnect tag the loop would send -- which the loop
                # cannot send here, because it never saw a stream.
                st.lost[slot] = True
                _report_lost(String("stream begin"), slot, len(begin_frame))
                _send_disconnect_tag(pool.submit_write_fd(self.lane), slot)
                var failed = InternalError()
                handler.after_response(st.methods[slot], st.paths[slot], failed)
                pool.put_response(slot, failed^, True)
                _queue_completion(pool, st.pending_done, slot)
                return False
            # The head: an ordinary completion whose response is marked
            # streaming — _finish_response pops content-length, keeps the
            # connection, and flips the slot into streaming state once the
            # head is on the wire. From here this slot's bytes travel ONLY
            # as chunk frames; the completion channel carries nothing more
            # for it except, if the app raises mid-body, the abort.
            var response: HTTPResponse
            var raised = False
            try:
                response = build_response(
                    handler.apps[0]._bridge, String(py=ev[2]), ev[3], ev[4],
                    streaming=True,
                )
            except:
                response = InternalError()
                raised = True
            response.stream_gen = st.gens[slot]
            handler.after_response(st.methods[slot], st.paths[slot], response)
            pool.put_response(slot, response^, raised)
            _queue_completion(pool, st.pending_done, slot)
        elif kind == "stream_chunk":
            if st.lost[slot]:
                return False
            _flush_completions(pool, st.pending_done)
            # Park-then-poke does not apply here: the chunk's bytes ride
            # IN the datagram, so the send is both the publish and the
            # happens-before edge. Retried, never dropped — a lost chunk
            # is a corrupt body.
            var chunk = handler.apps[0]._bridge.body_bytes(ev[2])
            var frame = encode_bus_frame(
                asgi_stream_url(String("s"), slot, self.lane), st.gens[slot], Span(chunk)
            )
            if not self._place_frame(pool, Span(frame)):
                # Unplaceable even after waiting detached: the loop is not
                # draining this channel at all, so this body is short. It is
                # ABORTED rather than left to end normally, because the end
                # frame that follows would put a clean chunked terminator
                # after a truncated body — a 200 indistinguishable from a
                # good one, which is the silent-wrong this whole seam is
                # built to refuse. `stream_pump` (the pool thread's copy of
                # this decision) does the same thing for the same reason.
                st.lost[slot] = True
                _report_lost(String("stream chunk"), slot, len(frame))
                _report_abort(pool, slot, st.gens[slot])
        elif kind == "stream_end":
            if st.lost[slot]:
                return False
            _flush_completions(pool, st.pending_done)
            var empty = List[UInt8]()
            var frame = encode_bus_frame(
                asgi_stream_url(String("e"), slot, self.lane), st.gens[slot], Span(empty)
            )
            if not self._place_frame(pool, Span(frame)):
                # The body is whole but its end marker cannot be delivered,
                # and the loop only closes a stream it has been told ended:
                # dropped, this connection streams nothing and closes never.
                # The abort rides the COMPLETION channel — a different
                # socket, which is why it is worth trying — and closes
                # without the terminator, so a client sees a truncated body
                # rather than a hang.
                st.lost[slot] = True
                _report_lost(String("stream end"), slot, len(frame))
                _report_abort(pool, slot, st.gens[slot])
        elif kind == "stream_abort":
            # The app raised after its head went out: the loop closes the
            # connection WITHOUT the chunked terminator, so the client sees
            # a truncated body rather than a short one under a clean end.
            # Rides the completion channel, gen-checked there against the
            # head this slot last completed.
            _report_abort(pool, slot, st.gens[slot])
        elif kind == "stream_note":
            print(
                "asgi-executor: stream raised after its head: "
                + String(py=ev[2]),
                flush=True,
            )
        elif kind == "ws_accept":
            # Begin frame before the 101 — the same FIFO anchor as a
            # stream's head, for the sockets registry this time.
            if st.pending_101[slot]:
                st.gens[slot] = st.next_gen
                st.next_gen += 1
                st.lost[slot] = False
                var begin = List[UInt8]()
                var begin_frame = encode_bus_frame(
                    asgi_stream_url(String("B"), slot, self.lane), st.gens[slot],
                    Span(begin),
                )
                if not self._place_frame(pool, Span(begin_frame)):
                    # Without the begin the sockets registry never learns
                    # about this slot, so the 101 would hand the connection
                    # to a frame mode with no producer and no outbox: a
                    # socket that connects and then says nothing, for ever.
                    # Release the held 101 as a 500 and close, and tell the
                    # task its connection is gone.
                    st.lost[slot] = True
                    _report_lost(String("websocket begin"), slot, len(begin_frame))
                    _ = st.pending_101[slot].take()
                    _send_disconnect_tag(pool.submit_write_fd(self.lane), slot)
                    var failed = InternalError()
                    handler.after_response(st.methods[slot], st.paths[slot], failed)
                    pool.put_response(slot, failed^, True)
                    _queue_completion(pool, st.pending_done, slot)
                    return False
                var held = st.pending_101[slot].take()
                held.stream_gen = st.gens[slot]
                handler.after_response(st.methods[slot], st.paths[slot], held)
                pool.put_response(slot, held^, False)
                _queue_completion(pool, st.pending_done, slot)
        elif kind == "ws_reject":
            # The application refused (or never answered) the handshake.
            if st.pending_101[slot]:
                _ = st.pending_101[slot].take()
                var response = _ws_forbidden()
                handler.after_response(st.methods[slot], st.paths[slot], response)
                pool.put_response(slot, response^, False)
                _queue_completion(pool, st.pending_done, slot)
        elif kind == "ws_send":
            if st.lost[slot]:
                return False
            _flush_completions(pool, st.pending_done)
            var opcode = Int(py=ev[2])
            var payload = handler.apps[0]._bridge.body_bytes(ev[3])
            var frame_bytes = encode_ws_frame(
                WS_OP_TEXT if opcode == 1 else WS_OP_BINARY, Span(payload)
            )
            var frame = encode_bus_frame(
                asgi_stream_url(String("w"), slot, self.lane), st.gens[slot],
                Span(frame_bytes),
            )
            if not self._place_frame(pool, Span(frame)):
                # A WebSocket message that silently never arrives is worse
                # than a closed socket: the peer waits on a protocol that
                # gives it no way to know. Unlike a stream's chunks, these
                # are not credit-gated at all — the shim's `websocket.send`
                # has no window — so this is the reachable one. Abort: the
                # loop flushes what is queued and closes, and the
                # application's task learns of it through the disconnect
                # that follows. (The loop's abort path had to learn about
                # sockets for this: it gated on `slot_sse`, which a 101
                # never sets, so an abort of a socket used to be a silent
                # no-op.)
                st.lost[slot] = True
                _report_lost(String("websocket frame"), slot, len(frame))
                _report_abort(pool, slot, st.gens[slot])
        elif kind == "ws_close":
            if st.lost[slot]:
                # Already torn down (a frame this socket needed did not go
                # out, and the abort that followed closes the connection).
                # Trying anyway costs two more ~5 s detached waits on a
                # channel that is not draining, and answers nothing.
                return False
            _flush_completions(pool, st.pending_done)
            # A close frame with the app's code, then the end marker that
            # lets the loop close after it lands.
            var code = Int(py=ev[2])
            var close_body = List[UInt8]()
            close_body.append(UInt8((code >> 8) & 0xFF))
            close_body.append(UInt8(code & 0xFF))
            var close_frame = encode_ws_frame(WS_OP_CLOSE, Span(close_body))
            var f1 = encode_bus_frame(
                asgi_stream_url(String("w"), slot, self.lane), st.gens[slot],
                Span(close_frame),
            )
            if not self._place_frame(pool, Span(f1)):
                st.lost[slot] = True
                _report_lost(String("websocket close frame"), slot, len(f1))
                _report_abort(pool, slot, st.gens[slot])
                return False
            var empty = List[UInt8]()
            var f2 = encode_bus_frame(
                asgi_stream_url(String("x"), slot, self.lane), st.gens[slot], Span(empty)
            )
            if not self._place_frame(pool, Span(f2)):
                # The close frame is queued but the end marker that lets the
                # loop close after it lands is not: without one the socket
                # stays subscribed for ever.
                st.lost[slot] = True
                _report_lost(String("websocket end"), slot, len(f2))
                _report_abort(pool, slot, st.gens[slot])
        elif kind == "ws_ack":
            # The inbound window refill: the shim's cumulative count of
            # bytes the app's `receive()` consumed, riding the chunk
            # channel as an 'r' frame the loop's handler credits and
            # drains parked messages against. Gen-stamped HERE, where the
            # slot's current generation is known, so a late ack from a
            # finished task is dropped by the same `_gen_matches` that
            # protects every sibling frame.
            if st.lost[slot]:
                return False
            _flush_completions(pool, st.pending_done)
            var consumed = Int(py=ev[2])
            var body = List[UInt8](capacity=8)
            var cbits = UInt64(consumed)
            for shift in range(0, 64, 8):
                body.append(UInt8((cbits >> UInt64(shift)) & 0xFF))
            var rframe = encode_bus_frame(
                asgi_stream_url(String("r"), slot, self.lane), st.gens[slot],
                Span(body),
            )
            if not self._place_frame(pool, Span(rframe)):
                # Droppable, uniquely on this seam: the counter is
                # cumulative, so the NEXT consume's ack carries everything
                # this one did. No abort, no lost-claim — the cost of a
                # drop is latency on a suspended read, not correctness.
                pass
        return False




def dispatch_job(
    mut pool: OffloadPool, mut handler: WSGIHandler, mut st: ExecutorState,
    lane: Int, slot: Int,
) raises -> Bool:
    """One `('job', slot)`: take the parked request and start it.

    The port's job branch, as a function, because the loop inversion has a
    second caller: `WSGIHandler.direct_job`, invoked by the event loop on
    this same thread with the request already parked, which is exactly
    what the datagram path delivered. Returns True for the pill.
    """
    if slot < 0:
        st.stopping = True
        return True
    var request = pool.take_request(slot)
    st.methods[slot] = request.method
    st.paths[slot] = request.uri.path
    var early = handler.before_request(request)
    if early:
        var response = early.take()
        handler.after_response(st.methods[slot], st.paths[slot], response)
        pool.put_response(slot, response^, False)
        _queue_completion(pool, st.pending_done, slot)
        return False
    var local = handler.serve_local(request)
    if local:
        var response = local.take()
        handler.after_response(st.methods[slot], st.paths[slot], response)
        pool.put_response(slot, response^, False)
        _queue_completion(pool, st.pending_done, slot)
        return False
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
            handler.after_response(st.methods[slot], st.paths[slot], probe)
            pool.put_response(slot, probe^, False)
            _queue_completion(pool, st.pending_done, slot)
            return False
        st.pending_101[slot] = probe^
        try:
            handler.apps[0]._bridge.spawn_asgi_ws(slot, request)
        except:
            st.pending_101[slot] = None
            var response = InternalError()
            handler.after_response(st.methods[slot], st.paths[slot], response)
            pool.put_response(slot, response^, True)
            _queue_completion(pool, st.pending_done, slot)
        return False
    try:
        handler.apps[0]._bridge.spawn_asgi(slot, request)
    except:
        # The spawn itself failed (environ build, task creation):
        # same policy as a raising handler — 500 and a closed
        # connection, because what it left behind is unknown.
        var response = InternalError()
        handler.after_response(st.methods[slot], st.paths[slot], response)
        pool.put_response(slot, response^, True)
        _queue_completion(pool, st.pending_done, slot)
    return False


def _direct_job_thunk(
    pool_addr: Int, handler_addr: Int, state_addr: Int, lane: Int, slot: Int,
) raises -> Bool:
    """`WSGIHandler.direct_fn` under `M0_INVERTED`: the port's job branch,
    reached through addresses so `handler.mojo` needs no import of this
    module. Same function the datagram path runs (`dispatch_job`)."""
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=pool_addr
    )[]
    ref handler = Pointer[WSGIHandler, MutUntrackedOrigin](
        unsafe_from_address=handler_addr
    )[]
    ref st = Pointer[ExecutorState, MutUntrackedOrigin](
        unsafe_from_address=state_addr
    )[]
    return dispatch_job(pool, handler, st, lane, slot)


def serve_inverted(
    opts: ServeOptions,
    listen_fd: FileDescriptor,
    config: ServerConfig,
    address: String,
    shutdown_fd: Int,
    mut pool: OffloadPool,
    peer_bus_fd: Int = -1,
) raises:
    """`M0_INVERTED`: serve an unmounted ASGI application on ONE thread.

    The executor's asyncio loop is the driver and the Mojo event loop runs
    inside it, one non-blocking pass per readiness of the backend's own fd
    (`run_forever_inverted`). One handler is both the loop's and the
    executor's, built with the lifespan; a request reaches the app through
    `WSGIHandler.direct_job` → `dispatch_job` with no datagram, and its
    response reaches the wire through `service_direct_completions` with no
    wake. The submit and ack channels stay registered on the asyncio loop:
    disconnect tags, WebSocket messages and stream credit still ride them,
    to this same thread.

    Runs on the calling thread — `m0serve`'s main, which is attached since
    `Py_Initialize` — so there is no thread to spawn and nothing to detach:
    the only wait is asyncio's own selector, which releases the GIL itself.
    """
    var lane = -1
    var handler = WSGIHandler.for_options(
        WSGIApp(
            opts.module,
            server_name=opts.host,
            server_port=String(opts.port),
            attribute=opts.attribute,
            multiprocess=opts.workers > 1,
            multithread=False,
            protocol="asgi",
            lifespan=True,
        ),
        opts,
    )
    handler.set_abort_pool(pool.addr())
    handler.set_asgi_notify(pool.submit_write_fd(lane))

    var native = _ensure_port_type()
    var state = ExecutorState(lane, pool.capacity)
    var handler_ptr = Pointer(to=handler)
    var state_ptr = Pointer(to=state)
    var handler_addr = Pointer(to=handler_ptr).unsafe_bitcast[Int]()[]
    var state_addr = Pointer(to=state_ptr).unsafe_bitcast[Int]()[]
    handler.set_direct_executor(pool.addr(), state_addr, lane, _direct_job_thunk)

    var stream_bus_fd = pool.stream_chunk_read if pool.chunk_active() else -1

    comptime if CompilationTarget.is_macos():
        from lightbug_http.c.kqueue_backend import KqueueBackend
        var backend = KqueueBackend()
        var st = prepare_loop(
            listen_fd, backend, config, address, True, shutdown_fd,
            stream_bus_fd, pool.addr(), peer_bus_fd,
        )
        var st_ptr = Pointer(to=st)
        var backend_ptr = Pointer(to=backend)
        var port_obj = PythonObject(
            alloc=ExecutorPort(
                pool.addr(), handler_addr, state_addr, lane,
                Pointer(to=st_ptr).unsafe_bitcast[Int]()[],
                Pointer(to=backend_ptr).unsafe_bitcast[Int]()[],
                1,
            )
        )
        handler.apps[0]._bridge.set_port(port_obj)
        set_nonblocking(FileDescriptor(pool.submit_read_fd(lane)))
        set_nonblocking(FileDescriptor(pool.ack_read_fd(lane)))
        handler.apps[0]._bridge.executor_init(
            pool.submit_read_fd(lane), pool.ack_read_fd(lane)
        )
        print("inverted: the event loop runs inside asyncio (kqueue fd " + String(backend.kq.value) + ")", flush=True)
        handler.apps[0]._bridge.run_forever_inverted(backend.kq.value)
        _ = st
        _ = port_obj
    else:
        from lightbug_http.c.epoll_backend import EpollBackend
        var backend = EpollBackend()
        var st = prepare_loop(
            listen_fd, backend, config, address, True, shutdown_fd,
            stream_bus_fd, pool.addr(), peer_bus_fd,
        )
        var st_ptr = Pointer(to=st)
        var backend_ptr = Pointer(to=backend)
        var port_obj = PythonObject(
            alloc=ExecutorPort(
                pool.addr(), handler_addr, state_addr, lane,
                Pointer(to=st_ptr).unsafe_bitcast[Int]()[],
                Pointer(to=backend_ptr).unsafe_bitcast[Int]()[],
                1,
            )
        )
        handler.apps[0]._bridge.set_port(port_obj)
        set_nonblocking(FileDescriptor(pool.submit_read_fd(lane)))
        set_nonblocking(FileDescriptor(pool.ack_read_fd(lane)))
        handler.apps[0]._bridge.executor_init(
            pool.submit_read_fd(lane), pool.ack_read_fd(lane)
        )
        print("inverted: the event loop runs inside asyncio (epoll fd " + String(backend.epfd.value) + ")", flush=True)
        handler.apps[0]._bridge.run_forever_inverted(backend.epfd.value)
        _ = st
        _ = port_obj
    handler.shutdown()
    _ = native
    _ = state


def _report_lost(what: String, slot: Int, nbytes: Int):
    """Name a frame the chunk channel would not take, and its consequence.

    Every one of these was a silent failure until 0.14.1: the send's result
    was discarded at five of the six sites, so a dropped begin was a stream
    the loop never subscribed, a dropped end a connection that never closed,
    and a dropped WebSocket frame a message the peer had no way to miss.
    The channel only refuses after `_send_chunk_frame` has waited detached
    for ~5 s, so reaching here means the loop is not draining at all — the
    caller tears the connection down, and this says which one and why."""
    print(
        "asgi-executor: chunk channel would not take " + String(nbytes)
        + " bytes of " + what + " for slot " + String(slot)
        + " after ~5s — tearing this connection down rather than hanging it",
        flush=True,
    )


def _report_abort(mut pool: OffloadPool, slot: Int, gen: Int):
    """Abort a stream, and say so if even the abort will not go.

    The abort rides the COMPLETION channel, not the chunk channel, so it is
    genuinely a second chance when the chunk channel is the one that is
    wedged. If it is refused too there is nothing left to do but name it:
    the connection stays open until the client or the shutdown budget ends
    it."""
    if not pool.abort_stream(slot, gen):
        print(
            "asgi-executor: could not abort slot " + String(slot)
            + "'s stream — the completion channel is full too; the "
            "connection will hang until the client closes it",
            flush=True,
        )


def _queue_completion(mut pool: OffloadPool, mut pending: List[Int], slot: Int):
    """Park-then-poke, deferred: the response is already parked; the poke
    joins this pass's batch, flushed at the end of the pass or when full."""
    pending.append(slot)
    if len(pending) >= COMPLETE_BATCH_MAX:
        _flush_completions(pool, pending)


def _flush_completions(mut pool: OffloadPool, mut pending: List[Int]):
    """One completion datagram for every queued slot; never a drop.

    `complete_many` already retries with yields. If the channel still will
    not take it the loop is not draining completions at that instant, and
    the wait has to be DETACHED — this thread is attached, and the loop
    needs to attach for other work — the `_send_chunk_frame` discipline.
    Bounded at ~5 s like the drain; past that the slots stay queued for the
    next flush rather than being dropped, and the log says so. The old
    per-response `complete` dropped silently after its retries, leaving the
    slot leaked for the process's life; this is strictly better.
    """
    if len(pending) == 0:
        return
    if pool.complete_many(pending):
        pending.clear()
        return
    ref cpy = Python().cpython()
    var ts = cpy.PyEval_SaveThread()
    var placed = False
    for _ in range(25000):
        sleep(0.0002)
        if pool.complete_many(pending):
            placed = True
            break
    cpy.PyEval_RestoreThread(ts)
    if placed:
        pending.clear()
        return
    print(
        "asgi-executor: completion channel full, " + String(len(pending))
        + " completion(s) still queued — the loop is not draining",
        flush=True,
    )

def _send_chunk_frame(mut pool: OffloadPool, frame: Span[Byte, _]) -> Bool:
    """Place one chunk datagram, waiting **detached** if the channel is full.

    A dropped chunk is a corrupt body — a short response under a clean
    terminator, or, for an end frame, one that never completes — so this may
    not simply give up. But it also may not wait while attached: the executor
    holds the GIL here, and the thread that has to drain this channel is the
    event loop, which needs to attach for other work. So the wait releases
    the thread state first, touches no Python object inside it, and takes it
    back before returning. The same discipline `DetachingBackend` applies to
    the loop, in the other direction.

    The shim's global window (`_ASGI_TOTAL_WINDOW`) is what makes this rare;
    what makes it *correct* is that being wrong about that budget on some
    platform now costs a few hundred microseconds of backpressure rather
    than a truncated response. CI found exactly that: a budget that never
    overflowed on macOS overflowed on Linux, where the kernel charges each
    datagram's whole `skb` against the receiver's buffer.

    Bounded at ~5 s, matching the drain: past that the loop is not draining
    at all and nothing this thread does will help.
    """
    if pool.send_stream_chunk(frame):
        return True
    ref cpy = Python().cpython()
    var ts = cpy.PyEval_SaveThread()
    var placed = False
    for _ in range(25000):
        sleep(0.0002)
        if pool.send_stream_chunk(frame):
            placed = True
            break
    cpy.PyEval_RestoreThread(ts)
    return placed


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
