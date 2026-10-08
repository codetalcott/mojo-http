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

from std.ffi import external_call
from std.os import makedirs, path, remove, rmdir, setenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from src.multiworker import SharedAtomics, WorkerSupervisor, _forget_supervisor_signals
from src.global_slot import record_supervisor_stop
from src.signal import install_shutdown_signals
from src.threads import _OpaqueMut, read_one_byte_blocking
from lightbug_http.accept_share import (
    ACCEPT_SHARE_FIRST_WORKER_SLOT, ACCEPT_SHARE_WORKER_STRIDE, AcceptShare,
    STATE_LEFT, STATE_PARKED, accept_share_slots,
)
from lightbug_http.c.fdpass import send_fd
from lightbug_http.c.fcntl import set_nonblocking
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.process import (
    fork, process_exit, getpid, waitpid_blocking, waitpid_nonblocking,
    was_signaled, term_signal, exit_code, kill_process, SIGTERM, SIGKILL,
    executable_path, path_from_bytes,
)
from lightbug_http.c.socketpair import socketpair_dgram


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


# --- The respawn budget is a rate (SPEC E36) ----------------------------------
#
# `max_respawns` used to be compared against a count of every respawn in the
# supervisor's life, so a server whose workers crashed rarely stopped
# replacing them after `workers * 10` crashes, however far apart. It is now
# counted over `respawn_window_ns`, an hour, which the first test sets short.
# The crashes are spaced past the rapid-crash breaker's second, so neither
# test is about the breaker.


comptime _SPACED_CRASH_LIFE_S = 1.1
"""How long each crashing incarnation serves before it crashes: past the
rapid-crash breaker's second, so every crash is an ordinary one."""


def _spaced_crash_scenario(budget: Int, window_ns: Int, crashes: Int, tag: String):
    """One worker whose first `crashes` incarnations each serve for
    `_SPACED_CRASH_LIFE_S` and crash (exit 9); the next leaves the `ok`
    marker and exits 0. `budget` respawns are allowed in any `window_ns`,
    or in the supervisor's own window when `window_ns` is 0."""
    try:
        var supervisor = WorkerSupervisor(1)
        supervisor.max_respawns = budget
        if window_ns > 0:
            supervisor.respawn_window_ns = window_ns
        supervisor.fork_all()
        var k = 0
        while path.exists(tag + String(k)):
            k += 1
        if k >= crashes:
            with open(tag + "ok", "w") as f:
                f.write(String("the incarnation after the last crash started"))
            process_exit(0)
        with open(tag + String(k), "w") as f:
            f.write(String("crashing"))
        sleep(_SPACED_CRASH_LIFE_S)
        process_exit(9)
    except:
        process_exit(7)


def _spaced_crashes(
    budget: Int, window_ns: Int, crashes: Int
) raises -> Tuple[Int, Int, Bool]:
    """Run the scenario and answer the supervisor's exit code, how many
    incarnations crashed, and whether one started after the last crash."""
    var tag = "/tmp/m0_spaced_" + String(getpid()) + "_"
    var markers = List[String]()
    markers.append(tag + "ok")
    for k in range(crashes + 1):
        markers.append(tag + String(k))
    for m in markers:
        if path.exists(m):
            remove(m)
    var pid = fork()
    if pid == 0:
        _spaced_crash_scenario(budget, window_ns, crashes, tag)
        process_exit(99)  # unreachable
    var result = waitpid_blocking(pid)
    var crashed = 0
    while path.exists(tag + String(crashed)):
        crashed += 1
    var started = path.exists(tag + "ok")
    for m in markers:
        if path.exists(m):
            remove(m)
    assert_false(was_signaled(result[1]), "supervisor process died on a signal")
    return (exit_code(result[1]), crashed, started)


def test_a_budget_spent_over_a_longer_window_is_not_spent() raises:
    """Crashes rarer than the budget's rate are replaced however many there
    have been: two respawns allowed in any 1.5 s, and three crashes 1.1 s
    apart, so the window never holds more than one respawn when the next
    crash comes. The third crash is replaced and the supervisor exits 0.
    Counted over the supervisor's life, the budget ran out at the third:
    `max respawns (2) reached, not respawning`, and an exit 1 (measured).

    covers: E36
    """
    var got = _spaced_crashes(budget=2, window_ns=1_500_000_000, crashes=3)
    assert_equal(got[1], 3, "the scenario did not crash three times")
    assert_true(got[2], "the worker was not replaced after its third crash")
    assert_equal(got[0], 0)


