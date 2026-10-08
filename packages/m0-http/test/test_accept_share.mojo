"""Tests for passing accepted connections between workers (SPEC E16).

covers: E16

Everything here runs in one process: a passed descriptor is a kernel
mechanism that behaves the same across a socketpair whether the two ends
are in one process or two, and the shared page is plain memory until a
fork. The fork half — two real workers splitting a burst — is
`poe smoke-accept-spread` against the real server on both platforms. The
loop's own drain of the channel (`_admit_handoffs`) runs here too, over a
`LoopState` built by its constructor and this OS's multiplexer.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.time import perf_counter_ns, sleep

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.accept_share import (
    AcceptShare, accept_share_slots, ACCEPT_SHARE_FIRST_WORKER_SLOT,
    ACCEPT_SHARE_WORKER_STRIDE, ACCEPT_SHARE_BUSY_NS, STATE_LEFT,
    STATE_NOT_STARTED, STATE_PARKED, HandoffPost, mark_reaped,
)
from lightbug_http.c.fdpass import (
    send_fd, recv_fd, FDPASS_MAX_PAYLOAD, RECV_FD_EMPTY, RECV_FD_REFUSED,
    _CMSG_HDR, _SCM_RIGHTS, _msghdr, _sendmsg, _store_u32,
)
from lightbug_http.c.fcntl import set_nonblocking
from lightbug_http.c.socket import iovec_t, send, recv, close, setsockopt, SocketOption, SOL_SOCKET
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.c.platform import MSG_DONTWAIT, PlatformBackend
from lightbug_http.loop.accept import _admit_handoffs
from lightbug_http.loop.state import LoopState, UNUSED, _close_slot
from lightbug_http.server_config import ServerConfig

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


def _stream_pair() raises -> Tuple[Int, Int]:
    """An `AF_UNIX` `SOCK_STREAM` pair, standing in for an accepted connection
    where the test must tell a closed descriptor from a leaked one: once the
    last reference to one end is closed, in any process, the other end reads
    EOF (`_peer_gone`). A datagram pair has no EOF, so it cannot tell."""
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


def _peer_gone(fd: Int) -> Bool:
    """Whether every reference to `fd`'s peer is closed: EOF, where a peer
    still open anywhere -- a descriptor installed and never closed -- answers
    EAGAIN."""
    var buf = List[UInt8](capacity=1)
    buf.append(0)
    try:
        return Int(recv(FileDescriptor(fd), Span(buf), UInt(1), MSG_DONTWAIT)) == 0
    except:
        return False


def _send_raw(channel: Int, data_len: Int, fds: List[Int]) -> Bool:
    """One `sendmsg` of `data_len` bytes and every descriptor in `fds` in a
    single `SCM_RIGHTS` message: the shapes `send_fd` never sends -- a
    payload past its cap, more than one descriptor -- which are the ones that
    reach `recv_fd`'s truncation paths."""
    var data = List[UInt8](capacity=data_len)
    for _ in range(data_len):
        data.append(UInt8(ord("x")))
    var used = _CMSG_HDR + 4 * len(fds)
    var align = 8
    comptime if CompilationTarget.is_macos():
        align = 4
    var space = (used + align - 1) // align * align
    var control = List[UInt8](capacity=space)
    for _ in range(space):
        control.append(0)
    _store_u32(control, 0, UInt32(used))
    comptime if CompilationTarget.is_macos():
        _store_u32(control, 4, UInt32(SOL_SOCKET))
        _store_u32(control, 8, UInt32(_SCM_RIGHTS))
    else:
        _store_u32(control, 8, UInt32(SOL_SOCKET))
        _store_u32(control, 12, UInt32(_SCM_RIGHTS))
    for i in range(len(fds)):
        _store_u32(control, _CMSG_HDR + 4 * i, UInt32(fds[i]))
    var iov = iovec_t(UInt(Int(data.unsafe_ptr())), UInt(data_len))
    var iov_ptr = Pointer(to=iov)
    var hdr = _msghdr(
        0, 0, UInt64(Pointer(to=iov_ptr).unsafe_bitcast[Int]()[]), 1,
        UInt64(Int(control.unsafe_ptr())), UInt64(space), 0,
    )
    var rc = _sendmsg(c_int(channel), Pointer(to=hdr), MSG_DONTWAIT)
    _ = iov
    _ = data
    _ = control
    return Int(rc) >= 0


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
    # An empty channel answers that it is empty, not a stale descriptor.
    assert_equal(recv_fd(channel[0], payload), RECV_FD_EMPTY)
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
    """Refused, and told apart from an empty channel: the datagram was
    taken off it, and whatever is queued behind is still owed a read.
    Both used to answer -1."""
    var channel = _nonblocking_pair()
    var msg = _bytes("no fd here")
    _ = send(FileDescriptor(channel[1]), Span(msg), UInt(len(msg)), 0)
    var payload = List[UInt8]()
    assert_equal(recv_fd(channel[0], payload), RECV_FD_REFUSED)
    assert_equal(recv_fd(channel[0], payload), RECV_FD_EMPTY)
    close(FileDescriptor(channel[0]))
    close(FileDescriptor(channel[1]))


