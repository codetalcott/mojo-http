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

The third test is the scope every handle is opened with, which is what
makes a second libpq in the process sound on Linux. It asks the loader
directly, and can fail on both platforms.
"""

from std.collections.span import Span
from std.ffi import OwnedDLHandle, c_int, external_call
from std.os import getenv, remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from src.lib import (
    PGRES_FATAL_ERROR,
    PgFns,
    PgLib,
    default_search_path,
    is_pinned,
    pinned_count,
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
    And the pin is taken once: a reopen that pinned again would leak a
    handle and a record per open, on every platform.

    covers: O24
    """
    var first = _table_of_a_dropped_library()
    assert_true(first.image() != 0)
    assert_true(is_pinned(first.image()), "the first open did not pin its image")
    var pinned = pinned_count()
    # No `PgLib` holds the library now: only the pin's kept handle.
    for _ in range(5):
        var again = _table_of_a_dropped_library()
        assert_equal(
            again.image(), first.image(), "a reopen mapped another image of libpq"
        )
        assert_equal(again.ntuples(0), 0)
    assert_equal(pinned_count(), pinned, "a reopen pinned its image again")
    assert_equal(first.result_status(0), PGRES_FATAL_ERROR)


def test_a_second_library_is_pinned_like_the_first() raises:
    """A second libpq file is a second image, and is pinned, kept and
    answered from exactly as the first is: not refused.

    m0-sqlite refuses a second image because SQLite does not survive two
    copies of itself on one database file (SPEC O23). libpq has no such
    rule, so here each image a process opens is pinned once, and a table
    copied from either answers after every handle is gone.

    The second image is a copy of the library's own file, so this holds the
    pin and not the coexistence of two BUILDS, which a copy cannot show:
    that is the scope's doing (the next test), and was measured with a
    second build by hand (docs/notes/libpq-keeps-its-handle.md).

    covers: O24
    """
    var first = _table_of_a_dropped_library()
    var file = _library_file()
    var copy = _copy_of(file)
    var before = pinned_count()
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
    assert_equal(
        failed,
        "",
        "a copy of " + file + " was refused, or its table failed. If it could"
        " not be opened at all, its dependencies may be relative to its own"
        " directory, which a copy elsewhere cannot follow: name a libpq whose"
        " dependencies are absolute in M0_LIBPQ",
    )
    assert_true(other != 0 and other != first.image(), "the copy is the same image")
    assert_true(is_pinned(other), "the second library was not pinned")
    assert_equal(
        reopened, other, "a reopen mapped another image of the second library"
    )
    assert_equal(
        pinned_count(), before + 1, "the second library was not pinned exactly once"
    )
    assert_true(is_pinned(first.image()), "the first library is no longer pinned")
    assert_equal(first.ntuples(0), 0)


def test_libpq_stays_out_of_the_loaders_global_scope() raises:
    """Opening libpq through this package leaves it out of the loader's
    global scope: the open is `RTLD_LOCAL`, and so is the pin's re-open,
    which would otherwise promote it.

    An image in the global scope captures the internal calls of any libpq
    loaded after it, on glibc and for a build not linked `-Bsymbolic`:
    measured with Ubuntu's libpq 16.15 first and psycopg-binary's bundled
    18.6 second, 70 symbols bound across and a connection attempt through
    the second crashed. So the property is asked of the loader itself: a
    lookup through the process's own handle searches the global scope, and
    must not find libpq there. Nothing else in this process loads one.

    covers: O24
    """
    var lib = PgLib.open()
    assert_true(lib.libversion() > 0)
    var process = OwnedDLHandle()
    assert_false(
        process.check_symbol("PQlibVersion"),
        "libpq is in the loader's global scope: a second libpq loaded into"
        " this process would have its calls bound into this one",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
