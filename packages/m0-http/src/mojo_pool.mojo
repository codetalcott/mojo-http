"""Handler threads for a **Mojo** handler — the pool without an interpreter.

`m0-wsgi`'s `blocking_pool.mojo` puts N handler threads behind one event loop
so a slow view stops holding the keep-alive connections pinned to that loop
(p99 1.0 ms -> 190.7 ms without it, -> 7.4 ms with; docs/BENCHMARKS.md). That
file is the same shape as this one and cannot be shared: it imports
`std.python`, and importing it here would put libpython on the link line of
every Mojo app in the repo. `lightbug_http.offload` was written for exactly
this split — its docstring says it "knows nothing about Python or about
handlers" — so what is left is the thread body below.

**Only for handlers that BLOCK.** A pool buys nothing for a handler that is
merely slow to compute: `std.runtime.asyncrt` already parallelises CPU work
inside one handler (measured 3.6x on four tasks) with no threads of our own,
and a compute-bound handler on a pool thread is the same work on a different
core. What a pool answers is a handler parked in a syscall — a database round
trip, a subprocess, an outbound HTTP call, `sleep` — because that is what an
event loop cannot multiplex away.

Rules, inherited from the WSGI pool and load-bearing for the same reasons:

- **One pool per loop.** A job names a slot and a slot indexes one loop's
  `ProvisionPool`; a pool shared between loops would answer the wrong
  connection.
- **Each thread owns a whole handler**, built by `T.make(ctx)` on the thread
  that will use it. Nothing in a handler is shared between pool threads
  unless the handler itself shares it, deliberately and safely.
- **No `DetachingBackend` here.** The loop must detach around its wait only
  because of the GIL; with no interpreter there is nothing to detach from,
  and the plain `KqueueBackend`/`EpollBackend` is correct.
- **Streaming handlers are refused, loudly — unless the stream is a hold.**
  `sse_drain_slot`, `sse_slot_disconnected` and `ws_message` are called on
  the LOOP's handler, while `func` here runs against a pool thread's own
  handler and its own registries — so a stream begun on a pool thread has
  no producer the loop can drain. `_pool_serve` answers 409 rather than
  serving a head that promises a body nothing will write. The one stream a
  pool thread CAN begin is an `M0-Hold: stream`, because a hold has no
  producer of its own: the loop drains it from its registries and the bus
  feeds it. A handler returns the same two instruction headers a Django
  view returns (`lightbug_http/hold.mojo`), and this thread does what a
  WSGI pool thread does with them — rewrites the response into the
  stream's head, sends the loop an `h` frame on the loop's own bus channel
  BEFORE completing (the frame is what subscribes the slot, in the
  registries the loop actually drains), and completes with the head. Only
  where the loop wired a channel (`OffloadPool.hold_notify_fd`, set by
  `m0serve --realtime`); without one the headers go to the wire as they
  would under any server that has never heard of them. A `websocket` hold
  degrades the same way (`take_stream_hold`): nothing here performs a 101.
- **`before_request` runs TWICE per pooled request**, and that is the loop's
  contract, not an accident here: once on the LOOP's handler before the job
  is submitted (`event_loop.mojo` — what answers there never becomes a job),
  and once on the pool thread's own handler inside `_pool_serve`. The WSGI
  pool has the same double call and `WSGIHandler` neutralises its pool-side
  one; a Mojo handler whose `before_request` has side effects (a rate
  counter, a metric) must expect both. The useful consequence: put the paths
  that must stay responsive whatever the pool is doing — `/health` above
  all — in the LOOP handler's `before_request`, or they queue behind a
  saturated pool like everything else.
"""

from std.time import perf_counter_ns, sleep

from lightbug_http.offload import OffloadPool, JOB_REQUEST, JOB_WS_MESSAGE, JOB_STOP
from lightbug_http.http import HTTPResponse, Headers, Header, HeaderKey
from lightbug_http.http.common_response import InternalError
from lightbug_http.service import HTTPService
from lightbug_http.hold import take_stream_hold, request_last_event_id, send_hold_frame
from lightbug_http.c.process import getpid

