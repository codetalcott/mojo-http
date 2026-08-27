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
from lightbug_http.c.socket import recv
from lightbug_http.offload import (
    JOB_STOP,
    OffloadPool, OffloadLoopState, OFFLOAD_MAX_INFLIGHT, STREAM_GEN_NONE,
    make_stream_ack_pair, drain_ack_fd, stream_gen_seed,
)
from lightbug_http.uri import URI


def _read_ack(fd: Int) raises -> Tuple[Int, Int]:
    """One `(slot i32, credit i32)` datagram off an ack pair's read end."""
    var buf = List[UInt8](capacity=8)
    for _ in range(8):
        buf.append(0)
    var n = recv(FileDescriptor(fd), Span(buf), UInt(8), 0)
    assert_equal(Int(n), 8)
    var s = UInt32(0)
    var c = UInt32(0)
    for i in range(4):
        s |= UInt32(buf[i]) << UInt32(8 * i)
        c |= UInt32(buf[4 + i]) << UInt32(8 * i)
    return (Int(s), Int(c))


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


# --- streamed WSGI bodies: a pool thread as a second chunk-channel producer ---


def test_chunk_channel_and_executor_ack_pair_are_separate_switches() raises:
    """A pure-WSGI pool server enables the chunk channel and NOT the
    executor's ack pair: `stream_active` must stay false there, or every
    M0-Hold on the default topology would be read as an executor stream."""
    var pool = OffloadPool(8)
    assert_false(pool.chunk_active())
    assert_false(pool.stream_active())
    pool.enable_stream_channel()
    assert_true(pool.chunk_active())
    assert_false(pool.stream_active())
    assert_false(pool.slot_is_executor(3))
    assert_false(pool.slot_channel_stream(3))
    pool.enable_base_stream_ack()
    assert_true(pool.stream_active())
    # Unmounted with an executor: every slot is the executor's, as before.
    assert_true(pool.slot_is_executor(3))
    assert_true(pool.slot_channel_stream(3))


def test_a_slot_with_a_pool_ack_fd_is_a_channel_stream_until_cleared() raises:
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    var pair = make_stream_ack_pair()
    pool.set_slot_ack_fd(5, pair[1])
    assert_true(pool.slot_channel_stream(5))
    assert_false(pool.slot_channel_stream(4))
    assert_false(pool.slot_is_executor(5))
    pool.clear_slot_ack_fd(5)
    assert_false(pool.slot_channel_stream(5))


def test_ack_stream_routes_to_the_pool_threads_own_pair() raises:
    """Credit for a pool thread's stream reaches THAT thread's fd, ahead of
    any lane default; a slot without one still takes the lane path."""
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    pool.enable_base_stream_ack()
    var pair = make_stream_ack_pair()
    pool.set_slot_ack_fd(2, pair[1])
    assert_true(pool.ack_stream(2, 16384))
    var got = _read_ack(pair[0])
    assert_equal(got[0], 2)
    assert_equal(got[1], 16384)
    # Another slot's ack goes to the base (executor) pair, not this thread.
    assert_true(pool.ack_stream(3, 100))
    var base = _read_ack(pool.stream_ack_read)
    assert_equal(base[0], 3)
    assert_equal(base[1], 100)


def test_drain_ack_fd_discards_what_is_queued() raises:
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    var pair = make_stream_ack_pair()
    pool.set_slot_ack_fd(1, pair[1])
    assert_true(pool.ack_stream(1, 1))
    assert_true(pool.ack_stream(1, 2))
    drain_ack_fd(pair[0])
    # A fresh ack after the drain is the first thing read.
    assert_true(pool.ack_stream(1, 3))
    var got = _read_ack(pair[0])
    assert_equal(got[1], 3)


def test_abort_rides_the_completion_channel_beside_completions() raises:
    """An abort datagram and an ordinary completion share one channel and one
    drain; the drain keeps them apart and preserves the completions' order."""
    var pool = OffloadPool(8)
    pool.park_request(2, _request("/a"))
    assert_true(pool.submit(2))
    _ = _next_slot(pool)
    _ = pool.take_request(2)
    pool.put_response(2, OK(String("two")))
    pool.complete(2)
    assert_true(pool.abort_stream(6, 4294967297))
    pool.park_request(3, _request("/b"))
    assert_true(pool.submit(3))
    _ = _next_slot(pool)
    _ = pool.take_request(3)
    pool.put_response(3, OK(String("three")))
    pool.complete(3)

    var done = pool.drain_completions()
    assert_equal(len(done), 2)
    assert_equal(done[0], 2)
    assert_equal(done[1], 3)
    var aborts = pool.take_aborts()
    assert_equal(len(aborts), 2)
    assert_equal(aborts[0], 6)
    assert_equal(aborts[1], 4294967297)
    # Taken once: a second take is empty.
    assert_equal(len(pool.take_aborts()), 0)


def test_generation_seeds_are_disjoint_across_producers() raises:
    """Executors (lane + 1) and pool threads (1024 + index) can never hand
    out the same generation, however many streams each produces."""
    var exec_unmounted = stream_gen_seed(0)
    var exec_lane_0 = stream_gen_seed(1)
    var pool_thread_0 = stream_gen_seed(1024)
    var pool_thread_1 = stream_gen_seed(1025)
    assert_true(exec_unmounted != STREAM_GEN_NONE)
    assert_true(exec_lane_0 - exec_unmounted >= (1 << 32))
    assert_true(pool_thread_0 - exec_lane_0 >= (1 << 32))
    assert_true(pool_thread_1 - pool_thread_0 == (1 << 32))
    # A producer's own range: a billion streams stay inside it.
    assert_true(exec_unmounted + 1_000_000_000 < exec_lane_0)


def test_loop_state_clear_stream_forgets_fd_and_generation() raises:
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    var state = OffloadLoopState(pool.addr(), 8)
    var pair = make_stream_ack_pair()
    pool.set_slot_ack_fd(4, pair[1])
    state.stream_gen[4] = 77
    assert_true(state.slot_channel_stream(4))
    assert_true(state.chunk_active())
    state.clear_stream(4)
    assert_false(state.slot_channel_stream(4))
    assert_equal(state.stream_gen[4], STREAM_GEN_NONE)
    assert_false(pool.slot_channel_stream(4))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
