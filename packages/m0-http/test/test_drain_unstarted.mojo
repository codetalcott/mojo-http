"""The drain waits only for requests whose head has arrived (#611).

A keep-alive connection that was answered and then sent a stray CRLF, or
the first bytes of its next request, held the SIGTERM drain to its 5 s
deadline: `_close_between_requests` took an empty receive buffer to mean
"between requests", and `prepare_for_new_request` keeps the answered
request's bytes whenever anything follows them, moving `head_start` to the
tail. Measured against m0serve 1.14.0: 0.08 s to exit with nothing after
the request, 5.15 s with one CRLF after it, 5.13 s with `GET /ne`.

A head still arriving is a request not yet made, and the drain closes its
connection as it closes an idle one; a body still arriving belongs to a
request whose head has, and is read on (SPEC D9). When the budget rather
than the work ends a drain, the drain says what it is leaving.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.c.kqueue import EVFILT_READ
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import recv, send
from lightbug_http.connection import ConnectionState, ListenConfig
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.io.bytes import Bytes
from lightbug_http.loop.accept import _admit_connection
from lightbug_http.loop.shutdown import (
    DRAIN_TIMEOUT_NS,
    _holds_a_request,
    _shutdown_begin,
    _shutdown_drain_step,
    _unfinished_at_deadline,
)
from lightbug_http.loop.state import LoopState, UNUSED, _close_slot
from lightbug_http.server_config import ServerConfig

from test.support import _stream_pair


struct QuietBackend(EventLoopBackend):
    """A backend whose `wait` returns the events pushed since the last one."""

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


def _config() -> ServerConfig:
    var config = ServerConfig()
    config.max_connections = SLOTS
    config.sse_heartbeat_ms = 0
    return config^


def _send_text(fd: Int, text: String) raises:
    var b = List[UInt8](text.as_bytes())
    assert_equal(Int(send(FileDescriptor(fd), Span(b), 0)), len(b))


def _read_all(fd: Int) -> String:
    """Everything waiting on `fd`, without blocking, and whether it ended."""
    var out = List[UInt8]()
    var buf = List[UInt8](length=65536, fill=0)
    while True:
        var n: UInt
        try:
            n = recv(FileDescriptor(fd), Span(buf), MSG_DONTWAIT)
        except:
            break
        if n == 0:
            out.append(0)  # EOF, marked so a test can tell
            break
        for i in range(Int(n)):
            out.append(buf[i])
    return String(from_utf8_lossy=Span(out))


def _close_all[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState
):
    for s in range(st.max_conns):
        if st.slot_fds[s] != UNUSED:
            _close_slot(handler, backend, st, s, st.slot_fds[s])


def _slot_of(st: LoopState, fd: Int) -> Int:
    for s in range(st.max_conns):
        if st.slot_fds[s] == fd:
            return s
    return -1


def _drain_after(sent: String) raises -> Tuple[Int, Int, String]:
    """Admit a connection that sent `sent`, then begin the drain.

    Returns the requests answered before the drain, the connections the
    drain's beginning left open, and what the client read, EOF marked as a
    NUL at the end.
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var pipe = create_shutdown_pipe()
    var st = LoopState(ln.socket.fd, _config(), String(""), True, shutdown_read_fd=pipe[0])
    var backend = QuietBackend()
    var handler = Recorder()
    var conn = _stream_pair()
    _send_text(conn[1], sent)
    _admit_connection(handler, backend, st, conn[0], String("127.0.0.1"), 1)
    var answered = handler.requests
    assert_equal(st.active_count, 1, "the connection was not kept alive after its request")
    _ = _shutdown_begin(handler, backend, st)
    var left = st.active_count
    var read = _read_all(conn[1])
    _close_all(handler, backend, st)
    close_fd(conn[1])
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)
    _ = ln^
    return (answered, left, read)


def test_empty_lines_after_a_request_are_no_request() raises:
    """An answered keep-alive connection that then sent an empty line is
    closed when the drain begins, with its answer delivered.

    A second empty line, or a bare LF, is answered 400 and closed by the
    request path itself: RFC 9112 §2.2 asks a server to skip at least one
    CRLF, and this one skips exactly that.

    covers: D14
    """
    var got = _drain_after(String("GET / HTTP/1.1\r\nHost: t\r\n\r\n\r\n"))
    assert_equal(got[0], 1, "the request before the empty line was not answered")
    assert_equal(
        got[1], 0, "a connection holding an empty line was kept for the drain to wait on"
    )
    assert_true(got[2].startswith("HTTP/1.1 200"), "the answer did not reach the client")
    assert_true(got[2].endswith("\0"), "the connection was not closed")


