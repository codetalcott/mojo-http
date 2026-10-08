"""The `--blocking-threads` work queue, exercised without any threads.

Every handoff `offload.mojo` performs is a socketpair round trip, and a
socketpair does not care whether its two ends are on different threads. So the
whole protocol — park, submit, receive, take, respond, complete, drain — runs
here on one thread, where a failure is a failed assertion rather than a hang.
What is NOT covered here is the concurrency itself; that is what
`poe smoke-blocking-threads` measures against a live server.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.os import setenv
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from lightbug_http.http import HTTPResponse, OK
from lightbug_http.http.request import HTTPRequest
from lightbug_http.c.platform import MSG_DONTWAIT, PlatformBackend
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.socket import close, recv
from lightbug_http.event_loop import _wait_for_events
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.loop.offload import _run_inline
from lightbug_http.loop.state import LoopState
from lightbug_http.service import HTTPService
from lightbug_http.offload import (
    JOB_STOP, JOB_REQUEST, JOB_NONE, JOB_WS_MESSAGE,
    OffloadPool, OffloadLoopState, OFFLOAD_MAX_INFLIGHT, STREAM_GEN_NONE,
    make_stream_ack_pair, drain_ack_fd, stream_gen_seed,
    COMPLETE_BATCH_MAX, SUBMIT_BATCH_MAX, TAG_JOB_BATCH, POOL_SPIN_NS,
    POOL_FREE_WAKE_AGE_NS, POOL_WAKE_WAIT_MS, _WAKE_MAX_LANES,
    WS_DATAGRAM_MAX, ws_message_room,
    send_bounded, append_i64_le, read_i64_le, ACK_BYTES, ACK_DISCONNECT,
    encode_ack, decode_ack,
)
from lightbug_http.ring import atomic_at
from lightbug_http.server_config import ServerConfig
from lightbug_http.uri import URI

from src.threads import (
    ThreadSet, ThreadBlock, BLK_USER, BLK_STATUS, BLK_LANE, STATUS_OK,
)


def _read_ack(fd: Int) raises -> Tuple[Int, Int]:
    """One ack datagram off an ack pair's read end, through the codec's
    own reader (`decode_ack`)."""
    var buf = List[UInt8](capacity=ACK_BYTES)
    for _ in range(ACK_BYTES):
        buf.append(0)
    var n = recv(FileDescriptor(fd), Span(buf), UInt(ACK_BYTES), 0)
    assert_equal(Int(n), ACK_BYTES)
    return decode_ack(Span(buf))


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


# --- the moves: derived by the compiler, pinned here ---


def _ints(xs: List[Int]) -> String:
    var s = String("[")
    for i in range(len(xs)):
        s += String(xs[i]) + ","
    return s + "]"


def _bools(xs: List[Bool]) -> String:
    var s = String("[")
    for i in range(len(xs)):
        s += "T," if xs[i] else "F,"
    return s + "]"


def _pool_fields(pool: OffloadPool) -> String:
    """Every field of `pool`, rendered: what a move has to carry whole."""
    var s = String()
    for i in range(len(pool.lane_prefixes)):
        s += "'" + pool.lane_prefixes[i] + "',"
    s += _ints(pool.lane_submit_read) + _ints(pool.lane_submit_write)
    s += String(pool.submit_read) + "," + String(pool.submit_write) + ","
    s += String(pool.complete_read) + "," + String(pool.complete_write) + ","
    for i in range(len(pool.requests)):
        s += "R" if pool.requests[i] else "-"
    for i in range(len(pool.responses)):
        s += "S" if pool.responses[i] else "-"
    s += _bools(pool.errored)
    s += String(pool.stream_chunk_read) + "," + String(pool.stream_chunk_write) + ","
    s += String(pool.stream_ack_read) + "," + String(pool.stream_ack_write) + ","
    s += String(pool.hold_notify_fd) + ","
    s += _ints(pool.slot_lane) + _ints(pool.lane_ack_read) + _ints(pool.lane_ack_write)
    s += _ints(pool.slot_ack_fd) + _ints(pool.aborts)
    s += String(len(pool._drain_buf)) + "," + String(pool.sweep_every_pass) + ","
    s += String(pool.capacity) + "," + String(pool.ring_enabled) + ","
    for i in range(len(pool.job_rings)):
        s += String(pool.job_rings[i].base) + "/" + String(pool.job_rings[i].mask) + ","
    s += String(pool.done_ring.base) + "/" + String(pool.done_ring.mask) + ","
    s += String(pool.wake_base) + "," + String(pool.elastic) + ","
    s += String(pool.debug) + ","
    s += _ints(pool.submit_ns) + _ints(pool.lane_pops) + _ints(pool.lane_progress)
    s += String(pool.last_look) + ","
    s += String(pool.parallel) + "," + String(pool._parallel_forced) + ","
    s += _bools(pool.lane_gil_free)
    s += String(pool.wake_age) + "," + String(pool.spin) + ","
    s += String(pool.thread_base) + "," + String(pool.thread_cap)
    return s^


def _loop_state_fields(state: OffloadLoopState) -> String:
    """Every field of `state`, rendered, as `_pool_fields` does the pool's."""
    var s = String(state.addr) + ","
    s += _bools(state.offloaded) + _bools(state.is_head)
    s += _bools(state.http11) + _bools(state.chunked)
    s += _ints(state.ack_payload) + _ints(state.ack_owed)
    s += String(state.ack_owed_count) + "," + String(state.inflight) + ","
    s += _ints(state.stream_gen)
    for i in range(len(state.pending_submit)):
        s += _ints(state.pending_submit[i])
    s += String(state.pending_submit_count) + "," + String(state.streaming_hint) + ","
    s += _ints(state.done_scratch)
    s += String(state.waits) + "," + String(state.waits_capped) + ","
    s += String(state.waits_skipped) + "," + String(state.waits_empty) + ","
    s += _ints(state.wait_over) + _ints(state.pass_over)
    return s^


def _moved_pool(var pool: OffloadPool) -> OffloadPool:
    """A transfer through a call, so the move constructor runs whatever the
    optimiser makes of a transfer between two locals."""
    return pool^


def _moved_loop_state(var state: OffloadLoopState) -> OffloadLoopState:
    return state^


