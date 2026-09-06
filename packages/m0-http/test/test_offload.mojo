"""The `--blocking-threads` work queue, exercised without any threads.

Every handoff `offload.mojo` performs is a socketpair round trip, and a
socketpair does not care whether its two ends are on different threads. So the
whole protocol — park, submit, receive, take, respond, complete, drain — runs
here on one thread, where a failure is a failed assertion rather than a hang.
What is NOT covered here is the concurrency itself; that is what
`poe smoke-blocking-threads` measures against a live server.
"""

from std.os import setenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from lightbug_http.http import HTTPResponse, OK
from lightbug_http.http.request import HTTPRequest
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import recv
from lightbug_http.offload import (
    JOB_STOP, JOB_REQUEST,
    OffloadPool, OffloadLoopState, OFFLOAD_MAX_INFLIGHT, STREAM_GEN_NONE,
    make_stream_ack_pair, drain_ack_fd, stream_gen_seed,
    COMPLETE_BATCH_MAX, SUBMIT_BATCH_MAX, TAG_JOB_BATCH,
)
from lightbug_http.uri import URI

from src.threads import ThreadSet, ThreadBlock, BLK_USER, BLK_STATUS, STATUS_OK


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
            String(StringSpan(unsafe_from_utf8=Span(resp.body_raw))),
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
# --- pump batching: one datagram per pass in each direction --------------------


def _read_datagram(fd: Int) raises -> List[UInt8]:
    """One whole datagram off a submit lane's read end, as the executor's
    shim would read it."""
    var buf = List[UInt8](capacity=4096)
    for _ in range(4096):
        buf.append(0)
    var n = recv(FileDescriptor(fd), Span(buf), UInt(4096), 0)
    var out = List[UInt8](capacity=Int(n))
    for i in range(Int(n)):
        out.append(buf[i])
    return out^


def test_complete_many_delivers_every_slot_in_one_datagram() raises:
    var pool = OffloadPool(8)
    for slot in [2, 5, 7]:
        pool.park_request(slot, _request("/x"))
        assert_true(pool.submit(slot))
        _ = _next_slot(pool)
        _ = pool.take_request(slot)
        pool.put_response(slot, OK(String("r")))
    assert_true(pool.complete_many([2, 5, 7]))
    var done = pool.drain_completions()
    assert_equal(len(done), 3)
    assert_equal(done[0], 2)
    assert_equal(done[1], 5)
    assert_equal(done[2], 7)
    # An empty batch is a no-op, not a zero-length datagram.
    assert_true(pool.complete_many(List[Int]()))
    assert_equal(len(pool.drain_completions()), 0)


def test_single_and_batched_completions_both_reach_the_drain() raises:
    """The blocking pool's one-slot `complete` (the ring) and the executor's
    batch (the channel) are two producers with no order between them — they
    name different slots — and one drain delivers every slot of both, the
    ring's in push order and the channel's in datagram order."""
    var pool = OffloadPool(16)
    pool.complete(2)
    assert_true(pool.complete_many([3, 4]))
    pool.complete(9)
    var done = pool.drain_completions()
    assert_equal(len(done), 4)
    if pool.ring_active():
        assert_equal(done[0], 2)
        assert_equal(done[1], 9)
        assert_equal(done[2], 3)
        assert_equal(done[3], 4)
    else:
        assert_equal(done[0], 2)
        assert_equal(done[1], 3)
        assert_equal(done[2], 4)
        assert_equal(done[3], 9)


def test_a_full_completion_batch_decodes_whole() raises:
    """Pins the drain's receive buffer: a SOCK_DGRAM `recv` into a short
    buffer silently discards the excess, and a batch decoded short is a
    slot that never answers."""
    var pool = OffloadPool(128)
    var slots = List[Int]()
    for i in range(COMPLETE_BATCH_MAX):
        slots.append(i)
    assert_true(pool.complete_many(slots))
    var done = pool.drain_completions()
    assert_equal(len(done), COMPLETE_BATCH_MAX)
    assert_equal(done[COMPLETE_BATCH_MAX - 1], COMPLETE_BATCH_MAX - 1)


