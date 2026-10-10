"""The listener is closed once, by the loop it was given to (review B26).

`run_event_loop` closes the listener as its drain begins
(`_shutdown_begin`). Until this record every owner of a listener closed it
again: a `NoTLSListener`'s socket closes its descriptor when it is
destroyed, and each owner destroyed its listener after the loop returned --
`Server.listen_and_serve_nonblocking` its own, `Server.serve` and
`serve_nonblocking` the caller's, the Mojo host's prefork `serve` its own
before `_join_pool` and the producer's join, and m0serve's inline and
offloaded paths theirs. Between the two closes the drain ran for up to its
5 s with the number free, and a new descriptor is the lowest free number:
in the Linux container a `print`'s `dup(1)` on the loop thread took it, and
pool threads' `.pyc` opens took it dozens of times. The owner's close then
failed EBADF, or -- in the interleaving that matters -- closed a descriptor
that was by then someone else's.

Each test here plays that someone else. Once the drain has closed the
listener, an instrument takes its number, as the next descriptor this
process opened would, and holds it past the serve: it must still be the
instrument's -- a pipe's write end, whose byte arrives at the read end --
when the owner returns. Before the fix every owner closed it. The owner is
driven end to end by one client of the handler's own: the first tick finds
the listener by its port and sends a request, then a second one whose body
has not all arrived; answering the first stops the server; the body still
arriving keeps the drain waiting, the drain's tick places the instrument
and closes the client, and the drain ends. m0serve's two owners live in its entry file, which no test can call;
`smoke-shutdown` meters them under strace on Linux.
"""

from std.ffi import c_int, c_uint, external_call, get_errno
from std.os import getenv, setenv, unsetenv
from std.sys.info import CompilationTarget
from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http import HTTPRequest, HTTPResponse, OK
from lightbug_http.address import NetworkType
from lightbug_http.c.fcntl import F_DUPFD_CLOEXEC, F_GETFD, _fcntl
from lightbug_http.c.fcntl import set_nonblocking
from lightbug_http.c.pipe import ShutdownHandle, close_fd, create_shutdown_pipe
from lightbug_http.c.platform import PlatformBackend
from lightbug_http.c.process import (
    SIG_DFL, SIGINT, SIGTERM, _raw_signal, getpid, kill_process,
)
from lightbug_http.connection import ListenConfig, TCPConnection
from test.loopback import create_connection
from lightbug_http.event_loop import run_event_loop
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.server import Server
from lightbug_http.server_config import ServerConfig
from m0_host.host import AppHandler, HostContext, serve
from m0_http.config import AppConfig


comptime WATCHDOG_S = 60
"""How long one serve may run before SIGALRM ends this file (status 142). A
bound on a hang, never a measurement: each serve here takes milliseconds."""

comptime CELLS_ENV = "M0_TEST_LISTENER_OWNER_CELLS"
"""Where the host's `make` finds the cells: it builds the handler itself."""

comptime C_PORT = 0
"""The port the listener is bound to, which is how the first tick finds it."""
comptime C_STOP = 1
"""The shutdown pipe's write end, or -1: SIGTERM this process (the host's
own signal pipe)."""
comptime C_INSTRUMENT = 2
"""A pipe's write end, which the instrument duplicates onto the number."""
comptime C_NUMBER = 3
"""The listener's number, once found; -1 before."""
comptime C_TAKEN = 4
"""Where the instrument sat once the drain freed the number; -1 before."""
comptime C_ANSWERED = 5
comptime C_ERROR = 6
"""Non-zero if the choreography could not run; the test then fails on it."""
comptime CELLS = 7

comptime FIRST = "GET /first HTTP/1.1\r\nHost: t\r\n\r\n"
comptime ARRIVING = "POST /second HTTP/1.1\r\nHost: t\r\nContent-Length: 10\r\n\r\nabc"
"""The second request, never finished: a connection with a request in
progress is what the drain waits for, and a body still arriving is one
(SPEC D9). Half a request head was the stand-in until #611; that is no
request yet, and the drain now closes it as it begins."""


def _get(cells: Int, i: Int) -> Int:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=cells + 8 * i)[]


def _set(cells: Int, i: Int, value: Int):
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=cells + 8 * i)[] = value


def _is_open(fd: Int) -> Bool:
    """Whether `fd` names an open file in this process."""
    return Int(_fcntl(c_int(fd), c_int(F_GETFD))) != -1


