"""The Python-free handler pool: one job in, one response out, no interpreter.

Drives `MojoPool` against a real `OffloadPool` over its real socketpairs — the
same thing `test_offload.mojo` does for the queue alone, one layer up. What is
NOT covered here is the p99 behaviour the pool exists for; that is the
measurement in `scripts/pool_spike_probe.py` against a live server.
"""

from std.ffi import c_int, external_call
from std.testing import TestSuite, assert_equal, assert_true
from std.time import perf_counter_ns

from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.offload import OffloadPool
from lightbug_http.uri import URI

from lightbug_http.mojo_pool import MojoPool, PoolContext, PoolHandler
from src.reply import json


@fieldwise_init
struct EchoHandler(PoolHandler):
    """Answers 200 and names the thread that served it."""

    var index: Int

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        return Self(ctx.index)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return json(200, String("OK"), String('{"thread":', self.index, "}"))

    def shutdown(mut self):
        pass


@fieldwise_init
struct SleepyHandler(PoolHandler):
    """Blocks 60 ms per request, so a burst of jobs MUST spread across threads."""

    var index: Int

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        return Self(ctx.index)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        _ = external_call["usleep", c_int, c_int](c_int(60_000))
        return json(200, String("OK"), String('{"thread":', self.index, "}"))

    def shutdown(mut self):
        pass


def _request() raises -> HTTPRequest:
    return HTTPRequest(URI.parse("http://127.0.0.1:8080/x"))


def _thread_of(body: String) -> Int:
    """Pull the index out of `{"thread":N}` — enough parsing for one field."""
    var b = body.as_bytes()
    var i = 0
    var n = body.byte_length()
    while i < n and (Int(b[i]) < ord("0") or Int(b[i]) > ord("9")):
        i += 1
    var v = 0
    var saw = False
    while i < n and Int(b[i]) >= ord("0") and Int(b[i]) <= ord("9"):
        v = v * 10 + (Int(b[i]) - ord("0"))
        saw = True
        i += 1
    return v if saw else -1


def test_a_pool_thread_answers_a_parked_request() raises:
    """The whole round trip: park, submit, the thread answers, the loop drains."""
    var pool = OffloadPool(8)
    var threads = MojoPool(1)
    threads.start[EchoHandler](pool.addr())

    pool.park_request(0, _request())
    assert_true(pool.submit(0))

    # The loop's side: wait for the completion, then take the response.
    var deadline = perf_counter_ns() + 5_000_000_000
    var got = False
    while perf_counter_ns() < deadline and not got:
        var done = pool.drain_completions()
        for i in range(len(done)):
            if done[i] == 0:
                got = True
    assert_true(got, "the pool thread never completed the job")

    var resp = pool.take_response(0)
    assert_equal(resp.status_code, 200)

    _ = threads.stop_and_join(pool, 5_000_000_000)


def test_every_thread_gets_its_own_handler() raises:
    """`make` runs per thread, so each handler carries its OWN index.

    The indices are the assertion, not the completion count. An earlier
    version of this test only counted completions, and `scripts/
    pool_sabotage.py` caught it: building every handler with index 0 —
    the shape a shared handler would have — passed cleanly.

    The jobs BLOCK (60 ms each), and that is load-bearing too: with
    instant jobs this asserted a fairness property the FIFO queue does not
    have, and CI's 3-core runner promptly disproved it — one thread
    drained all 24 before the others were ever scheduled. A burst of
    blocking jobs is different: a thread asleep in `usleep` is not in
    `recv`, so the next datagram wakes a different thread. Eight 60 ms
    jobs on one thread would be 480 ms of serial sleeping; another thread
    only has to wake once in that window.
    """
    var pool = OffloadPool(64)
    var threads = MojoPool(3)
    threads.start[SleepyHandler](pool.addr())

    comptime JOBS = 8
    var seen = 0
    var indices = List[Int]()
    var deadline = perf_counter_ns() + 10_000_000_000
    for slot in range(JOBS):
        pool.park_request(slot, _request())
        assert_true(pool.submit(slot))
    while perf_counter_ns() < deadline and seen < JOBS:
        var done = pool.drain_completions()
        for i in range(len(done)):
            var resp = pool.take_response(done[i])
            var body = String(
                StringSlice(unsafe_from_utf8=Span(resp.body_raw))
            )
            indices.append(_thread_of(body))
            seen += 1
    assert_equal(seen, JOBS)

    var distinct = 0
    for candidate in range(3):
        for i in range(len(indices)):
            if indices[i] == candidate:
                distinct += 1
                break
    assert_true(
        distinct > 1,
        String("every response came from one handler (distinct=", distinct, ")"),
    )

    _ = threads.stop_and_join(pool, 5_000_000_000)


def test_stop_and_join_ends_every_thread() raises:
    """One pill per thread — a miscount is a hung join, not a slow one."""
    var pool = OffloadPool(8)
    var threads = MojoPool(4)
    threads.start[EchoHandler](pool.addr())
    var failed = threads.stop_and_join(pool, 5_000_000_000)
    assert_equal(failed, 0)
    assert_equal(threads.stragglers, 0)


def test_an_unstarted_pool_joins_cleanly() raises:
    """`stop_and_join` before `start` must not send pills nobody will take."""
    var pool = OffloadPool(4)
    var threads = MojoPool(2)
    assert_equal(threads.stop_and_join(pool, 1_000_000_000), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
