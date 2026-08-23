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

from std.python import Python

from lightbug_http.offload import OffloadPool
from lightbug_http.http import HTTPResponse
from lightbug_http.http.common_response import InternalError

from m0_http import (
    ThreadSet, ThreadBlock, BLK_INDEX, BLK_USER, BLK_STATUS,
    STATUS_OK, STATUS_RAISED,
)

from .thread_handler import ThreadContext, ThreadHandler


comptime BLK_POOL = 7
"""Block slot holding the `OffloadPool`'s address."""


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

    def __init__(out self, count: Int):
        self.count = count
        self._set = ThreadSet(count)
        self._started = False

    def __init__(out self, *, deinit move: Self):
        self.count = move.count
        self._set = move._set^
        self._started = move._started

    def start[T: ThreadHandler](mut self, pool_addr: Int, user: Int) raises:
        """Spawn the threads. `user` is what `T.make` receives as `ctx.user`."""
        var body = _pool_body[T]
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        for i in range(self.count):
            var block = self._set.block(i)
            block.set(BLK_USER, user)
            block.set(BLK_POOL, pool_addr)
        for i in range(self.count):
            self._set.spawn(i, body_addr)
        self._started = True

    def stop_and_join(mut self, mut pool: OffloadPool) raises -> Int:
        """Poison the queue with one pill per thread, then join. Returns the
        count that did not end cleanly.

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
        pool.stop(self.count)
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
    var ctx = ThreadContext(block.get(BLK_INDEX), block.get(BLK_USER))
    var handler = T.make(ctx)
    ref cpy = Python().cpython()

    while True:
        # Detached across the block. This is where the thread spends its life,
        # and holding a thread state through it would stall every other
        # thread's stop-the-world.
        var ts = cpy.PyEval_SaveThread()
        var slot = pool.next_job()
        cpy.PyEval_RestoreThread(ts)
        if slot < 0:
            break

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

        # Park, THEN poke: the completion send is the happens-before edge that
        # publishes this write to the loop thread. Reversing them is a race
        # that would read a half-written response, and it would be rare enough
        # to look like anything else.
        pool.put_response(slot, response^, raised)
        pool.complete(slot)


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
