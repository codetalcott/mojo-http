"""The drain stops watching the listener before it closes it (review B24).

`_shutdown_begin` closes the listener so that the drain accepts nothing. On
epoll that close did not take the listener out of the worker's interest
list. A registration belongs to the open file DESCRIPTION, not to the number,
and under `--workers N` the supervisor and every sibling still hold the
listener's description, so the registration stayed: a connection waiting
for a sibling to accept it woke the draining worker too, tagged with a
descriptor number that worker had just freed (measured in the Linux
container with the siblings slow to accept: 50 connections, 50 `accept`
calls on the old number failing EBADF).

The next descriptor the drain was given took that number, because a new
descriptor is the lowest free one. A connection a sibling handed over during
the drain was such a descriptor. Its reads then matched `st.listen_fd` and
went to the accept path, which failed on a connected socket with EINVAL; the
request was never read, and the drain waited out its budget. kqueue drops a
descriptor's filters when the process closes it, so macOS never had the
stale registration; the misrouting needs only the number, and holds there
too.

Three tests: the listener is deregistered while its number still names it,
a connection given that number afterwards is read as a connection, and --
over the platform's own backend -- a connection to a listener still open
elsewhere raises nothing in the loop that closed its reference.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.c.fcntl import F_GETFD, _fcntl
from lightbug_http.c.kqueue import EVFILT_READ, set_nonblocking
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.platform import MSG_DONTWAIT, PlatformBackend
from lightbug_http.c.socket import recv, send
from lightbug_http.connection import ListenConfig
from test.loopback import create_connection
from lightbug_http.event_loop import prepare_loop
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.loop.accept import _admit_connection
from lightbug_http.loop.shutdown import _shutdown_begin, _shutdown_drain_step
from lightbug_http.loop.state import LoopState, UNUSED, _close_slot
from lightbug_http.server_config import ServerConfig

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc


def _is_open(fd: Int) -> Bool:
    """Whether `fd` names an open file in this process."""
    return Int(_fcntl(c_int(fd), c_int(F_GETFD))) != -1


struct RecordingBackend(EventLoopBackend):
    """A backend whose next `wait` returns the events pushed since the last
    one, and which records each read deregistration with whether the number
    was still open when it was asked for."""

    var next_ident: List[Int]
    var next_filter: List[Int16]
    var ident: List[Int]
    var filter: List[Int16]
    var deleted: List[Int]
    var deleted_open: List[Bool]

    def __init__(out self):
        self.next_ident = List[Int]()
        self.next_filter = List[Int16]()
        self.ident = List[Int]()
        self.filter = List[Int16]()
        self.deleted = List[Int]()
        self.deleted_open = List[Bool]()

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
        self.deleted.append(fd)
        self.deleted_open.append(_is_open(fd))

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


def _move_to(fd: Int, number: Int) raises:
    """Put `fd`'s file at `number` and close `fd`: what the kernel does for
    the next descriptor a process is given when `number` is its lowest free
    one, done on purpose so the test does not depend on which numbers the
    runner left free. The kernel may have given `fd` that number already."""
    if fd == number:
        return
    var rc = external_call["dup2", c_int, c_int, c_int](c_int(fd), c_int(number))
    if Int(rc) != number:
        raise Error("dup2() failed, errno: ", get_errno())
    close_fd(fd)


def _send_text(fd: Int, text: String) raises:
    var b = List[UInt8](text.as_bytes())
    assert_equal(Int(send(FileDescriptor(fd), Span(b), UInt(len(b)), 0)), len(b))


def _read_all(fd: Int) -> String:
    """Everything waiting on `fd`, without blocking."""
    var out = List[UInt8]()
    var buf = List[UInt8](length=65536, fill=0)
    while True:
        var n: UInt
        try:
            n = recv(FileDescriptor(fd), Span(buf), UInt(len(buf)), MSG_DONTWAIT)
        except:
            break
        if n == 0:
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


def test_the_drain_deregisters_the_listener_before_closing_it() raises:
    """The drain asks the backend to stop watching the listener while the
    number still names it, and then forgets the number.

    A deregistration after the close is no deregistration on epoll: DEL is
    looked up by the number, which then names nothing (EBADF) or a stranger,
    while the stale entry stays. And a number the loop still held after the
    close is one the next descriptor could take (the next test).

    covers: D1
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var listen_number = ln.socket.fd.value
    # A sibling's reference: the description outlives this loop's close, as
    # it does under `--workers N`.
    var sibling = Int(external_call["dup", c_int, c_int](c_int(listen_number)))
    var pipe = create_shutdown_pipe()
    var st = LoopState(ln.socket.fd, _config(), String(""), True, shutdown_read_fd=pipe[0])
    var backend = RecordingBackend()
    var handler = Recorder()

    _ = _shutdown_begin(handler, backend, st)

    var asked = False
    for i in range(len(backend.deleted)):
        if backend.deleted[i] == listen_number:
            asked = True
            assert_true(
                backend.deleted_open[i],
                "the listener was deregistered after its number was closed",
            )
    assert_true(asked, "the drain closed the listener without deregistering it")
    assert_false(_is_open(listen_number), "the drain did not close its reference")
    assert_true(
        st.listen_fd.value != listen_number,
        "the loop still names the listener's number after closing it",
    )
    close_fd(sibling)
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)
    # Its number is closed already; the owner's own close finds EBADF.
    _ = ln^


