"""The Python-free handler pool: one job in, one response out, no interpreter.

Drives `MojoPool` against a real `OffloadPool` over its real socketpairs — the
same thing `test_offload.mojo` does for the queue alone, one layer up. What is
NOT covered here is the p99 behaviour the pool exists for; that is the
measurement in `scripts/pool_spike_probe.py` against a live server.
"""

from std.ffi import c_int, external_call
from std.testing import TestSuite, assert_equal, assert_true
from std.time import perf_counter_ns

from lightbug_http.broadcast import decode_bus_frame
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import recv
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.header import Header, Headers
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


@fieldwise_init
struct StreamingHandler(PoolHandler):
    """Begins a stream that is not a hold: what `_pool_serve` must refuse."""

    var index: Int

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        return Self(ctx.index)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var resp = json(200, String("OK"), String(": open\n\n"))
        resp.sse_streaming = True
        return resp^

    def shutdown(mut self):
        pass


@fieldwise_init
struct HoldHandler(PoolHandler):
    """Takes an SSE hold the way a Django view does: two headers, a head."""

    var index: Int

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        return Self(ctx.index)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return HTTPResponse(
            body_bytes=String("event: connected\ndata: {}\n\n").as_bytes(),
            headers=Headers(
                Header("M0-Hold", "stream"), Header("M0-Channel", "news")
            ),
            status_code=200,
            status_text="OK",
        )

    def shutdown(mut self):
        pass


def _request() raises -> HTTPRequest:
    return HTTPRequest(URI.parse("http://127.0.0.1:8080/x"))


def _complete(mut pool: OffloadPool, slot: Int) raises -> HTTPResponse:
    """The loop's side of one job: wait for its completion, take the response."""
    var deadline = perf_counter_ns() + 5_000_000_000
    var got = False
    while perf_counter_ns() < deadline and not got:
        var done = pool.drain_completions()
        for i in range(len(done)):
            if done[i] == slot:
                got = True
    assert_true(got, "the pool thread never completed the job")
    return pool.take_response(slot)


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
    drained all 24 before the others were ever scheduled.

    **The drain loop calls `wake_aged`, and that is where the spread comes
    from.** Under the elastic rules `submit` wakes nobody while any thread
    of the lane is busy or spinning, deliberately: a wake beside a thread
    that is microseconds from coming back is a second thread on the GIL
    for nothing. A thread that is NOT coming back soon — a 60 ms `usleep`
    is exactly that — is the LOOP's case, `wake_aged` once per pass. So a
    bare pool driven with no loop has no wake at all: the lane's one
    spinner takes the first job, every later `submit` sees a busy lane and
    pokes nobody, and all eight jobs drain to that one thread at 60 ms
    apiece. Not a hypothesis — this test failed that way on PR #278's
    macOS runner (`distinct=1`, 783 ms) on a diff that cannot reach
    `MojoPool`, and reproduces on demand by stalling the spinner across
    the burst. Calling `wake_aged` here pairs the test with the shape a
    served request actually has; `M0_POOL_ELASTIC=0` would also pass, by
    testing the arm nobody runs.
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
        # The event loop's own line, `event_loop.mojo`'s bottom-of-pass
        # call. Without it the burst has no second taker; see the
        # docstring.
        _ = pool.wake_aged(perf_counter_ns(), pool.wake_age_ns())
        var done = pool.drain_completions()
        for i in range(len(done)):
            var resp = pool.take_response(done[i])
            var body = String(
                StringSpan(unsafe_from_utf8=Span(resp.body_raw))
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


def test_an_unheld_streaming_response_is_refused() raises:
    """A stream begun on a pool thread has no producer the loop drains, so
    the thread answers 409 and marks the job raised (the connection closes
    rather than hanging on a head that promises a body nothing writes).
    A hold is the one exception, and the next test is that exception."""
    var pool = OffloadPool(8)
    var threads = MojoPool(1)
    threads.start[StreamingHandler](pool.addr())
    pool.park_request(0, _request())
    assert_true(pool.submit(0))
    var resp = _complete(pool, 0)
    assert_equal(resp.status_code, 409)
    assert_true(not resp.sse_streaming, "the refusal must not itself be a stream")
    assert_true(pool.raised(0), "a refused stream must close the connection")
    _ = threads.stop_and_join(pool, 5_000_000_000)


def test_a_hold_sends_the_loop_its_frame_and_completes_with_the_head() raises:
    """The seam a WSGI pool thread uses, taken by a Mojo one.

    The response's `M0-Hold`/`M0-Channel` headers are consumed, the response
    becomes the stream's head (`text/event-stream`, `sse_streaming` set, the
    body kept), and an `h` frame naming the slot, the request's
    `Last-Event-ID` and the channel is on the loop's bus channel by the time
    the completion is — which is what lets the loop subscribe the slot in
    its own registries before it writes the head. Without the frame the
    client holds a stream nothing feeds; `poe sabotage-pool` reverts the
    send and this must fail.

    covers: N11
    """
    var pair = socketpair_dgram()
    var loop_end = pair[0]
    var thread_end = pair[1]
    var pool = OffloadPool(8)
    pool.set_hold_notify(thread_end)
    var threads = MojoPool(1)
    threads.start[HoldHandler](pool.addr())

    pool.park_request(
        0, HTTPRequest(URI.parse("http://127.0.0.1:8080/hold"),
                       headers=Headers(Header("Last-Event-ID", "7")))
    )
    assert_true(pool.submit(0))
    var resp = _complete(pool, 0)

    assert_equal(resp.status_code, 200)
    assert_true(resp.sse_streaming, "a hold completes as the stream's head")
    assert_true(not pool.raised(0), "a hold is not a refusal")
    assert_true("m0-hold" not in resp.headers, "the instruction header must not reach the wire")
    assert_true("m0-channel" not in resp.headers, "the channel header must not reach the wire")
    assert_equal(resp.headers["content-type"], "text/event-stream")
    assert_true("x-worker" in resp.headers, "a hold names its worker, as a WSGI hold does")
    assert_equal(
        String(StringSpan(unsafe_from_utf8=Span(resp.body_raw))),
        "event: connected\ndata: {}\n\n",
    )

    var buf = List[UInt8](capacity=256)
    for _ in range(256):
        buf.append(0)
    var n = recv(FileDescriptor(loop_end), Span(buf), UInt(256), MSG_DONTWAIT)
    assert_true(n > 10, "no hold frame on the loop's channel; the slot would never be subscribed")
    var decoded = decode_bus_frame(Span(buf)[0:Int(n)])
    assert_true(Bool(decoded), "the frame did not decode as a bus frame")
    var frame = decoded.take()
    # `\x01h/0`: the reserved byte, the kind, the slot; no lane on a
    # single-lane pool.
    var expected = List[UInt8]()
    expected.append(UInt8(1))
    for ch in String("h/0").as_bytes():
        expected.append(ch)
    assert_equal(frame.url, String(StringSpan(unsafe_from_utf8=Span(expected))))
    assert_equal(frame.event_id, 7)
    assert_equal(String(StringSpan(unsafe_from_utf8=Span(frame.frame))), "news")

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
