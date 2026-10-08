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
the wire, through m0serve and the Mojo host. The listen address's rules
for either family live here too (review records LF33, LF45-LF47): how it
is parsed, and the banner that names it once bound.
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
    SOL_SOCKET,
    SocketOption,
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


def test_the_inet_calls_refuse_a_family_they_cannot_read() raises:
    """`inet_ntop` and `inet_pton` raise what the call reports for a family
    other than IPv4 and IPv6: EAFNOSUPPORT, read after the call, as its own
    error for `inet_ntop` and as the code in `inet_pton`'s. And the longest
    IPv6 text fits `inet_ntop`'s buffer (`INET6_ADDRSTRLEN`)."""
    var loopback = inet_pton[AddressFamily.AF_INET6](String("::1"))
    with assert_raises(contains="(EAFNOSUPPORT)"):
        _ = inet_ntop[AddressFamily.AF_UNSPEC](loopback)
    with assert_raises(
        contains=String("Error code: ", ErrNo.EAFNOSUPPORT)
    ):
        _ = inet_pton[AddressFamily.AF_UNSPEC](String("127.0.0.1"))
    with assert_raises(contains="not a valid address"):
        _ = inet_pton[AddressFamily.AF_INET6](String("::1::2"))
    var longest = String("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
    assert_equal(
        inet_ntop[AddressFamily.AF_INET6](inet_pton[AddressFamily.AF_INET6](longest)),
        longest,
    )
    assert_equal(
        inet_ntop[AddressFamily.AF_INET6](
            inet_pton[AddressFamily.AF_INET6](String("::ffff:255.255.255.255"))
        ),
        "::ffff:255.255.255.255",
    )


# --- parsing an address ---------------------------------------------------------


def test_each_malformed_address_is_refused_by_its_own_rule() raises:
    """Every refusal `parse_address` makes, each in its own rule's words,
    and through `ListenConfig.listen` as one that names the listen address.

    covers: A33
    """
    var cases: List[Tuple[String, String]] = [
        ("", "received empty address string"),
        ("[::1", "missing ']'"),
        ("[::1]", "missing port in address"),
        ("[::1]80", "missing port in address"),
        ("[::1]:8]0", "unexpectedly contained brackets"),
        ("[::1]:[80", "unexpectedly contained brackets"),
        ("127.0.0.1:", "port string is empty"),
        ("127.0.0.1:http", "invalid integer value"),
        ("127.0.0.1:65536", "out of range"),
        ("127.0.0.1", "missing port separator"),
        ("::1:80", "too many colons"),
    ]
    for refusal in cases:
        with assert_raises(contains=refusal[1]):
            _ = parse_address[NetworkType.tcp](StringSpan(refusal[0]))
        with assert_raises(contains="Failed to parse listen address"):
            var ln = ListenConfig(max_bind_retries=1, quiet=True).listen(refusal[0])
            _ = ln^


def test_a_host_that_is_not_an_address_is_refused_at_bind() raises:
    """The parser leaves the host to `inet_pton`, at bind: an empty host, a
    name other than `localhost`, a stray bracket, and an address of the
    other family than the network's, are each refused at startup as not a
    valid address, never listened on.

    An IPv6 zone (`fe80::1%lo0`) is not among them: the parser refuses
    it before either libc sees it (review record LF48).
    """
    var refused: List[String] = [
        ":0", "[]:0", "LOCALHOST:0", "example.com:0", "[[::1]:0",
        "127.0.0.1]:0", "1.2.3:0",
    ]
    for address in refused:
        with assert_raises(contains="not a valid address"):
            var ln = ListenConfig(max_bind_retries=1, quiet=True).listen(address)
            _ = ln^
    with assert_raises(contains="not a valid address"):
        var v4 = ListenConfig(max_bind_retries=1, quiet=True).listen[NetworkType.tcp4]("[::1]:0")
        _ = v4^
    with assert_raises(contains="not a valid address"):
        var v6 = ListenConfig(max_bind_retries=1, quiet=True).listen[NetworkType.tcp6]("127.0.0.1:0")
        _ = v6^


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


def test_an_address_without_a_port_is_refused() raises:
    """`localhost` alone is refused as missing its port, as `127.0.0.1`
    alone always was, in every network (review record LF45).

    It was read as the loopback at port 0, so `listen_and_serve("localhost")`
    listened on a port the kernel chose, which no client was told of. A
    port named after it is kept: `localhost:80` is the loopback's port 80,
    IPv6's under `tcp6`.

    covers: A33
    """
    with assert_raises(contains="missing port separator"):
        _ = parse_address[NetworkType.tcp](StringSpan("localhost"))
    with assert_raises(contains="missing port separator"):
        _ = parse_address[NetworkType.tcp4](StringSpan("localhost"))
    with assert_raises(contains="missing port separator"):
        _ = parse_address[NetworkType.tcp6](StringSpan("localhost"))
    with assert_raises(contains="missing port separator"):
        _ = parse_address[NetworkType.tcp](StringSpan("127.0.0.1"))
    with assert_raises(contains="Failed to parse listen address"):
        var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("localhost")
        _ = ln^
    var hp = parse_address[NetworkType.tcp](StringSpan("localhost:80"))
    assert_equal(hp.host, "127.0.0.1")
    assert_equal(Int(hp.port), 80)
    hp = parse_address[NetworkType.tcp6](StringSpan("localhost:80"))
    assert_equal(hp.host, "::1")
    assert_equal(Int(hp.port), 80)


def test_a_port_is_decimal_digits() raises:
    """A listen address's port is ASCII digits and nothing else (review
    record LF46).

    It was read by `Int()`, which takes what Python's `int()` takes: a sign,
    whitespace around the number and underscores between its digits. So
    `127.0.0.1:-0` listened on a port the kernel chose, and `:+80`, `: 80`,
    `:8_0` and `:80` with a newline after it on port 80. A port is now one
    or more ASCII digits (RFC 3986's `port = *DIGIT`, the empty one refused
    as before) naming a number from 0 to 65535: `080` is port 80.

    covers: A34
    """
    var refused: List[String] = [
        "+80", "-0", "-1", " 80", "80 ", "\t80", "80\n", "8_0", "0x50", "8 0",
        "٨٠",
    ]
    for port in refused:
        with assert_raises(contains="invalid integer value"):
            _ = parse_address[NetworkType.tcp](StringSpan("127.0.0.1:" + port))
        with assert_raises(contains="invalid integer value"):
            _ = parse_address[NetworkType.tcp](StringSpan("[::1]:" + port))
    with assert_raises(contains="Port number out of range"):
        _ = parse_address[NetworkType.tcp](StringSpan("127.0.0.1:65536"))
    with assert_raises(contains="port string is empty"):
        _ = parse_address[NetworkType.tcp](StringSpan("127.0.0.1:"))
    assert_equal(Int(parse_address[NetworkType.tcp](StringSpan("127.0.0.1:0")).port), 0)
    assert_equal(Int(parse_address[NetworkType.tcp](StringSpan("127.0.0.1:080")).port), 80)
    assert_equal(Int(parse_address[NetworkType.tcp](StringSpan("[::1]:65535")).port), 65535)


def test_an_ipv6_zone_is_refused() raises:
    """A listen host carrying an IPv6 zone (`fe80::1%lo0`) is refused, the
    same on every platform (review record LF48).

    macOS's `inet_pton` reads a zone, writing the interface's index into
    the address (KAME's embedded form), so `[fe80::1%lo0]:8080` listened
    there on lo0's link-local address and was reported without its zone;
    glibc's refuses one, so Linux refused it at bind as not an address. A
    listener carries no zone, so the parser refuses it first, and says so
    through `ListenConfig.listen`.
    """
    var zoned: List[String] = [
        "[fe80::1%lo0]:0", "[::1%lo0]:0", "[fe80::1%]:0", "[fe80::1%1]:0",
    ]
    for address in zoned:
        with assert_raises(contains="IPv6 zone"):
            _ = parse_address[NetworkType.tcp](StringSpan(address))
        with assert_raises(contains="IPv6 zone"):
            var ln = ListenConfig(max_bind_retries=1, quiet=True).listen(address)
            _ = ln^
    with assert_raises(contains="IPv6 zone"):
        _ = parse_address[NetworkType.tcp6](StringSpan("[fe80::1%en0]:8080"))


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


def _socket_option(fd: Int, name: c_int) raises -> Int:
    """An integer `SOL_SOCKET` option of `fd`, as the kernel holds it."""
    var value = c_int(-1)
    var size = c_int(4)
    var rc = external_call["getsockopt", c_int](
        c_int(fd), c_int(SOL_SOCKET), name, Pointer(to=value), Pointer(to=size)
    )
    if rc != 0:
        raise Error("getsockopt failed, errno ", get_errno())
    return Int(value)


def test_a_listener_shares_its_port_only_when_asked() raises:
    """A listener sets `SO_REUSEADDR`, so a restart binds past the previous
    server's TIME_WAIT, and `SO_REUSEPORT` only under `reuse_port`, so a
    second server on its port fails to bind rather than share it.

    covers: D6
    """
    var plain = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var fd = Int(plain.socket.fd.value)
    assert_true(_socket_option(fd, SocketOption.SO_REUSEADDR.value) != 0, "SO_REUSEADDR is off")
    assert_equal(_socket_option(fd, SocketOption.SO_REUSEPORT.value), 0, "SO_REUSEPORT is on unasked")
    var taken = "127.0.0.1:" + String(plain.socket.local_address.port)
    with assert_raises(contains="bind: "):
        var second = ListenConfig(max_bind_retries=1, quiet=True).listen(taken)
        _ = second^
    _ = plain^
    var shared = ListenConfig(max_bind_retries=1, reuse_port=True, quiet=True).listen("127.0.0.1:0")
    assert_true(
        _socket_option(Int(shared.socket.fd.value), SocketOption.SO_REUSEPORT.value) != 0,
        "reuse_port did not set SO_REUSEPORT",
    )
    _ = shared^


comptime _OpaqueMut = Pointer[NoneType, MutUntrackedOrigin]
"""`read(2)`'s buffer type as every declaration in the m0-http test
program spells it (`src/threads.mojo`): `test-http` builds all the test
files as one program, where a second `external_call["read"]` with another
signature is a conflicting declaration."""


def _banner_of(address: String) raises -> Tuple[String, Int]:
    """What `ListenConfig.listen(address)` prints with its banner on, read
    from a pipe standing in for stdout during the call, and the port the
    listener is bound to."""
    var fds = List[c_int](length=2, fill=-1)
    if external_call["pipe", c_int](fds.unsafe_ptr()) != 0:
        raise Error("pipe() failed, errno ", get_errno())
    var r = Int(fds[0])
    var w = Int(fds[1])
    var port: Int
    var text: String
    # The pipe's ends are closed on every path, a failed `dup`, a failed
    # `dup2` and a `listen` that raises among them, and stdout is put back
    # whenever it was moved.
    try:
        var saved = Int(external_call["dup", c_int, c_int](c_int(1)))
        if saved < 0:
            raise Error("dup(1) failed, errno ", get_errno())
        try:
            if Int(external_call["dup2", c_int, c_int, c_int](c_int(w), c_int(1))) != 1:
                raise Error("dup2() onto stdout failed, errno ", get_errno())
            var ln = ListenConfig(max_bind_retries=1).listen(address)
            port = Int(ln.socket.local_address.port)
            _ = ln^
        finally:
            _ = external_call["dup2", c_int, c_int, c_int](c_int(saved), c_int(1))
            close_fd(saved)
        close_fd(w)
        w = -1
        var buf = List[UInt8](length=4096, fill=0)
        var n = external_call["read", Int, Int, _OpaqueMut, Int](
            r,
            buf.unsafe_ptr().unsafe_bitcast[NoneType]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            4096,
        )
        if n < 0:
            raise Error("read() failed, errno ", get_errno())
        text = String(unsafe_from_utf8=Span(buf)[:n])
    finally:
        if w >= 0:
            close_fd(w)
        close_fd(r)
    return (text^, port)


def test_the_banner_names_the_port_bound() raises:
    """The listening banner names the port the listener is bound to, so a
    server asked for port 0 says which one the kernel chose (review record
    LF47).

    It named the port it was asked for: `Lightbug is listening on
    http://127.0.0.1:0`, a port no client can connect to. Reached by an
    application that passes `Server.listen_and_serve` or
    `ListenConfig.listen` a port of 0 itself; m0serve and the Mojo host
    refuse a port of 0 (LF56).

    covers: F25
    """
    for address in [String("127.0.0.1:0"), String("[::1]:0")]:
        var got = _banner_of(address)
        var text = got[0]
        var port = got[1]
        assert_true(port > 0, "the listener is not bound")
        var host = String("[::1]") if address.startswith("[") else String("127.0.0.1")
        assert_true(
            text.find("http://" + host + ":" + String(port) + "\n") != -1,
            String("the banner does not name the port bound (", port, "): ", repr(text)),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
