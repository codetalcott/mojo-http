"""Tests for the threaded mode's pure parts.

No interpreter here either, same charter as `test_hold` and `test_cli`:
`refusal_message` and `ThreadContext` are plain values, and the message is
what a user reads when the mode cannot run, so its wording is pinned. What
is NOT reachable here — attaching threads, the detaching backend's
attached wait, the refusal actually exiting 78 — is `smoke-threads`'s
job, which runs the built binary. The detached wait is: it touches no
interpreter.

Importing `src.threaded` links `std.python` exactly as `src.app` already
does for `test_hold`; nothing in these tests initializes an interpreter.
"""

from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.event_loop_backend import EventLoopBackend
from src.threaded import (
    asgi_free_threading_refusal,
    DetachingBackend,
    PYOBJECT_LAYOUT_ISSUE,
    FreeThreadingReport,
    ThreadContext,
    refusal_message,
    EXIT_NOT_FREE_THREADED,
)


def test_refusal_names_the_requirement_the_version_and_the_fix() raises:
    var report = FreeThreadingReport(String("3.13.7"), False, True)
    var msg = refusal_message(4, report)
    assert_true(msg.find("M0_THREADS=4") >= 0, msg)
    assert_true(msg.find("requires free-threaded CPython") >= 0, msg)
    assert_true(msg.find("3.13.7") >= 0, msg)
    assert_true(msg.find("not a free-threaded build") >= 0, msg)
    assert_true(msg.find("M0_WORKERS") >= 0, msg)


def test_refusal_distinguishes_a_free_threaded_build_with_the_gil_on() raises:
    """3.14t under PYTHON_GIL=1 is a different mistake from 3.13, and the
    message says which one was made."""
    var report = FreeThreadingReport(String("3.14.7"), True, True)
    var msg = refusal_message(2, report)
    assert_true(msg.find("GIL is enabled") >= 0, msg)
    assert_true(msg.find("PYTHON_GIL") >= 0, msg)


def test_asgi_refusal_names_the_build_the_issue_and_the_fix() raises:
    """A free-threaded build cannot host the executor's Python type
    (PyObject layout, upstream); the refusal says so, names the upstream
    issue so the reader can check whether it moved, and names the fix."""
    var report = FreeThreadingReport(String("3.14.7"), True, False)
    var msg = asgi_free_threading_refusal(report)
    assert_true(msg.find("free-threaded CPython build") >= 0, msg)
    assert_true(msg.find("3.14.7t") >= 0, msg)
    assert_true(msg.find(PYOBJECT_LAYOUT_ISSUE) >= 0, msg)
    assert_true(msg.find("modular/modular#5726") >= 0, msg)
    assert_true(msg.find("GIL-enabled CPython") >= 0, msg)
    assert_true(msg.find("--workers") >= 0, msg)
    # Where an agent meets it: uv picked 3.14t for a project with no pin.
    assert_true(msg.find("put 3.13 in .python-version") >= 0, msg)


def test_exit_code_is_sysexits_ex_config() raises:
    assert_equal(EXIT_NOT_FREE_THREADED, 78)


def test_thread_context_round_trip() raises:
    var ctx = ThreadContext(3, 0xDEAD)
    assert_equal(ctx.index, 3)
    assert_equal(ctx.user, 0xDEAD)
    var copied = ctx.copy()
    assert_equal(copied.index, 3)


struct WaitKinds(EventLoopBackend, Movable):
    """A backend that reports no events and records each wait's kind and
    timeout: `wait`'s milliseconds, or `wait_ns`'s nanoseconds."""

    var ms: List[Int]
    var ns: List[Int]

    def __init__(out self):
        self.ms = List[Int]()
        self.ns = List[Int]()

    def wait(mut self, timeout_ms: Int) raises -> Int:
        self.ms.append(timeout_ms)
        return 0

    def wait_ns(mut self, timeout_ns: Int) raises -> Int:
        self.ns.append(timeout_ns)
        return 0

    def event_ident(self, i: Int) -> UInt:
        return 0

    def event_filter(self, i: Int) -> Int16:
        return 0

    def event_flags(self, i: Int) -> UInt16:
        return 0

    def event_data(self, i: Int) -> Int:
        return 0

    def add_read_listen(mut self, fd: Int) raises:
        pass

    def add_read(mut self, fd: Int) raises:
        pass

    def try_add_read(mut self, fd: Int):
        pass

    def add_write_oneshot(mut self, fd: Int) raises:
        pass

    def try_add_write_oneshot(mut self, fd: Int):
        pass

    def try_delete_read(mut self, fd: Int):
        pass

    def try_delete_write(mut self, fd: Int):
        pass

    def try_add_timer(mut self, ident: UInt, timeout_ms: Int):
        pass

    def try_delete_timer(mut self, ident: UInt):
        pass


def test_the_detaching_backend_forwards_a_wait_in_nanoseconds() raises:
    """The offloaded loop of m0serve waits through `DetachingBackend`, so the
    pool's timed look (`wait_ns`, SPEC E37) reaches the kernel only if the
    wrapper forwards it whole: the trait's default would round 10 µs up to
    `wait`'s millisecond, and a WSGI or Mojo mount's fast request behind a
    slow view would wait that millisecond again. Detached, as
    `_serve_offloaded` leaves it, so no interpreter is touched."""
    var backend = DetachingBackend[WaitKinds](WaitKinds())
    backend.set_loop_detached()
    _ = backend.wait_ns(12_345)
    _ = backend.wait(7)
    assert_equal(len(backend.inner.ns), 1, "the nanosecond wait was not forwarded whole")
    assert_equal(backend.inner.ns[0], 12_345)
    assert_equal(len(backend.inner.ms), 1)
    assert_equal(backend.inner.ms[0], 7)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
