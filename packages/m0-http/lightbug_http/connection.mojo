from std.sys.info import CompilationTarget
from std.time import sleep

from lightbug_http.address import HostPort, NetworkType, ParseError, TCPAddr, UDPAddr, parse_address
from lightbug_http.c.address import AddressFamily
from lightbug_http.c.socket_error import (
    AcceptError,
    GetpeernameError,
    RecvError,
    RecvfromError,
    SendError,
    SetsockoptError,
    ShutdownEINVALError,
)
from lightbug_http.c.socket_error import SocketError as CSocketError
from lightbug_http.io.bytes import Bytes
from lightbug_http.io.sync import Duration
from lightbug_http.socket import (
    EOF,
    FatalCloseError,
    Socket,
    SocketAcceptError,
    SocketBindError,
    SocketConnectError,
    SocketOption,
    SocketRecvError,
    SocketRecvfromError,
    SocketType,
    TCPSocket,
    UDPSocket,
)
from lightbug_http.utils.error import CustomError
from std.utils import Variant


comptime default_buffer_size = 4096
"""The default buffer size for reading and writing data."""
comptime default_tcp_keep_alive = Duration(15 * 1000 * 1000 * 1000)  # 15 seconds
"""The default TCP keep-alive duration."""


@fieldwise_init
struct AddressParseError(CustomError, ImplicitlyCopyable):
    # Phase 0: @register_passable("trivial") removed — zero-field struct is
    # trivially movable without the decorator (deprecated in Mojo nightly).
    comptime message = "ListenerError: Failed to parse listen address"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct SocketCreationError(CustomError, ImplicitlyCopyable):
    comptime message = "ListenerError: Failed to create socket"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct BindFailedError(CustomError, ImplicitlyCopyable):
    comptime message = "ListenerError: Failed to bind socket to address"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ListenFailedError(CustomError, ImplicitlyCopyable):
    comptime message = "ListenerError: Failed to listen on socket"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ListenerError(Movable, Writable):
    """Error variant for listener creation operations.

    Represents failures during address parsing, socket creation, binding, or listening.
    """

    comptime type = Variant[
        AddressParseError, SocketCreationError, BindFailedError, ListenFailedError, CSocketError, SocketBindError, Error
    ]
    var value: Self.type

    @implicit
    def __init__(out self, value: AddressParseError):
        self.value = value

    @implicit
    def __init__(out self, value: SocketCreationError):
        self.value = value

    @implicit
    def __init__(out self, value: BindFailedError):
        self.value = value

    @implicit
    def __init__(out self, value: ListenFailedError):
        self.value = value

    @implicit
    def __init__(out self, var value: CSocketError):
        self.value = value^

    @implicit
    def __init__(out self, var value: SocketBindError):
        self.value = value^

    @implicit
    def __init__(out self, var value: Error):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[AddressParseError]():
            writer.write(self.value[AddressParseError])
        elif self.value.isa[SocketCreationError]():
            writer.write(self.value[SocketCreationError])
        elif self.value.isa[BindFailedError]():
            writer.write(self.value[BindFailedError])
        elif self.value.isa[ListenFailedError]():
            writer.write(self.value[ListenFailedError])
        elif self.value.isa[CSocketError]():
            writer.write(self.value[CSocketError])
        elif self.value.isa[SocketBindError]():
            writer.write(self.value[SocketBindError])
        elif self.value.isa[Error]():
            writer.write(self.value[Error])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


struct NoTLSListener[network: NetworkType = NetworkType.tcp4](Movable):
    """A TCP listener that listens for incoming connections and can accept them."""

    var socket: TCPSocket[TCPAddr[Self.network]]

    def __init__(out self, var socket: TCPSocket[TCPAddr[Self.network]]):
        self.socket = socket^

    def __init__(out self) raises CSocketError:
        self.socket = Socket[TCPAddr[Self.network]]()

    def accept(self) raises SocketAcceptError -> TCPConnection[Self.network]:
        """Accept an incoming TCP connection.

        Returns:
            A new TCPConnection for the accepted client.

        Raises:
            SocketAcceptError: If accept fails.
        """
        return TCPConnection(self.socket.accept())

    def close(mut self) raises FatalCloseError -> None:
        """Close the listener socket.

        Raises:
            FatalCloseError: If close fails (excludes EBADF).
        """
        return self.socket.close()

    def shutdown(mut self) raises ShutdownEINVALError:
        """Shutdown the listener socket.

        Raises:
            ShutdownEINVALError: If shutdown fails.
        """
        return self.socket.shutdown()

    def teardown(deinit self) raises FatalCloseError:
        """Teardown the listener socket on destruction.

        Raises:
            FatalCloseError: If close fails during teardown.
        """
        self.socket^.teardown()

    def addr(self) -> TCPAddr[Self.network]:
        return self.socket.local_address


