"""No connection is lost to a worker that is leaving (review record B25).

Under `--workers N` the worker that wins an accept may pass the connection
to a sibling (SPEC E16). A sibling that is shutting down stores
`STATE_LEFT` on the shared page, and then its drain takes what its channel
holds. Nothing ordered a sender's `sendmsg` before that drain, and both
ways the connection was lost. Each was measured in a Linux container with
the gap between the acceptor's `pick` and its send widened:

- **Late.** The leaver was idle, and it exited about 50 ms after SIGTERM.
  A sibling's `sendmsg` succeeded 255 ms after that, into a channel nothing
  would read again, because the supervisor does not respawn a clean exit.
  The client got no answer for 8 s and was reset only when the whole
  server stopped.
- **Early.** The hand-off reached the leaver during its drain, before the
  client's first byte. The drain admitted it, and 1.6 ms later closed it as
  a connection idle between requests: the client read EOF.

The fix is a handshake on the page, in which each side writes its own word
before it reads the other's. The sender raises the target's `pending`, then
reads its `state` again, and keeps a connection whose target has left. The
leaver stores `STATE_LEFT`, then drains until `pending`, less what it has
received, is 0. And a worker that has left passes what its channel delivers
on to a sibling that has not, admitting it only when none is left. The
leaver's wait trusts `pending` never to run high for good, so the worker that
takes the index of one that died takes back what it had taken off its channel
and not yet retired.

These tests force each interleaving in one process: a descriptor passes
over a socketpair within one process as it does between two, and the shared
page is plain memory until a fork. `PushedBackend` returns exactly the events
a test pushed. `_LeaveInsideTheHandoff` is a `HandoffPost` that makes the
target leave after the sender's second read of `state` and before the
datagram exists: the one order the sender cannot see, which two real
processes produce only when the sender is preempted there.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.accept_share import (
    AcceptShare, HandoffPost, accept_share_slots, ACCEPT_SHARE_BUSY_NS,
    ACCEPT_SHARE_FIRST_WORKER_SLOT, ACCEPT_SHARE_WORKER_STRIDE, STATE_LEFT,
    STATE_PARKED,
)
from lightbug_http.c.fdpass import RECV_FD_EMPTY, send_fd
from lightbug_http.c.fcntl import set_nonblocking
from lightbug_http.c.kqueue import EVFILT_READ
from lightbug_http.c.pipe import close_fd
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import recv, send
from lightbug_http.event_loop import run_pass_once
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.loop.accept import _admit_connection, _admit_handoffs
from lightbug_http.loop.shutdown import (
    _shutdown_begin, _shutdown_drain_step, _shutdown_finish,
)
from lightbug_http.loop.state import LoopState, UNUSED, _close_slot
from lightbug_http.server_config import ServerConfig

from src.multiworker import SharedAtomics


struct PushedBackend(EventLoopBackend):
    """A backend whose next `wait` returns the events pushed since the last
    one, and nothing else. Registrations change nothing."""

    var next_ident: List[Int]
    var next_filter: List[Int16]
    var ident: List[Int]
    var filter: List[Int16]

    def __init__(out self):
        self.next_ident = List[Int]()
        self.next_filter = List[Int16]()
        self.ident = List[Int]()
        self.filter = List[Int16]()

    def push(mut self, ident: Int, filter: Int16):
        """Add one event to the batch the next `wait` returns."""
        self.next_ident.append(ident)
        self.next_filter.append(filter)

    def wait(mut self, timeout_ms: Int) raises -> Int:
        self.ident = self.next_ident^
        self.filter = self.next_filter^
        self.next_ident = List[Int]()
        self.next_filter = List[Int16]()
        return len(self.ident)

    def event_ident(self, i: Int) -> UInt:
        return UInt(self.ident[i])

    def event_filter(self, i: Int) -> Int16:
        return self.filter[i]

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


struct Recorder(HTTPService):
    """Answers every request, and counts them."""

    var requests: Int

    def __init__(out self):
        self.requests = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.requests += 1
        return OK(String("answered"), "text/plain")


comptime SLOTS = 4
comptime REQUEST = "GET /x HTTP/1.1\r\nHost: t\r\n\r\n"


def _config() -> ServerConfig:
    var config = ServerConfig()
    config.max_connections = SLOTS
    config.sse_heartbeat_ms = 0
    return config^


def _pending_slot(worker: Int) -> Int:
    """The page slot of `worker`'s `pending` word."""
    return ACCEPT_SHARE_FIRST_WORKER_SLOT + ACCEPT_SHARE_WORKER_STRIDE * worker + 2


