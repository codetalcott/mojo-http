"""Opening libsqlite3 at run time, and the lifetime rules that hold it.

`lib.mojo`'s three rules were each found by crashing in m0-postgres, where
this file's shape comes from. A dangling call is a segmentation fault, not
an exception, so the tests that guard them assert the shape that works in
the position the broken one fails in: a table moved through a function, a
statement stepped after the connection — and with it the only handle the
library was opened through — is gone. The sabotage that proves them is to
revert the rule in `lib.mojo` and watch the process die rather than the
test fail, which is why the rules are written in that module's docstring
as well as here.

Runs under `mojo run` like every other test in this package now: nothing
here links libsqlite3, which is the point of the loader.
"""

from std.ffi import OwnedDLHandle, c_int
from std.os import getenv, setenv, unsetenv
from std.python._cpython import ExternalFunction
from std.sys import CompilationTarget
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from src import Connection, open_memory
from src.lib import (
    MIN_SQLITE_VERSION,
    SqliteLib,
    _checked,
    default_search_path,
    open_library,
)

comptime _Getpid = ExternalFunction["getpid", def () thin abi("C") -> c_int]
comptime _Absent = ExternalFunction[
    "m0_sqlite_no_such_symbol", def () thin abi("C") -> c_int
]


def _moved_through_a_function() raises -> SqliteLib:
    """Build a table and hand it back, which is what `open_library` does."""
    var lib = open_library()
    # Called here too, so the failure can be told apart: a table that never
    # worked is a different defect from one that stopped working when moved.
    assert_true(lib.libversion_number() >= MIN_SQLITE_VERSION)
    return lib^


def test_the_library_opens_and_meets_the_floor() raises:
    """The library is found by the search path, is new enough, and was
    built thread-safe, which one connection per thread depends on.

    covers: O17
    """
    var lib = open_library()
    assert_true(lib.libversion_number() >= MIN_SQLITE_VERSION)
    assert_true(lib.threadsafe() != 0)
    assert_true(len(lib.path.as_bytes()) > 0)
    assert_true(lib.libversion().startswith("3."))
    assert_equal(lib.errstr(0), "not an error")


def test_the_table_still_works_after_being_moved() raises:
    """The first rule: the handle and its pointers move together.

    `open_library` returns the table by move, and a `Connection` moves it
    again into its field. A loaded pointer carries no borrow, so a handle
    held anywhere else would be closed at its last mention; with both in
    one struct the move carries both.
    """
    var lib = _moved_through_a_function()
    assert_true(lib.libversion_number() >= MIN_SQLITE_VERSION)
    assert_true(lib.threadsafe() != 0)
    var db = open_memory()
    assert_equal(db.library_path(), lib.path)


def test_a_statement_outlives_every_handle_of_the_library() raises:
    """The third rule, in the position that crashed without it.

    `Connection` owns the only `OwnedDLHandle` the library was opened
    through; `Statement` holds a COPY of the entry points it calls. Closing
    and dropping the connection here closes that handle, and the
    statement's next `step` and `column_int` call through the copies. They
    answer only because `pin_library` re-opened the image `RTLD_NODELETE`
    at construction: remove the pin and, on a host where nothing else has
    the library mapped, the `dlclose` unmaps it and this test dies with a
    segmentation fault rather than failing.

    covers: O18
    """
    var db = open_memory()
    db.execute("CREATE TABLE t (v INTEGER)")
    db.execute("INSERT INTO t VALUES (41), (42)")
    var q = db.prepare("SELECT v FROM t ORDER BY v")
    db.close()
    _ = db^
    assert_true(q.step())
    assert_equal(q.column_int(0), 41)
    assert_true(q.step())
    assert_equal(q.column_int(0), 42)
    assert_false(q.step())
    assert_equal(q.column_count(), 1)


def test_a_symbol_the_library_lacks_is_an_error_naming_it() raises:
    """Every entry point is checked before it is loaded, in ONE place.

    `ExternalFunction.load` aborts the process on a missing symbol, and
    statically so, so there is no recovering after the fact. `_checked`
    asks `check_symbol` first and raises naming the symbol and the path,
    which is what makes a libsqlite3 too old an error an operator can act
    on. Both arms run against the process image, because the refusal is the
    half `open_library()` succeeding cannot show.

    covers: O17
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
            image, String("/some/where/libsqlite3.so")
        )
        _ = absent
    except e:
        raised = True
        var text = String(e)
        assert_true("m0_sqlite_no_such_symbol" in text)
        assert_true("/some/where/libsqlite3.so" in text)
        assert_true("3.20.0" in text)
    assert_true(raised)

    # And the whole table still loads, which is the 41 checks passing.
    var lib = open_library()
    assert_true(lib.libversion_number() > 0)


def test_a_path_that_is_not_a_library_is_an_error_naming_it() raises:
    """An absent file, named outright or through `M0_LIBSQLITE3`, is one
    error carrying the path and the variable, before any database is
    touched.

    covers: O17
    """
    var raised = False
    try:
        _ = open_library(String("/no/such/dir/libsqlite3.so"))
    except e:
        raised = True
        assert_true("/no/such/dir/libsqlite3.so" in String(e))
        assert_true("M0_LIBSQLITE3" in String(e))
    assert_true(raised)

    # Through the environment, the way a deployment names it -- and what a
    # Connection sees, since it opens the library first.
    _ = setenv("M0_LIBSQLITE3", "/no/such/dir/libsqlite3.so", True)
    var through_env = String("")
    try:
        _ = open_memory()
    except e:
        through_env = String(e)
    _ = unsetenv("M0_LIBSQLITE3")
    assert_true("/no/such/dir/libsqlite3.so" in through_env, through_env)
    assert_true("M0_LIBSQLITE3" in through_env, through_env)


def test_a_library_that_is_not_libsqlite3_is_refused_by_symbol() raises:
    """A file that opens and is not libsqlite3 is refused naming the first
    symbol it lacks, not aborted: the C library is every process's.

    covers: O17
    """
    var other: String
    comptime if CompilationTarget.is_macos():
        other = String("/usr/lib/libSystem.B.dylib")
    else:
        other = String("libc.so.6")
    var raised = False
    try:
        _ = open_library(other)
    except e:
        raised = True
        var text = String(e)
        assert_true("sqlite3_" in text, text)
        assert_true(other in text, text)
    assert_true(raised)


def test_the_search_path_is_ordered_and_names_bare_libraries_first() raises:
    """The loader finds a system library by name, so the bare name comes
    first and the package-manager paths after it; every entry names the
    library, and the list is what an error prints."""
    var paths = default_search_path()
    assert_true(len(paths) >= 3)
    assert_false("/" in paths[0], "the first entry is not a bare name: " + paths[0])
    for p in paths:
        assert_true("libsqlite3" in p, p)
    for i in range(1, len(paths)):
        assert_true(paths[i].startswith("/"), paths[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
