"""Every socket wrapper raises on failure, whatever the errno (review
record B9).

The upstream wrappers gave each errno their man page listed a type of its
own and returned normally for any other: `socket()` handed back -1 as a
descriptor for EPROTOTYPE, and `listen()` on a connected socket, EINVAL,
reported success. Each wrapper now raises one `SysError` naming the call
and its errno. These tests provoke a failure from every wrapper and require
the raise -- two with an errno the old ladders left out, the second on both
platforms -- and hold the predicates the event loop, the handler pool and
the listener's bind retry read.
"""

from std.collections import Optional
from std.ffi import ErrNo, c_int
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from lightbug_http.c.network import SocketAddress
from lightbug_http.c.pipe import close_fd
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.c.socket import (
    SOL_SOCKET,
    ShutdownOption,
    SocketOption,
    accept_with_peer,
    bind,
    close,
    getpeername,
    getsockname,
    listen,
    recv,
    send,
    setsockopt,
    shutdown,
    socket,
)
from lightbug_http.c.socket_error import SysError
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.connection import ListenConfig
from test.loopback import create_connection
from lightbug_http.loop.accept import _accept_retries


comptime AF_INET = 2
comptime SOCK_STREAM = 1
comptime IPPROTO_UDP = 17

comptime NOT_OPEN = 1 << 20
"""A descriptor number no process here reaches, so EBADF from every call."""


def _expect(err: Optional[SysError], op: String, errno: ErrNo) raises:
    """Require a raise, naming `op` and carrying `errno`."""
    assert_true(Bool(err), op + " returned instead of raising")
    var e = err.value()
    assert_equal(String(e.op), op)
    assert_true(e.errno == errno, String(e))


def test_socket_raises_where_it_returned_minus_one() raises:
    """A stream socket asked for UDP. macOS answers EPROTOTYPE, which the
    old ladder did not list, so -1 came back as the descriptor; Linux
    answers EPROTONOSUPPORT."""
    var err: Optional[SysError] = None
    var fd = c_int(0)
    try:
        fd = socket(c_int(AF_INET), c_int(SOCK_STREAM), c_int(IPPROTO_UDP))
    except e:
        err = e
    if not err and fd >= 0:
        close_fd(Int(fd))
    assert_true(Bool(err), "socket() returned " + String(fd) + " instead of raising")
    var e = err.value()
    assert_equal(String(e.op), "socket")
    assert_true(
        e.errno == ErrNo.EPROTOTYPE or e.errno == ErrNo.EPROTONOSUPPORT, String(e)
    )


def test_listen_raises_on_a_connected_socket() raises:
    """EINVAL on macOS and Linux alike, and not on the old ladder: `listen()`
    reported success for a socket that can never accept."""
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var host = String("127.0.0.1")
    var client = create_connection(host, ln.socket.local_address.port)
    var err: Optional[SysError] = None
    try:
        listen(client.socket.fd, c_int(4))
    except e:
        err = e
    _expect(err, "listen", ErrNo.EINVAL)
    _ = client^
    _ = ln^


def test_every_wrapper_raises_on_a_descriptor_that_is_not_open() raises:
    """EBADF from each call, each naming itself. The old ladders listed EBADF
    for most of them; the table holds the contract for every one."""
    var bad = FileDescriptor(NOT_OPEN)
    var addr = SocketAddress()
    var buf = List[UInt8](length=16, fill=0)
    var err: Optional[SysError] = None

    try:
        getsockname(bad, addr)
    except e:
        err = e
    _expect(err, "getsockname", ErrNo.EBADF)

    err = None
    try:
        _ = getpeername(bad)
    except e:
        err = e
    _expect(err, "getpeername", ErrNo.EBADF)

    err = None
    try:
        bind(bad, addr)
    except e:
        err = e
    _expect(err, "bind", ErrNo.EBADF)

    err = None
    try:
        listen(bad, c_int(1))
    except e:
        err = e
    _expect(err, "listen", ErrNo.EBADF)

    err = None
    try:
        _ = accept_with_peer(bad)
    except e:
        err = e
    _expect(err, "accept", ErrNo.EBADF)

    err = None
    try:
        _ = recv(bad, Span(buf), UInt(len(buf)), c_int(0))
    except e:
        err = e
    _expect(err, "recv", ErrNo.EBADF)

    err = None
    try:
        _ = send(bad, Span(buf), UInt(len(buf)), c_int(0))
    except e:
        err = e
    _expect(err, "send", ErrNo.EBADF)

    err = None
    try:
        setsockopt(bad, c_int(SOL_SOCKET), SocketOption.SO_REUSEADDR.value, c_int(1))
    except e:
        err = e
    _expect(err, "setsockopt", ErrNo.EBADF)

    err = None
    try:
        shutdown(bad, ShutdownOption.SHUT_RDWR)
    except e:
        err = e
    _expect(err, "shutdown", ErrNo.EBADF)

    err = None
    try:
        close(bad)
    except e:
        err = e
    _expect(err, "close", ErrNo.EBADF)