def _state_slot(worker: Int) -> Int:
    return ACCEPT_SHARE_FIRST_WORKER_SLOT + ACCEPT_SHARE_WORKER_STRIDE * worker


def _active_slot(worker: Int) -> Int:
    return ACCEPT_SHARE_FIRST_WORKER_SLOT + ACCEPT_SHARE_WORKER_STRIDE * worker + 1


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


def _send_text(fd: Int, text: String) raises:
    var b = List[UInt8](text.as_bytes())
    assert_equal(Int(send(FileDescriptor(fd), Span(b), 0)), len(b))


def _read_all(fd: Int) -> String:
    """Everything waiting on `fd`, without blocking."""
    var out = List[UInt8]()
    var buf = List[UInt8](length=65536, fill=0)
    while True:
        var n: UInt
        try:
            n = recv(FileDescriptor(fd), Span(buf), MSG_DONTWAIT)
        except:
            break
        if n == 0:
            break
        for i in range(Int(n)):
            out.append(buf[i])
    return String(from_utf8_lossy=Span(out))


def _peer_gone(fd: Int) -> Bool:
    """Whether every reference to `fd`'s peer is closed: EOF, where a peer
    still open anywhere -- in a process, or in flight in a channel --
    answers EAGAIN."""
    var buf = List[UInt8](capacity=1)
    buf.append(0)
    try:
        return Int(recv(FileDescriptor(fd), Span(buf), MSG_DONTWAIT)) == 0
    except:
        return False


def _the_slot(st: LoopState) -> Int:
    """The one slot `st` holds a connection in, or -1."""
    for s in range(st.max_conns):
        if st.slot_fds[s] != UNUSED:
            return s
    return -1


def _close_all[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState
):
    for s in range(st.max_conns):
        if st.slot_fds[s] != UNUSED:
            _close_slot(handler, backend, st, s, st.slot_fds[s])


struct _LeaveInsideTheHandoff(HandoffPost):
    """The target leaves after the sender read its `state` again and before
    the datagram is queued. Its drain begins, and runs one pass, inside the
    hand-off, and whether that pass found the drain over is recorded: the
    worker would have exited there."""

    var st: LoopState
    """The target's loop, `STATE_LEFT` once the hand-off has run."""
    var backend: PushedBackend
    var handler: Recorder
    var drain_start: Int
    var over_before_send: Bool
    """Whether the target's drain was over with the datagram not yet sent."""
    var error: String

    def __init__(out self, var st: LoopState):
        self.st = st^
        self.backend = PushedBackend()
        self.handler = Recorder()
        self.drain_start = 0
        self.over_before_send = False
        self.error = String("")

    def post(mut self, channel: Int, fd: Int, payload: List[UInt8]) -> Bool:
        try:
            self.drain_start = _shutdown_begin(self.handler, self.backend, self.st)
            self.over_before_send = _shutdown_drain_step(
                self.handler, self.backend, self.st, self.drain_start, 0
            )
        except e:
            self.error = String(e)
        return send_fd(channel, fd, payload)


