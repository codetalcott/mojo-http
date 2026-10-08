"""The process and pipe calls at their edges (`c/process.mojo`, `c/pipe.mojo`).

`test_respawn.mojo` drives `fork`, `waitpid_blocking`, `process_exit`,
`kill_process` and the status readers through a supervisor's real forks,
and `test_lifecycle.mojo` and `test_cloexec.mojo` the shutdown pipe a
server makes. This holds what those runs never reach: the status words a
crash, a core dump or an exit code at its limit leaves, and each call's
answer when it cannot do what it was asked.

A failure is provoked in a child of the test's own -- under a descriptor
limit, under a process limit, with no child of its own to wait for -- and
reported by the child's exit code, so nothing the provoking does reaches
the suite's process. Every child ends in `process_exit` on every path, as
`test_respawn.mojo`'s do, so none can return into the test runner.
"""

from std.ffi import c_int, external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import sleep

from lightbug_http.c.pipe import create_shutdown_pipe
from lightbug_http.c.process import (
    SIGKILL, exit_code, fork, kill_process, process_exit, term_signal,
    waitpid_blocking, waitpid_nonblocking, was_signaled,
)


comptime _RLIMIT_NOFILE = 8 if CompilationTarget.is_macos() else 7
comptime _RLIMIT_NPROC = 7 if CompilationTarget.is_macos() else 6
comptime _NO_SUCH_PID = 0x7FFFFFF0
"""A pid no process has: above macOS's 99998 and Linux's `pid_max` cap of
2^22."""


def _set_soft_limit(resource: Int, value: Int) -> Bool:
    """Lower this process's soft limit on `resource` to `value`."""
    var lim = Array[UInt64, 2](fill=UInt64(0))
    comptime LimPtr = type_of(Pointer(to=lim[0]))
    if external_call["getrlimit", c_int, c_int, LimPtr](
        c_int(resource), Pointer(to=lim[0])
    ) != 0:
        return False
    lim[0] = UInt64(value)
    return external_call["setrlimit", c_int, c_int, LimPtr](
        c_int(resource), Pointer(to=lim[0])
    ) == 0


def test_a_wait_status_is_read_as_posix_lays_it_out() raises:
    """The exit code is bits 8-15, a signal bits 0-6, and bit 7 says a core
    was dumped, on macOS and Linux alike: a worker that exited 255 is not
    signalled, and one that died of SIGSEGV leaving a core is signal 11,
    not 139. Then the same reading of what `waitpid` hands back on this OS
    for a child that exited 255 and one SIGKILL ended.

    covers: E40
    """
    assert_false(was_signaled(0))
    assert_equal(exit_code(0), 0)
    assert_false(was_signaled(0x0100))
    assert_equal(exit_code(0x0100), 1)
    assert_equal(exit_code(0x4E00), 78)
    assert_false(was_signaled(0xFF00))
    assert_equal(exit_code(0xFF00), 255)
    assert_true(was_signaled(0x0009))
    assert_equal(term_signal(0x0009), 9)
    assert_true(was_signaled(0x008B), "a SIGSEGV that dumped a core")
    assert_equal(term_signal(0x008B), 11)

    var exiting = fork()
    if exiting == 0:
        process_exit(255)
    var exited = waitpid_blocking(exiting)
    assert_equal(exited[0], exiting)
    assert_false(was_signaled(exited[1]))
    assert_equal(exit_code(exited[1]), 255)

    var killed = fork()
    if killed == 0:
        sleep(30.0)
        process_exit(0)
    assert_true(kill_process(killed, SIGKILL))
    var reaped = waitpid_blocking(killed)
    assert_equal(reaped[0], killed)
    assert_true(was_signaled(reaped[1]))
    assert_equal(term_signal(reaped[1]), SIGKILL)


