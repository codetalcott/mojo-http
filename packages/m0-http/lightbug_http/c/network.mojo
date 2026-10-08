from std.ffi import c_char, c_int, c_uint, c_ushort, external_call, get_errno
from std.sys.info import CompilationTarget, size_of

from lightbug_http.c.address import AddressFamily, AddressLength
from lightbug_http.c.aliases import ExternalImmutPointer, ExternalMutPointer, c_void
from lightbug_http.utils.error import CustomError
from std.memory import stack_allocation
from std.memory.alloc import unsafe_alloc
from std.utils import StaticTuple, Variant


@fieldwise_init
struct InetNtopEAFNOSUPPORTError(CustomError, TrivialRegisterPassable):
    comptime message = "inet_ntop Error (EAFNOSUPPORT): `*src` was not an `AF_INET` or `AF_INET6` family address."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct InetNtopENOSPCError(CustomError, TrivialRegisterPassable):
    comptime message = "inet_ntop Error (ENOSPC): The buffer size was not large enough to store the presentation form of the address."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct InetPtonInvalidAddressError(CustomError, TrivialRegisterPassable):
    comptime message = "inet_pton Error: The input is not a valid address."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct InetNtopError(Movable, Writable):
    """Typed error variant for inet_ntop() function."""

    comptime type = Variant[InetNtopEAFNOSUPPORTError, InetNtopENOSPCError, Error]
    var value: Self.type

    @implicit
    def __init__(out self, value: InetNtopEAFNOSUPPORTError):
        self.value = value

    @implicit
    def __init__(out self, value: InetNtopENOSPCError):
        self.value = value

    @implicit
    def __init__(out self, var value: Error):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[InetNtopEAFNOSUPPORTError]():
            writer.write(self.value[InetNtopEAFNOSUPPORTError])
        elif self.value.isa[InetNtopENOSPCError]():
            writer.write(self.value[InetNtopENOSPCError])
        elif self.value.isa[Error]():
            writer.write(self.value[Error])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct InetPtonError(Movable, Writable):
    """Typed error variant for inet_pton() function."""

    comptime type = Variant[InetPtonInvalidAddressError, Error]
    var value: Self.type

    @implicit
    def __init__(out self, value: InetPtonInvalidAddressError):
        self.value = value

    @implicit
    def __init__(out self, var value: Error):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[InetPtonInvalidAddressError]():
            writer.write(self.value[InetPtonInvalidAddressError])
        elif self.value.isa[Error]():
            writer.write(self.value[Error])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


def htons(hostshort: c_ushort) -> c_ushort:
    """Libc POSIX `htons` function.

    Args:
        hostshort: A 16-bit integer in host byte order.

    Returns:
        The value provided in network byte order.

    #### C Function
    ```c
    uint16_t htons(uint16_t hostshort)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/htonl.3p.html .
    """
    return external_call["htons", c_ushort, type_of(hostshort)](hostshort)


def ntohs(netshort: c_ushort) -> c_ushort:
    """Libc POSIX `ntohs` function.

    Args:
        netshort: A 16-bit integer in network byte order.

    Returns:
        The value provided in host byte order.

    #### C Function
    ```c
    uint16_t ntohs(uint16_t netshort)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/htonl.3p.html .
    """
    return external_call["ntohs", c_ushort, type_of(netshort)](netshort)


comptime sa_family_t = c_ushort
"""Address family type."""
comptime socklen_t = c_uint
"""Used to represent the length of socket addresses and other related data structures in bytes."""
comptime in_addr_t = c_uint
"""Used to represent IPv4 Internet addresses."""
comptime in_port_t = c_ushort
"""Used to represent port numbers."""


@fieldwise_init
struct in_addr(TrivialRegisterPassable):
    var s_addr: in_addr_t