def test_a_moved_pool_carries_every_field() raises:
    """`OffloadPool`'s move is the one Mojo 1.1 derives: the hand-written
    one listed all 39 fields and did nothing else. Every field is set away
    from its default here, the pool is moved, and the moved value reads back
    whole -- and still hands over the job it was holding."""
    var pool = OffloadPool(8)
    pool.add_lane(String(""))
    pool.add_lane(String("/b"))
    pool.enable_stream_channel()
    pool.enable_base_stream_ack()
    pool.enable_stream_ack(1)
    pool.set_hold_notify(42)
    pool.set_sweep_every_pass()
    pool.set_lane_gil_free(1)
    pool.set_parallel(True)
    pool.reserve_threads(2)
    pool.set_slot_ack_fd(3, 17)
    pool.stamp_lane(5, 1)
    pool.put_response(2, OK(String("x")), raised=True)
    assert_true(pool.abort_stream(4, 9))
    _ = pool.drain_completions()
    _ = pool.wake_aged(12345, 1)
    pool.park_request(6, _request("/a"))
    assert_true(pool.submit(6, String("/a")))
    var before = _pool_fields(pool)
    var moved = _moved_pool(pool^)
    assert_equal(_pool_fields(moved), before)
    var buf = _job_buffer()
    var job = moved.try_next_job(0, buf)
    assert_equal(job.kind, JOB_REQUEST)
    assert_equal(job.slot, 6)
    assert_equal(moved.take_request(6).uri.path, "/a")
    var aborts = moved.take_aborts()
    assert_equal(len(aborts), 2)
    assert_equal(aborts[0], 4)
    assert_equal(aborts[1], 9)


def test_a_moved_loop_state_carries_every_field() raises:
    """The same for `OffloadLoopState`, which `LoopState` moves into itself
    on every server start: all 20 fields set, moved, and read back whole."""
    var pool = OffloadPool(8)
    var state = OffloadLoopState(pool.addr(), 8)
    state.offloaded[1] = True
    state.is_head[2] = True
    state.http11[3] = True
    state.chunked[4] = True
    state.ack_payload[5] = 55
    state.ack_owed[6] = 66
    state.ack_owed_count = 1
    state.inflight = 3
    state.stream_gen[7] = 77
    _ = state.queue_submit(2, 1)
    state.streaming_hint = 4
    state.done_scratch.append(9)
    state.note_wait(True, True, 0, 3_000_000)
    state.note_wait(False, False, 0)
    state.note_pass(5_000_000)
    var before = _loop_state_fields(state)
    var moved = _moved_loop_state(state^)
    assert_equal(_loop_state_fields(moved), before)
    assert_equal(moved.pool()[].capacity, 8)
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
    channel's in datagram order and THEN the ring's in push order. The
    channel goes first on purpose: a stream's abort rides it and its head
    rides the ring, pushed before the abort was sent, so reading the channel
    first is what guarantees a drain never holds an abort without its head
    (`drain_completions_into`'s docstring). This pins that order."""
    var pool = OffloadPool(16)
    pool.complete(2)
    assert_true(pool.complete_many([3, 4]))
    pool.complete(9)
    var done = pool.drain_completions()
    assert_equal(len(done), 4)
    if pool.ring_active():
        assert_equal(done[0], 3)
        assert_equal(done[1], 4)
        assert_equal(done[2], 2)
        assert_equal(done[3], 9)
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


def test_a_websocket_message_is_one_datagram_in_the_pool_shape() raises:
    """`send_ws_message` is the one encoder of a pool lane's inbound
    WebSocket message, the loop handler's live path included:
    `[2][slot i64 LE][opcode][chan_len u16 LE][channel][payload]` on the
    lane's own socket -- byte for byte what the handler's deleted copy sent
    -- and what `next_job` on that lane takes apart. The channel is longer
    than 255 bytes so its length's high byte is on the wire."""
    var pool = OffloadPool(8)
    pool.add_lane(String(""))
    pool.add_lane(String("/b"))
    var chan = String("")
    for i in range(300):
        chan += String(i % 10)
    var payload = List[UInt8]()
    for b in String("hello").as_bytes():
        payload.append(b)
    assert_true(pool.send_ws_message(1, 1027, 2, chan, Span(payload)))
    var got = _read_datagram(pool.submit_read_fd(1))
    var want: List[UInt8] = [2, 0x03, 0x04, 0, 0, 0, 0, 0, 0, 2, 0x2C, 0x01]
    for b in chan.as_bytes():
        want.append(b)
    for b in payload:
        want.append(b)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]))
    # Nothing on lane 0: the message went to the lane it was addressed to.
    assert_equal(_try_read(pool.submit_read), -1)
    assert_true(pool.send_ws_message(1, 1027, 2, chan, Span(payload)))
    var buf = _job_buffer()
    var job = pool.next_job(1, buf)
    assert_equal(job.kind, JOB_WS_MESSAGE)
    assert_equal(job.slot, 1027)
    assert_equal(job.opcode, 2)
    assert_equal(job.chan_len, 300)
    var name = String(StringSpan(
        unsafe_from_utf8=Span(buf)[job.chan_start : job.chan_start + job.chan_len]
    ))
    assert_equal(name, chan)
    assert_equal(job.payload_len, 5)
    for i in range(5):
        assert_equal(Int(buf[job.payload_start + i]), Int(payload[i]))


def test_a_websocket_message_fills_its_datagram_and_not_a_byte_more() raises:
    """The bound the loop handler's 1009 check and the encoder share
    (`ws_message_room`, SPEC I26): a payload of exactly the room is one
    datagram of exactly `WS_DATAGRAM_MAX` bytes, the buffer a pool thread
    posts; one byte more is refused, and nothing is sent. Read into a
    buffer LARGER than the bound, so a datagram past it would show its real
    size here rather than arrive truncated."""
    var pool = OffloadPool(8)
    var chan = String("room/42")
    var room = ws_message_room(chan)
    var payload = List[UInt8](capacity=room + 1)
    for i in range(room + 1):
        payload.append(UInt8(i & 0xFF))
    assert_false(pool.send_ws_message(0, 5, 1, chan, Span(payload)))
    assert_equal(_try_read(pool.submit_read), -1)
    _ = payload.pop()
    assert_true(pool.send_ws_message(0, 5, 1, chan, Span(payload)))
    var big = List[UInt8](capacity=WS_DATAGRAM_MAX + 64)
    for _ in range(WS_DATAGRAM_MAX + 64):
        big.append(0)
    var n = recv(FileDescriptor(pool.submit_read), Span(big), UInt(len(big)), 0)
    assert_equal(Int(n), WS_DATAGRAM_MAX)
    assert_equal(Int(big[WS_DATAGRAM_MAX - 1]), (room - 1) & 0xFF)


