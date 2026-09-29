"""The event loop's per-slot lifecycle, and the backend contract it rests on.

Two halves.

**The backend contract, on the real multiplexer.** A write one-shot
REPLACES a socket's read interest on both backends: a slot waiting to write
reads nothing until `add_read` restores it. epoll always behaved so (read
and write share one registration, and the MOD replaces the mask); kqueue's
filters are separate, and its read filter, level triggered, stayed -- so a
slot waiting on a client that had half-closed, or had sent its next
request, was reported readable by every wait while it read nothing, the
loop at a full core (review record R4). `test_a_write_wait_holds_no_read_interest`
runs against `PlatformBackend`, so it holds each OS to the same answer; on
macOS it fails without the fix.

**The transitions** (`loop/state.mojo`'s "Per-slot lifecycle" section,
review record C4). Each helper owns the resets of its phase, which is what
makes a stale-state defect a helper's bug rather than one call site's. They
are driven here over a `LoopState` built by its own constructor, as
`prepare_loop` builds one, and over `FakeBackend`, which keeps one socket's
registration the way epoll does -- ONE registration, so a read added
replaces a pending write -- the stricter of the two, and the one a wrong
arm is wrong on. Its timers are epoll's too: an expired timerfd is
reported by every wait until it is deleted, where kqueue's one-shot fires
once.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.c.kqueue import EVFILT_READ, EVFILT_TIMER, EVFILT_WRITE
from lightbug_http.c.platform import PlatformBackend
from lightbug_http.c.socket import close, send
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.connection import ConnectionState
from lightbug_http.loop.state import (
    LoopState,
    TIMER_BODY,
    UNUSED,
    WS_CLOSE_LINGER_NS,
    _arm_reads,
    _arm_ws_linger,
    _await_write,
    _begin_request,
    _end_request,
    _record_response,
    _stop_reads,
    _stream_idle,
)
from lightbug_http.loop.timers import _on_timer
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.io.bytes import Bytes
from lightbug_http.server_config import ServerConfig


struct FakeBackend(EventLoopBackend):
    """One socket's registration, kept as epoll keeps it: read and write
    interest are ONE registration, so adding reads replaces a pending write
    one-shot, registering the write one-shot replaces the reads, and a
    delete takes both.

    Timers are kept as epoll keeps a timerfd, too: registered with EPOLLIN
    and never read by the loop, one that has expired is readable -- level
    triggered -- so every `wait` reports it until it is deleted or re-armed.
    `expire` is the clock running out."""

    var read: Bool
    var write: Bool
    var read_adds: Int
    var timers: List[UInt]
    var expired: List[UInt]
    var fired: List[UInt]

    def __init__(out self):
        self.read = False
        self.write = False
        self.read_adds = 0
        self.timers = List[UInt]()
        self.expired = List[UInt]()
        self.fired = List[UInt]()

    def expire(mut self, ident: UInt):
        """The timer's time has come: it is readable from now on."""
        if ident in self.timers and not ident in self.expired:
            self.expired.append(ident)

    def wait(mut self, timeout_ms: Int) raises -> Int:
        self.fired = self.expired.copy()
        return len(self.fired)

    def event_ident(self, i: Int) -> UInt:
        return self.fired[i]

    def event_filter(self, i: Int) -> Int16:
        return EVFILT_TIMER

    def event_flags(self, i: Int) -> UInt16:
        return 0

    def event_data(self, i: Int) -> Int:
        return 0

    def add_read_listen(mut self, fd: Int) raises:
        pass

    def add_read(mut self, fd: Int) raises:
        self.read = True
        self.write = False
        self.read_adds += 1

    def try_add_read(mut self, fd: Int):
        try:
            self.add_read(fd)
        except:
            pass

    def add_write_oneshot(mut self, fd: Int) raises:
        self.write = True
        self.read = False

    def try_add_write_oneshot(mut self, fd: Int):
        try:
            self.add_write_oneshot(fd)
        except:
            pass

    def try_delete_read(mut self, fd: Int):
        self.read = False
        self.write = False

    def try_delete_write(mut self, fd: Int):
        self.write = False

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        # A re-arm resets the timerfd, which clears its expiry.
        _drop(self.expired, ident)
        if not ident in self.timers:
            self.timers.append(ident)

    def try_delete_timer(mut self, ident: UInt):
        _drop(self.timers, ident)
        _drop(self.expired, ident)


