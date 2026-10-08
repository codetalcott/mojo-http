from lightbug_http.utils.error import CustomError
from std.utils import Variant


comptime MAX_PORT = 65535
comptime MIN_PORT = 0


struct AddressConstants:
    """Constants used in address parsing."""

    comptime LOCALHOST = "localhost"
    comptime IPV4_LOCALHOST = "127.0.0.1"
    comptime IPV6_LOCALHOST = "::1"
    comptime EMPTY = ""


trait Addr(
    Copyable,
    Defaultable,
    ImplicitlyCopyable,
    Deinitable,
):
    """What `Socket` needs of its address type: a placeholder before `bind`
    (`Defaultable`) and one built from what the kernel names (`ip`, `port`)."""

    def __init__(out self, ip: String, port: UInt16):
        ...


@fieldwise_init
struct NetworkType(Equatable, ImplicitlyCopyable):
    var value: UInt8

    comptime tcp = Self(1)
    """TCP in the family the address names, as Go's "tcp" is: a listener
    on `::` or `::1` is IPv6 -- `::` dual-stack, taking IPv4 too -- and one
    on `0.0.0.0` IPv4 (review R15). `tcp4` and `tcp6` are one family
    only."""
    comptime tcp4 = Self(2)
    comptime tcp6 = Self(3)

    def __eq__(self, other: NetworkType) -> Bool:
        return self.value == other.value

    def is_ipv6(self) -> Bool:
        """Check if the network type is IPv6."""
        return self == NetworkType.tcp6


struct TCPAddr[network: NetworkType = NetworkType.tcp4](Addr, ImplicitlyCopyable):
    var ip: String
    var port: UInt16

    def __init__(out self):
        self.ip = "127.0.0.1"
        self.port = 8000

    def __init__(out self, ip: String = "127.0.0.1", port: UInt16 = 8000):
        self.ip = ip
        self.port = port


@fieldwise_init
struct ParseEmptyAddressError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse address: received empty address string."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParseMissingClosingBracketError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse ipv6 address: missing ']'"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParseMissingPortError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse ipv6 address: missing port in address"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParseUnexpectedBracketError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Address failed bracket validation, unexpectedly contained brackets"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParseEmptyPortError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse port: port string is empty."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParseInvalidPortNumberError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse port: invalid integer value."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParsePortOutOfRangeError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse port: Port number out of range (0-65535)."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParseMissingSeparatorError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse address: missing port separator ':' in address."

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


@fieldwise_init
struct ParseTooManyColonsError(CustomError, TrivialRegisterPassable):
    comptime message = "ParseError: Failed to parse address: too many colons in address"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(Self.message)


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

    return (
        StringSpan(unsafe_from_utf8=address.as_bytes()[1:end_bracket_index]),
        UInt16(end_bracket_index + 1),
    )


def validate_no_brackets[
    origin: ImmOrigin
](address: StringSpan[origin], start_idx: UInt16) raises ParseError:
    """Validate that the address from `start_idx` on contains no brackets."""
    var segment = StringSpan(unsafe_from_utf8=address.as_bytes()[Int(start_idx) :])

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

    # An address names its port, `localhost` as much as `127.0.0.1`: read
    # as the loopback at port 0, `localhost` alone listened on a port the
    # kernel chose (review record LF45).
    var colon_index = address.rfind(":")
    if colon_index == -1:
        raise ParseMissingSeparatorError()

    var host: StringSpan[origin]
    var port: UInt16

    # Every slice below is cut beside a `[`, `]` or `:`, and an ASCII byte
    # is never inside a multi-byte UTF-8 sequence, so each is whole text.
    # Sliced as bytes all the same: the fork holds no `[byte=a:b]` slice.
    if address.byte_length() > 0 and address.as_bytes()[0] == UInt8(ord("[")):
        var bracket_offset: UInt16
        (host, bracket_offset) = parse_ipv6_bracketed_address(address)
        validate_no_brackets(address, bracket_offset)
        # The port follows the colon after `]`, so that colon must be the
        # last: `[::1]:8:0` read port 0 from after the last colon, and
        # listened on a port the kernel chose (review record LF33).
        if Int(bracket_offset) != colon_index:
            raise ParseTooManyColonsError()
    else:
        host = StringSpan(unsafe_from_utf8=address.as_bytes()[:colon_index])
        if host.find(":") != -1:
            raise ParseTooManyColonsError()

    port = parse_port(
        StringSpan(unsafe_from_utf8=address.as_bytes()[colon_index + 1 :])
    )
    if host == AddressConstants.LOCALHOST:

        comptime if network.is_ipv6():
            return HostPort(AddressConstants.IPV6_LOCALHOST, port)
        else:
            # `tcp` too: `localhost` is the IPv4 loopback, as it always was.
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

