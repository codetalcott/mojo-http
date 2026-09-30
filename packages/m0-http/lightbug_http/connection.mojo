from std.sys.info import CompilationTarget
from std.time import sleep

from lightbug_http.address import (
    HostPort,
    NetworkType,
    ParseError,
    TCPAddr,
    is_ipv6_literal,
    join_host_port,
    parse_address,
)
from lightbug_http.c.address import AddressFamily
from lightbug_http.c.process import ignore_sigpipe
from lightbug_http.c.socket_error import SysError
from lightbug_http.io.bytes import Bytes
from lightbug_http.socket import (
    Socket,
    SocketBindError,
    SocketOption,
    SocketRecvError,
    TCPSocket,
)
from lightbug_http.utils.error import CustomError
from std.utils import Variant


comptime default_buffer_size = 4096
"""The default buffer size for reading and writing data."""


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
struct ListenerError(Movable, Writable):
    """Error variant for listener creation operations.

    An address that does not parse, or the call that failed, errno and all:
    a SysError from `socket` or `listen`, a SocketBindError from the bind.
    """

    comptime type = Variant[AddressParseError, SysError, SocketBindError, Error]
    var value: Self.type

    @implicit
    def __init__(out self, value: AddressParseError):
        self.value = value

    @implicit
    def __init__(out self, value: SysError):
        self.value = value

    @implicit
    def __init__(out self, var value: SocketBindError):
        self.value = value^

    @implicit
    def __init__(out self, var value: Error):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[AddressParseError]():
            writer.write(self.value[AddressParseError])
        elif self.value.isa[SysError]():
            writer.write(self.value[SysError])
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

    def address_in_use(self) -> Bool:
        """Whether this is a bind refused with EADDRINUSE, its retries spent
        -- the one failure `ListenConfig.listen` waits out, and the only one
        a caller may report as "address already in use"."""
        return self.value.isa[SocketBindError]() and bind_in_use(
            self.value[SocketBindError]
        )


def bind_in_use(err: SocketBindError) -> Bool:
    """Whether a bind failed because the address is taken (EADDRINUSE).

    The one bind failure that waiting can cure: a previous server still
    draining, or another one on the port. Every other errno -- an address
    that is not on this machine (EADDRNOTAVAIL), a privileged port
    (EACCES) -- fails the same way a second later.
    """
    return err.value.isa[SysError]() and err.value[SysError].address_in_use()


struct NoTLSListener[network: NetworkType = NetworkType.tcp](Movable):
    """A bound, listening TCP socket; the event loop accepts from its descriptor.

    `tcp`, the default, is the family its address names, which the socket
    holds as a value (`Socket.family`): `::` and `0.0.0.0` listeners are
    one type, so nothing that holds a listener is generic over a family
    (review R15). It was `tcp4`, whose sockets were IPv4 whatever the
    address.
    """

    var socket: TCPSocket[TCPAddr[Self.network]]

    def __init__(out self, var socket: TCPSocket[TCPAddr[Self.network]]):
        self.socket = socket^

    def __init__(out self) raises SysError:
        comptime if Self.network == NetworkType.tcp6:
            self.socket = Socket[TCPAddr[Self.network]](family=AddressFamily.AF_INET6)
        else:
            self.socket = Socket[TCPAddr[Self.network]](family=AddressFamily.AF_INET)

    def close(mut self) raises SysError -> None:
        """Close the listener socket.

        Raises:
            SysError: If close fails (excludes EBADF).
        """
        return self.socket.close()

    def shutdown(mut self) raises SysError:
        """Shutdown the listener socket.

        Raises:
            SysError: If shutdown fails with EINVAL.
        """
        return self.socket.shutdown()

    def teardown(deinit self) raises SysError:
        """Teardown the listener socket on destruction.

        Raises:
            SysError: If close fails during teardown.
        """
        self.socket^.teardown()

    def into_fd(deinit self) -> FileDescriptor:
        """Hand the listener's descriptor over without closing it.

        `run_event_loop` owns the listener it is given and closes it once,
        as its drain begins; this is how an owner gives it one (review
        B26). Passing `listener.socket.fd` instead left the listener here to
        close the number a second time when it was destroyed, after the
        loop returned -- by then the lowest free number, and often another
        part of the process's descriptor.
        """
        return self.socket^.into_fd()

    def addr(self) -> TCPAddr[Self.network]:
        return self.socket.local_address