def test_a_sender_keeps_a_connection_for_a_worker_that_left() raises:
    """The late shape, the sender's side. The acceptor picks the lighter
    sibling, and the sibling leaves before the send: idle, its drain finds
    nothing and it exits. The send must be refused, with the count taken
    back and nothing in the channel, so the acceptor keeps the connection
    (`_accept_batch` admits it). Before the fix the datagram was queued: the
    connection sat in a channel nothing would read again.

    covers: E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    w0.start()
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    w1.start()
    var conn = _stream_pair()

    assert_equal(w0.pick(3, perf_counter_ns()), 1, "the acceptor did not pick the idle sibling")
    w1.leave()
    assert_false(w1.awaiting_handoffs(), "a leaver with nothing counted to it waits")
    assert_false(
        w0.send(1, conn[0], "10.0.0.1", 1001),
        "a hand-off was queued to a worker that had left: nothing reads its channel again",
    )
    assert_equal(page.load(_pending_slot(1)), 0, "a refused hand-off stayed counted")
    var host = String("")
    var port = 0
    assert_equal(w1.receive(host, port), RECV_FD_EMPTY, "the channel holds a hand-off")
    assert_equal(w0.handoffs_out, 0)
    close_fd(conn[0])
    close_fd(conn[1])


def test_a_leaver_waits_for_a_handoff_counted_before_it_left() raises:
    """The late shape, the leaver's side. A sender read the target's `state`
    again before the target left, so it sends. The target, idle, leaves
    before the datagram exists. Its drain must go on while the hand-off is
    counted to it and not yet received, take it when it arrives, and only
    then end. Before the fix the drain ended at once, and the datagram
    reached a channel nothing would read again. Where the connection is
    answered, a sibling or the leaver, is the next test's business.

    covers: D1, E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    w0.start()
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    w1.start()
    var st0 = LoopState(FileDescriptor(-1), _config(), String(""), True, accept_share=w0)
    var b0 = PushedBackend()
    var h0 = Recorder()
    var race = _LeaveInsideTheHandoff(
        LoopState(FileDescriptor(-1), _config(), String(""), True, accept_share=w1)
    )

    var conn = _stream_pair()
    _send_text(conn[1], REQUEST)
    assert_true(w0.send_with(race, 1, conn[0], "10.0.0.1", 1001))
    close_fd(conn[0])  # the in-flight datagram holds the connection now
    assert_equal(race.error, "")
    assert_equal(page.load(_state_slot(1)), STATE_LEFT, "the target did not leave inside the hand-off")
    assert_false(
        race.over_before_send,
        "the drain ended with a hand-off counted to it and not yet sent:"
        + " the worker would exit, and the datagram reach a channel nobody reads",
    )

    # The datagram arrives; the next pass of the drain takes it.
    race.backend.push(share.read_fds[1], EVFILT_READ)
    assert_false(
        _shutdown_drain_step(race.handler, race.backend, race.st, race.drain_start, 0),
        "the drain ended before the pass that takes the hand-off",
    )
    var host = String("")
    var port = 0
    assert_equal(race.st.accept_share.receive(host, port), RECV_FD_EMPTY, "the hand-off is still in the channel")
    assert_equal(page.load(_pending_slot(1)), 0, "the hand-off taken is still counted")
    assert_true(
        _shutdown_drain_step(race.handler, race.backend, race.st, race.drain_start, 0),
        "the drain went on with nothing in flight",
    )

    # Answered, wherever it went.
    _ = _admit_handoffs(h0, b0, st0)
    assert_true(_read_all(conn[1]).startswith("HTTP/1.1 200"), "the connection was never answered")
    _close_all(h0, b0, st0)
    _close_all(race.handler, race.backend, race.st)
    close_fd(conn[1])