def test_job_batch_is_tag_4_and_one_mod_eight() raises:
    """A batch's first byte is 4 and its length is 1 + 8n — so a two-slot
    batch cannot be read as a plain job (8 bytes), and a one-slot batch
    goes out as the legacy job, not as a 9-byte datagram that only its tag
    would distinguish from a disconnect."""
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    assert_true(pool.submit_batch(0, [3, 6]))
    var batch = _read_datagram(pool.submit_read)
    assert_equal(len(batch), 17)
    assert_equal(batch[0], TAG_JOB_BATCH)
    assert_equal(Int(batch[1]), 3)
    assert_equal(Int(batch[9]), 6)
    assert_true(pool.submit_batch(0, [5]))
    var single = _read_datagram(pool.submit_read)
    assert_equal(len(single), 8)
    assert_equal(Int(single[0]), 5)


def test_next_job_does_not_misparse_a_job_batch() raises:
    """A batch on a pool lane is a sender bug; `next_job` skips it loudly and
    the real job behind it is still served."""
    var pool = OffloadPool(8)
    assert_true(pool.submit_batch(0, [1, 2]))
    pool.park_request(4, _request("/real"))
    assert_true(pool.submit(4))
    var buf = _job_buffer()
    var job = pool.next_job(0, buf)
    assert_equal(job.kind, JOB_REQUEST)
    assert_equal(job.slot, 4)


def test_lane_is_executor_agrees_with_slot_is_executor() raises:
    var pool = OffloadPool(8)
    assert_false(pool.lane_is_executor(0))
    # The chunk channel alone is not an executor — a streaming pool has one
    # too; the executor's own ack pair is what says one exists, and only
    # then are submits to its lane batched.
    pool.enable_stream_channel()
    assert_false(pool.lane_is_executor(0))
    pool.enable_base_stream_ack()
    # Unmounted with an executor: every lane and every slot is its.
    assert_true(pool.lane_is_executor(0))
    assert_true(pool.lane_is_executor(-1))
    pool.stamp_lane(3, 0)
    assert_true(pool.slot_is_executor(3))


def test_loop_state_buffers_submits_per_lane_and_flushes_at_the_cap() raises:
    var pool = OffloadPool(128)
    pool.enable_stream_channel()
    var state = OffloadLoopState(pool.addr(), 128)
    for i in range(SUBMIT_BATCH_MAX - 1):
        assert_false(state.queue_submit(i, 0))
    assert_equal(state.pending_submit_count, SUBMIT_BATCH_MAX - 1)
    # The cap: the last slot says "flush now".
    assert_true(state.queue_submit(SUBMIT_BATCH_MAX - 1, 0))
    var unsent = state.flush_lane(0)
    assert_equal(len(unsent), 0)
    assert_equal(state.pending_submit_count, 0)
    var batch = _read_datagram(pool.submit_read)
    assert_equal(len(batch), 1 + 8 * SUBMIT_BATCH_MAX)
    assert_equal(batch[0], TAG_JOB_BATCH)


def test_flush_submits_sends_every_lane_and_returns_nothing_when_all_went() raises:
    var pool = OffloadPool(16)
    pool.enable_stream_channel()
    var state = OffloadLoopState(pool.addr(), 16)
    _ = state.queue_submit(1, 0)
    _ = state.queue_submit(2, 0)
    var unsent = state.flush_submits()
    assert_equal(len(unsent), 0)
    assert_equal(state.pending_submit_count, 0)
    var batch = _read_datagram(pool.submit_read)
    assert_equal(len(batch), 17)
    # Nothing buffered: a flush sends nothing and reads back nothing.
    assert_equal(len(state.flush_submits()), 0)


def _try_read(fd: Int) -> Int:
    """Bytes of one datagram off `fd`, or -1 when none is waiting."""
    var buf = List[UInt8](capacity=64)
    for _ in range(64):
        buf.append(0)
    try:
        var n = recv(FileDescriptor(fd), Span(buf), UInt(64), MSG_DONTWAIT)
        return Int(n)
    except:
        return -1


def test_submit_wakes_only_a_parked_thread() raises:
    """The producer's half of the wake protocol: push, then read the parked
    count, then poke — so a thread that is spinning costs the loop no
    syscall, and a thread that is blocked gets exactly one datagram."""
    var pool = OffloadPool(8)
    if not pool.ring_active():
        return
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    # Nobody parked: the job is on the ring and the socket stays quiet.
    assert_equal(_try_read(pool.submit_read), -1)
    assert_equal(_next_slot(pool), 1)
    # A parked thread: the push is followed by one wake datagram.
    pool.note_parked(0, 1)
    pool.park_request(2, _request("/b"))
    assert_true(pool.submit(2))
    assert_equal(_try_read(pool.submit_read), 8)
    pool.note_parked(0, -1)
    assert_equal(_next_slot(pool), 2)
    assert_equal(pool.parked_count(0), 0)