def _local_port(fd: Int) -> Int:
    """The port `fd` is bound to if it is an IPv4 socket, else -1."""
    var addr = unsafe_alloc[UInt8](count=128)
    for i in range(128):
        addr[unsafe_offset=i] = 0
    var size = unsafe_alloc[UInt32](count=1)
    size[unsafe_offset=0] = 128
    var rc = external_call[
        "getsockname", c_int, c_int, type_of(addr), type_of(size)
    ](c_int(fd), addr, size)
    var port = -1
    if Int(rc) == 0:
        var family: Int
        comptime if CompilationTarget.is_macos():
            # BSD's sockaddr opens with a length byte.
            family = Int(addr[unsafe_offset=1])
        else:
            family = Int(addr[unsafe_offset=0]) | (Int(addr[unsafe_offset=1]) << 8)
        if family == 2:
            port = (Int(addr[unsafe_offset=2]) << 8) | Int(addr[unsafe_offset=3])
    addr.unsafe_free()
    size.unsafe_free()
    return port


def _find_listener(port: Int) -> Int:
    """The descriptor bound to `port`: before a connection is accepted, the
    listener is the only one."""
    for fd in range(1024):
        if _local_port(fd) == port:
            return fd
    return -1


def _free_port() raises -> Int:
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    return Int(ln.socket.local_address.port)


def _stop(cells: Int):
    """End the serve: the shutdown pipe the loop watches, or the host's own
    signal pipe, which a SIGTERM to this process writes."""
    var w = _get(cells, C_STOP)
    if w >= 0:
        ShutdownHandle(w).notify()
    else:
        _ = kill_process(getpid(), SIGTERM)


comptime _OpaqueMut = Pointer[NoneType, MutUntrackedOrigin]
"""`read(2)`'s buffer type as `m0_http.threads` declares it: a second
declaration with another signature does not compile beside it."""


def _read_one(fd: Int) -> Int:
    """One byte from a non-blocking `fd`: how many arrived (0 or 1)."""
    var buf = unsafe_alloc[UInt8](count=1)
    var n = external_call["read", Int, Int, _OpaqueMut, Int](
        fd, _OpaqueMut(unsafe_from_address=Int(buf)), 1
    )
    buf.unsafe_free()
    return 1 if n == 1 else 0


struct Reuser(AppHandler):
    """Drives one owner through a drain and puts the instrument on the
    listener's number in the window (module docstring)."""

    var cells: Int
    var client: Optional[TCPConnection[NetworkType.tcp4]]

    def __init__(out self, cells: Int):
        self.cells = cells
        self.client = None

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Self(Int(getenv(CELLS_ENV, "0")))

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        _set(self.cells, C_ANSWERED, _get(self.cells, C_ANSWERED) + 1)
        if req.uri.path == "/first":
            _stop(self.cells)
        return OK(String("answered"), "text/plain")

    def tick(mut self, now_ms: Int):
        var number = _get(self.cells, C_NUMBER)
        if number < 0:
            number = _find_listener(_get(self.cells, C_PORT))
            if number < 0:
                _set(self.cells, C_ERROR, 1)
                _stop(self.cells)
                return
            _set(self.cells, C_NUMBER, number)
            try:
                var host = String("127.0.0.1")
                var conn = create_connection(host, UInt16(_get(self.cells, C_PORT)))
                var text = String(FIRST) + String(ARRIVING)
                _ = conn.write(text.as_bytes())
                self.client = conn^
            except:
                _set(self.cells, C_ERROR, 2)
                _stop(self.cells)
            return
        if _get(self.cells, C_TAKEN) < 0 and not _is_open(number):
            # The drain has closed the listener. Take its number, as the
            # next descriptor opened anywhere in this process would.
            var taken = Int(_fcntl(
                c_int(_get(self.cells, C_INSTRUMENT)),
                c_int(F_DUPFD_CLOEXEC),
                c_int(number),
            ))
            _set(self.cells, C_TAKEN, taken)
            # The second request can never finish now, so the drain closes
            # the connection and ends.
            self.client = None


def _cells(port: Int, stop: Int, instrument: Int) -> Int:
    var cells = unsafe_alloc[Int](count=CELLS)
    var addr = Int(cells)
    for i in range(CELLS):
        _set(addr, i, -1)
    _set(addr, C_PORT, port)
    _set(addr, C_STOP, stop)
    _set(addr, C_INSTRUMENT, instrument)
    _set(addr, C_ANSWERED, 0)
    _set(addr, C_ERROR, 0)
    return addr


def _config() -> ServerConfig:
    var config = ServerConfig()
    config.max_connections = 8
    config.sse_heartbeat_ms = 0
    config.app_tick_ms = 10
    return config^


def _arm_watchdog(what: StringSpan):
    print(
        "watchdog:", what, "must return within", WATCHDOG_S,
        "s, or SIGALRM ends this file (status 142)", flush=True,
    )
    _ = external_call["alarm", c_uint](c_uint(WATCHDOG_S))


