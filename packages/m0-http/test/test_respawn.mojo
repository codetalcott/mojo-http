"""WorkerSupervisor respawn, exercised with real forks.

`test_lifecycle.mojo` deliberately never forks: a child that escaped back into
the test runner would re-enter the suite. This file forks anyway, safely, by
running the whole supervisor scenario inside one isolated child process. Every
process in that subtree ends in `process_exit` before it could return into the
suite, and the test process itself only forks once and waits.

The scenario pins the respawn bug this repo shipped with: a respawned child
used to return `True` up through `_supervise` and keep *supervising* instead of
returning to `fork_all`'s caller — so a respawned worker never reached the
server startup path. Reaching the code after `fork_all()` is therefore the
assertion, and a marker file is the proof, because exit codes cannot tell the
two apart: a supervisor that quietly exhausts its respawn budget also exits 0.

Flow inside the isolated process, with one worker:

    fork_all() -> worker #1 returns, sees no crash marker, writes it, exits 9
               -> supervisor sees the crash and respawns
               -> the respawned worker returns from fork_all(), sees the crash
                  marker, writes the OK marker, exits 0
               -> supervisor sees the clean exit and exits 0

The OK marker exists if and only if the respawned worker made it back to the
caller.
"""

from std.os import path, remove
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.multiworker import WorkerSupervisor
from lightbug_http.c.process import (
    fork, process_exit, getpid, waitpid_blocking, was_signaled, exit_code,
)


def _scenario(crash_marker: String, ok_marker: String):
    """Body of the isolated process. Never returns — every path exits."""
    try:
        var supervisor = WorkerSupervisor(1)
        supervisor.fork_all()
        # Only workers reach here; the supervisor exits inside fork_all.
        if path.exists(crash_marker):
            # Second incarnation: we are the respawned worker, back at the
            # caller's "server startup" — the very thing the bug prevented.
            with open(ok_marker, "w") as f:
                f.write(String("respawned worker reached server startup"))
            process_exit(0)
        # First incarnation: leave a trace and crash to force the respawn.
        with open(crash_marker, "w") as f:
            f.write(String("first worker crashed"))
        process_exit(9)
    except:
        process_exit(7)


def test_respawned_worker_returns_to_the_callers_startup_path() raises:
    var crash_marker = String("/tmp/m0_respawn_crash_", getpid())
    var ok_marker = String("/tmp/m0_respawn_ok_", getpid())
    # A stale marker from an interrupted earlier run would fake a pass.
    if path.exists(crash_marker):
        remove(crash_marker)
    if path.exists(ok_marker):
        remove(ok_marker)

    var pid = fork()
    if pid == 0:
        _scenario(crash_marker, ok_marker)
        process_exit(99)  # unreachable: _scenario exits on every path

    var result = waitpid_blocking(pid)
    var status = result[1]
    assert_false(was_signaled(status), "supervisor process died on a signal")
    assert_equal(exit_code(status), 0)
    assert_true(
        path.exists(crash_marker),
        "first worker never ran — the scenario itself is broken",
    )
    assert_true(
        path.exists(ok_marker),
        "respawned worker never returned to fork_all's caller",
    )
    remove(crash_marker)
    remove(ok_marker)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
