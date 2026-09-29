"""A socket that has closed its descriptor leaves the number alone (review
B27, B27b).

`Socket.close()` closes the descriptor and marks the socket closed, so its
destructor closes nothing more. It did not mark the socket unconnected, and
a socket made from a descriptor it was given -- `Socket(fd=...)`, the way
a spawned m0serve worker adopts its listener -- is born connected:
destroyed after `close()`, it shut down the number it had closed. A closed
number is free, and the next descriptor the process opens takes the lowest
free one, so by then the number is usually someone else's. A second
`close()` closed it again the same way. Since review B26 no owner in the
tree closes a socket and keeps it, but the type allowed both.

B27 mended the destructor and `close()`; every other method went on passing
the old number to the kernel (B27b): a `send` wrote into the newcomer, a
`receive` took its bytes, a `shutdown` shut it down, a socket option or a
`bind`, `listen` or `connect` landed on it, and `into_fd` handed it to an
owner that would close it. `close()` now leaves the socket holding no
number at all, so each refuses with EBADF, or does nothing where that is
its contract.

Each test plays that someone else: once the socket has closed its number,
another socket is put on it, as the next descriptor the process opened
would be, and the closed socket is then used. The newcomer must come out
whole: its peer reading nothing, its bytes still queued, its options,
address, listening state and connection as they were, and the number
still open. Where a reading could fail to see the damage, a check made on
purpose afterwards shows that it sees it.
"""

from std.ffi import ErrNo, c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.address import NetworkType, TCPAddr, binary_port_to_int
from lightbug_http.c.fcntl import F_GETFD, _fcntl
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.network import SocketAddress
from lightbug_http.c.pipe import close_fd
from lightbug_http.c.socket import (
    SOL_SOCKET,
    ShutdownOption,
    SocketOption,
    accept_with_peer,
    getpeername,
    getsockname,
    recv,
    send,
    shutdown,
    socket,
)
from lightbug_http.c.socket_error import SysError
from lightbug_http.connection import ListenConfig, TCPConnection
from lightbug_http.io.bytes import Bytes
from lightbug_http.socket import Socket


comptime Adopted = Socket[TCPAddr[NetworkType.tcp4]]

comptime _MSG_PEEK = c_int(2)
"""The same value on macOS and Linux."""

comptime _EBADF = Int(ErrNo.EBADF.value)


def _stream_pair() raises -> Tuple[Int, Int]:
    """An `AF_UNIX` `SOCK_STREAM` pair, non-blocking at both ends."""
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


def _tcp_socket() raises -> Int:
    """A new `AF_INET` `SOCK_STREAM` socket: unbound, not listening, not
    connected."""
    return Int(socket(c_int(2), c_int(1), c_int(0)))  # AF_INET, SOCK_STREAM


def _adopt(fd: Int) -> Adopted:
    """A socket made from a descriptor it was given, as a spawned m0serve
    worker adopts its listener: born connected."""
    return Adopted(
        fd=FileDescriptor(fd),
        local_address=TCPAddr[NetworkType.tcp4](ip="127.0.0.1", port=0),
    )


def _move_to(fd: Int, number: Int) raises:
    """Put `fd`'s socket at `number` and close `fd`: what the kernel does for
    the next descriptor the process is given when `number` is its lowest
    free one, done on purpose so the test does not depend on which numbers
    the runner left free. `fd` must have been opened while `number` was
    still taken, or it could be `number` itself."""
    if fd == number:
        raise Error("the newcomer was opened on the freed number itself")
    var rc = external_call["dup2", c_int, c_int, c_int](c_int(fd), c_int(number))
    if Int(rc) != number:
        raise Error("dup2() failed, errno: ", get_errno())
    close_fd(fd)


def _is_open(fd: Int) -> Bool:
    """Whether `fd` names an open file in this process."""
    return Int(_fcntl(c_int(fd), c_int(F_GETFD))) != -1


def _reads_eof(fd: Int) raises -> Bool:
    """Whether a read of `fd` returns end-of-file at once, as it does once
    its peer has shut down; False when the read would wait."""
    var buf = List[UInt8](length=16, fill=0)
    try:
        return recv(FileDescriptor(fd), Span(buf), UInt(len(buf)), 0) == 0
    except e:
        if e.would_block():
            return False
        raise Error(String(e))


def _queued(fd: Int) raises -> Int:
    """How many bytes wait to be read on `fd`, without taking them: -1 when
    a read would wait, 0 at end-of-file."""
    var buf = List[UInt8](length=64, fill=0)
    try:
        return Int(recv(FileDescriptor(fd), Span(buf), UInt(len(buf)), _MSG_PEEK))
    except e:
        if e.would_block():
            return -1
        raise Error(String(e))