def _process_failures_scenario():
    """In a child: each process call where it cannot do what it was asked,
    one exit-code bit per answer that was wrong, 0 when every one was
    right. Never returns."""
    var wrong = 0
    try:
        # No child at all: the poller's "nothing left to wait for", and the
        # blocking wait's raise.
        try:
            var none = waitpid_nonblocking()
            if none[0] != -1 or none[1] != 0:
                wrong |= 1
        except:
            wrong |= 1
        var raised = False
        try:
            _ = waitpid_blocking(-1)
        except e:
            raised = String(e).find("waitpid() failed") >= 0
        if not raised:
            wrong |= 2
        # A child that has not exited: the poller answers (0, 0).
        var child = fork()
        if child == 0:
            sleep(30.0)
            process_exit(0)
        var running = waitpid_nonblocking()
        if running[0] != 0 or running[1] != 0:
            wrong |= 4
        _ = kill_process(child, SIGKILL)
        _ = waitpid_blocking(child)
        # A signal for a process that does not exist is refused, not sent.
        if kill_process(_NO_SUCH_PID, 0):
            wrong |= 8
        # `fork` at the process limit raises. Root is exempt from the
        # limit on Linux, so there the check is skipped.
        if Int(external_call["geteuid", UInt32]()) != 0:
            if not _set_soft_limit(_RLIMIT_NPROC, 0):
                wrong |= 16
            else:
                var refused = False
                try:
                    var grandchild = fork()
                    if grandchild == 0:
                        process_exit(0)
                    _ = waitpid_blocking(grandchild)
                except e:
                    refused = String(e).find("fork() failed") >= 0
                if not refused:
                    wrong |= 32
        process_exit(wrong)
    except:
        process_exit(64)


def test_each_process_call_answers_what_it_cannot_do() raises:
    """With no child, `waitpid_nonblocking` answers (-1, 0) and
    `waitpid_blocking` raises; with a child still running the poller
    answers (0, 0); `kill_process` answers False for a pid that names no
    process; and `fork` raises at the process limit -- each in a child, so
    the suite's process keeps its own children and limits.

    covers: E40
    """
    var pid = fork()
    if pid == 0:
        _process_failures_scenario()
        process_exit(99)  # unreachable: the scenario exits on every path
    var result = waitpid_blocking(pid)
    assert_false(was_signaled(result[1]), "the child died on a signal")
    var wrong = exit_code(result[1])
    assert_equal(wrong & 1, 0, "waitpid_nonblocking with no child did not answer (-1, 0), or raised")
    assert_equal(wrong & 2, 0, "waitpid_blocking with no child did not raise")
    assert_equal(wrong & 4, 0, "waitpid_nonblocking beside a running child did not answer (0, 0)")
    assert_equal(wrong & 8, 0, "kill_process answered True for a pid that names no process")
    assert_equal(wrong & 16, 0, "the child could not lower its process limit")
    assert_equal(wrong & 32, 0, "fork at the process limit did not raise")
    assert_equal(wrong, 0, "the scenario itself raised")


def _pipe_at_the_descriptor_limit_scenario():
    """In a child: `create_shutdown_pipe` once no descriptor is free.
    Exits 0 when it raised naming `pipe()`. Never returns."""
    if not _set_soft_limit(_RLIMIT_NOFILE, 3):
        process_exit(2)
    try:
        _ = create_shutdown_pipe()
        process_exit(1)
    except e:
        process_exit(0 if String(e).find("pipe() failed") >= 0 else 3)


def test_a_shutdown_pipe_past_the_descriptor_limit_is_refused() raises:
    """`create_shutdown_pipe` raises when the process has no descriptor to
    give it (EMFILE), rather than handing back a number it never got; in a
    child whose soft limit is lowered below the descriptors it holds.

    covers: E40
    """
    var pid = fork()
    if pid == 0:
        _pipe_at_the_descriptor_limit_scenario()
        process_exit(99)  # unreachable: the scenario exits on every path
    var result = waitpid_blocking(pid)
    assert_false(was_signaled(result[1]), "the child died on a signal")
    var code = exit_code(result[1])
    assert_true(code != 1, "a shutdown pipe was made past the descriptor limit")
    assert_true(code != 2, "the child could not lower its descriptor limit")
    assert_equal(code, 0, "the refusal did not name pipe()")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