# This file lived in the fork until 2026-09-18, because on Mojo 1.0 an app's
# conformance to `PoolHandler` behind the `.mojoc` got no witness table. The
# cause was the package's name differing from its source directory, Mojo
# 1.1.0 fixed it, and `poe check-mojoc-trait` is the regression guard
# (DECISIONS D28, retired).
from .threads import (
    ThreadSet, ThreadBlock, BLK_INDEX, BLK_USER, BLK_STATUS, BLK_LANE,
    STATUS_NEVER_RAN, STATUS_OK, STATUS_RAISED,
)


comptime BLK_POOL = 7
"""Block slot holding the `OffloadPool`'s address. Same slot the WSGI pool
uses, and for the same reason: `BLK_INTS` is 8, so 7 is the last one free."""

comptime BLK_THREAD_ID = 10
"""Block slot holding this thread's registered id (`register_thread`), or -1.
The slot `m0_wsgi.blocking_pool` uses for the same value."""

comptime BLK_READY = 11
"""Block slot a pool thread sets to 1 once `T.make` has returned.

What `wait_ready` polls: a thread whose `make` raised never sets it and
ends with `STATUS_RAISED` instead, so a caller that must not serve short
(the Mojo host, D30) can tell "still building" from "refused" without a
thread-level error channel. Until 2026-09-17 a raising `make` here left the
pool serving on with one thread fewer and nothing but a log line to say so
-- an existing gap under `m0serve`, and a contradiction of D30 the day the
host took a lane."""

comptime JOB_BUFFER = 4096
"""Bytes a pool thread's receive buffer holds.

An ordinary job is 8 bytes. The WSGI pool sizes its buffer at 64 KB because
an inbound WebSocket message rides IN the datagram; nothing here takes a
WebSocket hold (that needs the `--realtime` machinery, which is `m0-wsgi`'s),
so a datagram larger than a job cannot arrive. `next_job` treats `len(buf)`
as the most a datagram may be, and a `JOB_WS_MESSAGE` that somehow did arrive
is skipped below rather than truncated.
"""

comptime JOIN_TIMEOUT_NS = 5_000_000_000
"""How long `stop_and_join` waits before leaving a thread behind.

The same budget the WSGI pool and the loop's drain use. A Mojo handler
blocked in a syscall with no timeout holds its thread for as long as the
syscall does, and `pthread_join` has none — so past this the caller is
expected to leave without it rather than make SIGTERM a no-op.
"""


struct PoolContext(Copyable, Movable):
    """What a handler factory is handed: which thread, and the app's own data."""

    var index: Int
    """This thread's index in the pool, 0-based."""
    var user: Int
    """The address the app passed to `MojoPool.start` — its own config,
    connection string, or whatever `make` needs to build a handler."""
    var lane: Int
    """Which submit lane this thread serves, or -1 for the single-lane pool.

    Present so a mounted server can deal threads per mount the way `m0serve`
    does. It is here because `start` already has to write a lane into the
    block for `stop_and_join` to send its pill to the right place, and
    hiding that from `make` would be arbitrary; `prefix` below is what a
    handler actually reads.
    """
    var prefix: String
    """The path prefix the lane serves — `--mount PREFIX=mojo`'s PREFIX —
    or empty for an unmounted pool and for the root mount.

    Read off the pool's own lane table (`OffloadPool.lane_prefixes`), the
    table the loop routes by, so a handler that builds its URL table under
    `Mount(ctx.prefix)` matches exactly the paths it is sent and renders
    links that carry the prefix. Nothing else tells a handler where it is
    mounted: a request arrives with its path whole, and a table that
    registered `/probe` would never see `/native/probe`.
    """

    def __init__(
        out self, index: Int, user: Int, lane: Int = -1, prefix: String = ""
    ):
        self.index = index
        self.user = user
        self.lane = lane
        self.prefix = prefix


