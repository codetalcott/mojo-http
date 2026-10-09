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
once. The close echo (review record R6) is driven over both: `FakeBackend`
for the registration it takes, and the real multiplexer for the events
that send it.
"""

from std.ffi import c_int, external_call, get_errno
from std.os import remove
from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.c.kqueue import (
    EV_EOF, EVFILT_READ, EVFILT_TIMER, EVFILT_WRITE,
)
from lightbug_http.c.fcntl import dup_cloexec, set_nonblocking
from lightbug_http.c.platform import MSG_DONTWAIT, PlatformBackend
from lightbug_http.c.process import getpid, ignore_sigpipe
from lightbug_http.c.socket import (
    SOL_SOCKET, SocketOption, close, recv, send, setsockopt,
)
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.connection import ConnectionState
from lightbug_http.loop.accept import _admit_connection
from lightbug_http.loop.offload import _run_inline
from lightbug_http.loop.request import _on_read
from lightbug_http.loop.response import _on_write
from lightbug_http.loop.streams import _read_websocket
from lightbug_http.websocket import (
    WS_OP_CLOSE, close_frame, encode_ws_frame_masked,
)
from lightbug_http.loop.state import (
    LoopState,
    SLOT_BUFFER_KEEP,
    TIMER_BODY,
    TIMER_SSE_HEARTBEAT,
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
    _ws_linger,
)
from lightbug_http.loop.state import _close_slot, _farewell_streams
from lightbug_http.websocket import WS_CLOSE_GOING_AWAY
from lightbug_http.c.socket import ShutdownOption, shutdown
from lightbug_http.loop.response import _finish_response, _owe_interim
from lightbug_http.loop.streams import _drain_outboxes
from lightbug_http.offload import OffloadPool, make_stream_ack_pair
from lightbug_http.loop.timers import _on_timer
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.io.bytes import Bytes
from lightbug_http.server_config import ServerConfig
from lightbug_http.uri import URI


struct FakeBackend(EventLoopBackend):
    """One socket's registration, kept as epoll keeps it: read and write
    interest are ONE registration, so adding reads replaces a pending write
    one-shot, registering the write one-shot replaces the reads, and a
    delete takes both.

    Timers are kept as epoll keeps a timerfd, too: registered with EPOLLIN
    and never read by the loop, one that has expired is readable -- level
    triggered -- so every `wait` reports it until it is deleted or re-armed.
    `expire` is the clock running out, and `refuse_write` a write
    registration the kernel refuses."""

    var read: Bool
    var write: Bool
    var refuse_write: Bool
    var read_adds: Int
    var timers: List[UInt]
    var expired: List[UInt]
    var fired: List[UInt]

    def __init__(out self):
        self.read = False
        self.write = False
        self.refuse_write = False
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
        if self.refuse_write:
            raise Error("add_write_oneshot: refused")
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
    _ = send(FileDescriptor(tx), one.as_bytes(), 0)

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


def test_a_close_landing_leaves_a_suspended_sockets_reads_alone() raises:
    """This side's Close has landed on a WebSocket whose inbound the
    handler had suspended: the slot lingers for the peer's Close, and its
    reads stay off until the handler resumes them (review record LF15).
    `_ws_linger` armed them, which `_stream_idle` had refused to do for
    the same socket since the inbound backpressure landed: the socket
    undid its own suspension, and the parked queue grew with whatever the
    client sent next. `take_ws_resumes` is the only thing that may re-arm
    a suspended slot.

    covers: I41
    """
    var backend = FakeBackend()
    var st = _loop(_config())
    var slot = st.provision_pool.borrow()
    st.slot_ws[slot] = True
    st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
    assert_true(_arm_reads(backend, st, slot, FD))
    _stop_reads(backend, st, slot, FD)
    st.slot_ws_state[slot].inbound_suspended = True
    # The Close goes out through the write-ready path, and lands.
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    assert_true(_await_write(backend, st, slot, FD))
    var adds = backend.read_adds
    _ws_linger(backend, st, slot, FD)
    assert_equal(st.provision_pool.provisions[slot].state.kind, ConnectionState.STREAMING_WS)
    assert_true(st.slot_ws_state[slot].closing)
    assert_true(st.slot_idle_deadline[slot] > 0)
    assert_equal(backend.read_adds, adds, "the linger re-armed a suspended socket's reads")
    assert_false(st.slot_read_armed[slot])

    # A socket that is not suspended lingers reading: the peer's Close is a
    # read.
    var other = st.provision_pool.borrow()
    st.slot_ws[other] = True
    st.provision_pool.provisions[other].state = ConnectionState.responding()
    _ws_linger(backend, st, other, FD)
    assert_true(st.slot_read_armed[other])
    assert_true(backend.read)


def test_a_closed_slot_lets_go_of_its_response() raises:
    """`_close_slot`, the one place every close goes through, releases the
    answer still owed (review record LF26): a client that vanished with a
    large response unsent held its buffer until the slot answered someone
    else."""
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(_config())
    var pair = _stream_pair()
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = pair[0]
    st.fd_to_slot[pair[0]] = slot
    st.active_count = 1
    st.slot_response[slot] = Bytes(length=1 << 20, fill=0x61)
    st.slot_send_offset[slot] = 4096
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    _close_slot(app, backend, st, slot, pair[0])
    assert_equal(st.slot_fds[slot], UNUSED)
    assert_equal(st.slot_response[slot].capacity(), 0, "the closed slot kept its response")
    assert_equal(st.slot_send_offset[slot], 0)
    close(FileDescriptor(pair[1]))


def _close_with_buffers(
    mut st: LoopState, recv_capacity: Int, encode_capacity: Int
) raises -> Int:
    """Open a connection on `st`, grow its receive and encode buffers to the
    capacities given, close it, and return its slot."""
    var app = NoApp()
    var backend = FakeBackend()
    var pair = _stream_pair()
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = pair[0]
    st.fd_to_slot[pair[0]] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].recv_buffer = Bytes(length=recv_capacity, fill=0x61)
    st.provision_pool.provisions[slot].encoding_buffer = Bytes(capacity=encode_capacity)
    _close_slot(app, backend, st, slot, pair[0])
    close(FileDescriptor(pair[1]))
    assert_equal(st.slot_fds[slot], UNUSED)
    return slot


def test_a_closed_slot_gives_back_a_grown_buffer() raises:
    """`_close_slot` gives back a receive or encode buffer a large request
    or response grew past `SLOT_BUFFER_KEEP` (review record LF25). Cleared,
    each kept its capacity, and a slot is never rebuilt: a burst of uploads
    stayed resident for the life of the process. The slot's next connection
    starts from one read, as its first did.

    covers: C17
    """
    var st = _loop(_config())
    var slot = _close_with_buffers(st, 4 << 20, 4 << 20)
    assert_equal(
        st.provision_pool.provisions[slot].recv_buffer.capacity(),
        st.provision_pool.buffer_size,
        "the closed slot kept its grown receive buffer",
    )
    assert_equal(len(st.provision_pool.provisions[slot].recv_buffer), 0)
    assert_equal(
        st.provision_pool.provisions[slot].encoding_buffer.capacity(),
        st.provision_pool.buffer_size,
        "the closed slot kept its grown encode buffer",
    )


def test_a_closed_slot_keeps_an_ordinary_buffer() raises:
    """At or under `SLOT_BUFFER_KEEP` the buffers stay, so ordinary requests
    and pages reuse them from one connection to the next."""
    var st = _loop(_config())
    var slot = _close_with_buffers(st, SLOT_BUFFER_KEEP, SLOT_BUFFER_KEEP)
    assert_equal(st.provision_pool.provisions[slot].recv_buffer.capacity(), SLOT_BUFFER_KEEP)
    assert_equal(len(st.provision_pool.provisions[slot].recv_buffer), 0)
    assert_equal(st.provision_pool.provisions[slot].encoding_buffer.capacity(), SLOT_BUFFER_KEEP)


def test_a_closed_slot_keeps_buffers_within_its_configured_size() raises:
    """A server configured to read more than `SLOT_BUFFER_KEEP` at a time
    gives every slot buffers that size from its first connection, and those
    are the slot's ordinary buffers: past `SLOT_BUFFER_KEEP` the threshold
    is the configured size, so a close does not trade each for a new one of
    the same size. Held with buffers between the two sizes, which a close
    must leave as they are; a replacement AT the configured size cannot be
    told from no replacement, since the allocator hands the block it just
    took back straight back (tried: the same address both ways)."""
    var config = _config()
    config.socket_buffer_size = 4 * SLOT_BUFFER_KEEP
    var st = _loop(config)
    var slot = _close_with_buffers(st, 2 * SLOT_BUFFER_KEEP, 2 * SLOT_BUFFER_KEEP)
    assert_equal(
        st.provision_pool.provisions[slot].recv_buffer.capacity(), 2 * SLOT_BUFFER_KEEP,
        "the close replaced a receive buffer within the configured size",
    )
    assert_equal(
        st.provision_pool.provisions[slot].encoding_buffer.capacity(), 2 * SLOT_BUFFER_KEEP,
        "the close replaced an encode buffer within the configured size",
    )


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


def test_a_file_body_is_counted_as_sent() raises:
    """A body sent with `sendfile` never enters `slot_response`, so the bytes
    sent counted its head alone: every static file was missing from
    `http_bytes_sent_total`, and the access log's `bytes` read the same
    buffer. The metrics count head and body; the log reads the body, which
    `_finish_response` records with the status."""
    var config = _config()
    config.enable_metrics = True
    var st = _loop(config)
    var slot = st.provision_pool.borrow()
    st.active_count = 1
    st.provision_pool.provisions[slot].response_status = 200
    st.provision_pool.provisions[slot].response_body_len = 5000
    st.provision_pool.provisions[slot].response_file_len = 5000
    st.slot_header_start[slot] = perf_counter_ns()
    st.slot_send_offset[slot] = 180
    _record_response(st, slot)
    assert_equal(st.metrics.bytes_sent_total, 5180)


# Larger than either kernel's buffers for an `AF_UNIX` stream pair, so the
# transfer stops part way with the file still owed.
comptime FILE_BYTES = 4 << 20


def test_a_file_that_ends_early_closes_its_connection() raises:
    """A file body that ends before the length its head promised closes the
    connection on the next write event, rather than waiting for room on a
    socket that has it for bytes the file no longer holds.

    The head and the first part of a large file go out until the socket is
    full; the file is then truncated where the transfer has got to, and
    the peer reads. `sendfile` finds the end of the file, and used to
    report it as no progress, which the pump took for a full socket
    (`BODY_FD_MORE`): the write one-shot was re-armed and fired at once,
    pass after pass, moving nothing and so refreshing no deadline, until
    the idle timeout reaped the slot, and for good with idle timeouts off
    (review record LF16). Nothing can finish the response honestly, so the
    connection closes, and the peer reads EOF where the bytes ran out.
    Over this OS's multiplexer, so the spin is the real one.

    covers: J15
    """
    var path = String("/tmp/m0_lifecycle_truncated_body_") + String(getpid())
    try:
        _send_a_file_that_ends_early(path)
    finally:
        # Every path, a failing assertion's included: the file is 4 MB.
        try:
            remove(path)
        except:
            pass


def _send_a_file_that_ends_early(path: String) raises:
    """The round above, over the file at `path`, which its caller removes."""
    with open(path, "w") as f:
        f.write(String("b") * FILE_BYTES)
    var file = open(path, "r")
    var body_fd = dup_cloexec(Int(file._get_raw_fd()))
    file.close()

    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var app = NoApp()
    var backend = PlatformBackend()
    var st = _loop(_config())
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    var head = String("HTTP/1.1 200 OK\r\nContent-Length: ") + String(
        FILE_BYTES
    ) + "\r\n\r\n"
    st.slot_response[slot] = Bytes(head.as_bytes())
    st.slot_send_offset[slot] = 0
    st.provision_pool.provisions[slot].body_fd = body_fd
    st.provision_pool.provisions[slot].body_fd_offset = 0
    st.provision_pool.provisions[slot].body_fd_remaining = FILE_BYTES
    st.provision_pool.provisions[slot].state = ConnectionState.responding()

    _on_write(app, backend, st, fd)
    var sent_of_file = st.provision_pool.provisions[slot].body_fd_offset
    assert_equal(st.slot_fds[slot], fd, "the transfer ended before the socket filled")
    assert_true(sent_of_file > 0)
    assert_true(sent_of_file < FILE_BYTES)

    # The file now ends where the transfer has got to.
    with open(path, "w") as f:
        f.write(String("b") * sent_of_file)
    var got = List[UInt8]()
    var eof = _read_available(peer, got)
    assert_false(eof)

    var writable = 0
    while st.slot_fds[slot] != UNUSED and writable < 50:
        var n = backend.wait(1000)
        var reported = False
        for i in range(n):
            if (
                Int(backend.event_ident(i)) == fd
                and backend.event_filter(i) == EVFILT_WRITE
            ):
                reported = True
        if not reported:
            break
        writable += 1
        _on_write(app, backend, st, fd)
    assert_equal(
        st.slot_fds[slot], UNUSED,
        String("a file that ended early left its slot waiting to write: ")
        + "reported writable " + String(writable) + " times, moving nothing",
    )
    assert_equal(writable, 1)
    assert_true(_read_available(peer, got), "the peer read no EOF")
    assert_equal(len(got), head.byte_length() + sent_of_file)
    close(FileDescriptor(peer))


def _exchange(
    parts: List[String], metrics: Bool = False
) raises -> Tuple[String, Bool]:
    """Send `parts` to a slot reading headers, one write and one `_on_read`
    apiece, over a real stream pair: the reply as the client read it,
    lowercased, and whether the loop closed the slot behind it. `NoApp`
    answers whatever reaches it with a 200 saying `unused`."""
    var config = _config()
    config.enable_metrics = metrics
    var app = NoApp()
    return _exchange_with(app, config, parts)


def _exchange_with[H: HTTPService](
    mut app: H, config: ServerConfig, parts: List[String]
) raises -> Tuple[String, Bool]:
    """`_exchange` over a handler and a configuration of the caller's."""
    var backend = FakeBackend()
    var st = _loop(config)
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    for part in parts:
        if st.slot_fds[slot] == UNUSED:
            break
        var raw = part.as_bytes()
        var sent = send(FileDescriptor(peer), raw, 0)
        assert_equal(Int(sent), len(raw))
        _on_read(app, backend, st, fd, False)
    var got = List[UInt8]()
    _ = _read_available(peer, got)
    var closed = st.slot_fds[slot] == UNUSED
    if not closed:
        close(FileDescriptor(fd))
    close(FileDescriptor(peer))
    return (String(unsafe_from_utf8=Span(got)).lower(), closed)