def _option(fd: Int, name: c_int) raises -> Int:
    """An integer `SOL_SOCKET` option of `fd`, as `getsockopt` reads it."""
    var value = unsafe_alloc[c_int](count=1)
    var size = unsafe_alloc[UInt32](count=1)
    value[unsafe_offset=0] = 0
    size[unsafe_offset=0] = 4
    var rc = external_call[
        "getsockopt", c_int, c_int, c_int, c_int, type_of(value), type_of(size)
    ](c_int(fd), c_int(SOL_SOCKET), name, value, size)
    var result = Int(value[unsafe_offset=0])
    value.unsafe_free()
    size.unsafe_free()
    if rc != 0:
        raise Error("getsockopt() failed, errno: ", get_errno())
    return result


def _receive_timeout_seconds(fd: Int) raises -> Int:
    """The whole seconds of `fd`'s `SO_RCVTIMEO`; 0 when it has none."""
    var tv = unsafe_alloc[Int64](count=2)
    var size = unsafe_alloc[UInt32](count=1)
    tv[unsafe_offset=0] = 0
    tv[unsafe_offset=1] = 0
    size[unsafe_offset=0] = 16
    var rc = external_call[
        "getsockopt", c_int, c_int, c_int, c_int, type_of(tv), type_of(size)
    ](c_int(fd), c_int(SOL_SOCKET), SocketOption.SO_RCVTIMEO.value, tv, size)
    var seconds = Int(tv[unsafe_offset=0])
    tv.unsafe_free()
    size.unsafe_free()
    if rc != 0:
        raise Error("getsockopt() failed, errno: ", get_errno())
    return seconds


def _is_listening(fd: Int) raises -> Bool:
    """Whether `fd` listens: a non-blocking `accept` on it finds no
    connection waiting (EAGAIN) rather than a socket that does not listen
    (EINVAL). macOS does not answer `SO_ACCEPTCONN`."""
    set_nonblocking(FileDescriptor(fd))
    try:
        var accepted = accept_with_peer(FileDescriptor(fd))
        close_fd(accepted[0].value)
        return True
    except e:
        if e.would_block():
            return True
        if e.errno == ErrNo.EINVAL:
            return False
        raise Error(String(e))


def _local_port(fd: Int) raises -> Int:
    """The port `fd` is bound to; 0 when it is not bound."""
    var address = SocketAddress()
    getsockname(FileDescriptor(fd), address)
    return binary_port_to_int(address.as_sockaddr_in().sin_port)


def _is_connected(fd: Int) -> Bool:
    """Whether `fd` has a peer."""
    try:
        _ = getpeername(FileDescriptor(fd))
        return True
    except:
        return False


def _errno_of(e: SysError) -> Int:
    return Int(e.errno.value)


def test_a_destroyed_socket_leaves_what_took_its_number_connected() raises:
    """An adopted socket, closed and then destroyed, neither shuts down nor
    closes the socket that took its number.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    # Made while the socket still holds its number, so neither end is it.
    var newcomer = _stream_pair()
    sock.close()
    _move_to(newcomer[0], number)
    _ = sock^  # the destructor runs here, with the newcomer on the number

    assert_true(_is_open(number), "the destroyed socket closed its number again")
    assert_false(
        _reads_eof(newcomer[1]),
        "the destroyed socket shut down the socket that took its number",
    )
    # The same reading sees a shutdown when there is one.
    shutdown(FileDescriptor(number), ShutdownOption.SHUT_RDWR)
    assert_true(_reads_eof(newcomer[1]), "a shutdown made on purpose read as none")

    close_fd(number)
    close_fd(newcomer[1])
    close_fd(old[1])


def test_a_second_close_leaves_what_took_its_number_open() raises:
    """`close()` on a socket already closed does not close the descriptor
    that took its number.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var newcomer = _stream_pair()
    sock.close()
    _move_to(newcomer[0], number)
    sock.close()

    assert_true(
        _is_open(number), "a second close() closed the descriptor that took the number"
    )
    _ = sock^

    close_fd(number)
    close_fd(newcomer[1])
    close_fd(old[1])


