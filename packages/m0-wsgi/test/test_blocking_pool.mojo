"""The WSGI handler pool's thread lifecycle, against a real `OffloadPool`.

A handler that never touches Python beyond what the pool body itself does --
attach, detach around every wait, release -- so what is under test is the
pool, not an application. The interpreter is started here and released
before the threads spawn, because each one takes the GIL for its life and a
main thread holding it would stall them all (the pool's own docstring says
the same about `stop_and_join`).
"""

from std.python import Python
from std.testing import TestSuite, assert_equal

from lightbug_http.http import HTTPResponse, OK
from lightbug_http.http.request import HTTPRequest
from lightbug_http.offload import OffloadPool

from src.blocking_pool import BlockingPool
from src.thread_handler import ThreadContext, ThreadHandler


@fieldwise_init
struct NullHandler(ThreadHandler):
    """Answers 200; every hook a pool thread may call is a no-op."""

    var index: Int

    @staticmethod
    def make(ctx: ThreadContext) raises -> Self:
        return Self(ctx.index)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
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
    threads.start[NullHandler](pool.addr(), 0)
    var counted = pool.thread_count(0)
    var failed = threads.stop_and_join(pool, 5_000_000_000)
    cpy.PyEval_RestoreThread(ts)
    assert_equal(counted, 4)
    assert_equal(failed, 0)
    assert_equal(threads.stragglers, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
