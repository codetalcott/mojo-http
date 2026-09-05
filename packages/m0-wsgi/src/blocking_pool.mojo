"""`--blocking-threads N`: the handler threads behind the acceptor loop.

Stage B. Stage A (`--threads N`) gave the process N event loops; it did not
change the thing that actually strands connections, because a keep-alive
connection belongs to whichever loop accepted it in *both* execution modes.
The measurement is in `docs/WSGI_PERFORMANCE.md`: one `/slow?ms=200` beside
fast traffic takes fast-request p99 from 1.6 ms to ~194 ms — 120x — while p50
does not move at all, which is the signature of a subset of connections
stopped dead rather than of general slowdown. Granian's `--blocking-threads`,
which is this architecture, is flat under the same load.

So the loop stops calling the handler. `lightbug_http.offload` is the queue;
this file is the threads that drain it.

**Each pool thread owns a whole handler**, built by `T.make(ctx)` on the
thread that will use it, inside its own attached region — so its `WSGIApp`,
its `PyBridge`, its shim namespace and its bridge singletons are per-thread,
which is the same rule `threaded.mojo` follows and the same rule the thread
probe measured at 3.96x when obeyed and 0.7x when not.

**The attach/detach discipline is the file.** A pool thread spends almost all
of its life asleep in `recv` waiting for work, and it must be DETACHED while
it sleeps: an attached thread parked in a syscall stalls every other thread's
stop-the-world pause. So the loop is detach → block → attach → run one job →
repeat, and the handler is constructed and destroyed inside an outer attached
region because `PythonObject` destructors need a thread state.

**The acceptor loop must detach too**, and that is not this file's job but it
is this file's problem: a loop that sits in `kevent`/`epoll_wait` while
attached would keep every pool thread out under a GIL-enabled interpreter.
`DetachingBackend` (threaded.mojo) is what the callers wrap their backend in,
under prefork as well as under `--threads`.

Unlike `--threads`, this mode is NOT refused on a GIL-enabled interpreter.
A pool under the GIL is what gunicorn's `--threads` is: CPU-bound views
serialize, but every view that waits on a database, a socket or a sleep
releases the GIL and the isolation is real. That is the workload the mode
exists for.
"""

from std.ffi import c_int, external_call
from std.os import getenv
from std.python import Python
from std.time import perf_counter_ns

from lightbug_http.offload import (
    OffloadPool, JOB_REQUEST, JOB_WS_MESSAGE, JOB_STOP,
    make_stream_ack_pair, drain_ack_fd, stream_gen_seed,
)
from lightbug_http.http import HTTPResponse, Headers, Header, HeaderKey
from lightbug_http.http.common_response import InternalError

from m0_http import (
    ThreadSet, ThreadBlock, BLK_INDEX, BLK_USER, BLK_STATUS, BLK_LANE, BLK_QOS,
    request_qos_class, QOS_CLASS_USER_INITIATED,
    BLK_TURN_ADDR, shared_fetch_add, shared_load,
    STATUS_OK, STATUS_RAISED,
)

from .thread_handler import ThreadContext, ThreadHandler


comptime BLK_POOL = 7
"""Block slot holding the `OffloadPool`'s address."""

comptime WS_JOB_BUFFER = 65546
"""Bytes a pool thread's receive buffer holds.

The submit channel's own socket buffer, plus the tag header. Matches what
the executor's shim reads for the same channel, and must equal
`handler.WS_CHANNEL_DATAGRAM_MAX`, which is what the SENDER checks against.

It is not `max_message_size` that keeps an inbound WebSocket message under
this, though the comment here used to say so: that is
`max_request_body_size`, 4 MB by default, 64x this buffer. `recv` here
passes no `MSG_TRUNC`, so a larger datagram would be copied up to the
buffer with the remainder discarded and the short count indistinguishable
from a short message -- a truncated message handed to the application as a
complete one. The senders in `handler.mojo` refuse to send one instead."""