def test_a_leaver_passes_a_handoff_on_before_its_first_byte() raises:
    """The early shape. The leaver has a request in flight, so its drain
    runs on, and a hand-off it was counted before it left arrives during
    that drain, before the client has sent a byte. The leaver must pass it
    on to the sibling that has not left, which answers the request when it
    comes. Before the fix the drain admitted it, found it idle between
    requests, and closed it: the client read EOF with no answer.

    covers: D1, E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    w0.start()
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    w1.start()
    var st0 = LoopState(FileDescriptor(-1), _config(), String(""), True, accept_share=w0)
    var b0 = PushedBackend()
    var h0 = Recorder()
    var race = _LeaveInsideTheHandoff(
        LoopState(FileDescriptor(-1), _config(), String(""), True, accept_share=w1)
    )

    # The leaver's request in flight: half a request, which the drain waits
    # for, so the drain runs whatever the hand-off does.
    var busy = _stream_pair()
    _send_text(busy[1], "GET /slow HTTP/1.1\r\n")
    _admit_connection(race.handler, race.backend, race.st, busy[0], String("127.0.0.1"), 1)
    assert_equal(race.st.active_count, 1)

    var conn = _stream_pair()
    assert_true(w0.send_with(race, 1, conn[0], "10.0.0.2", 2002))
    close_fd(conn[0])
    assert_equal(race.error, "")
    assert_false(race.over_before_send, "the drain ended with a request in flight")

    race.backend.push(share.read_fds[1], EVFILT_READ)
    assert_false(_shutdown_drain_step(race.handler, race.backend, race.st, race.drain_start, 0))
    assert_false(
        _peer_gone(conn[1]),
        "the leaver closed the hand-off before its first byte: the client reads EOF, unanswered",
    )
    assert_equal(race.st.active_count, 1, "the leaver kept the hand-off")
    assert_equal(race.st.accept_share.handoffs_forwarded, 1)

    # The sibling admits it and answers the request when it comes.
    _ = _admit_handoffs(h0, b0, st0)
    var slot = _the_slot(st0)
    assert_true(slot >= 0, "the hand-off never reached the sibling that had not left")
    assert_equal(st0.provision_pool.provisions[slot].peer_host, "10.0.0.2")
    assert_equal(st0.provision_pool.provisions[slot].peer_port, 2002)
    _send_text(conn[1], REQUEST)
    b0.push(st0.slot_fds[slot], EVFILT_READ)
    _ = run_pass_once(h0, b0, st0)
    assert_equal(h0.requests, 1)
    assert_true(_read_all(conn[1]).startswith("HTTP/1.1 200"), "the request was not answered")

    _close_all(h0, b0, st0)
    _close_all(race.handler, race.backend, race.st)
    close_fd(busy[1])
    close_fd(conn[1])


def test_a_handoff_queued_before_the_leave_is_passed_on() raises:
    """The same, for a hand-off already in the channel when the leaver's
    shutdown begins, which takes it before the drain's first pass. It must
    go to the sibling, not be admitted and closed as idle. And what that
    first drain took is retired from `pending` by the time the drain is
    over, though no pass ran to retire it: a clean exit leaves the count
    exact.

    covers: D1, E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    w0.start()
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    w1.start()
    var st0 = LoopState(FileDescriptor(-1), _config(), String(""), True, accept_share=w0)
    var b0 = PushedBackend()
    var h0 = Recorder()
    var st1 = LoopState(FileDescriptor(-1), _config(), String(""), True, accept_share=w1)
    var b1 = PushedBackend()
    var h1 = Recorder()

    var conn = _stream_pair()
    assert_true(w0.send(1, conn[0], "10.0.0.3", 3003))
    close_fd(conn[0])

    var drain_start = _shutdown_begin(h1, b1, st1)
    assert_false(
        _peer_gone(conn[1]),
        "the shutdown closed a queued hand-off before its first byte: the client reads EOF",
    )
    assert_true(
        _shutdown_drain_step(h1, b1, st1, drain_start, 0),
        "the drain waited for a hand-off it had already taken",
    )
    _shutdown_finish(h1, b1, st1)
    assert_equal(
        page.load(_pending_slot(1)), 0,
        "the drain exited with a hand-off it took still counted in pending",
    )

    _ = _admit_handoffs(h0, b0, st0)
    var slot = _the_slot(st0)
    assert_true(slot >= 0, "the queued hand-off never reached the sibling that had not left")
    _send_text(conn[1], REQUEST)
    b0.push(st0.slot_fds[slot], EVFILT_READ)
    _ = run_pass_once(h0, b0, st0)
    assert_true(_read_all(conn[1]).startswith("HTTP/1.1 200"), "the request was not answered")
    _close_all(h0, b0, st0)
    close_fd(conn[1])