def test_a_burst_sends_one_wake_per_parked_thread() raises:
    """Three pushes into two parked threads send two wakes, not three; a
    wake read by a thread retires itself, and a fresh push then wakes."""
    var pool = OffloadPool(8)
    if not pool.ring_active():
        return
    pool.note_parked(0, 2)
    for slot in range(3):
        pool.park_request(slot, _request("/b"))
        assert_true(pool.submit(slot))
    assert_equal(pool.wakes_in_flight(0), 2)
    # The two threads "wake" and read the ring dry; `next_job` retires a
    # wake it reads on its socket poll, and reads the other behind the
    # pill when it parks for good. Two sent, two retired, none served.
    pool.note_parked(0, -2)
    for slot in range(3):
        assert_equal(_next_slot(pool), slot)
    pool.stop(1)
    assert_equal(_next_slot(pool), -1)
    assert_equal(pool.wakes_in_flight(0), 0)


def test_a_job_that_has_waited_past_the_threshold_wakes_a_parked_sibling() raises:
    """Two jobs, one parked sibling, one wake in flight — and the thread
    that takes the first job does NOT wake the sibling for the second (the
    chained wake of 2026-09-05 is gone: it is what put a burst of trivial
    jobs on N threads). The LOOP does, once the second job has aged past
    the threshold: `wake_aged` says no while it is fresh and sends the wake
    the sibling is owed once it is old, however the sibling's original
    wake went — the hole the chain used to fill, now filled every pass."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    pool.note_parked(0, 1)
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    pool.park_request(2, _request("/b"))
    assert_true(pool.submit(2))
    # One parked thread, so one wake for the two pushes.
    assert_equal(pool.wakes_in_flight(0), 1)
    # This thread stands in for a second, running sibling: its socket poll
    # reads the wake, it takes job 1, and work remains for the parked one.
    assert_equal(_next_slot(pool), 1)
    assert_equal(pool.wakes_in_flight(0), 0)
    # Fresh: the loop leaves it to whoever comes back first.
    assert_equal(pool.wake_aged(perf_counter_ns(), 1_000_000_000), 0)
    assert_equal(pool.wakes_in_flight(0), 0)
    # Aged: the same head, unmoved across the loop's looks for longer than
    # the threshold, and the loop wakes the parked sibling — once, however
    # many passes find it standing, because the cap is a wake per parked
    # thread.
    sleep(0.002)
    assert_equal(pool.wake_aged(perf_counter_ns(), 1_000_000), 1)
    assert_equal(pool.wakes_in_flight(0), 1)
    assert_equal(pool.wake_aged(perf_counter_ns(), 1_000_000), 0)
    assert_equal(pool.wakes_in_flight(0), 1)
    # The "parked" thread takes the rest, and nothing is owed any more.
    pool.note_parked(0, -1)
    assert_equal(_next_slot(pool), 2)
    assert_equal(pool.wake_aged(perf_counter_ns(), 0), 0)
    pool.stop(1)
    assert_equal(_next_slot(pool), -1)
    assert_equal(pool.wakes_in_flight(0), 0)


def test_submit_wakes_nobody_while_a_sibling_is_busy() raises:
    """The elastic rule: a push into a lane where some thread is neither
    parked nor spinning wakes no one — that thread is coming back to the
    ring, and a wake would put a second thread on the GIL for a job the
    first takes in microseconds. Every thread parked, the push wakes one."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    # Two threads announced on the lane, one parked: the other is busy.
    pool.note_thread(0, 2)
    pool.note_parked(0, 1)
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    assert_equal(pool.wakes_in_flight(0), 0)
    assert_equal(_try_read(pool.submit_read), -1)
    assert_true(pool.jobs_pending())
    # The busy thread comes back and takes it, no wake having been spent.
    assert_equal(_next_slot(pool), 1)
    assert_false(pool.jobs_pending())
    # Both parked: the push wakes exactly one.
    pool.note_parked(0, 1)
    pool.park_request(2, _request("/b"))
    assert_true(pool.submit(2))
    assert_equal(pool.wakes_in_flight(0), 1)
    assert_equal(_try_read(pool.submit_read), 8)
    pool.note_parked(0, -2)
    pool.note_thread(0, -2)
    assert_equal(_next_slot(pool), 2)