def _le(value: Int) -> List[UInt8]:
    var out = List[UInt8]()
    append_i64_le(out, value)
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]))


def test_the_i64_codec_is_little_endian_twos_complement() raises:
    """`append_i64_le` and `read_i64_le` are the one codec of every slot,
    generation and event id on the pool's channels and the loop handler's
    tags, where each sender and reader used to spell its own. The pill
    (-1) and the wake (-2) are negative, so two's complement is on the
    wire; a slot is read at an offset, after a tag byte."""
    _assert_bytes(_le(0), [0, 0, 0, 0, 0, 0, 0, 0])
    _assert_bytes(_le(-1), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    _assert_bytes(_le(-2), [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    _assert_bytes(_le(0x0102030405060708), [8, 7, 6, 5, 4, 3, 2, 1])
    _assert_bytes(_le(-9223372036854775807 - 1), [0, 0, 0, 0, 0, 0, 0, 0x80])
    for v in [0, 1027, -1, -2, 9223372036854775807, -9223372036854775807 - 1]:
        var buf: List[UInt8] = [4]
        append_i64_le(buf, v)
        buf.append(9)
        assert_equal(read_i64_le(Span(buf), 1), v)


def test_the_ack_codec_is_i32_little_endian_and_sign_extends() raises:
    """`encode_ack` and `decode_ack` are the one codec of a drain ack,
    `(slot: i32 LE, credit: i32 LE)`, where the loop's credit
    (`ack_stream`), its disconnect to a pool thread
    (`_send_pool_disconnect`, `ACK_DISCONNECT`) and the thread's reader
    (`_read_ack`) each used to spell their own. The shim reads an
    executor's with `int.from_bytes(..., 'little')`, so the byte order is
    pinned here, and the disconnect's -1 must come back as -1: a credit of
    4294967295 is a stream that never learns its client left."""
    _assert_bytes(encode_ack(3, 70000), [3, 0, 0, 0, 0x70, 0x11, 0x01, 0])
    _assert_bytes(
        encode_ack(42, ACK_DISCONNECT), [42, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]
    )
    _assert_bytes(encode_ack(0x01020304, 0), [4, 3, 2, 1, 0, 0, 0, 0])
    assert_equal(len(encode_ack(1023, 65536)), ACK_BYTES)
    for pair in [
        (0, 0), (1023, 65536), (42, ACK_DISCONNECT), (7, 2147483647),
        (7, -2147483648),
    ]:
        var wire = encode_ack(pair[0], pair[1])
        var got = decode_ack(Span(wire))
        assert_equal(got[0], pair[0])
        assert_equal(got[1], pair[1])
    # What `ack_stream` writes is what the codec reads.
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    pool.enable_base_stream_ack()
    assert_true(pool.ack_stream(5, 4096))
    var got = _read_ack(pool.stream_ack_read)
    assert_equal(got[0], 5)
    assert_equal(got[1], 4096)


def test_send_bounded_reports_a_channel_that_will_not_take_it() raises:
    """`send_bounded` is every sender's retry. A datagram the channel takes
    goes whole; on a channel stuffed until it refuses, it gives up after
    its tries and says so rather than parking (its senders run on the loop,
    or attached); and once the reader takes one, the next goes."""
    var pair = make_stream_ack_pair()
    var msg: List[UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    assert_true(send_bounded(pair[1], Span(msg)))
    var stuffed = 1
    while send_bounded(pair[1], Span(msg), tries=1):
        stuffed += 1
        assert_true(stuffed < 100_000)
    assert_false(send_bounded(pair[1], Span(msg)))
    _assert_bytes(_read_datagram(pair[0]), msg)
    assert_true(send_bounded(pair[1], Span(msg)))


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


def test_a_gil_free_lane_wakes_a_sibling_behind_a_draining_ring() raises:
    """A Mojo mount's lane, beside a Python lane in one pool. Both get the
    same history: two threads, one parked, three jobs pushed, one taken, so
    each ring has MOVED since the loop's last look. The Python lane is left
    alone (the progress rule: a sibling would queue for the GIL). The
    GIL-free lane gets its parked sibling woken, because its head has waited
    past `POOL_FREE_WAKE_AGE_NS` since its push -- at 50 ms on a clock whose
    GIL threshold is 100 ms, so both halves are pinned: counting from the
    push, and the lower threshold. Without them `/native/search` ran on one
    of four threads. `submit` stays elastic on both lanes: a push beside a
    busy thread wakes nobody, which is what keeps a trivial Mojo route at
    one thread's rate. `M0_POOL_PARALLEL=0` puts the GIL rule back.

    covers: M25
    """
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    comptime T = 100_000_000
    comptime MS = 1_000_000
    pool.add_lane(String(""))
    pool.add_lane(String("/native"))
    pool.set_lane_gil_free(1)
    assert_false(pool.is_lane_gil_free(0))
    assert_true(pool.is_lane_gil_free(1))
    assert_true(POOL_FREE_WAKE_AGE_NS < 50 * MS)
    for lane in range(2):
        pool.note_thread(lane, 2)
        pool.note_parked(lane, 1)
    var t0 = perf_counter_ns()
    assert_equal(pool.wake_aged(t0, T), 0)
    for slot in range(3):
        pool.park_request(slot, _request("/q"))
        assert_true(pool.submit(slot, String("/q")))
        pool.park_request(slot + 3, _request("/native/q"))
        assert_true(pool.submit(slot + 3, String("/native/q")))
    # Elastic submit on both: a thread of each lane is busy.
    assert_equal(pool.wakes_in_flight(0), 0)
    assert_equal(pool.wakes_in_flight(1), 0)
    # The busy threads take one job each: both rings moved.
    assert_equal(_next_slot(pool, 0), 0)
    assert_equal(_next_slot(pool, 1), 3)
    assert_equal(pool.wake_aged(t0 + 50 * MS, T), 1)
    assert_equal(pool.wakes_in_flight(0), 0)
    assert_equal(pool.wakes_in_flight(1), 1)
    # One wake per parked thread, however many passes find the head old.
    assert_equal(pool.wake_aged(t0 + 60 * MS, T), 0)
    # The woken sibling takes the rest; its socket poll retires the wake.
    pool.note_parked(1, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool, 1), 4)
    assert_equal(_next_slot(pool, 1), 5)
    assert_equal(pool.wakes_in_flight(1), 0)
    assert_equal(_next_slot(pool, 0), 1)
    assert_equal(_next_slot(pool, 0), 2)
    pool.note_parked(0, -1)
    for lane in range(2):
        pool.note_thread(lane, -2)

    # The knob: forced to the GIL rule, a marked lane is an ordinary one.
    _ = setenv("M0_POOL_PARALLEL", "0", True)
    var forced = OffloadPool(8)
    _ = setenv("M0_POOL_PARALLEL", "", True)
    forced.add_lane(String(""))
    forced.add_lane(String("/native"))
    forced.set_lane_gil_free(1)
    assert_false(forced.is_lane_gil_free(1))
    forced.note_thread(1, 2)
    forced.note_parked(1, 1)
    var t1 = perf_counter_ns()
    assert_equal(forced.wake_aged(t1, T), 0)
    for slot in range(2):
        forced.park_request(slot, _request("/native/q"))
        assert_true(forced.submit(slot, String("/native/q")))
    assert_equal(_next_slot(forced, 1), 0)
    assert_equal(forced.wake_aged(t1 + 50 * MS, T), 0)
    assert_equal(forced.wakes_in_flight(1), 0)
    assert_equal(_next_slot(forced, 1), 1)
    forced.note_parked(1, -1)
    forced.note_thread(1, -2)


def test_the_idle_spin_follows_its_measurement_knob() raises:
    """`M0_POOL_SPIN_US` overrides `POOL_SPIN_NS`, in microseconds, read once
    when the pool is built. Four records described this knob for a week
    while nothing read it; this is what keeps it read. A value that does not
    parse, or a negative one, keeps the default rather than spinning for
    nothing or forever."""
    _ = setenv("M0_POOL_SPIN_US", "", True)
    assert_equal(OffloadPool(4).spin_ns(), POOL_SPIN_NS)
    _ = setenv("M0_POOL_SPIN_US", "0", True)
    assert_equal(OffloadPool(4).spin_ns(), 0)
    _ = setenv("M0_POOL_SPIN_US", "250", True)
    assert_equal(OffloadPool(4).spin_ns(), 250_000)
    _ = setenv("M0_POOL_SPIN_US", "ten", True)
    assert_equal(OffloadPool(4).spin_ns(), POOL_SPIN_NS)
    _ = setenv("M0_POOL_SPIN_US", "-5", True)
    assert_equal(OffloadPool(4).spin_ns(), POOL_SPIN_NS)
    _ = setenv("M0_POOL_SPIN_US", "", True)


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


def test_the_loop_looks_when_a_heads_threshold_runs_out() raises:
    """The look's timing (`OffloadPool.next_look`). A job pushed beside a
    busy thread wakes nobody at the push -- the elastic rule -- and the
    loop's next look must come when that head's threshold runs out: its
    push plus `POOL_FREE_WAKE_AGE_NS` on a GIL-free lane, plus the GIL
    threshold on a GIL lane. It came at the next pass instead, and an idle
    loop passed once per `POOL_WAKE_WAIT_MS`, so a fast request that met
    one slow view waited 1.3 ms whatever its threshold.

    Each deadline is offered ONCE: a look before it wakes nobody and
    leaves it standing, the look at it wakes the parked sibling, and a
    judged deadline is not offered again while its head stands -- or a
    lane whose threads are all busy would turn every wait into a spin. A
    ring a GIL lane is draining is offered a look one threshold after
    now, since the look will count the move as progress. And no look is
    offered where no wake is owed: under the eager rules
    (`M0_POOL_ELASTIC=0`) the push woke a thread itself, and a head the
    lane's spinner took leaves nothing to look at -- the look scheduled
    for it wakes nobody. The clock is simulated from one real origin,
    far enough apart that real time between calls cannot cross a
    boundary.

    covers: E37
    """
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    comptime T = 100_000_000
    pool.add_lane(String(""))
    pool.add_lane(String("/native"))
    pool.set_lane_gil_free(1)
    for lane in range(2):
        pool.note_thread(lane, 2)
        pool.note_parked(lane, 1)
    var t0 = perf_counter_ns()
    assert_equal(pool.wake_aged(t0, T), 0)
    # Nothing pending: nothing to look at.
    assert_equal(pool.next_look(t0, T), 0)
    pool.park_request(1, _request("/q"))
    assert_true(pool.submit(1, String("/q")))
    pool.park_request(2, _request("/native/q"))
    assert_true(pool.submit(2, String("/native/q")))
    # Beside a busy thread the push wakes nobody, on either lane.
    assert_equal(pool.wakes_in_flight(0), 0)
    assert_equal(pool.wakes_in_flight(1), 0)
    var gil_due = pool.submitted_ns(1) + T
    var free_due = pool.submitted_ns(2) + POOL_FREE_WAKE_AGE_NS
    assert_true(free_due < gil_due)
    # The earliest deadline is the GIL-free head's: its push plus 10 µs.
    assert_equal(pool.next_look(t0, T), free_due)
    # A look before it wakes nobody, and the deadline stands.
    assert_equal(pool.wake_aged(free_due - 1, T), 0)
    assert_equal(pool.next_look(free_due - 1, T), free_due)
    # The look at it wakes the parked sibling.
    assert_equal(pool.wake_aged(free_due, T), 1)
    assert_equal(pool.wakes_in_flight(1), 1)
    # Judged: not offered again, though its head stands until the woken
    # thread takes it. The GIL lane's deadline is next, and the same.
    assert_equal(pool.next_look(free_due + 1, T), gil_due)
    assert_equal(pool.wake_aged(gil_due, T), 1)
    assert_equal(pool.wakes_in_flight(0), 1)
    assert_equal(pool.next_look(gil_due + 1, T), 0)
    # The woken threads take their jobs; each one's socket poll retires
    # its wake.
    for lane in range(2):
        pool.note_parked(lane, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool, 1), 2)
    assert_equal(_next_slot(pool, 0), 1)
    assert_equal(pool.wakes_in_flight(0), 0)
    assert_equal(pool.wakes_in_flight(1), 0)
    for lane in range(2):
        pool.note_thread(lane, -2)

    # A GIL lane being drained: looked at one threshold after now, where
    # the look will see the move and count the wait from itself.
    var drained = OffloadPool(8)
    drained.note_thread(0, 2)
    drained.note_parked(0, 1)
    var t1 = perf_counter_ns()
    assert_equal(drained.wake_aged(t1, T), 0)
    for slot in range(2):
        drained.park_request(slot, _request("/q"))
        assert_true(drained.submit(slot))
    assert_equal(_next_slot(drained), 0)
    var t2 = t1 + 50_000_000
    assert_equal(drained.next_look(t2, T), t2 + T)
    assert_equal(drained.wake_aged(t2, T), 0)
    assert_equal(drained.next_look(t2 + 1, T), t2 + T)
    assert_equal(_next_slot(drained), 1)
    drained.note_parked(0, -1)
    drained.note_thread(0, -2)

    # The lane's spinner takes the head itself: the look scheduled for it
    # finds nothing and wakes nobody.
    var spun = OffloadPool(8)
    spun.set_lane_gil_free(0)
    spun.note_thread(0, 3)
    spun.note_parked(0, 1)
    spun.note_spinning(0, 1)
    var t3 = perf_counter_ns()
    assert_equal(spun.wake_aged(t3, T), 0)
    spun.park_request(4, _request("/q"))
    assert_true(spun.submit(4))
    assert_equal(spun.wakes_in_flight(0), 0)
    var spun_due = spun.submitted_ns(4) + POOL_FREE_WAKE_AGE_NS
    assert_equal(spun.next_look(t3, T), spun_due)
    assert_equal(_next_slot(spun), 4)
    assert_equal(spun.next_look(spun_due, T), 0)
    assert_equal(spun.wake_aged(spun_due, T), 0)
    assert_equal(spun.wakes_in_flight(0), 0)
    spun.note_spinning(0, -1)
    spun.note_parked(0, -1)
    spun.note_thread(0, -3)

    # The eager rules: the push wakes the parked thread itself, and the
    # loop is offered no look.
    _ = setenv("M0_POOL_ELASTIC", "0", True)
    var eager = OffloadPool(8)
    _ = setenv("M0_POOL_ELASTIC", "", True)
    assert_false(eager.elastic_active())
    eager.note_parked(0, 1)
    eager.park_request(1, _request("/a"))
    assert_true(eager.submit(1))
    assert_equal(eager.wakes_in_flight(0), 1)
    assert_equal(eager.next_look(perf_counter_ns(), T), 0)
    eager.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(eager), 1)


struct WaitRecordingBackend(EventLoopBackend):
    """A backend that reports no events and records how each wait was
    asked for: `wait`'s milliseconds, or `wait_ns`'s nanoseconds."""

    var ms: List[Int]
    var ns: List[Int]

    def __init__(out self):
        self.ms = List[Int]()
        self.ns = List[Int]()

    def wait(mut self, timeout_ms: Int) raises -> Int:
        self.ms.append(timeout_ms)
        return 0

    def wait_ns(mut self, timeout_ns: Int) raises -> Int:
        self.ns.append(timeout_ns)
        return 0

    def event_ident(self, i: Int) -> UInt:
        return 0

    def event_filter(self, i: Int) -> Int16:
        return 0

    def event_flags(self, i: Int) -> UInt16:
        return 0

    def event_data(self, i: Int) -> Int:
        return 0

    def add_read_listen(mut self, fd: Int) raises:
        pass

    def add_read(mut self, fd: Int) raises:
        pass

    def try_add_read(mut self, fd: Int):
        pass

    def add_write_oneshot(mut self, fd: Int) raises:
        pass

    def try_add_write_oneshot(mut self, fd: Int):
        pass

    def try_delete_read(mut self, fd: Int):
        pass

    def try_delete_write(mut self, fd: Int):
        pass

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        pass

    def try_delete_timer(mut self, ident: UInt):
        pass


def test_an_idle_loop_waits_for_a_pending_heads_deadline() raises:
    """`_wait_for_events` is where the look's timing reaches the kernel.
    Rings empty, the wait is the caller's, in milliseconds. A job pending
    beside a busy thread of a GIL-free lane: the wait is `wait_ns`, ending
    at the head's deadline, no later than `POOL_FREE_WAKE_AGE_NS` after its
    push -- where it was `POOL_WAKE_WAIT_MS`. Once the look has judged that
    deadline (it woke the parked sibling), the wait falls back to
    `POOL_WAKE_WAIT_MS` rather than being offered the same deadline, a
    wait of nothing, on every pass."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    pool.set_lane_gil_free(0)
    pool.note_thread(0, 2)
    pool.note_parked(0, 1)
    var config = ServerConfig()
    config.max_connections = 8
    var st = LoopState(
        FileDescriptor(-1), config, String(""), True, offload_addr=pool.addr()
    )
    var backend = WaitRecordingBackend()
    _ = _wait_for_events(backend, st, 1000)
    assert_equal(len(backend.ms), 1)
    assert_equal(backend.ms[0], 1000)
    assert_equal(len(backend.ns), 0)
    # A job beside the busy thread: nobody woken at the push, and a look
    # at the push finds it fresh. The look is given the push's own clock,
    # not a later one: the threshold is `POOL_FREE_WAKE_AGE_NS`, 10 us, and
    # a test thread paused that long between the two lines aged the job
    # (seen on the macOS runner, 2026-10-02).
    pool.park_request(1, _request("/a"))
    assert_true(pool.submit(1))
    assert_equal(pool.wakes_in_flight(0), 0)
    assert_equal(st.offload.wake_aged(pool.submitted_ns(1)), 0)
    var before = perf_counter_ns()
    _ = _wait_for_events(backend, st, 1000)
    assert_equal(len(backend.ms), 1, "the wait was not timed to the head")
    assert_equal(len(backend.ns), 1)
    var left = pool.submitted_ns(1) + POOL_FREE_WAKE_AGE_NS - before
    assert_true(backend.ns[0] <= (left if left > 0 else 0))
    # The look at the deadline wakes the sibling; judged, the deadline is
    # not offered again, and the wait is the pool's fallback cadence.
    sleep(0.0001)
    assert_equal(st.offload.wake_aged(perf_counter_ns()), 1)
    _ = _wait_for_events(backend, st, 1000)
    assert_equal(len(backend.ns), 1, "a judged deadline was offered again")
    assert_equal(len(backend.ms), 2)
    assert_equal(backend.ms[1], POOL_WAKE_WAIT_MS)
    pool.note_parked(0, -1)
    sleep(0.0002)
    assert_equal(_next_slot(pool), 1)
    assert_equal(pool.wakes_in_flight(0), 0)
    _ = _wait_for_events(backend, st, 1000)
    assert_equal(backend.ms[2], 1000)
    pool.note_thread(0, -2)


def test_the_platform_backend_waits_in_nanoseconds() raises:
    """`wait_ns` on the backend this build serves on keeps its
    nanoseconds: the best of twenty 100 µs waits is at least 90 µs (not
    rounded to nothing, a spin) and under 900 µs (not rounded up to
    `epoll_wait`'s millisecond, the timing the look exists for). On Linux
    this is `epoll_pwait2` by syscall number, and nothing else runs it
    before a request does: an argument out of place is a refusal the
    backend answers by falling back, which serves, silently, at the old
    cadence. A kernel older than 5.11 fails the second bound by design."""
    var backend = PlatformBackend()
    var best = 1_000_000_000
    for _ in range(20):
        var t0 = perf_counter_ns()
        var n = backend.wait_ns(100_000)
        var took = perf_counter_ns() - t0
        assert_equal(n, 0)
        if took < best:
            best = took
    assert_true(best >= 90_000, "a 100 µs wait returned in " + String(best) + " ns")
    assert_true(
        best < 900_000,
        "a 100 µs wait took " + String(best) + " ns: rounded up to a millisecond",
    )


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


def _stream_pair() raises -> Tuple[Int, Int]:
    """An `AF_UNIX` `SOCK_STREAM` pair, non-blocking at both ends: the first
    end is the server's side of a connection, the second the client's."""
    var fds = unsafe_alloc[c_int](count=2)
    var rc = external_call[
        "socketpair", c_int, c_int, c_int, c_int, type_of(fds)
    ](c_int(1), c_int(1), c_int(0), fds)  # AF_UNIX, SOCK_STREAM
    if rc != 0:
        var errno = get_errno()
        fds.unsafe_free()
        raise Error("socketpair() failed, errno: ", errno)
    var pair = (Int(fds[unsafe_offset=0]), Int(fds[unsafe_offset=1]))
    fds.unsafe_free()
    set_nonblocking(FileDescriptor(pair[0]))
    set_nonblocking(FileDescriptor(pair[1]))
    return pair


struct _InlineApp(HTTPService):
    """Counts the requests the loop ran itself."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.calls += 1
        return OK(String("inline"))


def test_run_inline_counts_only_the_requests_it_ran() raises:
    """`_run_inline` answers how many requests the handler ran, not how
    many slots it was handed. Of three, one is no longer offloaded and is
    skipped, one's client left while its request sat in the buffer and is
    released unanswered, and one is answered on its connection: one ran.
    It answered `len(slots)`, three here (review record LF31). Both callers
    discard the count today, so this test is what keeps it honest."""
    var pool = OffloadPool(8)
    var config = ServerConfig()
    config.max_connections = 8
    var st = LoopState(
        FileDescriptor(-1), config, String(""), True, offload_addr=pool.addr()
    )
    var backend = PlatformBackend()
    var app = _InlineApp()
    var skipped = st.provision_pool.borrow()
    var gone = st.provision_pool.borrow()
    pool.park_request(gone, _request("/gone"))
    st.offload.offloaded[gone] = True
    st.offload.inflight += 1
    var live = st.provision_pool.borrow()
    var pair = _stream_pair()
    st.slot_fds[live] = pair[0]
    st.fd_to_slot[pair[0]] = live
    st.active_count = 1
    pool.park_request(live, _request("/live"))
    st.offload.offloaded[live] = True
    st.offload.inflight += 1
    var slots = List[Int]()
    slots.append(skipped)
    slots.append(gone)
    slots.append(live)
    assert_equal(_run_inline(app, backend, st, slots), 1)
    assert_equal(app.calls, 1)
    assert_equal(st.offload.inflight, 0)
    var buf = _job_buffer()
    var n = recv(FileDescriptor(pair[1]), Span(buf), UInt(len(buf)), MSG_DONTWAIT)
    var reply = String(unsafe_from_utf8=Span(buf)[: Int(n)])
    assert_true(reply.startswith("HTTP/1.1 200"), reply)
    close(FileDescriptor(pair[0]))
    close(FileDescriptor(pair[1]))
    # `pool` must outlive the loop state that holds its address.
    _ = pool.capacity


def test_ring_off_is_the_datagram_handoff() raises:
    """`M0_POOL_RING=0`: no rings, no flags, and the two crossings are the
    socketpair syscalls they were — the A/B arm."""
    _ = setenv("M0_POOL_RING", "0", True)
    var pool = OffloadPool(8)
    _ = setenv("M0_POOL_RING", "", True)
    assert_false(pool.ring_active())
    assert_false(pool.loop_parked())
    assert_false(pool.done_pending())
    # Lane i's ring is `job_rings[i]` on either hand-off: a disabled one
    # each here (review record LF31; lane 1's sat at index 0).
    pool.add_lane(String(""))
    pool.add_lane(String("/x"))
    assert_equal(len(pool.job_rings), 2)
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


def _pool(ring_off: Bool) raises -> OffloadPool:
    """A pool on the ring, or on the datagram hand-off (`M0_POOL_RING=0`)."""
    if ring_off:
        _ = setenv("M0_POOL_RING", "0", True)
    var pool = OffloadPool(8)
    _ = setenv("M0_POOL_RING", "", True)
    return pool^


def test_try_next_job_takes_what_is_queued() raises:
    """`try_next_job` is `next_job` without the wait -- what a pool thread
    calls holding the GIL inside its hand-off slice (`m0_wsgi.blocking_pool`,
    docs/notes/a-slice-keeps-the-gil.md): the jobs already queued, in
    order. On the ring and on the datagram hand-off. The empty lane is the
    next test's, on a thread of its own: asked here, a version that waits
    would hang the suite rather than fail it."""
    for ring_off in range(2):
        var pool = _pool(ring_off == 1)
        var buf = _job_buffer()
        pool.park_request(3, _request("/a"))
        assert_true(pool.submit(3))
        pool.park_request(5, _request("/b"))
        assert_true(pool.submit(5))
        var first = pool.try_next_job(0, buf)
        assert_equal(first.kind, JOB_REQUEST)
        assert_equal(first.slot, 3)
        var second = pool.try_next_job(0, buf)
        assert_equal(second.kind, JOB_REQUEST)
        assert_equal(second.slot, 5)
        _ = pool.take_request(3)
        _ = pool.take_request(5)


comptime _BLK_KIND = 12
"""Block slot `_try_once` leaves the kind it was answered in."""


def _try_once(arg: Int) -> Int:
    """One `try_next_job` against an empty lane, on a thread of its own."""
    var block = ThreadBlock(arg)
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )[]
    var buf = _job_buffer()
    block.set(_BLK_KIND, pool.try_next_job(0, buf).kind)
    block.set(BLK_STATUS, STATUS_OK)
    return 0


def test_try_next_job_answers_an_empty_lane_at_once() raises:
    """The contract the keep rule rests on: its caller HOLDS the GIL, so an
    empty lane is answered at once, never spun on or parked in -- a park
    there would hold the GIL through a sleep with no timeout. Called on a
    thread of its own so that a version that waits fails inside a second
    instead of hanging the suite, and is released with a job and a pill."""
    for ring_off in range(2):
        var pool = _pool(ring_off == 1)
        var threads = ThreadSet(1)
        var body = _try_once
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        threads.block(0).set(BLK_USER, pool.addr())
        threads.spawn(0, body_addr)
        var left = threads.join_within(1_000_000_000)
        if left != 0:
            pool.park_request(1, _request("/x"))
            _ = pool.submit(1)
            pool.stop(1)
            threads.join_all()
        assert_equal(left, 0)
        assert_equal(threads.block(0).get(_BLK_KIND), JOB_NONE)


def _stop_within(mut pool: OffloadPool, thread: Int) raises -> Bool:
    """Whether `try_next_job` answers the pill within 100 ms of polling."""
    var buf = _job_buffer()
    var deadline = perf_counter_ns() + 100_000_000
    while perf_counter_ns() < deadline:
        if pool.try_next_job(0, buf, thread).kind == JOB_STOP:
            return True
        sleep(0.00005)
    return False


def test_try_next_job_answers_the_pill() raises:
    """A thread taking jobs inside its slice still leaves on its pill: on
    its own channel for a registered thread, on the lane socket for the
    rest, each read on the socket poll's cadence (`POOL_DGRAM_POLL_NS`)."""
    var pool = OffloadPool(8)
    if not pool.ring_active():
        return
    pool.reserve_threads(1)
    var tid = pool.register_thread(0)
    pool.stop(1)
    assert_true(_stop_within(pool, tid))
    pool.unregister_thread(tid, 0)

    var bare = OffloadPool(8)
    bare.stop(1)
    assert_true(_stop_within(bare, -1))


comptime _PARK_ROUNDS = 200

comptime _SLOW_SLOT = 7
"""With `slow`, a job on this slot holds its echo thread for
`_SLOW_HOLD_S`: the slow view of the two-thread test below."""

comptime _SLOW_HOLD_S = 0.2


comptime _BLK_SERVED = 11
"""Block slot an echo thread counts its jobs in; read after the join."""

comptime _BLK_WS_SERVED = 12
"""Block slot an echo thread counts the WebSocket messages it took in;
read after the join."""


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
    var ws_served = 0
    while True:
        var job = pool.next_job(0, buf, tid)
        if job.kind == JOB_STOP:
            break
        if job.kind == JOB_WS_MESSAGE:
            ws_served += 1
            continue
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
    block.set(_BLK_WS_SERVED, ws_served)
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


def test_a_websocket_message_wakes_a_thread_parked_on_its_own_channel() raises:
    """A payload datagram rides the lane socket, which a thread parked on
    its own channel is not watching: `send_ws_message`, the loop handler's
    one way to deliver a message to a pool, wakes the most recently parked
    thread, which polls the socket first thing. The echo thread counts the
    message as served (it answers nothing for it) and parks again; without
    the wake it would sit parked and the message with it — CI's WebSocket
    smoke, "only pings arriving"."""
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    var threads = ThreadSet(1)
    _spawn_echo[False](pool, threads, 1)
    var payload = List[UInt8]()
    for b in String("hello").as_bytes():
        payload.append(b)
    assert_true(pool.send_ws_message(0, 3, 1, String("chan"), Span(payload)))
    # The thread wakes for it: parked count drops, then it parks again.
    var deadline = perf_counter_ns() + 2_000_000_000
    var woke = False
    while perf_counter_ns() < deadline:
        if pool.parked_count(0) == 0:
            woke = True
            break
        sleep(0.0001)
    assert_true(woke)
    _await_parked(pool, 1)
    pool.stop(1)
    threads.join_all()
    assert_true(threads.all_ok())
    assert_equal(threads.block(0).get(_BLK_SERVED), 0)
    assert_equal(threads.block(0).get(_BLK_WS_SERVED), 1)


def test_a_websocket_message_sent_while_the_thread_is_on_its_way_to_park_is_taken() raises:
    """The parking-in-progress case of the test above: the message lands
    while the lane's one thread is not parked, so `send_ws_message`
    wakes nobody, and the thread's next park must find it on the lane
    socket by itself. Here the thread is inside a 200 ms view when the
    message is sent, and the lane's poll clock is moved past the end of
    the test, standing in for a thread that polled the socket a moment
    before it parked: the poll on that cadence never comes round, so the
    only look at the socket is the one `_park_on_own` takes after
    announcing the park. Without it the thread blocks on its own channel
    with the message left on the socket until something else wakes the
    lane -- the pill, here (review LF22, where the window was held open
    by a sleep before the announcement: 24 messages of 24 stranded).

    covers: I39
    """
    var pool = OffloadPool(8)
    if not pool.elastic_active():
        return
    var threads = ThreadSet(1)
    _spawn_echo[True](pool, threads, 1)
    pool.park_request(_SLOW_SLOT, _request("/slow"))
    assert_true(pool.submit(_SLOW_SLOT))
    # Taken: the ring is empty and nobody is parked, so the thread is
    # inside the view, its last poll of the socket already made.
    var deadline = perf_counter_ns() + 2_000_000_000
    while pool.jobs_pending() or pool.parked_count(0) != 0:
        assert_true(perf_counter_ns() < deadline, "the slow job was never taken")
        sleep(0.0001)
    atomic_at(pool._poll_addr(0))[].store(
        Int64(perf_counter_ns() + 60_000_000_000)
    )
    var payload = List[UInt8]()
    for b in String("hello").as_bytes():
        payload.append(b)
    assert_true(pool.send_ws_message(0, 3, 1, String("chan"), Span(payload)))
    assert_equal(pool.parked_count(0), 0)
    assert_true(_await_completion(pool, _SLOW_SLOT, 2_000_000_000) >= 0)
    _await_parked(pool, 1)
    pool.stop(1)
    threads.join_all()
    assert_true(threads.all_ok())
    assert_equal(threads.block(0).get(_BLK_SERVED), 1)
    assert_equal(
        threads.block(0).get(_BLK_WS_SERVED), 1,
        "the message was left on the lane socket when the thread parked",
    )


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


comptime _BLK_TOOK = 13
"""Block slot `_unregistered_thread` sets once it holds its slow job."""


def _unregistered_thread(arg: Int) -> Int:
    """A pool thread that never registers -- a test's, or every thread
    under the eager rules (`M0_POOL_ELASTIC=0`) and without rings -- so it
    parks on its lane's socket and its pill has to come through that
    socket. Serves the lane in `BLK_LANE` until the pill; `_SLOW_SLOT`
    holds it for `_SLOW_HOLD_S`, and anything that is not a request (an
    inbound WebSocket message) is taken and skipped."""
    var block = ThreadBlock(arg)
    ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )[]
    var lane = block.get(BLK_LANE)
    var buf = _job_buffer()
    while True:
        var job = pool.next_job(lane, buf)
        if job.kind == JOB_STOP:
            break
        if job.kind != JOB_REQUEST:
            continue
        _ = pool.take_request(job.slot)
        if job.slot == _SLOW_SLOT:
            block.set(_BLK_TOOK, 1)
            sleep(_SLOW_HOLD_S)
        pool.put_response(job.slot, OK(String("x")))
        pool.complete(job.slot)
    block.set(BLK_STATUS, STATUS_OK)
    return 0


