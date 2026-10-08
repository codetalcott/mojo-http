"""The platform seam: one place chooses the OS multiplexer.

`lightbug_http/c/platform.mojo` names `PlatformBackend` (kqueue on macOS,
epoll on Linux) and the two libc constants whose values differ between
them. These tests prove the alias is a real backend on THIS operating
system -- constructible through the trait-declared initializer, owning a
multiplexer fd -- and that the constants are the ones this OS needs. The
other half of the guarantee, that no other file chooses a backend, is
`scripts/check_docs.py::check_backend_seam`, a rule over the tree's text.
"""

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, TestSuite
from std.time import perf_counter_ns

from lightbug_http.c.kqueue import EV_EOF, EVFILT_READ, EVFILT_TIMER, EVFILT_WRITE
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.platform import (
    MSG_DONTWAIT,
    PlatformBackend,
    SC_NPROCESSORS_ONLN,
)
from lightbug_http.loop.state import TIMER_APP_TICK, TIMER_BODY


def test_platform_backend_is_a_constructible_multiplexer() raises:
    """`PlatformBackend()` resolves to the trait's initializer and opens the
    OS multiplexer: a non-negative fd, distinct across two instances.

    covers: E12
    """
    var a = PlatformBackend()
    var b = PlatformBackend()
    assert_true(a.multiplexer_fd() >= 0)
    assert_true(b.multiplexer_fd() >= 0)
    assert_true(a.multiplexer_fd() != b.multiplexer_fd())


def test_platform_constants_are_this_operating_systems() raises:
    """The seam's constants match the OS the test runs on, and the sysconf
    name it exports really answers: a count of at least one CPU.
    """
    comptime if CompilationTarget.is_macos():
        assert_equal(Int(MSG_DONTWAIT), 0x80)
        assert_equal(SC_NPROCESSORS_ONLN, 58)
    else:
        assert_equal(Int(MSG_DONTWAIT), 0x40)
        assert_equal(SC_NPROCESSORS_ONLN, 84)
    var cpus = external_call["sysconf", Int](Int(SC_NPROCESSORS_ONLN))
    assert_true(cpus >= 1)


def test_the_backend_reports_what_it_was_asked_to_watch() raises:
    """`EventLoopBackend`'s contract, held on this OS's backend over a pipe,
    which kqueue and epoll both watch: a readable descriptor is one READ
    event naming it; bytes left unread are reported again by kqueue, whose
    `add_read` is level triggered, and not by epoll, whose is edge triggered
    (re-adding regenerates one on both); a deleted read interest reports
    nothing; a one-shot write fires once; a timer fires once with its
    ident, and one deleted first never does; a writer that has gone is
    EV_EOF on the reader; and `wait_ns` waits.

    The wrappers under it -- `ev_set`, `kevent_register_one` and `_pair`,
    `kevent_poll` and `_ns`; `epoll_ctl_*`, `epoll_wait`, `epoll_pwait2_ns`,
    `timerfd_*` -- are inherited code the loop's own tests reach only
    through whole requests (review audit A3).

    covers: C16
    """
    var pipe = create_shutdown_pipe()
    var r = pipe[0]
    var w = pipe[1].fd
    var backend = PlatformBackend()

    backend.add_read(r)
    assert_equal(backend.wait(0), 0, "an empty pipe was reported readable")
    pipe[1].notify()
    assert_equal(backend.wait(1000), 1)
    assert_equal(Int(backend.event_ident(0)), r)
    assert_equal(backend.event_filter(0), EVFILT_READ)
    assert_equal(Int(backend.event_flags(0) & EV_EOF), 0)
    comptime if CompilationTarget.is_macos():
        assert_equal(backend.event_data(0), 1, "kqueue reports the bytes waiting")
        assert_equal(backend.wait(0), 1, "kqueue's read is level triggered")
    else:
        assert_equal(backend.event_data(0), 0, "epoll knows no count")
        assert_equal(backend.wait(0), 0, "epoll's read is edge triggered")
    backend.try_add_read(r)
    assert_equal(backend.wait(0), 1, "a re-add did not report the unread byte")
    backend.try_delete_read(r)
    assert_equal(backend.wait(0), 0, "a deleted read interest still reports")

    backend.add_write_oneshot(w)
    assert_equal(backend.wait(1000), 1)
    assert_equal(Int(backend.event_ident(0)), w)
    assert_equal(backend.event_filter(0), EVFILT_WRITE)
    assert_equal(backend.wait(0), 0, "a one-shot write fired twice")
    backend.try_delete_write(w)
    backend.try_add_write_oneshot(w)
    assert_equal(backend.wait(1000), 1, "a one-shot write did not re-arm")
    backend.try_delete_write(w)

    backend.try_add_timer(TIMER_APP_TICK, 1)
    assert_equal(backend.wait(1000), 1, "the timer did not fire")
    assert_equal(backend.event_filter(0), EVFILT_TIMER)
    assert_equal(backend.event_ident(0), TIMER_APP_TICK)
    backend.try_delete_timer(TIMER_APP_TICK)
    backend.try_add_timer(TIMER_BODY + 7, 30)
    backend.try_delete_timer(TIMER_BODY + 7)
    assert_equal(backend.wait(100), 0, "a deleted timer fired")

    var t0 = perf_counter_ns()
    assert_equal(backend.wait_ns(2_000_000), 0)
    assert_true(perf_counter_ns() - t0 >= 1_500_000, "wait_ns did not wait")

    backend.try_add_read(r)
    pipe[1].signal()
    assert_equal(backend.wait(1000), 1)
    assert_equal(Int(backend.event_ident(0)), r)
    assert_true(
        (backend.event_flags(0) & EV_EOF) != 0, "a closed writer is not EV_EOF"
    )
    backend.try_delete_read(r)
    close_fd(r)
    _ = backend


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
