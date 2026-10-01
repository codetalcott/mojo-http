"""One image of each libpq a process opens, however connections come and go
(`lib.mojo`'s third rule, SPEC O24).

Needs libpq present; it needs no SERVER. Nothing here connects, and nothing
here skips: without a library every test fails at its first open.

The property is the same on every platform and only macOS can lose it.
There an image opened `RTLD_NODELETE` stays mapped after its last handle
closes but leaves dyld's list, so the next `dlopen` of the same path maps a
FRESH copy: measured with Homebrew's libpq 17.6 before the pin kept a
handle, a new image at five reopens of five, each bringing its own copies
of the libraries libpq links. No libpq on macOS escapes it, because none is
in the dyld shared cache — Apple ships no libpq — so wherever this file
runs on macOS it can fail. glibc keeps a `RTLD_NODELETE` object findable,
so on Linux the first test states the property without being able to lose
it; the second can fail on both.

An image is told by an entry point's address (`PgFns.image`), read and
never called: a stale pointer into an image the loader dropped keeps
answering, which is how this went unseen.
"""

from std.collections.span import Span
from std.ffi import c_int, external_call
from std.os import getenv, remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from src.lib import (
    PGRES_FATAL_ERROR,
    PgFns,
    PgLib,
    default_search_path,
    is_pinned,
)

comptime COPY_SUFFIX = "-m0-postgres-second-image.so"


def _table_of_a_dropped_library(path: String = "") raises -> PgFns:
    """Open libpq, copy its table out, and let the `PgLib` go: the handle
    the library was opened through closes before this returns, which is
    what a `Connection` at its last use does."""
    var lib = PgLib.open(path)
    return lib.fns


def _library_file() raises -> String:
    """The file libpq is opened from here, to copy: the one the process
    opens when it names a file, else the first file on the search path. A
    bare name the loader resolved names no file to read."""
    var lib = PgLib.open()
    if lib.path.startswith("/") and exists(lib.path):
        return lib.path
    for p in default_search_path():
        if p.startswith("/") and exists(p):
            return p
    raise Error(
        "libpq opened as `" + lib.path + "`, and no file on the search path"
        " is one to copy: set M0_LIBPQ to the library file"
    )


def _copy_of(path: String) raises -> String:
    """A copy of the library at `path`, which the loader maps as an image of
    its own: it identifies an object by its file. Keyed to the pid, since
    two runs sharing a `$TMPDIR` would otherwise truncate a file the other
    has mapped."""
    var copy = (
        getenv("TMPDIR", "/tmp") + "/"
        + String(Int(external_call["getpid", c_int]())) + COPY_SUFFIX
    )
    var data: List[UInt8]
    with open(path, "r") as f:
        data = f.read_bytes()
    with open(copy, "w") as f:
        f.write_bytes(Span(data))
    return copy


def test_one_image_however_connections_come_and_go() raises:
    """Every open of one libpq file finds the image the first open pinned,
    even after every earlier `PgLib` has gone.

    The first open pins its image and keeps that handle for the life of the
    process. Without the kept handle each reopen below maps another image on
    macOS — the leak this row is about: a process that connects per request
    grew by one libpq, and one copy of each library it links, per request.

    covers: O24
    """
    var first = _table_of_a_dropped_library()
    assert_true(first.image() != 0)
    assert_true(is_pinned(first.image()), "the first open did not pin its image")
    # No `PgLib` holds the library now: only the pin's kept handle.
    for _ in range(5):
        var again = _table_of_a_dropped_library()
        assert_equal(
            again.image(), first.image(), "a reopen mapped another image of libpq"
        )
        assert_equal(again.ntuples(0), 0)
    assert_equal(first.result_status(0), PGRES_FATAL_ERROR)


def test_a_second_library_is_pinned_like_the_first() raises:
    """A second libpq file is a second image, and is pinned, kept and
    answered from exactly as the first is: not refused.

    m0-sqlite refuses a second image because SQLite does not survive two
    copies of itself on one database file (SPEC O23). Nothing in libpq
    forbids two copies in a process, so here each image a process opens is
    pinned once, and a table copied from either answers after every handle
    is gone. The second image is a copy of the library's own file.

    covers: O24
    """
    var first = _table_of_a_dropped_library()
    var copy = _copy_of(_library_file())
    var other = 0
    var reopened = 0
    var failed = String("")
    try:
        var theirs = _table_of_a_dropped_library(copy)
        other = theirs.image()
        var again = _table_of_a_dropped_library(copy)
        reopened = again.image()
        # Each through its own image, after its `PgLib` has gone.
        assert_equal(theirs.ntuples(0), 0)
        assert_equal(again.result_status(0), PGRES_FATAL_ERROR)
    except e:
        failed = String(e)
    remove(copy)
    assert_equal(failed, "", "the second library was refused, or its table failed")
    assert_true(other != 0 and other != first.image(), "the copy is the same image")
    assert_true(is_pinned(other), "the second library was not pinned")
    assert_equal(
        reopened, other, "a reopen mapped another image of the second library"
    )
    assert_true(is_pinned(first.image()), "the first library is no longer pinned")
    assert_equal(first.ntuples(0), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
