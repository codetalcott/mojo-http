"""The pass that reads the stop dispatches the rest of its batch (review B22).

`_run_pass` noted the shutdown pipe's event and then `break`, leaving every
event behind the pipe in the same batch undispatched. A backend reports each
of those once: epoll registers every read, channel and write edge-triggered,
and kqueue's writes and timers are one-shots, so nothing reports them again.
On Linux, a request whose handler raised SIGTERM (`/raise-sigterm`, on the
ASGI pump) went unanswered in 20 of 32 rounds with the server pinned to one
CPU, and the process exited only when the drain's 5 s budget ran out: the
executor's completion was behind the pipe in the batch, and `inflight` never
fell.

`BatchBackend` is that batch, crafted: its next `wait` returns exactly the
events a test pushed, in order, and nothing is ever reported twice. Each test
puts the shutdown pipe first and one kind of event behind it, and requires
that kind to be handled by the pass that read the stop -- deterministic on
every OS, where the Linux reproduction needs a pinned CPU and even then
misses more than a third of its rounds. The one thing the stop changes in
that pass is below the batch: no new connection is admitted (the last test).
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.broadcast import encode_bus_frame
from lightbug_http.c.fcntl import set_nonblocking
from lightbug_http.c.kqueue import (
    EVFILT_READ, EVFILT_TIMER, EVFILT_WRITE,
)
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import recv, send
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.connection import ConnectionState, ListenConfig
from test.loopback import create_connection
from lightbug_http.event_loop import run_pass_once
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.loop.accept import _admit_connection
from lightbug_http.loop.shutdown import _run_shutdown
from lightbug_http.loop.state import LoopState, TIMER_APP_TICK, UNUSED, _close_slot
from lightbug_http.offload import OffloadPool
from lightbug_http.server_config import ServerConfig

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc


struct BatchBackend(EventLoopBackend):
    """A backend whose next `wait` returns the events pushed since the last
    one, in push order, and never reports an event twice.

    That is epoll's edge trigger, and kqueue's one-shot writes and timers: an
    event the pass does not dispatch is gone. Registrations change nothing
    here; the timers armed are recorded, so a test can see a re-arm."""

    var next_ident: List[Int]
    var next_filter: List[Int16]
    var next_data: List[Int]
    var ident: List[Int]
    var filter: List[Int16]
    var data: List[Int]
    var timers_armed: List[UInt]

    def __init__(out self):
        self.next_ident = List[Int]()
        self.next_filter = List[Int16]()
        self.next_data = List[Int]()
        self.ident = List[Int]()
        self.filter = List[Int16]()
        self.data = List[Int]()
        self.timers_armed = List[UInt]()

    def push(mut self, ident: Int, filter: Int16, data: Int = 0):
        """Add one event to the batch the next `wait` returns."""
        self.next_ident.append(ident)
        self.next_filter.append(filter)
        self.next_data.append(data)

    def wait(mut self, timeout_ms: Int) raises -> Int:
        self.ident = self.next_ident^
        self.filter = self.next_filter^
        self.data = self.next_data^
        self.next_ident = List[Int]()
        self.next_filter = List[Int16]()
        self.next_data = List[Int]()
        return len(self.ident)

    def event_ident(self, i: Int) -> UInt:
        return UInt(self.ident[i])

    def event_filter(self, i: Int) -> Int16:
        return self.filter[i]

    def event_flags(self, i: Int) -> UInt16:
        return 0

    def event_data(self, i: Int) -> Int:
        return self.data[i]

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
        self.timers_armed.append(ident)

    def try_delete_timer(mut self, ident: UInt):
        pass


struct Recorder(HTTPService):
    """Answers every request with `body`, and counts what the loop hands it."""

    var body: String
    var requests: Int
    var frames: Int
    var ticks: Int

    def __init__(out self, body: String = "answered"):
        self.body = body
        self.requests = 0
        self.frames = 0
        self.ticks = 0

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        self.requests += 1
        return OK(self.body, "text/plain")

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        self.frames += 1

    def tick(mut self, now_ms: Int):
        self.ticks += 1


comptime SLOTS = 4
comptime REQUEST = "GET /x HTTP/1.1\r\nHost: t\r\n\r\n"


def _config() -> ServerConfig:
    var config = ServerConfig()
    config.max_connections = SLOTS
    config.sse_heartbeat_ms = 0
    config.app_tick_ms = 50
    return config^


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


def _read_all(fd: Int) -> List[UInt8]:
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
    return out^


def _text(b: List[UInt8]) -> String:
    return String(from_utf8_lossy=Span(b))


def test_a_request_behind_the_stop_is_answered() raises:
    """Two connections' requests share the batch that reads the stop, one
    before the pipe and one behind it. Both are answered by that pass.

    Before the fix the one behind was never read: the pass stopped at the
    pipe, the read's edge was spent, and the drain's first step closed the
    connection as idle between requests with the request still unread.

    covers: D1
    """
    var pipe = create_shutdown_pipe()
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), True, shutdown_read_fd=pipe[0]
    )
    var backend = BatchBackend()
    var handler = Recorder()
    var a = _stream_pair()
    var b = _stream_pair()
    _admit_connection(handler, backend, st, a[0], String("127.0.0.1"), 1)
    _admit_connection(handler, backend, st, b[0], String("127.0.0.1"), 2)
    assert_equal(st.active_count, 2)
    _send_text(a[1], REQUEST)
    _send_text(b[1], REQUEST)
    pipe[1].notify()

    backend.push(a[0], EVFILT_READ)
    backend.push(pipe[0], EVFILT_READ)
    backend.push(b[0], EVFILT_READ)
    assert_true(run_pass_once(handler, backend, st), "the pass did not report the stop")
    assert_equal(handler.requests, 2, "a request behind the stop in its batch was never read")
    assert_true(_text(_read_all(a[1])).startswith("HTTP/1.1 200"))
    assert_true(
        _text(_read_all(b[1])).startswith("HTTP/1.1 200"),
        "the request behind the stop was not answered",
    )

    # Both are between requests now, so the drain closes them at once.
    var t0 = perf_counter_ns()
    _run_shutdown(handler, backend, st)
    assert_true(perf_counter_ns() - t0 < 1_000_000_000, "the drain waited")
    assert_equal(st.active_count, 0)
    for fd in [a[1], b[1], pipe[0], pipe[1].fd]:
        close_fd(fd)


def test_a_completion_behind_the_stop_is_answered() raises:
    """The ASGI pump's shape, measured on Linux: a request out on the
    executor, whose completion datagram shares the batch that reads the stop
    and sits behind the pipe. That pass answers it, and the drain then has
    nothing to wait for.

    Before the fix the completion channel was never read: `inflight` stayed
    at 1, the response was never sent, and the drain waited out its 5 s --
    the executor's `complete_many` pokes the channel once for the batch, and
    no second edge comes.

    covers: D1
    """
    var pool = OffloadPool(SLOTS)
    # What makes lane 0 the executor's: its submits are buffered and flushed
    # once per pass, and it completes with one datagram (`complete_many`).
    pool.enable_stream_channel()
    pool.enable_base_stream_ack()
    var pipe = create_shutdown_pipe()
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), True,
        shutdown_read_fd=pipe[0], offload_addr=pool.addr(),
    )
    var backend = BatchBackend()
    var handler = Recorder()
    var conn = _stream_pair()
    _admit_connection(handler, backend, st, conn[0], String("127.0.0.1"), 1)
    _send_text(conn[1], REQUEST)
    backend.push(conn[0], EVFILT_READ)
    assert_false(run_pass_once(handler, backend, st))
    assert_equal(st.offload.inflight, 1, "the request did not go out to the executor")
    assert_equal(handler.requests, 0)

    # The executor answers it and signals SIGTERM, in either order: the
    # batch the loop then reads holds the pipe first.
    var slot = st.fd_to_slot[conn[0]]
    _ = pool.take_request(slot)
    pool.put_response(slot, OK(String("done"), "text/plain"))
    var done = List[Int]()
    done.append(slot)
    assert_true(pool.complete_many(done))
    pipe[1].notify()

    backend.push(pipe[0], EVFILT_READ)
    backend.push(pool.complete_read, EVFILT_READ)
    assert_true(run_pass_once(handler, backend, st), "the pass did not report the stop")
    assert_equal(
        st.offload.inflight, 0,
        "the completion behind the stop in its batch was never read",
    )
    var got = _text(_read_all(conn[1]))
    assert_true(got.startswith("HTTP/1.1 200"), "the executor's answer never went out")
    assert_true(got.endswith("done"))

    var t0 = perf_counter_ns()
    _run_shutdown(handler, backend, st)
    assert_true(perf_counter_ns() - t0 < 1_000_000_000, "the drain waited")
    assert_equal(st.active_count, 0)
    for fd in [conn[1], pipe[0], pipe[1].fd]:
        close_fd(fd)
    _ = pool.capacity


def test_a_response_behind_the_stop_goes_on_out() raises:
    """A response too large for one send, waiting on its write readiness,
    which arrives behind the pipe. That pass sends more of it.

    A write interest is a one-shot on both backends, so before the fix the
    readiness was spent and nothing else would move the response: it sat
    until the drain gave up on it, and the client got a truncated body.
    """
    var pipe = create_shutdown_pipe()
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), True, shutdown_read_fd=pipe[0]
    )
    var backend = BatchBackend()
    var handler = Recorder(String("x") * (4 * 1024 * 1024))
    var conn = _stream_pair()
    _admit_connection(handler, backend, st, conn[0], String("127.0.0.1"), 1)
    _send_text(conn[1], REQUEST)
    backend.push(conn[0], EVFILT_READ)
    assert_false(run_pass_once(handler, backend, st))
    var slot = st.fd_to_slot[conn[0]]
    assert_equal(
        st.provision_pool.provisions[slot].state.kind, ConnectionState.RESPONDING,
        "the response went out in one send; the test needs one that waits",
    )
    # The client takes what fit, so the socket is writable again.
    var first = _read_all(conn[1])
    assert_true(len(first) > 0)

    backend.push(pipe[0], EVFILT_READ)
    backend.push(conn[0], EVFILT_WRITE)
    assert_true(run_pass_once(handler, backend, st), "the pass did not report the stop")
    assert_true(
        len(_read_all(conn[1])) > 0,
        "the write readiness behind the stop in its batch was never acted on",
    )
    _close_slot(handler, backend, st, slot, conn[0])
    for fd in [conn[1], pipe[0], pipe[1].fd]:
        close_fd(fd)


def test_a_bus_frame_behind_the_stop_is_delivered() raises:
    """A frame another worker broadcast, behind the pipe: that pass hands it
    to the handler, before the drain says goodbye to the streams it was for.
    """
    var bus = socketpair_dgram()
    var pipe = create_shutdown_pipe()
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), True,
        shutdown_read_fd=pipe[0], bus_read_fd=bus[0],
    )
    var backend = BatchBackend()
    var handler = Recorder()
    var payload = List[UInt8](String("data: x\n\n").as_bytes())
    var dg = encode_bus_frame("/events", 7, Span(payload))
    _ = send(FileDescriptor(bus[1]), Span(dg), 0)

    backend.push(pipe[0], EVFILT_READ)
    backend.push(bus[0], EVFILT_READ)
    assert_true(run_pass_once(handler, backend, st), "the pass did not report the stop")
    assert_equal(handler.frames, 1, "the bus frame behind the stop in its batch was never read")
    for fd in [bus[0], bus[1], pipe[0], pipe[1].fd]:
        close_fd(fd)


def test_a_timer_behind_the_stop_fires() raises:
    """The application's tick, behind the pipe: that pass runs it and arms
    the next. kqueue's timers are one-shots, so before the fix a tick spent
    this way never fired again, through the whole drain."""
    var pipe = create_shutdown_pipe()
    var st = LoopState(
        FileDescriptor(-1), _config(), String(""), True, shutdown_read_fd=pipe[0]
    )
    var backend = BatchBackend()
    var handler = Recorder()

    backend.push(pipe[0], EVFILT_READ)
    backend.push(Int(TIMER_APP_TICK), EVFILT_TIMER)
    assert_true(run_pass_once(handler, backend, st), "the pass did not report the stop")
    assert_equal(handler.ticks, 1, "the tick behind the stop in its batch never ran")
    assert_equal(len(backend.timers_armed), 1, "the tick was not armed again")
    assert_equal(backend.timers_armed[0], TIMER_APP_TICK)
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)


def test_the_pass_that_reads_the_stop_admits_no_connection() raises:
    """The one thing the stop changes in its own pass: the listener's
    readiness, behind the pipe, admits nothing, because the drain is about
    to close the listener. The same readiness in a pass without the stop
    admits the connection, so the first half is not vacuous."""
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    set_nonblocking(ln.socket.fd)
    var host = String("127.0.0.1")
    var client = create_connection(host, ln.socket.local_address.port)
    var pipe = create_shutdown_pipe()
    var st = LoopState(ln.socket.fd, _config(), String(""), True, shutdown_read_fd=pipe[0])
    var backend = BatchBackend()
    var handler = Recorder()

    backend.push(pipe[0], EVFILT_READ)
    backend.push(ln.socket.fd.value, EVFILT_READ, 1)
    assert_true(run_pass_once(handler, backend, st), "the pass did not report the stop")
    assert_equal(st.active_count, 0, "the pass that read the stop admitted a connection")

    backend.push(ln.socket.fd.value, EVFILT_READ, 1)
    assert_false(run_pass_once(handler, backend, st))
    assert_equal(st.active_count, 1, "the control pass admitted nothing: the test proves nothing")
    for s in range(st.max_conns):
        if st.slot_fds[s] != UNUSED:
            _close_slot(handler, backend, st, s, st.slot_fds[s])
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)
    _ = client^
    _ = ln^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