comptime JOIN_TIMEOUT_NS = 5_000_000_000
"""How long a shutdown waits for handler threads after the loop has drained.

The same 5 s the loop gives its own drain. A pool thread is inside the
application for as long as the application keeps it. An SSE generator
served under WSGI used to be the real case (docs/REAL_APP_VALIDATION.md,
textshelf, 2026-08-26): buffered, it never ended, and kept its thread for
the life of the process. It streams now, and its thread comes back when the
client goes — but a generator asleep inside the application (`time.sleep`
between events) does not notice the disconnect until it wakes, and a view
that never returns is still a view that never returns. `stop_and_join`
used to wait for those forever: SIGTERM did nothing, and `docker stop`
ended in SIGKILL. Past this budget the process leaves without the
stragglers.
"""


struct BlockingPool(Movable):
    """N handler threads against one loop's `OffloadPool`.

    One pool per event loop, not one per process: slots index a single loop's
    provision pool, so a job means nothing outside the loop that issued it.
    Under `--workers W --blocking-threads B` that is W processes of B threads;
    under `--threads T --blocking-threads B`, T pools of B in one process.

        var pool = OffloadPool(config.max_connections)
        var threads = BlockingPool(count)
        threads.start[MyHandler](pool.addr(), spec_addr)
        run_event_loop(..., offload_addr=pool.addr())   # with a DetachingBackend
        threads.stop_and_join(pool)

    `stop_and_join` rather than a separate `OffloadPool.stop(n)` + `join()`:
    the pill count must equal the thread count exactly, because `next_job`
    blocks with no timeout and a thread that gets no pill hangs the join
    forever. Keeping both under one method makes that a property of the type
    rather than an agreement between two call sites that could drift.
    """

    var count: Int
    var _set: ThreadSet
    var _started: Bool
    var _lanes: List[Int]
    """Each thread's submit lane, filled by `start` and read by
    `stop_and_join` — the pills have to go where the threads are parked."""
    var stragglers: Int
    """Threads `stop_and_join` gave up waiting for: still inside the
    application when its budget ran out, left running and unjoined."""
    var turn_addr: Int
    """The pool's turn counters (docs/notes/detached-loop.md): two atomics,
    threads parked in `PyEval_RestoreThread` and attaches completed. A
    thread that drops the GIL while another is parked on it yields until
    that one has acquired (`_yield_turn`), so the hand-off goes to the
    thread that waited rather than back to the one that just ran. 0 for a
    pool of one, and under `M0_POOL_TURN=0` (the probe's negative arm)."""

    def __init__(out self, count: Int):
        self.count = count
        self._set = ThreadSet(count)
        self._started = False
        self._lanes = List[Int]()
        self.stragglers = 0
        self.turn_addr = 0

    def __init__(out self, *, deinit move: Self):
        self.count = move.count
        self._set = move._set^
        self._started = move._started
        self._lanes = move._lanes^
        self.stragglers = move.stragglers
        self.turn_addr = move.turn_addr

    def start[T: ThreadHandler](
        mut self, pool_addr: Int, user: Int, var lanes: List[Int] = List[Int](),
        qos: Bool = False,
    ) raises:
        """Spawn the threads. `user` is what `T.make` receives as `ctx.user`.

        `lanes` are the submit lanes these threads serve, dealt round-robin:
        thread i takes `lanes[i % len(lanes)]`, so one pool covers every WSGI
        mount without a pool per mount. A thread's lane reaches `T.make` as
        `ctx.lane`, and the handler then builds only that mount's
        application — it can never receive another's job. An empty list is
        the unmounted pool: one lane, every thread on it.
        """
        var body = _pool_body[T]
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        self._lanes = List[Int]()
        # The hand-off barrier. With the loop thread holding no thread state
        # (docs/notes/detached-loop.md) nothing forces CPython's GIL hand-off
        # between pool threads: a thread that finishes a job re-takes the GIL
        # before the thread it just signalled is scheduled, and a job THAT
        # thread already dequeued waits out the convoy -- measured as a
        # fast-route max of seconds under a CPU-bound view with four threads.
        # Two counters, no fds: a thread parks itself as a waiter around its
        # re-attach, and a thread that drops the GIL while waiters exist
        # yields until an attach completes (`_yield_turn`). A token queue was
        # tried first and was either a gap (one token: the GIL idle while the
        # next taker woke from the kernel) or no order at all (N-1 tokens,
        # once some threads were asleep inside views). One thread needs none.
        if self.count > 1 and getenv("M0_POOL_TURN", "") != "0":
            self.turn_addr = external_call["malloc", Int, Int](16)
            Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=self.turn_addr)[] = 0
            Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=self.turn_addr + 8)[] = 0
        for i in range(self.count):
            var lane = -1 if len(lanes) == 0 else lanes[i % len(lanes)]
            self._lanes.append(lane)
            var block = self._set.block(i)
            block.set(BLK_USER, user)
            block.set(BLK_POOL, pool_addr)
            block.set(BLK_LANE, lane)
            block.set(BLK_TURN_ADDR, self.turn_addr)
            block.set(BLK_QOS, 1 if qos else 0)
        for i in range(self.count):
            self._set.spawn(i, body_addr)
        self._started = True

    def stop_and_join(mut self, mut pool: OffloadPool, timeout_ns: Int = -1) raises -> Int:
        """Poison the queue with one pill per thread, then join. Returns the
        count that did not end cleanly.

        With `timeout_ns >= 0` the join is bounded (`ThreadSet.join_within`):
        a thread still inside the application when the budget runs out is
        counted in `stragglers`, left unjoined, and the caller is expected to
        leave the process without it. Unbounded otherwise, for callers that
        know every thread will come back.

        BLOCKS — detach from the interpreter around it, because a pool thread
        finishing its last job has to attach and cannot while this thread
        holds a state and sleeps in `pthread_join`.

        The two halves are one method on purpose: `OffloadPool.stop(n)` sends
        `n` pills, `next_job` has no timeout, and a thread that receives no
        pill blocks forever. Closing the queue does not rescue it — on Linux a
        closed peer does not wake a blocked `recv` on a connected SOCK_DGRAM
        pair (see `OffloadPool.stop`). So the only safe `n` is `self.count`,
        and this is where that is guaranteed.
        """
        if not self._started:
            return 0
        # One pill per THREAD, on that thread's own lane: a thread parked on
        # lane 2 is not woken by a pill sent to lane 0, and `next_job` has no
        # timeout, so a miscounted lane is a hung `pthread_join` rather than a
        # slow one. Lane 0 goes last because its `stop` also closes the
        # descriptor.
        var pending = List[Int]()
        for i in range(len(self._lanes)):
            pending.append(self._lanes[i])
        for lane in range(1, len(pool.lane_prefixes)):
            var n = 0
            for i in range(len(pending)):
                if pending[i] == lane:
                    n += 1
            if n > 0:
                pool.stop(n, lane)
        var zero = 0
        for i in range(len(pending)):
            if pending[i] <= 0:
                zero += 1
        if zero > 0:
            pool.stop(zero, 0)
        if timeout_ns >= 0:
            self.stragglers = self._set.join_within(timeout_ns)
        else:
            self._set.join_all()
        var failed = 0
        for i in range(self.count):
            if self._set.status(i) != STATUS_OK:
                failed += 1
        return failed