@fieldwise_init
struct InetAddress(TrivialRegisterPassable):
    """An address in network byte order, as `inet_pton` writes it: the four
    bytes of an IPv4 address, or the sixteen of an IPv6 one, from
    `bytes[0]`; the rest are zero."""

    var bytes: StaticTuple[UInt8, 16]

    def in_addr(self) -> in_addr_t:
        """The first four bytes, as `sockaddr_in.sin_addr` holds an IPv4
        address: loaded in memory order, so still network byte order."""
        return Pointer(to=self.bytes).unsafe_bitcast[in_addr_t]()[]

    def is_v4_mapped(self) -> Bool:
        """Whether this IPv6 address is an IPv4 one written as IPv6
        (`::ffff:a.b.c.d`, the IPv4-mapped form): how a dual-stack
        socket reports an IPv4 peer."""
        for i in range(10):
            if self.bytes[i] != 0:
                return False
        return self.bytes[10] == 0xFF and self.bytes[11] == 0xFF

    def mapped_ipv4(self) -> String:
        """The IPv4 address a v4-mapped IPv6 one carries, dotted."""
        return String(
            Int(self.bytes[12]), ".", Int(self.bytes[13]), ".",
            Int(self.bytes[14]), ".", Int(self.bytes[15]),
        )


struct sockaddr(TrivialRegisterPassable):
    var sa_family: sa_family_t
    var sa_data: StaticTuple[c_char, 14]

    def __init__(
        out self,
        family: sa_family_t = 0,
        data: StaticTuple[c_char, 14] = StaticTuple[c_char, 14](),
    ):
        self.sa_family = family
        self.sa_data = data


@fieldwise_init
struct sockaddr_in(TrivialRegisterPassable):
    var sin_family: sa_family_t
    var sin_port: in_port_t
    var sin_addr: in_addr
    var sin_zero: StaticTuple[c_char, 8]

    def __init__(out self, address_family: Int, port: UInt16, binary_ip: UInt32):
        """Construct a sockaddr_in struct.

        Args:
            address_family: The address family.
            port: A 16-bit integer port in host byte order, gets converted to network byte order via `htons`.
            binary_ip: The binary representation of the IP address.
        """
        # macOS opens the struct `[sin_len u8][sin_family u8]`, Linux with
        # `sin_family` as a u16: written as a plain u16 on macOS, the family
        # landed in `sin_len` and `sin_family` read 0. `bind` accepted it
        # (XNU takes AF_UNSPEC for AF_INET, for old callers), but the
        # address did not say what it was (review R15).
        comptime if CompilationTarget.is_macos():
            self.sin_family = sa_family_t(size_of[sockaddr_in]() | (address_family << 8))
        else:
            self.sin_family = sa_family_t(address_family)
        self.sin_port = htons(port)
        self.sin_addr = in_addr(binary_ip)
        self.sin_zero = StaticTuple[c_char, 8](0, 0, 0, 0, 0, 0, 0, 0)


comptime SOCKADDR_STORAGE_SIZE = 128
"""`sizeof(struct sockaddr_storage)` on macOS and Linux: room for any
address family's `sockaddr`, an IPv6 one's 28 bytes included."""

comptime SOCKADDR_IN6_SIZE = 28
"""`sizeof(struct sockaddr_in6)` on macOS and Linux."""

comptime _IS_MACOS = CompilationTarget.is_macos()


def sockaddr_family(sa: Pointer[UInt8, _]) -> Int:
    """The address family a `sockaddr` the kernel filled carries.

    macOS's opens `[sa_len u8][sa_family u8]` and Linux's `[sa_family u16]`
    (little-endian on every target here), so the family is byte 1 on one
    and bytes 0-1 on the other.
    """
    comptime if _IS_MACOS:
        return Int(sa[unsafe_offset=1])
    else:
        return Int(sa[unsafe_offset=0]) | (Int(sa[unsafe_offset=1]) << 8)