def _drop(mut idents: List[UInt], ident: UInt):
    var kept = List[UInt]()
    for i in range(len(idents)):
        if idents[i] != ident:
            kept.append(idents[i])
    idents = kept^


struct NoApp(HTTPService):
    """The handler the loop's functions are generic over. Nothing here
    reaches it."""

    def __init__(out self):
        pass

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("unused", "text/plain")


comptime SLOTS = 4
comptime FD = 7


def _config() -> ServerConfig:
    var config = ServerConfig()
    config.idle_timeout = 5
    config.sse_heartbeat_ms = 0
    config.max_connections = SLOTS
    return config^


def _loop(config: ServerConfig) -> LoopState:
    """A loop's state before its first pass, over no socket: the helpers
    under test touch the slot tables and the backend they are handed, never
    the listener."""
    return LoopState(FileDescriptor(-1), config, String(""), True)


def test_a_write_wait_holds_no_read_interest() raises:
    """The backend contract, on this OS's multiplexer: with a datagram
    pending, a registered read reports it; once the write one-shot is
    registered the wait reports the write and NOT the read; the one-shot
    spent, nothing is reported; `add_read` reports the datagram again.
    kqueue kept its read filter beside the write before R4's fix, and the
    second wait returned both."""
    var pair = socketpair_dgram()
    var rx = pair[0]
    var tx = pair[1]
    var backend = PlatformBackend()
    backend.add_read(rx)
    var one = String("m")
    _ = send(FileDescriptor(tx), one.as_bytes(), UInt(1), 0)

    var n = backend.wait(1000)
    assert_equal(n, 1)
    assert_equal(Int(backend.event_ident(0)), rx)
    assert_equal(backend.event_filter(0), EVFILT_READ)

    backend.add_write_oneshot(rx)
    n = backend.wait(1000)
    var reads = 0
    var writes = 0
    for i in range(n):
        if Int(backend.event_ident(i)) != rx:
            continue
        if backend.event_filter(i) == EVFILT_READ:
            reads += 1
        elif backend.event_filter(i) == EVFILT_WRITE:
            writes += 1
    assert_equal(writes, 1)
    assert_equal(reads, 0)

    assert_equal(backend.wait(50), 0)

    backend.add_read(rx)
    n = backend.wait(1000)
    assert_equal(n, 1)
    assert_equal(backend.event_filter(0), EVFILT_READ)
    close(FileDescriptor(rx))
    close(FileDescriptor(tx))


def test_a_resume_mid_send_keeps_the_write() raises:
    """R1 on the real multiplexer: a WebSocket suspended its reads (the
    registration deleted), a frame then went out only in part, so the slot
    waits to write, and the resume arms reads while it does. The write
    readiness must still be reported. On epoll `add_read`'s ADD, EEXIST,
    MOD replaced the write one-shot, the wait reported nothing, and the
    frame's tail never went out: the slot stayed RESPONDING for good.
    kqueue's filters are separate, so this passes on macOS either way."""
    var pair = socketpair_dgram()
    var rx = pair[0]
    var tx = pair[1]
    var backend = PlatformBackend()
    var st = _loop(_config())
    var slot = st.provision_pool.borrow()
    st.slot_ws[slot] = True
    st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
    assert_true(_arm_reads(backend, st, slot, rx))
    _stop_reads(backend, st, slot, rx)
    st.slot_ws_state[slot].inbound_suspended = True
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    assert_true(_await_write(backend, st, slot, rx))

    st.slot_ws_state[slot].inbound_suspended = False
    assert_true(_arm_reads(backend, st, slot, rx))
    var n = backend.wait(1000)
    var writes = 0
    for i in range(n):
        if (
            Int(backend.event_ident(i)) == rx
            and backend.event_filter(i) == EVFILT_WRITE
        ):
            writes += 1
    assert_equal(writes, 1)
    close(FileDescriptor(rx))
    close(FileDescriptor(tx))