def test_submit_wakes_nobody_while_a_sibling_spins() raises:
    """The lane's idle spinner sees the push itself; a wake beside it is a
    second thread woken for a job the spinner takes at once."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    pool.note_thread(0, 2)
    pool.note_parked(0, 1)
    pool.note_spinning(0, 1)
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    assert_equal(pool.wakes_in_flight(0), 0)
    assert_equal(_try_read(pool.submit_read), -1)
    # This thread, arriving beside a spinner, is refused a spin of its own
    # and parks at once — and its re-check after announcing finds the job.
    assert_equal(_next_slot(pool), 1)
    assert_equal(pool.spinner_count(0), 1)
    pool.note_spinning(0, -1)
    pool.note_parked(0, -1)
    pool.note_thread(0, -2)
    assert_equal(pool.spinner_count(0), 0)


def test_a_ring_being_drained_is_never_stalled() raises:
    """The progress rule. A ring whose pop count moved since the loop
    last looked wakes nobody, however old its head; a ring that has not
    moved for the threshold — counted from the later of the head's push
    and the last look that saw it move — does. The loop's clock is
    simulated from one real origin in 50 ms steps against a 100 ms
    threshold, so the real milliseconds between calls cannot cross a
    boundary. The stand-in sibling parks on the lane socket, so each wake
    is a datagram there, retired by the next `next_job`'s socket poll."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    comptime T = 100_000_000
    comptime MS = 1_000_000
    pool.note_thread(0, 2)
    pool.note_parked(0, 1)
    # The loop's first look, nothing pending: the ring is drained now.
    var t0 = perf_counter_ns()
    assert_equal(pool.wake_aged(t0, T), 0)
    for slot in range(3):
        pool.park_request(slot, _request("/q"))
        assert_true(pool.submit(slot))
    assert_equal(pool.wakes_in_flight(0), 0)
    # Nothing taken since: at 50 ms not stalled, at 150 ms stalled — one
    # wake, and no second while that one is owed.
    assert_equal(pool.wake_aged(t0 + 50 * MS, T), 0)
    assert_equal(pool.wake_aged(t0 + 150 * MS, T), 1)
    assert_equal(pool.wake_aged(t0 + 150 * MS + 1, T), 0)
    assert_equal(pool.wakes_in_flight(0), 1)
    # The busy thread (this one) takes jobs 0 and 1: the ring moved. Its
    # socket poll retires the wake on the way.
    pool.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool), 0)
    assert_equal(_next_slot(pool), 1)
    assert_equal(pool.wakes_in_flight(0), 0)
    pool.note_parked(0, 1)
    # Job 2 is as old as job 0 was, but the ring moved since the loop's
    # 150 ms look: progress at 200 ms, and the stall is counted from
    # there — not at 250 ms, stalled at 310.
    assert_equal(pool.wake_aged(t0 + 200 * MS, T), 0)
    assert_equal(pool.wake_aged(t0 + 250 * MS, T), 0)
    assert_equal(pool.wake_aged(t0 + 310 * MS, T), 1)
    pool.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool), 2)
    assert_equal(pool.wakes_in_flight(0), 0)
    # A push into a lane that just drained: the wait counts from the
    # push, not from the loop's last look — a job pushed at 390 ms into
    # a lane last seen moving at 400 ms is not stalled at 450 ms.
    pool.note_parked(0, 1)
    sleep(0.0001)
    pool.park_request(2, _request("/again"))
    assert_true(pool.submit(2))
    assert_equal(pool.wake_aged(t0 + 400 * MS, T), 0)
    assert_equal(pool.wake_aged(t0 + 450 * MS, T), 0)
    assert_equal(pool.wake_aged(t0 + 510 * MS, T), 1)
    pool.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool), 2)
    assert_equal(pool.wakes_in_flight(0), 0)
    pool.note_thread(0, -2)


