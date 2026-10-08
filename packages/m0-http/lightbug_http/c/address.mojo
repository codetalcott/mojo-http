from std.ffi import c_int
from std.sys.info import CompilationTarget


# AF_UNSPEC and AF_INET are 0 and 2 everywhere. AF_INET6 is not: upstream
# took 24 from OpenBSD's <sys/socket.h>, which on macOS names no family at
# all (socket() refused it, EAFNOSUPPORT) and on Linux is AF_PPPOX, so no
# IPv6 socket could be made. 30 is the macOS SDK's value and 10 Linux's
# (review R15); `test_ipv6.mojo` asks the kernel which family a socket made
# with it reports.
@fieldwise_init
struct AddressFamily(Copyable, Equatable, Writable, TrivialRegisterPassable):
    var value: c_int
    comptime AF_UNSPEC = Self(0)
    comptime AF_INET = Self(2)
    comptime AF_INET6 = Self(c_int(30 if CompilationTarget.is_macos() else 10))

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to[W: Writer, //](self, mut writer: W):
        # TODO: Only writing the important AF for now.
        if self == Self.AF_UNSPEC:
            writer.write("AF_UNSPEC")
        elif self == Self.AF_INET:
            writer.write("AF_INET")
        elif self == Self.AF_INET6:
            writer.write("AF_INET6")
        else:
            writer.write("AddressFamily(", self.value, ")")

    def __str__(self) -> String:
        return String(self)

    @always_inline("nodebug")
    def is_inet(self) -> Bool:
        return self == Self.AF_INET or self == Self.AF_INET6


@fieldwise_init
struct AddressLength(Copyable, Equatable, Writable, TrivialRegisterPassable):
    var value: Int
    comptime INET_ADDRSTRLEN = Self(16)
    comptime INET6_ADDRSTRLEN = Self(46)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to[W: Writer, //](self, mut writer: W):
        var value: StaticString
        if self == Self.INET_ADDRSTRLEN:
            value = "INET_ADDRSTRLEN"
        else:
            value = "INET6_ADDRSTRLEN"
        writer.write(value)

    def __str__(self) -> String:
        return String(self)
