"""What both hosts make before they fork, and how a spawned worker adopts it.

`m0_http.prefork` is shared by `m0serve` and the Mojo host. Everything here
runs in one process, which is enough for the adopt path: a spawned worker
is a fresh image that finds the page, the bus and the accept-share channels
by descriptor number in its environment, and a second mapping of the same
descriptor in this process is exactly what it gets. The exec itself is
`smoke-spawn-workers` (SPEC E15).
"""

from std.os import getenv, setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.accept_share import (
    SHARED_PAGE_MAGIC,
    SHARED_PAGE_MAGIC_SLOT,
    accept_share_slots,
)

from lightbug_http.c.fcntl import clear_cloexec, is_cloexec
from src.multiworker import SharedAtomics, spawn_inherited_fds
from src.prefork import (
    bind_accept_share,
    int_list_env,
    prefork_accept_share,
    prefork_bus,
    prefork_page,
    shared_id_addr,
    spawned_worker_index,
)


def _spawned(index: Int):
    _ = setenv("M0_WORKER_SPAWNED", "1", True)
    _ = setenv("M0_WORKER_INDEX", String(index), True)


def _forked():
    _ = unsetenv("M0_WORKER_SPAWNED")
    _ = unsetenv("M0_WORKER_INDEX")


def test_the_spawned_index_comes_from_both_variables() raises:
    _forked()
    assert_equal(spawned_worker_index(), -1)
    _ = setenv("M0_WORKER_INDEX", "3", True)
    assert_equal(spawned_worker_index(), -1, "an index without the marker is not a spawn")
    _spawned(3)
    assert_equal(spawned_worker_index(), 3)
    _ = setenv("M0_WORKER_INDEX", "x", True)
    assert_equal(spawned_worker_index(), -1)
    _forked()


def test_an_int_list_skips_what_is_not_an_int() raises:
    _ = setenv("M0_TEST_INTS", "4,x,,17", True)
    var got = int_list_env("M0_TEST_INTS")
    _ = unsetenv("M0_TEST_INTS")
    assert_equal(len(got), 2)
    assert_equal(got[0], 4)
    assert_equal(got[1], 17)
    assert_equal(len(int_list_env("M0_TEST_UNSET_INTS")), 0)


def test_a_page_is_made_marked_and_exported() raises:
    _forked()
    var page = prefork_page(2)
    assert_equal(page.count(), accept_share_slots(2))
    assert_equal(page.load(SHARED_PAGE_MAGIC_SLOT), SHARED_PAGE_MAGIC)
    assert_equal(shared_id_addr(), page.addr(0))
    if page.fd >= 0:
        assert_equal(getenv("M0_SHARED_ID_FD", ""), String(page.fd))


def test_a_spawned_worker_adopts_the_page() raises:
    """The same page, at a new address, with that address re-exported.

    covers: E24
    """
    _forked()
    var page = prefork_page(2, required=True)
    page.store(0, 41)
    _spawned(1)
    var adopted = prefork_page(2)
    _forked()
    assert_true(adopted.addr(0) != page.addr(0), "the page was not mapped again")
    assert_equal(shared_id_addr(), adopted.addr(0))
    assert_equal(adopted.load(0), 41)
    assert_equal(adopted.load(SHARED_PAGE_MAGIC_SLOT), SHARED_PAGE_MAGIC)
    _ = adopted.fetch_add(0, 1)
    assert_equal(page.load(0), 42, "a store through the adopted mapping did not reach the page")


def test_a_spawned_worker_with_no_page_descriptor_is_refused() raises:
    _ = unsetenv("M0_SHARED_ID_FD")
    _spawned(0)
    var raised = False
    try:
        _ = prefork_page(2)
    except:
        raised = True
    _forked()
    assert_true(raised, "a spawned worker with no page descriptor was handed a page")


def test_the_bus_is_exported_and_adopted() raises:
    _forked()
    var bus = prefork_bus(3)
    assert_equal(bus.size(), 3)
    assert_equal(len(int_list_env("M0_BUS_WRITE_FDS")), 3)
    _spawned(2)
    var adopted = prefork_bus(99)
    _forked()
    assert_equal(adopted.size(), 3, "a spawned worker made channels instead of adopting")
    for i in range(3):
        assert_equal(adopted.read_fds[i], bus.read_fds[i])
        assert_equal(adopted.write_fds[i], bus.write_fds[i])


def test_accept_sharing_is_made_only_above_one_worker() raises:
    _forked()
    assert_equal(prefork_accept_share(1).workers(), 0)
    _ = setenv("M0_ACCEPT_SHARE", "0", True)
    assert_equal(prefork_accept_share(2).workers(), 0, "the knob did not turn it off")
    _ = unsetenv("M0_ACCEPT_SHARE")
    var share = prefork_accept_share(2)
    assert_equal(share.workers(), 2)
    assert_equal(len(int_list_env("M0_ACCEPT_READ_FDS")), 2)
    _spawned(1)
    var adopted = prefork_accept_share(2)
    _forked()
    assert_equal(adopted.read_fds[1], share.read_fds[1])


def test_adopted_descriptors_are_close_on_exec_again() raises:
    """A spawned worker's inherited descriptors arrive with close-on-exec
    cleared -- the spawn kept them across its own exec -- and adopting them
    sets it again, or the worker's own children would inherit the page, the
    bus and the accept-share channels (SPEC G16).

    covers: E24
    """
    _forked()
    var page = prefork_page(2, required=True)
    var bus = prefork_bus(2)
    var share = prefork_accept_share(2)
    # What `_exec_if_spawning` does to exactly these before the exec.
    var kept = spawn_inherited_fds()
    for fd in kept:
        _ = clear_cloexec(fd)
    assert_false(is_cloexec(bus.read_fds[0]), "the setup did not clear the flag")
    _spawned(1)
    var adopted_page = prefork_page(2)
    var adopted_bus = prefork_bus(2)
    var adopted_share = prefork_accept_share(2)
    _forked()
    assert_true(is_cloexec(page.fd), "the adopted page is inheritable")
    for i in range(2):
        assert_true(is_cloexec(adopted_bus.read_fds[i]), "an adopted bus read end is inheritable")
        assert_true(is_cloexec(adopted_bus.write_fds[i]), "an adopted bus write end is inheritable")
        assert_true(is_cloexec(adopted_share.read_fds[i]), "an adopted accept-share end is inheritable")
        assert_true(is_cloexec(adopted_share.write_fds[i]), "an adopted accept-share end is inheritable")
    _ = adopted_page^


def test_binding_an_inactive_share_is_harmless() raises:
    var page = SharedAtomics(accept_share_slots(1))
    var share = prefork_accept_share(1)
    bind_accept_share(share, 0, page.addr(0))
    assert_false(share.active())
    var two = prefork_accept_share(2)
    var page2 = SharedAtomics(accept_share_slots(2))
    bind_accept_share(two, 1, page2.addr(0))
    assert_true(two.active())
    assert_equal(two.worker, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
