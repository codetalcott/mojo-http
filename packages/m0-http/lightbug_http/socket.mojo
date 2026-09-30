from std.ffi import ErrNo, c_uint, get_errno
from std.sys.info import CompilationTarget

from lightbug_http.c.aliases import c_void

from lightbug_http.address import (
    Addr,
    binary_ip_to_string,
    binary_port_to_int,
    get_ip_address,
)
from lightbug_http.c.address import AddressFamily, AddressLength
from lightbug_http.c.network import InetNtopError, InetPtonError, SocketAddress, inet_pton
from lightbug_http.c.socket import (
    SOL_SOCKET,
    ShutdownOption,
    SocketOption,
    SocketType,
    _setsockopt,
    bind,
    close,
    connect,
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
from lightbug_http.connection import default_buffer_size
from lightbug_http.io.bytes import Bytes
from std.utils import Variant


@fieldwise_init
struct SocketClosedError(Movable, TrivialRegisterPassable):
    pass


@fieldwise_init
struct EOF(Movable, TrivialRegisterPassable):
    pass


@fieldwise_init
struct SocketRecvError(Movable, Writable):
    """Error variant for socket receive operations.
    Can be a SysError from the syscall or EOF if connection closed cleanly.
    """

    comptime type = Variant[SysError, EOF]
    var value: Self.type

    @implicit
    def __init__(out self, value: SysError):
        self.value = value

    @implicit
    def __init__(out self, value: EOF):
        self.value = value

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[SysError]():
            writer.write(self.value[SysError])
        elif self.value.isa[EOF]():
            writer.write("EOF")

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct SocketNameError(Movable, Writable):
    """Error variant for `get_sock_name` and `get_peer_name`.
    Can be a SysError from getsockname or getpeername (its `op` says which),
    SocketClosedError, or InetNtopError from binary_ip_to_string.
    """

    comptime type = Variant[SysError, SocketClosedError, InetNtopError]
    var value: Self.type

    @implicit
    def __init__(out self, value: SysError):
        self.value = value

    @implicit
    def __init__(out self, value: SocketClosedError):
        self.value = value

    @implicit
    def __init__(out self, var value: InetNtopError):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[SysError]():
            writer.write(self.value[SysError])
        elif self.value.isa[SocketClosedError]():
            writer.write("SocketClosedError")
        elif self.value.isa[InetNtopError]():
            writer.write(self.value[InetNtopError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct SocketBindError(Movable, Writable):
    """Error variant for socket bind operations.
    Can be a SysError from bind(), SocketNameError from get_sock_name(), or InetPtonError from inet_pton.
    """

    comptime type = Variant[SysError, SocketNameError, InetPtonError]
    var value: Self.type

    @implicit
    def __init__(out self, value: SysError):
        self.value = value

    @implicit
    def __init__(out self, var value: SocketNameError):
        self.value = value^

    @implicit
    def __init__(out self, var value: InetPtonError):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[SysError]():
            writer.write(self.value[SysError])
        elif self.value.isa[SocketNameError]():
            writer.write(self.value[SocketNameError])
        elif self.value.isa[InetPtonError]():
            writer.write(self.value[InetPtonError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct Socket[
    address: Addr,
    sock_type: SocketType = SocketType.SOCK_STREAM,
    address_family: AddressFamily = AddressFamily.AF_INET,
](Movable, Writable):
    """Represents a network file descriptor. Wraps around a file descriptor and provides network functions.

    Parameters:
        address: The type of address the socket uses.
        sock_type: The type of socket (SOCK_STREAM for TCP).
        address_family: The address family (e.g., AF_INET for IPv4, AF_INET6 for IPv6).

    Args:
        local_address: The local address of the socket (local address if bound).
        remote_address: The remote address of the socket (peer's address if connected).
    """

    var fd: FileDescriptor
    """The file descriptor of the socket."""
    var local_address: Self.address
    """The local address of the socket (local address if bound)."""
    var remote_address: Self.address
    """The remote address of the socket (peer's address if connected)."""
    var _closed: Bool
    """Whether the socket is closed."""
    var _connected: Bool
    """Whether the socket is connected."""

    def __init__(
        out self,
        local_address: Self.address = Self.address(),
        remote_address: Self.address = Self.address(),
    ) raises SysError:
        """Create a new socket object.

        Args:
            local_address: The local address of the socket (local address if bound).
            remote_address: The remote address of the socket (peer's address if connected).

        Raises:
            SysError: If the socket creation fails.
        """
        # TODO: Tried unspec for both address family and protocol, and inet for both but that doesn't seem to work.
        # I guess for now, I'll leave protocol as unspec.
        self.fd = FileDescriptor(Int(socket(Self.address_family.value, Self.sock_type.value, 0)))
        self.local_address = local_address
        self.remote_address = remote_address
        self._closed = False
        self._connected = False

    def __init__(
        out self,
        fd: FileDescriptor,
        local_address: Self.address,
        remote_address: Self.address = Self.address(),
    ):
        """
        Create a new socket object when you already have a socket file descriptor, such as a listener another process bound.

        Args:
            fd: The file descriptor of the socket.
            local_address: The local address of the socket (local address if bound).
            remote_address: The remote address of the socket (peer's address if connected).
        """
        self.fd = fd
        self.local_address = local_address
        self.remote_address = remote_address
        self._closed = False
        self._connected = True

    def teardown(deinit self) raises SysError:
        """Close the socket and free the file descriptor."""
        if self._connected:
            try:
                self.shutdown()
            except shutdown_err:
                pass

        if not self._closed:
            self.close()

    def into_fd(deinit self) -> FileDescriptor:
        """Give up the socket without closing it, and return its descriptor.

        A named destructor: neither `teardown` nor `__deinit__` runs, so
        the number is neither shut down nor closed here. Whoever takes the
        descriptor now owns it and closes it, once. This is how a listener
        is given to the event loop, which closes it as its drain begins
        (review B26): a `Socket` still holding the number would close it
        again when destroyed, after the drain had freed it for anything
        else in the process to take.

        A closed socket has no descriptor to give, and returns -1 (review
        B27b): the number it closed may be another descriptor's by now, and
        its new owner would close that one.
        """
        return self.fd

    def __enter__(var self) -> Self:
        return self^

    def __deinit__(deinit self):
        """Close the socket when the object is deleted."""
        try:
            self^.teardown()
        except teardown_err:
            pass

    def __str__(self) -> String:
        return String(self)

    def __repr__(self) -> String:
        return String(self)

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(
            "Socket[",
            Self.address._type,
            ", ",
            Self.address_family,
            "]",
            "(",
            "fd=",
            self.fd.value,
            ", local_address=",
            repr(self.local_address),
            ", remote_address=",
            repr(self.remote_address),
            ", _closed=",
            self._closed,
            ", _connected=",
            self._connected,
            ")",
        )

    def listen(self, backlog: UInt = 0) raises SysError:
        """Enable a server to accept connections.

        Args:
            backlog: The maximum number of queued connections. Should be at least 0, and the maximum is system-dependent (usually 5).

        Raises:
            SysError: If listening for a connection fails; EBADF on a
                closed socket, which listens on nothing (see `close`).
        """
        listen(self.fd, Int32(backlog))

    def bind(mut self, ip_address: String, port: UInt16) raises SocketBindError:
        """Bind the socket to address. The socket must not already be bound. (The format of address depends on the address family).

        When a socket is created with Socket(), it exists in a name
        space (address family) but has no address assigned to it.  bind()
        assigns the address specified by addr to the socket referred to
        by the file descriptor fd.  addrlen specifies the size, in
        bytes, of the address structure pointed to by addr.
        Traditionally, this operation is called 'assigning a name to a
        socket'.

        Args:
            ip_address: The IP address to bind the socket to.
            port: The port number to bind the socket to.

        Raises:
            SocketBindError: If IP conversion fails, bind fails, or getting socket name fails.
                A closed socket's bind fails with EBADF (see `close`).
        """
        var binary_ip = inet_pton[Self.address_family](ip_address)

        var local_address = SocketAddress(
            address_family=Self.address_family,
            port=port,
            binary_ip=binary_ip,
        )
        bind(self.fd, local_address)

        var local = self.get_sock_name()
        self.local_address = Self.address(local[0], local[1])

    def get_sock_name(self) raises SocketNameError -> Tuple[String, UInt16]:
        """Return the address of the socket.

        Returns:
            The address of the socket.

        Raises:
            SocketNameError: If socket is closed or getsockname fails.
        """
        if self._closed:
            raise SocketClosedError()

        # TODO: Add check to see if the socket is bound and error if not.
        var local_address = SocketAddress()
        getsockname(self.fd, local_address)

        ref local_sockaddr_in = local_address.as_sockaddr_in()
        return (
            binary_ip_to_string[Self.address_family](local_sockaddr_in.sin_addr.s_addr),
            UInt16(binary_port_to_int(local_sockaddr_in.sin_port)),
        )

    def get_peer_name(self) raises SocketNameError -> Tuple[String, UInt16]:
        """Return the address of the peer connected to the socket.

        Returns:
            The address of the peer connected to the socket.

        Raises:
            SocketNameError: If socket is closed or getpeername fails.
        """
        if self._closed:
            raise SocketClosedError()

        # TODO: Add check to see if the socket is bound and error if not.
        var peer_address = getpeername(self.fd)

        ref peer_sockaddr_in = peer_address.as_sockaddr_in()
        return (
            binary_ip_to_string[Self.address_family](peer_sockaddr_in.sin_addr.s_addr),
            UInt16(binary_port_to_int(peer_sockaddr_in.sin_port)),
        )

    def set_socket_option(self, option_name: SocketOption, var option_value: Int = 1) raises SysError:
        """Set the given socket option.

        Args:
            option_name: The socket option to set.
            option_value: The value to set the socket option to. Defaults to 1 (True).

        Raises:
            SysError: If setting the socket option fails; EBADF on a
                closed socket (see `close`).
        """
        setsockopt(self.fd, Int32(SOL_SOCKET), option_name.value, Int32(option_value))

    def connect(mut self, mut ip_address: String, port: UInt16) raises -> None:
        """Connect to a remote socket at address.

        Args:
            ip_address: The IP address to connect to.
            port: The port number to connect to.

        Raises:
            Error: If connecting to the remote socket fails; the SysError
                of an EBADF on a closed socket (see `close`).
        """
        var ip = get_ip_address(ip_address, Self.address_family, Self.sock_type)
        var remote_address = SocketAddress(address_family=Self.address_family, port=port, binary_ip=ip)
        connect(self.fd, remote_address)

        var remote = self.get_peer_name()
        self.remote_address = Self.address(remote[0], remote[1])

    def send(self, buffer: Span[Byte, _]) raises SysError -> UInt:
        """Send what `buffer` holds, or as much of it as the socket takes.

        Args:
            buffer: The bytes to send.

        Returns:
            The number of bytes sent.

        Raises:
            SysError: If the send fails; EBADF on a closed socket, which
                sends nothing (see `close`).
        """
        return send(self.fd, buffer, UInt(len(buffer)), 0)

    def _receive(self, mut buffer: Bytes) raises SocketRecvError -> UInt:
        """Receive data from the socket into the buffer.

        Args:
            buffer: The buffer to read data into.

        Returns:
            The number of bytes received.

        Raises:
            SocketRecvError: A SysError if reading from the socket fails --
                EBADF on a closed socket, which reads nothing (see `close`)
                -- or EOF if 0 bytes are received.
        """
        var bytes_received: UInt
        var size = len(buffer)
        bytes_received = recv(
            self.fd,
            Span(buffer)[size:],
            UInt(buffer.capacity() - len(buffer)),
            0,
        )
        buffer._len += Int(bytes_received)

        if bytes_received == 0:
            raise SocketRecvError(EOF())

        return bytes_received

    def receive(self, size: Int = default_buffer_size) raises SocketRecvError -> List[Byte]:
        """Receive data from the socket into the buffer with capacity of `size` bytes.

        Args:
            size: The size of the buffer to receive data into.

        Returns:
            The buffer with the received data, and an error if one occurred.
        """
        var buffer = Bytes(capacity=size)
        _ = self._receive(buffer)
        return buffer^

    def receive(self, mut buffer: Bytes) raises SocketRecvError -> UInt:
        """Receive data from the socket into the buffer.

        Args:
            buffer: The buffer to read data into.

        Returns:
            The buffer with the received data, and an error if one occurred.

        Raises:
            SocketRecvError: A SysError if reading from the socket fails, or
                EOF if 0 bytes are received.
        """
        return self._receive(buffer)

    def shutdown(mut self) raises SysError -> None:
        """Shut down the socket. The remote end will receive no more data (after queued data is flushed).

        On a closed socket it does nothing: there is nothing of its own left
        to shut down, and the number it closed may be another descriptor's
        by now (review B27b; see `close`). The kernel's EBADF for the -1 it
        holds is one of the failures that mean exactly that.

        Raises:
            SysError: EINVAL only. Any other failure means the socket is
                already closed or its descriptor is gone, which is shut
                down.
        """
        try:
            shutdown(self.fd, ShutdownOption.SHUT_RDWR)
        except shutdown_err:
            if shutdown_err.errno == ErrNo.EINVAL:
                raise shutdown_err

        self._connected = False

    def close(mut self) raises SysError -> None:
        """Close the socket's descriptor, once.
        The remote end will receive no more data (after queued data is flushed).

        A closed number is free, and the next descriptor the process opens
        takes the lowest free one, so the socket leaves it alone from here
        on (review B27): a second `close` does nothing, and the socket is no
        longer connected, so its destructor does not shut the number down.
        A socket made from a descriptor it was given (`Socket(fd=...)`) is
        born connected, and destroyed after `close` it shut down whatever
        held the number by then.

        Nor does any other method reach it (review B27b): the socket keeps
        no number once it is closed, holding -1 in its place, which the
        kernel refuses with EBADF whatever the call. `send`, `receive`,
        `bind`, `listen`, `connect` and the options each raise that EBADF
        as their own failure, `shutdown` does nothing, and `into_fd` hands
        over -1. Each of those passed the old number on, by then usually
        another descriptor's: a `send` wrote into it, a `receive` took its
        bytes, a `shutdown` ended its connection, a `bind`, `listen` or
        option landed on it, and the owner `into_fd` handed it to closed it.
        One guard here rather than one in each method, so a method added
        later, and a caller that reads `fd` itself, are covered too.

        Raises:
            SysError: If closing the socket fails, except EBADF, which means
                it is already closed.
        """
        if self._closed:
            return
        try:
            close(self.fd)
        except close_err:
            if close_err.errno != ErrNo.EBADF:
                raise close_err

        self._closed = True
        self._connected = False
        self.fd = FileDescriptor(-1)

    def set_timeout(self, seconds: Int) raises SysError:
        """Set the receive timeout for the socket.

        Args:
            seconds: The timeout duration in seconds.

        Raises:
            SysError: If setting the socket option fails; EBADF on a
                closed socket (see `close`).
        """
        # SO_RCVTIMEO requires a timeval struct: {tv_sec: Int64, tv_usec: Int64}
        # (16 bytes on both macOS and Linux 64-bit).
        var timeval: Array[Int64, 2] = [Int64(seconds), Int64(0)]
        var result = _setsockopt(
            Int32(self.fd.value),
            Int32(SOL_SOCKET),
            SocketOption.SO_RCVTIMEO.value,
            Pointer(to=timeval).unsafe_bitcast[c_void](),
            16,
        )
        if result == -1:
            raise SysError("setsockopt", get_errno())


comptime TCPSocket[address: Addr] = Socket[
    address=address,
    sock_type = SocketType.SOCK_STREAM,
    address_family = AddressFamily.AF_INET,
]
