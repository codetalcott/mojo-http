"""The pool thread's half of a streamed WSGI body, without an interpreter.

Same charter as `test_hold`: the pieces that operate on plain values — the
`P` begin-frame name that carries a thread's ack fd, the parser that reads
it back, and the disconnect ack the loop sends down that fd — are exercised
here. What is NOT reachable without a `WSGIApp` is the handler's frame
dispatch and the pump itself; `smoke-wsgi-stream` covers those end to end.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.offload import make_stream_ack_pair, drain_ack_fd

from src.handler import (
    pool_stream_url,
    pool_stream_ack_fd,
    asgi_stream_url,
    _send_pool_disconnect,
    _read_ack,
    _poll_acks,
    _i32,
)
from std.ffi import c_int
from std.sys.info import CompilationTarget

comptime _MSG_DONTWAIT = c_int(0x80) if CompilationTarget.is_macos() else c_int(0x40)


def test_pool_stream_url_carries_slot_lane_and_ack_fd() raises:
    """`\\x01P/<slot>/<lane>/<ack_fd>`, the lane written literally — the
    unmounted pool's lane is -1, and the fd must sit at a fixed position."""
    var url = pool_stream_url(7, -1, 23)
    var b = url.as_bytes()
    assert_equal(Int(b[0]), 1)
    assert_equal(Int(b[1]), ord("P"))
    assert_equal(String(url[byte=2:]), "/7/-1/23")
    assert_equal(pool_stream_ack_fd(url), 23)
    assert_equal(pool_stream_ack_fd(pool_stream_url(1024, 3, 9)), 9)


def test_only_a_p_name_answers_an_ack_fd() raises:
    assert_equal(pool_stream_ack_fd(asgi_stream_url(String("b"), 7, 2)), -1)
    assert_equal(pool_stream_ack_fd(asgi_stream_url(String("h"), 7)), -1)
    assert_equal(pool_stream_ack_fd(String("/news")), -1)
    assert_equal(pool_stream_ack_fd(String("")), -1)


def test_i32_sign_extends_the_wire_value() raises:
    """`Int(Int32(UInt32(0xFFFFFFFF)))` is 4294967295 on this toolchain, not
    -1; the disconnect ack depends on getting -1 back."""
    assert_equal(_i32(UInt32(0xFFFFFFFF)), -1)
    assert_equal(_i32(UInt32(16384)), 16384)
    assert_equal(_i32(UInt32(0)), 0)
    assert_equal(_i32(UInt32(0x80000000)), -2147483648)


def test_disconnect_ack_round_trips_as_minus_one_for_the_slot() raises:
    """What `sse_slot_disconnected` sends down a pool thread's pair is what
    the thread's own reader decodes: `(slot, -1)`, and nothing else."""
    var pair = make_stream_ack_pair()
    _send_pool_disconnect(pair[1], 42)
    var slot = -1
    var credit = 0
    var rc = _read_ack(pair[0], _MSG_DONTWAIT, slot, credit)
    assert_equal(rc, 1)
    assert_equal(slot, 42)
    assert_equal(credit, -1)
    # Nothing more queued: the non-blocking read says so rather than parking.
    assert_equal(_read_ack(pair[0], _MSG_DONTWAIT, slot, credit), 0)


def test_poll_acks_accumulates_credit_and_stops_at_a_disconnect() raises:
    var pair = make_stream_ack_pair()
    # Two credits for slot 5, one stale credit for another slot, then the
    # disconnect for slot 5 — the poll must add the first two, skip the
    # stranger, and answer -1 at the disconnect.
    for pieces in [(5, 100), (5, 200), (9, 999)]:
        var s = UInt32(pieces[0])
        var c = UInt32(pieces[1])
        var msg = List[UInt8]()
        for i in range(4):
            msg.append(UInt8((s >> UInt32(8 * i)) & 0xFF))
        for i in range(4):
            msg.append(UInt8((c >> UInt32(8 * i)) & 0xFF))
        _ = _send_bytes(pair[1], msg)
    var total = _poll_acks(pair[0], 5, 16384)
    assert_equal(total, 16384 + 300)
    _send_pool_disconnect(pair[1], 5)
    assert_equal(_poll_acks(pair[0], 5, total), -1)
    # After a drain, a fresh poll sees nothing and keeps its credit.
    drain_ack_fd(pair[0])
    assert_equal(_poll_acks(pair[0], 5, 7), 7)


def _send_bytes(fd: Int, msg: List[UInt8]) -> Bool:
    from std.ffi import external_call
    var rc = external_call["send", Int](
        c_int(fd), msg.unsafe_ptr(), UInt(len(msg)), c_int(0)
    )
    return rc == len(msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