def test_a_budget_spent_inside_the_window_is_spent() raises:
    """The same three crashes inside the supervisor's own window, an hour:
    the third finds two respawns already in it, is not replaced, and the
    supervisor exits 1, as it did for a budget counted over its life. A
    rate still ends a crash loop the rapid-crash breaker cannot see.

    covers: E36
    """
    var got = _spaced_crashes(budget=2, window_ns=0, crashes=3)
    assert_equal(got[1], 3, "the scenario did not crash three times")
    assert_false(got[2], "the worker was replaced with its budget spent")
    assert_equal(got[0], 1)


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


def _stopping_scenario(ready_marker: String, again_marker: String):
    """One worker that drains badly: on the forwarded SIGTERM it exits 9.

    A second incarnation would be a respawn during the shutdown; it leaves a
    marker and exits 0, so the supervisor would then exit 0 as well.
    """
    try:
        var supervisor = WorkerSupervisor(1)
        supervisor.fork_all()
        if path.exists(ready_marker):
            with open(again_marker, "w") as f:
                f.write(String("respawned while the supervisor was stopping"))
            process_exit(0)
        var fd = install_shutdown_signals()
        with open(ready_marker, "w") as f:
            f.write(String("armed"))
        _ = read_one_byte_blocking(fd)
        process_exit(9)
    except:
        process_exit(7)


def test_a_worker_that_fails_while_stopping_is_not_respawned() raises:
    """SIGTERM to the supervisor alone, and the worker fails its drain.

    The supervisor forwards the signal (what `docker stop` relies on), the
    worker exits 9 instead of 0, and the supervisor must let it go and exit
    1 -- not respawn it. A respawned worker is sent no signal, so the
    supervisor served it for good and SIGTERM ended only in SIGKILL; found
    when a sabotaged Mojo host worker crashed on its way out.

    covers: D10
    """
    var ready = "/tmp/m0_stopping_ready_" + String(getpid())
    var again = "/tmp/m0_stopping_again_" + String(getpid())
    for m in [ready, again]:
        if path.exists(m):
            remove(m)
    var pid = fork()
    if pid == 0:
        _stopping_scenario(ready, again)
        process_exit(99)  # unreachable
    var waited = 0
    while not path.exists(ready) and waited < 500:
        sleep(0.01)
        waited += 1
    assert_true(path.exists(ready), "the worker never armed its shutdown")
    # The supervisor armed its forwarding handler before it forked the
    # worker (B21), so the worker's marker is the only wait there is.
    _ = kill_process(pid, SIGTERM)
    var result = waitpid_blocking(pid)
    var status = result[1]
    assert_false(was_signaled(status), "supervisor process died on the signal")
    assert_false(path.exists(again), "the worker was respawned during the shutdown")
    assert_equal(exit_code(status), 1)
    for m in [ready, again]:
        if path.exists(m):
            remove(m)


def _refusing_sibling_scenario(outlived_marker: String):
    """Two workers: worker 0 refuses at once with 78, worker 1 serves with the
    default signal disposition, and leaves a marker if it is still alive
    three seconds later -- the supervisor having let it serve a host missing
    the worker that refused."""
    try:
        var supervisor = WorkerSupervisor(2)
        supervisor.fork_all()
        if supervisor.worker_index == 0:
            process_exit(78)
        sleep(3.0)
        with open(outlived_marker, "w") as f:
            f.write(String("the sibling outlived the refusal"))
        process_exit(5)
    except:
        process_exit(7)


def test_a_refusal_by_one_worker_ends_its_siblings() raises:
    """One worker's exit 78 ends supervision for all of them: the siblings
    are sent SIGTERM and the supervisor exits 78 once they are gone. Left
    serving, they were a server missing the worker that refused -- the
    Mojo host's producer runs on worker 0 alone, and a producer whose
    `make` raised left worker 1 answering requests with no producer
    anywhere, for good.

    covers: E25
    """
    var outlived = "/tmp/m0_refuse_sibling_" + String(getpid())
    if path.exists(outlived):
        remove(outlived)
    var pid = fork()
    if pid == 0:
        _refusing_sibling_scenario(outlived)
        process_exit(99)  # unreachable
    var result = waitpid_blocking(pid)
    var status = result[1]
    assert_false(was_signaled(status), "supervisor process died on a signal")
    assert_equal(exit_code(status), 78)
    assert_false(path.exists(outlived), "the sibling was left serving after the refusal")
    if path.exists(outlived):
        remove(outlived)


