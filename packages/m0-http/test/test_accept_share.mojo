"""Tests for passing accepted connections between workers (SPEC E16).

covers: E16

Everything here runs in one process: a passed descriptor is a kernel
mechanism that behaves the same across a socketpair whether the two ends
are in one process or two, and the shared page is plain memory until a
fork. The fork half — two real workers splitting a burst — is
`poe smoke-accept-spread` against the real server on both platforms.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.time import perf_counter_ns

from lightbug_http.accept_share import (
    AcceptShare, accept_share_slots, ACCEPT_SHARE_FIRST_WORKER_SLOT,
    ACCEPT_SHARE_WORKER_STRIDE, ACCEPT_SHARE_BUSY_NS, STATE_LEFT,
)
from lightbug_http.c.fdpass import send_fd, recv_fd, FDPASS_MAX_PAYLOAD
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.socket import send, recv, close, setsockopt, SocketOption, SOL_SOCKET
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.c.platform import MSG_DONTWAIT

from src.multiworker import SharedAtomics


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _word_slot(worker: Int, which: Int) -> Int:
    return ACCEPT_SHARE_FIRST_WORKER_SLOT + ACCEPT_SHARE_WORKER_STRIDE * worker + which


def _nonblocking_pair() raises -> Tuple[Int, Int]:
    var pair = socketpair_dgram()
    set_nonblocking(FileDescriptor(pair[0]))
    set_nonblocking(FileDescriptor(pair[1]))
    return pair


def test_a_descriptor_crosses_a_socketpair_with_its_payload() raises:
    var channel = _nonblocking_pair()
    var conn = _nonblocking_pair()  # stands in for an accepted connection
    assert_true(send_fd(channel[1], conn[0], _bytes("hello")))
    var payload = List[UInt8]()
    var got = recv_fd(channel[0], payload)
    assert_true(got >= 0, "recv_fd returned no descriptor")
    assert_true(got != conn[0], "the receiver must get its own fd number")
    assert_equal(String(from_utf8_lossy=Span(payload)), "hello")
    # The passed fd is the same open file: bytes written into the far end
    # of the original pair arrive on it, even after the sender's own
    # reference is closed.
    close(FileDescriptor(conn[0]))
    var msg = _bytes("ping")
    _ = send(FileDescriptor(conn[1]), Span(msg), UInt(len(msg)), 0)
    var buf = List[UInt8](capacity=16)
    for _ in range(16):
        buf.append(0)
    var n = recv(FileDescriptor(got), Span(buf), UInt(16), MSG_DONTWAIT)
    assert_equal(Int(n), 4)
    assert_equal(String(from_utf8_lossy=Span(buf)[:4]), "ping")
    # An empty channel answers -1, not a stale descriptor.
    assert_equal(recv_fd(channel[0], payload), -1)
    close(FileDescriptor(got))
    close(FileDescriptor(conn[1]))
    close(FileDescriptor(channel[0]))
    close(FileDescriptor(channel[1]))


def test_a_payload_is_capped_and_an_empty_one_still_carries_the_fd() raises:
    var channel = _nonblocking_pair()
    var conn = _nonblocking_pair()
    var big = List[UInt8]()
    for i in range(FDPASS_MAX_PAYLOAD * 3):
        big.append(UInt8(i & 0xFF))
    assert_true(send_fd(channel[1], conn[0], big))
    var payload = List[UInt8]()
    var got = recv_fd(channel[0], payload)
    assert_true(got >= 0)
    assert_equal(len(payload), FDPASS_MAX_PAYLOAD)
    close(FileDescriptor(got))
    assert_true(send_fd(channel[1], conn[0], List[UInt8]()))
    got = recv_fd(channel[0], payload)
    assert_true(got >= 0, "an fd with no payload must still arrive")
    close(FileDescriptor(got))
    close(FileDescriptor(conn[0]))
    close(FileDescriptor(conn[1]))
    close(FileDescriptor(channel[0]))
    close(FileDescriptor(channel[1]))


def test_a_datagram_without_a_descriptor_is_not_a_connection() raises:
    var channel = _nonblocking_pair()
    var msg = _bytes("no fd here")
    _ = send(FileDescriptor(channel[1]), Span(msg), UInt(len(msg)), 0)
    var payload = List[UInt8]()
    assert_equal(recv_fd(channel[0], payload), -1)
    close(FileDescriptor(channel[0]))
    close(FileDescriptor(channel[1]))


def test_an_unbound_share_is_inactive_and_costs_nothing() raises:
    var share = AcceptShare()
    assert_false(share.active())
    assert_equal(share.read_fd(), -1)
    assert_equal(share.pick(0, perf_counter_ns()), -1)
    var host = String("x")
    var port = 1
    assert_equal(share.receive(host, port), -1)
    # Two channels but bound as a single worker: still inactive.
    var one = AcceptShare(1)
    var page = SharedAtomics(accept_share_slots(1))
    one.bind(0, page.addr(0))
    assert_false(one.active())


def test_a_connection_passes_between_two_workers_with_its_peer() raises:
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    assert_true(w0.active())
    assert_true(w1.active())
    assert_equal(w1.read_fd(), share.read_fds[1])
    var conn = _nonblocking_pair()
    assert_true(w0.send(1, conn[0], "10.1.2.3", 4321))
    assert_equal(w0.handoffs_out, 1)
    assert_equal(page.load(_word_slot(1, 2)), 1, "pending[1] after the send")
    close(FileDescriptor(conn[0]))
    var host = String("")
    var port = 0
    var fd = w1.receive(host, port)
    assert_true(fd >= 0)
    assert_equal(host, "10.1.2.3")
    assert_equal(port, 4321)
    assert_equal(w1.handoffs_in, 1)
    # Retired from `pending` at the end of the pass that admitted it, and
    # the connection count published beside it.
    w1.pass_end(7)
    assert_equal(page.load(_word_slot(1, 2)), 0)
    assert_equal(page.load(_word_slot(1, 1)), 7)
    assert_equal(w1.receive(host, port), -1)
    close(FileDescriptor(fd))
    close(FileDescriptor(conn[1]))


def test_pick_names_the_least_loaded_sibling_or_itself() raises:
    var page = SharedAtomics(accept_share_slots(3))
    var me = AcceptShare(3)
    me.bind(0, page.addr(0))
    var now = perf_counter_ns()
    # Siblings idle and empty, this worker holding two: a sibling.
    var target = me.pick(2, now)
    assert_true(target == 1 or target == 2, "expected a sibling")
    # Both siblings busier than this worker: keep it.
    page.store(_word_slot(1, 1), 5)
    page.store(_word_slot(2, 1), 5)
    assert_equal(me.pick(2, now), 0)
    # Connections in flight to a sibling count as its load.
    page.store(_word_slot(1, 1), 0)
    page.store(_word_slot(1, 2), 3)
    assert_equal(me.pick(2, now), 0)
    page.store(_word_slot(1, 2), 0)
    assert_equal(me.pick(2, now), 1)
    # A sibling inside a pass for longer than the budget is skipped...
    page.store(_word_slot(1, 0), now - ACCEPT_SHARE_BUSY_NS - 1)
    assert_equal(me.pick(2, now), 0)
    # ...one that just began a pass is not.
    page.store(_word_slot(1, 0), now - 1000)
    assert_equal(me.pick(2, now), 1)
    # A sibling that left is never chosen.
    page.store(_word_slot(1, 0), STATE_LEFT)
    assert_equal(me.pick(2, now), 0)
    # Equal loads: this worker keeps the connection (ties favour the
    # acceptor, so a hand-off always buys a strictly lighter worker).
    page.store(_word_slot(1, 0), 0)
    page.store(_word_slot(1, 1), 2)
    page.store(_word_slot(2, 1), 2)
    assert_equal(me.pick(2, now), 0)


def test_a_burst_spreads_across_siblings_through_pending() raises:
    """Thirty-two accepts in one pass, the siblings' published counts
    stale at zero throughout: `pending` is what keeps the acceptor from
    handing every one to the same sibling."""
    var page = SharedAtomics(accept_share_slots(3))
    var share = AcceptShare(3)
    var me = share.copy()
    me.bind(0, page.addr(0))
    var now = perf_counter_ns()
    var kept = 0
    var to = List[Int]()
    to.append(0)
    to.append(0)
    to.append(0)
    var own = 0
    var fds = List[Int]()
    for _ in range(32):
        var conn = _nonblocking_pair()
        var target = me.pick(own, now)
        if target == 0:
            kept += 1
            own += 1
            fds.append(conn[0])
        else:
            assert_true(me.send(target, conn[0], "127.0.0.1", 1))
            close(FileDescriptor(conn[0]))
        to[target] += 1
        fds.append(conn[1])
    assert_equal(to[0], kept)
    for i in range(3):
        assert_true(to[i] >= 10 and to[i] <= 12, "worker " + String(i) + " took " + String(to[i]))
    # Each sibling drains what it was sent and retires it.
    for i in range(1, 3):
        var w = share.copy()
        w.bind(i, page.addr(0))
        var host = String("")
        var port = 0
        var n = 0
        while True:
            var fd = w.receive(host, port)
            if fd < 0:
                break
            close(FileDescriptor(fd))
            n += 1
        assert_equal(n, to[i])
        w.pass_end(n)
        assert_equal(page.load(_word_slot(i, 2)), 0)
        assert_equal(page.load(_word_slot(i, 1)), n)
    for fd in fds:
        close(FileDescriptor(fd))


def test_leaving_wins_over_the_pass_bookkeeping() raises:
    var page = SharedAtomics(accept_share_slots(2))
    var w1 = AcceptShare(2)
    w1.bind(1, page.addr(0))
    var now = perf_counter_ns()
    w1.pass_begin(now)
    assert_equal(page.load(_word_slot(1, 0)), now)
    w1.pass_end(3)
    assert_equal(page.load(_word_slot(1, 0)), 0)
    w1.leave()
    assert_equal(page.load(_word_slot(1, 0)), STATE_LEFT)
    # The shutdown drain still runs passes; they must not un-announce it.
    w1.pass_begin(now)
    w1.pass_end(1)
    assert_equal(page.load(_word_slot(1, 0)), STATE_LEFT)
    var w0 = w1.copy()
    w0.left = False
    w0.bind(0, page.addr(0))
    assert_equal(w0.pick(5, now), 0)


def test_start_resets_the_state_and_count_but_not_pending() raises:
    var page = SharedAtomics(accept_share_slots(2))
    page.store(_word_slot(1, 0), STATE_LEFT)
    page.store(_word_slot(1, 1), 40)
    page.store(_word_slot(1, 2), 2)  # in flight from before a respawn
    var w1 = AcceptShare(2)
    w1.bind(1, page.addr(0))
    w1.start()
    assert_equal(page.load(_word_slot(1, 0)), 0)
    assert_equal(page.load(_word_slot(1, 1)), 0)
    assert_equal(page.load(_word_slot(1, 2)), 2)


def test_a_full_channel_refuses_the_send_and_the_acceptor_keeps_it() raises:
    var page = SharedAtomics(accept_share_slots(2))
    var w0 = AcceptShare(2)
    w0.bind(0, page.addr(0))
    # Shrink the sibling's receive buffer so it fills within a few
    # datagrams (the kernel clamps to its minimum; a handful still fit).
    setsockopt(
        FileDescriptor(w0.read_fds[1]), Int32(SOL_SOCKET),
        SocketOption.SO_RCVBUF.value, Int32(1024),
    )
    var conn = _nonblocking_pair()
    var sent = 0
    var refused = False
    for _ in range(100000):
        if w0.send(1, conn[0], "127.0.0.1", 1):
            sent += 1
        else:
            refused = True
            break
    assert_true(refused, "a channel that never fills is unbounded kernel memory")
    assert_true(sent > 0)
    assert_equal(page.load(_word_slot(1, 2)), sent, "pending counts only what was queued")
    close(FileDescriptor(conn[0]))
    close(FileDescriptor(conn[1]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
