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
    EV_EOF, EVFILT_READ, EVFILT_TIMER, EVFILT_WRITE, set_nonblocking,
)
from lightbug_http.c.fcntl import dup_cloexec
from lightbug_http.c.platform import MSG_DONTWAIT, PlatformBackend
from lightbug_http.c.process import getpid
from lightbug_http.c.socket import close, recv, send
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.connection import ConnectionState
from lightbug_http.loop.request import _on_read
from lightbug_http.loop.response import _on_write
from lightbug_http.loop.streams import _read_websocket
from lightbug_http.websocket import (
    WS_OP_CLOSE, close_frame, encode_ws_frame_masked,
)
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
    _ws_linger,
)
from lightbug_http.c.socket import ShutdownOption, shutdown
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
    remove(path)


def _metrics_exchange(request: String) raises -> Tuple[String, Bool]:
    """One request to `/__metrics`, metrics on, read through `_on_read` over
    a real stream pair: the reply as the client read it, lowercased, and
    whether the loop closed the slot behind it."""
    var config = _config()
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
    var raw = request.as_bytes()
    var sent = send(FileDescriptor(peer), raw, UInt(len(raw)), 0)
    assert_equal(Int(sent), len(raw))
    _on_read(app, backend, st, fd, False)
    var got = List[UInt8]()
    _ = _read_available(peer, got)
    var closed = st.slot_fds[slot] == UNUSED
    if not closed:
        close(FileDescriptor(fd))
    close(FileDescriptor(peer))
    return (String(unsafe_from_utf8=Span(got)).lower(), closed)


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
    var sent = send(FileDescriptor(fd), raw, UInt(len(raw)), 0)
    assert_equal(Int(sent), len(raw))


def _half_closed_exchange(request: String) raises -> Tuple[String, Bool]:
    """`request` written by a client that then shut down its write side,
    read by ONE event that carries the EOF with the bytes, which is how
    both backends report a FIN that arrived beside them: the reply as the
    client read it, lowercased, and whether the loop closed the slot."""
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
    _send_all(peer, request)
    shutdown(FileDescriptor(peer), ShutdownOption.SHUT_WR)
    _on_read(app, backend, st, fd, True)
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
    arrived, not that everything ahead of it has been read.

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


def test_the_access_log_times_a_request_without_a_header_timeout() raises:
    """A request's duration runs from its first bytes whatever the header
    timeout (review record LF14). The header clock was stamped only while
    `header_read_timeout` was above 0, and the access log subtracted it
    anyway: with the timeout off every line's `dur_us` was the time since
    the machine booted, and the metrics' latency, which asked for a stamp
    first, recorded nothing.

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
    var sent = send(FileDescriptor(peer), Span(frame), UInt(len(frame)), 0)
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
                sent = send(FileDescriptor(fd), Span(chunk)[:size], UInt(size), 0)
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
            n = recv(FileDescriptor(fd), Span(buf), UInt(len(buf)), MSG_DONTWAIT)
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
            n = recv(FileDescriptor(fd), Span(buf), UInt(len(buf)), MSG_DONTWAIT)
        except:
            break
        if n == 0:
            break


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
