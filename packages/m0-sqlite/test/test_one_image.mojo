"""One libsqlite3 image per process (`lib.mojo`, SPEC O23), and the backstop
behind it for registered functions (O22).

A process of its own, on purpose. The package holds a process to the first
libsqlite3 it opens, so tests that need a particular one cannot share a
process with tests that opened another first. This file wants a library
backed by a FILE — the only kind macOS ever dropped from its loader's list,
which is what O23 was found by — so `main` names one in `M0_LIBSQLITE3`
before any test opens anything, unless the caller already named a library.

The second image the refusals need is found by asking the loader which
image a file is (`sqlite3_libversion`'s address), never by comparing paths:
`/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib` and its Cellar spelling are
one file. On Linux it is a copy of the system library; on macOS whichever
of Apple's and Homebrew's builds this process is not using, so without
Homebrew's there is none, and each test that needs one says so.
"""

from std.collections.span import Span
from std.ffi import OwnedDLHandle
from std.memory import stack_allocation
from std.os import getenv, remove, setenv, unsetenv
from std.os.path import exists
from std.sys import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from src import Answer, Args, ScalarFunction, open_memory
from src.ffi import (
    SQLITE_OK,
    SQLITE_OPEN_CREATE,
    SQLITE_OPEN_READWRITE,
    c_string,
)
from src.function import _publish
from src.lib import (
    SqliteFns,
    _open_flags,
    as_cstr,
    default_search_path,
    open_library,
    pinned_image,
    pinned_path,
)

comptime BREW = "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"
comptime APPLE = "/usr/lib/libsqlite3.dylib"
comptime COPY_NAME = "/m0-sqlite-second-image.so"


struct AddN(ScalarFunction):
    comptime arity: Int = 1
    comptime deterministic: Bool = True
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def call(mut self, args: Args, mut answer: Answer) raises:
        answer.int(args.int(0) + self.n)


def _file_backed_library() -> String:
    """A libsqlite3 the loader maps from a file of its own, or "".

    macOS: Homebrew's build. Apple's lives in the dyld shared cache, where no
    image is ever dropped, so it cannot show what O23 is about. Linux: the
    system library by its path, whose loader keeps a `RTLD_NODELETE` object
    findable anyway, so there the reopen states the property without being
    able to lose it.
    """
    comptime if CompilationTarget.is_macos():
        return String(BREW) if exists(BREW) else String("")
    else:
        for p in default_search_path():
            if p.startswith("/") and exists(p):
                return p
        return String("")


def _image_of(path: String) raises -> Int:
    """Which image the loader gives for `path`: `sqlite3_libversion`'s
    address, as `SqliteFns.image` names one. Asked of the loader directly,
    since `open_library` would refuse the very library this is looking for."""
    var handle = OwnedDLHandle(path, _open_flags())
    var symbol = handle.get_symbol[UInt8]("sqlite3_libversion")
    if not symbol:
        raise Error(path + " has no sqlite3_libversion")
    return Int(symbol.value())


def _second_image() raises -> String:
    """A libsqlite3 file that is not the image this process is pinned to, or
    "" when this host has none. Call after the first connection."""
    var pinned = pinned_image()
    comptime if CompilationTarget.is_macos():
        if exists(BREW) and _image_of(BREW) != pinned:
            return String(BREW)
        if _image_of(APPLE) != pinned:
            return String(APPLE)
        return String("")
    else:
        # A copy is a second image: the loader identifies an object by its
        # file, and a path with a slash never matches a loaded soname.
        for p in default_search_path():
            if p.startswith("/") and exists(p):
                var copy = getenv("TMPDIR", "/tmp") + COPY_NAME
                var data: List[UInt8]
                with open(p, "r") as f:
                    data = f.read_bytes()
                with open(copy, "w") as f:
                    f.write_bytes(Span(data))
                return copy
        return String("")


def _forget(other: String) raises:
    """Remove the copy `_second_image` made, if `other` is one."""
    if other.endswith(COPY_NAME) and exists(other):
        remove(other)


def _is_loaded(path: String) -> Bool:
    """Whether the loader still has the file at `path` mapped: `RTLD_NOLOAD`
    opens only what is already there (glibc's value; Linux only)."""
    try:
        var probe = OwnedDLHandle(path, 1 | 4)
        _ = probe.check_symbol("sqlite3_libversion")
        return True
    except:
        return False


def _nothing_to_refuse() -> Bool:
    print("    (no second libsqlite3 image on this host; the refusal is not exercised)")
    return True


def test_one_image_however_connections_come_and_go() raises:
    """Every connection of a process calls into ONE image of its libsqlite3,
    even after every earlier connection has closed.

    SQLite requires it: two copies in one process each keep their own list of
    open files, so a close through one drops the POSIX locks the other holds
    on the same file ("How To Corrupt An SQLite Database File", 2.2.1), and a
    registered function's callbacks reach one image. macOS drops an image
    opened `RTLD_NODELETE` from dyld's list once its last handle closes --
    the code stays mapped, which is why O18 held -- and the next `dlopen` of
    the path maps a fresh copy: measured with Homebrew's build, a new image
    at every reopen until `pin_library` kept a handle. Without that handle
    the reopen below is a second image, which the pin now refuses outright.

    covers: O23
    """
    var first = open_memory()
    var path = first.library_path()
    var first_image = first._lib.fns.image()
    assert_true(first_image != 0)
    assert_equal(pinned_image(), first_image, "the first connection pins its image")
    assert_true(len(pinned_path().as_bytes()) > 0)
    first.close()
    _ = first^
    # No connection holds the library now: only the pin's kept handle.
    var reopened = String("")
    var second_image = 0
    try:
        var second = open_memory()
        second_image = second._lib.fns.image()
        assert_equal(second.query_scalar("SELECT 1"), "1")
    except e:
        reopened = String(e)
    assert_equal(reopened, "", "a reopen of " + path + " was refused")
    assert_equal(first_image, second_image, "a reopen mapped another image of " + path)
    assert_equal(pinned_image(), first_image)
    comptime if CompilationTarget.is_macos():
        if not exists(path):
            print(
                "    (", path, "is in the dyld shared cache, where no image is"
                " dropped: the reopen cannot fail here)"
            )