def sockaddr_host_port(sa: Pointer[UInt8, _], length: Int) -> Tuple[String, Int]:
    """The host and port a `sockaddr` the kernel filled names, or `("", 0)`
    for a family other than IPv4 and IPv6, or a truncated address.

    One reader for every address the server reports -- an accepted peer, a
    socket's own name -- so an IPv6 peer reads the same wherever it is
    read. The port is at bytes 2-3 in both families, network order. An
    IPv4 address is bytes 4-7 of a `sockaddr_in`, an IPv6 one bytes 8-23 of
    a `sockaddr_in6`, formatted by `inet_ntop`.

    **An IPv4 peer of a dual-stack socket is reported as IPv4.** The kernel
    hands it over as `::ffff:a.b.c.d`; it is read as `a.b.c.d`, so a server
    moved from `--host 0.0.0.0` to `--host ::` reports every IPv4 client
    exactly as it did (review R15). gunicorn and uvicorn report the mapped
    form (measured 2026-09-29); Go's `net` and Java's `InetAddress` unmap
    as this does.
    """
    if length < 4:
        return (String(""), 0)
    var family = sockaddr_family(sa)
    var port = (Int(sa[unsafe_offset=2]) << 8) | Int(sa[unsafe_offset=3])
    if family == Int(AddressFamily.AF_INET.value) and length >= 8:
        var host = String(
            Int(sa[unsafe_offset=4]), ".", Int(sa[unsafe_offset=5]), ".", Int(sa[unsafe_offset=6]), ".", Int(sa[unsafe_offset=7])
        )
        return (host^, port)
    if family == Int(AddressFamily.AF_INET6.value) and length >= 24:
        var bytes = StaticTuple[UInt8, 16](fill=0)
        for i in range(16):
            bytes[i] = sa[unsafe_offset=8 + i]
        var address = InetAddress(bytes)
        if address.is_v4_mapped():
            return (address.mapped_ipv4(), port)
        try:
            return (inet_ntop[AddressFamily.AF_INET6](address), port)
        except:
            return (String(""), port)
    return (String(""), 0)


struct SocketAddress(Movable):
    """A socket address, in storage any family's fits: what `bind` is
    given and what `getsockname` and `getpeername` fill.

    It used to be one 16-byte `sockaddr`, which an IPv6 address (28 bytes)
    does not fit: the kernel truncated one it filled before its address
    (review R15). `length` is how much of the storage the address takes --
    16 for IPv4, 28 for IPv6, what the kernel said for one it filled.
    """

    comptime CAPACITY = socklen_t(SOCKADDR_STORAGE_SIZE)
    """The storage's size, what a call the kernel fills is told."""
    var addr: ExternalMutPointer[sockaddr]
    """Pointer to the storage, as the `sockaddr` the calls take."""
    var length: socklen_t
    """How many bytes of the storage the address takes."""

    def __init__(out self):
        """Zeroed storage for the kernel to fill."""
        var storage = unsafe_alloc[UInt8](count=SOCKADDR_STORAGE_SIZE)
        for i in range(SOCKADDR_STORAGE_SIZE):
            storage[unsafe_offset=i] = 0
        self.addr = storage.unsafe_bitcast[sockaddr]()
        self.length = Self.CAPACITY

    def __init__(out self, address_family: AddressFamily, port: UInt16, binary_ip: UInt32):
        """An IPv4 address.

        Args:
            address_family: The address family.
            port: A 16-bit integer port in host byte order, gets converted to network byte order via `htons`.
            binary_ip: The binary representation of the IP address.
        """
        self = Self()
        self.addr.unsafe_bitcast[sockaddr_in]().unsafe_write(
            sockaddr_in(
                address_family=Int(address_family.value),
                port=port,
                binary_ip=binary_ip,
            )
        )
        self.length = socklen_t(size_of[sockaddr_in]())

    def __init__(out self, address_family: AddressFamily, port: UInt16, address: InetAddress):
        """An address of either family, from what `inet_pton` wrote.

        An IPv6 one is a `sockaddr_in6`, written byte by byte: its first two
        bytes are `[sin6_len][sin6_family]` on macOS and `sin6_family` as a
        u16 on Linux, and macOS's `bind` refuses one whose family byte is
        not `AF_INET6`. Port and address sit at the same offsets on both.

        Args:
            address_family: `AF_INET` or `AF_INET6`.
            port: The port, in host byte order.
            address: The address, as `inet_pton` wrote it.
        """
        if address_family != AddressFamily.AF_INET6:
            self = Self(address_family, port, address.in_addr())
            return
        self = Self()
        var sa = self.addr.unsafe_bitcast[UInt8]()
        comptime if _IS_MACOS:
            sa[unsafe_offset=0] = UInt8(SOCKADDR_IN6_SIZE)
            sa[unsafe_offset=1] = UInt8(AddressFamily.AF_INET6.value)
        else:
            sa[unsafe_offset=0] = UInt8(AddressFamily.AF_INET6.value)
            sa[unsafe_offset=1] = 0
        sa[unsafe_offset=2] = UInt8((Int(port) >> 8) & 0xFF)
        sa[unsafe_offset=3] = UInt8(Int(port) & 0xFF)
        # Bytes 4-7, `sin6_flowinfo`, and 24-27, `sin6_scope_id`, stay 0.
        for i in range(16):
            sa[unsafe_offset=8 + i] = address.bytes[i]
        self.length = socklen_t(SOCKADDR_IN6_SIZE)

    def __deinit__(deinit self):
        if Int(self.addr) != 0:
            self.addr.unsafe_free()

    def unsafe_ptr[
        origin: Origin, address_space: AddressSpace, //
    ](ref [origin, address_space]self) -> Pointer[sockaddr, origin, address_space=address_space]:
        return self.addr.unsafe_mut_cast[origin.mut]().unsafe_origin_cast[origin]().unsafe_address_space_cast[address_space]()

    def as_sockaddr_in(mut self) -> ref [origin_of(self)] sockaddr_in:
        return self.unsafe_ptr().unsafe_bitcast[sockaddr_in]()[]

    def family(self) -> Int:
        """The address family the address carries."""
        return sockaddr_family(self.addr.unsafe_bitcast[UInt8]())

    def host_port(self) -> Tuple[String, Int]:
        """The host and port, as `sockaddr_host_port` reads them."""
        return sockaddr_host_port(
            self.addr.unsafe_bitcast[UInt8](), Int(self.length)
        )


