from std.ffi import c_uchar

from lightbug_http.c.address import AddressFamily
from lightbug_http.c.aliases import c_void
from lightbug_http.c.network import InetPtonError, ntohs
from lightbug_http.c.socket import socket
from lightbug_http.socket import Socket
from lightbug_http.utils.error import CustomError
from std.utils import Variant


comptime MAX_PORT = 65535
comptime MIN_PORT = 0
comptime DEFAULT_IP_PORT = UInt16(0)


struct AddressConstants:
    """Constants used in address parsing."""

    comptime LOCALHOST = "localhost"
    comptime IPV4_LOCALHOST = "127.0.0.1"
    comptime IPV6_LOCALHOST = "::1"
    comptime EMPTY = ""


trait Addr(
    Copyable,
    Defaultable,
    Equatable,
    ImplicitlyCopyable,
    Deinitable,
    Writable,
):
    comptime _type: StaticString

    def __init__(out self, ip: String, port: UInt16):
        ...

    @always_inline
    def address_family(self) -> Int:
        ...

    @always_inline
    def is_v4(self) -> Bool:
        ...

    @always_inline
    def is_v6(self) -> Bool:
        ...

    @always_inline
    def is_unix(self) -> Bool:
        ...


@fieldwise_init
struct NetworkType(Equatable, ImplicitlyCopyable):
    var value: UInt8

    comptime empty = Self(0)
    comptime tcp = Self(1)
    """TCP in the family the address names, as Go's "tcp" is: a listener
    on `::` or `::1` is IPv6 -- `::` dual-stack, taking IPv4 too -- and one
    on `0.0.0.0` IPv4 (review R15). `tcp4` and `tcp6` are one family
    only."""
    comptime tcp4 = Self(2)
    comptime tcp6 = Self(3)
    comptime udp = Self(4)
    comptime ip = Self(7)
    comptime ip4 = Self(8)
    comptime ip6 = Self(9)
    comptime unix = Self(10)

    def __eq__(self, other: NetworkType) -> Bool:
        return self.value == other.value

    def is_ip_protocol(self) -> Bool:
        """Check if the network type is an IP protocol."""
        return self in (NetworkType.ip, NetworkType.ip4, NetworkType.ip6)

    def is_ipv4(self) -> Bool:
        """Check if the network type is IPv4."""
        return self in (NetworkType.tcp4, NetworkType.ip4)

    def is_ipv6(self) -> Bool:
        """Check if the network type is IPv6."""
        return self in (NetworkType.tcp6, NetworkType.ip6)


# @fieldwise_init
struct TCPAddr[network: NetworkType = NetworkType.tcp4](Addr, ImplicitlyCopyable):
    comptime _type = "TCPAddr"
    var ip: String
    var port: UInt16
    var zone: String  # IPv6 addressing zone

    def __init__(out self):
        self.ip = "127.0.0.1"
        self.port = 8000
        self.zone = ""

    def __init__(out self, ip: String = "127.0.0.1", port: UInt16 = 8000):
        self.ip = ip
        self.port = port
        self.zone = ""

    def __init__(out self, ip: String, port: UInt16, zone: String):
        self.ip = ip
        self.port = port
        self.zone = zone

    @always_inline
    def address_family(self) -> Int:
        if self.is_v4():
            return Int(AddressFamily.AF_INET.value)
        elif self.is_v6():
            return Int(AddressFamily.AF_INET6.value)
        else:
            return Int(AddressFamily.AF_UNSPEC.value)

    @always_inline
    def is_v4(self) -> Bool:
        comptime if Self.network == NetworkType.tcp:
            return not is_ipv6_literal(self.ip)
        return Self.network == NetworkType.tcp4

    @always_inline
    def is_v6(self) -> Bool:
        comptime if Self.network == NetworkType.tcp:
            return is_ipv6_literal(self.ip)
        return Self.network == NetworkType.tcp6

    @always_inline
    def is_unix(self) -> Bool:
        return False

    def __eq__(self, other: Self) -> Bool:
        return self.ip == other.ip and self.port == other.port and self.zone == other.zone

    def __ne__(self, other: Self) -> Bool:
        return not self == other

    def __str__(self) -> String:
        if self.zone != "":
            return join_host_port(self.ip + "%" + self.zone, String(self.port))
        return join_host_port(self.ip, String(self.port))

    def __repr__(self) -> String:
        return String(self)

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(
            "TCPAddr(",
            "ip=",
            repr(self.ip),
            ", port=",
            String(self.port),
            ", zone=",
            repr(self.zone),
            ")",
        )