def test_a_second_image_is_refused_at_open() raises:
    """A libsqlite3 that is another image than the one this process opened
    first is refused where it is opened — by name, and through
    `M0_LIBSQLITE3`, the way a deployment would bring one — naming both
    files. The refusal comes before anything of the second library is
    pinned: the process's image is unchanged, the first library still opens,
    and on Linux the refused copy is no longer mapped at all.

    covers: O23
    """
    var db = open_memory()
    var ours = pinned_path()
    var image = pinned_image()
    assert_equal(db._lib.fns.image(), image)
    var other = _second_image()
    if not other:
        _ = _nothing_to_refuse()
        return

    var by_name = String("")
    try:
        _ = open_library(other)
    except e:
        by_name = String(e)

    var before = getenv("M0_LIBSQLITE3", "")
    _ = setenv("M0_LIBSQLITE3", other, True)
    var by_env = String("")
    try:
        _ = open_memory()
    except e:
        by_env = String(e)
    if before:
        _ = setenv("M0_LIBSQLITE3", before, True)
    else:
        _ = unsetenv("M0_LIBSQLITE3")

    var still_loaded = False
    comptime if not CompilationTarget.is_macos():
        still_loaded = _is_loaded(other)
    _forget(other)

    assert_true("is not the image this process already opened" in by_name, by_name)
    assert_true(other in by_name, by_name)
    assert_true(ours in by_name, "the refusal does not name the library to keep: " + by_name)
    assert_equal(by_env, by_name, "the same refusal through M0_LIBSQLITE3")
    assert_false(still_loaded, "the refused library is still mapped: it was pinned")
    assert_equal(pinned_image(), image, "a refused library became the process's image")

    var again = open_memory()
    assert_equal(again._lib.fns.image(), image)
    assert_equal(again.query_scalar("SELECT 41 + 1"), "42")
    assert_equal(db.query_scalar("SELECT 1"), "1")


def test_another_copy_of_sqlite_is_not_bound_into_this_one() raises:
    """A second libsqlite3 loaded into the process by something else must
    still be a working SQLite of its own. With this package's image in the
    loader's global scope it is not, on a build whose internal calls go
    through that scope (Ubuntu's): the copy's `sqlite3_initialize` resolves
    into the first image, the copy never registers a VFS, and every open on
    it answers "no such vfs". So every handle here is `RTLD_LOCAL`. The
    package refuses a second image of its own; this is the one it cannot
    refuse, stood in for by a table built straight from a handle.

    covers: O23
    """
    var db = open_memory()
    db.execute("CREATE TABLE t (x INTEGER)")
    var other = _second_image()
    if not other:
        _ = _nothing_to_refuse()
        return
    var handle = OwnedDLHandle(other, _open_flags())
    var fns = SqliteFns(handle, other)
    var apart = fns.image() != pinned_image()

    var pp = stack_allocation[1, Int]()
    pp[unsafe_offset=0] = 0
    var cpath = c_string(":memory:")
    var rc = fns.open_v2(
        as_cstr(cpath), Int(pp), SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, 0
    )
    _ = cpath
    var theirs = pp[unsafe_offset=0]
    var said = fns.errmsg(theirs)
    if theirs != 0:
        _ = fns.close_v2(theirs)
    # The handle's last mention comes after the last call through its table:
    # nothing pinned this library, so it unloads when the handle goes
    # (`lib.mojo`'s first rule, which `SqliteLib` exists to hold).
    _ = handle
    _forget(other)

    assert_true(apart, "the copy is the same image")
    assert_equal(rc, SQLITE_OK, "the second copy could not open a database: " + said)
    assert_equal(db.query_scalar("SELECT count(*) FROM t"), "0")


def test_a_table_of_another_image_may_not_register() raises:
    """The backstop behind the loader's refusal. A callback reaches one
    library, so a registration through a table of another image is refused
    by `_publish`, the first thing a registration does, naming the file the
    process's functions already call. No `Connection` can bring such a table
    any more — `open_library` refuses the library first — so this hands
    `_publish` one built straight from a handle, with no database on it.

    covers: O22
    """
    var db = open_memory()
    db.create_function("add_one", AddN(1))
    var other = _second_image()
    if not other:
        _ = _nothing_to_refuse()
        return
    var refused = String("")
    try:
        var handle = OwnedDLHandle(other, _open_flags())
        var fns = SqliteFns(handle, other)
        _ = _publish(fns, other)
        # After the last call through its table, as above.
        _ = handle
    except e:
        refused = String(e)
    _forget(other)
    assert_true("is not the image" in refused, refused)
    assert_true(other in refused, refused)
    assert_true(
        "set M0_LIBSQLITE3 to " + db.library_path() in refused,
        "the refusal does not name the library to keep: " + refused,
    )
    assert_equal(db.query_scalar("SELECT add_one(1)"), "2")


def main() raises:
    # Before any test opens a library: this process is held to the first.
    if not getenv("M0_LIBSQLITE3", ""):
        var path = _file_backed_library()
        if path:
            _ = setenv("M0_LIBSQLITE3", path, True)
    TestSuite.discover_tests[__functions_in_module()]().run()
