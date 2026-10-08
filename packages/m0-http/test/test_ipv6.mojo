"""The fork listens on IPv6 (review R15).

It could not, four ways over. `AF_INET6` was OpenBSD's number (24), which
the kernel refuses on macOS (30) and reads as another family on Linux (10).
`inet_pton` read back four bytes of the sixteen an IPv6 address has. A
`SocketAddress` was one 16-byte `sockaddr`, which a `sockaddr_in6` (28
bytes) does not fit. And every listener was IPv4 whatever its address.

The listener's family is now the address's: `[::]` is IPv6 taking IPv4
too, set explicitly because the system default differs by host, `[::1]` the
IPv6 loopback alone, and anything else IPv4 as before. An IPv4 client of a
dual-stack listener is reported as IPv4 (`127.0.0.1`, not
`::ffff:127.0.0.1`), so moving a server from `0.0.0.0` to `::` changes no
address an application sees.

Each test says which rule it holds; `smoke-ipv6` holds the same rules on
the wire, through m0serve and the Mojo host.
"""

from std.ffi import ErrNo, c_int, external_call, get_errno
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true
from std.utils import StaticTuple

from lightbug_http.address import (
    NetworkType,
    TCPAddr,
    join_host_port,
    parse_address,
)
from lightbug_http.c.address import AddressFamily
from lightbug_http.c.network import (
    InetAddress,
    SocketAddress,
    inet_ntop,
    inet_pton,
    sockaddr_host_port,
)
from lightbug_http.c.pipe import close_fd
from lightbug_http.c.socket import (
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    SocketType,
    accept_with_peer,
    bind,
    getsockname,
    socket,
)
from lightbug_http.connection import ListenConfig
from lightbug_http.socket import Socket
from lightbug_http.uri import URI
from test.loopback import connect


# --- helpers -------------------------------------------------------------------


def _v6only(fd: Int) raises -> Int:
    """`IPV6_V6ONLY` as the kernel holds it for `fd`. The fork binds no
    `getsockopt` (nothing it runs reads an option back), so the test does."""
    var value = c_int(-1)
    var size = c_int(4)
    var rc = external_call["getsockopt", c_int](
        c_int(fd), c_int(IPPROTO_IPV6), c_int(IPV6_V6ONLY),
        Pointer(to=value), Pointer(to=size),
    )
    if rc != 0:
        raise Error("getsockopt(IPV6_V6ONLY) failed, errno ", get_errno())
    return Int(value)


def _set_v6only_raw(fd: Int, on: Bool) raises:
    var value = c_int(1 if on else 0)
    var rc = external_call["setsockopt", c_int](
        c_int(fd), c_int(IPPROTO_IPV6), c_int(IPV6_V6ONLY),
        Pointer(to=value), c_int(4),
    )
    if rc != 0:
        raise Error("setsockopt(IPV6_V6ONLY) failed, errno ", get_errno())


def _port(fd: Int) raises -> Int:
    var address = SocketAddress()
    getsockname(FileDescriptor(fd), address)
    return address.host_port()[1]


def _connect_v4(port: Int) raises -> Int:
    """A client connected to 127.0.0.1:`port`; its descriptor."""
    var fd = Int(socket(AddressFamily.AF_INET.value, SocketType.SOCK_STREAM.value, 0))
    var address = SocketAddress(
        AddressFamily.AF_INET, UInt16(port), inet_pton[AddressFamily.AF_INET](String("127.0.0.1"))
    )
    connect(FileDescriptor(fd), address)
    return fd


def _v4_refused(port: Int) raises -> Bool:
    """Whether a connect to 127.0.0.1:`port` is refused (ECONNREFUSED)."""
    var fd = Int(socket(AddressFamily.AF_INET.value, SocketType.SOCK_STREAM.value, 0))
    var address = SocketAddress(
        AddressFamily.AF_INET, UInt16(port), inet_pton[AddressFamily.AF_INET](String("127.0.0.1"))
    )
    try:
        connect(FileDescriptor(fd), address)
    except e:
        close_fd(fd)
        return e.errno == ErrNo.ECONNREFUSED
    close_fd(fd)
    return False


def _connect_v6(port: Int) raises -> Int:
    """A client connected to [::1]:`port`; its descriptor."""
    var fd = Int(socket(AddressFamily.AF_INET6.value, SocketType.SOCK_STREAM.value, 0))
    var address = SocketAddress(
        AddressFamily.AF_INET6, UInt16(port), inet_pton[AddressFamily.AF_INET6](String("::1"))
    )
    connect(FileDescriptor(fd), address)
    return fd


