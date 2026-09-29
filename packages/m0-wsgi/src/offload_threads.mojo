"""The threads behind one event loop's `OffloadPool`, wired once for both execution modes.

A loop that hands requests to threads has the same shape under prefork
(`m0serve`'s `_serve_offloaded`, one loop per worker process) and under
`--threads` (`_serve_one`, one loop per thread): a submit lane per mount, an
asyncio executor per ASGI lane, WSGI handler threads over the WSGI lanes, the
streaming channels they share, and a bounded, detached join at the end. The
two were written out twice and had drifted -- the guard that starts no WSGI
pool for a mount set with no WSGI mount lived in the prefork copy alone -- so
`wire_offload` and `join_offload` are the one copy, and what differs between
the modes arrives as an argument: the handler type, whose options (`user`),
where a pool thread's hold goes (`hold_notify_fd`), and whether the pool wakes
eagerly (the caller's `set_parallel`, before any of this).

What stays with the caller is what only it can do: the loop itself (prefork
releases its thread state for the whole run, a threaded loop detaches around
each wait), the inversion (prefork, unmounted ASGI), and the compiled mounts'
pools, whose handler types (`MojoMount`, `HoldMount`) are the entry file's.
`wire_offload` sizes and reserves those pools and leaves them unstarted;
`join_offload` stops them with the rest.

The rules this file keeps are `packages/m0-wsgi/AGENTS.md`'s: one pool per
loop; every pool's wake records reserved before any thread starts; a lane's
executor learns where its disconnect tags go before it starts; the chunk
channel exists before the first producer does; and the join is detached
(a thread finishing its last job must attach) and bounded, leaving through
`_exit` past its budget rather than hanging SIGTERM.
"""

from std.python import Python

from lightbug_http.c.process import process_exit
from lightbug_http.offload import OffloadPool
from m0_http import MojoPool

from .asgi_executor import AsgiExecutor
from .blocking_pool import BlockingPool, JOIN_TIMEOUT_NS
from .cli import ServeOptions, hold_lanes, mojo_lanes, pool_thread_count, wsgi_lanes
from .thread_handler import ThreadHandler


struct OffloadThreads(Movable):
    """Every thread one loop's pool is served by: what `join_offload` stops."""

    var executors: AsgiExecutor
    """One asyncio executor per ASGI lane, or one on the base lane."""
    var handler_pool: BlockingPool
    """The WSGI handler threads, dealt round-robin over the WSGI lanes."""
    var mojo_pool: MojoPool
    """`--mount PREFIX=mojo`'s threads: sized here, started by the caller."""
    var hold_pool: MojoPool
    """`--mount PREFIX=hold`'s threads: sized here, started by the caller."""
    var run_executor: Bool
    """Whether `executors` was started."""

    def __init__(out self):
        """Nothing wired: a loop that calls the application itself."""
        self.executors = AsgiExecutor(1)
        self.handler_pool = BlockingPool(0)
        self.mojo_pool = MojoPool(0)
        self.hold_pool = MojoPool(0)
        self.run_executor = False

    def __init__(
        out self,
        var executors: AsgiExecutor,
        var handler_pool: BlockingPool,
        var mojo_pool: MojoPool,
        var hold_pool: MojoPool,
        run_executor: Bool,
    ):
        """What `wire_offload` built. The threads it started hold heap
        blocks and the pool's address, never these values', so they move."""
        self.executors = executors^
        self.handler_pool = handler_pool^
        self.mojo_pool = mojo_pool^
        self.hold_pool = hold_pool^
        self.run_executor = run_executor


