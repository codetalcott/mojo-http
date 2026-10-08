"""`recv` and `send` move the bytes of the span they are given and no others
(review record LF20).

Both took the span and, beside it, a length the span did not have to back:
the loop's body and WebSocket reads passed an empty span and a capacity
count, and a count above the span's length was written past its end -- a
10-byte span given with a count of 64 received 64 bytes, 54 of them past
the span. The length is now the span's own, and a read into a list's
spare capacity asks `spare_capacity` for the span. Each test reads what
the call touched back out of the buffer around it.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_true

from lightbug_http.c.pipe import close_fd
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import recv, send, spare_capacity

comptime _UNTOUCHED: UInt8 = 0xAA
comptime _SENT: UInt8 = 0x41


def _stream_pair() raises -> Tuple[Int, Int]:
    """An `AF_UNIX` `SOCK_STREAM` pair, both ends blocking."""
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
    return pair


def test_recv_writes_only_inside_the_span_it_is_given() raises:
    """With 64 bytes waiting, a `recv` into the first 10 bytes of a 64-byte
    buffer takes 10 and leaves the other 54 as they were.

    covers: G21
    """
    var pair = _stream_pair()
    var out = List[UInt8](length=64, fill=_SENT)
    assert_equal(Int(send(FileDescriptor(pair[1]), Span(out), 0)), 64)

    var buf = List[UInt8](length=64, fill=_UNTOUCHED)
    var n = recv(FileDescriptor(pair[0]), Span(buf)[:10], 0)
    assert_equal(Int(n), 10, "recv took more than its span holds")
    for i in range(10):
        assert_equal(buf[i], _SENT, "recv left its span unfilled")
    var past = 0
    for i in range(10, 64):
        if buf[i] != _UNTOUCHED:
            past += 1
    assert_equal(past, 0, String("recv wrote ", past, " bytes past its span"))
    close_fd(pair[0])
    close_fd(pair[1])


def test_send_sends_only_the_span_it_is_given() raises:
    """A `send` of the first 5 bytes of a 64-byte buffer puts 5 bytes on the
    wire, and the peer reads those 5 and no more."""
    var pair = _stream_pair()
    var out = List[UInt8](length=64, fill=_SENT)
    assert_equal(Int(send(FileDescriptor(pair[1]), Span(out)[:5], 0)), 5)

    var buf = List[UInt8](length=64, fill=_UNTOUCHED)
    var n = recv(FileDescriptor(pair[0]), Span(buf), MSG_DONTWAIT)
    assert_equal(Int(n), 5, "send put more on the wire than its span holds")
    var more = 0
    try:
        more = Int(recv(FileDescriptor(pair[0]), Span(buf), MSG_DONTWAIT))
    except e:
        assert_true(e.would_block(), String(e))
    assert_equal(more, 0, "bytes past the span reached the peer")
    close_fd(pair[0])
    close_fd(pair[1])


def test_spare_capacity_is_the_room_past_the_length() raises:
    """`spare_capacity` lends the bytes past a list's length and within its
    capacity: a `recv` into it fills that room and leaves the list's own
    bytes as they were."""
    var pair = _stream_pair()
    var buf = List[UInt8](capacity=32)
    buf.append(1)
    buf.append(2)
    buf.append(3)
    var room = buf.capacity() - 3
    var out = List[UInt8](length=room + 16, fill=_SENT)
    assert_equal(Int(send(FileDescriptor(pair[1]), Span(out), 0)), room + 16)

    var n = recv(FileDescriptor(pair[0]), spare_capacity(buf), 0)
    assert_equal(Int(n), room, "recv into the spare capacity took more than the room")
    assert_equal(buf[0], 1, "the list's own bytes were overwritten")
    assert_equal(buf[1], 2, "the list's own bytes were overwritten")
    assert_equal(buf[2], 3, "the list's own bytes were overwritten")
    var p = buf.unsafe_ptr()
    for i in range(3, 3 + room):
        assert_equal(p[unsafe_offset=i], _SENT, "the room was not filled from its start")
    _ = buf
    close_fd(pair[0])
    close_fd(pair[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
