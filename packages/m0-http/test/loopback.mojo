"""A TCP client for the tests: a connection to a server this process runs.

The server has no client of its own. Its connect path -- `Socket.connect`,
the `getaddrinfo` machinery under it and the `connect(2)` binding -- had no
caller outside these tests once the HTTP client left the tree, and was
deleted (fork review LF26, owner decision 6); what the tests need of it is
this, over the same `Socket` and `TCPConnection` the server's own sockets
are. Literal addresses only: every caller connects to a listener it bound
itself, so there is no name to resolve.

Not a test file (no `test_` prefix): the suite runner builds and runs only
those, and a test imports this as `test.loopback`.
"""

from std.ffi import c_int, external_call, get_errno

from lightbug_http.address import NetworkType, TCPAddr
from lightbug_http.c.address import AddressFamily
from lightbug_http.c.network import SocketAddress, inet_pton, sockaddr, socklen_t
from lightbug_http.c.pipe import close_fd
from lightbug_http.c.socket import SocketType, getsockname, socket
from lightbug_http.c.socket_error import SysError
from lightbug_http.connection import TCPConnection
from lightbug_http.socket import Socket


def _connect[
    origin: ImmOrigin
](fd: c_int, address: Pointer[sockaddr, origin], length: socklen_t) -> c_int:
    """Libc POSIX `connect`."""
    return external_call[
        "connect", c_int, type_of(fd), type_of(address), type_of(length)
    ](fd, address, length)


def connect(fd: FileDescriptor, mut address: SocketAddress) raises SysError:
    """Libc POSIX `connect`, blocking on a blocking descriptor.

    Raises:
        SysError: If the call fails, whatever its errno.
    """
    if _connect(c_int(fd.value), address.unsafe_ptr(), address.length) == -1:
        raise SysError("connect", get_errno())


def create_connection(
    host: String, port: UInt16
) raises -> TCPConnection[NetworkType.tcp4]:
    """A blocking TCP connection to `host:port`, `host` an IPv4 literal.

    The socket is adopted once connected (`Socket(fd=...)`), so it is born
    connected and its destructor shuts it down and closes it.

    Raises:
        Error: If `host` is not an IPv4 literal, or if `connect` fails, with
            its errno. The descriptor is closed either way.
    """
    var remote = SocketAddress(
        AddressFamily.AF_INET, port, inet_pton[AddressFamily.AF_INET](host)
    )
    var fd = FileDescriptor(
        Int(socket(AddressFamily.AF_INET.value, SocketType.SOCK_STREAM.value, c_int(0)))
    )
    var near: Tuple[String, Int]
    try:
        connect(fd, remote)
        var local = SocketAddress()
        getsockname(fd, local)
        near = local.host_port()
    except e:
        close_fd(fd.value)
        raise Error(e)
    var sock = Socket[TCPAddr[NetworkType.tcp4]](
        fd=fd,
        local_address=TCPAddr[NetworkType.tcp4](near[0], UInt16(near[1])),
    )
    return TCPConnection(sock^)
