"""Every descriptor the server creates is close-on-exec (SPEC G16).

A child an application starts with `exec` keeps every descriptor that is
not, and the server's are client connections, the listener and its own
channels: a connection the server closes then stays open in the child. One
test per creation helper, each read back with `F_GETFD`. The shared page's
mode, and its descriptor when it cannot be sized, are here too (SPEC G20).
"""

from std.ffi import c_int, external_call, get_errno
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.c.fcntl import set_cloexec, is_cloexec, clear_cloexec, dup_cloexec
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.socket import socket as c_socket, accept_with_peer
from lightbug_http.c.fdpass import send_fd, recv_fd
from lightbug_http.c.process import shared_file_fd
from lightbug_http.connection import ListenConfig
from test.loopback import create_connection
from src.threads import dup_fd


def test_set_and_clear_cloexec_round_trip() raises:
    var pair = socketpair_dgram()
    set_cloexec(pair[0])
    assert_true(is_cloexec(pair[0]))
    assert_true(clear_cloexec(pair[0]))
    assert_false(is_cloexec(pair[0]))
    close_fd(pair[0])
    close_fd(pair[1])


def test_dup_cloexec_is_close_on_exec_at_birth() raises:
    var pair = socketpair_dgram()
    _ = clear_cloexec(pair[0])
    var d = dup_cloexec(pair[0])
    assert_true(is_cloexec(d))
    close_fd(d)
    close_fd(pair[0])
    close_fd(pair[1])


def test_socketpair_ends_are_close_on_exec() raises:
    """The bus, every loop and pool channel, the accept-share channels."""
    var pair = socketpair_dgram()
    assert_true(is_cloexec(pair[0]))
    assert_true(is_cloexec(pair[1]))
    close_fd(pair[0])
    close_fd(pair[1])


def test_shutdown_pipe_ends_are_close_on_exec() raises:
    """The signal self-pipe, each loop's fan-out, the pg-listen stop pipe."""
    var p = create_shutdown_pipe()
    assert_true(is_cloexec(p[0]))
    assert_true(is_cloexec(p[1].fd))
    close_fd(p[0])
    close_fd(p[1].fd)


def test_a_socket_is_close_on_exec() raises:
    """The listener's and every client socket's own call."""
    var fd = c_socket(c_int(2), c_int(1), c_int(0))  # AF_INET, SOCK_STREAM
    assert_true(is_cloexec(Int(fd)))
    close_fd(Int(fd))


def test_an_accepted_connection_is_close_on_exec() raises:
    """What a child held for 10 s under FastHTML's terminal example."""
    # Port 0, and the kernel's choice read back: a fixed port collided when
    # two checkouts ran the suite at once.
    var listener = ListenConfig(max_bind_retries=1, quiet=True).listen(
        "127.0.0.1:0"
    )
    var port = Int(listener.socket.get_sock_name()[1])
    var host = String("127.0.0.1")
    var client = create_connection(host, UInt16(port))
    var accepted = accept_with_peer(listener.socket.fd)
    assert_true(is_cloexec(accepted[0].value))
    close_fd(accepted[0].value)
    _ = client^
    _ = listener^


def test_a_received_descriptor_is_close_on_exec() raises:
    """A connection another worker handed over (accept sharing, E16)."""
    var channel = socketpair_dgram()
    var conn = socketpair_dgram()  # stands in for an accepted connection
    var payload = List[UInt8]()
    assert_true(send_fd(channel[1], conn[0], payload))
    var got = recv_fd(channel[0], payload)
    assert_true(got >= 0, "recv_fd returned no descriptor")
    assert_true(is_cloexec(got))
    for fd in [got, channel[0], channel[1], conn[0], conn[1]]:
        close_fd(fd)


def test_dup_fd_is_close_on_exec() raises:
    """Each serving thread's own dup of the listener, and a static body's."""
    var pair = socketpair_dgram()
    var d = dup_fd(pair[0])
    assert_true(is_cloexec(d))
    for fd in [d, pair[0], pair[1]]:
        close_fd(fd)


def test_the_shared_page_is_close_on_exec() raises:
    """Kept across exec only by the spawn hand-off, never by default."""
    var fd = shared_file_fd(4096)
    assert_true(is_cloexec(fd))
    close_fd(fd)


def _mode_of(fd: Int) raises -> Int:
    """The permission bits of the file `fd` names, from `fstat`.

    `st_mode` is a 2-byte `mode_t` at offset 4 of `struct stat` on macOS,
    and a 4-byte one at offset 24 on Linux x86-64 and 16 on Linux aarch64.
    """
    var buf = List[UInt8](capacity=256)
    for _ in range(256):
        buf.append(0)
    var rc = external_call["fstat", c_int, c_int, type_of(buf.unsafe_ptr())](
        c_int(fd), buf.unsafe_ptr()
    )
    if rc != 0:
        raise Error("fstat failed, errno: ", get_errno())
    var mode: Int
    comptime if CompilationTarget.is_macos():
        mode = Int(buf.unsafe_ptr().unsafe_offset(4).unsafe_bitcast[UInt16]()[])
    elif CompilationTarget.is_x86():
        mode = Int(buf.unsafe_ptr().unsafe_offset(24).unsafe_bitcast[UInt32]()[])
    else:
        mode = Int(buf.unsafe_ptr().unsafe_offset(16).unsafe_bitcast[UInt32]()[])
    _ = buf
    return mode & 0o777


def test_the_shared_page_is_its_owners_alone() raises:
    """The shared page is created with mode 0o600, as `shared_file_fd` asks.

    `shm_open` is variadic (`int shm_open(const char *, int, ...)`), and
    Darwin arm64 passes a variadic argument on the stack. Called with the
    mode as a third fixed argument, it put 0o600 in a register the callee
    never reads, and the page took its mode from whatever the stack held:
    measured as 0o0, 0o1 and 0o744 (review record LF17). The call now takes
    `_fcntl`'s shape there (`c/fcntl.mojo`). Linux passes variadic
    arguments in registers, so this bites on the macOS leg only. Several
    pages, because the stack's leftovers vary from call to call.

    covers: G20
    """
    for _ in range(4):
        var fd = shared_file_fd(4096)
        var mode = _mode_of(fd)
        close_fd(fd)
        assert_equal(
            mode, 0o600,
            String("the shared page was created with mode ") + oct(mode),
        )


def test_a_page_that_cannot_be_sized_is_closed() raises:
    """A page `ftruncate` refuses (here a negative length) raises with its
    descriptor closed, not leaked (review record LF17): the next descriptor
    made takes the number a leaked page would still hold."""
    var before = socketpair_dgram()
    close_fd(before[0])
    close_fd(before[1])
    var raised = False
    try:
        _ = shared_file_fd(-1)
    except:
        raised = True
    assert_true(raised, "a negative length was not refused")
    var after = socketpair_dgram()
    close_fd(after[0])
    close_fd(after[1])
    assert_equal(
        after[0], before[0],
        "the refused page's descriptor is still open",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
