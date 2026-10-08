"""A stream's socket has TCP keepalive on (SPEC I32).

A stream has no deadline (DECISIONS D57), so a client that vanishes without
a FIN is reaped only when something sent to it goes unanswered. The loop's
heartbeat is that something for a stream it writes itself. A stream the
application writes through the chunk channel gets no heartbeat, and no
stream does with the heartbeat off; for those the kernel's keepalive probe
is the one thing that looks, and `set_tcp_keepalive` is what turns it on.

These tests read the options back off a real loopback connection with
`getsockopt`. The option numbers below are written out from each
platform's headers a second time, on purpose: read back through the
fork's own constants, a wrong number would be set and read as the same
wrong option and agree with itself. That the loop sets them on each kind
of stream, and that a vanished client is then reaped, is
`smoke-stream-keepalive`'s.

covers: I32
"""

from std.ffi import c_int, external_call
from std.memory.alloc import unsafe_alloc
from std.os import getenv, setenv, unsetenv
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from lightbug_http.c.pipe import close_fd
from lightbug_http.c.socket import accept_with_peer, set_tcp_keepalive
from lightbug_http.connection import ListenConfig
from test.loopback import create_connection
from lightbug_http.loop.state import (
    STREAM_KEEPALIVE_S,
    _stream_keepalive_from_env,
)

comptime _MAC = CompilationTarget.is_macos()
# <sys/socket.h> and <netinet/tcp.h> on macOS; asm-generic/socket.h and
# <netinet/tcp.h> on Linux. Not imported from the fork: see the docstring.
comptime _SOL_SOCKET = 0xFFFF if _MAC else 1
comptime _SO_KEEPALIVE = 0x0008 if _MAC else 9
comptime _IPPROTO_TCP = 6
comptime _TCP_IDLE = 0x10 if _MAC else 4
comptime _TCP_INTVL = 0x101 if _MAC else 5
comptime _TCP_CNT = 0x102 if _MAC else 6


def _getsockopt(fd: Int, level: Int, name: Int) raises -> Int:
    """One `int` option of `fd`, as the kernel holds it."""
    var value = unsafe_alloc[c_int](count=1)
    var size = unsafe_alloc[UInt32](count=1)
    value[] = c_int(-1)
    size[] = UInt32(4)
    var rc = external_call[
        "getsockopt", c_int, c_int, c_int, c_int, type_of(value), type_of(size)
    ](c_int(fd), c_int(level), c_int(name), value, size)
    var got = Int(value[])
    value.unsafe_free()
    size.unsafe_free()
    if rc != 0:
        raise Error("getsockopt(" + String(level) + ", " + String(name) + ") failed")
    return got


def test_keepalive_is_off_until_it_is_asked_for() raises:
    """The control: an accepted connection has none, so what the next test
    reads is what the setter did."""
    var listener = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var port = Int(listener.socket.get_sock_name()[1])
    var host = String("127.0.0.1")
    var client = create_connection(host, UInt16(port))
    var accepted = accept_with_peer(listener.socket.fd)
    var fd = Int(accepted[0].value)
    assert_equal(_getsockopt(fd, _SOL_SOCKET, _SO_KEEPALIVE), 0)
    close_fd(fd)
    _ = client^
    _ = listener^


def test_the_setter_turns_keepalive_on_with_its_three_timings() raises:
    var listener = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var port = Int(listener.socket.get_sock_name()[1])
    var host = String("127.0.0.1")
    var client = create_connection(host, UInt16(port))
    var accepted = accept_with_peer(listener.socket.fd)
    var fd = Int(accepted[0].value)
    set_tcp_keepalive(accepted[0], 7, 5, 3)
    # Nonzero, not 1: macOS answers the option's own bit, 8.
    assert_true(_getsockopt(fd, _SOL_SOCKET, _SO_KEEPALIVE) != 0, "SO_KEEPALIVE is off")
    assert_equal(_getsockopt(fd, _IPPROTO_TCP, _TCP_IDLE), 7)
    assert_equal(_getsockopt(fd, _IPPROTO_TCP, _TCP_INTVL), 5)
    assert_equal(_getsockopt(fd, _IPPROTO_TCP, _TCP_CNT), 3)
    close_fd(fd)
    _ = client^
    _ = listener^


def test_the_knob_reads_seconds_and_zero_is_off() raises:
    """`M0_STREAM_KEEPALIVE_S`: a number of seconds, 0 for off, and the
    default for anything else. The variable is put back as it was found."""
    var was = getenv("M0_STREAM_KEEPALIVE_S", "")
    _ = unsetenv("M0_STREAM_KEEPALIVE_S")
    assert_equal(_stream_keepalive_from_env(), STREAM_KEEPALIVE_S)
    _ = setenv("M0_STREAM_KEEPALIVE_S", "0")
    assert_equal(_stream_keepalive_from_env(), 0)
    _ = setenv("M0_STREAM_KEEPALIVE_S", "4")
    assert_equal(_stream_keepalive_from_env(), 4)
    _ = setenv("M0_STREAM_KEEPALIVE_S", "-1")
    assert_equal(_stream_keepalive_from_env(), STREAM_KEEPALIVE_S)
    _ = setenv("M0_STREAM_KEEPALIVE_S", "soon")
    assert_equal(_stream_keepalive_from_env(), STREAM_KEEPALIVE_S)
    if was.byte_length() > 0:
        _ = setenv("M0_STREAM_KEEPALIVE_S", was)
    else:
        _ = unsetenv("M0_STREAM_KEEPALIVE_S")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