struct ListenConfig:
    var max_bind_retries: Int
    """Maximum number of bind() attempts on an address IN USE before its
    EADDRINUSE is raised (Phase 4c).

    Each retry sleeps 1 second.  Default 30 gives ~30 s total wait, covering
    the typical TIME_WAIT drain after a server restart.  Set to 0 for
    infinite retries (original behaviour). Any other bind failure is raised
    at the first attempt: waiting cures none of them (`bind_in_use`).
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
        max_bind_retries: Int = 30,
        reuse_port: Bool = False,
        quiet: Bool = False,
    ):
        self.max_bind_retries = max_bind_retries
        self.reuse_port = reuse_port
        self.quiet = quiet

    def listen[
        network: NetworkType = NetworkType.tcp
    ](self, address: StringSpan) raises ListenerError -> NoTLSListener[network]:
        """Create a TCP listener on the specified address.

        The process becomes a server here, so SIGPIPE is ignored first
        (`ignore_sigpipe`, SPEC A25). Both hosts bind before they fork or
        start a thread, so the ignore reaches every process and thread they
        run: a supervisor, which never enters the event loop, and whatever an
        application runs before its loop does -- a handler's or a producer's
        `make`, the producer's first steps, a pool.

        An IPv6 address is written in brackets, `[::]:8080`. Under `tcp`,
        the default, it makes an IPv6 listener -- `[::]` dual-stack, so
        IPv4 clients reach it too, and `[::1]` the IPv6 loopback alone --
        and any other address an IPv4 one, as every listener was. Under
        `tcp6` an IPv6 listener takes IPv6 alone, and under `tcp4` an IPv6
        address does not bind.

        Parameters:
            network: `tcp` (the family the address names), `tcp4` or `tcp6`.

        Args:
            address: The address to listen on (host:port).

        Returns:
            A NoTLSListener ready to accept connections.

        Raises:
            ListenerError: If address parsing, socket creation, bind, or listen fails.
        """
        ignore_sigpipe()
        var local: HostPort
        try:
            local = parse_address[network](address)
        except ParseError:
            raise AddressParseError()

        # The family is the address's (review R15). Every listener was
        # IPv4 whatever it was given, and AF_INET6 held OpenBSD's number,
        # so an IPv6 address could not be listened on at all.
        var family = AddressFamily.AF_INET
        comptime if network == NetworkType.tcp6:
            family = AddressFamily.AF_INET6
        elif network == NetworkType.tcp:
            if is_ipv6_literal(local.host):
                family = AddressFamily.AF_INET6

        var socket: Socket[TCPAddr[network]]
        try:
            socket = Socket[TCPAddr[network]](family=family)
        except socket_err:
            raise socket_err

        # Dual-stack on `::` under `tcp`, set rather than left to the
        # system's default, which differs by host (`Socket.set_ipv6_only`).
        # Fatal, unlike the options below: a listener that cannot say which
        # families it takes would serve whichever the host chose.
        if family == AddressFamily.AF_INET6:
            try:
                socket.set_ipv6_only(network == NetworkType.tcp6)
            except v6only_err:
                raise v6only_err

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
                # Only an address in use is worth waiting out. Every other
                # failure is raised at once, in its own words: retried, an
                # address not on this machine spent the whole budget and was
                # then reported as a failure to listen -- which m0serve
                # printed as "address already in use".
                if not bind_in_use(bind_err):
                    raise bind_err^
                bind_attempts += 1
                if self.max_bind_retries > 0 and bind_attempts >= self.max_bind_retries:
                    raise bind_err^
                if not bind_fail_logged:
                    print(
                        "Bind failed on " + join_host_port(addr.ip, String(addr.port))
                        + " (address in use: another server on the port,"
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
            raise listen_err

        var listener = NoTLSListener(socket^)
        var msg = String(
            "\n🔥🐝 Lightbug is listening on ",
            "http://",
            join_host_port(addr.ip, String(addr.port)),
        )
        if not self.quiet:
            print(msg)
            print("Ready to accept connections...")

        return listener^


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
    - lingering: an error was sent before the request was read; the
      write side is shut and what the client still sends is discarded
      until it closes or the linger's deadline passes (RFC 9112 §9.6)
    """

    comptime READING_HEADERS = 0
    comptime READING_BODY = 1
    comptime PROCESSING = 2
    comptime RESPONDING = 3
    comptime CLOSED = 4
    comptime STREAMING_SSE = 5
    comptime STREAMING_WS = 6
    comptime LINGERING = 7

    var kind: Int

    @staticmethod
    def reading_headers() -> Self:
        return ConnectionState(Self.READING_HEADERS)

    @staticmethod
    def reading_body() -> Self:
        """The body's length is not kept here: the provision's
        `BodyReadState` holds its length and progress, and is what the loop
        reads."""
        return ConnectionState(Self.READING_BODY)

    @staticmethod
    def processing() -> Self:
        return ConnectionState(Self.PROCESSING)

    @staticmethod
    def responding() -> Self:
        return ConnectionState(Self.RESPONDING)

    @staticmethod
    def closed() -> Self:
        return ConnectionState(Self.CLOSED)

    @staticmethod
    def streaming_sse() -> Self:
        return ConnectionState(Self.STREAMING_SSE)

    @staticmethod
    def streaming_ws() -> Self:
        return ConnectionState(Self.STREAMING_WS)

    @staticmethod
    def lingering() -> Self:
        return ConnectionState(Self.LINGERING)


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

    def write(self, buf: Span[Byte, _]) raises -> UInt:
        """Write all data to the TCP connection, handling partial sends.

        Untyped on purpose: the client writes and reads in one `try` beside
        errors of its own, which `SendError`'s `Error` arm used to absorb
        and a `SysError` cannot.

        Args:
            buf: Buffer containing data to write.

        Returns:
            Total number of bytes written.

        Raises:
            Error: The send's SysError, as text, if a send fails.
        """
        var total_sent: UInt = 0
        while total_sent < UInt(len(buf)):
            var sent = self.socket.send(buf[Int(total_sent):])
            total_sent += sent
        return total_sent

    def set_recv_timeout(self, seconds: Int) raises SysError:
        """Set the receive timeout on this connection's socket.

        Args:
            seconds: Timeout in seconds. 0 to disable.

        Raises:
            SysError: If setting the socket option fails.
        """
        self.socket.set_timeout(seconds)

    def close(mut self) raises SysError:
        """Close the TCP connection.

        Raises:
            SysError: If close fails (excludes EBADF).
        """
        self.socket.close()

    def shutdown(mut self) raises SysError:
        """Shutdown the TCP connection.

        Raises:
            SysError: If shutdown fails with EINVAL.
        """
        self.socket.shutdown()

    def teardown(deinit self) raises SysError:
        """Teardown the connection on destruction.

        Raises:
            SysError: If close fails during teardown.
        """
        self.socket^.teardown()

    def is_closed(self) -> Bool:
        return self.socket._closed

    # TODO: Switch to property or return ref when trait supports attributes.
    def local_addr(self) -> TCPAddr[Self.network]:
        return self.socket.local_address

    def remote_addr(self) -> TCPAddr[Self.network]:
        return self.socket.remote_address


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
        `Error`, name resolution's among them.
    """
    var socket: Socket[TCPAddr[NetworkType.tcp4]]
    try:
        socket = Socket[TCPAddr[NetworkType.tcp4]]()
    except socket_err:
        raise socket_err

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