def test_on_a_free_threaded_interpreter_the_pool_wakes_eagerly_and_counts_from_the_push() raises:
    """`set_parallel(True)`, the free-threaded rule. A push beside a busy
    sibling wakes a parked thread anyway (an idle core there), and the
    ring the progress test left alone — moved since the loop's last look
    — is stalled once its head has waited the threshold since its push.
    The knob `M0_POOL_PARALLEL` wins over the wiring's answer."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    assert_false(pool.is_parallel())
    pool.set_parallel(True)
    assert_true(pool.is_parallel())
    comptime T = 100_000_000
    comptime MS = 1_000_000
    pool.note_thread(0, 2)
    pool.note_parked(0, 1)
    # A busy sibling is no reason not to wake here.
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    assert_equal(pool.wakes_in_flight(0), 1)
    pool.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool), 1)
    assert_equal(pool.wakes_in_flight(0), 0)
    pool.note_parked(0, 1)
    # The stall check counts from the push whatever the progress.
    var t0 = perf_counter_ns()
    assert_equal(pool.wake_aged(t0, T), 0)
    for slot in range(2, 5):
        pool.park_request(slot, _request("/q"))
        assert_true(pool.submit(slot))
    # (One wake for the burst: the parked stand-in is owed one already.)
    assert_equal(pool.wakes_in_flight(0), 1)
    pool.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool), 2)
    assert_equal(pool.wakes_in_flight(0), 0)
    pool.note_parked(0, 1)
    # The ring moved since the loop's look at t0; under the GIL rule the
    # count would start at 150 ms. Here job 3 has waited since its push.
    assert_equal(pool.wake_aged(t0 + 150 * MS, T), 1)
    assert_equal(pool.wakes_in_flight(0), 1)
    pool.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool), 3)
    assert_equal(_next_slot(pool), 4)
    assert_equal(pool.wakes_in_flight(0), 0)
    pool.note_thread(0, -2)
    # The knob: forced off, the wiring cannot turn it on.
    _ = setenv("M0_POOL_PARALLEL", "0", True)
    var forced = OffloadPool(8)
    _ = setenv("M0_POOL_PARALLEL", "", True)
    forced.set_parallel(True)
    assert_false(forced.is_parallel())


def test_the_wait_is_bounded_only_while_a_job_is_pending() raises:
    """`jobs_pending` is what `_wait_for_events` consults to cap its
    timeout at `POOL_WAKE_WAIT_MS`: false with empty rings (the loop keeps
    its second), true from a push until the pop."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    assert_false(pool.jobs_pending())
    pool.park_request(3, _request("/a"))
    assert_true(pool.submit(3))
    assert_true(pool.jobs_pending())
    assert_equal(_next_slot(pool), 3)
    assert_false(pool.jobs_pending())


def test_elastic_off_restores_the_chained_wake() raises:
    """`M0_POOL_ELASTIC=0`, the A/B arm: every push into a parked lane
    wakes, a thread that takes a job wakes a sibling for the rest, the
    loop's age check does nothing and the wait is never bounded — the
    rules of 2026-09-05, verbatim."""
    _ = setenv("M0_POOL_ELASTIC", "0", True)
    var pool = OffloadPool(8)
    _ = setenv("M0_POOL_ELASTIC", "", True)
    if not pool.ring_active():
        return
    assert_false(pool.elastic_active())
    pool.note_thread(0, 2)
    pool.note_parked(0, 1)
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    # A busy sibling is no reason not to wake here.
    assert_equal(pool.wakes_in_flight(0), 1)
    assert_false(pool.jobs_pending())
    pool.park_request(2, _request("/b"))
    assert_true(pool.submit(2))
    assert_equal(pool.wakes_in_flight(0), 1)
    # This thread's socket poll eats the wake, it takes job 1, and the
    # chain sends the wake the parked sibling is owed for job 2.
    assert_equal(_next_slot(pool), 1)
    assert_equal(pool.wakes_in_flight(0), 1)
    sleep(0.002)
    assert_equal(pool.wake_aged(perf_counter_ns(), 0), 0)
    pool.note_parked(0, -1)
    pool.note_thread(0, -2)
    assert_equal(_next_slot(pool), 2)
    pool.stop(1)
    assert_equal(_next_slot(pool), -1)
    assert_equal(pool.wakes_in_flight(0), 0)