def test_a_zero_length_datagram_still_hands_over_its_descriptor() raises:
    """A datagram with no payload that brings a descriptor: the kernel
    installed it when the message was received, so it is the receiver's to
    hand over or close. `recv_fd` read the control data only when the read
    returned bytes, so it answered -1 and left this one open for the life
    of the process (`send_fd` itself always sends a byte). A read of 0 that
    brings nothing is still nothing received: it cannot be told from a read
    side shut down, which reads 0 forever, and a drain must not spin on it.
    """
    var channel = _nonblocking_pair()
    var conn = _stream_pair()
    var fds = List[Int]()
    fds.append(conn[0])
    assert_true(_send_raw(channel[1], 0, fds), "sendmsg failed")
    close(FileDescriptor(conn[0]))  # the kernel's in-flight reference holds it
    var payload = List[UInt8]()
    var got = recv_fd(channel[0], payload)
    assert_true(got >= 0, "a zero-length datagram's descriptor was not handed over")
    assert_equal(len(payload), 0)
    close(FileDescriptor(got))
    assert_true(_peer_gone(conn[1]), "a reference to the passed descriptor is still open")
    var empty = List[UInt8]()
    _ = send(FileDescriptor(channel[1]), Span(empty), UInt(0), 0)
    assert_equal(recv_fd(channel[0], payload), RECV_FD_EMPTY)
    close(FileDescriptor(conn[1]))
    close(FileDescriptor(channel[0]))
    close(FileDescriptor(channel[1]))


def test_a_payload_cut_short_still_hands_over_its_descriptor() raises:
    """A datagram longer than `FDPASS_MAX_PAYLOAD` arrives with `MSG_TRUNC`
    set: its tail is dropped, its descriptor is not, and the kernel has
    installed that descriptor already. Linux's `MSG_TRUNC` is 0x20, the value
    `recv_fd` once tested as `MSG_CTRUNC` on both platforms, so there it
    refused the descriptor and left it open for the life of the process: a
    connection whose client waited on it forever. On macOS `recv_fd` read
    the flags from a word the kernel never writes (fdpass's docstring), so
    this passed there before the fix too; it tells the two apart on Linux,
    which CI runs.
    """
    var channel = _nonblocking_pair()
    var conn = _stream_pair()
    var fds = List[Int]()
    fds.append(conn[0])
    assert_true(_send_raw(channel[1], FDPASS_MAX_PAYLOAD + 1, fds), "sendmsg failed")
    close(FileDescriptor(conn[0]))  # the kernel's in-flight reference holds it
    var payload = List[UInt8]()
    var got = recv_fd(channel[0], payload)
    assert_true(got >= 0, "a payload cut short cost its descriptor")
    assert_equal(len(payload), FDPASS_MAX_PAYLOAD)
    close(FileDescriptor(got))
    assert_true(_peer_gone(conn[1]), "a reference to the passed descriptor is still open")
    close(FileDescriptor(conn[1]))
    close(FileDescriptor(channel[0]))
    close(FileDescriptor(channel[1]))