def _sockaddr_in6(address: String, port: Int) raises -> SocketAddress:
    return SocketAddress(
        AddressFamily.AF_INET6, UInt16(port), inet_pton[AddressFamily.AF_INET6](address)
    )


# --- the constant --------------------------------------------------------------


def test_af_inet6_is_the_platforms() raises:
    """`AF_INET6` names the family the kernel makes IPv6 sockets in: a
    socket made with it binds `::1`, and `getsockname` reports the family
    back. Upstream's 24 was refused outright on macOS (EAFNOSUPPORT) and is
    `AF_PPPOX` on Linux."""
    var fd: Int
    try:
        fd = Int(socket(AddressFamily.AF_INET6.value, SocketType.SOCK_STREAM.value, 0))
    except e:
        assert_true(
            False,
            String("socket(AF_INET6 = ", AddressFamily.AF_INET6.value,
                   ") refused, so it is not this platform's IPv6 family: ", e),
        )
        return
    var local = _sockaddr_in6(String("::1"), 0)
    var bound = True
    try:
        bind(FileDescriptor(fd), local)
    except e:
        bound = False
    var name = SocketAddress()
    getsockname(FileDescriptor(fd), name)
    close_fd(fd)
    assert_true(bound, "an AF_INET6 socket did not bind ::1")
    assert_equal(name.family(), Int(AddressFamily.AF_INET6.value), "the kernel's family for the socket")
    assert_equal(Int(name.length), 28, "a sockaddr_in6 is 28 bytes")
    assert_equal(name.host_port()[0], "::1")


# --- inet_pton and the address readers ----------------------------------------


def test_inet_pton_keeps_all_sixteen_bytes() raises:
    """An IPv6 address is sixteen bytes, and all of them come back: read as
    one `c_uint`, only the first four did, and `2001:db8::1` and
    `2001:db8::2` were the same address."""
    var a = inet_pton[AddressFamily.AF_INET6](String("2001:db8::a:b:c:d"))
    var want = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0x0A, 0, 0x0B, 0, 0x0C, 0, 0x0D]
    for i in range(16):
        assert_equal(Int(a.bytes[i]), want[i], String("byte ", i))
    var one = inet_pton[AddressFamily.AF_INET6](String("2001:db8::1"))
    var two = inet_pton[AddressFamily.AF_INET6](String("2001:db8::2"))
    assert_equal(Int(one.bytes[15]), 1)
    assert_equal(Int(two.bytes[15]), 2)
    assert_equal(inet_ntop[AddressFamily.AF_INET6](a), "2001:db8::a:b:c:d")
    assert_equal(inet_ntop[AddressFamily.AF_INET6](one), "2001:db8::1")
    assert_equal(inet_ntop[AddressFamily.AF_INET6](inet_pton[AddressFamily.AF_INET6](String("::"))), "::")


def test_inet_pton_ipv4_is_unchanged() raises:
    """IPv4 is four bytes, the rest zero, and `in_addr` is what
    `sockaddr_in` holds: the bytes in memory order."""
    var a = inet_pton[AddressFamily.AF_INET](String("192.0.2.7"))
    assert_equal(Int(a.bytes[0]), 192)
    assert_equal(Int(a.bytes[3]), 7)
    for i in range(4, 16):
        assert_equal(Int(a.bytes[i]), 0)
    var raw = a.in_addr()
    assert_equal(Int(raw & 0xFF), 192, "network order, first byte first in memory")
    assert_equal(inet_ntop[AddressFamily.AF_INET](a), "192.0.2.7")
    with assert_raises():
        _ = inet_pton[AddressFamily.AF_INET](String("::1"))