# --- A stop while the supervisor forks (B21) ---------------------------------
#
# The supervisor arms its handler before its first fork, so every worker
# inherits it until `_forget_supervisor_signals`, and a stop can land between
# a fork and the publish of its PID. `smoke-shutdown` signals a supervisor
# held between two forks; these two pin the rules for the moments too short
# to hit from outside.


def _inherited_stop_scenario():
    """The isolated process plays a supervisor that has armed and published,
    as `fork_all` does before its first fork, with a stand-in sibling in its
    list. Its worker is signalled before it reaches
    `_forget_supervisor_signals`, where a SIGTERM forwarded to a worker forked
    a moment before lands, so the handler it inherited runs in it. Exits 0
    when the worker left with 0 and the sibling was not signalled, 3 when the
    worker served on, 4 when the worker passed the signal to the sibling."""
    try:
        var sibling = fork()
        if sibling == 0:
            sleep(10.0)
            process_exit(0)
        var supervisor = WorkerSupervisor(2)
        supervisor.child_pids.append(sibling)
        supervisor._arm_signal_propagation()
        var worker = fork()
        if worker == 0:
            _ = kill_process(getpid(), SIGTERM)
            _forget_supervisor_signals()
            process_exit(3)  # served on: the stop was swallowed
        var w = waitpid_blocking(worker)
        # A signal the worker sent the sibling has ended it by now.
        sleep(0.2)
        var s = waitpid_nonblocking()
        _ = kill_process(sibling, SIGKILL)
        if s[0] == 0:
            _ = waitpid_blocking(sibling)
        if was_signaled(w[1]) or exit_code(w[1]) != 0:
            process_exit(3)
        if s[0] == sibling:
            process_exit(4)
        process_exit(0)
    except:
        process_exit(7)


def test_a_worker_signalled_before_it_resets_leaves_and_signals_no_sibling() raises:
    """A worker the stop reaches before it restores its own signals leaves.

    The handler it inherited catches the signal, so without the rule the
    worker went on to serve with the stop swallowed, and a supervisor
    waiting for it never exits. And a worker must never act as the
    supervisor: the list its handler would read is its parent's.

    covers: D2
    """
    var pid = fork()
    if pid == 0:
        _inherited_stop_scenario()
        process_exit(99)  # unreachable
    var result = waitpid_blocking(pid)
    var status = result[1]
    assert_false(was_signaled(status), "the stand-in supervisor died on a signal")
    var code = exit_code(status)
    assert_true(code != 3, "a worker stopped before it reset its signals served on")
    assert_true(code != 4, "a worker's inherited handler signalled a sibling")
    assert_equal(code, 0)


def _catch_up_scenario():
    """A stop the handler recorded while a just-forked child's PID was not
    yet published. The child keeps the default disposition, so the SIGTERM
    the publish must send ends it; without one it sleeps out and exits 0.
    Exits 0 when the child was signalled, 5 when it was not."""
    try:
        var child = fork()
        if child == 0:
            sleep(5.0)
            process_exit(0)
        var supervisor = WorkerSupervisor(1)
        record_supervisor_stop(SIGTERM)
        supervisor.child_pids.append(child)
        supervisor._publish_children()
        var r = waitpid_blocking(child)
        if was_signaled(r[1]) and term_signal(r[1]) == SIGTERM:
            process_exit(0)
        process_exit(5)
    except:
        process_exit(7)


def test_a_stop_before_a_pid_is_published_still_reaches_that_child() raises:
    """The handler signals the PIDs published when it runs, so a stop that
    lands between a fork and the publish of its PID reaches that child only
    because the publish passes it on.

    covers: D2
    """
    var pid = fork()
    if pid == 0:
        _catch_up_scenario()
        process_exit(99)  # unreachable
    var result = waitpid_blocking(pid)
    var status = result[1]
    assert_false(was_signaled(status), "the stand-in supervisor died on a signal")
    assert_equal(
        exit_code(status), 0, "a stop recorded before the publish never reached the child"
    )


# --- A stop that reaches a worker before it arms (S1) -------------------------
#
# A worker is at SIGTERM's default action from `_forget_supervisor_signals`
# until its caller arms its own handler, so a stop that reaches it there kills
# it. When that death was the first the supervisor reaped, it passed the signal
# on and reaped the rest blind: a sibling that then failed its drain went
# unreported and the supervisor exited 0, against D10. CI's `smoke-shutdown`
# signalled into that window once (train 22). Worker 1 here waits a second on
# the byte before it leaves, so worker 0's death is the first reaped.


