"""Every descriptor the server creates is close-on-exec (SPEC G16).

A child an application starts with `exec` keeps every descriptor that is
not, and the server's are client connections, the listener and its own
channels: a connection the server closes then stays open in the child. One
test per creation helper, each read back with `F_GETFD`.
"""

from std.testing import assert_true, assert_false, TestSuite

from lightbug_http.c.fcntl import set_cloexec, is_cloexec, clear_cloexec, dup_cloexec
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.c.pipe import close_fd


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
