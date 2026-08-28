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
- **Streaming handlers are refused, loudly.** `sse_drain_slot`,
  `sse_slot_disconnected` and `ws_message` are called on the LOOP's handler,
  while `func` here runs against a pool thread's own handler and its own
  registries — so a stream begun on a pool thread has no producer the loop
  can drain. `_pool_serve` answers 409 rather than serving a head that
  promises a body nothing will write.
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

from lightbug_http.offload import OffloadPool, JOB_REQUEST, JOB_WS_MESSAGE, JOB_STOP
from lightbug_http.http import HTTPResponse, Headers, Header, HeaderKey
from lightbug_http.http.common_response import InternalError
from lightbug_http.service import HTTPService

# The same back-edge `event_loop.mojo` uses for `m0_http.log`, and for the
# same reason: `threads.mojo` is framework code, both sides live inside
# `packages/m0-http/`, and the cycle never crosses a package boundary. It is
# also why this file is HERE rather than in `src/` — a trait a handler must
# conform to has to be source-visible to apps the way `HTTPService` is. Behind
# the `.mojoc` its required methods mention `m0_http`'s own `HTTPRequest`
# while an app's conformance mentions `lightbug_http`'s, and the witness table
# is silently never emitted ("does not have witness table for trait").
from m0_http.threads import (
    ThreadSet, ThreadBlock, BLK_INDEX, BLK_USER, BLK_STATUS, BLK_LANE,
    STATUS_OK, STATUS_RAISED,
)


comptime BLK_POOL = 7
"""Block slot holding the `OffloadPool`'s address. Same slot the WSGI pool
uses, and for the same reason: `BLK_INTS` is 8, so 7 is the last one free."""

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
    does. Nothing in-tree uses it yet; it is here because `start` already has
    to write a lane into the block for `stop_and_join` to send its pill to the
    right place, and hiding that from `make` would be arbitrary.
    """

    def __init__(out self, index: Int, user: Int, lane: Int = -1):
        self.index = index
        self.user = user
        self.lane = lane


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
        for i in range(self.count):
            var lane = -1 if len(lanes) == 0 else lanes[i % len(lanes)]
            self._lanes.append(lane)
            var block = self._set.block(i)
            block.set(BLK_USER, user)
            block.set(BLK_POOL, pool_addr)
            block.set(BLK_LANE, lane)
        for i in range(self.count):
            self._set.spawn(i, body_addr)
        self._started = True

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

    var handler = T.make(PoolContext(index, block.get(BLK_USER), lane))

    # One receive buffer for this thread's life, not one per job.
    var buf = List[UInt8](capacity=JOB_BUFFER)
    for _ in range(JOB_BUFFER):
        buf.append(0)

    while True:
        var job = pool.next_job(lane if lane > 0 else 0, buf)
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
        if response.sse_streaming:
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
    var status = STATUS_RAISED
    try:
        _pool_serve[T](block)
        status = STATUS_OK
    except e:
        print(
            "mojo-pool[" + String(block.get(BLK_INDEX)) + "] raised: " + String(e),
            flush=True,
        )
    block.set(BLK_STATUS, status)
    return 0