def _unarmed_sibling_scenario(
    ready0: String, ready1: String, drain_exit: Int, reload_dir: String
):
    """Two workers. Worker 0 never arms, so the forwarded SIGTERM kills it;
    worker 1 arms, and a second after the byte leaves with `drain_exit`, or
    by SIGKILL when that is -1. A `reload_dir` supervises by polling, which is
    `--reload`'s loop."""
    try:
        var supervisor = WorkerSupervisor(2)
        if reload_dir.byte_length() > 0:
            supervisor.enable_reload([reload_dir], String(".m0-never"))
        supervisor.fork_all()
        if supervisor.worker_index == 0:
            with open(ready0, "w") as f:
                f.write(String("unarmed"))
            sleep(10.0)
            process_exit(0)
        var fd = install_shutdown_signals()
        with open(ready1, "w") as f:
            f.write(String("armed"))
        _ = read_one_byte_blocking(fd)
        # A deadline, not one `sleep`: the signal passed on again after
        # worker 0's death interrupts a sleep, and this wait is what makes
        # that death the first reaped.
        var until = perf_counter_ns() + 1_000_000_000
        while perf_counter_ns() < until:
            sleep(0.05)
        if drain_exit < 0:
            _ = kill_process(getpid(), SIGKILL)
        process_exit(drain_exit)
    except:
        process_exit(7)


def _stop_beside_an_unarmed_worker(drain_exit: Int, polling: Bool) raises -> Int:
    """Run the scenario, signal its supervisor alone once both workers are
    ready, and answer the supervisor's exit code."""
    var tag = String(getpid())
    var ready0 = "/tmp/m0_unarmed_ready0_" + tag
    var ready1 = "/tmp/m0_unarmed_ready1_" + tag
    var dir = String("")
    if polling:
        dir = "/tmp/m0_unarmed_reload_" + tag
        makedirs(dir, exist_ok=True)
    for m in [ready0, ready1]:
        if path.exists(m):
            remove(m)
    var pid = fork()
    if pid == 0:
        _unarmed_sibling_scenario(ready0, ready1, drain_exit, dir)
        process_exit(99)  # unreachable
    var waited = 0
    while not (path.exists(ready0) and path.exists(ready1)) and waited < 500:
        sleep(0.01)
        waited += 1
    var ready = path.exists(ready0) and path.exists(ready1)
    _ = kill_process(pid, SIGTERM)
    var result = waitpid_blocking(pid)
    for m in [ready0, ready1]:
        if path.exists(m):
            remove(m)
    if polling:
        rmdir(dir)
    assert_true(ready, "the workers never came up")
    assert_false(was_signaled(result[1]), "the supervisor died on the signal")
    return exit_code(result[1])


def test_a_sibling_failing_its_drain_after_an_unarmed_death_makes_the_exit_1() raises:
    """The first worker reaped died of the forwarded SIGTERM before it armed,
    and its sibling then fails its drain (exit 9). The supervisor must judge
    that sibling as it judges any worker failing a drain, and exit 1; it used
    to reap it without a look and exit 0.

    covers: D10
    """
    assert_equal(_stop_beside_an_unarmed_worker(9, polling=False), 1)


def test_an_unarmed_death_beside_a_clean_drain_is_a_clean_stop() raises:
    """A worker killed by the SIGTERM it was forwarded, before it armed its
    handler, is a stop and not a failure: it had started no loop, and a
    worker that has armed catches the signal, so the death names exactly that
    case. Beside a sibling that drains and exits 0, the supervisor exits 0.

    covers: D2
    """
    assert_equal(_stop_beside_an_unarmed_worker(0, polling=False), 0)


def test_the_polling_supervisor_judges_the_rest_after_an_unarmed_death() raises:
    """`--reload`'s supervisor reaps the same way: after an unarmed worker's
    death it passed the signal on and reaped the rest blind, so a sibling
    killed by SIGKILL in its drain went unseen and the exit was 0. It is 1.

    covers: D10
    """
    assert_equal(_stop_beside_an_unarmed_worker(-1, polling=True), 1)


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


def test_a_path_above_ascii_keeps_its_bytes_for_the_exec() raises:
    """The spawn re-execs `executable_path()`, and a path is bytes: the
    String it is built from must hold exactly the bytes the OS returned.
    `chr()` per byte re-encoded each one at or above 0x80, so a binary
    under `/Users/josé/` answered `josÃ©`, which names no file. The bytes
    here are that `é` in UTF-8 and a 0xFF that is not UTF-8 at all, as a
    Linux path may hold; and `executable_path()` itself still answers the
    running image.

    covers: E35
    """
    var raw = List[UInt8](String("/Users/jos").as_bytes())
    raw.append(0xC3)
    raw.append(0xA9)
    raw.extend(String("/d").as_bytes())
    raw.append(0xFF)
    raw.extend(String("/m0serve").as_bytes())
    var got = path_from_bytes(Span(raw))
    var bytes = got.as_bytes()
    assert_equal(len(bytes), len(raw), "the path's length changed on the way")
    for i in range(len(raw)):
        assert_equal(Int(bytes[i]), Int(raw[i]), String("byte ", i, " changed"))
    assert_true(path.exists(executable_path()), "executable_path() names no file")


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


