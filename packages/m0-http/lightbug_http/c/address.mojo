from std.ffi import c_int
from std.sys.info import CompilationTarget


# AF_UNSPEC and AF_INET are 0 and 2 everywhere. AF_INET6 is not: upstream
# took 24 from OpenBSD's <sys/socket.h>, which on macOS names no family at
# all (socket() refused it, EAFNOSUPPORT) and on Linux is AF_PPPOX, so no
# IPv6 socket could be made. 30 is the macOS SDK's value and 10 Linux's
# (review R15); `test_ipv6.mojo` asks the kernel which family a socket made
# with it reports.
@fieldwise_init
struct AddressFamily(Copyable, Equatable, TrivialRegisterPassable):
    var value: c_int
    comptime AF_UNSPEC = Self(0)
    comptime AF_INET = Self(2)
    comptime AF_INET6 = Self(c_int(30 if CompilationTarget.is_macos() else 10))

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value


@fieldwise_init
struct AddressLength(Copyable, TrivialRegisterPassable):
    """The room `inet_ntop` needs for an address's text, its NUL included
    (<netinet/in.h>, the same on macOS and Linux)."""

    var value: Int
    comptime INET6_ADDRSTRLEN = Self(46)
