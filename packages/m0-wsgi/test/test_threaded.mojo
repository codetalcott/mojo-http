"""Tests for the threaded mode's pure parts.

No interpreter here either, same charter as `test_hold` and `test_cli`:
`refusal_message` and `ThreadContext` are plain values, and the message is
what a user reads when the mode cannot run, so its wording is pinned. What
is NOT reachable here — attaching threads, the detaching backend, the
refusal actually exiting 78 — is `smoke-threads`'s job, which runs the
built binary.

Importing `src.threaded` links `std.python` exactly as `src.app` already
does for `test_hold`; nothing in these tests initializes an interpreter.
"""

from std.testing import assert_equal, assert_true, TestSuite

from src.threaded import (
    asgi_free_threading_refusal,
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


def test_exit_code_is_sysexits_ex_config() raises:
    assert_equal(EXIT_NOT_FREE_THREADED, 78)


def test_thread_context_round_trip() raises:
    var ctx = ThreadContext(3, 0xDEAD)
    assert_equal(ctx.index, 3)
    assert_equal(ctx.user, 0xDEAD)
    var copied = ctx.copy()
    assert_equal(copied.index, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