def test_complete_wakes_only_a_parked_loop() raises:
    """The pool thread's half: push, then read the loop's flag, then poke.
    The flag starts SET (the inversion's driver never clears it), so a
    fresh pool pokes on every completion; a loop inside a pass clears it
    and the completion waits in memory, syscall-free."""
    var pool = OffloadPool(8)
    if not pool.ring_active():
        return
    assert_true(pool.loop_parked())
    pool.complete(3)
    assert_equal(_try_read(pool.complete_read), 8)
    var done = pool.drain_completions(read_fd=False)
    assert_equal(len(done), 1)
    assert_equal(done[0], 3)

    pool.set_loop_parked(False)
    pool.complete(4)
    assert_equal(_try_read(pool.complete_read), -1)
    assert_true(pool.done_pending())
    done = pool.drain_completions()
    assert_equal(len(done), 1)
    assert_equal(done[0], 4)
    assert_false(pool.done_pending())

    # A wake read by the drain itself is skipped, not served as slot -2.
    pool.set_loop_parked(True)
    pool.complete(5)
    done = pool.drain_completions()
    assert_equal(len(done), 1)
    assert_equal(done[0], 5)


def test_a_wake_datagram_is_not_a_job() raises:
    """A pool thread that reads a wake goes back to its ring; it never
    serves slot -2, and a pill queued behind a stale wake still ends it."""
    var pool = OffloadPool(8)
    if not pool.ring_active():
        return
    pool.note_parked(0, 1)
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    pool.note_parked(0, -1)
    # The socket poll and the ring pop both happen inside next_job, and
    # whichever order they land in the answer is the job, never the wake.
    assert_equal(_next_slot(pool), 1)
    assert_equal(pool.wakes_in_flight(0), 0)
    pool.stop(1)
    assert_equal(_next_slot(pool), -1)


def test_ring_off_is_the_datagram_handoff() raises:
    """`M0_POOL_RING=0`: no rings, no flags, and the two crossings are the
    socketpair syscalls they were — the A/B arm."""
    _ = setenv("M0_POOL_RING", "0", True)
    var pool = OffloadPool(8)
    _ = setenv("M0_POOL_RING", "", True)
    assert_false(pool.ring_active())
    assert_false(pool.loop_parked())
    assert_false(pool.done_pending())
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    assert_equal(_next_slot(pool), 1)
    _ = pool.take_request(1)
    pool.put_response(1, OK(String("x")))
    pool.complete(1)
    var done = pool.drain_completions()
    assert_equal(len(done), 1)
    assert_equal(done[0], 1)
    pool.stop(1)
    assert_equal(_next_slot(pool), -1)


comptime _PARK_ROUNDS = 200

comptime _SLOW_SLOT = 7
"""With `slow`, a job on this slot holds its echo thread for
`_SLOW_HOLD_S`: the slow view of the two-thread test below."""

comptime _SLOW_HOLD_S = 0.2


comptime _BLK_SERVED = 11
"""Block slot an echo thread counts its jobs in; read after the join."""


def _echo_thread[slow: Bool](arg: Int) -> Int:
    """A pool thread that answers every job with a 200, until its pill —
    registered on its lane exactly as `m0_wsgi`'s pool body registers
    itself, so it parks on a channel of its own and the elastic rules
    apply to it. With `slow`, `_SLOW_SLOT` is a 200 ms view."""
    var block = ThreadBlock(arg)
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )[]
    var buf = _job_buffer()
    var tid = pool.register_thread(0)
    var served = 0
    while True:
        var job = pool.next_job(0, buf, tid)
        if job.kind == JOB_STOP:
            break
        if job.kind != JOB_REQUEST:
            continue
        _ = pool.take_request(job.slot)

        comptime if slow:
            if job.slot == _SLOW_SLOT:
                sleep(_SLOW_HOLD_S)
        pool.put_response(job.slot, OK(String("x")))
        pool.complete(job.slot)
        served += 1
    pool.unregister_thread(tid, 0)
    block.set(_BLK_SERVED, served)
    block.set(BLK_STATUS, STATUS_OK)
    return 0


def _spawn_echo[slow: Bool](
    mut pool: OffloadPool, mut threads: ThreadSet, count: Int
) raises:
    """`count` echo threads on `pool`, with a wake channel reserved for
    each; returns once every one is parked."""
    pool.reserve_threads(count)
    var body = _echo_thread[slow]
    var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
    for i in range(count):
        threads.block(i).set(BLK_USER, pool.addr())
        threads.spawn(i, body_addr)
    _await_parked(pool, count)
    assert_equal(pool.registered_threads(), count)


