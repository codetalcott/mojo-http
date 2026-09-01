"""Tests for the per-request context, the shutdown pipe, and the supervisor.

Three small modules that had no coverage, grouped because none of them fills a
file on its own.

**The signal tests really do signal this process.** `kill(getpid(), SIGTERM)`
with a handler installed is the only honest way to prove the handler is
installed, and it is safe in both directions: POSIX requires an unblocked
signal sent to self to be delivered before `kill` returns, so the byte is in
the pipe before the read — and if the handler were *not* installed, the
default action would kill the test runner outright rather than hang it.

**What is deliberately not tested here: forking.** `WorkerSupervisor.fork_all`
calls `fork(2)`, and a child forked out of a test binary resumes inside the test
runner — it would re-enter the suite, duplicate output, and race the parent for
the terminal. Only the supervisor's pure state is exercised below. The respawn
path, which must fork, lives in `test_respawn.mojo` — it isolates the whole
scenario in a forked subprocess so nothing escapes into the runner — and the
serving path is covered end to end by `poe smoke-hello`, which starts a real
server and asserts it answers.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.c.process import getpid, kill_process, SIGTERM, SIGINT

from src.content_negotiation import AcceptResult, parse_accept
from src.request_context import RequestContext
from src.signal import (
    create_shutdown_pipe, install_shutdown_signals, shutdown_signals_active,
)
from src.global_slot import (
    slot_is_live, set_shutdown_write_fd, shutdown_write_fd,
    publish_child_pids, child_pid_count, child_pid_at, MAX_TRACKED_CHILDREN,
)
from src.multiworker import WorkerSupervisor


# --- RequestContext ----------------------------------------------------------


def test_context_carries_the_parsed_accept_result() raises:
    """The point of the struct: parse Accept once, read it in after_response."""
    var accept = parse_accept("application/json")
    var ctx = RequestContext(7, accept, UInt(1000))
    assert_equal(ctx.request_id, 7)
    assert_equal(ctx.start_ns, UInt(1000))
    assert_true(ctx.accept.wants_json)


def test_context_starts_with_no_response_status() raises:
    """0 means "not yet answered" — after_response fills it in."""
    var ctx = RequestContext(1, parse_accept("*/*"), UInt(0))
    assert_equal(ctx.response_status, 0)


def test_context_status_is_mutable_after_construction() raises:
    var ctx = RequestContext(1, parse_accept("*/*"), UInt(0))
    ctx.response_status = 404
    assert_equal(ctx.response_status, 404)


def test_context_copy_is_independent() raises:
    """It is Copyable and passed through hooks; a copy must not alias."""
    var a = RequestContext(1, parse_accept("text/html"), UInt(5))
    var b = a.copy()
    b.response_status = 500
    assert_equal(a.response_status, 0)
    assert_equal(b.response_status, 500)
    assert_equal(b.request_id, 1)


def test_context_move_preserves_every_field() raises:
    var a = RequestContext(9, parse_accept("application/json"), UInt(42))
    a.response_status = 201
    var b = a^
    assert_equal(b.request_id, 9)
    assert_equal(b.start_ns, UInt(42))
    assert_equal(b.response_status, 201)
    assert_true(b.accept.wants_json)


# --- Shutdown pipe -----------------------------------------------------------


def test_shutdown_pipe_yields_a_usable_read_fd() raises:
    """The event loop watches this fd; a bad one would break graceful drain."""
    var pair = create_shutdown_pipe()
    assert_true(pair[0] > 2, "read fd overlaps stdin/stdout/stderr")
    assert_true(pair[1].fd > 2, "write fd overlaps stdin/stdout/stderr")
    assert_true(pair[0] != pair[1].fd)


def test_each_shutdown_pipe_is_distinct() raises:
    """Two servers in one process must not share a shutdown channel."""
    var first = create_shutdown_pipe()
    var second = create_shutdown_pipe()
    assert_true(first[0] != second[0])
    assert_true(first[1].fd != second[1].fd)


def test_signalling_a_shutdown_handle_succeeds() raises:
    """signal() closes the write end; the loop sees EOF on the read end."""
    var pair = create_shutdown_pipe()
    pair[1].signal()


# --- WorkerSupervisor: state only, never fork() ------------------------------


def test_supervisor_starts_with_no_children() raises:
    var s = WorkerSupervisor(4)
    assert_equal(s.num_workers, 4)
    assert_equal(len(s.child_pids), 0)
    assert_equal(s.respawn_count, 0)
    assert_equal(s.rapid_crash_count, 0)


def test_respawn_budget_scales_with_worker_count() raises:
    """A crash loop must terminate; the cap is what makes that true."""
    assert_equal(WorkerSupervisor(1).max_respawns, 10)
    assert_equal(WorkerSupervisor(4).max_respawns, 40)


def test_single_worker_supervisor_is_valid() raises:
    """M0_WORKERS=1 is the default, so it must not be a degenerate case."""
    var s = WorkerSupervisor(1)
    assert_equal(s.num_workers, 1)
    assert_true(s.max_respawns > 0)


# --- The data-segment slots ---------------------------------------------------


def test_the_shutdown_slot_round_trips() raises:
    """Written by one function, read by another — the whole trick in one line.

    If `@no_inline` ever stops holding, each accessor materialises its own
    global and this fails. Everything else in this section rests on it.
    """
    var saved = shutdown_write_fd()
    set_shutdown_write_fd(4242)
    assert_equal(shutdown_write_fd(), 4242)
    set_shutdown_write_fd(saved)


def test_slot_is_live_agrees() raises:
    """The check `install_shutdown_signals` gates on, and it must not disturb."""
    var saved = shutdown_write_fd()
    assert_true(slot_is_live())
    assert_equal(shutdown_write_fd(), saved, "the probe did not restore the slot")


def test_child_pids_round_trip() raises:
    publish_child_pids([11, 22, 33])
    assert_equal(child_pid_count(), 3)
    assert_equal(child_pid_at(0), 11)
    assert_equal(child_pid_at(2), 33)


def test_a_vacant_index_publishes_as_zero() raises:
    """The supervisor writes -1 for a vacated index. `kill(-1, sig)` would
    signal every process the caller can reach, so it must never survive here."""
    publish_child_pids([11, -1, 33])
    assert_equal(child_pid_at(1), 0)


def test_publishing_fewer_pids_lowers_the_count() raises:
    """A shrink has to be visible immediately: the handler reads count first."""
    publish_child_pids([11, 22, 33])
    publish_child_pids([11])
    assert_equal(child_pid_count(), 1)


def test_reading_past_the_count_is_zero_not_garbage() raises:
    publish_child_pids([11])
    assert_equal(child_pid_at(MAX_TRACKED_CHILDREN), 0)
    assert_equal(child_pid_at(-1), 0)


# --- Signal-driven shutdown ---------------------------------------------------


comptime _OpaqueMut = Pointer[NoneType, MutUntrackedOrigin]


def _read_one(fd: Int) -> Int:
    """Read one byte, returning the count. Only the count is asserted on.

    Into an explicit allocation: a `List(capacity=8)` reserves, but a write
    through its pointer before any append is a write the list does not own
    — it passed here under the JIT and corrupted the heap in a real build
    (the same helper in `src/threads.mojo` found it).
    """
    var buf = List[UInt8](length=8, fill=0)
    return external_call["read", Int, Int, _OpaqueMut, Int](
        fd,
        buf.unsafe_ptr().unsafe_bitcast[NoneType]().unsafe_origin_cast[
            MutUntrackedOrigin
        ](),
        1,
    )


def test_installing_arms_the_process() raises:
    var read_fd = install_shutdown_signals()
    assert_true(read_fd > 2, "no usable read fd came back")
    assert_true(
        shutdown_signals_active(),
        "install reported success but left nothing armed",
    )


def test_sigterm_reaches_the_shutdown_pipe() raises:
    """The assertion the whole feature reduces to.

    Reaching the next line at all proves a handler ran — the default action for
    SIGTERM would have killed the runner.

    covers: D4
    """
    var read_fd = install_shutdown_signals()
    _ = kill_process(getpid(), SIGTERM)
    assert_equal(_read_one(read_fd), 1, "SIGTERM did not reach the pipe")


def test_sigint_is_armed_and_a_second_signal_is_safe() raises:
    """Ctrl-C too, and repeatedly: the handler writes rather than closing, so
    two signals cannot double-close an fd the kernel may have recycled."""
    var read_fd = install_shutdown_signals()
    _ = kill_process(getpid(), SIGTERM)
    _ = kill_process(getpid(), SIGINT)
    assert_equal(_read_one(read_fd), 1)
    assert_equal(_read_one(read_fd), 1, "the second signal was lost")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