def _pool_serve[T: ThreadHandler](block: ThreadBlock) raises:
    """One pool thread's whole life, inside its attached region.

    Separate from `_pool_body` so the handler — and every `PythonObject` it
    owns — is destroyed when this scope ends, which is before the caller
    releases the thread state. Same reason `threaded.mojo` splits `_serve_one`
    out of `_thread_body`.
    """
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_POOL)
    )[]
    var lane = block.get(BLK_LANE)
    var index = block.get(BLK_INDEX)
    var turn_addr = block.get(BLK_TURN_ADDR)
    if block.get(BLK_QOS) == 1:
        _ = request_qos_class(QOS_CLASS_USER_INITIATED)

    # This thread's own drain-ack pair, for the WSGI iterables it streams
    # through the loop's chunk channel: the loop acks each drained buffer
    # to the fd this thread registered for the slot (`slot_ack_fd`), and
    # sends a disconnect the same way. One pair per THREAD, not per lane —
    # N threads share a lane — and kept for the process's life, because
    # its number rides in the begin frame. No pair (no chunk channel, or
    # the socketpair failed) means this thread joins iterables as before.
    var ack_read = -1
    var ack_write = -1
    if pool.chunk_active():
        try:
            var pair = make_stream_ack_pair()
            ack_read = pair[0]
            ack_write = pair[1]
        except:
            pass
    var ctx = ThreadContext(
        index, block.get(BLK_USER), lane, pool.hold_notify_fd,
        pool=True,
        stream_fd=pool.stream_chunk_write if ack_write >= 0 else -1,
    )
    var handler = T.make(ctx)
    ref cpy = Python().cpython()
    # Generations name this thread's streams, disjointly from every other
    # producer's (`stream_gen_seed`); one per stream, counting up.
    var gen = stream_gen_seed(1024 + index)

    # One receive buffer for this thread's life. An ordinary job is 8 bytes,
    # but an inbound WebSocket message rides in the datagram, so the buffer
    # is sized for the largest one a channel will carry — allocated once
    # here rather than per job, which would put a WebSocket's cost on every
    # request.
    var buf = List[UInt8](capacity=WS_JOB_BUFFER)
    for _ in range(WS_JOB_BUFFER):
        buf.append(0)

    # When this thread's current run of the GIL began (the hand-off slice).
    var streak_start = perf_counter_ns()

    while True:
        # Detached across the block. This is where the thread spends its life,
        # and holding a thread state through it would stall every other
        # thread's stop-the-world.
        # The snapshot before the drop, the yield after it: once this thread
        # has held its run for a slice, and another pool thread is parked
        # waiting for the GIL this drop releases, stay off it until that
        # thread has acquired. Then park as a waiter around the re-attach so
        # the next thread to drop sees us. A slice rather than every job:
        # a hand-off is a thread switch plus a condvar wake, which on a
        # 200 us view was 15 % of throughput when paid per job and is
        # ~3 % per millisecond; no waiter waits more than the slice.
        var now = perf_counter_ns()
        var attaches_before = shared_load(turn_addr + 8) if turn_addr != 0 else 0
        var ts = cpy.PyEval_SaveThread()
        var yielded = False
        if turn_addr != 0 and now - streak_start >= TURN_SLICE_NS:
            yielded = _yield_turn(turn_addr, attaches_before)
        var job = pool.next_job(lane if lane > 0 else 0, buf)
        if turn_addr != 0:
            _ = shared_fetch_add(turn_addr, 1)
        var t_attach = perf_counter_ns()
        cpy.PyEval_RestoreThread(ts)
        if turn_addr != 0:
            _ = shared_fetch_add(turn_addr, -1)
            _ = shared_fetch_add(turn_addr + 8, 1)
            var t_held = perf_counter_ns()
            # A new run starts when this thread gave the GIL away, or had to
            # wait for it: a thread that queued a millisecond for its turn
            # must not be over its slice the moment it gets one.
            if yielded or t_held - t_attach >= TURN_WAITED_NS:
                streak_start = t_held
        if job.kind == JOB_STOP:
            break

        if job.kind == JOB_WS_MESSAGE:
            # An inbound frame from a socket THIS mount's view gated. It is
            # not a request the loop is waiting on — nothing is owed on the
            # completion channel — so it is served and its response dropped,
            # exactly as the loop-thread path did before the pool could take
            # a hold. What the view does (publishing, writing) is the point.
            handler.serve_ws_message(
                job.slot,
                job.opcode,
                String(
                    StringSpan(
                        unsafe_from_utf8=Span(buf)[
                            job.chan_start : job.chan_start + job.chan_len
                        ]
                    )
                ),
                Span(buf)[job.payload_start : job.payload_start + job.payload_len],
            )
            continue

        var slot = job.slot
        var request = pool.take_request(slot)
        # Read before `func` consumes the request: `after_response` needs both,
        # and the loop cannot supply them — it gave the request away.
        var request_method = request.method
        var request_path = request.uri.path

        var response: HTTPResponse
        var raised = False
        var early = handler.before_request(request)
        if early:
            var early_resp = early.take()
            response = early_resp^
        else:
            try:
                response = handler.func(request^)
            except:
                # Same policy as the synchronous path: a raising handler is a
                # 500 AND a closed connection, because what it left behind is
                # unknown. The loop cannot infer that from the status — a
                # handler may return 500 deliberately — so it is signalled.
                response = InternalError()
                raised = True
        handler.after_response(request_method, request_path, response)

        if response.sse_streaming and ack_write >= 0 and handler.stream_pending():
            # A streamed WSGI body: this thread is its producer, on the
            # same chunk channel the executor uses, and the order below is
            # the executor's. Register where credit comes back FIRST (the
            # begin frame's send publishes it), send the begin frame
            # SECOND, and only then complete the head — begin before head,
            # so the loop's handler is subscribed before the slot can ever
            # be seen streaming. Stale acks from this thread's previous
            # stream are discarded first, or one would pre-credit this one.
            drain_ack_fd(ack_read)
            pool.set_slot_ack_fd(slot, ack_write)
            response.stream_gen = gen
            if handler.stream_begin(slot, gen, ack_write):
                pool.put_response(slot, response^, raised)
                pool.complete(slot)
                # The body: chunk by chunk, credit by credit, until the
                # iterable ends, raises, or the client is gone.
                handler.stream_pump(slot, gen, ack_read, pool)
                gen += 1
                continue
            # The channel would not take the begin frame — the loop is not
            # draining it. `stream_begin` closed the iterable; answer with
            # something the client can parse rather than an empty head that
            # promises a body.
            pool.clear_slot_ack_fd(slot)
            response = _stream_unavailable()
            raised = True

        # Park, THEN poke: the completion send is the happens-before edge that
        # publishes this write to the loop thread. Reversing them is a race
        # that would read a half-written response, and it would be rare enough
        # to look like anything else.
        pool.put_response(slot, response^, raised)
        pool.complete(slot)

    # After the poison pill, before the handler's destructors: the one
    # point where this thread is attached, idle, and still owns its app.
    handler.shutdown()


