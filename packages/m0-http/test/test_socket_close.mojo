"""A socket that has closed its descriptor leaves the number alone (review
B27).

`Socket.close()` closes the descriptor and marks the socket closed, so its
destructor closes nothing more. It did not mark the socket unconnected, and
a socket made from a descriptor it was given -- `Socket(fd=...)`, the way
a spawned m0serve worker adopts its listener -- is born connected:
destroyed after `close()`, it shut down the number it had closed. A closed
number is free, and the next descriptor the process opens takes the lowest
free one, so by then the number is usually someone else's. A second
`close()` closed it again the same way. Since review B26 no owner in the
tree closes a socket and keeps it, but the type allowed both.

Each test plays that someone else: once the socket has closed its number,
one end of another stream pair is put on it, as the next descriptor the
process opened would be, and the socket is then destroyed or closed again.
The newcomer must come out whole -- the number still open, and its peer
reading nothing rather than end-of-file -- and a shutdown made on purpose
afterwards shows that the same reading sees one.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_false, assert_true

from lightbug_http.address import NetworkType, TCPAddr
from lightbug_http.c.fcntl import F_GETFD, _fcntl
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.pipe import close_fd
from lightbug_http.c.socket import ShutdownOption, recv, shutdown
from lightbug_http.socket import Socket


comptime Adopted = Socket[TCPAddr[NetworkType.tcp4]]


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
    the runner left free."""
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
