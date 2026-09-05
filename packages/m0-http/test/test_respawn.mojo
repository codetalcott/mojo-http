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
    """Declared coverage.

    covers: E2
    """
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


def _hopeless_scenario():
    """A worker that cannot start, ever: crashes immediately every time.

    Five rapid crashes trip the supervisor's breaker. The question is what
    the supervisor then tells the world — and it used to say 0.
    """
    try:
        var supervisor = WorkerSupervisor(1)
        supervisor.fork_all()
        # Every incarnation reaches here and dies at once — the shape of a
        # worker whose first Python call fails (a bad module path, say).
        process_exit(9)
    except:
        process_exit(7)


def test_supervisor_exits_nonzero_when_respawn_budget_is_spent() raises:
    """A supervisor that gave up has not succeeded, and its exit code says so.

    Pinned because `m0serve --workers N` with a mistyped `module:attr` is
    exactly this scenario, and a CLI that exits 0 after failing to load the
    application misreports to everything that launches it.

    covers: E3
    """
    var pid = fork()
    if pid == 0:
        _hopeless_scenario()
        process_exit(99)  # unreachable

    var result = waitpid_blocking(pid)
    var status = result[1]
    assert_false(was_signaled(status), "supervisor process died on a signal")
    assert_equal(exit_code(status), 1)


def _refusing_scenario(first_marker: String, again_marker: String):
    """Every incarnation exits 78 -- the shape of a worker refusing a mode
    its interpreter cannot run. A second incarnation would mean a respawn
    happened, and it leaves a marker saying so."""
    try:
        var supervisor = WorkerSupervisor(1)
        supervisor.fork_all()
        if path.exists(first_marker):
            with open(again_marker, "w") as f:
                f.write(String("a refusing worker was respawned"))
            process_exit(78)
        with open(first_marker, "w") as f:
            f.write(String("first refusal"))
        process_exit(78)
    except:
        process_exit(7)


def test_a_worker_refusing_its_configuration_is_not_respawned() raises:
    """Exit 78 (EX_CONFIG) from a worker is a refusal the next incarnation
    would repeat -- an ASGI app on a free-threaded interpreter, say -- so
    the supervisor must not respawn it, and must exit 78 itself rather
    than reporting ten crashes and a 1. Pinned because a refusal made
    post-fork (protocol detection can only happen in the worker) used to
    read as a respawn loop.

    covers: E10
    """
    var first = "/tmp/m0_refuse_first_" + String(getpid())
    var again = "/tmp/m0_refuse_again_" + String(getpid())
    for m in [first, again]:
        if path.exists(m):
            remove(m)
    var pid = fork()
    if pid == 0:
        _refusing_scenario(first, again)
        process_exit(99)  # unreachable
    var result = waitpid_blocking(pid)
    var status = result[1]
    assert_false(was_signaled(status), "supervisor process died on a signal")
    assert_equal(exit_code(status), 78)
    assert_true(path.exists(first), "the worker never ran")
    assert_false(path.exists(again), "the refusing worker was respawned")
    for m in [first, again]:
        if path.exists(m):
            remove(m)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


# --- spawned workers -------------------------------------------------------
#
# Under `enable_spawn` a child is forked and at once execs the given path, so
# what returns to the caller is never a worker: the scenario's own code after
# `fork_all` runs only in the supervisor, which exits inside `fork_all`. The
# worker is `/bin/sh -c ...`, which can read its environment and leave
# markers exactly as a Mojo worker would, without re-entering this suite.


def _spawn_scenario(script: String, workers: Int, exe: String):
    try:
        var supervisor = WorkerSupervisor(workers)
        var args = List[String]()
        args.append(String("sh"))
        args.append(String("-c"))
        args.append(script)
        supervisor.enable_spawn(exe, args^)
        supervisor.fork_all()
        # Unreachable: every child exec'd, and the parent exits in fork_all.
        process_exit(7)
    except:
        process_exit(7)


def test_spawned_workers_run_the_exec_image_with_their_index() raises:
    """Each spawned worker is a fresh image that knows its index.

    The worker here is the shell, and it exits 0 only if the supervisor put
    `M0_WORKER_SPAWNED=1` and a numeric `M0_WORKER_INDEX` in its
    environment before the exec; two workers must see two different
    indices, which the marker files prove. A supervisor whose workers all
    exit 0 exits 0.

    covers: E15
    """
    var tag = String(getpid())
    var m0 = "/tmp/m0_spawn_idx0_" + tag
    var m1 = "/tmp/m0_spawn_idx1_" + tag
    for m in [m0, m1]:
        if path.exists(m):
            remove(m)
    var script = (
        String('[ "$M0_WORKER_SPAWNED" = 1 ] || exit 9; ')
        + 'case "$M0_WORKER_INDEX" in 0) touch ' + m0 + ';; 1) touch ' + m1
        + ';; *) exit 9;; esac; exit 0'
    )
    var pid = fork()
    if pid == 0:
        _spawn_scenario(script, 2, String("/bin/sh"))
        process_exit(99)
    var result = waitpid_blocking(pid)
    assert_false(was_signaled(result[1]), "supervisor died on a signal")
    assert_equal(exit_code(result[1]), 0)
    assert_true(path.exists(m0), "worker 0 never ran the exec image with its index")
    assert_true(path.exists(m1), "worker 1 never ran the exec image with its index")
    remove(m0)
    remove(m1)


def test_a_crashed_spawned_worker_is_respawned_through_exec() raises:
    """A respawn under spawn mode is a fresh exec too.

    First incarnation: no marker, leave one, exit 9 (a crash). The
    supervisor respawns index 0, and the replacement -- which must again be
    the exec image, not a forked copy of the supervisor -- sees the marker
    and exits 0, leaving a second marker. The supervisor then exits 0.

    covers: E15
    """
    var tag = String(getpid())
    var first = "/tmp/m0_spawn_first_" + tag
    var again = "/tmp/m0_spawn_again_" + tag
    for m in [first, again]:
        if path.exists(m):
            remove(m)
    var script = (
        String('if [ -e ') + first + ' ]; then [ "$M0_WORKER_INDEX" = 0 ] || exit 9; touch '
        + again + '; exit 0; fi; touch ' + first + '; exit 9'
    )
    var pid = fork()
    if pid == 0:
        _spawn_scenario(script, 1, String("/bin/sh"))
        process_exit(99)
    var result = waitpid_blocking(pid)
    assert_false(was_signaled(result[1]), "supervisor died on a signal")
    assert_equal(exit_code(result[1]), 0)
    assert_true(path.exists(again), "the respawned worker was not a fresh exec image")
    remove(first)
    remove(again)


def test_a_spawn_that_cannot_exec_is_a_refusal_not_a_crash_loop() raises:
    """An image that cannot load would fail on every respawn, so the child
    exits EX_CONFIG and the supervisor stops at once with 78 (E10's path),
    rather than spending its budget on ten identical failures.

    covers: E15
    """
    var pid = fork()
    if pid == 0:
        _spawn_scenario(String("exit 0"), 1, String("/nonexistent/m0serve"))
        process_exit(99)
    var result = waitpid_blocking(pid)
    assert_false(was_signaled(result[1]), "supervisor died on a signal")
    assert_equal(exit_code(result[1]), 78)