def test_a_spawned_worker_inherits_exactly_the_exported_descriptors() raises:
    """The spawn keeps what the new image adopts, and nothing else (SPEC G16).

    Every descriptor is close-on-exec from birth, so a child the application
    starts inherits none of the server's. The spawn's own exec is the one
    that must keep some: those the environment names -- here the bus's two
    ends -- and only those. The worker is the shell, and it exits 0 only if
    both exported ends are open in it and an unexported one is not.

    covers: E15
    """
    var exported = socketpair_dgram()
    var hidden = socketpair_dgram()
    _ = setenv("M0_BUS_READ_FDS", String(exported[0]), True)
    _ = setenv("M0_BUS_WRITE_FDS", String(exported[1]), True)
    var script = (
        String("[ -e /dev/fd/") + String(exported[0]) + " ] && [ -e /dev/fd/"
        + String(exported[1]) + " ] && ! [ -e /dev/fd/" + String(hidden[0])
        + " ] || exit 9; exit 0"
    )
    var pid = fork()
    if pid == 0:
        _spawn_scenario(script, 1, String("/bin/sh"))
        process_exit(99)
    var result = waitpid_blocking(pid)
    _ = setenv("M0_BUS_READ_FDS", String(""), True)
    _ = setenv("M0_BUS_WRITE_FDS", String(""), True)
    for fd in [exported[0], exported[1], hidden[0], hidden[1]]:
        close_fd(fd)
    assert_false(was_signaled(result[1]), "supervisor died on a signal")
    assert_equal(
        exit_code(result[1]), 0,
        "the spawned image did not hold exactly the exported descriptors",
    )


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


# --- A worker reaped and not replaced (review RP) ----------------------------
#
# Accept sharing reads each worker's `state` word off the pre-fork page, and a
# worker that dies writes it no more: killed while parked, it read as parked
# with no load, and `pick` handed it connections nothing would read when no
# replacement followed. The supervisor marks every index it reaps left
# (`share_accepts`, `_remove_pid`). The page here is the test's own, made
# before the isolated supervisor is forked, so the test reads the supervisor's
# marks directly -- while worker 0, which the mark must not touch, lives on.


def _state_slot(worker: Int) -> Int:
    """The slot of worker `worker`'s `state` word (`accept_share.mojo`)."""
    return ACCEPT_SHARE_FIRST_WORKER_SLOT + ACCEPT_SHARE_WORKER_STRIDE * worker


def _pending_slot(worker: Int) -> Int:
    """The slot of worker `worker`'s `pending` word (`accept_share.mojo`)."""
    return _state_slot(worker) + 2


def _reaped_scenario(
    page_addr: Int, share: AcceptShare, exit_with: Int, budget: Int,
    reload_dir: String, ready: String, again: String, go: String,
):
    """Two workers over one accept-share page, each parked as a started
    loop is. Worker 1 leaves `ready` and exits with `exit_with` at once,
    with `budget` respawns allowed; a replacement leaves `again` once
    parked and waits as worker 0 does. Worker 0 waits for `go`, then exits
    0. A `reload_dir` supervises by polling, `--reload`'s loop."""
    try:
        var supervisor = WorkerSupervisor(2)
        supervisor.max_respawns = budget
        if reload_dir.byte_length() > 0:
            supervisor.enable_reload([reload_dir], String(".m0-never"))
        supervisor.share_accepts(share, page_addr)
        supervisor.fork_all()
        var mine = share.copy()
        mine.bind(supervisor.worker_index, page_addr)
        mine.start()
        if supervisor.worker_index == 1:
            if path.exists(ready):
                with open(again, "w") as f:
                    f.write(String("replaced, parked"))
            else:
                with open(ready, "w") as f:
                    f.write(String("parked"))
                process_exit(exit_with)
        var waited = 0
        while not path.exists(go) and waited < 1000:
            sleep(0.01)
            waited += 1
        process_exit(0)
    except:
        process_exit(7)