def _disarm_watchdog():
    _ = external_call["alarm", c_uint](c_uint(0))


def _assert_the_instrument_survived(cells: Int, read_end: Int, owner: String) raises:
    """The number the instrument took after the drain is still its own."""
    assert_equal(_get(cells, C_ERROR), 0, "the choreography did not run (see C_ERROR)")
    assert_equal(_get(cells, C_ANSWERED), 1, "the first request was not answered")
    var number = _get(cells, C_NUMBER)
    var taken = _get(cells, C_TAKEN)
    assert_true(number >= 0, "the first tick never found the listener")
    assert_equal(
        taken, number,
        "the instrument did not get the listener's number after the drain:"
        + " something else took it first, and the test proves nothing",
    )
    ShutdownHandle(taken).notify()
    var arrived = _read_one(read_end)
    close_fd(taken)
    close_fd(read_end)
    assert_equal(
        arrived, 1,
        owner + " closed descriptor " + String(number)
        + " after its loop ended: the drain had closed the listener, and"
        + " the number was the instrument's by then",
    )


def _instrument() raises -> Tuple[Int, Int]:
    """A pipe: (read end, non-blocking; write end, for the instrument)."""
    var p = create_shutdown_pipe()
    set_nonblocking(FileDescriptor(p[0]))
    return (p[0], p[1].fd)


def test_listen_and_serve_leaves_the_number_to_its_next_owner() raises:
    """`Server.listen_and_serve`: the listener the server made is closed
    by the drain alone.

    covers: D1
    """
    var port = _free_port()
    var stop = create_shutdown_pipe()
    var pipe = _instrument()
    var cells = _cells(port, stop[1].fd, pipe[1])
    var server = Server(_config(), shutdown_read_fd=stop[0])
    var handler = Reuser(cells)
    _arm_watchdog("Server.listen_and_serve")
    server.listen_and_serve("127.0.0.1:" + String(port), handler)
    _disarm_watchdog()
    close_fd(pipe[1])
    close_fd(stop[0])
    close_fd(stop[1].fd)
    _assert_the_instrument_survived(cells, pipe[0], "Server.listen_and_serve")


def test_serve_leaves_the_number_to_its_next_owner() raises:
    """`Server.serve`: a listener the caller made is the loop's once given,
    and nothing closes it after.

    covers: D1
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var port = Int(ln.socket.local_address.port)
    var stop = create_shutdown_pipe()
    var pipe = _instrument()
    var cells = _cells(port, stop[1].fd, pipe[1])
    var server = Server(_config(), shutdown_read_fd=stop[0])
    var handler = Reuser(cells)
    _arm_watchdog("Server.serve")
    server.serve(ln^, handler)
    _disarm_watchdog()
    close_fd(pipe[1])
    close_fd(stop[0])
    close_fd(stop[1].fd)
    _assert_the_instrument_survived(cells, pipe[0], "Server.serve")


def test_the_host_leaves_the_number_to_its_next_owner() raises:
    """The Mojo host's prefork `serve`, one worker: its listener went
    before `_join_pool` and the producer's join, where a straggler thread
    may hold the number.

    covers: D1
    """
    var port = _free_port()
    var pipe = _instrument()
    var cells = _cells(port, -1, pipe[1])
    _ = setenv(CELLS_ENV, String(cells), True)
    var seed = AppConfig(default_port=port)
    seed.host = "127.0.0.1"
    seed.port = port
    seed.workers = 1
    seed.threads = 1
    seed.blocking_threads = 0
    var server_config = seed.server_config()
    server_config.max_connections = 8
    server_config.sse_heartbeat_ms = 0
    server_config.app_tick_ms = 10
    _arm_watchdog("the host's serve")
    serve[Reuser](seed, server_config^)
    _disarm_watchdog()
    # `serve` armed SIGTERM and SIGINT to write its pipe; put the defaults
    # back, so this file still ends on either.
    _ = _raw_signal(c_int(SIGTERM), SIG_DFL)
    _ = _raw_signal(c_int(SIGINT), SIG_DFL)
    _ = unsetenv(CELLS_ENV)
    close_fd(pipe[1])
    _assert_the_instrument_survived(cells, pipe[0], "the host's serve")


comptime FAIL_REGISTERING = 0
"""`prepare_loop` raises: the listener cannot be registered."""
comptime FAIL_WAITING = 1
"""The first wait raises, before any drain."""
comptime FAIL_DRAINING = 2
"""The first wait after the drain closed the listener raises, having put
the instrument on its number first."""


struct FailingBackend(EventLoopBackend):
    """The platform's backend, raising where `mode` says."""

    var inner: PlatformBackend
    var cells: Int
    var mode: Int

    def __init__(out self, cells: Int, mode: Int) raises:
        self.inner = PlatformBackend()
        self.cells = cells
        self.mode = mode

    def wait(mut self, timeout_ms: Int) raises -> Int:
        if self.mode == FAIL_WAITING:
            raise Error("the backend failed before the drain")
        var number = _get(self.cells, C_NUMBER)
        if not _is_open(number):
            _set(self.cells, C_TAKEN, Int(_fcntl(
                c_int(_get(self.cells, C_INSTRUMENT)),
                c_int(F_DUPFD_CLOEXEC),
                c_int(number),
            )))
            raise Error("the backend failed during the drain")
        return self.inner.wait(timeout_ms)

    def event_ident(self, i: Int) -> UInt:
        return self.inner.event_ident(i)

    def event_filter(self, i: Int) -> Int16:
        return self.inner.event_filter(i)

    def event_flags(self, i: Int) -> UInt16:
        return self.inner.event_flags(i)

    def event_data(self, i: Int) -> Int:
        return self.inner.event_data(i)

    def add_read_listen(mut self, fd: Int) raises:
        if self.mode == FAIL_REGISTERING:
            raise Error("the backend could not register the listener")
        self.inner.add_read_listen(fd)

    def add_read(mut self, fd: Int) raises:
        self.inner.add_read(fd)

    def try_add_read(mut self, fd: Int):
        self.inner.try_add_read(fd)

    def add_write_oneshot(mut self, fd: Int) raises:
        self.inner.add_write_oneshot(fd)

    def try_add_write_oneshot(mut self, fd: Int):
        self.inner.try_add_write_oneshot(fd)

    def try_delete_read(mut self, fd: Int):
        self.inner.try_delete_read(fd)

    def try_delete_write(mut self, fd: Int):
        self.inner.try_delete_write(fd)

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        self.inner.try_add_timer(ident, timeout_ms)

    def try_delete_timer(mut self, ident: UInt):
        self.inner.try_delete_timer(ident)