def wire_offload[T: ThreadHandler](
    mut pool: OffloadPool,
    mut handler: T,
    opts: ServeOptions,
    executor: Bool,
    blocking_threads: Int,
    user: Int,
    hold_notify_fd: Int = -1,
) raises -> OffloadThreads:
    """Declare this loop's lanes and start the threads that serve them.

    `handler` is the LOOP's own handler, which learns the pool's address and
    where each lane's disconnect tags and inbound WebSocket messages go.
    `executor` is `use_asgi_executor`'s answer and `blocking_threads` the
    resolved pool size; `user` is what each thread's `T.make` receives as
    `ctx.user` -- the address of `opts`. `hold_notify_fd` is this loop's own
    bus channel under `--realtime`, or -1: a pool thread's hold must land in
    THIS loop's registries, whose slot numbers are the only ones it means.

    Lane i is mount i, so the loop's `submit(slot, path)` and the handler's
    `app_for(path)` cannot disagree: both ask `match_path_prefix` the same
    question about the same table.
    """
    # The loop's handler needs the pool for one thing: a chunk frame its
    # outbox has to refuse must abort the stream rather than vanish. See
    # `WSGIHandler.abort_pool_addr`.
    handler.set_abort_pool(pool.addr())
    if hold_notify_fd >= 0:
        pool.set_hold_notify(hold_notify_fd)
    for i in range(len(opts.mount_prefixes)):
        pool.add_lane(opts.mount_prefixes[i])
    # A compiled mount's threads never attach, so its lane is not queueing
    # for a GIL and a job that has waited past the spin gets a sibling woken
    # whether or not the ring is moving (`OffloadPool.lane_gil_free`). After
    # `add_lane`, which declared these lanes.
    var mojo_ln = mojo_lanes(opts)
    var hold_ln = hold_lanes(opts)
    for i in range(len(mojo_ln)):
        pool.set_lane_gil_free(mojo_ln[i])
    for i in range(len(hold_ln)):
        pool.set_lane_gil_free(hold_ln[i])

    var handler_pool = BlockingPool(pool_thread_count(opts, executor, blocking_threads))
    var mojo_pool = MojoPool(blocking_threads if len(mojo_ln) > 0 else 0)
    var hold_pool = MojoPool(blocking_threads if len(hold_ln) > 0 else 0)
    # Every pool thread's wake record, reserved ONCE and before any pool
    # starts: `reserve_threads` sizes the block on its first call and
    # ignores the rest, and when the WSGI pool was the only caller the Mojo
    # and hold pools' threads found no record left.
    pool.reserve_threads(handler_pool.count + mojo_pool.count + hold_pool.count)

    var asgi_ln = opts.asgi_mounts.copy()
    var executors = AsgiExecutor(len(asgi_ln) if len(asgi_ln) > 0 else 1)
    var run_executor = executor or len(asgi_ln) > 0
    if run_executor:
        # The streaming channels exist before any executor thread does, so
        # their fds are plain fields by the time anything reads them. Every
        # executor gets its OWN drain-ack pair: credit belongs to the
        # executor owning the slot, and an ack routed elsewhere is a stream
        # stalled forever. Its disconnect tags go on that mount's own submit
        # channel, since that is where it is parked.
        pool.enable_stream_channel()
        pool.enable_base_stream_ack()
        # The pump: the loop keeps its per-pass outbox sweep even with no
        # stream open, because the microsecond it costs is what lets a pass
        # batch submits (offload.mojo, `sweeps_every_pass`).
        pool.set_sweep_every_pass()
        if len(asgi_ln) == 0:
            handler.set_asgi_notify(pool.submit_write_fd(-1))
        for k in range(len(asgi_ln)):
            var lane = asgi_ln[k]
            pool.enable_stream_ack(lane)
            handler.set_lane_notify(lane, pool.submit_write_fd(lane))
        executors.start(pool.addr(), user, asgi_ln^, qos=opts.qos)

    if handler_pool.count > 0:
        # Pool threads stream WSGI iterables through the chunk channel the
        # executor uses -- a second producer on one FIFO -- so a pure-WSGI
        # pool server creates it too. NOT the executor's ack pair:
        # `stream_active()` keeps meaning "an executor exists", which is what
        # keeps an M0-Hold on this loop from being mistaken for a channel
        # stream.
        if not pool.chunk_active():
            pool.enable_stream_channel()
        var wsgi_ln = wsgi_lanes(opts)
        if opts.realtime:
            # Where an inbound WebSocket message goes when a pool thread's
            # view held the socket: that mount's own submit lane, so the
            # frame is served by a thread that has that urlconf and no other.
            if len(wsgi_ln) == 0:
                handler.set_ws_pool_notify(-1, pool.submit_write_fd(-1))
            for wl in range(len(wsgi_ln)):
                handler.set_ws_pool_notify(wsgi_ln[wl], pool.submit_write_fd(wsgi_ln[wl]))
        handler_pool.start[T](pool.addr(), user, wsgi_ln^, qos=opts.qos)
    return OffloadThreads(
        executors^, handler_pool^, mojo_pool^, hold_pool^, run_executor
    )


def join_offload(mut threads: OffloadThreads, mut pool: OffloadPool, who: String) raises:
    """Stop and join every thread `wire_offload` sized, after the loop returned.

    Detached across it: a thread finishing its last job, or the executor
    draining its tasks, has to attach, and it cannot while this thread holds
    a state and blocks in `pthread_join`. Pills go per lane, because a
    thread parked on lane 2 is not woken by one sent to lane 0 and
    `next_job` has no timeout -- each pool's `stop_and_join` sends its own.

    Bounded by `JOIN_TIMEOUT_NS`: a thread still inside the application
    after the drain and the join budget is not coming back -- a response
    that never ends holds it for the life of the process -- and nothing here
    can unwind Python on another thread, so the process leaves the way a
    forked worker does, `_exit` with no teardown, every connection the loop
    could answer already answered. The alternative was a SIGTERM that did
    nothing until `docker stop` sent SIGKILL. `who` opens both lines this
    prints (`m0serve: `, `thread[2] `).
    """
    ref cpy = Python().cpython()
    var join_ts = cpy.PyEval_SaveThread()
    var failed = 0
    var stuck = 0
    if threads.run_executor:
        failed += threads.executors.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += threads.executors.stragglers
    if threads.handler_pool.count > 0:
        failed += threads.handler_pool.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += threads.handler_pool.stragglers
    if threads.mojo_pool.count > 0:
        failed += threads.mojo_pool.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += threads.mojo_pool.stragglers
    if threads.hold_pool.count > 0:
        failed += threads.hold_pool.stop_and_join(pool, JOIN_TIMEOUT_NS)
        stuck += threads.hold_pool.stragglers
    if stuck > 0:
        print(
            who + String(stuck) + " handler thread(s) still inside the"
            " application " + String(JOIN_TIMEOUT_NS // 1_000_000_000)
            + " s after the drain; exiting without them",
            flush=True,
        )
        process_exit(0)
    cpy.PyEval_RestoreThread(join_ts)
    if failed > 0:
        print(
            who + String(failed) + " offload thread(s) did not exit cleanly",
            flush=True,
        )