def test_a_connection_given_the_listeners_number_is_read() raises:
    """A connection a sibling hands over during the drain, given the number
    the listener just freed, has its request read and answered.

    The connection's request arrives in two parts, so the admission's eager
    read takes the first and the rest comes as a read event, tagged with the
    old number. Before the fix that event matched `st.listen_fd`, went to the
    accept path (EINVAL on a connected socket), and the request was never
    read: 0 requests, nothing sent.

    covers: D1
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var listen_number = ln.socket.fd.value
    var sibling = Int(external_call["dup", c_int, c_int](c_int(listen_number)))
    var pipe = create_shutdown_pipe()
    var st = LoopState(ln.socket.fd, _config(), String(""), True, shutdown_read_fd=pipe[0])
    var backend = RecordingBackend()
    var handler = Recorder()
    var drain_start = _shutdown_begin(handler, backend, st)
    assert_false(_is_open(listen_number))

    var conn = _stream_pair()
    _move_to(conn[0], listen_number)
    _send_text(conn[1], "GET /x HTTP/1.1\r\n")
    _admit_connection(handler, backend, st, listen_number, String("127.0.0.1"), 1)
    assert_equal(st.active_count, 1)
    assert_equal(handler.requests, 0, "the first part alone was answered")

    _send_text(conn[1], "Host: t\r\n\r\n")
    backend.push(listen_number, EVFILT_READ)
    _ = _shutdown_drain_step(handler, backend, st, drain_start, 0)
    assert_equal(
        handler.requests, 1,
        "the read on the listener's old number was taken for the listener's",
    )
    assert_true(_read_all(conn[1]).startswith("HTTP/1.1 200"), "the request was not answered")

    _close_all(handler, backend, st)
    close_fd(conn[1])
    close_fd(sibling)
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)
    _ = ln^


def test_a_listener_open_elsewhere_raises_nothing_after_the_close() raises:
    """Over the platform's own backend: once the drain has closed its
    reference, a connection to the listener -- still listening, through a
    sibling's reference -- raises no event in this loop.

    Before the fix, epoll reported it, tagged with the old number, once for
    every connection the siblings took; kqueue dropped the filter at the
    close and reported nothing, so on macOS this passes either way and the
    two tests above are the gate.

    covers: D1
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var port = ln.socket.local_address.port
    var sibling = Int(external_call["dup", c_int, c_int](c_int(ln.socket.fd.value)))
    var pipe = create_shutdown_pipe()
    var backend = PlatformBackend()
    var st = prepare_loop(
        ln.socket.fd, backend, _config(), String(""), True, shutdown_read_fd=pipe[0]
    )
    var handler = Recorder()
    _ = _shutdown_begin(handler, backend, st)

    var host = String("127.0.0.1")
    var client = create_connection(host, port)
    var n = backend.wait(200)
    for i in range(n):
        assert_true(
            False,
            String(
                "an event for number ", backend.event_ident(i),
                " after the listener was closed (it was number ",
                ln.socket.fd.value, ")",
            ),
        )
    assert_equal(n, 0)

    _ = client^
    close_fd(sibling)
    for fd in [pipe[0], pipe[1].fd]:
        close_fd(fd)
    _ = ln^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