def test_stop_pills_an_unregistered_thread_through_a_full_lane() raises:
    """`stop` waits for room to pill a thread that never registered.

    Such a thread parks on its lane's socket, so its pill rides that
    socket, and the socket also carries inbound WebSocket messages. Here
    the one thread of lane 1 is inside a 200 ms view while messages fill
    the lane until it refuses one, and then the pool is stopped. `stop`
    used to offer that pill with ONE non-blocking send and ignore a
    refusal: the thread came back, took the messages, and parked on an
    empty socket for good -- `pthread_join` never returned, and a
    bounded join (`JOIN_TIMEOUT_NS`) abandoned it. On the ring and on the
    datagram hand-off (`M0_POOL_RING=0`). Lane 1, because stopping lane
    0 closes its write end, and the rescue below must be able to pill the
    thread again: a lost pill fails this test inside a few seconds rather
    than hanging it.
    """
    for ring_off in range(2):
        var pool = _pool(ring_off == 1)
        pool.add_lane(String(""))
        pool.add_lane(String("/x"))
        var threads = ThreadSet(1)
        var body = _unregistered_thread
        var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
        threads.block(0).set(BLK_USER, pool.addr())
        threads.block(0).set(BLK_LANE, 1)
        threads.spawn(0, body_addr)
        pool.park_request(_SLOW_SLOT, _request("/x/slow"))
        assert_true(pool.submit(_SLOW_SLOT, String("/x/slow")))
        var deadline = perf_counter_ns() + 2_000_000_000
        while (
            threads.block(0).get(_BLK_TOOK) == 0
            and perf_counter_ns() < deadline
        ):
            sleep(0.0005)
        var took = threads.block(0).get(_BLK_TOOK) == 1
        # The thread is inside its view: nothing reads the lane until it
        # comes back, so messages fill it -- large ones, then smaller, down
        # to an empty one, which is a datagram longer than a pill: a lane
        # full for the last of them has no room for the pill either.
        var sent = 0
        var refused = False
        for size in [60000, 4096, 256, 0]:
            var payload = List[UInt8](capacity=size)
            for _ in range(size):
                payload.append(0x61)
            refused = False
            while took and sent < 100_000:
                if not pool.send_ws_message(
                    1, 0, 1, String("c"), Span(payload)
                ):
                    refused = True
                    break
                sent += 1
        pool.stop(1, 1)
        var left = threads.join_within(3_000_000_000)
        if left != 0:
            # The pill was lost: the thread has taken the messages and is
            # parked on an empty socket. Pill it again so the suite ends.
            pool.stop(1, 1)
            threads.join_all()
        assert_true(took, "the thread never took its slow job")
        assert_true(refused, "the lane never filled")
        assert_true(sent > 0)
        assert_equal(
            left, 0, "a thread that never registered missed its pill"
        )
        var done = pool.drain_completions()
        assert_equal(len(done), 1)
        _ = pool.take_response(_SLOW_SLOT)