trait PoolHandler(HTTPService, Movable, Deinitable):
    """An `HTTPService` that can construct itself on a pool thread.

    Two methods, against `ThreadHandler`'s eleven: the other nine on the WSGI
    side exist for streaming, mounts and WebSocket holds, none of which a pool
    thread does here. A trait rather than a function parameter because Mojo
    1.0 cannot materialize a function-parameterized `def` as a runtime value —
    the address a pthread needs; a type parameter it can.
    """

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        """Build this thread's handler, ON this thread. Called once."""
        ...

    def shutdown(mut self):
        """Called after the poison pill, before the handler is destroyed.

        The one point where the thread is idle and still owns its handler.
        Must not raise: teardown has nowhere to send an error.
        """
        pass


struct MojoPool(Movable):
    """N handler threads against one loop's `OffloadPool`.

        var pool = OffloadPool(config.max_connections)
        var threads = MojoPool(4)
        threads.start[MyHandler](pool.addr())
        server.listen_and_serve_nonblocking(addr, handler, offload_addr=pool.addr())
        _ = threads.stop_and_join(pool, JOIN_TIMEOUT_NS)

    `stop_and_join` rather than a separate `stop(n)` + `join()`: the pill
    count must equal the thread count exactly, because `next_job` blocks with
    no timeout and a thread that gets no pill hangs the join forever. Keeping
    both under one method makes that a property of the type rather than an
    agreement between two call sites that could drift.
    """

    var count: Int
    var _set: ThreadSet
    var _started: Bool
    var _lanes: List[Int]
    var stragglers: Int
    """Threads `stop_and_join` gave up waiting for: still inside the handler
    when its budget ran out, left running and unjoined."""

    def __init__(out self, count: Int):
        self.count = count
        self._set = ThreadSet(count)
        self._started = False
        self._lanes = List[Int]()
        self.stragglers = 0

    def __init__(out self, *, deinit move: Self):
        self.count = move.count
        self._set = move._set^
        self._started = move._started
        self._lanes = move._lanes^
        self.stragglers = move.stragglers

    def start[T: PoolHandler](
        mut self, pool_addr: Int, user: Int = 0, var lanes: List[Int] = List[Int]()
    ) raises:
        """Spawn the threads. `user` is what `T.make` receives as `ctx.user`."""
        var body = _pool_body[T]
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        self._lanes = List[Int]()
        # A wake channel per thread, reserved on the spawning thread before
        # any of them exists. A no-op when the caller reserved already --
        # the reservation is made ONCE per pool, so a server running this
        # beside a `BlockingPool` reserves for both before starting either
        # (`m0serve._serve_offloaded`); a thread past the reservation still
        # counts on its lane and parks on the lane socket.
        ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
            unsafe_from_address=pool_addr
        )[]
        pool.reserve_threads(self.count)
        for i in range(self.count):
            var lane = -1 if len(lanes) == 0 else lanes[i % len(lanes)]
            self._lanes.append(lane)
            var block = self._set.block(i)
            block.set(BLK_USER, user)
            block.set(BLK_POOL, pool_addr)
            block.set(BLK_LANE, lane)
            # Registered HERE, before the thread exists, never in its body:
            # `stop` pills every registered thread on its own channel and
            # sends the rest to the lane socket, so a thread that registered
            # after a `stop` already ran would park on a channel with no pill
            # in it while its pill sat on a socket it no longer reads -- a
            # hung join, caught by `test_stop_and_join_ends_every_thread`,
            # which stops the pool the instant it starts. Registered here,
            # the pill is waiting for it whenever it gets there.
            block.set(BLK_THREAD_ID, pool.register_thread(lane if lane > 0 else 0))
        for i in range(self.count):
            self._set.spawn(i, body_addr)
        self._started = True

    def wait_ready(self, timeout_ns: Int) raises -> Int:
        """How many threads have NOT built their handler within `timeout_ns`.

        Polls each thread's `BLK_READY` word, which `_pool_serve` sets the
        instant `T.make` returns; a thread whose `make` raised has ended
        with `STATUS_RAISED` by then and is counted at once rather than
        waited for. Zero means every thread is parked on its lane with a
        handler of its own. The Mojo host calls this before it serves, so a
        `make` that raises on a pool thread is a refusal (exit 78) rather
        than a server quietly one thread short.
        """
        if not self._started:
            return 0
        var deadline = perf_counter_ns() + timeout_ns
        var short = 0
        for i in range(self.count):
            var block = self._set.block(i)
            while (
                block.get(BLK_READY) == 0
                and self._set.status(i) == STATUS_NEVER_RAN
                and perf_counter_ns() < deadline
            ):
                sleep(0.001)
            if block.get(BLK_READY) == 0:
                short += 1
        return short

    def raised_before_ready(self) -> Int:
        """How many threads ended (`STATUS_RAISED`) without ever setting
        `BLK_READY`: a `make` that raised, as opposed to one still
        building. For the caller of `wait_ready` to say which."""
        if not self._started:
            return 0
        var n = 0
        for i in range(self.count):
            if (
                self._set.block(i).get(BLK_READY) == 0
                and self._set.status(i) == STATUS_RAISED
            ):
                n += 1
        return n

    def stop_and_join(
        mut self, mut pool: OffloadPool, timeout_ns: Int = -1
    ) raises -> Int:
        """Poison the queue with one pill per thread, then join.

        Returns the count that did not end cleanly. With `timeout_ns >= 0` the
        join is bounded and a thread still inside the handler when the budget
        runs out is counted in `stragglers`, left unjoined, and the caller is
        expected to leave the process without it.
        """
        if not self._started:
            return 0
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


