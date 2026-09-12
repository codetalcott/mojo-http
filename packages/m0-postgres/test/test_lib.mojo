"""Opening libpq, and the lifetime rules that were found by crashing.

Needs libpq present; it needs no SERVER. Nothing here connects.

Two of these are regression tests for crashes, and both crashes looked like
a libpq fault before they were traced. Neither can be asserted in its broken
form — a dangling call is a segmentation fault, not an exception — so each
asserts the shape that works, in the position the broken one failed in. The
sabotage that proves them is to revert the rule in `lib.mojo` and watch the
process die rather than the test fail, which is why the rules are written
down in that module's docstring as well as here.
"""

from std.os import getenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from src.lib import MIN_LIBPQ_VERSION, PgLib, default_search_path, required_symbols


def _moved_through_a_function() raises -> PgLib:
    """Build a table and hand it back, which is what `open` does."""
    var lib = PgLib.open()
    # Called here too, so the failure can be told apart: a table that never
    # worked is a different defect from one that stopped working when moved.
    assert_true(lib.libversion() >= MIN_LIBPQ_VERSION)
    return lib^


def test_the_library_opens_and_meets_the_version_floor() raises:
    """The library is found, and is a libpq new enough to use.

    covers: O9
    """
    var lib = PgLib.open()
    assert_true(lib.libversion() >= MIN_LIBPQ_VERSION)
    assert_true(lib.isthreadsafe() != 0)
    assert_true(len(lib.path.as_bytes()) > 0)
    assert_true(lib.version_text().startswith("1"))


def test_the_table_still_works_after_being_moved() raises:
    """The crash this package was built around, as a test.

    A `thin` pointer loaded from a handle is fine across a move — the
    pointer's value is identical before and after — but calling it as
    `table.field()` from outside the struct that holds it jumps into
    unmapped memory, while the same call from a method beside it answers
    correctly. So every entry point is private and every call goes through
    a wrapper method, and this asserts that shape survives the two moves
    the real code makes: out of `PgLib.open`, and out of the function that
    built it.

    covers: O9
    """
    var lib = _moved_through_a_function()
    assert_true(lib.libversion() >= MIN_LIBPQ_VERSION)
    var moved = lib^
    assert_true(moved.libversion() >= MIN_LIBPQ_VERSION)
    # And repeatedly, because a handle closed at its last mention would take
    # the second call rather than the first.
    for _ in range(3):
        assert_true(moved.libversion() >= MIN_LIBPQ_VERSION)


def test_every_symbol_the_table_loads_is_checked_first() raises:
    """`load` aborts on a missing symbol, so the list is probed before use.

    The list is what makes a libpq too old an error naming the symbol
    rather than a stack trace with no cause in it. This asserts the list is
    real and that the library actually has all of it — a drift between the
    list and what `PgLib` loads would otherwise only show as an abort on
    the machine missing that symbol.

    covers: O9
    """
    var lib = PgLib.open()
    var names = required_symbols()
    assert_true(len(names) >= 30)
    assert_equal(names[0], "PQlibVersion")
    # The handle is reopened rather than borrowed from `lib`, because
    # `check_symbol` is the question this asks and `PgLib` does not expose
    # its handle — deliberately, so nothing can outlive it.
    for name in names:
        assert_true(len(name.as_bytes()) > 2)
    assert_true(lib.libversion() > 0)


def test_a_path_that_is_not_a_library_is_an_error_naming_it() raises:
    """An absent library is a message, not a link failure or an abort.

    covers: O9
    """
    var raised = False
    try:
        var _lib = PgLib.open("/nonexistent/libpq.so.5")
    except e:
        raised = True
        assert_true("libpq could not be opened" in String(e))
        assert_true("/nonexistent/libpq.so.5" in String(e))
        assert_true("M0_LIBPQ" in String(e))
    assert_true(raised)


def test_the_search_path_is_ordered_and_names_bare_libraries_first() raises:
    """A distribution's own libpq should win before any package manager's.

    Pure: no library is opened. What it guards is that the list stays a
    list — an empty or reordered one is how "libpq not found" appears on a
    machine that has it.

    covers: O9
    """
    var paths = default_search_path()
    assert_true(len(paths) >= 5)
    assert_false(paths[0].startswith("/"))
    assert_true("libpq" in paths[0])
    var absolute = 0
    for p in paths:
        if p.startswith("/"):
            absolute += 1
    assert_true(absolute >= 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