def test_a_control_message_cut_short_is_refused_and_leaks_nothing() raises:
    """Three descriptors in one message, into `recv_fd`'s control buffer,
    which has room for one on macOS and two on Linux: the kernel sets
    `MSG_CTRUNC`, and `recv_fd` refuses the message, `send_fd` passing
    exactly one. The kernel installed every descriptor that reached the
    buffer when the message was received, so the refusal must close each of
    them, or each is a connection left open for the life of the process.

    What did not fit differs by kernel. Linux releases it. macOS installs it
    too, with its number lost (measured), where no code can close it. So the
    assertion is on what reached the buffer: the first descriptor on both,
    and on Linux the second, with the third checked as released.

    Before the fix both platforms returned the first descriptor instead,
    missing the truncation for different reasons. On Linux `MSG_CTRUNC` is
    0x08, and the 0x20 tested is Linux's `MSG_TRUNC`. On macOS the bit was
    right but read from a word the kernel never writes: its `struct msghdr`
    is 48 bytes, `msg_flags` the high half of the sixth word. And a refusal
    closed nothing, so each descriptor it refused stayed open.
    """
    var channel = _nonblocking_pair()
    var a = _stream_pair()
    var b = _stream_pair()
    var c = _stream_pair()
    var fds = List[Int]()
    fds.append(a[0])
    fds.append(b[0])
    fds.append(c[0])
    assert_true(_send_raw(channel[1], 1, fds), "sendmsg failed")
    close(FileDescriptor(a[0]))
    close(FileDescriptor(b[0]))
    close(FileDescriptor(c[0]))
    var payload = List[UInt8]()
    var got = recv_fd(channel[0], payload)
    assert_true(got == RECV_FD_REFUSED, "a message whose control data was cut short was not refused")
    assert_true(_peer_gone(a[1]), "the refused message's first descriptor was left open")
    comptime if not CompilationTarget.is_macos():
        assert_true(_peer_gone(b[1]), "the refused message's second descriptor was left open")
        assert_true(_peer_gone(c[1]), "the descriptor that did not fit was not released")
    close(FileDescriptor(a[1]))
    close(FileDescriptor(b[1]))
    close(FileDescriptor(c[1]))
    close(FileDescriptor(channel[0]))
    close(FileDescriptor(channel[1]))


def test_an_unbound_share_is_inactive_and_costs_nothing() raises:
    var share = AcceptShare()
    assert_false(share.active())
    assert_equal(share.read_fd(), -1)
    assert_equal(share.pick(0, perf_counter_ns()), -1)
    var host = String("x")
    var port = 1
    assert_equal(share.receive(host, port), RECV_FD_EMPTY)
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
    assert_equal(w1.receive(host, port), RECV_FD_EMPTY)
    close(FileDescriptor(fd))
    close(FileDescriptor(conn[1]))


struct _ReceiverWinsTheGap(HandoffPost):
    """The interleaving review record R5 names, forced: the sibling takes the
    datagram, admits the connection and ends its pass -- retiring it from
    `pending` -- before the sender runs one more instruction. Two real
    processes do this only when the sender is preempted right after its
    `sendmsg`, which the wake of the receiver it just sent to invites."""

    var receiver: AcceptShare
    var admitted: Int
    var pending_seen: Int
    """`pending` of the receiver as the datagram was queued: what a sibling's
    `pick` read at that moment."""

    def __init__(out self, receiver: AcceptShare):
        self.receiver = receiver.copy()
        self.admitted = -1
        self.pending_seen = -1

    def post(mut self, channel: Int, fd: Int, payload: List[UInt8]) -> Bool:
        if not send_fd(channel, fd, payload):
            return False
        self.pending_seen = self.receiver.load_of(self.receiver.worker)
        var host = String("")
        var port = 0
        self.admitted = self.receiver.receive(host, port)
        self.receiver.pass_end(1)
        return True


struct _Refused(HandoffPost):
    """A send the kernel refused: nothing was queued."""

    def __init__(out self):
        pass

    def post(mut self, channel: Int, fd: Int, payload: List[UInt8]) -> Bool:
        return False


