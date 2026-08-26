"""The `--blocking-threads` work queue, exercised without any threads.

Every handoff `offload.mojo` performs is a socketpair round trip, and a
socketpair does not care whether its two ends are on different threads. So the
whole protocol — park, submit, receive, take, respond, complete, drain — runs
here on one thread, where a failure is a failed assertion rather than a hang.
What is NOT covered here is the concurrency itself; that is what
`poe smoke-blocking-threads` measures against a live server.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.http import HTTPResponse, OK
from lightbug_http.http.request import HTTPRequest
from lightbug_http.offload import (
    JOB_STOP,
    OffloadPool, OffloadLoopState, OFFLOAD_MAX_INFLIGHT,
)
from lightbug_http.uri import URI


def _job_buffer() -> List[UInt8]:
    """A pool thread's receive buffer: one per thread, reused for its life."""
    var buf = List[UInt8](capacity=4096)
    for _ in range(4096):
        buf.append(0)
    return buf^


def _next_slot(mut pool: OffloadPool, lane: Int = 0) raises -> Int:
    """`next_job` as the pool body reads it: the slot, or -1 for the pill.

    The channel carries inbound WebSocket messages too now, so `next_job`
    answers with a `PoolJob` rather than an Int; these tests are about the
    request path, and this is that path's half of the answer.
    """
    var buf = _job_buffer()
    var job = pool.next_job(lane, buf)
    if job.kind == JOB_STOP:
        return -1
    return job.slot


def _request(path: String) raises -> HTTPRequest:
    return HTTPRequest(URI.parse("http://localhost" + path))


def test_round_trip_carries_the_request_and_the_response() raises:
    """A whole job crosses both channels and comes back on the right slot."""
    var pool = OffloadPool(8)

    pool.park_request(3, _request("/hello"))
    assert_true(pool.submit(3))

    # The pool side.
    assert_equal(_next_slot(pool), 3)
    var received = pool.take_request(3)
    assert_equal(received.uri.path, "/hello")
    pool.put_response(3, OK(String("answered")))
    pool.complete(3)

    # The loop side.
    var done = pool.drain_completions()
    assert_equal(len(done), 1)
    assert_equal(done[0], 3)
    assert_true(pool.has_response(3))
    var response = pool.take_response(3)
    assert_equal(response.status_code, 200)
    assert_false(pool.has_response(3))


def test_slots_do_not_bleed_into_each_other() raises:
    """Three jobs in flight at once keep their own requests and responses."""
    var pool = OffloadPool(8)
    for i in range(3):
        pool.park_request(i, _request("/p" + String(i)))
        assert_true(pool.submit(i))

    # Datagrams are ordered on one channel, so the jobs come back in order.
    for i in range(3):
        assert_equal(_next_slot(pool), i)
        var req = pool.take_request(i)
        assert_equal(req.uri.path, "/p" + String(i))
        pool.put_response(i, OK("body" + String(i)))
        pool.complete(i)

    var done = pool.drain_completions()
    assert_equal(len(done), 3)
    for i in range(3):
        assert_equal(done[i], i)
        var resp = pool.take_response(i)
        assert_equal(
            String(StringSlice(unsafe_from_utf8=Span(resp.body_raw))),
            "body" + String(i),
        )


def test_drain_is_empty_when_nothing_finished() raises:
    """The loop's drain must be cheap and silent on an idle pool.

    It runs on a readiness edge, and a spurious wakeup must not invent work.
    """
    var pool = OffloadPool(4)
    var done = pool.drain_completions()
    assert_equal(len(done), 0)


def test_unpark_returns_the_request_for_an_inline_run() raises:
    """A submit the queue refuses must leave the request recoverable.

    This is the overflow path: the loop parks, `submit` fails, and it has to
    get the request back to run it itself. Dropping it there would be a
    request the client never gets an answer to.
    """
    var pool = OffloadPool(4)
    pool.park_request(1, _request("/inline"))
    var back = pool.unpark_request(1)
    assert_equal(back.uri.path, "/inline")


def test_raised_is_reported_and_cleared() raises:
    """The handler-raised signal survives the completion and resets with it."""
    var pool = OffloadPool(4)
    pool.park_request(0, _request("/boom"))
    assert_true(pool.submit(0))
    _ = _next_slot(pool)
    _ = pool.take_request(0)
    pool.put_response(0, OK(String("x")), raised=True)
    pool.complete(0)
    _ = pool.drain_completions()
    assert_true(pool.raised(0))
    pool.discard(0)
    assert_false(pool.raised(0))


def test_stop_poisons_every_waiting_thread() raises:
    """`stop(n)` must release exactly `n` blocked receivers.

    A thread only ever leaves `next_job` on a negative slot, so one pill per
    thread is the entire reason `BlockingPool.stop_and_join` terminates.

    Exactly `n` reads, never `n + 1`. An earlier version of this test read a
    fourth time to prove the close was a backstop — it is not, and the fourth
    read blocked forever on Linux while passing on macOS, which cost a
    20-minute CI timeout. `next_job` has no timeout by design, so a test that
    reads more pills than were sent cannot fail; it can only hang.
    """
    var pool = OffloadPool(4)
    pool.stop(3)
    for _ in range(3):
        assert_equal(_next_slot(pool), -1)


def test_a_disabled_pool_builds_and_is_inert() raises:
    """`OffloadPool(0)` is what a loop gets when the flag is off.

    The threaded path constructs one per loop unconditionally (Mojo 1.0's
    `Optional` wants `ImplicitlyCopyable`, and this type deliberately is
    not), so the zero case has to be a real, safe object rather than an
    error — and it must not open descriptors for a pool nobody will use.
    """
    var pool = OffloadPool(0)
    assert_equal(pool.capacity, 0)
    assert_equal(pool.submit_read, -1)
    assert_equal(pool.submit_write, -1)
    assert_equal(pool.complete_read, -1)
    assert_equal(pool.complete_write, -1)


def test_loop_state_is_inert_without_a_pool() raises:
    """`addr == 0` is how a server without the flag says "run it yourself"."""
    var state = OffloadLoopState(0, 16)
    assert_false(state.enabled())
    assert_false(state.accepting())
    assert_equal(len(state.offloaded), 16)
    for i in range(16):
        assert_false(state.offloaded[i])
        assert_false(state.is_head[i])


def test_loop_state_stops_accepting_at_the_inflight_bound() raises:
    """The bound is what keeps the channels inside a default `rmem_max`.

    Past it the loop runs requests inline — degraded, never dropped — so
    `accepting()` going False is a policy, not an error.
    """
    var pool = OffloadPool(4)
    var state = OffloadLoopState(pool.addr(), 16)
    assert_true(state.enabled())
    assert_true(state.accepting())
    state.inflight = OFFLOAD_MAX_INFLIGHT
    assert_false(state.accepting())
    assert_true(state.enabled())
    state.inflight = OFFLOAD_MAX_INFLIGHT - 1
    assert_true(state.accepting())
    # `pool` must outlive the state that holds its address.
    _ = pool.capacity


def test_loop_state_reaches_the_pool_it_was_given() raises:
    """`pool()` must resolve to the same object `addr()` came from."""
    var pool = OffloadPool(9)
    var state = OffloadLoopState(pool.addr(), 9)
    assert_equal(state.pool()[].capacity, 9)
    _ = pool.capacity


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