def test_a_leaver_with_no_sibling_left_admits_and_serves() raises:
    """The whole server stopping: every sibling has left, so the connection
    is admitted where it arrived, and the drain answers its request."""
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    w0.start()
    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    w1.start()
    var st1 = LoopState(FileDescriptor(-1), _config(), String(""), True, accept_share=w1)
    var b1 = PushedBackend()
    var h1 = Recorder()

    var conn = _stream_pair()
    _send_text(conn[1], REQUEST)
    assert_true(w0.send(1, conn[0], "10.0.0.4", 4004))
    close_fd(conn[0])
    w0.leave()

    var drain_start = _shutdown_begin(h1, b1, st1)
    assert_equal(h1.requests, 1, "with no sibling left the hand-off was not served where it arrived")
    assert_true(_read_all(conn[1]).startswith("HTTP/1.1 200"))
    assert_equal(st1.accept_share.handoffs_forwarded, 0)
    _ = _shutdown_drain_step(h1, b1, st1, drain_start, 0)
    _close_all(h1, b1, st1)
    close_fd(conn[1])


def test_a_respawn_takes_back_what_its_predecessor_had_taken() raises:
    """A worker that dies between taking a hand-off off its channel and
    retiring it at the end of the pass leaves that connection counted in
    `pending`, and it died with the worker. The worker that takes the index
    must take the count back, while a hand-off still queued in the channel
    stays counted, so that leaving it waits for what is really in flight.
    Left in the count, every drain at the index would wait out its budget
    for a connection that does not exist, which under `--reload` runs into
    the reload's own deadline and SIGKILL, leaving the count behind again.

    covers: E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var w0 = share.copy()
    w0.bind(0, page.addr(0))
    var dead = share.copy()
    dead.bind(1, page.addr(0))
    var a = _stream_pair()
    var b = _stream_pair()
    assert_true(w0.send(1, a[0], "10.0.0.5", 5005))
    assert_true(w0.send(1, b[0], "10.0.0.6", 6006))
    close_fd(a[0])
    close_fd(b[0])
    assert_equal(page.load(_pending_slot(1)), 2)

    # The predecessor takes the first hand-off and dies before its pass
    # ends: its connection goes with it.
    var host = String("")
    var port = 0
    var lost = dead.receive(host, port)
    assert_true(lost >= 0)
    close_fd(lost)

    var w1 = share.copy()
    w1.bind(1, page.addr(0))
    w1.start()
    assert_equal(
        page.load(_pending_slot(1)), 1,
        "pending after the respawn: 2 counts the connection that died with the"
        + " predecessor, 0 lost the one still queued",
    )
    w1.leave()
    assert_true(w1.awaiting_handoffs(), "the queued hand-off is in flight to the leaver")
    var queued = w1.receive(host, port)
    assert_true(queued >= 0)
    assert_equal(host, "10.0.0.6")
    assert_false(
        w1.awaiting_handoffs(),
        "the leaver waits for a connection that died with its predecessor",
    )
    w1.pass_end(0)
    assert_equal(page.load(_pending_slot(1)), 0)
    close_fd(queued)
    close_fd(a[1])
    close_fd(b[1])


def test_a_leaver_picks_any_sibling_that_has_not_left() raises:
    """Where a leaver passes a connection: the least-loaded sibling that has
    not left, however loaded, since its own load never wins; one inside a
    long pass only when no other has not left; itself when every sibling
    has left."""
    var page = SharedAtomics(accept_share_slots(3))
    var me = AcceptShare(3)
    me.bind(0, page.addr(0))
    me.start()
    me.leave()
    page.store(_state_slot(1), STATE_PARKED)
    page.store(_state_slot(2), STATE_PARKED)
    var now = perf_counter_ns()
    # Sibling 1 has left; sibling 2 is loaded far past anything: still it.
    page.store(_state_slot(1), STATE_LEFT)
    page.store(_active_slot(2), 500)
    assert_equal(me.pick_for_leaver(now), 2)
    # Sibling 2 inside a long pass, and no other has not left: still it.
    page.store(_state_slot(2), now - ACCEPT_SHARE_BUSY_NS - 1)
    assert_equal(me.pick_for_leaver(now), 2)
    # A sibling that has not left and is not busy wins over a busy one,
    # however light the busy one is.
    page.store(_state_slot(1), STATE_PARKED)
    page.store(_active_slot(1), 900)
    page.store(_active_slot(2), 0)
    assert_equal(me.pick_for_leaver(now), 1)
    # Every sibling has left: this worker.
    page.store(_state_slot(1), STATE_LEFT)
    page.store(_state_slot(2), STATE_LEFT)
    assert_equal(me.pick_for_leaver(now), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