def _reap_worker_1(
    exit_with: Int, budget: Int, polling: Bool, replaced: Bool = False
) raises -> List[Int]:
    """Run the scenario and answer, read while worker 0 still lives: worker
    1's `state`, worker 0's, and where worker 0 would send a connection
    while it holds fifty; then the supervisor's exit code. `replaced`: the
    reads wait for worker 1's replacement to park, not for the mark."""
    var tag = String(getpid())
    var ready = "/tmp/m0_reaped_ready_" + tag
    var again = "/tmp/m0_reaped_again_" + tag
    var go = "/tmp/m0_reaped_go_" + tag
    var dir = String("")
    if polling:
        dir = "/tmp/m0_reaped_reload_" + tag
        makedirs(dir, exist_ok=True)
    for m in [ready, again, go]:
        if path.exists(m):
            remove(m)
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var pid = fork()
    if pid == 0:
        _reaped_scenario(
            page.addr(0), share, exit_with, budget, dir, ready, again, go
        )
        process_exit(99)  # unreachable
    # The reap follows the death at once, and under polling within the
    # interval; 5 s is a bound, never a wait on the good path.
    var waited = 0
    while waited < 500:
        if replaced and path.exists(again):
            break
        if not replaced and path.exists(ready) and page.load(_state_slot(1)) == STATE_LEFT:
            break
        sleep(0.01)
        waited += 1
    var dead = page.load(_state_slot(1))
    var live = page.load(_state_slot(0))
    # Worker 0's view, fifty connections open: it keeps the next one unless
    # a sibling is willing and lighter.
    var view = share.copy()
    view.bind(0, page.addr(0))
    view.start()
    var picked = view.pick(50, perf_counter_ns())
    with open(go, "w") as f:
        f.write(String("go"))
    var result = waitpid_blocking(pid)
    var readied = path.exists(ready)
    var replacement = path.exists(again)
    for m in [ready, again, go]:
        if path.exists(m):
            remove(m)
    if polling:
        rmdir(dir)
    for fd in share.read_fds:
        close_fd(fd)
    for fd in share.write_fds:
        close_fd(fd)
    for fd in share.anchor_fds:
        close_fd(fd)
    assert_true(readied, "worker 1 never parked: the scenario itself is broken")
    assert_equal(replacement, replaced, "worker 1 was replaced, or was not, against the scenario")
    assert_false(was_signaled(result[1]), "the supervisor died on a signal")
    return [dead, live, picked, exit_code(result[1])]


def test_a_crashed_worker_the_supervisor_gave_up_on_is_never_picked() raises:
    """A worker that crashes once the respawn budget is spent is not
    replaced, and the supervisor, which reaps it, marks its index left
    while its sibling serves on: that sibling keeps its fifty connections'
    next one rather than handing it to the dead worker's channel, and its
    own word is untouched. Before the mark the dead worker read parked with
    no load for good, and every connection handed to it was accepted and
    never answered. The exit is 1, as for any supervisor that gave up.

    covers: E16
    """
    var got = _reap_worker_1(9, budget=0, polling=False)
    assert_equal(got[0], STATE_LEFT, "the supervisor did not mark the worker it reaped")
    assert_equal(got[1], STATE_PARKED, "the mark reached the sibling that lives")
    assert_equal(got[2], 0, "a sibling would hand a connection to the reaped worker")
    assert_equal(got[3], 1)


def test_a_worker_that_exits_cleanly_is_marked_as_it_is_reaped() raises:
    """A clean exit is never respawned, and a worker's own exit 0 does not
    say it left (an application's `os._exit(0)` from a thread, say): the
    supervisor's mark does.

    covers: E16
    """
    var got = _reap_worker_1(0, budget=10, polling=False)
    assert_equal(got[0], STATE_LEFT, "the supervisor did not mark the worker that exited")
    assert_equal(got[1], STATE_PARKED)
    assert_equal(got[2], 0, "a sibling would hand a connection to the exited worker")
    assert_equal(got[3], 0)


def test_the_polling_supervisor_marks_a_worker_it_will_not_replace() raises:
    """`--reload`'s supervisor reaps by polling, through its own accounting,
    and marks as the blocking one does.

    covers: E16
    """
    var got = _reap_worker_1(9, budget=0, polling=True)
    assert_equal(got[0], STATE_LEFT, "the polling supervisor did not mark the worker it reaped")
    assert_equal(got[1], STATE_PARKED)
    assert_equal(got[2], 0, "a sibling would hand a connection to the reaped worker")
    assert_equal(got[3], 1)