def test_a_v4_mapped_peer_reads_as_ipv4() raises:
    """A dual-stack listener's IPv4 client arrives as `::ffff:a.b.c.d` and
    is reported as `a.b.c.d`, as a `0.0.0.0` listener reports it. A real
    IPv6 peer is reported as `inet_ntop` writes it."""
    var mapped = _sockaddr_in6(String("::ffff:10.1.2.3"), 4321)
    var got = mapped.host_port()
    assert_equal(got[0], "10.1.2.3")
    assert_equal(got[1], 4321)
    var real = _sockaddr_in6(String("2001:db8::1"), 80)
    assert_equal(real.host_port()[0], "2001:db8::1")
    # Only ::ffff:0:0/96 is mapped: ::1.2.3.4, the deprecated IPv4-
    # compatible form, is IPv6 (each libc spells it its own way).
    assert_true(_sockaddr_in6(String("::1.2.3.4"), 1).host_port()[0] != "1.2.3.4")
    var v4 = SocketAddress(
        AddressFamily.AF_INET, UInt16(2002), inet_pton[AddressFamily.AF_INET](String("10.0.0.2"))
    )
    got = v4.host_port()
    assert_equal(got[0], "10.0.0.2")
    assert_equal(got[1], 2002)
    # Truncated: nothing is guessed.
    got = sockaddr_host_port(real.addr.unsafe_bitcast[UInt8](), 20)
    # `real` owns the storage the call read through: without a use after
    # it, it could be freed as soon as its pointer was taken.
    _ = real^
    assert_equal(got[0], "")
    assert_equal(got[1], 0)


# --- parsing an address ---------------------------------------------------------


def test_bracketed_addresses_parse() raises:
    """An IPv6 listen address is bracketed, as in a URL; `localhost` keeps
    its meaning, the IPv4 loopback; an unbracketed IPv6 address with a port
    is ambiguous and refused."""
    var hp = parse_address[NetworkType.tcp](StringSpan("[::1]:8080"))
    assert_equal(hp.host, "::1")
    assert_equal(Int(hp.port), 8080)
    hp = parse_address[NetworkType.tcp](StringSpan("[::]:0"))
    assert_equal(hp.host, "::")
    hp = parse_address[NetworkType.tcp](StringSpan("localhost:80"))
    assert_equal(hp.host, "127.0.0.1")
    hp = parse_address[NetworkType.tcp](StringSpan("0.0.0.0:80"))
    assert_equal(hp.host, "0.0.0.0")
    with assert_raises():
        _ = parse_address[NetworkType.tcp](StringSpan("::1:80"))
    with assert_raises():
        _ = parse_address[NetworkType.tcp](StringSpan("[::1]"))
    assert_equal(join_host_port("::", "8080"), "[::]:8080")
    assert_equal(join_host_port("0.0.0.0", "8080"), "0.0.0.0:8080")


def test_a_colon_inside_a_bracketed_address_port_is_refused() raises:
    """After `]` comes one colon and the port: `[::1]:8:0` is refused, not
    read as port 0 (review record LF33).

    The port was the text after the LAST colon, wherever the bracket
    closed, so `[::1]:8:0` listened on `::1` at a port the kernel picked,
    and `[::1]:8:80` on port 80. A port is now the text after the colon
    that follows `]`, and a colon in it is too many.

    covers: A31
    """
    with assert_raises(contains="too many colons"):
        _ = parse_address[NetworkType.tcp](StringSpan("[::1]:8:0"))
    with assert_raises(contains="too many colons"):
        _ = parse_address[NetworkType.tcp](StringSpan("[::1]:8:80"))
    with assert_raises(contains="too many colons"):
        _ = parse_address[NetworkType.tcp6](StringSpan("[::]::80"))
    var hp = parse_address[NetworkType.tcp](StringSpan("[::1]:80"))
    assert_equal(hp.host, "::1")
    assert_equal(Int(hp.port), 80)


def test_a_uri_behind_an_ipv6_server_address_parses() raises:
    """The loop put the server's own address in front of a target that
    carried a query, so on `::` every such request was `[::]:8080/x?a=1`,
    and the port's colon was taken from inside the brackets: 400. It
    splits the address with this parser once now (`split_server_address`,
    review record LF54), which holds the bracketed form the same way."""
    var u = URI.parse(String("[::]:8080/x?a=1"))
    assert_equal(u.path, "/x")
    assert_equal(u.query_string, "a=1")
    assert_equal(u.host, "[::]")
    assert_true(Bool(u.port))
    assert_equal(Int(u.port.value()), 8080)
    u = URI.parse(String("http://[2001:db8::1]/p"))
    assert_equal(u.host, "[2001:db8::1]")
    assert_false(Bool(u.port))
    u = URI.parse(String("0.0.0.0:8080/x?a=1"))
    assert_equal(u.host, "0.0.0.0")
    assert_equal(u.path, "/x")
    with assert_raises():
        _ = URI.parse(String("[::1:8080/x?a=1"))


# --- listeners --------------------------------------------------------------------


