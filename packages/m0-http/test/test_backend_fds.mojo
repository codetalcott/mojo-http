"""A loop's backend gives back what it opened, and epoll reports the
registration that failed (review record LF21).

Neither backend closed its multiplexer when it was destroyed, nor the
epoll one its timerfds: every `Server.serve_nonblocking` that returned, and
every loop thread of the host's that ended, left a kqueue or an epoll
instance open for the life of the process. And `EpollBackend.add_read` fell
back from ADD to MOD on any errno, so an ADD the kernel refused for a
reason of its own was reported as MOD's ENOENT.
"""

from std.ffi import c_int
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.c.epoll_backend import EpollBackend
from lightbug_http.c.fcntl import F_GETFD, _fcntl
from lightbug_http.c.platform import PlatformBackend
from lightbug_http.loop.state import TIMER_APP_TICK, TIMER_BODY


def _is_open(fd: Int) -> Bool:
    return _fcntl(c_int(fd), c_int(F_GETFD)) != -1


def _open_count() -> Int:
    """Descriptors open below 4096: every one a test process holds."""
    var n = 0
    for fd in range(4096):
        if _is_open(fd):
            n += 1
    return n


def _a_backend_that_armed_two_timers() raises -> Int:
    """Build a backend, arm two timers on it (two timerfds on epoll), and
    let it go; its multiplexer's number."""
    var backend = PlatformBackend()
    backend.try_add_timer(TIMER_APP_TICK, 60_000)
    backend.try_add_timer(TIMER_BODY + 7, 60_000)
    return backend.multiplexer_fd()


def test_a_destroyed_backend_closes_what_it_opened() raises:
    """Once the backend is gone its multiplexer is closed, and the process
    holds exactly the descriptors it held before the backend was made.

    covers: C13
    """
    var before = _open_count()
    var fd = _a_backend_that_armed_two_timers()
    assert_false(_is_open(fd), String("the backend's multiplexer, ", fd, ", is still open"))
    assert_equal(
        _open_count(), before,
        "a destroyed backend left descriptors open (its multiplexer, or a timerfd)",
    )


def test_epoll_reports_the_registration_that_failed() raises:
    """On Linux: an `add_read` the kernel refuses for a reason other than
    EEXIST raises ADD's own error. Adding an epoll instance to one it
    already watches would close a loop, which ADD refuses with ELOOP; the
    MOD it fell back to answered ENOENT, the fd never having been added.
    Nothing to hold on macOS, whose kqueue backend has no fallback."""
    comptime if not CompilationTarget.is_macos():
        var outer = EpollBackend()
        var inner = EpollBackend()
        outer.add_read(inner.multiplexer_fd())
        var text = String("")
        try:
            inner.add_read(outer.multiplexer_fd())
        except e:
            text = String(e)
        assert_true(text != "", "an add that closes a loop of epoll instances was accepted")
        assert_true(
            text.find("epoll_ctl ADD") >= 0 and text.find("(errno 40)") >= 0,
            String("expected ADD's ELOOP, got: ", text),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
