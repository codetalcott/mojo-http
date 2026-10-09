"""The keep-alive reset must preserve a pipelined tail — and ONLY then.

RFC 9112 §9.3: a server must be able to receive pipelined requests. The
socket-level behaviour is pinned by `scripts/pipeline_probe.py`
(`poe smoke-pipelining`); what these tests pin is the provision-level
contract underneath it. Bytes past `request_end` survive exactly one
path — a keep-alive reset passing `keep_pipelined=True` — and every other
reset clears the buffer whole, because a tail preserved on accept or
close would be one client's bytes leaking into another connection's
first request. The tail survives where it is, `head_start` moved to it,
and the read path moves it to the front once (`compact_buffer`), so an
answer copies nothing (review record LF72).
"""

from std.bit import count_leading_zeros, pop_count
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.connection import ConnectionState
from lightbug_http.server import BodyReadState, ConnectionProvision, ProvisionPool
from lightbug_http.server_config import ServerConfig


def _provision_with(buf: String, request_end: Int) raises -> ConnectionProvision:
    var p = ConnectionProvision(ServerConfig())
    p.recv_buffer.extend(buf.as_bytes())
    p.request_end = request_end
    return p^


def _assert_buffer(p: ConnectionProvision, expected: String) raises:
    """The bytes pending from `head_start` are `expected`."""
    assert_equal(p.pending_len(), expected.byte_length())
    var want = expected.as_bytes()
    for i in range(len(want)):
        assert_equal(p.recv_buffer[p.head_start + i], want[i])


def test_keep_pipelined_preserves_tail() raises:
    """The tail stays where it is: the same buffer, the same bytes, nothing
    copied, `head_start` past the request answered. The reset copied it to
    a new buffer, after every answer, and a pipelined burst cost the loop
    time quadratic in its length (review record LF72).

    covers: A41
    """
    var p = _provision_with("REQ1TAIL", 4)
    var before = Int(p.recv_buffer.unsafe_ptr())
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "TAIL")
    assert_equal(Int(p.recv_buffer.unsafe_ptr()), before, "the tail was copied")
    assert_equal(len(p.recv_buffer), 8, "the tail was moved")
    assert_equal(p.head_start, 4)
    # The stamp is spent: the tail is a NEW request whose end is unknown.
    assert_equal(p.request_end, 0)
    # And the tail has never been scanned for a terminator.
    assert_equal(p.last_parse_len, 0)


def test_compaction_moves_the_pending_bytes_to_the_front() raises:
    """`compact_buffer` drops the answered requests' bytes and moves what is
    pending to the front, in place; with nothing answered it does
    nothing."""
    var p = _provision_with("REQ1REQ2TA", 4)
    p.prepare_for_new_request(keep_pipelined=True)
    p.request_end = 8
    p.prepare_for_new_request(keep_pipelined=True)
    assert_equal(p.head_start, 8)
    var before = Int(p.recv_buffer.unsafe_ptr())
    p.compact_buffer()
    assert_equal(p.head_start, 0)
    _assert_buffer(p, "TA")
    assert_equal(len(p.recv_buffer), 2)
    assert_equal(Int(p.recv_buffer.unsafe_ptr()), before)
    p.compact_buffer()
    _assert_buffer(p, "TA")


def test_a_keepalive_reset_keeps_the_half_close() raises:
    """`peer_eof` is the connection's: the keep-alive reset keeps it, so the
    requests a half-closed client left in the buffer are answered knowing
    nothing follows them. Every other reset clears it."""
    var p = _provision_with("REQ1TAIL", 4)
    p.peer_eof = True
    p.prepare_for_new_request(keep_pipelined=True)
    assert_true(p.peer_eof)
    p.prepare_for_new_request()
    assert_false(p.peer_eof)


def test_keep_pipelined_without_request_end_clears() raises:
    """0 means "end unknown" — nothing can be safely preserved."""
    var p = _provision_with("REQ1TAIL", 0)
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "")


def test_keep_pipelined_with_no_tail_clears() raises:
    var p = _provision_with("REQ1", 4)
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "")