def test_a_dual_stack_listener_answers_both_families() raises:
    """`[::]` takes IPv6 and IPv4, with `IPV6_V6ONLY` set to 0, and reports
    each client in its own family: `::1`, and `127.0.0.1` for the IPv4 one."""
    var listener = ListenConfig(max_bind_retries=1, quiet=True).listen("[::]:0")
    var lfd = Int(listener.socket.fd.value)
    assert_equal(Int(listener.socket.family.value), Int(AddressFamily.AF_INET6.value))
    assert_equal(_v6only(lfd), 0, "a :: listener must take IPv4 too")
    var named = listener.socket.get_sock_name()
    assert_equal(named[0], "::")
    var port = Int(named[1])
    assert_true(port > 0)

    var c4 = _connect_v4(port)
    var a4 = accept_with_peer(FileDescriptor(lfd))
    assert_equal(a4[1], "127.0.0.1", "an IPv4 client of :: is reported as IPv4")
    assert_equal(a4[2], _port(c4), "the client's own port")

    var c6 = _connect_v6(port)
    var a6 = accept_with_peer(FileDescriptor(lfd))
    assert_equal(a6[1], "::1")
    assert_equal(a6[2], _port(c6))

    close_fd(c4)
    close_fd(c6)
    close_fd(a4[0].value)
    close_fd(a6[0].value)
    # A use: without one the listener is destroyed, and its socket closed,
    # after its last method call above, before the clients connect.
    _ = listener^


def test_an_ipv6_loopback_listener_refuses_ipv4() raises:
    """`[::1]` answers on `::1` and on nothing IPv4."""
    var listener = ListenConfig(max_bind_retries=1, quiet=True).listen("[::1]:0")
    var lfd = Int(listener.socket.fd.value)
    var port = Int(listener.socket.get_sock_name()[1])
    assert_true(_v4_refused(port), "127.0.0.1 reached a [::1] listener")
    var c6 = _connect_v6(port)
    var a6 = accept_with_peer(FileDescriptor(lfd))
    assert_equal(a6[1], "::1")
    close_fd(c6)
    close_fd(a6[0].value)
    _ = listener^


def test_an_ipv4_listener_is_unchanged() raises:
    """`0.0.0.0` and `127.0.0.1` are IPv4 listeners, as they always were."""
    var listener = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    assert_equal(Int(listener.socket.family.value), Int(AddressFamily.AF_INET.value))
    var named = listener.socket.get_sock_name()
    assert_equal(named[0], "127.0.0.1")
    var c4 = _connect_v4(Int(named[1]))
    var a4 = accept_with_peer(listener.socket.fd)
    assert_equal(a4[1], "127.0.0.1")
    close_fd(c4)
    close_fd(a4[0].value)
    _ = listener^
    var any4 = ListenConfig(max_bind_retries=1, quiet=True).listen("0.0.0.0:0")
    assert_equal(Int(any4.socket.family.value), Int(AddressFamily.AF_INET.value))


def test_dual_stack_is_set_not_inherited() raises:
    """`IPV6_V6ONLY` is set, never left to the host's default, which is a
    system setting on both platforms and is 0 on this runner's. Two arms,
    since on such a host a listener that set nothing still serves both
    families: an `AF_INET6` socket already set to IPv6-only, as a host
    configured that way makes one, is turned back to dual-stack by the call
    the listener makes; and a `tcp6` listener, which asks for IPv6 alone,
    gets it, which only a listener that makes the call can."""
    var fd = Int(socket(AddressFamily.AF_INET6.value, SocketType.SOCK_STREAM.value, 0))
    _set_v6only_raw(fd, True)
    assert_equal(_v6only(fd), 1)
    var sock = Socket[TCPAddr[NetworkType.tcp]](
        fd=FileDescriptor(fd),
        local_address=TCPAddr[NetworkType.tcp](ip="::", port=0),
        family=AddressFamily.AF_INET6,
    )
    sock.set_ipv6_only(False)
    assert_equal(_v6only(fd), 0, "set_ipv6_only(False) left a v6-only socket v6-only")
    sock.close()

    var v6 = ListenConfig(max_bind_retries=1, quiet=True).listen[NetworkType.tcp6]("[::]:0")
    assert_equal(_v6only(Int(v6.socket.fd.value)), 1, "a tcp6 listener must be IPv6-only")
    assert_true(
        _v4_refused(Int(v6.socket.get_sock_name()[1])),
        "127.0.0.1 reached a tcp6 [::] listener",
    )
    _ = v6^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