def _inet_ntop(
    af: c_int,
    src: Pointer[c_void, _],
    dst: Pointer[c_char, _],
    size: socklen_t,
) raises -> ExternalImmutPointer[c_char]:
    """Libc POSIX `inet_ntop` function.

    Args:
        af: Address Family see AF_ aliases.
        src: A Pointer to a binary address.
        dst: A Pointer to a buffer to store the result.
        size: The size of the buffer.

    Returns:
        A Pointer to the buffer containing the result.

    #### C Function
    ```c
    const char *inet_ntop(int af, const void *restrict src, char *restrict dst, socklen_t size)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/inet_ntop.3p.html .
    """
    return external_call[
        "inet_ntop",
        ExternalImmutPointer[c_char],  # FnName, RetType
        type_of(af),
        type_of(src),
        type_of(dst),
        type_of(size),  # Args
    ](af, src, dst, size)


def inet_ntop[address_family: AddressFamily](address: InetAddress) raises InetNtopError -> String:
    """Libc POSIX `inet_ntop` function.

    It took the address as a `UInt32`, so an IPv6 one reached C as four
    bytes and twelve more of whatever the stack held (review R15).

    Parameters:
        address_family: `AF_INET` or `AF_INET6`.

    Args:
        address: The address, as `inet_pton` writes it.

    Returns:
        The IP Address in the human readable format.

    Raises:
        InetNtopError: If an error occurs while converting the address.
        EAFNOSUPPORT: `*src` was not an `AF_INET` or `AF_INET6` family address.
        ENOSPC: The buffer size, `size`, was not large enough to store the presentation form of the address.

    #### C Function
    ```c
    const char *inet_ntop(int af, const void *restrict src, char *restrict dst, socklen_t size)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/inet_ntop.3p.html.
    """
    var src = address.bytes
    var dst = List[Byte](length=AddressLength.INET6_ADDRSTRLEN.value + 1, fill=0)

    var result = _inet_ntop(
        address_family.value,
        Pointer(to=src).unsafe_bitcast[c_void](),
        dst.unsafe_ptr().unsafe_bitcast[c_char](),
        UInt32(AddressLength.INET6_ADDRSTRLEN.value),
    )
    _ = src
    if Int(result) == 0:
        var errno = get_errno()
        if errno == errno.EAFNOSUPPORT:
            raise InetNtopEAFNOSUPPORTError()
        elif errno == errno.ENOSPC:
            raise InetNtopENOSPCError()
        else:
            raise Error(
                "inet_ntop Error: An error occurred while converting the address. Error code: ",
                errno,
            )

    return String(unsafe_from_utf8_ptr=dst.unsafe_ptr())