def _raise_before_the_drain(mode: Int, where: String) raises:
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var port = Int(ln.socket.local_address.port)
    var number = ln.socket.fd.value
    var stop = create_shutdown_pipe()
    var cells = _cells(port, stop[1].fd, -1)
    var handler = Reuser(cells)
    var backend = FailingBackend(cells, mode)
    var raised = False
    try:
        run_event_loop(
            ln^.into_fd(), handler, backend, _config(), String("127.0.0.1"),
            True, shutdown_read_fd=stop[0],
        )
    except:
        raised = True
    close_fd(stop[0])
    close_fd(stop[1].fd)
    assert_true(raised, "the backend's raise did not reach the caller")
    assert_true(
        _local_port(number) != port,
        "a loop that raised " + where + " left its listener open, and"
        + " nothing else holds it to close it",
    )


def test_a_loop_that_raises_before_its_drain_closes_its_listener() raises:
    """The loop owns the listener on every path: one that raises before its
    drain has closed it -- while registering it, or waiting -- closes it on
    the way out, as the owner's destructor did when the owner kept it.

    covers: D1
    """
    _raise_before_the_drain(FAIL_REGISTERING, "registering it")
    _raise_before_the_drain(FAIL_WAITING, "waiting")


def test_a_loop_that_raises_during_its_drain_closes_nothing_more() raises:
    """A raise after the drain closed the listener closes nothing on the
    way out: the number is free by then, and the instrument holds it.

    covers: D1
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var port = Int(ln.socket.local_address.port)
    var number = ln.socket.fd.value
    var stop = create_shutdown_pipe()
    var pipe = _instrument()
    var cells = _cells(port, stop[1].fd, pipe[1])
    _set(cells, C_NUMBER, number)
    var host = String("127.0.0.1")
    var client = create_connection(host, UInt16(port))
    var text = String(FIRST) + String(ARRIVING)
    _ = client.write(text.as_bytes())
    var handler = Reuser(cells)
    var backend = FailingBackend(cells, FAIL_DRAINING)
    var raised = False
    _arm_watchdog("run_event_loop over a failing backend")
    try:
        run_event_loop(
            ln^.into_fd(), handler, backend, _config(), String("127.0.0.1"),
            True, shutdown_read_fd=stop[0],
        )
    except:
        raised = True
    _disarm_watchdog()
    _ = client^
    close_fd(pipe[1])
    close_fd(stop[0])
    close_fd(stop[1].fd)
    assert_true(raised, "the drain never waited: the test proves nothing")
    _assert_the_instrument_survived(cells, pipe[0], "run_event_loop's raise")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