struct ListenConfig:
    var _keep_alive: Duration
    var max_bind_retries: Int
    """Maximum number of bind() attempts before raising ListenFailedError (Phase 4c).

    Each retry sleeps 1 second.  Default 30 gives ~30 s total wait, covering
    the typical TIME_WAIT drain after a server restart.  Set to 0 for
    infinite retries (original behaviour).
    """
    var reuse_port: Bool
    """Set `SO_REUSEPORT` on the listener. Off by default, and opt-in on
    purpose: this server's workers and threads all accept from ONE listener
    bound before the fork, so nothing here needs the option — and with it
    set unconditionally (as it was until 0.14.0) a second server on the
    same port bound successfully, printed its banner, and on Linux took a
    share of the connections; on macOS it served nothing. Set it only for
    a deliberate handoff between two processes that both mean to listen.
    """
    var quiet: Bool
    """Suppress the listening banner and the "Ready" line. For a caller
    whose own startup line is the ready signal — `m0serve` prints its after
    the application has loaded, so that "ready" means ready; a banner
    printed before the load made a failed import read as "Ready" and then
    exit 1.
    """

    def __init__(
        out self,
        keep_alive: Duration = default_tcp_keep_alive,
        max_bind_retries: Int = 30,
        reuse_port: Bool = False,
        quiet: Bool = False,
    ):
        self._keep_alive = keep_alive
        self.max_bind_retries = max_bind_retries
        self.reuse_port = reuse_port
        self.quiet = quiet

    def listen[
        network: NetworkType = NetworkType.tcp4
    ](self, address: StringSpan) raises ListenerError -> NoTLSListener[network]:
        """Create a TCP listener on the specified address.

        Parameters:
            network: The network type (tcp4 or tcp6).

        Args:
            address: The address to listen on (host:port).

        Returns:
            A NoTLSListener ready to accept connections.

        Raises:
            ListenerError: If address parsing, socket creation, bind, or listen fails.
        """
        var local: HostPort
        try:
            local = parse_address[network](address)
        except ParseError:
            raise AddressParseError()

        var socket: Socket[TCPAddr[network]]
        try:
            socket = Socket[TCPAddr[network]]()
        except socket_err:
            raise SocketCreationError()

        # SO_REUSEADDR: allow rapid restart after TIME_WAIT
        try:
            socket.set_socket_option(SocketOption.SO_REUSEADDR, 1)
        except sockopt_err:
            pass  # non-fatal

        # SO_REUSEPORT is opt-in (see the field): a second server on the
        # same port must FAIL to bind, not silently share it. Workers and
        # threads share the one listener bound here, so they never need it.
        if self.reuse_port:
            try:
                socket.set_socket_option(SocketOption.SO_REUSEPORT, 1)
            except sockopt_err:
                pass  # non-fatal — kernel may not support SO_REUSEPORT

        var addr = TCPAddr[network](ip=local.host^, port=local.port)
        var bind_success = False
        var bind_fail_logged = False
        var bind_attempts = 0
        # Phase 4c: bounded retry — max_bind_retries=0 means unlimited.
        while not bind_success:
            try:
                socket.bind(addr.ip, addr.port)
                bind_success = True
            except bind_err:
                bind_attempts += 1
                if self.max_bind_retries > 0 and bind_attempts >= self.max_bind_retries:
                    raise ListenFailedError()
                if not bind_fail_logged:
                    print(
                        "Bind failed on " + String(addr.ip) + ":"
                        + String(addr.port)
                        + " (address in use? another server on the port,"
                        + " or a previous one still draining)"
                    )
                    var limit = String("unlimited") if self.max_bind_retries == 0 else String(self.max_bind_retries)
                    print("Retrying (max", limit, "attempts, 1s apart)...")
                    bind_fail_logged = True
                print(".", end="", flush=True)

                try:
                    socket.shutdown()
                except shutdown_err:
                    pass
                sleep(1)

        try:
            socket.listen(128)
        except listen_err:
            raise ListenFailedError()

        var listener = NoTLSListener(socket^)
        var msg = String(
            "\n🔥🐝 Lightbug is listening on ",
            "http://",
            addr.ip,
            ":",
            String(addr.port),
        )
        if not self.quiet:
            print(msg)
            print("Ready to accept connections...")

        return listener^


