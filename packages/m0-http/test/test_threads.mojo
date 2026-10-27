"""Tests for the pthread idiom — no interpreter, no server.

What is pinned: a thread body really runs on its own thread with its own
block, results written by a thread are visible after `join_all`, two
threads sharing an `Atomic` through a block slot both land their updates,
a dup'd fd outlives the original, the shutdown fan-out reaches every
pipe, and a thread the process limit refuses leaves its slot as never
spawned. What is NOT pinned here is anything Python — that is
`m0_wsgi.threaded`'s charter and `smoke-threads`'s proof.
"""

from std.atomic import Atomic
from std.ffi import c_int, external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.threads import (
    _slot,
    ThreadSet,
    ThreadBlock,
    ShutdownFanout,
    dup_fd,
    read_one_byte_blocking,
    BLK_INDEX,
    BLK_USER,
    BLK_STATUS,
    STATUS_OK,
    STATUS_NEVER_RAN,
)
from lightbug_http.c.pipe import create_shutdown_pipe, close_fd, ShutdownHandle
from lightbug_http.c.process import exit_code, fork, process_exit, waitpid_blocking


comptime _RLIMIT_NPROC = 7 if CompilationTarget.is_macos() else 6

comptime _REFUSED_OK = 0
"""The child's answers: the create was refused and its slot reads 0."""
comptime _SLOT_LEFT = 1
"""The create was refused and its slot still holds an id: the bug."""
comptime _NOT_REFUSED = 2
"""The create succeeded under the limit, so there was nothing to check."""
comptime _NO_LIMIT = 3
"""`setrlimit` failed."""


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


def _ok_body(arg: Int) -> Int:
    ThreadBlock(arg).set(BLK_STATUS, STATUS_OK)
    return 0


def _counting_body(arg: Int) -> Int:
    """Writes index*10 into a spare slot, bumps the shared counter, reports ok."""
    var block = ThreadBlock(arg)
    var counter = Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )
    _ = counter[].fetch_add(1)
    block.set(6, block.get(BLK_INDEX) * 10)
    block.set(BLK_STATUS, STATUS_OK)
    return 0


def test_threads_run_with_their_own_blocks_and_share_an_atomic() raises:
    var counter = Atomic[Int64](0)
    var counter_ptr = Pointer(to=counter)
    var counter_addr = Pointer(to=counter_ptr).unsafe_bitcast[Int]()[]

    var threads = ThreadSet(4)
    for i in range(4):
        assert_equal(threads.status(i), STATUS_NEVER_RAN)
        threads.block(i).set(BLK_USER, counter_addr)
    var body = _counting_body
    var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
    for i in range(4):
        threads.spawn(i, body_addr)
    threads.join_all()

    assert_equal(Int(counter.load()), 4)
    assert_true(threads.all_ok())
    for i in range(4):
        assert_equal(threads.status(i), STATUS_OK)
        assert_equal(threads.block(i).get(BLK_INDEX), i)
        assert_equal(threads.block(i).get(6), i * 10)


def test_a_thread_that_never_ran_is_not_ok() raises:
    var threads = ThreadSet(2)
    assert_false(threads.all_ok())
    threads.join_all()  # nothing spawned: must not block or raise


def test_a_thread_the_process_limit_refuses_is_left_never_spawned() raises:
    """A `spawn` that `pthread_create` refuses raises and leaves its slot at
    0, so `join_all` passes it as never spawned.

    On glibc a create refused in `clone()` has already stored a descriptor
    in the slot and freed it, and joining that is undefined. The refusal is
    provoked with RLIMIT_NPROC at 0 in a child of the test's own, which
    reports by exit code, as `test_process.mojo`'s do; the child never
    joins a slot that still holds an id. Linux counts threads against the
    limit, and root is exempt, so the check is required of a non-root
    Linux run. macOS limits processes there and not threads, and its
    libpthread writes NULL on a failure anyway, so there the create may
    succeed, which says nothing either way.

    covers: E41
    """
    var threads = ThreadSet(1)
    var body = _ok_body
    var body_addr = Pointer(to=body).unsafe_bitcast[Int]()[]
    var child = fork()
    if child == 0:
        if not _set_soft_limit(_RLIMIT_NPROC, 0):
            process_exit(_NO_LIMIT)
        var refused = False
        try:
            threads.spawn(0, body_addr)
        except e:
            refused = String(e).find("pthread_create failed for thread 0") >= 0
        if not refused:
            threads.join_all()
            process_exit(_NOT_REFUSED)
        if _slot(threads._tids)[] != 0:
            process_exit(_SLOT_LEFT)
        threads.join_all()
        process_exit(_REFUSED_OK)
    var code = exit_code(waitpid_blocking(child)[1])
    assert_true(code != _SLOT_LEFT, "a refused create left an id in its slot")
    assert_true(code != _NO_LIMIT, "setrlimit(RLIMIT_NPROC) failed")
    if CompilationTarget.is_linux() and Int(external_call["geteuid", UInt32]()) != 0:
        assert_equal(code, _REFUSED_OK, "RLIMIT_NPROC at 0 did not refuse the thread")
    else:
        assert_true(code == _REFUSED_OK or code == _NOT_REFUSED)


def test_dup_fd_survives_closing_the_original() raises:
    var pair = create_shutdown_pipe()
    var read_fd = pair[0]
    # ShutdownHandle is Movable only; the fd is all the test needs.
    var write_fd = pair[1].fd
    var dup = dup_fd(read_fd)
    assert_true(dup != read_fd)
    close_fd(read_fd)
    ShutdownHandle(write_fd).notify()
    assert_equal(read_one_byte_blocking(dup), 1)
    close_fd(dup)
    close_fd(write_fd)


def test_shutdown_fanout_reaches_every_pipe() raises:
    var fanout = ShutdownFanout(3)
    assert_equal(fanout.count(), 3)
    fanout.notify_all()
    for i in range(3):
        assert_equal(read_one_byte_blocking(fanout.read_fd(i)), 1)
    assert_equal(fanout.read_fd(3), -1)
    assert_equal(fanout.read_fd(-1), -1)


def test_read_one_byte_reports_eof_as_zero() raises:
    var pair = create_shutdown_pipe()
    pair[1].signal()  # closes the write end: the read end sees EOF
    assert_equal(read_one_byte_blocking(pair[0]), 0)
    close_fd(pair[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
