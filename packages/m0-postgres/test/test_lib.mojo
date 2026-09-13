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

from std.ffi import OwnedDLHandle, c_int
from std.os import getenv
from std.python._cpython import ExternalFunction
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from src.lib import (
    MIN_LIBPQ_VERSION,
    PGRES_FATAL_ERROR,
    PgLib,
    ResultLib,
    _checked,
    default_search_path,
)

comptime _Getpid = ExternalFunction["getpid", def() thin abi("C") -> c_int]
comptime _Absent = ExternalFunction[
    "m0_pg_no_such_symbol", def() thin abi("C") -> c_int
]


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


def _result_table_of_a_dropped_library() raises -> ResultLib:
    """Copy a `Result`'s entry points out, and let the `PgLib` go.

    The `PgLib` is destroyed before this returns, which releases its
    `dlopen` handle. When that was the only reference, the library was
    unmapped here and every copied pointer pointed into nothing.
    """
    var lib = PgLib.open()
    return lib.result_lib()


def test_a_result_table_outlives_the_handle_it_was_copied_from() raises:
    """The third rule, without a server: libpq stays mapped once opened.

    `PQntuples(NULL)` is 0 and `PQresultStatus(NULL)` is
    `PGRES_FATAL_ERROR` — libpq checks for NULL in both — so the calls need
    no connection and answer something definite. Before the pin, the same
    shape reached from a `Result` whose connection had gone was a
    segmentation fault, not a wrong answer, which is why this asserts the
    working shape in the position the broken one died in.

    covers: O16
    """
    var pq = _result_table_of_a_dropped_library()
    for _ in range(3):
        var other = _result_table_of_a_dropped_library()
        assert_equal(other.ntuples(0), 0)
    assert_equal(pq.ntuples(0), 0)
    assert_equal(pq.nfields(0), 0)
    assert_equal(pq.result_status(0), PGRES_FATAL_ERROR)


def test_a_symbol_the_library_lacks_is_an_error_naming_it() raises:
    """Every entry point is checked before it is loaded, in ONE place.

    `ExternalFunction.load` aborts the process on a missing symbol, and
    statically so -- the compiler calls a `try` around it unreachable -- so
    there is no recovering after the fact. `_checked` asks `check_symbol`
    first and raises naming the symbol, which is what makes a libpq too old
    an error a server operator can act on rather than a stack trace with no
    cause in it. This drives both arms against the process image, because
    the refusal is the half `PgLib.open()` succeeding cannot show.

    It replaces a test that walked a `required_symbols()` list and asserted
    the list was plausible. That list was a second source of truth beside
    the declarations and the fields, nothing compared them, and an entry
    point added without its list entry would have passed every gate here
    and aborted on the first host whose libpq lacked it -- the one failure
    the list existed to prevent. There is no list now: `_checked` takes the
    name from the declaration it loads, so checked-but-not-loaded and
    loaded-but-not-checked are both unspellable.

    covers: O9
    """
    var image = OwnedDLHandle()

    # The control, first: a symbol the process certainly has resolves and
    # answers. Without it a `_checked` that raised unconditionally would
    # pass the arm below.
    var pid = _checked[_Getpid.name, _Getpid.type](image, String("<image>"))
    assert_true(Int(pid()) > 0)

    var raised = False
    try:
        var absent = _checked[_Absent.name, _Absent.type](
            image, String("/some/where/libpq.so")
        )
        _ = absent
    except e:
        raised = True
        var text = String(e)
        assert_true("m0_pg_no_such_symbol" in text)
        assert_true("/some/where/libpq.so" in text)
    assert_true(raised)

    # And the whole table still loads, which is the 32 checks passing.
    var lib = PgLib.open()
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