@fieldwise_init
struct RequestBodyState(Copyable):
    """State for reading request body."""

    var content_length: Int
    var bytes_read: Int


@fieldwise_init
struct ConnectionState(Copyable):
    """
    State machine for connection processing.

    States:
    - reading_headers: Accumulating request header bytes
    - reading_body: Reading request body based on Content-Length
    - processing: Invoking application handler
    - responding: Sending response to client
    - closed: Connection finished
    - streaming_sse: SSE stream idle, waiting for events to push
    - streaming_ws: WebSocket connection, exchanging frames
    """

    comptime READING_HEADERS = 0
    comptime READING_BODY = 1
    comptime PROCESSING = 2
    comptime RESPONDING = 3
    comptime CLOSED = 4
    comptime STREAMING_SSE = 5
    comptime STREAMING_WS = 6

    var kind: Int
    var body_state: RequestBodyState

    @staticmethod
    def reading_headers() -> Self:
        return ConnectionState(Self.READING_HEADERS, RequestBodyState(0, 0))

    @staticmethod
    def reading_body(content_length: Int) -> Self:
        return ConnectionState(Self.READING_BODY, RequestBodyState(content_length, 0))

    @staticmethod
    def processing() -> Self:
        return ConnectionState(Self.PROCESSING, RequestBodyState(0, 0))

    @staticmethod
    def responding() -> Self:
        return ConnectionState(Self.RESPONDING, RequestBodyState(0, 0))

    @staticmethod
    def closed() -> Self:
        return ConnectionState(Self.CLOSED, RequestBodyState(0, 0))

    @staticmethod
    def streaming_sse() -> Self:
        return ConnectionState(Self.STREAMING_SSE, RequestBodyState(0, 0))

    @staticmethod
    def streaming_ws() -> Self:
        return ConnectionState(Self.STREAMING_WS, RequestBodyState(0, 0))


struct TCPConnection[network: NetworkType = NetworkType.tcp4]:
    var socket: TCPSocket[TCPAddr[Self.network]]

    def __init__(out self, var socket: TCPSocket[TCPAddr[Self.network]]):
        self.socket = socket^

    def read(self, mut buf: Bytes) raises SocketRecvError -> UInt:
        """Read data from the TCP connection.

        Args:
            buf: Buffer to read data into.

        Returns:
            Number of bytes read.

        Raises:
            SocketRecvError: If read fails or connection is closed.
        """
        return self.socket.receive(buf)

    def write(self, buf: Span[Byte, _]) raises SendError -> UInt:
        """Write all data to the TCP connection, handling partial sends.

        Args:
            buf: Buffer containing data to write.

        Returns:
            Total number of bytes written.

        Raises:
            SendError: If write fails.
        """
        var total_sent: UInt = 0
        while total_sent < UInt(len(buf)):
            var sent = self.socket.send(buf[Int(total_sent):])
            total_sent += sent
        return total_sent

    def set_recv_timeout(self, seconds: Int) raises SetsockoptError:
        """Set the receive timeout on this connection's socket.

        Args:
            seconds: Timeout in seconds. 0 to disable.

        Raises:
            SetsockoptError: If setting the socket option fails.
        """
        self.socket.set_timeout(seconds)

    def close(mut self) raises FatalCloseError:
        """Close the TCP connection.

        Raises:
            FatalCloseError: If close fails (excludes EBADF).
        """
        self.socket.close()

    def shutdown(mut self) raises ShutdownEINVALError:
        """Shutdown the TCP connection.

        Raises:
            ShutdownEINVALError: If shutdown fails.
        """
        self.socket.shutdown()

    def teardown(deinit self) raises FatalCloseError:
        """Teardown the connection on destruction.

        Raises:
            FatalCloseError: If close fails during teardown.
        """
        self.socket^.teardown()

    def is_closed(self) -> Bool:
        return self.socket._closed

    # TODO: Switch to property or return ref when trait supports attributes.
    def local_addr(self) -> TCPAddr[Self.network]:
        return self.socket.local_address

    def remote_addr(self) -> TCPAddr[Self.network]:
        return self.socket.remote_address