def _ensure_descriptors(want: Int):
    """Raise the soft descriptor limit to `want` when it is lower.

    A macOS shell starts at 256, and the test below holds about 250 of its
    own: every lane past the first is a socketpair. Best effort -- under a
    hard limit below `want` the test's own failure names the socketpair
    that could not be made.
    """
    comptime RLIMIT_NOFILE = 8 if CompilationTarget.is_macos() else 7
    var lim = Array[UInt64, 2](fill=UInt64(0))
    comptime LimPtr = type_of(Pointer(to=lim[0]))
    if external_call["getrlimit", c_int, c_int, LimPtr](
        c_int(RLIMIT_NOFILE), Pointer(to=lim[0])
    ) != 0:
        return
    if lim[0] >= UInt64(want):
        return
    lim[0] = UInt64(want) if lim[1] >= UInt64(want) else lim[1]
    _ = external_call["setrlimit", c_int, c_int, LimPtr](
        c_int(RLIMIT_NOFILE), Pointer(to=lim[0])
    )


def test_a_lane_past_the_wake_block_is_refused() raises:
    """`add_lane` refuses the lane past `_WAKE_MAX_LANES` and takes the last
    one that fits. A lane's wake words are one cache line of an 8192-byte
    block, room for 126 lanes, and `note_thread` writes a lane's line
    whatever its index, so a 127th lane -- 127 mounts under the
    zero-config pool -- wrote past the end of the block (B14). The last
    lane that fits is used as well as made: its thread count round-trips
    through the block's last line.
    """
    assert_equal(_WAKE_MAX_LANES, 126)
    _ensure_descriptors(1024)
    var pool = OffloadPool(4)
    for lane in range(_WAKE_MAX_LANES):
        pool.add_lane(String("/m") + String(lane))
    var refused = False
    try:
        pool.add_lane(String("/one-too-many"))
    except e:
        refused = True
        assert_true(
            String(e).find(String(_WAKE_MAX_LANES)) >= 0,
            "the refusal does not name the cap: " + String(e),
        )
    assert_true(refused, "a lane past the wake block was accepted")
    var last = _WAKE_MAX_LANES - 1
    assert_equal(pool.lane_for(String("/m") + String(last)), last)
    if pool.ring_enabled:
        pool.note_thread(last, 1)
        assert_equal(pool.thread_count(last), 1)
        pool.note_thread(last, -1)
        assert_equal(pool.thread_count(last), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
