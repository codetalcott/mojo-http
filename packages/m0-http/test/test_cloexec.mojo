"""Every descriptor the server creates is close-on-exec (SPEC G16).

A child an application starts with `exec` keeps every descriptor that is
not, and the server's are client connections, the listener and its own
channels: a connection the server closes then stays open in the child. One
test per creation helper, each read back with `F_GETFD`.
"""

from std.ffi import c_int
from std.testing import assert_true, assert_false, TestSuite

from lightbug_http.c.fcntl import set_cloexec, is_cloexec, clear_cloexec, dup_cloexec
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.socket import socket as c_socket, accept_with_peer
from lightbug_http.c.fdpass import send_fd, recv_fd
from lightbug_http.c.process import shared_file_fd
from lightbug_http.connection import ListenConfig, create_connection
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
    var listener = ListenConfig(max_bind_retries=1, quiet=True).listen(
        "127.0.0.1:18697"
    )
    var host = String("127.0.0.1")
    var client = create_connection(host, 18697)
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