def _metrics_exchange(request: String) raises -> Tuple[String, Bool]:
    """One request to `/__metrics`, metrics on (`_exchange`)."""
    return _exchange([request], metrics=True)


struct BodyLength(HTTPService):
    """Answers every request with the length of the body it was handed."""

    def __init__(out self):
        pass

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK(String("body=", len(req.body_raw)), "text/plain")


def _answers(reply: String) -> Int:
    """How many `200 OK` answers a lowercased reply holds."""
    return len(reply.split("http/1.1 200 ok")) - 1


def _tight_caps() -> ServerConfig:
    """Caps a test can reach: a head of at most 128 bytes, a body of at
    most 64, and no floor under the receive buffer, whose limit is then
    their sum."""
    var config = _config()
    config.max_total_header_size = 128
    config.max_request_body_size = 64
    config.recv_buffer_max = 0
    return config^


def _padded_head(start: String, length: Int) -> String:
    """`start`'s field lines, then an `X-Pad` field making the head
    `length` bytes long."""
    var head = start + "X-Pad: "
    return head + String("p") * (length - head.byte_length() - 4) + "\r\n\r\n"


def test_a_body_read_after_its_head_is_measured_by_its_own_sizes() raises:
    """A body read after its head is measured by its own sizes, never by
    the receive buffer that holds it (review record LF70): within both caps
    it is answered whatever shares the reads that bring it, and over the
    body cap it is refused 413 and lingered (SPEC A20) whatever its head's
    size. The body path compared the whole buffer, which holds the head and
    the next pipelined request beside the body, with `recv_buffer_limit()`,
    and measured a chunked body before decoding it, as its decoded part
    plus the raw tail still buffered: a `Content-Length` body whose last
    read also brought the next request was refused 400 once head, body and
    that request passed the buffer's limit; a chunked body at the cap was
    refused 413 when its framing, or a request behind it, came after its
    head, and answered when it came with it; and a chunked body over the
    cap behind a head near its own cap was refused 400 and closed. Each is
    measured now as the head path measures a body that arrives with it:
    the decoded body, and the raw bytes it cost. The head path still holds
    its whole buffer to the limit, so the same shapes sent in ONE read past
    it are refused 400 (review record LF72's residual).

    covers: C18
    """
    var config = _tight_caps()
    assert_equal(config.recv_buffer_limit(), 192)
    var app = BodyLength()
    var next = String("GET /b HTTP/1.1\r\nHost: x\r\n\r\n")

    var cl_head = _padded_head(
        "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 64\r\n", 120
    )
    var cl = _exchange_with(app, config, [cl_head, String("b") * 64 + next])
    assert_equal(_answers(cl[0]), 2, "a Content-Length body at the cap: " + cl[0])
    assert_true("body=64" in cl[0], cl[0])
    assert_false(cl[1], "the connection closed behind a body within the caps")

    var chunked = String(
        "POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    var at_cap = String("40\r\n") + String("b") * 64 + "\r\n0\r\n\r\n"
    var with_head = _exchange_with(app, config, [chunked + at_cap])
    assert_equal(_answers(with_head[0]), 1, "with its head: " + with_head[0])
    assert_true("body=64" in with_head[0], with_head[0])
    var after_head = _exchange_with(app, config, [chunked, at_cap])
    assert_equal(
        _answers(after_head[0]), 1,
        "a chunked body at the cap after its head: " + after_head[0],
    )
    assert_true("body=64" in after_head[0], after_head[0])

    var under = String("32\r\n") + String("b") * 50 + "\r\n0\r\n\r\n"
    var behind = _exchange_with(app, config, [chunked, under + next])
    assert_equal(
        _answers(behind[0]), 2,
        "a chunked body under the cap with a request behind it: " + behind[0],
    )
    assert_true("body=50" in behind[0], behind[0])

    var big_head = _padded_head(
        "POST /d HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n", 120
    )
    var over = _exchange_with(
        app, config, [big_head, String("50\r\n") + String("b") * 80 + "\r\n"]
    )
    assert_true(
        "413 payload too large" in over[0],
        "a chunked body over the cap behind a long head: " + over[0],
    )
    assert_false(over[1], "the 413 closed its connection where it should linger")


def test_a_chunk_line_that_never_ends_is_refused_at_twice_the_cap() raises:
    """A chunked body's receive buffer is bounded by its decoder consuming
    every byte it is handed: answering "incomplete", it leaves nothing
    undecoded (`pending_bytes` 0), so the buffer holds the head and the
    decoded body and no more, and what a line that never ends costs is
    counted in `_total_read` and refused 413, with the lingering close, at
    twice the body cap (C3). Since review record LF70 the body path
    compares no buffer size with any limit, so this is the bound: a decoder
    that kept an unfinished extension or size line back in the buffer
    would let it grow with no check firing, its decoded size and consumed
    bytes both flat. An extension that never reaches its CR, and a size
    line of leading zeros that never ends, each sent a read at a time
    after the head.

    covers: C18
    """
    var config = _tight_caps()
    var cap = config.max_request_body_size
    var head = String(
        "POST /e HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    for extension in [True, False]:
        var opening = String("5;ext=") if extension else String("")
        var fill = String("e") if extension else String("0")
        var app = NoApp()
        var backend = FakeBackend()
        var st = _loop(config)
        var pair = _stream_pair()
        var slot = st.provision_pool.borrow()
        st.slot_fds[slot] = pair[0]
        st.fd_to_slot[pair[0]] = slot
        st.active_count = 1
        st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
        _send_all(pair[1], head)
        _on_read(app, backend, st, pair[0], False)
        assert_equal(
            st.provision_pool.provisions[slot].state.kind,
            ConnectionState.READING_BODY,
        )
        var head_len = len(st.provision_pool.provisions[slot].recv_buffer)
        var sent = 0
        var refused = False
        for i in range(20):
            var piece = (opening if i == 0 else String("")) + fill * 40
            _send_all(pair[1], piece)
            sent += piece.byte_length()
            _on_read(app, backend, st, pair[0], False)
            if (
                st.provision_pool.provisions[slot].state.kind
                != ConnectionState.READING_BODY
            ):
                refused = True
                break
            assert_equal(
                st.provision_pool.provisions[slot].chunk_decoder.pending_bytes, 0,
                "the decoder left an unfinished line undecoded",
            )
            assert_equal(
                len(st.provision_pool.provisions[slot].recv_buffer), head_len,
                "an unfinished line stayed in the receive buffer",
            )
        assert_true(refused, "a line that never ends was never refused")
        assert_true(
            sent <= 2 * cap + opening.byte_length() + 40,
            String("refused only after ", sent, " bytes"),
        )
        var got = List[UInt8]()
        _ = _read_available(pair[1], got)
        var reply = String(unsafe_from_utf8=Span(got)).lower()
        assert_true(reply.startswith("http/1.1 413 payload too large"), reply)
        assert_true(st.slot_fds[slot] != UNUSED, "the 413 closed its connection where it should linger")
        _close_slot(app, backend, st, slot, pair[0])
        close(FileDescriptor(pair[1]))


struct Raises(HTTPService):
    """A handler with a bug: every request it is handed raises."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.calls += 1
        raise Error("the handler's own bug")


def test_a_handler_that_raises_is_answered_500_and_closed() raises:
    """A handler that raises is answered 500 with `Connection: close`, and
    the connection closes behind it, whether the loop ran it as its request
    arrived (`_process_request`) or inline, for a submit batch that could
    not carry it (`_run_inline`): what it raised is the application's, and
    the connection's state after it is not to be trusted. A request
    pipelined behind it is not run.

    covers: A39
    """
    var app = Raises()
    var got = _exchange_with(app, _config(), [
        "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"
    ])
    assert_true(got[0].startswith("http/1.1 500 internal server error"), got[0])
    assert_true("connection: close" in got[0], got[0])
    assert_equal(len(got[0].split("http/1.1 ")) - 1, 1, got[0])
    assert_true(got[1], "the connection stayed open after the 500")
    assert_equal(app.calls, 1, "the request behind the 500 was run")

    var pool = OffloadPool(SLOTS)
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), True, offload_addr=pool.addr()
    )
    var backend = FakeBackend()
    var inline = Raises()
    var pair = _stream_pair()
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = pair[0]
    st.fd_to_slot[pair[0]] = slot
    st.active_count = 1
    pool.park_request(slot, HTTPRequest(URI.parse("http://127.0.0.1/x")))
    st.offload.offloaded[slot] = True
    st.offload.inflight += 1
    var slots = List[Int]()
    slots.append(slot)
    assert_equal(_run_inline(inline, backend, st, slots), 1)
    var reply = List[UInt8]()
    _ = _read_available(pair[1], reply)
    var text = String(unsafe_from_utf8=Span(reply)).lower()
    assert_true(text.startswith("http/1.1 500 internal server error"), text)
    assert_true("connection: close" in text, text)
    assert_equal(st.slot_fds[slot], UNUSED, "the inline run's connection stayed open")
    close(FileDescriptor(pair[1]))
    # `pool` must outlive the loop state that holds its address.
    _ = pool.capacity


def test_a_head_still_arriving_past_its_timeout_is_answered_408_at_its_next_read() raises:
    """The header timeout is met at a read as well as by the once-a-second
    sweep: a head whose first bytes came longer ago than
    `header_read_timeout` is answered 408 with `Connection: close` at the
    read that brings more of it, rather than served late; the same head
    completed in time is answered. The sweep's half is
    `Smoke test the header read timeout` (A5).

    The 408 goes out with the lingering close a 413 gets (A20): the write
    side shut behind it, what the client still sends read and discarded,
    and the connection closed once the client closes. The check comes
    before the read, so the rest of the head is in the socket, and closing
    over it reset the connection: on Linux the client's read failed
    ECONNRESET, the 408 lost (review record LF75; macOS's AF_UNIX sockets
    do not reset, a TCP connection does on both).

    covers: A5
    """
    var config = _config()
    config.header_read_timeout = 1
    for late in [False, True]:
        var app = NoApp()
        var backend = FakeBackend()
        var st = _loop(config)
        var pair = _stream_pair()
        var slot = st.provision_pool.borrow()
        st.slot_fds[slot] = pair[0]
        st.fd_to_slot[pair[0]] = slot
        st.active_count = 1
        st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
        _send_all(pair[1], "GET / HTTP/1.1\r\n")
        _on_read(app, backend, st, pair[0], False)
        assert_true(st.slot_header_start[slot] > 0, "the head's first bytes were not stamped")
        if late:
            st.slot_header_start[slot] -= 2_000_000_000
        _send_all(pair[1], "Host: x\r\n\r\n")
        _on_read(app, backend, st, pair[0], False)
        var got = List[UInt8]()
        var eof = _read_available(pair[1], got)
        var reply = String(unsafe_from_utf8=Span(got)).lower()
        if late:
            assert_true(reply.startswith("http/1.1 408 request timeout"), reply)
            assert_true("connection: close" in reply, reply)
            assert_true(eof, "the 408 was not followed by the server's FIN")
            assert_equal(
                st.provision_pool.provisions[slot].state.kind,
                ConnectionState.LINGERING,
                "a head past its timeout was closed, not lingered",
            )
            # The client closes; the linger's read sees it and closes too.
            close(FileDescriptor(pair[1]))
            _on_read(app, backend, st, pair[0], True)
            assert_equal(
                st.slot_fds[slot], UNUSED, "the linger outlived its client"
            )
        else:
            assert_true(reply.startswith("http/1.1 200 ok"), reply)
            close(FileDescriptor(pair[0]))
            close(FileDescriptor(pair[1]))


def test_a_new_loop_has_every_slot_free_and_ignores_descriptors_it_does_not_hold() raises:
    """`LoopState`'s constructor: `max_connections` slots, each free -- no
    descriptor, response, stream, read interest or deadline -- every one in
    the pool, a descriptor map of 65536 numbers none of which is mapped,
    and the server's address split once. A read or write event for a
    descriptor no slot holds, whether mapped or past the map, is dropped
    without touching a slot or the backend."""
    var st = LoopState(
        FileDescriptor(-1), _config(), String("127.0.0.1:8080"), True,
        shutdown_read_fd=5,
    )
    assert_equal(st.max_conns, SLOTS)
    assert_equal(st.provision_pool.available_count(), SLOTS)
    assert_equal(st.metrics.pool_capacity, SLOTS)
    assert_equal(st.active_count, 0)
    assert_equal(st.shutdown_read_fd, 5)
    assert_equal(st.server_host, "127.0.0.1")
    assert_equal(Int(st.server_port.value()), 8080)
    for slot in range(SLOTS):
        assert_equal(st.slot_fds[slot], UNUSED)
        assert_equal(len(st.slot_response[slot]), 0)
        assert_equal(st.slot_send_offset[slot], 0)
        assert_equal(st.slot_header_start[slot], 0)
        assert_false(st.slot_sse[slot])
        assert_false(st.slot_ws[slot])
        assert_false(st.slot_read_armed[slot])
        assert_equal(st.slot_idle_deadline[slot], 0)
    assert_equal(len(st.fd_to_slot), 65536)
    var mapped = 0
    for fd in range(len(st.fd_to_slot)):
        if st.fd_to_slot[fd] != UNUSED:
            mapped += 1
    assert_equal(mapped, 0)

    var app = NoApp()
    var backend = FakeBackend()
    var past = len(st.fd_to_slot) + 1
    _on_read(app, backend, st, FD, True)
    _on_read(app, backend, st, past, True)
    _on_write(app, backend, st, FD)
    _on_write(app, backend, st, past)
    assert_equal(st.active_count, 0)
    assert_equal(st.provision_pool.available_count(), SLOTS)
    assert_false(backend.read)
    assert_false(backend.write)
    assert_equal(backend.read_adds, 0)


struct Departures(HTTPService):
    """Records the slots its streams left from."""

    var left: List[Int]

    def __init__(out self):
        self.left = List[Int]()

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("unused", "text/plain")

    def sse_slot_disconnected(mut self, slot: Int):
        self.left.append(slot)


def _stream_slot(mut st: LoopState, fd: Int, ws: Bool) raises -> Int:
    """A slot holding `fd` as an idle stream: a WebSocket, or SSE."""
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count += 1
    if ws:
        st.slot_ws[slot] = True
        st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
    else:
        st.slot_sse[slot] = True
        st.provision_pool.provisions[slot].state = ConnectionState.streaming_sse()
    return slot


def test_a_closed_stream_tells_its_handler_once_and_retires_its_timers() raises:
    """`_close_slot`, the door every close goes through, tells the handler
    which slot left when it held a stream, SSE or WebSocket, once, so a
    subscriber registry drops it; and for every connection deletes its
    read and write registrations and both timers a connection can hold,
    its body timer and its heartbeat, closes the descriptor (the peer
    reads EOF), unmaps it and gives the slot back. An ordinary
    connection's close tells the handler nothing.

    covers: I9
    """
    var app = Departures()
    var backend = FakeBackend()
    var st = _loop(_config())
    for ws in [False, True]:
        var pair = _stream_pair()
        var fd = pair[0]
        var slot = _stream_slot(st, fd, ws)
        assert_true(_arm_reads(backend, st, slot, fd))
        backend.try_add_timer(UInt(fd) + TIMER_BODY, 1000)
        backend.try_add_timer(UInt(fd) + TIMER_SSE_HEARTBEAT, 1000)
        var free = st.provision_pool.available_count()
        var left = len(app.left)
        _close_slot(app, backend, st, slot, fd)
        assert_equal(len(app.left), left + 1, "the handler was not told its stream left")
        assert_equal(app.left[left], slot)
        assert_false(st.slot_sse[slot] or st.slot_ws[slot])
        assert_equal(len(backend.timers), 0, "a timer outlived its connection")
        assert_false(backend.read)
        assert_false(backend.write)
        assert_equal(st.slot_fds[slot], UNUSED)
        assert_equal(st.fd_to_slot[fd], UNUSED)
        assert_equal(st.active_count, 0)
        assert_equal(st.provision_pool.available_count(), free + 1)
        var got = List[UInt8]()
        assert_true(_read_available(pair[1], got), "the peer read no EOF")
        close(FileDescriptor(pair[1]))

    var plain = _stream_pair()
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = plain[0]
    st.fd_to_slot[plain[0]] = slot
    st.active_count = 1
    _close_slot(app, backend, st, slot, plain[0])
    assert_equal(len(app.left), 2, "an ordinary connection's close told the handler a stream left")
    close(FileDescriptor(plain[1]))


def test_a_heartbeat_rearms_first_writes_its_frame_and_ends_a_dead_stream() raises:
    """A stream's heartbeat (`_heartbeat`, which `_on_timer` hands every
    ident from `TIMER_SSE_HEARTBEAT` up to the app tick's): re-armed before
    anything else, both backends' timers being one-shots, so a beat
    skipped for a stream that may not take a frame now (a WebSocket
    lingering after its Close) still leaves the next armed; an SSE stream
    sent the comment `: heartbeat` and a WebSocket a ping, the slot idle
    again once it has gone out; a stream whose client has gone closed by
    the send that fails, its handler told; and a heartbeat whose
    descriptor holds no stream any more retired, not re-armed.

    covers: I3, I9
    """
    ignore_sigpipe()
    var app = Departures()
    var backend = FakeBackend()
    var st = _loop(_config())

    var sse = _stream_pair()
    var sse_slot = _stream_slot(st, sse[0], False)
    var sse_beat = TIMER_SSE_HEARTBEAT + UInt(sse[0])
    _on_timer(app, backend, st, sse_beat)
    assert_true(sse_beat in backend.timers, "the heartbeat was not re-armed")
    var comment = List[UInt8]()
    _ = _read_available(sse[1], comment)
    assert_equal(String(unsafe_from_utf8=Span(comment)), ": heartbeat\n\n")
    assert_equal(
        st.provision_pool.provisions[sse_slot].state.kind,
        ConnectionState.STREAMING_SSE,
    )

    var ws = _stream_pair()
    var ws_slot = _stream_slot(st, ws[0], True)
    _on_timer(app, backend, st, TIMER_SSE_HEARTBEAT + UInt(ws[0]))
    var ping = List[UInt8]()
    _ = _read_available(ws[1], ping)
    assert_equal(len(ping), 4, "not a two-byte ping")
    assert_equal(Int(ping[0]), 0x89, "not a final ping frame")
    assert_equal(Int(ping[1]), 2)
    assert_equal(
        st.provision_pool.provisions[ws_slot].state.kind,
        ConnectionState.STREAMING_WS,
    )

    # A WebSocket lingering after its own Close takes no frame it did not
    # write (L29): the beat is skipped, and its timer re-armed all the same,
    # so the stream's heartbeats go on once it may take one.
    st.slot_ws_state[ws_slot].closing = True
    var ws_beat = TIMER_SSE_HEARTBEAT + UInt(ws[0])
    backend.try_delete_timer(ws_beat)
    _on_timer(app, backend, st, ws_beat)
    assert_true(ws_beat in backend.timers, "a skipped beat was not re-armed")
    var nothing = List[UInt8]()
    _ = _read_available(ws[1], nothing)
    assert_equal(len(nothing), 0, "a frame went to a socket lingering after its Close")

    # The SSE stream's client leaves without a word.
    close(FileDescriptor(sse[1]))
    _on_timer(app, backend, st, sse_beat)
    assert_equal(st.slot_fds[sse_slot], UNUSED, "a heartbeat to a client that left kept its stream")
    assert_equal(len(app.left), 1)
    assert_equal(app.left[0], sse_slot)
    assert_false(sse_beat in backend.timers, "the closed stream's heartbeat outlived it")

    # Its descriptor holds no stream now: a beat still pending is retired.
    backend.try_add_timer(sse_beat, 1000)
    _on_timer(app, backend, st, sse_beat)
    assert_false(sse_beat in backend.timers, "a heartbeat for no stream was re-armed")
    _close_slot(app, backend, st, ws_slot, ws[0])
    close(FileDescriptor(ws[1]))


def test_admission_takes_what_the_pool_has_room_for_and_maps_any_descriptor() raises:
    """`_admit_connection` takes a connection into a free slot and nothing
    else: one past the last slot is closed unanswered, holding nothing; a
    descriptor that is not open is refused at the non-blocking flag, its
    slot given back; and a descriptor past the end of the descriptor map
    grows the map to hold it, as one at or above 65536 needs.

    covers: A40
    """
    var config = _config()
    config.max_connections = 1
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(config)
    st.fd_to_slot.resize(4, UNUSED)

    var first = _stream_pair()
    assert_true(first[0] >= 4)
    _admit_connection(app, backend, st, first[0], String("127.0.0.1"), 1)
    assert_equal(st.active_count, 1)
    assert_true(len(st.fd_to_slot) > first[0], "the map did not grow to the descriptor")
    var slot = st.fd_to_slot[first[0]]
    assert_true(slot != UNUSED, "a descriptor past the map was not mapped")
    assert_equal(st.slot_fds[slot], first[0])

    var second = _stream_pair()
    _admit_connection(app, backend, st, second[0], String("127.0.0.1"), 2)
    assert_equal(st.active_count, 1, "a connection past the last slot was admitted")
    var got = List[UInt8]()
    assert_true(_read_available(second[1], got), "a connection past the last slot was left open")
    assert_equal(len(got), 0)
    close(FileDescriptor(second[1]))

    _close_slot(app, backend, st, slot, first[0])
    close(FileDescriptor(first[1]))
    var gone = _stream_pair()
    close(FileDescriptor(gone[0]))
    _admit_connection(app, backend, st, gone[0], String("127.0.0.1"), 3)
    assert_equal(st.active_count, 0, "a descriptor that is not open was admitted")
    assert_equal(st.provision_pool.available_count(), 1, "the refused descriptor kept its slot")
    close(FileDescriptor(gone[1]))


def test_a_response_whose_write_wait_is_refused_closes_its_connection() raises:
    """`_await_write` answers False when the backend refuses the write
    one-shot, the slot's read interest counted gone as on success; and a
    response that could not go out whole then closes its connection
    (`_finish_response`) rather than wait on an event nothing will
    report."""
    var backend = FakeBackend()
    backend.refuse_write = True
    var st = _loop(_config())
    var slot = st.provision_pool.borrow()
    assert_true(_arm_reads(backend, st, slot, FD))
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    assert_false(_await_write(backend, st, slot, FD))
    assert_false(st.slot_read_armed[slot])
    st.provision_pool.release(slot)

    var app = NoApp()
    var pair = _stream_pair()
    var other = st.provision_pool.borrow()
    st.slot_fds[other] = pair[0]
    st.fd_to_slot[pair[0]] = other
    st.active_count = 1
    _ = _fill_send_buffer(pair[0])
    _finish_response(app, backend, st, other, pair[0], OK("unsent", "text/plain"))
    assert_equal(st.slot_fds[other], UNUSED, "a response that could not wait kept its connection")
    _discard_all(pair[1])
    close(FileDescriptor(pair[1]))


def test_connect_is_answered_501_and_closed() raises:
    """CONNECT is refused before the application: 501, `Connection: close`
    and the slot closed, where `NoApp` -- like any application answering
    every method -- answered it 200, which a front end forwarding it reads
    as an open tunnel. A malformed request stays 400.

    covers: B18
    """
    var got = _exchange(["CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\n\r\n"])
    assert_true("501 not implemented" in got[0], got[0])
    assert_true("connection: close" in got[0], got[0])
    assert_false("unused" in got[0], got[0])
    assert_true(got[1], "the slot stayed open after the 501")
    var bad = _exchange(["GET / HTTP/1.1\r\nHost: h\r\nHost: i\r\n\r\n"])
    assert_true("400 bad request" in bad[0], bad[0])
    assert_true(bad[1], "the slot stayed open after the 400")


def test_a_transfer_coding_it_cannot_decode_is_answered_501_and_closed() raises:
    """A body in a coding the loop does not decode, before a final
    `chunked`, is refused 501 and the connection closed, the body unread
    (RFC 9112 §6.1). `gzip, chunked` was de-chunked and served, the
    application reading a body still gzipped. Where `chunked` is not final
    -- a lone `gzip`, `chunked, gzip` -- the framing is undeterminable and
    the answer is 400 and a close (RFC 9112 §6.3).

    covers: B21
    """
    var gz = _exchange([
        "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
        "5\r\nhello\r\n0\r\n\r\n"
    ])
    assert_true("501 not implemented" in gz[0], gz[0])
    assert_true("connection: close" in gz[0], gz[0])
    assert_false("unused" in gz[0], gz[0])
    assert_true(gz[1], "the slot stayed open after the 501")
    var lone = _exchange([
        "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\nhello"
    ])
    assert_true("400 bad request" in lone[0], lone[0])
    assert_true(lone[1], "the slot stayed open after the 400")
    var misplaced = _exchange([
        "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"
    ])
    assert_true("400 bad request" in misplaced[0], misplaced[0])
    assert_true(misplaced[1], "the slot stayed open after the 400")


def test_a_close_on_either_connection_line_closes() raises:
    """Two `Connection` field lines are one list (RFC 9110 §5.3), so the
    loop closes behind the answer whichever line says `close`. The store
    kept the last line, and `close` then `keep-alive` kept the connection.

    covers: B22
    """
    var first = _exchange([
        "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n"
        "Connection: keep-alive\r\n\r\n"
    ])
    assert_true("200 ok" in first[0], first[0])
    assert_true("connection: close" in first[0], first[0])
    assert_true(first[1], "the slot stayed open after a first-line close")
    var plain = _exchange([
        "GET / HTTP/1.1\r\nHost: h\r\nConnection: keep-alive\r\n"
        "Connection: TE\r\n\r\n"
    ])
    assert_false(plain[1], "a request asking no close was closed")


def test_a_bare_lf_in_a_head_still_arriving_is_answered_400_at_once() raises:
    """A bare LF in a request head can only be refused (SPEC B12), but the
    parser runs once `find_header_end` frames a head by its CRLFCRLF, and a
    head of bare LFs holds none: it went unanswered until its peer's EOF
    or the header timeout's 408. It is refused at the read that brings
    it, in whichever read that is and past the 64-byte scan. A CR that
    ends one read and the LF that opens the next are a CRLF, and a head
    of CRLFs still arriving is waited for.

    covers: B23
    """
    for shape in [
        "GET / HTTP/1.1\nHost: x\n\n",
        "\n\n\n",
        "GET / HTTP/1.1\n",
        "GET / HTTP/1.1\r\nX-Pad: " + String("p") * 100 + "\nHost: x",
    ]:
        var got = _exchange([shape])
        assert_true("400 bad request" in got[0], shape + ": " + got[0])
        assert_true("connection: close" in got[0], got[0])
        assert_true(got[1], "the slot stayed open after the 400: " + shape)
    var later = _exchange(["GET / HTTP/1.1\r\n", "Host: x\n"])
    assert_true("400 bad request" in later[0], later[0])
    assert_true(later[1], "the slot stayed open after a later read's bare LF")
    var split = _exchange(["GET / HTTP/1.1\r", "\nHost: x\r\n"])
    assert_equal(split[0], "", "a CRLF split across two reads was answered")
    assert_false(split[1], "a CRLF split across two reads was closed")
    var long = _exchange([
        "GET / HTTP/1.1\r\nX-Pad: " + String("p") * 150 + "\r\n", "Host: x\r\n"
    ])
    assert_equal(long[0], "", "a long head of CRLFs still arriving was answered")
    assert_false(long[1], "a long head of CRLFs still arriving was closed")


def test_empty_lines_before_a_request_are_answered_alike_split_or_whole() raises:
    """Two empty lines and then a request are refused 400 in one read, and
    in two reads however the first ended. The loop tells the framer how
    much it scanned, and the terminator search began there when that was
    one to three bytes, so it missed the CRLFCRLF the empty lines make and
    served the request behind them (review record LF66). One empty line is
    skipped, split or whole (RFC 9112 §2.2).

    covers: B29
    """
    var request = String("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    var whole = _exchange(["\r\n\r\n" + request])
    assert_true("400 bad request" in whole[0], whole[0])
    assert_true(whole[1], "the slot stayed open after the 400")
    var empty_lines = String("\r\n\r\n")
    for n in range(1, 4):
        var first = String(unsafe_from_utf8=empty_lines.as_bytes()[:n])
        var rest = String(unsafe_from_utf8=empty_lines.as_bytes()[n:])
        var split = _exchange([first, rest + request])
        assert_true(
            "400 bad request" in split[0],
            String("a first read of ", n, " bytes: ", split[0]),
        )
        assert_true(split[1], "the slot stayed open after the 400")
    var one = _exchange(["\r\n", request])
    assert_true("200 ok" in one[0], one[0])


def test_the_metrics_path_honours_a_requested_close() raises:
    """`/__metrics` is answered by the loop itself, and its branch reset
    `should_close` to False after the request had set it: a scrape asking
    `Connection: close` (SPEC B17's token list included), or an HTTP/1.0
    chunked POST, whose faulty framing closes the connection (SPEC B15),
    was kept alive there. The scrape that asks nothing stays open, which is
    what a scraper holding one connection relies on."""
    var asked = _metrics_exchange(
        "GET /__metrics HTTP/1.1\r\nHost: x\r\nConnection: close, TE\r\n\r\n"
    )
    assert_true("200 ok" in asked[0], asked[0])
    assert_true("connection: close" in asked[0], asked[0])
    assert_true(asked[1], "the slot stayed open after Connection: close")

    var faulty = _metrics_exchange(
        "POST /__metrics HTTP/1.0\r\nConnection: keep-alive\r\n"
        "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    )
    assert_true("connection: close" in faulty[0], faulty[0])
    assert_true(faulty[1], "the slot stayed open after faulty framing")

    var plain = _metrics_exchange("GET /__metrics HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_true("connection: keep-alive" in plain[0], plain[0])
    assert_false(plain[1], "a scrape asking nothing was closed")


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
            st.provision_pool.provisions[slot].state = ConnectionState.reading_body()
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


def _send_all(fd: Int, text: String) raises:
    """Write `text` on `fd` in one send, which a fresh stream pair takes
    whole."""
    var raw = text.as_bytes()
    var sent = send(FileDescriptor(fd), raw, 0)
    assert_equal(Int(sent), len(raw))


def _half_closed_exchange(request: String) raises -> Tuple[String, Bool]:
    """`request` written by a client that then shut down its write side,
    read by the event that carries the EOF with the bytes, which is how
    both backends report a FIN that arrived beside them, and by each event
    a registration issued in the one before brings back -- on epoll
    nothing else does: the reply as the client read it, lowercased, and
    whether the loop closed the slot."""
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(_config())
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    st.slot_read_armed[slot] = True
    _send_all(peer, request)
    shutdown(FileDescriptor(peer), ShutdownOption.SHUT_WR)
    var events = 0
    while st.slot_fds[slot] != UNUSED and events < 4:
        var adds = backend.read_adds
        _on_read(app, backend, st, fd, True)
        events += 1
        if backend.read_adds == adds:
            break
    var got = List[UInt8]()
    _ = _read_available(peer, got)
    var closed = st.slot_fds[slot] == UNUSED
    if not closed:
        close(FileDescriptor(fd))
    close(FileDescriptor(peer))
    return (String(unsafe_from_utf8=Span(got)).lower(), closed)


def test_a_half_closed_request_is_answered_with_a_close() raises:
    """A client that half-closes after its request has sent its last one,
    so the answer says `Connection: close` and the connection ends behind
    it (review record LF11). The EOF set `should_close` and the request's
    own reading of `Connection` replaced it: the answer said `keep-alive`,
    and the slot waited for a next request no event would announce -- on
    epoll the edge that carried the FIN was spent, so it stayed until the
    idle sweep, and for good with idle timeouts off. kqueue's level trigger
    reported the EOF again and hid the hold, not the header.

    A request pipelined behind it is still answered: only the LAST request
    the client sent closes the connection. Behind it in the same read, and
    behind it in the socket, where a read that filled its buffer ended
    exactly at the first request's last byte: the EOF says the FIN has
    arrived, not that everything ahead of it has been read. That one is
    the next read event's, which the drain registers for (LF72).

    covers: A27
    """
    var one = _half_closed_exchange("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_true("200 ok" in one[0], one[0])
    assert_true("connection: close" in one[0], one[0])
    assert_false("keep-alive" in one[0], one[0])
    assert_true(one[1], "a half-closed request's connection stayed open")

    var two = _half_closed_exchange(
        "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"
    )
    var reply = two[0]
    var answers = List[String]()
    for part in reply.split("http/1.1 200 ok"):
        answers.append(String(part))
    assert_equal(len(answers), 3, reply)
    assert_true("connection: keep-alive" in answers[1], reply)
    assert_true("connection: close" in answers[2], reply)
    assert_true(two[1], "the last pipelined request left its connection open")

    # The first request exactly one read long, the second still in the
    # socket when the first is answered.
    var sizing = _loop(_config())
    var want = sizing.provision_pool.provisions[
        sizing.provision_pool.borrow()
    ].recv_staging.capacity()
    var head = String("GET /a HTTP/1.1\r\nHost: x\r\nX-Pad: ")
    var first = head + String("p") * (want - head.byte_length() - 4) + "\r\n\r\n"
    assert_equal(first.byte_length(), want)
    var full = _half_closed_exchange(
        first + "GET /b HTTP/1.1\r\nHost: x\r\n\r\n"
    )
    var full_reply = full[0]
    var full_answers = List[String]()
    for part in full_reply.split("http/1.1 200 ok"):
        full_answers.append(String(part))
    assert_equal(
        len(full_answers), 3,
        "a request still in the socket behind a half-close went unanswered: "
        + full_reply,
    )
    assert_true("connection: keep-alive" in full_answers[1], full_reply)
    assert_true("connection: close" in full_answers[2], full_reply)
    assert_true(full[1])


def test_a_half_closed_head_longer_than_a_read_is_answered() raises:
    """A head larger than one read, its FIN arriving with its first bytes,
    is read to its end and answered (review record LF42). The read path
    took one buffer, found the head incomplete, and closed the slot
    because the event said the peer had half-closed, with the rest of the
    head still in the socket: the client's request went unanswered. The
    EOF says the FIN has arrived; only a read of nothing, or a shorter one
    behind it, says nothing more is coming. The next read takes the rest:
    the drain's, in the same event, or the re-armed one, which both
    backends report again.

    covers: A29
    """
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(_config())
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    var want = st.provision_pool.provisions[slot].recv_staging.capacity()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    var head = String("GET /long HTTP/1.1\r\nHost: x\r\nX-Pad: ")
    head += String("p") * (want + want // 2) + "\r\n\r\n"
    _send_all(peer, head)
    shutdown(FileDescriptor(peer), ShutdownOption.SHUT_WR)

    # The event that brings the first bytes carries the EOF; while the slot
    # stays open, its re-armed registration reports it again.
    var events = 0
    while st.slot_fds[slot] != UNUSED and events < 3:
        _on_read(app, backend, st, fd, True)
        events += 1
    var got = List[UInt8]()
    _ = _read_available(peer, got)
    var reply = String(unsafe_from_utf8=Span(got)).lower()
    assert_true(
        reply.startswith("http/1.1 200 ok"),
        "a half-closed head longer than one read went unanswered: " + reply,
    )
    assert_true("connection: close" in reply, reply)
    assert_equal(st.slot_fds[slot], UNUSED)
    close(FileDescriptor(peer))


def test_a_half_close_behind_a_slow_answer_keeps_the_pipelined_rest() raises:
    """A client that pipelines, half-closes, and reads slowly is answered
    every request it sent (review record LF43). The first answer waited on
    a full socket when the EOF arrived, and the read path's `should_close`
    then closed the connection as soon as that answer landed: the request
    pipelined behind it, already in the buffer, went unanswered. The
    keep-alive transition answers it, keeping the EOF, so the last one
    closes (`_answers_the_last_request`).

    Only a stale event reaches a slot waiting to write, which holds no read
    registration on either backend: an EOF in the same batch as a pool
    thread's or the executor's completion whose answer went out in part.
    This dispatches that event to the waiting slot directly.

    covers: A30
    """
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(_config())
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    var filler = _fill_send_buffer(fd)
    _send_all(peer, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n")
    shutdown(FileDescriptor(peer), ShutdownOption.SHUT_WR)

    # The requests are read, and the first answer waits on the full socket.
    _on_read(app, backend, st, fd, False)
    assert_equal(
        st.provision_pool.provisions[slot].state.kind, ConnectionState.RESPONDING,
    )
    # The EOF arrives while it waits.
    _on_read(app, backend, st, fd, True)

    var got = List[UInt8]()
    var rounds = 0
    while st.slot_fds[slot] != UNUSED and rounds < 1000:
        _ = _read_available(peer, got)
        if (
            st.provision_pool.provisions[slot].state.kind
            == ConnectionState.RESPONDING
        ):
            _on_write(app, backend, st, fd)
        else:
            # Between requests with its reads armed: the registration
            # reports the EOF, as both backends do.
            _on_read(app, backend, st, fd, True)
        rounds += 1
    _ = _read_available(peer, got)
    var reply = String(unsafe_from_utf8=Span(got)[filler:])
    var answers = len(reply.split("HTTP/1.1 200 OK")) - 1
    assert_equal(
        answers, 2,
        "a request pipelined behind a slow answer went unanswered: " + reply,
    )
    assert_true("connection: close" in reply.lower(), reply)
    assert_equal(st.slot_fds[slot], UNUSED, "the connection was left open")
    close(FileDescriptor(peer))


struct Tally(HTTPService):
    """Answers every request with a 200, and counts them."""

    var n: Int

    def __init__(out self):
        self.n = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.n += 1
        return OK("ok", "text/plain")


def _big_buffers(fd: Int):
    """Ask for a megabyte of socket buffer each way, as TCP autotuning gives
    a busy connection: room for a burst to wait unread, and for the answers
    to it. Best effort; the kernel caps it (Linux at `wmem_max`)."""
    for option in [SocketOption.SO_SNDBUF, SocketOption.SO_RCVBUF]:
        try:
            setsockopt(FileDescriptor(fd), c_int(SOL_SOCKET), option.value, c_int(1 << 20))
        except:
            pass


def _send_what_fits(fd: Int, raw: Span[UInt8, _], off: Int) raises -> Int:
    """Send `raw` from `off` until the socket takes no more; the new offset.
    A server that has closed takes nothing more ever: all of it, then."""
    var at = off
    while at < len(raw):
        var sent: UInt
        try:
            sent = send(FileDescriptor(fd), raw[at:], 0)
        except err:
            if err.would_block():
                break
            return len(raw)
        if sent == 0:
            break
        at += Int(sent)
    return at


def _pipelined_burst(
    config: ServerConfig, n: Int
) raises -> Tuple[Int, Int, Bool, Int, Bool]:
    """`n` pipelined 27-byte GETs, as many written before the loop's first
    read as the socket takes and the rest as it makes room, served by the
    events epoll would report: a write one-shot's once the client has read,
    and a read once the client has written more or something registered
    the socket again since the last read (nothing else raises an edge).
    The client reads every answer between events. Returns the requests
    run, the `200`s the client read, whether a 400 was among them, the most
    requests one event answered, and whether the slot is still open."""
    ignore_sigpipe()
    var app = Tally()
    var backend = FakeBackend()
    var st = _loop(config)
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    _big_buffers(fd)
    _big_buffers(peer)
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    st.slot_read_armed[slot] = True
    var burst = String("GET /x HTTP/1.1\r\nHost: x\r\n\r\n") * n
    var raw = burst.as_bytes()
    var off = _send_what_fits(peer, raw, 0)
    var got = List[UInt8]()
    var most = 0
    var events = 0
    var adds_at_read = -1
    var sent_at_read = -1
    while st.slot_fds[slot] != UNUSED and events < 10 * n:
        var ran = app.n
        if (
            st.provision_pool.provisions[slot].state.kind
            == ConnectionState.RESPONDING
        ):
            _on_write(app, backend, st, fd)
        elif backend.read_adds != adds_at_read or off != sent_at_read:
            adds_at_read = backend.read_adds
            sent_at_read = off
            _on_read(app, backend, st, fd, False)
        else:
            break
        events += 1
        most = max(most, app.n - ran)
        _ = _read_available(peer, got)
        off = _send_what_fits(peer, raw, off)
    var reply = String(unsafe_from_utf8=Span(got)).lower()
    var open = st.slot_fds[slot] != UNUSED
    if open:
        close(FileDescriptor(fd))
    close(FileDescriptor(peer))
    return (
        app.n, len(reply.split("http/1.1 200 ok")) - 1,
        "400 bad request" in reply, most, open,
    )


def test_a_pipelined_burst_is_answered_one_read_at_a_time() raises:
    """A burst of pipelined requests waiting in the socket is answered as
    the loop reads it, one read per event, and every request within the
    caps is answered (review record LF72).

    The drain framed each request behind an answer through the read path,
    whose read came first: every answer took up to one more read off the
    socket, so the whole burst came into the buffer during ONE event, and
    the keep-alive reset copied what was left of it after every answer.
    20,000 GETs held the loop 1.56 s in that one event, the cost of a
    request doubling with the burst; and at a receive limit of 8,256 bytes
    600 GETs of 27 bytes, each within every cap, were answered twice, then
    refused 400 and closed. Now the drain reads nothing, so an event
    answers at most what its read brought, and each read that fills its
    buffer leaves the rest to an event its registration brings: the events
    here are only the ones epoll would report.

    covers: A41
    """
    var want = _loop(_config()).provision_pool.buffer_size
    var per_read = want // 27 + 1

    var tight = _config()
    tight.max_total_header_size = 8192
    tight.max_request_body_size = 64
    tight.recv_buffer_max = 0
    assert_equal(tight.recv_buffer_limit(), 8256)
    var small = _pipelined_burst(tight, 600)
    assert_equal(small[0], 600, "requests run")
    assert_equal(small[1], 600, "answers read")
    assert_false(small[2], "a request within every cap was refused 400")
    assert_true(small[4], "the connection closed")
    assert_true(
        small[3] <= per_read,
        String("one event answered ", small[3], " requests; one read holds ", per_read),
    )

    var config = _config()
    config.max_keepalive_requests = 0
    var big = _pipelined_burst(config, 20000)
    assert_equal(big[0], 20000, "requests run")
    assert_equal(big[1], 20000, "answers read")
    assert_false(big[2])
    assert_true(big[4], "the connection closed")
    assert_true(
        big[3] <= per_read,
        String("one event answered ", big[3], " requests; one read holds ", per_read),
    )


def test_a_filled_read_behind_a_pool_thread_is_registered_again() raises:
    """A read that fills its buffer leaves the rest of the socket to the
    next event, which on epoll only a registration issued after it brings:
    here the first request is exactly one read long, goes to a pool
    thread, and the second waits in the socket. The completion's answer
    registers the socket again, and the next event answers the second.

    The read path re-registered a filled read only when its request was
    answered at once, and the completion's `_arm_reads` found the slot
    armed: the drain's own read took the rest. The drain reads nothing now
    (LF72), so the filled read marks the slot unarmed instead
    (`_spend_read_edge`).

    covers: A41
    """
    var pool = OffloadPool(SLOTS)
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), True, offload_addr=pool.addr()
    )
    var backend = FakeBackend()
    var app = Tally()
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    var want = st.provision_pool.provisions[slot].recv_staging.capacity()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    st.slot_read_armed[slot] = True
    var head = String("GET /a HTTP/1.1\r\nHost: x\r\nX-Pad: ")
    var first = head + String("p") * (want - head.byte_length() - 4) + "\r\n\r\n"
    assert_equal(first.byte_length(), want)
    _send_all(peer, first + "GET /b HTTP/1.1\r\nHost: x\r\n\r\n")

    var slots = List[Int]()
    slots.append(slot)
    _on_read(app, backend, st, fd, False)
    assert_true(st.offload.offloaded[slot], "the first request did not go to the pool")
    var adds = backend.read_adds
    assert_equal(_run_inline(app, backend, st, slots), 1)
    assert_true(
        backend.read_adds > adds,
        "nothing registered the socket after the read that filled its buffer",
    )
    _on_read(app, backend, st, fd, False)
    assert_true(st.offload.offloaded[slot], "the second request was not read")
    assert_equal(_run_inline(app, backend, st, slots), 1)
    var got = List[UInt8]()
    _ = _read_available(peer, got)
    var reply = String(unsafe_from_utf8=Span(got)).lower()
    assert_equal(_answers(reply), 2, reply)
    assert_equal(app.n, 2)
    close(FileDescriptor(fd))
    close(FileDescriptor(peer))
    # `pool` must outlive the loop state that holds its address.
    _ = pool.capacity


def test_a_request_is_answered_alike_in_one_read_or_two() raises:
    """A request within every cap gets the same answer whether what follows
    its head comes in the head's read or the next one, and a head is held
    to the buffer's limit alone (review record LF72).

    The head path compared the WHOLE buffer with `recv_buffer_limit()`, so
    what came with a head counted against it: at caps of 128 head bytes,
    64 body bytes and a 192-byte limit, a body at the cap with a request
    behind it, a chunked body at the cap behind a 120-byte head, and a
    chunked body over the cap were each refused 400 and closed in one read,
    and answered 200 and 200, 200, and 413 with the lingering close in two;
    twenty GETs pipelined in one read were refused too. The pending head
    is what is measured now, and only while it is incomplete: a framed one
    is held to its own caps (SPEC A20, B29).

    covers: C19
    """
    var config = _tight_caps()
    assert_equal(config.recv_buffer_limit(), 192)
    var app = BodyLength()
    var next = String("GET /b HTTP/1.1\r\nHost: x\r\n\r\n")
    var cl_head = _padded_head(
        "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 64\r\n", 120
    )
    var chunked_head = _padded_head(
        "POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n", 120
    )
    var at_cap = String("40\r\n") + String("b") * 64 + "\r\n0\r\n\r\n"
    var over_cap = String("50\r\n") + String("b") * 80 + "\r\n"
    for split in [False, True]:
        var shape = String(" in two reads") if split else String(" in one read")

        var parts: List[String]
        if split:
            parts = [cl_head, String("b") * 64 + next]
        else:
            parts = [cl_head + String("b") * 64 + next]
        var cl = _exchange_with(app, config, parts)
        assert_equal(_answers(cl[0]), 2, "a body at the cap, a request behind" + shape + ": " + cl[0])
        assert_true("body=64" in cl[0], cl[0])
        assert_false(cl[1], "the connection closed" + shape)

        if split:
            parts = [chunked_head, at_cap]
        else:
            parts = [chunked_head + at_cap]
        var chunked = _exchange_with(app, config, parts)
        assert_equal(_answers(chunked[0]), 1, "a chunked body at the cap" + shape + ": " + chunked[0])
        assert_true("body=64" in chunked[0], chunked[0])
        assert_false(chunked[1], "the connection closed" + shape)

        if split:
            parts = [chunked_head, over_cap]
        else:
            parts = [chunked_head + over_cap]
        var over = _exchange_with(app, config, parts)
        assert_true(
            over[0].startswith("http/1.1 413 payload too large"),
            "a chunked body over the cap" + shape + ": " + over[0],
        )
        assert_false(over[1], "the 413 was not followed by its lingering close" + shape)

    var burst = _exchange_with(app, config, [next * 20])
    assert_equal(_answers(burst[0]), 20, "twenty GETs in one read: " + burst[0])
    assert_false(burst[1])

    # The bound is still there for a head that cannot be framed.
    var endless = _exchange_with(
        app, config, [String("GET / HTTP/1.1\r\nX-Pad: ") + String("p") * 200]
    )
    assert_true(endless[0].startswith("http/1.1 400 bad request"), endless[0])
    assert_true(endless[1], "a head past the limit kept its connection")


comptime INTERIM = "HTTP/1.1 100 Continue\r\n\r\n"


def _interim_exchange(
    config: ServerConfig,
    head: String,
    rest: List[String],
    taken: Int = 0,
    expire: Bool = False,
) raises -> String:
    """`head`, a request that expects `100 Continue`, read while the
    server's send side is full, so the interim response's send takes none
    of it -- or, with `taken`, as though it had taken that many bytes, which
    are written where the kernel would have put them (`_owe_interim`). The
    client then reads what was waiting and sends `rest`, a read event a
    part, the server's answers taken as they come; with `expire`, the body
    timer runs out instead. Returns what the client read after the filler."""
    var app = BodyLength()
    var backend = FakeBackend()
    var st = _loop(config)
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    st.slot_read_armed[slot] = True
    var filler = _fill_send_buffer(fd)
    _send_all(peer, head)
    _on_read(app, backend, st, fd, False)
    assert_equal(
        st.provision_pool.provisions[slot].state.kind, ConnectionState.READING_BODY
    )
    var got = List[UInt8]()
    _ = _read_available(peer, got)
    if taken > 0:
        var interim = String(INTERIM)
        var sent = send(FileDescriptor(fd), interim.as_bytes()[:taken], 0)
        assert_equal(Int(sent), taken)
        _owe_interim(st, slot, interim.as_bytes(), taken)
    for part in rest:
        if st.slot_fds[slot] == UNUSED:
            break
        _send_all(peer, part)
        _on_read(app, backend, st, fd, False)
        var rounds = 0
        while (
            st.slot_fds[slot] != UNUSED
            and st.provision_pool.provisions[slot].state.kind
            == ConnectionState.RESPONDING
            and rounds < 100
        ):
            _ = _read_available(peer, got)
            _on_write(app, backend, st, fd)
            rounds += 1
    if expire:
        var ident = UInt(fd) + TIMER_BODY
        backend.expire(ident)
        _on_timer(app, backend, st, ident)
    _ = _read_available(peer, got)
    if st.slot_fds[slot] != UNUSED:
        close(FileDescriptor(fd))
    close(FileDescriptor(peer))
    assert_true(len(got) >= filler, "the client did not read the filler")
    return String(unsafe_from_utf8=Span(got)[filler:])


def test_an_interim_response_the_socket_did_not_take_goes_out_first() raises:
    """A `100 Continue` the socket did not take whole reaches the client
    whole, ahead of whatever the connection sends next: the answer, a 413
    for a body over the cap, a 400 for a malformed chunk, or the body
    timer's 408 (review record LF73).

    The loop sent it and ignored the count. A non-blocking send takes what
    the socket has room for, and on Linux that can be part of even these
    25 bytes: a send queue that is full, with less than 25 bytes left in
    its last segment, takes the part that fits (153 of 200 trials of a
    socket filled 25 bytes at a time, over loopback TCP; macOS sends a
    write this small whole or not at all). The final response then followed
    a fragment, `HTTP/1.1 100 Co` and the rest of the stream unparseable.
    A test cannot make a kernel cut a send, so it fills the socket, which
    makes the send take nothing, and plays the kernel for a take of 7
    bytes: what was not taken is owed, and goes out first.

    covers: A42
    """
    var head = String(
        "POST /p HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n"
        "Content-Length: 5\r\n\r\n"
    )
    var answered = String(INTERIM) + "HTTP/1.1 200 OK"
    for taken in [0, 7]:
        var reply = _interim_exchange(_config(), head, ["hello"], taken)
        assert_true(
            reply.startswith(answered),
            String("an interim response ", taken, " bytes of which were taken: ", reply),
        )
        assert_true("body=5" in reply, reply)

    var chunked = String(
        "POST /c HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n"
        "Transfer-Encoding: chunked\r\n\r\n"
    )
    var over = _interim_exchange(
        _tight_caps(), chunked, [String("50\r\n") + String("b") * 80 + "\r\n"]
    )
    assert_true(
        over.startswith(String(INTERIM) + "HTTP/1.1 413 Payload Too Large"),
        "a body over the cap: " + over,
    )
    var malformed = _interim_exchange(_config(), chunked, ["zz\r\n"])
    assert_true(
        malformed.startswith(String(INTERIM) + "HTTP/1.1 400 Bad Request"),
        "a malformed chunk: " + malformed,
    )
    var late = _interim_exchange(_config(), head, [], expire=True)
    assert_true(
        late.startswith(String(INTERIM) + "HTTP/1.1 408 Request Timeout"),
        "a body that never came: " + late,
    )


struct OneChunkStream(HTTPService):
    """A channel stream's producer, as the loop sees it: one payload
    queued, and the stream over once it is drained."""

    var drained: Bool

    def __init__(out self):
        self.drained = False

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("unused", "text/plain")

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        if self.drained:
            return List[UInt8]()
        self.drained = True
        return List[UInt8](String("one-chunk").as_bytes())

    def sse_is_streaming(self, slot: Int) -> Bool:
        return not self.drained


def _chunked_stream_exchange(
    asked_close: Bool, keep_alive: Bool = True, half_closed: Bool = False,
) raises -> Tuple[String, Bool]:
    """A chunked stream from a channel producer, from its head to its
    terminator, for a request that asked for a close or did not, on a
    server with keep-alive on or off, from a client that has half-closed or
    not: what the client read, lowercased, and whether the loop closed the
    slot once the terminator landed."""
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    var acks = make_stream_ack_pair()
    var app = OneChunkStream()
    var backend = FakeBackend()
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), keep_alive,
        offload_addr=pool.addr(),
    )
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    pool.set_slot_ack_fd(slot, acks[1])
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.offload.http11[slot] = True
    st.offload.is_head[slot] = False
    # What `_process_request` decides before the handler runs.
    st.provision_pool.provisions[slot].should_close = asked_close or not keep_alive
    st.provision_pool.provisions[slot].state = ConnectionState.processing()
    if half_closed:
        # The request was the last bytes the client sent: its EOF reached
        # the read path (`peer_eof`), and nothing is buffered behind it.
        shutdown(FileDescriptor(peer), ShutdownOption.SHUT_WR)
        st.provision_pool.provisions[slot].peer_eof = True
    var response = OK("", "text/plain")
    response.sse_streaming = True
    _finish_response(app, backend, st, slot, fd, response^)
    assert_equal(
        st.provision_pool.provisions[slot].state.kind,
        ConnectionState.STREAMING_SSE,
    )
    _drain_outboxes(app, backend, st)
    var got = List[UInt8]()
    _ = _read_available(peer, got)
    var closed = st.slot_fds[slot] == UNUSED
    if not closed:
        close(FileDescriptor(fd))
    close(FileDescriptor(peer))
    close(FileDescriptor(acks[0]))
    close(FileDescriptor(acks[1]))
    # The loop holds the pool by its address, which keeps nothing alive.
    _ = pool
    return (String(unsafe_from_utf8=Span(got)).lower(), closed)


def test_a_chunked_stream_keeps_the_close_its_request_asked_for() raises:
    """A chunked stream answers its request whole, so once its terminator
    lands the connection does what the request asked: closes after
    `Connection: close`, on a server with keep-alive off, or for a client
    that has half-closed (LF11's close), and stays otherwise; the head says
    which (review record LF13). A stream's head clears `should_close`, or
    the head landing would close the slot, and the stream's end took the
    keep-alive path whatever the request had said, under a head that said
    `keep-alive`.

    covers: A28
    """
    var asked = _chunked_stream_exchange(True)
    assert_true("transfer-encoding: chunked" in asked[0], asked[0])
    assert_true("connection: close" in asked[0], asked[0])
    assert_true(asked[0].endswith("9\r\none-chunk\r\n0\r\n\r\n"), asked[0])
    assert_true(asked[1], "Connection: close kept the connection after the stream")

    var off = _chunked_stream_exchange(False, keep_alive=False)
    assert_true("connection: close" in off[0], off[0])
    assert_true(off[1], "a server with keep-alive off kept the connection")

    var half = _chunked_stream_exchange(False, half_closed=True)
    assert_true("transfer-encoding: chunked" in half[0], half[0])
    assert_true("connection: close" in half[0], half[0])
    assert_true(half[0].endswith("9\r\none-chunk\r\n0\r\n\r\n"), half[0])
    assert_true(half[1], "a half-closed client's stream kept the connection")

    var kept = _chunked_stream_exchange(False)
    assert_true("transfer-encoding: chunked" in kept[0], kept[0])
    assert_true("connection: keep-alive" in kept[0], kept[0])
    assert_true(kept[0].endswith("0\r\n\r\n"), kept[0])
    assert_false(kept[1], "a stream its request did not ask to close was closed")


def test_the_farewell_writes_only_into_a_stream_that_takes_one() raises:
    """The drain's farewell asks what the heartbeat asks
    (`_takes_an_out_of_band_frame`; review record LF12). An idle SSE
    stream gets its close comment and an idle WebSocket a Close carrying
    1001; a WebSocket that has sent its Close, a stream with a frame half
    sent, and an SSE stream its application writes through the chunk
    channel get nothing, and are closed as they stand. The farewell wrote
    into all five: a second Close, bytes inside a frame, and a comment the
    client's chunked parser read as a chunk size.

    covers: D13
    """
    var pool = OffloadPool(8)
    pool.enable_stream_channel()
    var acks = make_stream_ack_pair()
    var config = _config()
    config.max_connections = 8
    var app = NoApp()
    var backend = FakeBackend()
    var st = LoopState(
        FileDescriptor(-1), config, String(""), True, offload_addr=pool.addr(),
    )
    var peers = List[Int]()
    var slots = List[Int]()
    for shape in range(5):
        var pair = _stream_pair()
        var slot = st.provision_pool.borrow()
        st.slot_fds[slot] = pair[0]
        st.fd_to_slot[pair[0]] = slot
        st.active_count += 1
        if shape == 0 or shape == 3 or shape == 4:
            st.slot_sse[slot] = True
            st.provision_pool.provisions[slot].state = ConnectionState.streaming_sse()
        else:
            st.slot_ws[slot] = True
            st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
        if shape == 2:
            st.slot_ws_state[slot].closing = True
        elif shape == 3:
            st.provision_pool.provisions[slot].state = ConnectionState.responding()
        elif shape == 4:
            pool.set_slot_ack_fd(slot, acks[1])
        peers.append(pair[1])
        slots.append(slot)

    _farewell_streams(app, backend, st)

    var going = close_frame(WS_CLOSE_GOING_AWAY)
    var expected = List[List[UInt8]]()
    expected.append(List[UInt8](String(": close\n\n").as_bytes()))
    expected.append(going.copy())
    for _ in range(3):
        expected.append(List[UInt8]())
    var names = List[String]()
    names.append("an idle SSE stream")
    names.append("an idle WebSocket")
    names.append("a WebSocket that has sent its Close")
    names.append("a stream with a frame half sent")
    names.append("a chunk-channel SSE stream")
    for shape in range(5):
        assert_equal(st.slot_fds[slots[shape]], UNUSED, names[shape] + " was left open")
        var got = List[UInt8]()
        assert_true(_read_available(peers[shape], got), names[shape] + " read no EOF")
        assert_equal(
            len(got), len(expected[shape]),
            names[shape] + " was sent " + String(len(got)) + " bytes",
        )
        for i in range(len(got)):
            assert_equal(Int(got[i]), Int(expected[shape][i]), names[shape])
        close(FileDescriptor(peers[shape]))
    close(FileDescriptor(acks[0]))
    close(FileDescriptor(acks[1]))
    # The loop holds the pool by its address, which keeps nothing alive.
    _ = pool


def test_the_access_log_times_a_request_without_a_header_timeout() raises:
    """A keep-alive request's duration runs from its first bytes whatever
    the header timeout (review record LF14). The keep-alive reset zeroes
    the header clock, and it was stamped again only while
    `header_read_timeout` was above 0; the access log subtracted it anyway:
    with the timeout off every request after a connection's first logged
    the time since the machine booted, and the metrics' latency, which
    asked for a stamp first, recorded nothing for it. (The accept stamps a
    connection's first request.) The slot here starts with the clock at 0,
    as that reset leaves it.

    covers: F22
    """
    var config = _config()
    config.header_read_timeout = 0
    config.access_log = True
    config.enable_metrics = True
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(config)
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.provision_pool.provisions[slot].state = ConnectionState.reading_headers()
    _send_all(peer, "GET /timed HTTP/1.1\r\nHost: x\r\n\r\n")

    var out = _stream_pair()
    var saved = Int(external_call["dup", c_int, c_int](c_int(1)))
    assert_true(saved >= 0)
    _ = external_call["dup2", c_int, c_int, c_int](c_int(out[1]), c_int(1))
    _on_read(app, backend, st, fd, False)
    _ = external_call["dup2", c_int, c_int, c_int](c_int(saved), c_int(1))
    close(FileDescriptor(saved))
    close(FileDescriptor(out[1]))
    var logged = List[UInt8]()
    _ = _read_available(out[0], logged)
    close(FileDescriptor(out[0]))
    var line = String(unsafe_from_utf8=Span(logged))

    var at = line.find('"dur_us":')
    assert_true(at >= 0, "no access line was written: " + line)
    var digits = String()
    for b in line.as_bytes()[at + 9 :]:
        if b < 0x30 or b > 0x39:
            break
        digits += chr(Int(b))
    var dur_us = Int(digits)
    assert_true(
        dur_us < 1_000_000,
        String("a request answered at once was logged as taking ")
        + String(dur_us) + "us: " + line,
    )
    assert_equal(st.metrics.latency_count, 1, "the latency was not recorded")
    assert_true(st.metrics.latency_sum_us < 1_000_000)
    assert_equal(st.slot_header_start[slot], 0, "the keep-alive reset kept the stamp")
    close(FileDescriptor(fd))
    close(FileDescriptor(peer))


def test_a_send_deadline_leaves_a_websockets_close_linger() raises:
    """`_arm_send_deadline` skips a stream, and the skip is what keeps a
    WebSocket's close linger. A socket the handler closed itself
    (`take_ws_closes`) has its linger armed while its Close is still
    queued, and when that Close, or a frame ahead of it, goes out through
    the write-ready path, every send that moves bytes restarts the send
    deadline. Without the skip that re-stamped the linger as `idle_timeout`
    from the last progress. `_stream_idle` does not hide it: it keeps a
    closing socket's deadline when the bytes land
    (`test_a_frame_keeps_a_websockets_close_linger`), so the sweep would
    have reaped a peer that never answers by the idle timeout, not by
    `WS_CLOSE_LINGER_NS`.

    covers: L16
    """
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(_config())
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.slot_ws[slot] = True
    st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
    _arm_ws_linger(st, slot)
    var linger = st.slot_idle_deadline[slot]
    assert_true(linger > 0)
    # Queued bytes bigger than the socket takes in one send, on their way
    # out through the write-ready path, as the outbox drain leaves them.
    st.slot_response[slot] = Bytes(length=8 << 20, fill=0x61)
    st.slot_send_offset[slot] = 0
    st.provision_pool.provisions[slot].state = ConnectionState.responding()
    _on_write(app, backend, st, fd)
    assert_true(st.slot_send_offset[slot] > 0)
    assert_true(st.slot_send_offset[slot] < len(st.slot_response[slot]))
    assert_equal(
        st.slot_idle_deadline[slot], linger,
        "a send that moved bytes re-stamped the close linger",
    )
    # The peer reads the rest: the bytes land and the slot lingers in frame
    # mode, by the deadline it was given when the Close was queued.
    var rounds = 0
    while (
        st.provision_pool.provisions[slot].state.kind == ConnectionState.RESPONDING
        and rounds < 100_000
    ):
        _discard_all(peer)
        _on_write(app, backend, st, fd)
        rounds += 1
    assert_equal(st.provision_pool.provisions[slot].state.kind, ConnectionState.STREAMING_WS)
    assert_equal(st.slot_idle_deadline[slot], linger)
    close(FileDescriptor(fd))
    close(FileDescriptor(peer))


def test_a_close_echo_the_kernel_refused_goes_out_before_the_close() raises:
    """A peer's Close is answered by its echo WHOLE, and the socket closes
    only once the echo has gone (review record R6, the close half).

    The echo is the last reply, so whether the send buffer toward the peer
    is still full when it is sent is not the client's to arrange, and no
    wire gate can force it. Here it is arranged: the loop's end of a real
    stream pair has filled its send buffer, a byte at a time at the end, so
    the kernel refuses the echo whole. `_read_websocket` must queue it as
    the slot's response and mark the close owed (`should_close`) rather
    than close; the write-ready path sends it once the peer reads, and
    `_after_send` closes. The peer then reads the filler, the echo with its
    own code, and EOF. Closing at once, or dropping the part the kernel
    refused, ends the connection with no Close at all, which a client
    reports as 1006 rather than the code it sent.

    Over `FakeBackend`, epoll's shape, with the write-ready path called
    directly; `test_a_close_echo_waits_for_the_multiplexer` drives the same
    close through this OS's own.

    covers: I31
    """
    var app = NoApp()
    var backend = FakeBackend()
    var st = _loop(_config())
    var setup = _a_websocket_owed_a_close_echo(st)
    var fd = setup[0]
    var peer = setup[1]
    var slot = setup[2]
    var filler = setup[3]
    assert_true(_arm_reads(backend, st, slot, fd))

    _read_websocket(app, backend, st, slot, fd, False)
    _assert_the_echo_is_owed(st, slot, fd)
    # The echo holds the socket's one registration until it lands.
    assert_true(backend.write)
    assert_false(backend.read)

    var got = List[UInt8]()
    var rounds = 0
    while (
        st.slot_fds[slot] != UNUSED
        and st.provision_pool.provisions[slot].state.kind
        == ConnectionState.RESPONDING
        and rounds < 1000
    ):
        _ = _read_available(peer, got)
        _on_write(app, backend, st, fd)
        rounds += 1
    assert_equal(
        st.slot_fds[slot], UNUSED, "the echo went out and the slot stayed open",
    )
    assert_false(backend.read)
    assert_false(backend.write)
    assert_true(
        _read_available(peer, got), "the peer read no EOF after the echo",
    )
    _assert_the_peer_read_the_echo_last(got, filler)
    close(FileDescriptor(peer))


def test_a_close_echo_waits_for_the_multiplexer() raises:
    """The same close over this OS's multiplexer, kqueue on macOS and epoll
    on Linux, each step taken on the event the wait reports, as `_run_pass`
    dispatches it: the peer's Close is a read event (`_on_read`), and the
    echo waits for a write event (`_on_write`), which does not come until
    the peer reads. `FakeBackend` keeps a registration as epoll does and
    never reports a socket ready, so only this one shows that each OS
    reports the write that sends the echo, and nothing before it.

    covers: I31
    """
    var app = NoApp()
    var backend = PlatformBackend()
    var st = _loop(_config())
    var setup = _a_websocket_owed_a_close_echo(st)
    var fd = setup[0]
    var peer = setup[1]
    var slot = setup[2]
    var filler = setup[3]
    assert_true(_arm_reads(backend, st, slot, fd))

    var n = backend.wait(1000)
    assert_equal(n, 1, "the peer's Close was not reported readable")
    assert_equal(Int(backend.event_ident(0)), fd)
    assert_equal(backend.event_filter(0), EVFILT_READ)
    _on_read(app, backend, st, fd, (backend.event_flags(0) & EV_EOF) != 0)
    _assert_the_echo_is_owed(st, slot, fd)
    assert_equal(
        backend.wait(50), 0,
        "the socket was reported ready while its peer had read nothing",
    )

    var got = List[UInt8]()
    var rounds = 0
    while (
        st.slot_fds[slot] != UNUSED
        and st.provision_pool.provisions[slot].state.kind
        == ConnectionState.RESPONDING
        and rounds < 100
    ):
        _ = _read_available(peer, got)
        n = backend.wait(1000)
        var writes = 0
        for i in range(n):
            if (
                Int(backend.event_ident(i)) == fd
                and backend.event_filter(i) == EVFILT_WRITE
            ):
                writes += 1
        assert_equal(
            writes, 1, "the peer read, and the socket was not reported writable",
        )
        _on_write(app, backend, st, fd)
        rounds += 1
    assert_equal(
        st.slot_fds[slot], UNUSED, "the echo went out and the slot stayed open",
    )
    assert_true(
        _read_available(peer, got), "the peer read no EOF after the echo",
    )
    _assert_the_peer_read_the_echo_last(got, filler)
    close(FileDescriptor(peer))


# An application's close code (4000-4999), so an echo carrying it cannot be
# one the server made up.
comptime CLOSE_CODE = 4321
comptime FILLER: UInt8 = 0x61


def _a_websocket_owed_a_close_echo(
    mut st: LoopState,
) raises -> Tuple[Int, Int, Int, Int]:
    """A WebSocket slot in frame mode over a real stream pair, its send
    buffer toward the peer full, and the peer's masked Close, carrying
    `CLOSE_CODE`, waiting to be read. Returns the loop's end, the peer's,
    the slot, and how many filler bytes the kernel took."""
    var pair = _stream_pair()
    var fd = pair[0]
    var peer = pair[1]
    var slot = st.provision_pool.borrow()
    st.slot_fds[slot] = fd
    st.fd_to_slot[fd] = slot
    st.active_count = 1
    st.slot_ws[slot] = True
    st.slot_ws_state[slot].reset()
    st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
    var filler = _fill_send_buffer(fd)
    assert_true(filler > 0)

    var code = List[UInt8]()
    code.append(UInt8(CLOSE_CODE >> 8))
    code.append(UInt8(CLOSE_CODE & 0xFF))
    var mask = List[UInt8]()
    mask.append(0x37)
    mask.append(0xFA)
    mask.append(0x21)
    mask.append(0x3D)
    var frame = encode_ws_frame_masked(WS_OP_CLOSE, Span(code), mask)
    var sent = send(FileDescriptor(peer), Span(frame), 0)
    assert_equal(Int(sent), len(frame))
    return (fd, peer, slot, filler)


def _fill_send_buffer(fd: Int) raises -> Int:
    """Send filler from `fd` until the kernel takes nothing more, and return
    how much it took. Large writes first, then smaller, down to one byte, so
    the last refusal is of a single byte and no frame fits after it."""
    var chunk = List[UInt8](length=65536, fill=FILLER)
    var total = 0
    var size = 65536
    while size >= 1:
        while True:
            var sent: UInt
            try:
                sent = send(FileDescriptor(fd), Span(chunk)[:size], 0)
            except err:
                if err.would_block():
                    break
                raise Error("filling the send buffer: ", err)
            if sent == 0:
                break
            total += Int(sent)
        size //= 16
    return total


def _read_available(fd: Int, mut got: List[UInt8]) raises -> Bool:
    """Read what is waiting on `fd` into `got` without blocking; True once
    the peer's EOF has been read."""
    var buf = List[UInt8](length=65536, fill=0)
    while True:
        var n: UInt
        try:
            n = recv(FileDescriptor(fd), Span(buf), MSG_DONTWAIT)
        except err:
            if err.would_block():
                return False
            raise Error("reading the peer's end: ", err)
        if n == 0:
            return True
        got.extend(Span(buf)[: Int(n)])


def _assert_the_echo_is_owed(st: LoopState, slot: Int, fd: Int) raises:
    """After the read that parsed the Close: the echo is the slot's queued
    response, whole, with bytes still owed, and the close waits for it."""
    var echo = close_frame(CLOSE_CODE)
    assert_equal(
        len(st.slot_response[slot]), len(echo),
        "the close echo was dropped, not queued",
    )
    for i in range(len(echo)):
        assert_equal(Int(st.slot_response[slot][i]), Int(echo[i]))
    assert_true(st.slot_send_offset[slot] < len(echo))
    assert_equal(
        st.slot_fds[slot], fd, "the slot closed with its close echo owed",
    )
    assert_equal(
        st.provision_pool.provisions[slot].state.kind,
        ConnectionState.RESPONDING,
    )
    assert_true(
        st.provision_pool.provisions[slot].should_close,
        "the close is not waiting for the echo",
    )
    assert_false(st.slot_read_armed[slot])


def _assert_the_peer_read_the_echo_last(got: List[UInt8], filler: Int) raises:
    """The peer read every filler byte, then the Close echo whole, carrying
    its own code."""
    var echo = close_frame(CLOSE_CODE)
    assert_equal(
        len(got), filler + len(echo),
        "the peer did not read the filler and the whole echo",
    )
    for i in range(filler):
        if got[i] != FILLER:
            raise Error("byte ", i, " of the filler arrived altered")
    assert_equal(Int(got[filler]), 0x88, "the last frame is not a Close")
    assert_equal(Int(got[filler + 1]), 2, "the Close carries no code")
    assert_equal(
        (Int(got[filler + 2]) << 8) | Int(got[filler + 3]), CLOSE_CODE,
        "the Close does not echo the peer's code",
    )


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


def _discard_all(fd: Int):
    """Read and drop everything waiting on `fd`, without blocking."""
    var buf = List[UInt8](length=65536, fill=0)
    while True:
        var n: UInt
        try:
            n = recv(FileDescriptor(fd), Span(buf), MSG_DONTWAIT)
        except:
            break
        if n == 0:
            break


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