def test_arming_reads_waits_out_a_send() raises:
    """R1 at the helper: a slot RESPONDING is waiting for its write
    one-shot, and arming reads on it is refused -- over a registration kept
    as epoll keeps it, the arm replaced the write. The send's completion
    arms reads: here `_stream_idle`, as the write-ready path's
    `_after_send` runs it."""
    var backend = FakeBackend()
    var st = _loop(_config())
    var slot = st.provision_pool.borrow()
    st.slot_ws[slot] = True
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    assert_true(_await_write(backend, st, slot, FD))
    assert_true(backend.write)
    assert_false(st.slot_read_armed[slot])

    assert_true(_arm_reads(backend, st, slot, FD))
    assert_true(backend.write)
    assert_false(backend.read)
    assert_false(st.slot_read_armed[slot])
    assert_equal(backend.read_adds, 0)

    _stream_idle(backend, st, slot, FD)
    assert_equal(st.provision_pool.provisions[slot].state.kind, ConnectionState.STREAMING_WS)
    assert_true(backend.read)
    assert_true(st.slot_read_armed[slot])


def test_a_frame_keeps_a_websockets_close_linger() raises:
    """A WebSocket's non-zero deadline IS its close linger, and a frame
    that lands through the write-ready path must not clear it: a socket
    the handler closed itself (`take_ws_closes`) has its linger armed while
    its Close is still queued, and when that Close needed the write-ready
    path, `_after_send` zeroed the deadline -- a peer that never answered
    then held the slot for good. A socket that is not closing still sheds
    any deadline as it goes back to frame mode."""
    var backend = FakeBackend()
    var st = _loop(_config())
    var slot = st.provision_pool.borrow()
    st.slot_ws[slot] = True
    _arm_ws_linger(st, slot)
    var armed = st.slot_idle_deadline[slot]
    assert_true(armed > 0)
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    _stream_idle(backend, st, slot, FD)
    assert_equal(st.provision_pool.provisions[slot].state.kind, ConnectionState.STREAMING_WS)
    assert_equal(st.slot_idle_deadline[slot], armed)
    assert_true(st.slot_ws_state[slot].closing)

    var other = st.provision_pool.borrow()
    st.slot_ws[other] = True
    st.slot_idle_deadline[other] = perf_counter_ns() + 1_000_000_000
    st.provision_pool.provisions[other].state = ConnectionState.responding()
    _stream_idle(backend, st, other, FD)
    assert_equal(st.slot_idle_deadline[other], 0)


def test_the_linger_arms_once() raises:
    """Arm once, and that is the whole bound: the drain reaches its linger
    branches on every pass while a slot lingers, and re-stamping pushed the
    deadline out for good."""
    var st = _loop(_config())
    _arm_ws_linger(st, 1)
    var first = st.slot_idle_deadline[1]
    assert_true(first > 0)
    assert_true(first <= perf_counter_ns() + WS_CLOSE_LINGER_NS)
    assert_true(st.slot_ws_state[1].closing)
    # An armed linger is left alone. A sentinel rather than a second call's
    # clock: two reads of it nanoseconds apart can be one tick, and a
    # re-stamp would then look like arm-once (it did, on an M-series Mac).
    st.slot_idle_deadline[1] = 12345
    _arm_ws_linger(st, 1)
    assert_equal(st.slot_idle_deadline[1], 12345)


def test_a_request_begins_with_no_idle_deadline() raises:
    """B2: the keep-alive deadline bounds the wait BETWEEN requests, and a
    request's first bytes end it -- left standing it cut an upload begun
    late in the window at the previous response's deadline."""
    var st = _loop(_config())
    st.slot_idle_deadline[2] = perf_counter_ns() + 1_000_000_000
    _begin_request(st, 2)
    assert_equal(st.slot_idle_deadline[2], 0)