def test_a_receiver_that_retires_inside_the_handoff_leaves_nothing_pending() raises:
    """`pending` is raised before the datagram exists, so the receiver can
    never retire a connection the count does not hold yet. Raised after the
    `sendmsg`, the retire found nothing, `pass_end` clamped the count at 0,
    and the late increment left it one high for good: `pick` read that
    worker as busier than it was from then on (review record R5).
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    var conn = _nonblocking_pair()
    var race = _ReceiverWinsTheGap(w1)
    assert_true(w0.send_with(race, 1, conn[0], "10.1.2.3", 4321))
    assert_true(race.admitted >= 0, "the receiver took the connection inside the hand-off")
    assert_equal(page.load(_word_slot(1, 2)), 0, "pending[1] once the one connection sent was admitted and retired")
    assert_equal(w0.load_of(1), 1, "worker 1's load is its one admitted connection")
    # Counted while in flight, too: a count raised after the datagram is
    # low until then, and without `pass_end`'s clamp it went negative.
    assert_equal(race.pending_seen, 1, "the connection was counted before its datagram was queued")
    assert_equal(w0.handoffs_out, 1)
    # A send that queued nothing takes its count back.
    var refused = _Refused()
    assert_false(w0.send_with(refused, 1, conn[0], "10.1.2.3", 4321))
    assert_equal(page.load(_word_slot(1, 2)), 0, "pending[1] after a refused send")
    assert_equal(w0.handoffs_out, 1)
    close(FileDescriptor(race.admitted))
    close(FileDescriptor(conn[0]))
    close(FileDescriptor(conn[1]))


struct _DescriptorLost(HandoffPost):
    """A hand-off as a receiver that could not install its descriptor sees
    it: the payload and nothing else. That is what a worker out of
    descriptors receives from a sender that did everything right -- macOS
    fails the receive with EMSGSIZE and leaves the data queued alone, Linux
    flags `MSG_CTRUNC` and installs nothing."""

    def __init__(out self):
        pass

    def post(mut self, channel: Int, fd: Int, payload: List[UInt8]) -> Bool:
        try:
            return Int(send(FileDescriptor(channel), Span(payload), UInt(len(payload)), 0)) > 0
        except:
            return False


@fieldwise_init
struct _Quiet(HTTPService):
    """A handler no request reaches: the connections admitted below send
    nothing, so their eager read finds the socket empty."""

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("quiet", "text/plain")


def test_a_refused_handoff_does_not_stop_the_drain() raises:
    """A hand-off that arrives without its descriptor is skipped, and the
    one queued behind it is still admitted.

    `recv_fd` answered -1 for an empty channel and for a datagram that
    brought no descriptor alike, and `_admit_handoffs` stopped at -1: a
    connection queued behind a refusal waited, its client connected and
    unanswered, until some later hand-off to this worker raised an edge on
    the channel. A refusal counts against the batch like any hand-off
    taken, and is retired from `pending` with the rest -- its sender
    counted it, and left there `pick` would read this worker a connection
    heavier for good (R5's shape).
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    var config = ServerConfig()
    config.max_connections = 4
    var st = LoopState(FileDescriptor(-1), config, String(""), True, accept_share=w1)
    var backend = PlatformBackend()
    var handler = _Quiet()

    var lost = _stream_pair()
    var kept = _stream_pair()
    var dropped = _DescriptorLost()
    assert_true(w0.send_with(dropped, 1, lost[0], "10.0.0.1", 1001))
    assert_true(w0.send(1, kept[0], "10.0.0.2", 2002))
    close(FileDescriptor(lost[0]))
    close(FileDescriptor(kept[0]))  # the kernel's in-flight reference holds it
    assert_equal(page.load(_word_slot(1, 2)), 2, "pending[1] counts both hand-offs")

    # A batch of one takes the refusal, and owes what is behind it.
    assert_true(
        _admit_handoffs(handler, backend, st, 1),
        "a refused hand-off ended the drain as if the channel were empty",
    )
    assert_equal(st.active_count, 0, "a refusal was admitted, or took no share of the batch")
    # The next batch admits the connection behind it and empties the channel.
    assert_false(_admit_handoffs(handler, backend, st, 16))
    assert_equal(st.active_count, 1, "the hand-off behind a refused one was not admitted")
    var slot = -1
    for s in range(st.max_conns):
        if st.slot_fds[s] != UNUSED:
            slot = s
    assert_true(slot >= 0)
    assert_equal(st.provision_pool.provisions[slot].peer_host, "10.0.0.2")
    assert_equal(st.provision_pool.provisions[slot].peer_port, 2002)
    st.accept_share.pass_end(st.active_count)
    assert_equal(page.load(_word_slot(1, 2)), 0, "a refused hand-off was never retired from pending")

    _close_slot(handler, backend, st, slot, st.slot_fds[slot])
    assert_true(_peer_gone(kept[1]), "the admitted connection is not the one sent, or leaked")
    close(FileDescriptor(lost[1]))
    close(FileDescriptor(kept[1]))


def test_pick_names_the_least_loaded_sibling_or_itself() raises:
    var page = SharedAtomics(accept_share_slots(3))
    var me = AcceptShare(3)
    me.bind(0, page.addr(0))
    page.store(_word_slot(1, 0), STATE_PARKED)
    page.store(_word_slot(2, 0), STATE_PARKED)
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
    page.store(_word_slot(1, 0), STATE_PARKED)
    page.store(_word_slot(1, 1), 2)
    page.store(_word_slot(2, 1), 2)
    assert_equal(me.pick(2, now), 0)


def test_a_sibling_that_has_not_started_is_never_picked() raises:
    """A sibling whose loop has not started is refused as one that has left
    is: nothing reads its channel until its `start()`, which in m0serve
    follows the application's import, and a stop that reaches it first
    kills it unarmed with every connection it was handed (review AR). A
    fresh page reads not started with nothing written; a replacement marks
    its index so again as it binds, whatever its predecessor last wrote,
    and keeps the predecessor's hand-offs in flight; and a leaver passes
    nothing on to a sibling that has not started.

    covers: E16
    """
    var page = SharedAtomics(accept_share_slots(3))
    var share = AcceptShare(3)
    var me = share.copy()
    me.bind(0, page.addr(0))
    me.start()
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    var w2 = share.copy()
    w2.bind(2, page.addr(0))
    var now = perf_counter_ns()
    assert_equal(page.load(_word_slot(1, 0)), STATE_NOT_STARTED)
    # Two siblings bound, neither started, this worker holding fifty.
    assert_equal(
        me.pick(50, now), 0,
        "a sibling that has not started its loop was handed a connection",
    )
    w1.start()
    assert_equal(me.pick(50, now), 1, "a started sibling was not picked")

    # Worker 1 dies parked with two hand-offs in flight, and a replacement
    # takes its index: not started until its own `start()`.
    page.store(_word_slot(1, 2), 2)
    var r1 = share.copy()
    r1.bind(1, page.addr(0))
    assert_equal(page.load(_word_slot(1, 0)), STATE_NOT_STARTED)
    assert_equal(page.load(_word_slot(1, 2)), 2, "binding dropped the predecessor's hand-offs")
    assert_equal(me.pick(50, now), 0, "a replacement was picked before its loop started")
    r1.start()
    assert_equal(me.pick(50, now), 1)
    assert_equal(page.load(_word_slot(1, 2)), 2)

    # A leaver: the started sibling, and when it leaves too, itself rather
    # than the sibling that has not started.
    me.leave()
    assert_equal(me.pick_for_leaver(now), 1)
    r1.leave()
    assert_equal(
        me.pick_for_leaver(now), 0,
        "a leaver passed a connection on to a sibling that has not started",
    )


def test_a_worker_reaped_after_the_pick_is_not_sent_to() raises:
    """The supervisor's mark for a worker it reaped (`mark_reaped`) is
    `STATE_LEFT`, and the sender's second read of `state` refuses it: an
    acceptor that picked the worker while it still read parked, and reads
    the word again after the reap, keeps the connection and takes its
    count back. Marked not started instead, `pick` would refuse the worker
    from then on but this send would go through, into a channel nothing
    reads (review record RP). A replacement's `bind` and `start` make the
    index willing again.

    covers: E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var me = share.copy()
    me.bind(0, page.addr(0))
    me.start()
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    w1.start()
    var now = perf_counter_ns()
    assert_equal(me.pick(50, now), 1, "an idle parked sibling was not picked")
    # Worker 1 dies parked, and the supervisor reaps it between the pick
    # and the send.
    mark_reaped(page.addr(0), 1)
    var conn = _nonblocking_pair()
    var sent = me.send(1, conn[0], "127.0.0.1", 1)
    var payload = List[UInt8]()
    var queued = recv_fd(share.read_fds[1], payload)
    if queued >= 0:
        close(FileDescriptor(queued))
    close(FileDescriptor(conn[0]))
    close(FileDescriptor(conn[1]))
    assert_false(sent, "a connection was sent to a worker the supervisor had reaped")
    assert_equal(queued, RECV_FD_EMPTY, "the reaped worker's channel holds a connection")
    assert_equal(page.load(_word_slot(1, 2)), 0, "the refused send left its count in pending")
    assert_equal(me.pick(50, now), 0, "a reaped worker was picked")
    assert_equal(me.pick_for_leaver(now), 0, "a leaver would pass a connection to a reaped worker")
    # Its replacement is not started until its loop starts, then willing.
    var r1 = share.copy()
    r1.bind(1, page.addr(0))
    assert_equal(page.load(_word_slot(1, 0)), STATE_NOT_STARTED)
    r1.start()
    assert_equal(me.pick(50, now), 1, "a replacement was never picked again")


def test_a_burst_spreads_across_siblings_through_pending() raises:
    """Thirty-two accepts in one pass, the siblings' published counts
    stale at zero throughout: `pending` is what keeps the acceptor from
    handing every one to the same sibling."""
    var page = SharedAtomics(accept_share_slots(3))
    var share = AcceptShare(3)
    var me = share.copy()
    me.bind(0, page.addr(0))
    for i in range(1, 3):
        var sibling = share.copy()
        sibling.bind(i, page.addr(0))
        sibling.start()
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
    assert_equal(page.load(_word_slot(1, 0)), STATE_PARKED)
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
    assert_equal(page.load(_word_slot(1, 0)), STATE_PARKED)
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


comptime _MSG_PEEK = c_int(0x2)
"""`MSG_PEEK`, the same on both platforms."""


def _schedule_the_collector() raises:
    """Close an AF_UNIX socket pair: on macOS each such close schedules a run
    of the kernel's collector of descriptors in flight (XNU's `unp_gc`)."""
    var t = _stream_pair()
    close(FileDescriptor(t[0]))
    close(FileDescriptor(t[1]))


def _request_intact(fd: Int) -> Bool:
    """Whether what the client sent before the hand-off is still there to
    read. A connection the collector flushed has lost it: its receive side
    is shut and what was queued is discarded, so it reads EOF."""
    var buf = List[UInt8](capacity=1)
    buf.append(0)
    try:
        return Int(
            recv(FileDescriptor(fd), Span(buf), UInt(1), _MSG_PEEK | MSG_DONTWAIT)
        ) == 1
    except:
        return False


def test_a_handoff_in_flight_is_beyond_the_kernels_collector() raises:
    """A connection in flight whose sender has closed its copy, as every
    hand-off's sender does, survives the kernel's collector of descriptors
    in flight.

    On macOS it did not (review record B25). XNU's collector walks only the
    descriptors in flight, marks the ones still open somewhere, and follows
    what their buffers hold, so a channel that was merely open was never
    followed, and every hand-off queued in one was flushed by each run: its
    receive side shut, the request it carried discarded, and the receiver
    closed it unanswered at its first read. Any AF_UNIX socket closed on
    the machine schedules a run. `AcceptShare` keeps each channel's read end
    in flight in a pair of its own, which puts the channel in the walk.

    Each round puts a hand-off on an accept-share channel and a control
    connection on a plain socket pair, both with a request queued and both
    senders' copies closed, then schedules a run. A flushed control shows a
    run happened while both were in flight; the hand-off must come through
    it with its request. Linux's collector never takes a socket that is
    open somewhere, so there no control is flushed and the rounds show
    nothing; the rule is macOS's.

    covers: E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    var plain = _nonblocking_pair()
    var runs_seen = 0
    for _ in range(20):
        var conn = _stream_pair()
        var ctl = _stream_pair()
        var request = _bytes("GET / HTTP/1.1\r\n")
        _ = send(FileDescriptor(conn[1]), Span(request), UInt(len(request)), 0)
        _ = send(FileDescriptor(ctl[1]), Span(request), UInt(len(request)), 0)
        assert_true(w0.send(1, conn[0], "10.0.0.8", 8008))
        assert_true(send_fd(plain[1], ctl[0], _bytes("c")))
        close(FileDescriptor(conn[0]))  # only the messages in flight hold them now
        close(FileDescriptor(ctl[0]))
        _schedule_the_collector()
        sleep(0.01)
        var payload = List[UInt8]()
        var ctl_fd = recv_fd(plain[0], payload)
        assert_true(ctl_fd >= 0, "the control connection did not arrive")
        var host = String("")
        var port = 0
        var got = w1.receive(host, port)
        assert_true(got >= 0, "the hand-off did not arrive")
        var ran = not _request_intact(ctl_fd)
        var intact = _request_intact(got)
        w1.pass_end(0)
        for fd in [ctl_fd, got, conn[1], ctl[1]]:
            close(FileDescriptor(fd))
        if ran:
            runs_seen += 1
            assert_true(
                intact,
                "the kernel's collector flushed a hand-off in flight: its"
                + " request was discarded and the receiver reads EOF",
            )
            if runs_seen == 3:
                break
    comptime if CompilationTarget.is_macos():
        if runs_seen == 0:
            print(
                "note: no collector run flushed the control in 20 rounds;"
                + " this kernel no longer does what the anchor guards against"
            )
    close(FileDescriptor(plain[0]))
    close(FileDescriptor(plain[1]))