struct UDPConnection[
    network: NetworkType = NetworkType.udp4,
    address_family: AddressFamily = AddressFamily.AF_INET,
](Movable):
    comptime _sock_type = Socket[
        sock_type = SocketType.SOCK_DGRAM,
        address = UDPAddr[Self.network],
        address_family = Self.address_family,
    ]
    var socket: Self._sock_type

    def __init__(out self, var socket: Self._sock_type):
        self.socket = socket^

    def read_from(mut self, size: Int = default_buffer_size) raises -> Tuple[Bytes, String, UInt16]:
        """Reads data from the underlying file descriptor.

        Args:
            size: The size of the buffer to read data into.

        Returns:
            The number of bytes read, or an error if one occurred.

        Raises:
            SocketRecvfromError: If an error occurred while reading data.
        """

        return self.socket.receive_from(size)

    def read_from(mut self, mut dest: Bytes) raises -> Tuple[UInt, String, UInt16]:
        """Reads data from the underlying file descriptor.

        Args:
            dest: The buffer to read data into.

        Returns:
            The number of bytes read, or an error if one occurred.

        Raises:
            SocketRecvfromError: If an error occurred while reading data.
        """

        return self.socket.receive_from(dest)

    def close(mut self) raises FatalCloseError:
        """Close the UDP connection.

        Raises:
            FatalCloseError: If close fails (excludes EBADF).
        """
        self.socket.close()

    def shutdown(mut self) raises ShutdownEINVALError:
        """Shutdown the UDP connection.

        Raises:
            ShutdownEINVALError: If shutdown fails.
        """
        self.socket.shutdown()

    def teardown(deinit self) raises FatalCloseError:
        """Teardown the connection on destruction.

        Raises:
            FatalCloseError: If close fails during teardown.
        """
        self.socket^.teardown()

    def is_closed(self) -> Bool:
        return self.socket._closed

    # fn local_addr(self) -> ref [self.socket.local_address] UDPAddr[network]:
    #     return self.socket.local_address

    # fn remote_addr(self) -> ref [self.socket.remote_address] UDPAddr[network]:
    #     return self.socket.remote_address


@fieldwise_init
struct CreateConnectionError(Movable, Writable):
    """Error variant for create_connection operations.
    Can be CSocketError from socket creation or SocketConnectError from connect.
    """

    comptime type = Variant[CSocketError, SocketConnectError]
    var value: Self.type

    @implicit
    def __init__(out self, var value: CSocketError):
        self.value = value^

    @implicit
    def __init__(out self, var value: SocketConnectError):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[CSocketError]():
            writer.write(self.value[CSocketError])
        elif self.value.isa[SocketConnectError]():
            writer.write(self.value[SocketConnectError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


def create_connection(mut host: String, port: UInt16) raises -> TCPConnection[NetworkType.tcp4]:
    """Connect to a server using a TCP socket.

    Args:
        host: The host to connect to.
        port: The port to connect on.

    Returns:
        A connected TCPConnection.

    Raises:
        Error: If socket creation, name resolution, or connection fails.
        The original error propagates: `Socket.connect` raises a plain
        `Error`, which the old `raises CreateConnectionError` signature
        could not carry — that wrap never compiled, this path being dead
        code until the client revived it.
    """
    var socket: Socket[TCPAddr[NetworkType.tcp4]]
    try:
        socket = Socket[TCPAddr[NetworkType.tcp4]]()
    except socket_err:
        raise socket_err^

    try:
        socket.connect(host, port)
    except connect_err:
        # Connection failed - try to shutdown gracefully before propagating error
        try:
            socket.shutdown()
        except shutdown_err:
            # Shutdown failure is not critical here - connection already failed
            pass
        # Propagate the original connection error
        raise connect_err^

    return TCPConnection(socket^)