def test_default_reset_clears_despite_tail() raises:
    """The accept/close contract: without the explicit opt-in the buffer
    clears whole, request_end notwithstanding — a preserved tail there
    would cross connections."""
    var p = _provision_with("REQ1TAIL", 4)
    p.prepare_for_new_request()
    _assert_buffer(p, "")
    assert_equal(p.request_end, 0)


def test_preserved_tail_then_default_reset_clears() raises:
    var p = _provision_with("REQ1TAIL", 4)
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "TAIL")
    p.prepare_for_new_request()
    _assert_buffer(p, "")
    assert_equal(len(p.recv_buffer), 0)
    assert_equal(p.head_start, 0)


def test_a_reset_clears_what_the_last_request_left() raises:
    """Every per-request field goes back to a new connection's value, the
    chunked decoder included, built again to consume a trailer."""
    var p = _provision_with("REQ1", 4)
    p.state = ConnectionState.processing()
    p.body_state = BodyReadState(5, 2, 4, True)
    p.peer_eof = True
    p.chunk_decoder.consume_trailer = False
    p.chunk_decoder.pending_bytes = 3
    p.last_parse_len = 9
    p.should_close = True
    p.log_method = "GET"
    p.log_path = "/x"
    p.response_status = 200
    p.response_body_len = 7
    p.response_file_len = 2
    p.prepare_for_new_request()
    assert_true(p.state.kind == ConnectionState.READING_HEADERS)
    assert_false(Bool(p.body_state))
    assert_false(Bool(p.parsed_headers))
    assert_false(p.peer_eof)
    assert_true(p.chunk_decoder.consume_trailer)
    assert_equal(p.chunk_decoder.pending_bytes, 0)
    assert_equal(p.last_parse_len, 0)
    assert_false(p.should_close)
    assert_equal(p.log_method, "")
    assert_equal(p.log_path, "")
    assert_equal(p.response_status, 0)
    assert_equal(p.response_body_len, 0)
    assert_equal(p.response_file_len, 0)


def _borrow(mut pool: ProvisionPool) raises -> Int:
    try:
        return pool.borrow()
    except:
        raise Error("exhausted")


def test_the_provision_pool_hands_out_every_slot_once() raises:
    """The pool's bitmask allocator, at capacities either side of its 64-bit
    words: every slot once, lowest first, then a refusal; a released slot
    comes back first; `available_count` follows. And the two `std.bit`
    calls it allocates and counts with, at every bit (review audit A3)."""
    assert_equal(Int(count_leading_zeros(UInt64(0))), 64)
    assert_equal(Int(pop_count(UInt64(0))), 0)
    assert_equal(Int(pop_count(~UInt64(0))), 64)
    for s in range(64):
        var bit = UInt64(1) << UInt64(s)
        assert_equal(Int(count_leading_zeros(bit)), 63 - s)
        assert_equal(Int(count_leading_zeros(bit | 1)), 63 - s)
        assert_equal(Int(pop_count(bit)), 1)
        assert_equal(Int(pop_count((bit - 1) | bit)), s + 1)

    var config = ServerConfig()
    config.socket_buffer_size = 16
    for capacity in [1, 63, 64, 65, 130]:
        var pool = ProvisionPool(capacity, config)
        assert_equal(pool.available_count(), capacity)
        for i in range(capacity):
            assert_equal(_borrow(pool), i, String("capacity ", capacity))
        assert_equal(pool.available_count(), 0)
        var refused = False
        try:
            _ = pool.borrow()
        except:
            refused = True
        assert_true(refused, String("an exhausted pool of ", capacity, " lent a slot"))
        # Released out of order, they come back lowest first.
        var back = List[Int]()
        for k in [capacity - 1, 0, 64, 63]:
            if k < capacity and k not in back:
                back.append(k)
        for k in back:
            pool.release(k)
        assert_equal(pool.available_count(), len(back))
        var last = -1
        for _ in range(len(back)):
            var got = _borrow(pool)
            assert_true(got in back and got > last, String("capacity ", capacity, ": lent ", got))
            last = got
        assert_equal(pool.available_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