def test_an_empty_nonblocking_read_would_block() raises:
    """The errno every read path in the event loop waits on rather than
    closing the connection, read from a real empty socket."""
    var pair = socketpair_dgram()
    var buf = List[UInt8](length=16, fill=0)
    var err: Optional[SysError] = None
    try:
        _ = recv(FileDescriptor(pair[0]), Span(buf), UInt(len(buf)), MSG_DONTWAIT)
    except e:
        err = e
    close_fd(pair[0])
    close_fd(pair[1])
    assert_true(Bool(err), "a recv with nothing queued returned")
    var e = err.value()
    assert_equal(String(e.op), "recv")
    assert_true(e.would_block(), String(e))
    assert_false(e.interrupted(), String(e))


def test_the_predicates_read_the_errno() raises:
    assert_true(SysError("recv", ErrNo.EAGAIN).would_block())
    assert_true(SysError("recv", ErrNo.EWOULDBLOCK).would_block())
    assert_false(SysError("recv", ErrNo.EINTR).would_block())
    assert_false(SysError("recv", ErrNo.ECONNRESET).would_block())
    assert_true(SysError("recv", ErrNo.EINTR).interrupted())
    assert_false(SysError("recv", ErrNo.EAGAIN).interrupted())
    assert_true(SysError("accept", ErrNo.ECONNABORTED).connection_aborted())
    assert_false(SysError("accept", ErrNo.EMFILE).connection_aborted())
    assert_true(SysError("bind", ErrNo.EADDRINUSE).address_in_use())
    assert_false(SysError("bind", ErrNo.EADDRNOTAVAIL).address_in_use())


def _goes_on(errno: ErrNo) -> Bool:
    return _accept_retries(SysError("accept", errno))


def test_the_accept_drain_goes_on_past_one_connections_error() raises:
    """`_accept_retries`: whether the loop's accept drain takes the next
    connection after a failed `accept`, or stops the pass.

    ECONNABORTED and EINTR go on everywhere. On Linux so do the eight
    network errors accept(2) returns for a connection it has already taken
    off the queue and says to retry like EAGAIN: read as anything else,
    they stopped the pass, and the listener is edge-triggered, so the
    backlog behind them waited for the next connection to arrive. macOS
    returns none of them, and its EOPNOTSUPP is a listener that cannot
    accept at all. What a retry cannot cure stops the pass everywhere.
    """
    assert_true(_goes_on(ErrNo.ECONNABORTED), "ECONNABORTED")
    assert_true(_goes_on(ErrNo.EINTR), "EINTR")
    assert_false(_goes_on(ErrNo.EAGAIN), "EAGAIN ends the drain on its own path")
    assert_false(_goes_on(ErrNo.EMFILE), "EMFILE")
    assert_false(_goes_on(ErrNo.ENFILE), "ENFILE")
    assert_false(_goes_on(ErrNo.ENOBUFS), "ENOBUFS")
    assert_false(_goes_on(ErrNo.ENOMEM), "ENOMEM")
    assert_false(_goes_on(ErrNo.EBADF), "EBADF")
    assert_false(_goes_on(ErrNo.EPERM), "EPERM")
    comptime if CompilationTarget.is_macos():
        assert_false(_goes_on(ErrNo.EOPNOTSUPP), "EOPNOTSUPP on macOS")
        assert_false(_goes_on(ErrNo.ENETDOWN), "ENETDOWN on macOS")
    else:
        assert_true(_goes_on(ErrNo.ENETDOWN), "ENETDOWN")
        assert_true(_goes_on(ErrNo.EPROTO), "EPROTO")
        assert_true(_goes_on(ErrNo.ENOPROTOOPT), "ENOPROTOOPT")
        assert_true(_goes_on(ErrNo.EHOSTDOWN), "EHOSTDOWN")
        assert_true(_goes_on(ErrNo.ENONET), "ENONET")
        assert_true(_goes_on(ErrNo.EHOSTUNREACH), "EHOSTUNREACH")
        assert_true(_goes_on(ErrNo.EOPNOTSUPP), "EOPNOTSUPP")
        assert_true(_goes_on(ErrNo.ENETUNREACH), "ENETUNREACH")


def test_the_error_names_the_call_and_its_errno() raises:
    """The text m0serve prints for a listener it could not make."""
    var text = String(SysError("listen", ErrNo.EINVAL))
    assert_true(text.startswith("listen: "), text)
    assert_true(text.find("Invalid argument") >= 0, text)
    assert_true(
        text.endswith("(errno " + String(Int(ErrNo.EINVAL.value)) + ")"), text
    )


def test_only_an_address_in_use_is_address_in_use() raises:
    """`ListenConfig.listen` waits out EADDRINUSE and nothing else (review
    record R9), and m0serve reports only that as an address in use. Both
    read the bind's own SysError."""
    var first = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var taken = "127.0.0.1:" + String(first.socket.local_address.port)
    var in_use = False
    var text = String()
    try:
        var second = ListenConfig(max_bind_retries=1, quiet=True).listen(taken)
        _ = second^
    except e:
        in_use = e.address_in_use()
        text = String(e)
    assert_true(in_use, "a second bind of a listening port: " + text)
    assert_true(text.startswith("bind: "), text)
    _ = first^

    # 192.0.2.1 is TEST-NET-1, on no machine: EADDRNOTAVAIL.
    var elsewhere = True
    var other = String()
    try:
        var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("192.0.2.1:0")
        _ = ln^
    except e:
        elsewhere = e.address_in_use()
        other = String(e)
    assert_false(elsewhere, "an address on no machine: " + other)
    assert_true(other.startswith("bind: "), other)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
