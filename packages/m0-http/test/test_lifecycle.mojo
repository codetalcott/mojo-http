"""Tests for the per-request context, the shutdown pipe, and the supervisor.

Three small modules that had no coverage, grouped because none of them fills a
file on its own.

**What is deliberately not tested here: forking.** `WorkerSupervisor.fork_all`
calls `fork(2)`, and a child forked out of a test binary resumes inside the test
runner — it would re-enter the suite, duplicate output, and race the parent for
the terminal. Only the supervisor's pure state is exercised below. The respawn
path, which must fork, lives in `test_respawn.mojo` — it isolates the whole
scenario in a forked subprocess so nothing escapes into the runner — and the
serving path is covered end to end by `poe smoke-hello`, which starts a real
server and asserts it answers.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.content_negotiation import AcceptResult, parse_accept
from src.request_context import RequestContext
from src.signal import create_shutdown_pipe
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
