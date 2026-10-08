"""The listener asks for the platform's `SOMAXCONN` (review record LF19).

`ListenConfig.listen` asked for a backlog of 128. On Linux, where
`net.core.somaxconn` has been 4096 by default since 5.4, a burst of more
than 128 new connections arriving while the loop is busy overflowed the
accept queue: the kernel drops each handshake past a full queue
(`TcpExtListenOverflows`), and its client retries a second later. The
queue is now up to `SOMAXCONN` (4096 on Linux, 128 on macOS), or the
system's setting if that is lower. Linux reports a listener's limit in
`TCP_INFO` (`tcpi_sacked`, as `ss -lt` shows it); macOS's is 128 either
way (`netstat -Lan` shows it as `maxqlen`), so there the test holds the
constant.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal

from lightbug_http.c.socket import IPPROTO_TCP, SOMAXCONN
from lightbug_http.connection import ListenConfig

comptime _TCP_INFO = 11
"""Linux <netinet/tcp.h>."""
comptime _TCP_LISTEN = 10
"""Linux's `TCP_LISTEN` state, `tcpi_state` of a listener."""
comptime _TCPI_SACKED = 28
"""`struct tcp_info`'s `tcpi_sacked`: eight one-byte fields, then the
`__u32`s `rto`, `ato`, `snd_mss`, `rcv_mss`, `unacked`, `sacked`. For a
listener it is the accept queue's limit (`sk_max_ack_backlog`)."""


def _somaxconn() raises -> Int:
    """`net.core.somaxconn`, read from /proc."""
    with open("/proc/sys/net/core/somaxconn", "r") as f:
        return Int(String(f.read().strip()))


def test_the_listener_asks_for_the_systems_backlog() raises:
    """The listener's accept queue holds up to `SOMAXCONN` connections, or
    the system's setting if that is lower: on Linux `min(SOMAXCONN,
    net.core.somaxconn)`, as `TCP_INFO` reports it, where it was 128.

    covers: C12
    """
    comptime if CompilationTarget.is_macos():
        assert_equal(SOMAXCONN, 128, "macOS's SOMAXCONN is 128 (<sys/socket.h>)")
    else:
        assert_equal(SOMAXCONN, 4096, "Linux's SOMAXCONN is 4096 (since 5.4)")
        var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
        var info = unsafe_alloc[UInt8](count=256)
        var size = unsafe_alloc[UInt32](count=1)
        size[unsafe_offset=0] = 256
        var rc = external_call[
            "getsockopt", c_int, c_int, c_int, c_int, type_of(info), type_of(size)
        ](c_int(ln.socket.fd.value), c_int(IPPROTO_TCP), c_int(_TCP_INFO), info, size)
        var errno = get_errno()
        var state = Int(info[unsafe_offset=0])
        var limit = (
            Int(info[unsafe_offset=_TCPI_SACKED])
            | (Int(info[unsafe_offset=_TCPI_SACKED + 1]) << 8)
            | (Int(info[unsafe_offset=_TCPI_SACKED + 2]) << 16)
            | (Int(info[unsafe_offset=_TCPI_SACKED + 3]) << 24)
        )
        info.unsafe_free()
        size.unsafe_free()
        assert_equal(Int(rc), 0, String("getsockopt TCP_INFO failed: ", errno))
        assert_equal(state, _TCP_LISTEN, "TCP_INFO did not describe a listener")
        assert_equal(
            limit, min(SOMAXCONN, _somaxconn()),
            "the listener's backlog is not the system's",
        )
        _ = ln^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