def _stream_unavailable() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String(
            '{"error":"the stream channel would not take this response"}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=503,
        status_text="Service Unavailable",
    )


comptime TURN_SLICE_NS = 1_000_000
"""How long a pool thread may keep re-taking the GIL past parked waiters
before it must hand off: the bound on any waiter's extra wait, and the
period of the thread switch a hand-off costs. CPython's own switch
interval is 5 ms; this is fairer by five and, on views of a few hundred
microseconds, hands off every few jobs rather than every job."""

comptime TURN_WAITED_NS = 50_000
"""A `PyEval_RestoreThread` longer than this waited for another thread,
and the run it begins is a new one for the slice."""

comptime TURN_YIELD_NS = 1_000_000
"""How long a dropping thread yields for a parked waiter to acquire. A
waiter that never does -- the GIL taken meanwhile by a view re-acquiring it
inside CPython, where these counters cannot see -- costs a bounded spin,
not a stall."""


def _yield_turn(addr: Int, attaches_before: Int) -> Bool:
    """The hand-off barrier: after dropping the GIL, if another pool thread
    is parked waiting for it, yield until an attach completes. Returns
    whether there was a waiter to yield to.

    `addr` holds the waiter count, `addr + 8` the attach count. A parked
    waiter is already inside `PyEval_RestoreThread`, so the GIL never sits
    free while it wakes; the yield only keeps THIS thread from winning the
    race back. No syscall on the common path (no waiter: return at once).
    """
    if shared_load(addr) <= 0:
        return False
    var deadline = perf_counter_ns() + TURN_YIELD_NS
    while shared_load(addr + 8) == attaches_before:
        _ = external_call["sched_yield", c_int]()
        if perf_counter_ns() > deadline:
            return True
    return True


def _pool_body[T: ThreadHandler](arg: Int) -> Int:
    """pthread start routine: attach, serve, release, report."""
    var block = ThreadBlock(arg)
    ref cpy = Python().cpython()
    var gs = cpy.PyGILState_Ensure()
    var status = STATUS_RAISED
    try:
        _pool_serve[T](block)
        status = STATUS_OK
    except e:
        print(
            "blocking-thread[" + String(block.get(BLK_INDEX)) + "] raised: "
            + String(e),
            flush=True,
        )
    cpy.PyGILState_Release(gs)
    block.set(BLK_STATUS, status)
    return 0