def _await_completion(mut pool: OffloadPool, slot: Int, bound_ns: Int) raises -> Int:
    """Poll the completions until `slot` finishes; the nanoseconds it took,
    or -1 past `bound_ns`. Any other slot finishing first is a failure."""
    var start = perf_counter_ns()
    while perf_counter_ns() - start < bound_ns:
        var done = pool.drain_completions()
        if len(done) > 0:
            assert_equal(len(done), 1)
            assert_equal(done[0], slot)
            _ = pool.take_response(slot)
            return perf_counter_ns() - start
        sleep(0.0001)
    return -1


def _await_parked(pool: OffloadPool, count: Int) raises:
    """Wait until `count` threads of lane 0 are parked (bounded)."""
    var deadline = perf_counter_ns() + 2_000_000_000
    while pool.parked_count(0) != count or pool.wakes_in_flight(0) != 0:
        if perf_counter_ns() > deadline:
            assert_equal(pool.parked_count(0), count)
            assert_equal(pool.wakes_in_flight(0), 0)
        sleep(0.0005)


def test_a_job_behind_a_slow_sibling_is_taken_once_the_loop_wakes_a_parked_one() raises:
    """The isolation the pool exists for, under the elastic rules. Two
    threads; one is inside a 200 ms job. A second job pushed then wakes
    nobody (a thread is busy) and sits — until the test, standing in for
    the loop's per-pass age check, calls `wake_aged`: the parked thread
    takes it and it completes well inside the slow one's hold. The sit is
    asserted too, because the wake is the whole claim: without the age
    check the fast job waits the slow view out, which is the bug the pool
    was built against.

    covers: E17
    """
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    var threads = ThreadSet(2)
    _spawn_echo[True](pool, threads, 2)
    assert_equal(pool.thread_count(0), 2)

    # The slow job: every thread parked, so the push wakes one, which
    # takes it and sleeps.
    pool.park_request(_SLOW_SLOT, _request("/slow"))
    assert_true(pool.submit(_SLOW_SLOT))
    var deadline = perf_counter_ns() + 2_000_000_000
    while pool.jobs_pending() or pool.parked_count(0) != 1:
        assert_true(perf_counter_ns() < deadline)
        sleep(0.0005)

    # The fast job: a thread is busy, so nobody is woken, and it sits.
    pool.park_request(1, _request("/fast"))
    assert_true(pool.submit(1))
    assert_equal(pool.wakes_in_flight(0), 0)
    # The loop's look as it pushed: the ring just moved (the slow job was
    # taken), so nothing is stalled yet.
    assert_equal(pool.wake_aged(perf_counter_ns(), 1_000_000), 0)
    sleep(0.02)
    assert_equal(len(pool.drain_completions()), 0)
    assert_true(pool.jobs_pending())

    # The loop's next look: no pop for 20 ms against a 1 ms threshold.
    assert_equal(pool.wake_aged(perf_counter_ns(), 1_000_000), 1)
    var took = _await_completion(pool, 1, 2_000_000_000)
    assert_true(took >= 0)
    # Inside the slow hold by a wide margin: the parked thread took it.
    assert_true(took < 100_000_000)
    took = _await_completion(pool, _SLOW_SLOT, 2_000_000_000)
    assert_true(took >= 0)

    pool.stop(2)
    threads.join_all()
    assert_true(threads.all_ok())
    assert_equal(pool.thread_count(0), 0)


def test_a_parked_thread_is_woken_for_every_job() raises:
    """The lost-wakeup test. Two hundred jobs, each submitted only after the
    previous one completed and after a pause longer than the spin, so the
    thread has parked before every submit and every submit must wake it.
    A wake lost to a reordered announce/re-check/block is a job that never
    completes, which is what the two-second bound catches. The loop's flag
    is never cleared here, so every completion pokes the channel."""
    var pool = OffloadPool(8)
    if not pool.ring_active():
        return
    var threads = ThreadSet(1)
    _spawn_echo[False](pool, threads, 1)
    for round in range(_PARK_ROUNDS):
        sleep(0.0002)
        var slot = round % 8
        pool.park_request(slot, _request("/p"))
        assert_true(pool.submit(slot))
        var deadline = perf_counter_ns() + 2_000_000_000
        var got = False
        while perf_counter_ns() < deadline:
            var done = pool.drain_completions()
            if len(done) == 1:
                assert_equal(done[0], slot)
                got = True
                break
            sleep(0.0001)
        assert_true(got)
        _ = pool.take_response(slot)
    pool.stop(1)
    threads.join_all()
    assert_true(threads.all_ok())


