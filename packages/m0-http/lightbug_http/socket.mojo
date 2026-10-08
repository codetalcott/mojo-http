from std.ffi import ErrNo, c_uint
from std.sys.info import CompilationTarget

from lightbug_http.address import Addr
from lightbug_http.c.address import AddressFamily, AddressLength
from lightbug_http.c.network import InetNtopError, InetPtonError, SocketAddress, inet_pton
from lightbug_http.c.socket import (
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    SOL_SOCKET,
    ShutdownOption,
    SocketOption,
    SocketType,
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
    spare_capacity,
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
    or SocketClosedError. The InetNtopError arm is kept for callers that
    match it; nothing raises it since the address is read by
    `SocketAddress.host_port`, which reports an address it cannot format as
    `("", 0)`.
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


trait DescriptorClose:
    """How `Socket.close_with` closes its descriptor. The socket's own is
    `LibcClose`; a test's conformance reports the failures a real `close(2)`
    returns only under a signal or a failing device, which no test can
    produce on demand."""

    def close(mut self, fd: FileDescriptor) raises SysError:
        """Close `fd`, raising the `SysError` the call reports."""
        ...


struct LibcClose(DescriptorClose):
    """The close itself: one `close(2)`."""

    def __init__(out self):
        pass

    def close(mut self, fd: FileDescriptor) raises SysError:
        close(fd)


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
        address_family: The address family a socket is made with when none
            is given (`family`).

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
    var family: AddressFamily
    """The family the socket was made in, which `bind` builds its address
    for. A value, not only the `address_family` parameter: a listener's
    family is the address it is given, `AF_INET6` for `::` and `AF_INET`
    for `0.0.0.0`, known only once the address is (review R15). A parameter
    would make every signature that holds a listener generic over it."""

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
        self = Self(
            family=Self.address_family,
            local_address=local_address,
            remote_address=remote_address,
        )

    def __init__(
        out self,
        *,
        family: AddressFamily,
        local_address: Self.address = Self.address(),
        remote_address: Self.address = Self.address(),
    ) raises SysError:
        """Create a new socket in `family`, whatever `address_family` says.

        Args:
            family: `AF_INET` or `AF_INET6`.
            local_address: The local address of the socket (local address if bound).
            remote_address: The remote address of the socket (peer's address if connected).

        Raises:
            SysError: If the socket creation fails.
        """
        # Protocol 0: the family's default for the type, TCP for a stream.
        self.fd = FileDescriptor(Int(socket(family.value, Self.sock_type.value, 0)))
        self.local_address = local_address
        self.remote_address = remote_address
        self._closed = False
        self._connected = False
        self.family = family

    def __init__(
        out self,
        fd: FileDescriptor,
        local_address: Self.address,
        remote_address: Self.address = Self.address(),
        family: AddressFamily = Self.address_family,
    ):
        """
        Create a new socket object when you already have a socket file descriptor, such as a listener another process bound.

        Args:
            fd: The file descriptor of the socket.
            local_address: The local address of the socket (local address if bound).
            remote_address: The remote address of the socket (peer's address if connected).
            family: The family the descriptor's socket was made in.
        """
        self.fd = fd
        self.local_address = local_address
        self.remote_address = remote_address
        self._closed = False
        self._connected = True
        self.family = family

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
            self.family,
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
        var local_address: SocketAddress
        if self.family == AddressFamily.AF_INET6:
            local_address = SocketAddress(
                AddressFamily.AF_INET6, port, inet_pton[AddressFamily.AF_INET6](ip_address)
            )
        else:
            local_address = SocketAddress(
                AddressFamily.AF_INET, port, inet_pton[AddressFamily.AF_INET](ip_address)
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
        var named = local_address.host_port()
        return (named[0], UInt16(named[1]))

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
        var named = peer_address.host_port()
        return (named[0], UInt16(named[1]))

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

    def set_ipv6_only(self, ipv6_only: Bool) raises SysError:
        """Whether an `AF_INET6` socket takes IPv6 alone (`IPV6_V6ONLY`), or
        IPv4 too, which arrives as `::ffff:a.b.c.d`.

        Set, never left to the default, which is a system setting
        (`net.inet6.ip6.v6only` on macOS, `net.ipv6.bindv6only` on Linux):
        a listener on `::` meant for both families served IPv6 alone on a
        host configured that way (review R15). Before `bind`.

        Args:
            ipv6_only: True for IPv6 alone.

        Raises:
            SysError: If setting the option fails; ENOPROTOOPT or EINVAL on
                a socket that is not `AF_INET6`, EBADF on a closed one.
        """
        setsockopt(self.fd, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), Int32(1 if ipv6_only else 0))

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
        return send(self.fd, buffer, 0)

    def _receive(self, mut buffer: Bytes) raises SocketRecvError -> UInt:
        """Receive data from the socket into the buffer, after its length.

        A buffer with no room past its length -- full, or a `Bytes()` never
        given a capacity -- grows by `default_buffer_size` first. It was
        lent as it stood, and a `recv` into zero bytes returns 0, the count
        EOF returns: a full buffer read as a closed connection with the
        peer's bytes still waiting (review record LF34).

        Args:
            buffer: The buffer to read data into.

        Returns:
            The number of bytes received.

        Raises:
            SocketRecvError: A SysError if reading from the socket fails --
                EBADF on a closed socket, which reads nothing (see `close`)
                -- or EOF if 0 bytes are received.
        """
        if buffer.capacity() == len(buffer):
            buffer.reserve(len(buffer) + default_buffer_size)
        var bytes_received = recv(self.fd, spare_capacity(buffer), 0)
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
        `bind`, `listen` and the options each raise that EBADF as their own
        failure, `shutdown` does nothing, and `into_fd` hands over -1. Each
        of those passed the old number on, by then usually another
        descriptor's: a `send` wrote into it, a `receive` took its bytes, a
        `shutdown` ended its connection, a `bind`, `listen` or option landed
        on it, and the owner `into_fd` handed it to closed it.
        One guard here rather than one in each method, so a method added
        later, and a caller that reads `fd` itself, are covered too.

        A close that fails has released the number all the same, and the
        socket is closed afterwards whatever it reports (review AR): the
        failure is raised, and the number is never closed again. POSIX
        leaves a descriptor's state after EINTR unspecified; Linux and
        macOS both deallocate it before anything that can fail, so EINTR (a
        signal interrupting a lingering close) and EIO arrive with the
        number already free, and a retry, a second `close` or the
        destructor would close whatever another thread had opened on it
        meanwhile. The socket used to raise with the number still held.

        Raises:
            SysError: If closing the socket fails, except EBADF, which means
                it is already closed. The socket is closed either way.
        """
        var closer = LibcClose()
        self.close_with(closer)

    def close_with[C: DescriptorClose](mut self, mut closer: C) raises SysError -> None:
        """`close`, with the `close(2)` itself a parameter (`DescriptorClose`),
        so a test can report the failures a real one returns only under a
        signal or a failing device.

        The socket gives up its number BEFORE the call, so no failure the
        call reports can leave it holding a number the kernel has released.

        Raises:
            SysError: What `closer` raises, except EBADF. The socket is
                closed either way.
        """
        if self._closed:
            return
        var fd = self.fd
        self._closed = True
        self._connected = False
        self.fd = FileDescriptor(-1)
        try:
            closer.close(fd)
        except close_err:
            if close_err.errno != ErrNo.EBADF:
                raise close_err


comptime TCPSocket[address: Addr] = Socket[
    address=address,
    sock_type = SocketType.SOCK_STREAM,
    address_family = AddressFamily.AF_INET,
]