def _hold_unavailable() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String(
            '{"error":"the stream could not be registered with the event loop; retry"}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=503,
        status_text="Service Unavailable",
    )


def _streaming_refused() -> HTTPResponse:
    """What a pool thread answers when a handler tries to stream from one.

    409, matching `gate_streaming_response`'s refusal of a stream on the
    blocking loop: the same class of mistake — a streaming response where
    nothing can drain it — answered with the same status.
    """
    return HTTPResponse(
        body_bytes=String(
            '{"error":"a streaming response cannot be served from a pool'
            ' thread: the loop drains its own handler registries, not this'
            ' thread s"}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=409,
        status_text="Conflict",
    )


def _pool_serve[T: PoolHandler](block: ThreadBlock) raises:
    """One pool thread's whole life.

    Separate from `_pool_body` so the handler is destroyed when this scope
    ends, before the body reports its status — the same split `blocking_pool`
    makes so a handler's destructors run while the thread still exists.
    """
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_POOL)
    )[]
    var lane = block.get(BLK_LANE)
    var index = block.get(BLK_INDEX)
    var thread_id = block.get(BLK_THREAD_ID)

    # The lane's prefix, from the same table the loop routes by. Lane -1 is
    # the single-lane pool and lane 0 an unmounted server's only lane; both
    # read as the root. A mounted lane's prefix is what its mount was given.
    var prefix = String("")
    if lane >= 0 and lane < len(pool.lane_prefixes):
        prefix = pool.lane_prefixes[lane]
    var handler = T.make(PoolContext(index, block.get(BLK_USER), lane, prefix))
    # Built: what `wait_ready` is waiting to see. A `make` that raised never
    # gets here, and the body reports `STATUS_RAISED` instead.
    block.set(BLK_READY, 1)

    # One receive buffer for this thread's life, not one per job.
    var buf = List[UInt8](capacity=JOB_BUFFER)
    for _ in range(JOB_BUFFER):
        buf.append(0)

    while True:
        # With the id, parked on this thread's own channel: `stop` pills a
        # registered thread by name, so a thread that registered and then
        # waited on the lane socket would never see its pill.
        var job = pool.next_job(lane if lane > 0 else 0, buf, thread_id)
        if job.kind == JOB_STOP:
            break
        if job.kind == JOB_WS_MESSAGE:
            # Nothing here takes a WebSocket hold, so this cannot arrive from
            # a correct sender. Skipping beats serving: the loop is not
            # waiting on a completion for it, so dropping it strands nothing.
            continue

        var slot = job.slot
        var request = pool.take_request(slot)
        # Read before `func` consumes the request: `after_response` needs
        # both, and the loop cannot supply them — it gave the request away.
        # The reconnect cursor too: a hold's subscription starts where the
        # client says it left off, and only the request knows.
        var request_method = request.method
        var request_path = request.uri.path
        var last_event_id = request_last_event_id(request)

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
        var held = False
        if not raised and pool.hold_notify_fd >= 0:
            # An `M0-Hold: stream` from a Mojo handler: the same headers a
            # Django view returns, taken the way a WSGI pool thread takes
            # them. The frame goes BEFORE the completion below — the loop
            # drains its bus channels before it finishes a streaming head,
            # so the subscription is in place when the head goes out. A
            # frame the channel would not take is a client on a stream
            # nothing feeds, hence 503 rather than the head.
            var hold = take_stream_hold(response)
            if hold.held:
                if send_hold_frame(
                    pool.hold_notify_fd, slot, last_event_id, hold.channel,
                    kind=String("h"), lane=lane,
                ):
                    response.headers["x-worker"] = String(getpid())
                    held = True
                else:
                    response = _hold_unavailable()
        if response.sse_streaming and not held:
            # See the module docstring: the loop drains ITS handler, not this
            # one, so this stream would have no producer. Refused BEFORE
            # `after_response`, so that hook observes the 409 that actually
            # goes to the wire rather than a response that never will.
            print(
                "mojo-pool["
                + String(index)
                + "]: refused a streaming response from a pool thread ("
                + request_method
                + " "
                + request_path
                + ")",
                flush=True,
            )
            response = _streaming_refused()
            raised = True
        handler.after_response(request_method, request_path, response)

        # Park, THEN poke: the completion send is the happens-before edge that
        # publishes this write to the loop thread. Reversing them is a race
        # that would read a half-written response.
        pool.put_response(slot, response^, raised)
        pool.complete(slot)

    handler.shutdown()


