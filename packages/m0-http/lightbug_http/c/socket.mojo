from std.ffi import c_int, c_size_t, c_ssize_t, c_uchar, external_call, get_errno
from std.memory import stack_allocation
from std.sys.info import CompilationTarget, size_of

from lightbug_http.c.aliases import c_void
from lightbug_http.c.network import (
    SOCKADDR_STORAGE_SIZE,
    SocketAddress,
    sockaddr,
    sockaddr_host_port,
    socklen_t,
)
from lightbug_http.c.socket_error import SysError
from lightbug_http.c.fcntl import _fcntl, F_SETFD, FD_CLOEXEC


@fieldwise_init
struct ShutdownOption(Copyable, Equatable, Writable, TrivialRegisterPassable):
    var value: c_int
    comptime SHUT_RD = Self(0)
    comptime SHUT_WR = Self(1)
    comptime SHUT_RDWR = Self(2)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to[W: Writer, //](self, mut writer: W):
        if self == Self.SHUT_RD:
            writer.write("SHUT_RD")
        elif self == Self.SHUT_WR:
            writer.write("SHUT_WR")
        else:
            writer.write("SHUT_RDWR")

    def __str__(self) -> String:
        return String(self)


# Platform-specific socket constants.
# macOS uses BSD values (from sys/socket.h), Linux uses different numbering.
comptime _IS_MACOS = CompilationTarget.is_macos()
comptime SOL_SOCKET = 0xFFFF if _IS_MACOS else 1


# Socket option flags — platform-specific values resolved at compile time.
# Only the options this server sets, each checked against the macOS SDK's
# <sys/socket.h> and Linux's asm-generic/socket.h, which x86-64 and arm64
# share (SO_RCVTIMEO there is SO_RCVTIMEO_OLD on a 64-bit target). The
# upstream list carried twenty-two options nothing set, several with
# OpenBSD's numbers: its SO_TIMESTAMP, 0x0800, is 0x0400 on macOS.
@fieldwise_init
struct SocketOption(Copyable, Equatable, Writable, TrivialRegisterPassable):
    var value: c_int
    comptime SO_REUSEADDR = Self(c_int(0x0004 if _IS_MACOS else 2))
    comptime SO_KEEPALIVE = Self(c_int(0x0008 if _IS_MACOS else 9))
    comptime SO_REUSEPORT = Self(c_int(0x0200 if _IS_MACOS else 15))
    comptime SO_SNDBUF = Self(c_int(0x1001 if _IS_MACOS else 7))
    comptime SO_RCVBUF = Self(c_int(0x1002 if _IS_MACOS else 8))
    comptime SO_RCVTIMEO = Self(c_int(0x1006 if _IS_MACOS else 20))

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to[W: Writer, //](self, mut writer: W):
        if self == Self.SO_REUSEADDR:
            writer.write("SO_REUSEADDR")
        elif self == Self.SO_KEEPALIVE:
            writer.write("SO_KEEPALIVE")
        elif self == Self.SO_REUSEPORT:
            writer.write("SO_REUSEPORT")
        elif self == Self.SO_SNDBUF:
            writer.write("SO_SNDBUF")
        elif self == Self.SO_RCVBUF:
            writer.write("SO_RCVBUF")
        elif self == Self.SO_RCVTIMEO:
            writer.write("SO_RCVTIMEO")
        else:
            writer.write("SocketOption(", self.value, ")")

    def __str__(self) -> String:
        return String(self)


# The IPv6 level and the one option set there (macOS SDK <netinet6/in6.h>,
# Linux <linux/in6.h>): whether an AF_INET6 socket takes IPv6 alone or IPv4
# too, as `::ffff:a.b.c.d`. Its default is a system setting on both
# (`net.inet6.ip6.v6only`, `net.ipv6.bindv6only`), so a listener sets it.
comptime IPPROTO_IPV6 = 41
# TCP keepalive (`set_tcp_keepalive`), from each platform's <netinet/tcp.h>.
# The option that sets the idle time before the first probe is
# TCP_KEEPIDLE on Linux and TCP_KEEPALIVE on macOS: one name here, two
# numbers.
comptime IPPROTO_TCP = 6
comptime TCP_KEEPIDLE = 0x10 if _IS_MACOS else 4
comptime TCP_KEEPINTVL = 0x101 if _IS_MACOS else 5
comptime TCP_KEEPCNT = 0x102 if _IS_MACOS else 6
comptime IPV6_V6ONLY = 27 if _IS_MACOS else 26


# File open option flags (platform-specific)
comptime O_NONBLOCK = 4 if CompilationTarget.is_macos() else 2048
comptime O_CLOEXEC = 16777216 if CompilationTarget.is_macos() else 524288


# Socket Type constants. SOCK_STREAM is the only one a `Socket` is made
# with; the AF_UNIX datagram channels spell theirs in c/socketpair.mojo.
@fieldwise_init
struct SocketType(Copyable, Equatable, Writable, TrivialRegisterPassable):
    var value: c_int
    comptime SOCK_STREAM = Self(1)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to[W: Writer, //](self, mut writer: W):
        if self == Self.SOCK_STREAM:
            writer.write("SOCK_STREAM")
        else:
            writer.write("SocketType(", self.value, ")")

    def __str__(self) -> String:
        return String(self)


def _socket(domain: c_int, type: c_int, protocol: c_int) -> c_int:
    """Libc POSIX `socket` function.

    Args:
        domain: Address Family see AF_ aliases.
        type: Socket Type see SOCK_ aliases.
        protocol: The protocol to use.

    Returns:
        A File Descriptor or -1 in case of failure.

    #### C Function
    ```c
    int socket(int domain, int type, int protocol);
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/socket.3p.html .
    """
    return external_call["socket", c_int, type_of(domain), type_of(type), type_of(protocol)](domain, type, protocol)


def socket(domain: c_int, type: c_int, protocol: c_int) raises SysError -> c_int:
    """Libc POSIX `socket` function.

    Args:
        domain: Address Family see AF_ aliases.
        type: Socket Type see SOCK_ aliases.
        protocol: The protocol to use.

    Returns:
        A File Descriptor, never -1.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int socket(int domain, int type, int protocol)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/socket.3p.html .
    """
    # Close-on-exec (SPEC G16): a child the application starts must not
    # hold the listener or a client socket. Born that way on Linux; macOS
    # refuses SOCK_CLOEXEC in a type (EPROTONOSUPPORT, measured), so there
    # it is marked right after, below.
    var sock_type = type
    comptime if not CompilationTarget.is_macos():
        sock_type = type | c_int(O_CLOEXEC)
    var fd = _socket(domain, sock_type, protocol)
    if fd == -1:
        raise SysError("socket", get_errno())
    comptime if CompilationTarget.is_macos():
        # F_SETFD fails only on EBADF, which a fresh descriptor is not.
        _ = _fcntl(fd, c_int(F_SETFD), c_int(FD_CLOEXEC))
    return fd


def _setsockopt[
    origin: ImmOrigin
](
    socket: c_int,
    level: c_int,
    option_name: c_int,
    option_value: Pointer[c_void, origin],
    option_len: socklen_t,
) -> c_int:
    """Libc POSIX `setsockopt` function.

    Args:
        socket: A File Descriptor.
        level: The protocol level.
        option_name: The option to set.
        option_value: A Pointer to the value to set.
        option_len: The size of the value.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int setsockopt(int socket, int level, int option_name, const void *option_value, socklen_t option_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/setsockopt.3p.html .
    """
    return external_call[
        "setsockopt",
        c_int,  # FnName, RetType
        type_of(socket),
        type_of(level),
        type_of(option_name),
        type_of(option_value),
        type_of(option_len),  # Args
    ](socket, level, option_name, option_value, option_len)


def setsockopt(
    socket: FileDescriptor,
    level: c_int,
    option_name: c_int,
    option_value: c_int,
) raises SysError:
    """Libc POSIX `setsockopt` function. Manipulate options for the socket referred to by the file descriptor, `socket`.

    Args:
        socket: A File Descriptor.
        level: The protocol level.
        option_name: The option to set.
        option_value: A Pointer to the value to set.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int setsockopt(int socket, int level, int option_name, const void *option_value, socklen_t option_len);
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/setsockopt.3p.html .
    """
    var result = _setsockopt(
        Int32(socket.value),
        level,
        option_name,
        Pointer(to=option_value).unsafe_bitcast[c_void](),
        UInt32(size_of[Int32]()),
    )
    if result == -1:
        raise SysError("setsockopt", get_errno())


def set_tcp_keepalive(
    socket: FileDescriptor, idle_s: Int, interval_s: Int, count: Int,
) raises SysError:
    """Turn TCP keepalive on for a connected socket: after `idle_s` seconds
    with nothing received, the kernel probes the peer every `interval_s`
    seconds and fails the socket once `count` probes in a row go unanswered.

    The probes are empty segments, so nothing reaches the peer's
    application, and a live peer's kernel answers them whatever its
    application is doing. The timings go in before the switch, so the first
    timer the kernel arms is the one asked for.

    Raises:
        SysError: If a call fails, whatever its errno.
    """
    setsockopt(socket, c_int(IPPROTO_TCP), c_int(TCP_KEEPIDLE), c_int(idle_s))
    setsockopt(socket, c_int(IPPROTO_TCP), c_int(TCP_KEEPINTVL), c_int(interval_s))
    setsockopt(socket, c_int(IPPROTO_TCP), c_int(TCP_KEEPCNT), c_int(count))
    setsockopt(socket, c_int(SOL_SOCKET), SocketOption.SO_KEEPALIVE.value, c_int(1))


def _getsockname[
    origin: MutOrigin
](socket: c_int, address: Pointer[sockaddr, _], address_len: Pointer[socklen_t, origin],) -> c_int:
    """Libc POSIX `getsockname` function.

    Args:
        socket: A File Descriptor.
        address: A Pointer to a buffer to store the address of the peer.
        address_len: A Pointer to the size of the buffer.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int getsockname(int socket, struct sockaddr *restrict address, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/getsockname.3p.html
    """
    return external_call[
        "getsockname",
        c_int,  # FnName, RetType
        type_of(socket),
        type_of(address),
        type_of(address_len),  # Args
    ](socket, address, address_len)


def getsockname(socket: FileDescriptor, mut address: SocketAddress) raises SysError:
    """Libc POSIX `getsockname` function.

    Args:
        socket: A File Descriptor.
        address: A to a buffer to store the address of the peer.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int getsockname(int socket, struct sockaddr *restrict address, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/getsockname.3p.html .
    """
    var sockaddr_size = SocketAddress.CAPACITY
    var result = _getsockname(Int32(socket.value), address.unsafe_ptr(), Pointer(to=sockaddr_size))
    if result == -1:
        raise SysError("getsockname", get_errno())
    address.length = sockaddr_size


def _getpeername[
    origin: MutOrigin
](sockfd: c_int, addr: Pointer[sockaddr, _], address_len: Pointer[socklen_t, origin],) -> c_int:
    """Libc POSIX `getpeername` function.

    Args:
        sockfd: A File Descriptor.
        addr: A Pointer to a buffer to store the address of the peer.
        address_len: A Pointer to the size of the buffer.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int getpeername(int socket, struct sockaddr *restrict addr, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man2/getpeername.2.html .
    """
    return external_call[
        "getpeername",
        c_int,  # FnName, RetType
        type_of(sockfd),
        type_of(addr),
        type_of(address_len),  # Args
    ](sockfd, addr, address_len)


def getpeername(file_descriptor: FileDescriptor) raises SysError -> SocketAddress:
    """Libc POSIX `getpeername` function.

    Args:
        file_descriptor: A File Descriptor.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int getpeername(int socket, struct sockaddr *restrict addr, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man2/getpeername.2.html .
    """
    var remote_address = SocketAddress()
    var sockaddr_size = SocketAddress.CAPACITY
    var result = _getpeername(
        Int32(file_descriptor.value),
        remote_address.unsafe_ptr(),
        Pointer(to=sockaddr_size),
    )
    if result == -1:
        raise SysError("getpeername", get_errno())
    remote_address.length = sockaddr_size

    return remote_address^


def _bind[origin: ImmOrigin](socket: c_int, address: Pointer[sockaddr, origin], address_len: socklen_t) -> c_int:
    """Libc POSIX `bind` function. Assigns the address specified by `address` to the socket referred to by
       the file descriptor `socket`.

    Args:
        socket: A File Descriptor.
        address: A Pointer to the address to bind to.
        address_len: The size of the address.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int bind(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/bind.3p.html
    """
    return external_call["bind", c_int, type_of(socket), type_of(address), type_of(address_len)](
        socket, address, address_len
    )


def bind(socket: FileDescriptor, mut address: SocketAddress) raises SysError:
    """Libc POSIX `bind` function.

    Args:
        socket: A File Descriptor.
        address: A Pointer to the address to bind to.

    Raises:
        SysError: If the call fails, whatever its errno. EADDRINUSE, the
            one a caller may wait out, is `address_in_use()`.

    #### C Function
    ```c
    int bind(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/bind.3p.html .
    """
    var result = _bind(Int32(socket.value), address.unsafe_ptr(), address.length)
    if result == -1:
        raise SysError("bind", get_errno())


def _listen(socket: c_int, backlog: c_int) -> c_int:
    """Libc POSIX `listen` function.

    Args:
        socket: A File Descriptor.
        backlog: The maximum length of the queue of pending connections.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int listen(int socket, int backlog)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/listen.3p.html
    """
    return external_call["listen", c_int, type_of(socket), type_of(backlog)](socket, backlog)


def listen(socket: FileDescriptor, backlog: c_int) raises SysError:
    """Libc POSIX `listen` function.

    Args:
        socket: A File Descriptor.
        backlog: The maximum length of the queue of pending connections.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int listen(int socket, int backlog)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/listen.3p.html .
    """
    var result = _listen(Int32(socket.value), backlog)
    if result == -1:
        raise SysError("listen", get_errno())


def _accept[
    address_origin: MutOrigin, len_origin: MutOrigin
](socket: c_int, address: Pointer[sockaddr, address_origin], address_len: Pointer[socklen_t, len_origin],) -> c_int:
    """Libc POSIX `accept` function.

    Args:
        socket: A File Descriptor.
        address: A Pointer to a buffer to store the address of the peer.
        address_len: A Pointer to the size of the buffer.

    Returns:
        A File Descriptor or -1 in case of failure.

    #### C Function
    ```c
    int accept(int socket, struct sockaddr *restrict address, socklen_t *restrict address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/accept.3p.html .
    """
    # Close-on-exec (SPEC G16): a child the application starts must not hold
    # a client's connection, or the connection outlives the server's close
    # of it -- FastHTML's terminal example took 10 s to close a WebSocket.
    comptime if CompilationTarget.is_macos():
        var fd = external_call["accept", c_int, type_of(socket), type_of(address), type_of(address_len)](  # FnName, RetType
            socket, address, address_len
        )
        if fd >= 0:
            # macOS has no accept4, so the fd is marked right after, and a
            # fork and exec on another thread in the instant between the two
            # calls would inherit it -- the window CPython has there too.
            # F_SETFD fails only on EBADF, which a fresh descriptor is not.
            _ = _fcntl(fd, c_int(F_SETFD), c_int(FD_CLOEXEC))
        return fd
    else:
        # accept4(SOCK_CLOEXEC): born close-on-exec, with no window.
        return external_call[
            "accept4", c_int, type_of(socket), type_of(address), type_of(address_len), c_int
        ](socket, address, address_len, c_int(O_CLOEXEC))


def accept_with_peer(
    socket: FileDescriptor,
) raises SysError -> Tuple[FileDescriptor, String, Int]:
    """Libc POSIX `accept`, keeping the peer address the kernel handed over.

    Returns `(fd, host, port)`, read by `sockaddr_host_port`: an IPv4 peer
    dotted, an IPv6 one as `inet_ntop` writes it, and an IPv4 peer of a
    dual-stack listener as IPv4, not `::ffff:a.b.c.d`. Anything else, or a
    truncated address, yields `("", 0)` rather than a guess. The address
    lands in `sockaddr_storage`-sized room: in one 16-byte `sockaddr` the
    kernel truncated an IPv6 peer before its address (review R15), as
    upstream's 4-byte `addrlen` once truncated every peer.

    Raises:
        SysError: If the call fails, whatever its errno. The accept drain
            reads `would_block()`, `connection_aborted()` and
            `interrupted()`.
    """
    var storage = stack_allocation[SOCKADDR_STORAGE_SIZE, UInt8]()
    var buffer_size = socklen_t(SOCKADDR_STORAGE_SIZE)
    var result = _accept(
        Int32(socket.value),
        storage.unsafe_bitcast[sockaddr](),
        Pointer(to=buffer_size),
    )
    if result == -1:
        raise SysError("accept", get_errno())
    var peer = sockaddr_host_port(storage, Int(buffer_size))
    return (FileDescriptor(Int(result)), peer[0], peer[1])


def _connect[origin: ImmOrigin](socket: c_int, address: Pointer[sockaddr, origin], address_len: socklen_t) -> c_int:
    """Libc POSIX `connect` function.

    Args:
        socket: A File Descriptor.
        address: A Pointer to the address to connect to.
        address_len: The size of the address.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int connect(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/connect.3p.html
    """
    return external_call[
        "connect",
        c_int,
        type_of(socket),
        type_of(address),
        type_of(address_len),
    ](socket, address, address_len)


def connect(socket: FileDescriptor, mut address: SocketAddress) raises SysError:
    """Libc POSIX `connect` function.

    Args:
        socket: A File Descriptor.
        address: The address to connect to.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int connect(int socket, const struct sockaddr *address, socklen_t address_len)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/connect.3p.html .
    """
    var result = _connect(c_int(socket.value), address.unsafe_ptr(), address.length)
    if result == -1:
        raise SysError("connect", get_errno())


def _recv(
    socket: c_int,
    buffer: Pointer[c_void, _],
    length: c_size_t,
    flags: c_int,
) -> c_ssize_t:
    """Libc POSIX `recv` function.

    Args:
        socket: A File Descriptor.
        buffer: A Pointer to the buffer to store the received data.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes received or -1 in case of failure.

    #### C Function
    ```c
    ssize_t recv(int socket, void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/recv.3p.html
    """
    return external_call[
        "recv",
        c_ssize_t,  # FnName, RetType
        type_of(socket),
        type_of(buffer),
        type_of(length),
        type_of(flags),  # Args
    ](socket, buffer, length, flags)


def recv[
    origin: MutOrigin
](socket: FileDescriptor, buffer: Span[c_uchar, origin], length: c_size_t, flags: c_int,) raises SysError -> c_size_t:
    """Libc POSIX `recv` function.

    Args:
        socket: A File Descriptor.
        buffer: A Pointer to the buffer to store the received data.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes received; 0 is the peer's EOF.

    Raises:
        SysError: If the call fails, whatever its errno; `would_block()`
            on a non-blocking socket with nothing to read.

    #### C Function
    ```c
    ssize_t recv(int socket, void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/recv.3p.html .
    """
    var result = _recv(Int32(socket.value), buffer.unsafe_ptr().unsafe_bitcast[c_void](), length, flags)
    if result == -1:
        raise SysError("recv", get_errno())

    return UInt(result)


def _send(
    socket: c_int,
    buffer: Pointer[c_void, _],
    length: c_size_t,
    flags: c_int,
) -> c_ssize_t:
    """Libc POSIX `send` function.

    Args:
        socket: A File Descriptor.
        buffer: A Pointer to the buffer to send.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes sent or -1 in case of failure.

    #### C Function
    ```c
    ssize_t send(int socket, const void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/send.3p.html
    """
    return external_call[
        "send",
        c_ssize_t,
        type_of(socket),
        type_of(buffer),
        type_of(length),
        type_of(flags),
    ](socket, buffer, length, flags)


def send[
    origin: ImmOrigin
](socket: FileDescriptor, buffer: Span[c_uchar, origin], length: c_size_t, flags: c_int,) raises SysError -> c_size_t:
    """Libc POSIX `send` function.

    Args:
        socket: A File Descriptor.
        buffer: A Pointer to the buffer to send.
        length: The size of the buffer.
        flags: Flags to control the behaviour of the function.

    Returns:
        The number of bytes sent.

    Raises:
        SysError: If the call fails, whatever its errno; `would_block()`
            on a non-blocking socket whose send buffer is full.

    #### C Function
    ```c
    ssize_t send(int socket, const void *buffer, size_t length, int flags)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/send.3p.html .
    """
    var result = _send(Int32(socket.value), buffer.unsafe_ptr().unsafe_bitcast[c_void](), length, flags)
    if result == -1:
        raise SysError("send", get_errno())

    return UInt(result)


# --- Vectored I/O (writev) ---


@fieldwise_init
struct iovec_t(TrivialRegisterPassable):
    """POSIX struct iovec for scatter-gather I/O.

    Layout matches C: void *iov_base (8 bytes) + size_t iov_len (8 bytes).
    """

    var iov_base: UInt
    var iov_len: UInt


def _writev(
    fd: c_int,
    iov: Pointer[iovec_t, ...],
    iovcnt: c_int,
) -> c_ssize_t:
    """Libc POSIX `writev` function.

    Args:
        fd: A file descriptor.
        iov: Pointer to an array of iovec structures.
        iovcnt: Number of iovec structures.

    Returns:
        The number of bytes written or -1 in case of failure.

    #### C Function
    ```c
    ssize_t writev(int fd, const struct iovec *iov, int iovcnt)
    ```
    """
    return external_call[
        "writev",
        c_ssize_t,
        type_of(fd),
        type_of(iov),
        type_of(iovcnt),
    ](fd, iov, iovcnt)


def try_writev(
    fd: FileDescriptor,
    iov: Pointer[iovec_t, ...],
    iovcnt: Int,
) -> Int:
    """Libc POSIX `writev` — scatter-gather write (non-raising).

    Returns bytes written on success, -1 for EAGAIN/EWOULDBLOCK,
    -2 for fatal errors (connection reset, bad fd, etc.).
    """
    var result = _writev(Int32(fd.value), iov, c_int(iovcnt))
    if result == -1:
        var errno = get_errno()
        if errno in [errno.EAGAIN, errno.EWOULDBLOCK]:
            return -1
        return -2

    return Int(result)


def _shutdown(socket: c_int, how: c_int) -> c_int:
    """Libc POSIX `shutdown` function.

    Args:
        socket: A File Descriptor.
        how: How to shutdown the socket.

    Returns:
        0 on success, -1 on error.

    #### C Function
    ```c
    int shutdown(int socket, int how)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/shutdown.3p.html .
    """
    return external_call["shutdown", c_int, type_of(socket), type_of(how)](socket, how)


def shutdown(socket: FileDescriptor, how: ShutdownOption) raises SysError:
    """Libc POSIX `shutdown` function.

    Args:
        socket: A File Descriptor.
        how: How to shutdown the socket.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int shutdown(int socket, int how)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/shutdown.3p.html .
    """
    var result = _shutdown(Int32(socket.value), how.value)
    if result == -1:
        raise SysError("shutdown", get_errno())


def _close(fildes: c_int) -> c_int:
    """Libc POSIX `close` function.

    Args:
        fildes: A File Descriptor to close.

    Returns:
        Upon successful completion, 0 shall be returned; otherwise, -1
        shall be returned and errno set to indicate the error.

    #### C Function
    ```c
    int close(int fildes).
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/close.3p.html
    """
    return external_call["close", c_int, type_of(fildes)](fildes)


def close(file_descriptor: FileDescriptor) raises SysError:
    """Libc POSIX `close` function.

    Args:
        file_descriptor: A File Descriptor to close.

    Raises:
        SysError: If the call fails, whatever its errno.

    #### C Function
    ```c
    int close(int fildes)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/close.3p.html .
    """
    if _close(Int32(file_descriptor.value)) == -1:
        raise SysError("close", get_errno())
