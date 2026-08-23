"""Tests for `MtimeScanner`, the change detector behind `--reload`.

Real files in a real temporary directory: the whole point of this module is
what `listdir` and `stat` report about a tree that is being edited, and a
fake filesystem would test the fake. Each test makes its own directory under
`TMPDIR` and removes it afterwards.

**Forking is not tested here**, for the reason `test_lifecycle.mojo` records:
a child forked out of the test binary resumes inside the test runner. The
reload path that forks is proven end to end by `poe smoke-reload`, which
starts a real server, edits a real `.py`, and asserts a *new worker pid*
serves the change.
"""

from std.os import listdir, makedirs, remove, rmdir, getenv
from std.os.path import exists, isdir
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.time import sleep

from src.reload import MtimeScanner, ScanResult


def _tmpdir(name: String) raises -> String:
    """A fresh directory named for its test, removed by `_cleanup`."""
    var base = getenv("TMPDIR", "/tmp")
    if not base.endswith("/"):
        base += "/"
    var path = base + "m0-reload-test-" + name
    _cleanup(path)
    makedirs(path, exist_ok=True)
    return path^


def _cleanup(path: String):
    """Remove the tree; missing pieces are not an error."""
    try:
        var names = listdir(path)
        for i in range(len(names)):
            var child = path + "/" + String(names[i])
            if isdir(child):
                _cleanup(child)
            else:
                remove(child)
        rmdir(path)
    except:
        pass


def _write(path: String, body: String) raises:
    with open(path, "w") as f:
        f.write(body)


def _dirs(path: String) -> List[String]:
    var d = List[String]()
    d.append(path)
    return d^


def test_first_pass_records_and_reports_nothing() raises:
    """A supervisor that reloaded at startup would report only that it began."""
    var dir = _tmpdir("first")
    _write(dir + "/a.py", "x = 1\n")
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    assert_false(scanner.changed(), "the first pass must be a baseline")
    assert_equal(scanner.watching(), 1)
    _cleanup(dir)


def test_an_unchanged_tree_stays_unchanged() raises:
    var dir = _tmpdir("stable")
    _write(dir + "/a.py", "x = 1\n")
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    _ = scanner.changed()
    assert_false(scanner.changed())
    assert_false(scanner.changed())
    _cleanup(dir)


def test_a_rewritten_file_is_a_change() raises:
    var dir = _tmpdir("rewrite")
    _write(dir + "/a.py", "x = 1\n")
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    _ = scanner.changed()
    # Filesystem timestamp granularity is coarser than this loop; sleep past
    # it so the rewrite is distinguishable from the create.
    sleep(0.05)
    _write(dir + "/a.py", "x = 2\n")
    assert_true(scanner.changed(), "a rewritten file must be seen")
    assert_false(scanner.changed(), "and then only once")
    _cleanup(dir)


def test_a_new_file_is_a_change() raises:
    var dir = _tmpdir("added")
    _write(dir + "/a.py", "x = 1\n")
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    _ = scanner.changed()
    sleep(0.05)
    _write(dir + "/b.py", "y = 2\n")
    assert_true(scanner.changed())
    assert_equal(scanner.watching(), 2)
    _cleanup(dir)


def test_a_deleted_file_is_a_change() raises:
    """The reason a pass carries a file count and not an mtime alone.

    Deleting the newest file leaves the maximum mtime in the past, so a
    high-water mark would see nothing. The count moves, and the comparison
    is against the previous pass rather than against a maximum.
    """
    var dir = _tmpdir("deleted")
    _write(dir + "/a.py", "x = 1\n")
    _write(dir + "/b.py", "y = 2\n")
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    _ = scanner.changed()
    assert_equal(scanner.watching(), 2)
    remove(dir + "/b.py")
    assert_true(scanner.changed(), "a deletion must be seen")
    assert_equal(scanner.watching(), 1)
    _cleanup(dir)


def test_only_the_named_suffix_counts() raises:
    """`m0-http` has no notion of a source file; the caller names the suffix."""
    var dir = _tmpdir("suffix")
    _write(dir + "/a.py", "x = 1\n")
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    _ = scanner.changed()
    sleep(0.05)
    _write(dir + "/notes.txt", "not source\n")
    assert_false(scanner.changed(), "a .txt must not trigger a Python reload")
    assert_equal(scanner.watching(), 1)
    _cleanup(dir)


def test_subdirectories_are_walked() raises:
    var dir = _tmpdir("nested")
    makedirs(dir + "/pkg/sub", exist_ok=True)
    _write(dir + "/pkg/sub/deep.py", "x = 1\n")
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    _ = scanner.changed()
    assert_equal(scanner.watching(), 1)
    sleep(0.05)
    _write(dir + "/pkg/sub/deep.py", "x = 2\n")
    assert_true(scanner.changed())
    _cleanup(dir)


def test_pycache_is_ignored() raises:
    """It is written BY the import a reload causes — watching it never settles."""
    var dir = _tmpdir("pycache")
    _write(dir + "/a.py", "x = 1\n")
    makedirs(dir + "/__pycache__", exist_ok=True)
    var scanner = MtimeScanner(_dirs(dir), String(".py"))
    _ = scanner.changed()
    assert_equal(scanner.watching(), 1)
    sleep(0.05)
    _write(dir + "/__pycache__/a.cpython-313.py", "compiled\n")
    assert_false(scanner.changed(), "__pycache__ must never trigger a reload")
    _cleanup(dir)


def test_a_missing_directory_is_not_an_error() raises:
    """A build tool deleting a directory mid-scan must not kill the reloader."""
    var scanner = MtimeScanner(
        _dirs(String("/no/such/directory/anywhere")), String(".py")
    )
    assert_false(scanner.changed())
    assert_equal(scanner.watching(), 0)
    assert_false(scanner.changed())


def test_several_directories_are_watched_together() raises:
    var one = _tmpdir("multi-one")
    var two = _tmpdir("multi-two")
    _write(one + "/a.py", "x = 1\n")
    _write(two + "/b.py", "y = 2\n")
    var dirs = List[String]()
    dirs.append(one)
    dirs.append(two)
    var scanner = MtimeScanner(dirs^, String(".py"))
    _ = scanner.changed()
    assert_equal(scanner.watching(), 2)
    sleep(0.05)
    _write(two + "/b.py", "y = 3\n")
    assert_true(scanner.changed(), "the second directory is watched too")
    _cleanup(one)
    _cleanup(two)


def test_describe_names_every_directory() raises:
    var dirs = List[String]()
    dirs.append(String("/a"))
    dirs.append(String("/b"))
    var scanner = MtimeScanner(dirs^, String(".py"))
    assert_equal(scanner.describe(), String("/a, /b"))


def test_scan_result_equality() raises:
    assert_true(ScanResult(5, 1) == ScanResult(5, 1))
    assert_true(ScanResult(5, 1) != ScanResult(5, 2))
    assert_true(ScanResult(5, 1) != ScanResult(6, 1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
