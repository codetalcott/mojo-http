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

**The transitions** (`event_loop.mojo`'s "Per-slot lifecycle" section,
review record C4). Each helper owns the resets of its phase, which is what
makes a stale-state defect a helper's bug rather than one call site's. They
are driven here over `FakeBackend`, which keeps one socket's registration
the way epoll does -- ONE registration, so a read added replaces a pending
write -- the stricter of the two, and the one a wrong arm is wrong on.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from lightbug_http.c.kqueue import EVFILT_READ, EVFILT_WRITE
from lightbug_http.c.platform import PlatformBackend
from lightbug_http.c.socket import close, send
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.connection import ConnectionState
from lightbug_http.event_loop import (
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
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.io.bytes import Bytes
from lightbug_http.metrics import ServerMetrics
from lightbug_http.server import ProvisionPool
from lightbug_http.server_config import ServerConfig
from lightbug_http.websocket import WSState


struct FakeBackend(EventLoopBackend):
    """One socket's registration, kept as epoll keeps it: read and write
    interest are ONE registration, so adding reads replaces a pending write
    one-shot, registering the write one-shot replaces the reads, and a
    delete takes both."""

    var read: Bool
    var write: Bool
    var read_adds: Int

    def __init__(out self):
        self.read = False
        self.write = False
        self.read_adds = 0

    def wait(mut self, timeout_ms: Int) raises -> Int:
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
        pass

    def try_delete_timer(mut self, ident: UInt):
        pass


comptime SLOTS = 4
comptime FD = 7


struct Slots:
    """The loop's per-slot lists, as `prepare_loop` builds them."""

    var response: List[Bytes]
    var send_offset: List[Int]
    var header_start: List[Int]
    var sse: List[Bool]
    var ws: List[Bool]
    var read_armed: List[Bool]
    var deadline: List[Int]
    var ws_state: List[WSState]

    def __init__(out self):
        self.response = List[Bytes]()
        self.send_offset = List[Int]()
        self.header_start = List[Int]()
        self.sse = List[Bool]()
        self.ws = List[Bool]()
        self.read_armed = List[Bool]()
        self.deadline = List[Int]()
        self.ws_state = List[WSState]()
        for _ in range(SLOTS):
            self.response.append(Bytes())
            self.send_offset.append(0)
            self.header_start.append(0)
            self.sse.append(False)
            self.ws.append(False)
            self.read_armed.append(False)
            self.deadline.append(0)
            self.ws_state.append(WSState(1024))


def _config() -> ServerConfig:
    var config = ServerConfig()
    config.idle_timeout = 5
    config.sse_heartbeat_ms = 0
    return config^


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
    var config = _config()
    var pool = ProvisionPool(SLOTS, config)
    var slot = pool.borrow()
    var s = Slots()
    s.ws[slot] = True
    pool.provisions[slot].state = ConnectionState.streaming_ws()
    assert_true(_arm_reads(backend, slot, rx, s.read_armed, pool))
    _stop_reads(backend, slot, rx, s.read_armed)
    s.ws_state[slot].inbound_suspended = True
    pool.provisions[slot].state = ConnectionState.responding()
    assert_true(_await_write(backend, slot, rx, s.read_armed))

    s.ws_state[slot].inbound_suspended = False
    assert_true(_arm_reads(backend, slot, rx, s.read_armed, pool))
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
    var config = _config()
    var pool = ProvisionPool(SLOTS, config)
    var slot = pool.borrow()
    var s = Slots()
    s.ws[slot] = True
    pool.provisions[slot].state = ConnectionState.responding()
    assert_true(_await_write(backend, slot, FD, s.read_armed))
    assert_true(backend.write)
    assert_false(s.read_armed[slot])

    assert_true(_arm_reads(backend, slot, FD, s.read_armed, pool))
    assert_true(backend.write)
    assert_false(backend.read)
    assert_false(s.read_armed[slot])
    assert_equal(backend.read_adds, 0)

    _stream_idle(
        backend, slot, FD, config, s.response, s.send_offset, pool,
        s.ws, s.ws_state, s.read_armed, s.deadline,
    )
    assert_equal(pool.provisions[slot].state.kind, ConnectionState.STREAMING_WS)
    assert_true(backend.read)
    assert_true(s.read_armed[slot])


def test_the_linger_arms_once() raises:
    """Arm once, and that is the whole bound: the drain reaches its linger
    branches on every pass while a slot lingers, and re-stamping pushed the
    deadline out for good."""
    var s = Slots()
    _arm_ws_linger(1, s.ws_state, s.deadline)
    var first = s.deadline[1]
    assert_true(first > 0)
    assert_true(first <= perf_counter_ns() + WS_CLOSE_LINGER_NS)
    assert_true(s.ws_state[1].closing)
    _arm_ws_linger(1, s.ws_state, s.deadline)
    assert_equal(s.deadline[1], first)


def test_a_request_begins_with_no_idle_deadline() raises:
    """B2: the keep-alive deadline bounds the wait BETWEEN requests, and a
    request's first bytes end it -- left standing it cut an upload begun
    late in the window at the previous response's deadline."""
    var s = Slots()
    s.deadline[2] = perf_counter_ns() + 1_000_000_000
    _begin_request(2, s.deadline)
    assert_equal(s.deadline[2], 0)


def test_the_keepalive_transition_owns_its_resets() raises:
    """`_end_request`: the next request's count, a clean provision, the
    header clock stopped until the next request's bytes, the idle deadline
    in place of any send deadline, and read interest back."""
    var backend = FakeBackend()
    var config = _config()
    var pool = ProvisionPool(SLOTS, config)
    var slot = pool.borrow()
    var s = Slots()
    pool.provisions[slot].state = ConnectionState.responding()
    s.header_start[slot] = perf_counter_ns()
    s.response[slot] = Bytes(String("HTTP/1.1 200 OK\r\n\r\n").as_bytes())
    s.send_offset[slot] = len(s.response[slot])
    assert_true(_await_write(backend, slot, FD, s.read_armed))
    assert_false(s.read_armed[slot])
    var before = perf_counter_ns()
    _end_request(
        backend, slot, FD, config, s.response, s.send_offset, s.header_start,
        pool, s.read_armed, s.deadline,
    )
    assert_equal(pool.provisions[slot].keepalive_count, 1)
    assert_equal(pool.provisions[slot].state.kind, ConnectionState.READING_HEADERS)
    assert_equal(s.header_start[slot], 0)
    assert_equal(s.send_offset[slot], 0)
    assert_equal(len(s.response[slot]), 0)
    assert_true(s.deadline[slot] >= before + config.idle_timeout * 1_000_000_000)
    assert_true(backend.read)
    assert_true(s.read_armed[slot])


def test_a_stream_is_recorded_once() raises:
    """R3: `_after_send` runs for every send that completes, a stream's
    frames included, and each was recorded as a response of its own -- a
    count, an access-log line and the stream's age as a latency sample. The
    head is the response; a frame after it records nothing."""
    var config = _config()
    config.enable_metrics = True
    var pool = ProvisionPool(SLOTS, config)
    var slot = pool.borrow()
    var s = Slots()
    var metrics = ServerMetrics()
    pool.provisions[slot].response_status = 200
    s.header_start[slot] = perf_counter_ns()
    s.send_offset[slot] = 120
    _record_response(config, slot, s.send_offset, s.header_start, pool, 1, metrics)
    assert_equal(metrics.requests_total, 1)
    assert_equal(metrics.latency_count, 1)
    s.send_offset[slot] = 4096
    _record_response(config, slot, s.send_offset, s.header_start, pool, 1, metrics)
    assert_equal(metrics.requests_total, 1)
    assert_equal(metrics.latency_count, 1)
    assert_equal(metrics.bytes_sent_total, 120)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