def _queued_scenario(
    page_addr: Int, share: AcceptShare, ready: String, die: String, go: String
):
    """Two workers over one accept-share page, parked as a started loop is,
    with no respawns allowed. Worker 1 leaves `ready`, waits for `die` and
    crashes (exit 9) without reading its channel; worker 0 waits for `go`,
    then exits 0."""
    try:
        var supervisor = WorkerSupervisor(2)
        supervisor.max_respawns = 0
        supervisor.share_accepts(share, page_addr)
        supervisor.fork_all()
        var mine = share.copy()
        mine.bind(supervisor.worker_index, page_addr)
        mine.start()
        var until = go
        if supervisor.worker_index == 1:
            with open(ready, "w") as f:
                f.write(String("parked"))
            until = die
        var waited = 0
        while not path.exists(until) and waited < 1000:
            sleep(0.01)
            waited += 1
        process_exit(9 if supervisor.worker_index == 1 else 0)
    except:
        process_exit(7)


def _reads_eof_within(fd: Int, bound_s: Float64) -> Bool:
    """Whether the non-blocking pipe read end `fd` reads EOF (every write
    end closed) within `bound_s` seconds."""
    var buf = external_call["malloc", Int, Int](8)
    var ptr = _OpaqueMut(unsafe_from_address=buf)
    var until = perf_counter_ns() + Int(bound_s * 1_000_000_000.0)
    var eof = False
    while perf_counter_ns() < until:
        if external_call["read", Int, Int, _OpaqueMut, Int](fd, ptr, 1) == 0:
            eof = True
            break
        sleep(0.005)
    external_call["free", NoneType, Int](buf)
    return eof


comptime _RACED_POST_S = 0.05
"""How long after worker 1 is told to die a raced hand-off is posted: well
inside the supervisor's wait for it (`_REAPED_DRAIN_NS`, 250 ms), and after
the supervisor's drain has begun whenever it reaps inside 50 ms."""


def _queue_to_a_worker_given_up_on(raced: Bool) raises -> List[Int]:
    """Queue one connection to worker 1 of `_queued_scenario`, have it die
    with no respawns allowed, and answer: whether the hand-off was queued,
    worker 1's `pending` once it was, whether the connection read a close
    within 1 s of the death, `pending` once the supervisor had exited, and
    the supervisor's exit code (1 for yes, 0 for no, where a Bool).

    The connection is a pipe's write end; this process keeps the read end,
    which reads EOF once the last copy of the write end is closed. It is
    handed over by worker 0's side of the protocol, run from this process.
    `raced`: the sender raised `pending` and read worker 1's `state` before
    the supervisor's mark, and its datagram lands `_RACED_POST_S` after the
    death, as a sender preempted between the two does; otherwise the whole
    of `send` runs while worker 1 is parked."""
    var tag = String(getpid())
    var ready = "/tmp/m0_queued_ready_" + tag
    var die = "/tmp/m0_queued_die_" + tag
    var go = "/tmp/m0_queued_go_" + tag
    for m in [ready, die, go]:
        if path.exists(m):
            remove(m)
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    var pid = fork()
    if pid == 0:
        _queued_scenario(page.addr(0), share, ready, die, go)
        process_exit(99)  # unreachable
    var waited = 0
    while waited < 500:
        if path.exists(ready) and page.load(_state_slot(1)) == STATE_PARKED:
            break
        sleep(0.01)
        waited += 1
    # Made after the fork, so no process of the scenario holds either end.
    var ends = create_shutdown_pipe()
    var read_end = ends[0]
    set_nonblocking(FileDescriptor(read_end))
    var sent: Bool
    if raced:
        # `send_with`'s raise, and its second read of `state`, which finds
        # worker 1 parked: the mark has not been stored.
        _ = page.fetch_add(_pending_slot(1), 1)
        sent = page.load(_state_slot(1)) == STATE_PARKED
    else:
        var view = share.copy()
        view.bind(0, page.addr(0))
        sent = view.send(1, ends[1].fd, String("127.0.0.1"), 1)
    var queued = page.load(_pending_slot(1))
    with open(die, "w") as f:
        f.write(String("die"))
    if raced:
        sleep(_RACED_POST_S)
        sent = sent and send_fd(share.write_fds[1], ends[1].fd, List[UInt8]())
    ends[1].signal()  # the sender's own copy, closed as the server's is
    var closed = _reads_eof_within(read_end, 1.0)
    with open(go, "w") as f:
        f.write(String("go"))
    var result = waitpid_blocking(pid)
    var left = page.load(_pending_slot(1))
    close_fd(read_end)
    for m in [ready, die, go]:
        if path.exists(m):
            remove(m)
    for fd in share.read_fds:
        close_fd(fd)
    for fd in share.write_fds:
        close_fd(fd)
    for fd in share.anchor_fds:
        close_fd(fd)
    assert_false(was_signaled(result[1]), "the supervisor died on a signal")
    return [
        1 if sent else 0, queued, 1 if closed else 0, left, exit_code(result[1])
    ]