def test_the_keepalive_transition_owns_its_resets() raises:
    """`_end_request`: the next request's count, a clean provision, the
    header clock stopped until the next request's bytes, the idle deadline
    in place of any send deadline, and read interest back."""
    var backend = FakeBackend()
    var config = _config()
    var st = _loop(config)
    var slot = st.provision_pool.borrow()
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    st.slot_header_start[slot] = perf_counter_ns()
    st.slot_response[slot] = Bytes(String("HTTP/1.1 200 OK\r\n\r\n").as_bytes())
    st.slot_send_offset[slot] = len(st.slot_response[slot])
    assert_true(_await_write(backend, st, slot, FD))
    assert_false(st.slot_read_armed[slot])
    var before = perf_counter_ns()
    _end_request(backend, st, slot, FD)
    assert_equal(st.provision_pool.provisions[slot].keepalive_count, 1)
    assert_equal(st.provision_pool.provisions[slot].state.kind, ConnectionState.READING_HEADERS)
    assert_equal(st.slot_header_start[slot], 0)
    assert_equal(st.slot_send_offset[slot], 0)
    assert_equal(len(st.slot_response[slot]), 0)
    assert_true(st.slot_idle_deadline[slot] >= before + config.idle_timeout * 1_000_000_000)
    assert_true(backend.read)
    assert_true(st.slot_read_armed[slot])


def test_a_stream_is_recorded_once() raises:
    """R3: `_after_send` runs for every send that completes, a stream's
    frames included, and each was recorded as a response of its own -- a
    count, an access-log line and the stream's age as a latency sample. The
    head is the response; a frame after it records nothing."""
    var config = _config()
    config.enable_metrics = True
    var st = _loop(config)
    var slot = st.provision_pool.borrow()
    st.active_count = 1
    st.provision_pool.provisions[slot].response_status = 200
    st.slot_header_start[slot] = perf_counter_ns()
    st.slot_send_offset[slot] = 120
    _record_response(st, slot)
    assert_equal(st.metrics.requests_total, 1)
    assert_equal(st.metrics.latency_count, 1)
    st.slot_send_offset[slot] = 4096
    _record_response(st, slot)
    assert_equal(st.metrics.requests_total, 1)
    assert_equal(st.metrics.latency_count, 1)
    assert_equal(st.metrics.bytes_sent_total, 120)


def test_a_stale_body_expiry_is_retired() raises:
    """#412's retire, on its own: a body timer's expiry that reaches a slot
    no longer reading its body is DELETED, not only skipped. The body can
    complete in the `wait` that reports its timer, read first, and a slot
    whose request is out on a pool thread is not the timer's to end (B1's
    guard, both of its arms here). epoll's timerfd is level triggered and
    the loop never reads it, so an expiry left registered is reported by
    every wait after it, each returning at once. kqueue's timers are
    one-shots, so no macOS run could see it; the fake keeps them as epoll
    does. The slot itself is left alone, which is B1.

    covers: A23
    """
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(_config())
    var ident = UInt(FD) + TIMER_BODY
    for offloaded in range(2):
        var slot = st.provision_pool.borrow()
        st.slot_fds[slot] = FD
        st.fd_to_slot[FD] = slot
        if offloaded == 1:
            st.provision_pool.provisions[slot].state = ConnectionState.reading_body(64)
            st.offload.offloaded[slot] = True
        else:
            st.provision_pool.provisions[slot].state = ConnectionState.responding()
        backend.try_add_timer(ident, 30_000)
        backend.expire(ident)
        assert_equal(backend.wait(0), 1)
        assert_equal(backend.event_filter(0), EVFILT_TIMER)
        _on_timer(app, backend, st, backend.event_ident(0))
        assert_equal(st.slot_fds[slot], FD)
        assert_equal(
            backend.wait(0), 0,
            "a stale body expiry stayed registered: every wait reports it",
        )
        st.offload.offloaded[slot] = False
        st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
        st.slot_fds[slot] = UNUSED
        st.fd_to_slot[FD] = UNUSED
        st.provision_pool.release(slot)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