def test_a_receive_that_meets_a_collector_scan_still_takes_the_datagram() raises:
    """Draining a channel whose buffer the kernel's collector is scanning
    takes every hand-off queued in it: an empty channel is the only EMPTY.

    Keeping a channel's read end in flight (the test above) puts its buffer
    in the collector's walk on macOS, and XNU holds the buffer's lock while
    it scans it. A receive made with MSG_DONTWAIT fails EAGAIN on a held
    lock, with the datagram still queued: 5 in 3000 measured with another
    process closing AF_UNIX sockets throughout, none without the flag. A
    drain read the failure as the end of the channel, so `recv_fd` receives
    there without it, on a channel that is non-blocking, which waits out a
    scan and never waits for data.

    As many hand-offs as the channel holds are queued, up to two hundred,
    so each scan of the channel takes the longest it can, and a run is
    scheduled before every receive. macOS holds all two hundred; Linux caps
    a datagram queue at `net.unix.max_dgram_qlen` (10 in a fresh network
    namespace), and the acceptor keeps what a full channel refuses.

    covers: E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    var clients = List[Int]()
    var queued = 0
    for _ in range(200):
        var conn = _stream_pair()
        var sent = w0.send(1, conn[0], "10.0.0.9", 9009)
        close(FileDescriptor(conn[0]))
        clients.append(conn[1])
        if not sent:
            break
        queued += 1
    assert_true(queued > 0, "the channel took no hand-off at all")
    var taken = 0
    var host = String("")
    var port = 0
    while True:
        _schedule_the_collector()
        var fd = w1.receive(host, port)
        if fd == RECV_FD_EMPTY:
            break
        assert_true(fd >= 0)
        taken += 1
        close(FileDescriptor(fd))
    assert_equal(
        taken, queued,
        "a receive read the channel as empty with hand-offs still queued in it",
    )
    w1.pass_end(0)
    assert_equal(page.load(_word_slot(1, 2)), 0)
    for fd in clients:
        close(FileDescriptor(fd))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