@fieldwise_init
struct ParseEmptyAddressError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse address: received empty address string."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseMissingClosingBracketError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse ipv6 address: missing ']'"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseMissingPortError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse ipv6 address: missing port in address"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseUnexpectedBracketError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Address failed bracket validation, unexpectedly contained brackets"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseEmptyPortError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse port: port string is empty."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseInvalidPortNumberError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse port: invalid integer value."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParsePortOutOfRangeError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse port: Port number out of range (0-65535)."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseMissingSeparatorError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse address: missing port separator ':' in address."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseTooManyColonsError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse address: too many colons in address"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message


@fieldwise_init
struct ParseIPProtocolPortError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: IP protocol addresses should not include ports"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)

    def __str__(self) -> String:
        return Self.message




@fieldwise_init
struct ParseError(Movable, Writable):
    """Typed error variant for address parsing functions."""

    comptime type = Variant[
        ParseEmptyAddressError,
        ParseMissingClosingBracketError,
        ParseMissingPortError,
        ParseUnexpectedBracketError,
        ParseEmptyPortError,
        ParseInvalidPortNumberError,
        ParsePortOutOfRangeError,
        ParseMissingSeparatorError,
        ParseTooManyColonsError,
        ParseIPProtocolPortError,
    ]
    var value: Self.type

    @implicit
    def __init__(out self, value: ParseEmptyAddressError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseMissingClosingBracketError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseMissingPortError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseUnexpectedBracketError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseEmptyPortError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseInvalidPortNumberError):
        self.value = value

    @implicit
    def __init__(out self, value: ParsePortOutOfRangeError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseMissingSeparatorError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseTooManyColonsError):
        self.value = value

    @implicit
    def __init__(out self, value: ParseIPProtocolPortError):
        self.value = value

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[ParseEmptyAddressError]():
            writer.write(self.value[ParseEmptyAddressError])
        elif self.value.isa[ParseMissingClosingBracketError]():
            writer.write(self.value[ParseMissingClosingBracketError])
        elif self.value.isa[ParseMissingPortError]():
            writer.write(self.value[ParseMissingPortError])
        elif self.value.isa[ParseUnexpectedBracketError]():
            writer.write(self.value[ParseUnexpectedBracketError])
        elif self.value.isa[ParseEmptyPortError]():
            writer.write(self.value[ParseEmptyPortError])
        elif self.value.isa[ParseInvalidPortNumberError]():
            writer.write(self.value[ParseInvalidPortNumberError])
        elif self.value.isa[ParsePortOutOfRangeError]():
            writer.write(self.value[ParsePortOutOfRangeError])
        elif self.value.isa[ParseMissingSeparatorError]():
            writer.write(self.value[ParseMissingSeparatorError])
        elif self.value.isa[ParseTooManyColonsError]():
            writer.write(self.value[ParseTooManyColonsError])
        elif self.value.isa[ParseIPProtocolPortError]():
            writer.write(self.value[ParseIPProtocolPortError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


def parse_ipv6_bracketed_address[
    origin: ImmOrigin
](address: StringSpan[origin]) raises ParseError -> Tuple[StringSpan[origin], UInt16]:
    """Parse an IPv6 address enclosed in brackets.

    Returns:
        Tuple of (host, colon_index_offset).
    """
    if address.byte_length() == 0 or address.as_bytes()[0] != UInt8(ord("[")):
        return address, UInt16(0)

    var end_bracket_index = address.find("]")
    if end_bracket_index == -1:
        raise ParseMissingClosingBracketError()

    if end_bracket_index + 1 == address.byte_length():
        raise ParseMissingPortError()

    var colon_index = end_bracket_index + 1
    if address.as_bytes()[colon_index] != UInt8(ord(":")):
        raise ParseMissingPortError()

    return address[byte=1:end_bracket_index], UInt16(end_bracket_index + 1)


def validate_no_brackets[
    origin: ImmOrigin
](address: StringSpan[origin], start_idx: UInt16, end_idx: Optional[UInt16] = None,) raises ParseError:
    """Validate that the address segment contains no brackets."""
    var segment: StringSpan[origin]

    if end_idx is None:
        segment = address[byte=Int(start_idx) :]
    else:
        segment = address[byte=Int(start_idx) : Int(end_idx.value())]

    if segment.find("[") != -1:
        raise ParseUnexpectedBracketError()
    if segment.find("]") != -1:
        raise ParseUnexpectedBracketError()


def parse_port[origin: ImmOrigin](port_str: StringSpan[origin]) raises ParseError -> UInt16:
    """Parse and validate port number."""
    if port_str == AddressConstants.EMPTY:
        raise ParseEmptyPortError()

    var port: Int
    try:
        port = Int(String(port_str))
    except conversion_err:
        raise ParseInvalidPortNumberError()

    if port < MIN_PORT or port > MAX_PORT:
        raise ParsePortOutOfRangeError()

    return UInt16(port)


@fieldwise_init
struct HostPort(Movable):
    var host: String
    var port: UInt16


def parse_address[
    origin: ImmOrigin,
    //,
    network: NetworkType,
](address: StringSpan[origin]) raises ParseError -> HostPort:
    """Parse an address string into a host and port.

    Parameters:
        origin: The origin of the address string.
        network: The network type.

    Args:
        address: The address string.

    Returns:
        Tuple containing the host and port.
    """
    if address == AddressConstants.EMPTY:
        raise ParseEmptyAddressError()

    if address == AddressConstants.LOCALHOST:

        comptime if network.is_ipv6():
            return HostPort(AddressConstants.IPV6_LOCALHOST, DEFAULT_IP_PORT)
        else:
            # `tcp` too: `localhost` is the IPv4 loopback, as it always was.
            return HostPort(AddressConstants.IPV4_LOCALHOST, DEFAULT_IP_PORT)

    comptime if network.is_ip_protocol():
        if network == NetworkType.ip6 and address.find(":") != -1:
            return HostPort(String(address), DEFAULT_IP_PORT)

        if address.find(":") != -1:
            raise ParseIPProtocolPortError()

        return HostPort(String(address), DEFAULT_IP_PORT)

    var colon_index = address.rfind(":")
    if colon_index == -1:
        raise ParseMissingSeparatorError()

    var host: StringSpan[origin]
    var port: UInt16

    # TODO (Mikhail): StringSpan does byte level slicing, so this can be
    # invalid for multi-byte UTF-8 characters. Perhaps we instead assert that it's
    # an ascii string instead.
    if address.byte_length() > 0 and address.as_bytes()[0] == UInt8(ord("[")):
        var bracket_offset: UInt16
        (host, bracket_offset) = parse_ipv6_bracketed_address(address)
        validate_no_brackets(address, bracket_offset)
    else:
        host = address[byte=:colon_index]
        if host.find(":") != -1:
            raise ParseTooManyColonsError()

    port = parse_port(address[byte=colon_index + 1 :])
    if host == AddressConstants.LOCALHOST:

        comptime if network.is_ipv6():
            return HostPort(AddressConstants.IPV6_LOCALHOST, port)
        else:
            return HostPort(AddressConstants.IPV4_LOCALHOST, port)

    return HostPort(String(host), port)


def is_ipv6_literal(host: StringSpan) -> Bool:
    """Whether `host` is an IPv6 address rather than an IPv4 one or a name:
    only an IPv6 literal carries a `:`."""
    return host.find(":") != -1


def join_host_port(host: String, port: String) -> String:
    """`host:port`, an IPv6 literal bracketed (`[::1]:8080`), as a URL and
    `parse_address` both need it."""
    if is_ipv6_literal(host):
        return String("[", host, "]:", port)
    return String(host, ":", port)


def binary_port_to_int(port: UInt16) -> Int:
    """Convert a binary port to an integer.

    Args:
        port: The binary port.

    Returns:
        The port as an integer.
    """
    return Int(ntohs(port))