def test_a_job_submitted_the_instant_the_last_completed_is_still_taken() raises:
    """The lost-wakeup test's other edge: each job submitted the moment
    the previous completion is read, with no pause, so the submit races
    the thread's own transitions — busy, then the lane's spinner, then
    parked — and under the elastic rules most of these submits wake
    nobody. Every one must still complete: a thread announcing a state
    re-checks the ring after the announcement, and the push precedes the
    loop's reads."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    var threads = ThreadSet(1)
    _spawn_echo[False](pool, threads, 1)
    for round in range(_PARK_ROUNDS):
        var slot = round % 6
        pool.park_request(slot, _request("/r"))
        assert_true(pool.submit(slot))
        var took = _await_completion(pool, slot, 2_000_000_000)
        assert_true(took >= 0)
    pool.stop(1)
    threads.join_all()
    assert_true(threads.all_ok())


def test_a_wake_lands_on_the_parked_threads_own_channel() raises:
    """A registered thread is woken by name: the lane socket stays quiet
    across a wake, and the pill that ends it goes the same way."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    var threads = ThreadSet(1)
    _spawn_echo[False](pool, threads, 1)
    pool.park_request(2, _request("/a"))
    assert_true(pool.submit(2))
    assert_equal(_try_read(pool.submit_read), -1)
    assert_true(_await_completion(pool, 2, 2_000_000_000) >= 0)
    assert_equal(pool.wake_counts(0)[1], 1)
    _await_parked(pool, 1)
    pool.stop(1)
    threads.join_all()
    assert_true(threads.all_ok())
    # The pill went to the thread's own channel, not the lane socket.
    assert_equal(_try_read(pool.submit_read), -1)
    assert_equal(pool.registered_threads(), 1)
    assert_equal(pool.thread_count(0), 0)


def test_sequential_jobs_with_idle_gaps_stay_on_one_thread() raises:
    """Most recently parked first. Two threads, sixty jobs each submitted
    after a pause longer than the spin, so the lane is all parked before
    every one: the thread that served the last job parked last, and is
    the one woken for the next — every job on the same warm thread, the
    other never woken. The kernel's own choice for one shared socket is
    the opposite on both platforms (macOS wakes all, Linux the oldest),
    which is where a third of zero-config's throughput went."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    var threads = ThreadSet(2)
    _spawn_echo[False](pool, threads, 2)
    for round in range(60):
        sleep(0.0003)
        var slot = round % 6
        pool.park_request(slot, _request("/s"))
        assert_true(pool.submit(slot))
        assert_true(_await_completion(pool, slot, 2_000_000_000) >= 0)
    _await_parked(pool, 2)
    pool.stop(2)
    threads.join_all()
    assert_true(threads.all_ok())
    var a = threads.block(0).get(_BLK_SERVED)
    var b = threads.block(1).get(_BLK_SERVED)
    assert_equal(a + b, 60)
    assert_true(a == 60 or b == 60)


def test_a_burst_into_a_parked_lane_wakes_one_thread() raises:
    """Four jobs pushed back to back into two parked threads send ONE
    wake: the first push wakes the last-parked thread, and from then on
    the lane is not all idle — a woken thread is on its way — so the
    other three wake nobody. All four complete, on that one thread."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    var threads = ThreadSet(2)
    _spawn_echo[False](pool, threads, 2)
    for slot in range(4):
        pool.park_request(slot, _request("/b"))
        assert_true(pool.submit(slot))
    assert_equal(pool.wake_counts(0)[1], 1)
    var seen = 0
    var deadline = perf_counter_ns() + 2_000_000_000
    while seen < 4 and perf_counter_ns() < deadline:
        var done = pool.drain_completions()
        for i in range(len(done)):
            _ = pool.take_response(done[i])
            seen += 1
        sleep(0.0001)
    assert_equal(seen, 4)
    assert_equal(pool.wake_counts(0)[1], 1)
    _await_parked(pool, 2)
    pool.stop(2)
    threads.join_all()
    assert_true(threads.all_ok())
    var a = threads.block(0).get(_BLK_SERVED)
    var b = threads.block(1).get(_BLK_SERVED)
    assert_true(a == 4 or b == 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