def test_a_connection_queued_to_a_worker_given_up_on_is_closed() raises:
    """A hand-off that reached a worker's channel before the worker died,
    and that no replacement will read, is closed by the supervisor as it
    gives up, so its client reads a close at once (review record RB).
    Before, the channel held it -- every sibling and the supervisor keep a
    copy of the channel, so the dead worker's exit released nothing -- and
    the client of such a connection waited, accepted and unanswered, until
    the server stopped (measured: still open 1 s after the give-up). The
    hand-off's count in `pending` is retired with it, so a worker a reload
    later forks into the index does not wait in its own drain for it.

    covers: E16
    """
    var got = _queue_to_a_worker_given_up_on(raced=False)
    assert_equal(got[0], 1, "the hand-off to the parked worker was not queued")
    assert_equal(got[1], 1, "the hand-off was not counted to worker 1")
    assert_equal(
        got[2], 1,
        "a connection queued to the worker the supervisor gave up on was"
        " still open 1 s after the give-up",
    )
    assert_equal(got[3], 0, "the closed hand-off is still counted to worker 1")
    assert_equal(got[4], 1)


def test_a_handoff_that_raced_the_give_up_is_closed_too() raises:
    """A sender that read the worker's `state` before the supervisor's mark
    posts its hand-off after the mark, and the drain must not have finished
    first. It raised `pending` before that read, so the drain runs on while
    `pending` is above what it has received, within its bound, and takes
    the late datagram too (the leaver's handshake, `close_reaped_handoffs`).

    covers: E16
    """
    var got = _queue_to_a_worker_given_up_on(raced=True)
    assert_equal(got[0], 1, "the raced hand-off was not posted")
    assert_equal(got[1], 1, "the raced hand-off was not counted to worker 1")
    assert_equal(
        got[2], 1,
        "a hand-off posted after the give-up began was left open in the"
        " channel of the worker the supervisor gave up on",
    )
    assert_equal(got[3], 0, "the closed hand-off is still counted to worker 1")
    assert_equal(got[4], 1)


def test_a_replacement_is_picked_again_after_the_mark() raises:
    """The mark does not outlive the worker it names: a respawn at the same
    index writes over it in its own `bind` and `start`, and is picked
    again, where a mark that stuck would leave a live worker refused for
    good. The mark is made in `_remove_pid`, before `_try_respawn` forks,
    which is what orders it first; this test cannot force the other order
    (a mark made just after the fork still lands before the child's
    `bind`, measured), so it pins the outcome, not the placement.

    covers: E16
    """
    var got = _reap_worker_1(9, budget=10, polling=False, replaced=True)
    assert_equal(got[0], STATE_PARKED, "the replacement's index still reads as reaped")
    assert_equal(got[2], 1, "the replacement was never picked")
    assert_equal(got[3], 0)


def test_spawned_workers_are_marked_as_they_are_reaped() raises:
    """Under `--spawn-workers` the page is the supervisor's own mapping, and
    it marks each exec'd worker it reaps. The workers are the shell, which
    maps nothing, so the test writes each word parked, as a started loop
    would, before the supervisor forks them.

    covers: E16
    """
    var page = SharedAtomics(accept_share_slots(2))
    var share = AcceptShare(2)
    page.store(_state_slot(0), STATE_PARKED)
    page.store(_state_slot(1), STATE_PARKED)
    var pid = fork()
    if pid == 0:
        try:
            var supervisor = WorkerSupervisor(2)
            supervisor.share_accepts(share, page.addr(0))
            var args = List[String]()
            args.append(String("sh"))
            args.append(String("-c"))
            args.append(String("exit 0"))
            supervisor.enable_spawn(String("/bin/sh"), args^)
            supervisor.fork_all()
            process_exit(7)
        except:
            process_exit(7)
    var result = waitpid_blocking(pid)
    for fd in share.read_fds:
        close_fd(fd)
    for fd in share.write_fds:
        close_fd(fd)
    for fd in share.anchor_fds:
        close_fd(fd)
    assert_false(was_signaled(result[1]), "supervisor died on a signal")
    assert_equal(exit_code(result[1]), 0)
    assert_equal(page.load(_state_slot(0)), STATE_LEFT, "spawned worker 0 was not marked")
    assert_equal(page.load(_state_slot(1)), STATE_LEFT, "spawned worker 1 was not marked")