def test_a_closed_socket_sends_nothing_to_what_took_its_number() raises:
    """`send` on a closed socket is refused with EBADF, and nothing reaches
    the peer of the socket that took its number.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var newcomer = _stream_pair()
    sock.close()
    _move_to(newcomer[0], number)

    var errno = 0
    try:
        _ = sock.send("stale".as_bytes())
    except e:
        errno = _errno_of(e)

    assert_equal(
        _queued(newcomer[1]), -1,
        "a closed socket's send reached the socket that took its number",
    )
    assert_equal(errno, _EBADF, "a closed socket's send was not refused with EBADF")

    close_fd(number)
    close_fd(newcomer[1])
    close_fd(old[1])


def test_a_closed_socket_takes_nothing_from_what_took_its_number() raises:
    """Both `receive` forms on a closed socket are refused with EBADF, and
    the bytes waiting on the socket that took its number stay there.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var newcomer = _stream_pair()
    sock.close()
    _move_to(newcomer[0], number)
    _ = send(FileDescriptor(newcomer[1]), "x".as_bytes(), UInt(1), 0)
    assert_equal(_queued(number), 1, "the newcomer's byte did not arrive")

    var errno = 0
    try:
        _ = sock.receive(16)
    except e:
        if e.isa[SysError]():
            errno = _errno_of(e.value[SysError])
    assert_equal(
        _queued(number), 1,
        "a closed socket's receive(size) took the bytes of the socket that took its number",
    )
    assert_equal(
        errno, _EBADF, "a closed socket's receive(size) was not refused with EBADF"
    )

    errno = 0
    var buffer = Bytes(capacity=16)
    try:
        _ = sock.receive(buffer)
    except e:
        if e.isa[SysError]():
            errno = _errno_of(e.value[SysError])
    assert_equal(
        _queued(number), 1,
        "a closed socket's receive(buffer) took the bytes of the socket that took its number",
    )
    assert_equal(len(buffer), 0, "a closed socket's receive(buffer) filled the buffer")
    assert_equal(
        errno, _EBADF, "a closed socket's receive(buffer) was not refused with EBADF"
    )

    close_fd(number)
    close_fd(newcomer[1])
    close_fd(old[1])


def test_a_closed_connection_neither_writes_nor_reads_what_took_its_number() raises:
    """A `TCPConnection` whose `close()` has run refuses `write` and `read`,
    which are its socket's `send` and `receive`, and the socket that took
    its number is neither written to nor read from.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var conn = TCPConnection(_adopt(number))
    var newcomer = _stream_pair()
    conn.close()
    _move_to(newcomer[0], number)
    _ = send(FileDescriptor(newcomer[1]), "x".as_bytes(), UInt(1), 0)

    var wrote = True
    try:
        _ = conn.write("stale".as_bytes())
    except:
        wrote = False
    assert_equal(
        _queued(newcomer[1]), -1,
        "a closed connection's write reached the socket that took its number",
    )
    assert_false(wrote, "a closed connection's write was not refused")

    var read_refused = False
    var buffer = Bytes(capacity=16)
    try:
        _ = conn.read(buffer)
    except e:
        read_refused = e.isa[SysError]() and _errno_of(e.value[SysError]) == _EBADF
    assert_equal(
        _queued(number), 1,
        "a closed connection's read took the bytes of the socket that took its number",
    )
    assert_true(read_refused, "a closed connection's read was not refused with EBADF")
    assert_true(conn.is_closed(), "a closed connection does not say so")

    close_fd(number)
    close_fd(newcomer[1])
    close_fd(old[1])


def test_a_closed_socket_does_not_shut_down_what_took_its_number() raises:
    """`shutdown` on a closed socket does nothing, as it does on a number
    that is gone, and the socket that took the number stays connected.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var newcomer = _stream_pair()
    sock.close()
    _move_to(newcomer[0], number)

    sock.shutdown()

    assert_false(
        _reads_eof(newcomer[1]),
        "a closed socket's shutdown shut down the socket that took its number",
    )
    # The same reading sees a shutdown when there is one.
    shutdown(FileDescriptor(number), ShutdownOption.SHUT_RDWR)
    assert_true(_reads_eof(newcomer[1]), "a shutdown made on purpose read as none")

    close_fd(number)
    close_fd(newcomer[1])
    close_fd(old[1])