def _inet_pton(af: c_int, src: Pointer[c_char, _], dst: Pointer[c_void, _]) -> c_int:
    """Libc POSIX `inet_pton` function. Converts a presentation format address (that is, printable form as held in a character string)
    to network format (usually a struct in_addr or some other internal binary representation, in network byte order).
    It returns 1 if the address was valid for the specified address family, or 0 if the address was not parseable in the specified address family,
    or -1 if some system error occurred (in which case errno will have been set).

    Args:
        af: Address Family: `AF_INET` or `AF_INET6`.
        src: A Pointer to a string containing the address.
        dst: A Pointer to a buffer to store the result.

    Returns:
        1 on success, 0 if the input is not a valid address, -1 on error.

    #### C Function
    ```c
    int inet_pton(int af, const char *restrict src, void *restrict dst)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/inet_ntop.3p.html .
    """
    return external_call[
        "inet_pton",
        c_int,
        type_of(af),
        type_of(src),
        type_of(dst),
    ](af, src, dst)


def inet_pton[address_family: AddressFamily](var src: String) raises InetPtonError -> InetAddress:
    """Libc POSIX `inet_pton` function. Converts a presentation format address (that is, printable form as held in a character string)
    to network format (usually a struct in_addr or some other internal binary representation, in network byte order).

    Parameters:
        address_family: Address Family: `AF_INET` or `AF_INET6`.

    Args:
        src: A Pointer to a string containing the address.

    Returns:
        The address, network byte order: four bytes for `AF_INET`, sixteen
        for `AF_INET6`.

    Raises:
        InetPtonError: If an error occurs while converting the address or the input is not a valid address.

    #### C Function
    ```c
    int inet_pton(int af, const char *restrict src, void *restrict dst)
    ```

    #### Notes:
    * Reference: https://man7.org/linux/man-pages/man3/inet_ntop.3p.html .
    * This function is valid for `AF_INET` and `AF_INET6`.
    """
    var ip_buffer: ExternalMutPointer[c_void]

    # Counted in bytes: `c_void` is `NoneType`, whose size is 0, so
    # `stack_allocation[4, c_void]` reserved nothing and `inet_pton` wrote
    # the address over whatever the stack held beside it -- a String the
    # caller was building, found crashing `ListenConfig.listen` (review B27b).
    comptime if address_family == AddressFamily.AF_INET6:
        ip_buffer = stack_allocation[16, UInt8]().unsafe_bitcast[c_void]()
    else:
        ip_buffer = stack_allocation[4, UInt8]().unsafe_bitcast[c_void]()

    var result = _inet_pton(address_family.value, src.as_c_string_span().ptr(), ip_buffer)
    if result == 0:
        raise InetPtonInvalidAddressError()
    elif result == -1:
        var errno = get_errno()
        raise Error(
            "inet_pton Error: An error occurred while converting the address. Error code: ",
            errno,
        )

    # Every byte the call wrote. Read back as one `c_uint`, as upstream
    # did, an IPv6 address kept four of its sixteen (review R15).
    var written = ip_buffer.unsafe_bitcast[UInt8]()
    var bytes = StaticTuple[UInt8, 16](fill=0)
    comptime if address_family == AddressFamily.AF_INET6:
        for i in range(16):
            bytes[i] = written[unsafe_offset=i]
    else:
        for i in range(4):
            bytes[i] = written[unsafe_offset=i]
    return InetAddress(bytes)
