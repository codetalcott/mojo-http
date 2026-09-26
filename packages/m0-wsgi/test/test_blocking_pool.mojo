"""The WSGI handler pool's thread lifecycle, against a real `OffloadPool`.

A handler that never touches Python beyond what the pool body itself does --
attach, detach around every wait, release -- so what is under test is the
pool, not an application. The interpreter is started here and released
before the threads spawn, because each one takes the GIL for its life and a
main thread holding it would stall them all (the pool's own docstring says
the same about `stop_and_join`).
"""

from std.os import setenv
from std.python import Python
from std.testing import TestSuite, assert_equal, assert_true
from std.time import perf_counter_ns, sleep

from lightbug_http.http import HTTPResponse, OK
from lightbug_http.http.request import HTTPRequest
from lightbug_http.offload import OffloadPool
from lightbug_http.uri import URI

from src.blocking_pool import BlockingPool
from src.thread_handler import ThreadContext, ThreadHandler
from src.threaded import probe_free_threading


@fieldwise_init
struct NullHandler[busy: Bool](ThreadHandler):
    """Answers 200; every hook a pool thread may call is a no-op. With
    `busy`, `func` holds the GIL for a fraction of a millisecond first, as
    a CPU-bound view does -- the fairness probe's `/busy`."""

    var index: Int

    @staticmethod
    def make(ctx: ThreadContext) raises -> Self:
        return Self(ctx.index)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        comptime if Self.busy:
            _ = Python.evaluate("sum(range(10000))")
        return OK(String("ok"))

    def set_ws_pool_notify(mut self, lane: Int, fd: Int):
        pass

    def serve_ws_message(
        mut self, slot: Int, opcode: Int, channel: String,
        payload: Span[Byte, _],
    ):
        pass

    def set_asgi_notify(mut self, fd: Int):
        pass

    def set_lane_notify(mut self, lane: Int, fd: Int):
        pass

    def set_abort_pool(mut self, addr: Int):
        pass

    def stream_pending(self) -> Bool:
        return False

    def stream_begin(mut self, slot: Int, gen: Int, ack_fd: Int) -> Bool:
        return False

    def stream_pump(
        mut self, slot: Int, gen: Int, ack_read_fd: Int, mut pool: OffloadPool
    ):
        pass

    def shutdown(mut self):
        pass


def test_every_thread_is_counted_before_start_returns_and_stops_at_once() raises:
    """Registered by `start`, on the spawning thread, never by the body.

    `stop` pills every registered thread on its own channel and sends the
    rest to the lane socket. A thread that registered in its body after a
    `stop` had already run parked on its own channel, pill-less, while its
    pill sat on a socket it no longer read -- a join that waited out its
    bound. The Mojo pool had it first and `test_mojo_pool.mojo` caught it;
    this pool had the same body. The count right after `start` is what
    makes the test deterministic: a body that registers itself has almost
    never run yet at that point, while a join race is only sometimes lost.
    """
    _ = Python.import_module("sys")
    ref cpy = Python().cpython()
    var ts = cpy.PyEval_SaveThread()
    var pool = OffloadPool(8)
    var threads = BlockingPool(4)
    threads.start[NullHandler[False]](pool.addr(), 0)
    var counted = pool.thread_count(0)
    var failed = threads.stop_and_join(pool, 5_000_000_000)
    cpy.PyEval_RestoreThread(ts)
    assert_equal(counted, 4)
    assert_equal(failed, 0)
    assert_equal(threads.stragglers, 0)


comptime _BURST = 64


def _burst(keep: Bool) raises -> Tuple[Int, Int, Bool]:
    """`_BURST` jobs through four threads whose views hold the GIL, with
    every thread awake (`M0_POOL_ELASTIC=0`), so they contend for it the
    way the fairness probe's do. (jobs answered, jobs kept, GIL enabled)."""
    var gil = probe_free_threading().gil_enabled
    ref cpy = Python().cpython()
    var ts = cpy.PyEval_SaveThread()
    _ = setenv("M0_POOL_ELASTIC", "0", True)
    _ = setenv("M0_POOL_TURN_KEEP", "1" if keep else "0", True)
    var pool = OffloadPool(_BURST)
    var threads = BlockingPool(4)
    threads.start[NullHandler[True]](pool.addr(), 0)
    _ = setenv("M0_POOL_ELASTIC", "", True)
    _ = setenv("M0_POOL_TURN_KEEP", "", True)
    for slot in range(_BURST):
        pool.park_request(slot, HTTPRequest(URI.parse("http://localhost/busy")))
        _ = pool.submit(slot)
    var answered = 0
    var deadline = perf_counter_ns() + 20_000_000_000
    while answered < _BURST and perf_counter_ns() < deadline:
        var done = pool.drain_completions()
        for i in range(len(done)):
            _ = pool.take_response(done[i])
            answered += 1
        sleep(0.001)
    var failed = threads.stop_and_join(pool, 5_000_000_000)
    cpy.PyEval_RestoreThread(ts)
    assert_equal(failed, 0)
    assert_equal(threads.stragglers, 0)
    return (answered, threads.kept(), gil)


def test_a_slice_takes_the_jobs_queued_behind_it_without_dropping_the_gil() raises:
    """Inside its hand-off slice a thread takes a job already queued
    WITHOUT dropping the GIL. A drop there bought nothing -- the thread
    re-took the GIL before anyone it woke was scheduled -- and cost a
    parked waiter its place in CPython's condition variable, so the
    slice's hand-off went to whichever thread had just held the GIL: two
    threads ping-ponged while two starved, 0.3-1.6 s at a time
    (docs/notes/a-slice-keeps-the-gil.md). Every job is answered either
    way; with the GIL, jobs are kept, and under `M0_POOL_TURN_KEEP=0` --
    the knob, and the probe's Linux arm -- none are. A free-threaded
    interpreter has no GIL to wait on, so no run begins and none are kept.

    covers: E34
    """
    var on = _burst(True)
    assert_equal(on[0], _BURST)
    if on[2]:
        assert_true(on[1] > 0)
    var off = _burst(False)
    assert_equal(off[0], _BURST)
    assert_equal(off[1], 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