def test_a_closed_socket_sets_no_option_on_what_took_its_number() raises:
    """`set_socket_option` on a closed socket is refused with EBADF, and the
    socket that took its number keeps its own options.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var fresh = _tcp_socket()
    sock.close()
    _move_to(fresh, number)
    assert_equal(_option(number, SocketOption.SO_REUSEADDR.value), 0)

    var errno = 0
    try:
        sock.set_socket_option(SocketOption.SO_REUSEADDR, 1)
    except e:
        errno = _errno_of(e)

    assert_equal(
        _option(number, SocketOption.SO_REUSEADDR.value), 0,
        "a closed socket's set_socket_option set SO_REUSEADDR on the socket that took its number",
    )
    assert_equal(
        errno, _EBADF, "a closed socket's set_socket_option was not refused with EBADF"
    )

    close_fd(number)
    close_fd(old[1])


def test_a_closed_socket_sets_no_timeout_on_what_took_its_number() raises:
    """`set_timeout` on a closed socket is refused with EBADF, and the
    socket that took its number keeps waiting for as long as it did.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var newcomer = _stream_pair()
    sock.close()
    _move_to(newcomer[0], number)
    assert_equal(_receive_timeout_seconds(number), 0)

    var errno = 0
    try:
        sock.set_timeout(5)
    except e:
        errno = _errno_of(e)

    assert_equal(
        _receive_timeout_seconds(number), 0,
        "a closed socket's set_timeout set SO_RCVTIMEO on the socket that took its number",
    )
    assert_equal(errno, _EBADF, "a closed socket's set_timeout was not refused with EBADF")

    close_fd(number)
    close_fd(newcomer[1])
    close_fd(old[1])


def test_a_closed_socket_binds_nothing_it_does_not_hold() raises:
    """`bind` on a closed socket is refused with EBADF, and the socket that
    took its number stays unbound.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var fresh = _tcp_socket()
    sock.close()
    _move_to(fresh, number)
    assert_equal(_local_port(number), 0)

    var errno = 0
    try:
        sock.bind("127.0.0.1", 0)
    except e:
        if e.isa[SysError]():
            errno = _errno_of(e.value[SysError])

    assert_equal(
        _local_port(number), 0,
        "a closed socket's bind bound the socket that took its number",
    )
    assert_equal(errno, _EBADF, "a closed socket's bind was not refused with EBADF")

    close_fd(number)
    close_fd(old[1])


def test_a_closed_socket_does_not_make_what_took_its_number_listen() raises:
    """`listen` on a closed socket is refused with EBADF, and the socket
    that took its number does not start listening.

    covers: D1
    """
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var fresh = _tcp_socket()
    sock.close()
    _move_to(fresh, number)
    assert_false(_is_listening(number))

    var errno = 0
    try:
        sock.listen(8)
    except e:
        errno = _errno_of(e)

    assert_false(
        _is_listening(number),
        "a closed socket's listen made the socket that took its number listen",
    )
    assert_equal(errno, _EBADF, "a closed socket's listen was not refused with EBADF")
    # The same reading sees a socket that listens.
    _ = external_call["listen", c_int, c_int, c_int](c_int(number), c_int(8))
    assert_true(_is_listening(number), "a listen made on purpose read as none")

    close_fd(number)
    close_fd(old[1])


def test_a_closed_socket_does_not_connect_what_took_its_number() raises:
    """`connect` on a closed socket is refused with EBADF, and the socket
    that took its number stays unconnected.

    covers: D1
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var port = ln.addr().port
    var old = _stream_pair()
    var number = old[0]
    var sock = _adopt(number)
    var fresh = _tcp_socket()
    sock.close()
    _move_to(fresh, number)

    var errno = 0
    var ip = String("127.0.0.1")
    try:
        sock.connect(ip, port)
    except e:
        var text = String(e)
        if text.find("Bad file descriptor") >= 0 or text.find("errno 9)") >= 0:
            errno = _EBADF

    assert_false(
        _is_connected(number),
        "a closed socket's connect connected the socket that took its number",
    )
    assert_equal(errno, _EBADF, "a closed socket's connect was not refused with EBADF")

    close_fd(number)
    close_fd(old[1])
    ln.close()


def test_a_closed_listener_hands_over_no_number() raises:
    """`into_fd` on a closed listener gives its new owner no descriptor, so
    the close that owner makes, as the event loop's drain does, leaves the
    socket that took the number open.

    covers: D1
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var number = ln.socket.fd.value
    var newcomer = _stream_pair()
    ln.close()
    _move_to(newcomer[0], number)

    var given = ln^.into_fd().value
    assert_true(
        given != number, "a closed listener handed over the number another socket took"
    )
    assert_equal(given, -1, "a closed listener handed over a descriptor")
    close_fd(given)  # what the owner does with it
    assert_true(_is_open(number), "the owner's close closed the socket that took the number")

    close_fd(number)
    close_fd(newcomer[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