def _pool_body[T: PoolHandler](arg: Int) -> Int:
    """pthread start routine: serve, then report.

    No attach/detach bracket and no GIL, which is the whole difference from
    `blocking_pool._pool_body`.
    """
    var block = ThreadBlock(arg)
    # Counted on its lane from `start` until it leaves, however it leaves --
    # the WSGI pool's rule, which this pool skipped. Uncounted, the lane read as
    # "every thread parked" to `_all_idle` whenever its one awake thread was
    # busy, so `submit` poked a sibling on nearly every push: measured on
    # `/native/probe` at 16 connections as 65k wakes with one thread and
    # 202k with eight, the eight serving 20 % fewer requests on more CPU,
    # while the WSGI lane beside it reported its threads and woke nobody.
    # `start` registered it, on the spawning thread; see there for why.
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_POOL)
    )[]
    var lane = block.get(BLK_LANE)
    lane = lane if lane > 0 else 0
    var status = STATUS_RAISED
    try:
        _pool_serve[T](block)
        status = STATUS_OK
    except e:
        print(
            "mojo-pool[" + String(block.get(BLK_INDEX)) + "] raised: " + String(e),
            flush=True,
        )
    pool.unregister_thread(block.get(BLK_THREAD_ID), lane)
    block.set(BLK_STATUS, status)
    return 0