def test_the_first_bytes_of_a_next_request_are_no_request() raises:
    """An answered keep-alive connection holding the start of its next
    request's head is closed when the drain begins: the head has not
    arrived, so nothing has been asked.

    covers: D14
    """
    for tail in [String("GET /ne"), String("\r\nGET / HTTP/1.1\r\nHost: t\r\n")]:
        var got = _drain_after(String("GET / HTTP/1.1\r\nHost: t\r\n\r\n") + tail)
        assert_equal(got[0], 1, "the first request was not answered")
        assert_equal(
            got[1], 0, "a head still arriving was kept for the drain to wait on"
        )
        assert_true(got[2].endswith("\0"), "the connection was not closed")


def test_only_a_whole_head_holds_a_request() raises:
    """The rule itself, from `head_start`: empty lines and a head still
    arriving hold no request; a whole head does, after leading empty lines
    too, and bytes before `head_start` are the answered request's.

    covers: D14
    """
    var answered = String("GET /a HTTP/1.1\r\nHost: t\r\n\r\n")
    var base = answered.byte_length()
    var cases = [
        (String(""), False),
        (String("\r\n"), False),
        (String("\r\n\r\n\r\n"), False),
        (String("\n\n"), False),
        (String("G"), False),
        (String("GET /ne"), False),
        (String("GET / HTTP/1.1\r\nHost: t\r\n"), False),
        (String("GET / HTTP/1.1\r\nHost: t\r\n\r\n"), True),
        (String("\r\nGET / HTTP/1.1\r\nHost: t\r\n\r\n"), True),
        (String("GET / HTTP/1.1\nHost: t\n\n"), True),
    ]
    for c in cases:
        var buf = Bytes((answered + c[0]).as_bytes())
        assert_equal(
            _holds_a_request(buf, base), c[1],
            String("after an answered request: ", repr(c[0])),
        )
    # Nothing past the end, and a start past it, are no request.
    assert_false(_holds_a_request(Bytes(answered.as_bytes()), base + 5))


def test_a_body_still_arriving_is_read_on() raises:
    """A request whose head has arrived and whose body has not is kept by
    the drain and answered when the rest comes, as D9 requires: the close
    above takes only connections whose head has not arrived.

    covers: D14
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var pipe = create_shutdown_pipe()
    var st = LoopState(ln.socket.fd, _config(), String(""), True, shutdown_read_fd=pipe[0])
    var backend = QuietBackend()
    var handler = Recorder()
    var conn = _stream_pair()
    _send_text(conn[1], "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 10\r\n\r\nabc")
    _admit_connection(handler, backend, st, conn[0], String("127.0.0.1"), 1)
    var drain_start = _shutdown_begin(handler, backend, st)
    assert_equal(st.active_count, 1, "the drain closed a request whose body was arriving")
    _send_text(conn[1], "defghij")
    backend.push(conn[0], EVFILT_READ)
    _ = _shutdown_drain_step(handler, backend, st, drain_start, 0)
    assert_equal(handler.requests, 1, "the request was not answered once its body arrived")
    assert_true(_read_all(conn[1]).startswith("HTTP/1.1 200"), "the answer did not arrive")
    _close_all(handler, backend, st)
    close_fd(conn[1])
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)
    _ = ln^


def test_the_deadline_names_what_it_leaves() raises:
    """A drain its budget ends says what it is leaving, by what each
    connection was doing; one with nothing left says nothing.

    covers: D15
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var pipe = create_shutdown_pipe()
    var st = LoopState(ln.socket.fd, _config(), String(""), True, shutdown_read_fd=pipe[0])
    var backend = QuietBackend()
    var handler = Recorder()
    assert_equal(_unfinished_at_deadline(st), String(""), "an empty loop named something")

    var conn = _stream_pair()
    _send_text(conn[1], "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 10\r\n\r\nabc")
    _admit_connection(handler, backend, st, conn[0], String("127.0.0.1"), 1)
    var slot = _slot_of(st, conn[0])
    assert_equal(
        st.provision_pool.provisions[slot].state.kind, ConnectionState.READING_BODY
    )
    var line = _unfinished_at_deadline(st)
    assert_true(
        "1 with a request body still arriving" in line,
        String("the deadline's line did not name the body: ", repr(line)),
    )
    assert_true("5 s budget" in line, String("the line did not name the budget: ", repr(line)))

    # And the drain step ends on its budget with the connection still open.
    var spent = perf_counter_ns() - DRAIN_TIMEOUT_NS - 1
    assert_true(_shutdown_drain_step(handler, backend, st, spent, 0))
    assert_equal(st.active_count, 1)
    _close_all(handler, backend, st)
    close_fd(conn[1])
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)
    _ = ln^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
