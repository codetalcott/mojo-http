"""Tests for the pthread idiom — no interpreter, no server.

What is pinned: a thread body really runs on its own thread with its own
block, results written by a thread are visible after `join_all`, two
threads sharing an `Atomic` through a block slot both land their updates,
a dup'd fd outlives the original, and the shutdown fan-out reaches every
pipe. What is NOT pinned here is anything Python — that is
`m0_wsgi.threaded`'s charter and `smoke-threads`'s proof.
"""

from std.atomic import Atomic
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.threads import (
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


def _counting_body(arg: Int) -> Int:
    """Writes index*10 into a spare slot, bumps the shared counter, reports ok."""
    var block = ThreadBlock(arg)
    var counter = Pointer[Atomic[DType.int64], MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )
    _ = counter[].fetch_add(1)
    block.set(6, block.get(BLK_INDEX) * 10)
    block.set(BLK_STATUS, STATUS_OK)
    return 0


def test_threads_run_with_their_own_blocks_and_share_an_atomic() raises:
    var counter = Atomic[DType.int64](0)
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
