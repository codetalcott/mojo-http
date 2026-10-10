"""Tests for the m0serve wheel's console shim: which libpython it names.

The shim (`packaging/m0serve/src/m0serve/__main__.py`) is the `m0serve`
command a `pip install` puts on PATH. It runs inside the interpreter the
application is installed into, names that interpreter's shared libpython in
`MOJO_PYTHON_LIBRARY`, and execs the binary, which starts its own CPython
from that library. When it named nothing, the binary's Mojo runtime looked
for itself, found nothing, and aborted at its first Python call with a
native stack dump, exit 133, `--doctor` included (#612): a relocatable
interpreter whose sysconfig `LIBDIR` is the build machine's path
(python-build-standalone's 3.12.7, `/install/lib`) has its library in
`sys.base_prefix/lib`, and neither looked there.

The rules, each with a test:

* a stale `LIBDIR` falls back to `sys.base_prefix/lib`, and a `LIBDIR` that
  holds the library is still the first answer;
* the search holds every path the Mojo runtime's own lookup tries, so a
  refusal can only happen where the runtime would have aborted: `LIBPL` and
  `LIBDIR` crossed with `libpython{py_version_short}{ABIFLAGS}.{ext}`,
  `RUNTIME_LOOKUP` below being the runtime's script, copied from
  `libKGENCompilerRTShared` (`strings` shows it whole);
* no static archive is named, and `Py_ENABLE_SHARED` is not asked: a macOS
  framework build (python.org's installer, Apple's command-line tools)
  reports 0 and keeps its library in `LIBDIR`. No current Debian or Ubuntu
  reports 0 -- bookworm, trixie, 22.04 and 24.04 all say 1, checked in
  containers on 2026-10-10 -- whatever an earlier version of this file said;
* finding nothing refuses with 78, naming `MOJO_PYTHON_LIBRARY`, before the
  binary runs -- except for the flags answered without an interpreter, and
  where the user set `MOJO_PYTHON_LIBRARY` or `MOJO_PYTHON` themselves;
* the interpreter running this file resolves: it is the one every poe task
  runs m0serve under, so the runtime finds a library for it, and the shim
  must find one too.

    python3 scripts/wheel_shim.py              # run the tests
    python3 scripts/wheel_shim.py --sabotage   # and prove each one bites

`--sabotage` reverts each rule in the shim's source, in memory, and insists
the test written for it fails. A sabotage whose source will not compile is
a MISS, never a catch: it proves the build breaks, not that a test reads
the rule. The file on disk is never written.
"""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SHIM = REPO / "packaging" / "m0serve" / "src" / "m0serve" / "__main__.py"

# The Mojo runtime's own lookup, as `libKGENCompilerRTShared` carries it:
# run in the `python3` it finds, it prints the library or exits 1.
RUNTIME_LOOKUP = '''
import os
import sys
from pathlib import Path
from sysconfig import get_config_var
ext = "dll" if os.name == "nt" else "dylib" if sys.platform == "darwin" else "so"
pyver = get_config_var("py_version_short")
abiflags = get_config_var("ABIFLAGS") or ""
binary = f"libpython{pyver}{abiflags}.{ext}"
for libpython in [Path(get_config_var(p)) / binary for p in ["LIBPL", "LIBDIR"]]:
    if libpython.exists():
        print(libpython.resolve())
        exit(0)
exit(1)
'''


def load(source=None):
    """The shim as a module, from its file or from a sabotaged copy."""
    mod = types.ModuleType("m0serve_shim_under_test")
    mod.__file__ = str(SHIM)
    exec(compile(SHIM.read_text() if source is None else source, str(SHIM), "exec"),
         mod.__dict__)
    return mod


def config(**values):
    return values.get


def touch(root, rel):
    path = Path(root) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"")
    return path


def runtime_finds(cfg, platform):
    """What RUNTIME_LOOKUP would print for this configuration, or None."""
    ext = "dylib" if platform == "darwin" else "so"
    binary = "libpython%s%s.%s" % (cfg("py_version_short"), cfg("ABIFLAGS") or "", ext)
    for var in ("LIBPL", "LIBDIR"):
        if cfg(var) and (Path(cfg(var)) / binary).exists():
            return Path(cfg(var)) / binary
    return None


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


# --- The search ---------------------------------------------------------------

def test_a_stale_libdir_falls_back_to_base_prefix(shim):
    # The interpreter #612 was filed against, as sysconfig describes it.
    with tempfile.TemporaryDirectory() as root:
        lib = touch(root, "lib/libpython3.12.dylib")
        cfg = config(Py_ENABLE_SHARED=1, LIBDIR="/install/lib",
                     LIBPL="/install/lib/python3.12/config-3.12-darwin",
                     INSTSONAME="libpython3.12.dylib", LDLIBRARY="libpython3.12.dylib",
                     MULTIARCH="darwin", py_version_short="3.12", ABIFLAGS="")
        got = shim._libpython(shim._libpython_candidates(cfg, root, "darwin"))
        check(got == lib, f"a LIBDIR of /install/lib found {got}, not {lib}")


def test_a_libdir_that_holds_the_library_is_still_first(shim):
    with tempfile.TemporaryDirectory() as root:
        want = touch(root, "real/lib/libpython3.12.so.1.0")
        touch(root, "prefix/lib/libpython3.12.so.1.0")
        cfg = config(Py_ENABLE_SHARED=1, LIBDIR=str(Path(root) / "real/lib"),
                     INSTSONAME="libpython3.12.so.1.0", LDLIBRARY="libpython3.12.so",
                     py_version_short="3.12", ABIFLAGS="")
        got = shim._libpython(
            shim._libpython_candidates(cfg, str(Path(root) / "prefix"), "linux"))
        check(got == want, f"a LIBDIR holding the library lost to {got}")


def test_a_static_archive_is_never_named(shim):
    with tempfile.TemporaryDirectory() as root:
        touch(root, "lib/libpython3.12.a")
        touch(root, "lib/python3.12/config-3.12-x86_64-linux-gnu/libpython3.12.a")
        cfg = config(Py_ENABLE_SHARED=0, LIBDIR=str(Path(root) / "lib"),
                     LIBPL=str(Path(root) / "lib/python3.12/config-3.12-x86_64-linux-gnu"),
                     INSTSONAME="libpython3.12.a", LDLIBRARY="libpython3.12.a",
                     py_version_short="3.12", ABIFLAGS="")
        got = shim._libpython(shim._libpython_candidates(cfg, root, "linux"))
        check(got is None, f"a build with only an archive named {got}")


def test_a_framework_build_is_named(shim):
    # python.org's macOS installer, as its sysconfig describes it (3.13.7,
    # read 2026-10-10): Py_ENABLE_SHARED 0, INSTSONAME inside the framework,
    # and libpython3.13.dylib in LIBDIR, which is what the runtime loads.
    with tempfile.TemporaryDirectory() as root:
        fw = Path(root) / "Library/Frameworks/Python.framework/Versions/3.13"
        lib = touch(fw, "lib/libpython3.13.dylib")
        cfg = config(Py_ENABLE_SHARED=0, LIBDIR=str(fw / "lib"),
                     LIBPL=str(fw / "lib/python3.13/config-3.13-darwin"),
                     PYTHONFRAMEWORK="Python", MULTIARCH="darwin",
                     INSTSONAME="Python.framework/Versions/3.13/Python",
                     LDLIBRARY="Python.framework/Versions/3.13/Python",
                     py_version_short="3.13", ABIFLAGS="")
        got = shim._libpython(shim._libpython_candidates(cfg, str(fw), "darwin"))
        check(got == lib, f"a framework build's libpython was not named (got {got})")


def test_every_path_the_runtime_tries_is_searched(shim):
    # For each path RUNTIME_LOOKUP tries, a layout holding only that file,
    # and a sysconfig that names something else first: a python.org
    # framework build (INSTSONAME inside the framework, Py_ENABLE_SHARED 0),
    # a free-threaded build, and an unversioned dev symlink in LIBPL.
    cases = [
        ("darwin", "3.12", "", "Python.framework/Versions/3.12/Python", "LIBDIR"),
        ("darwin", "3.12", "", "Python.framework/Versions/3.12/Python", "LIBPL"),
        ("darwin", "3.14", "t", "libpython3.14t.dylib.missing", "LIBDIR"),
        ("linux", "3.12", "", "libpython3.12.so.1.0", "LIBPL"),
        ("linux", "3.14", "t", "libpython3.14t.so.1.0", "LIBDIR"),
    ]
    for platform, ver, flags, soname, where in cases:
        with tempfile.TemporaryDirectory() as root:
            dirs = {"LIBDIR": str(Path(root) / "lib"),
                    "LIBPL": str(Path(root) / f"lib/python{ver}/config")}
            ext = "dylib" if platform == "darwin" else "so"
            touch(dirs[where], f"libpython{ver}{flags}.{ext}")
            cfg = config(Py_ENABLE_SHARED=0, INSTSONAME=soname, LDLIBRARY=soname,
                         py_version_short=ver, ABIFLAGS=flags, **dirs)
            runtime = runtime_finds(cfg, platform)
            check(runtime is not None, f"fixture: the runtime finds nothing in {where}")
            got = shim._libpython(
                shim._libpython_candidates(cfg, str(Path(root) / "elsewhere"), platform))
            check(got is not None,
                  f"the runtime finds {runtime.name} in {where}; the shim finds nothing")


# --- main: export, exec, or refuse -------------------------------------------

@contextlib.contextmanager
def driven(shim, candidates, environ):
    """Run `shim.main` with a recorded execve, a fixed search and environment."""
    calls = []
    real_execve, real_cands = os.execve, shim._libpython_candidates
    saved = dict(os.environ)
    os.execve = lambda path, argv, env: calls.append((path, argv, env))
    shim._libpython_candidates = lambda *a, **k: list(candidates)
    os.environ.clear()
    os.environ.update(environ)
    try:
        yield calls
    finally:
        os.execve, shim._libpython_candidates = real_execve, real_cands
        os.environ.clear()
        os.environ.update(saved)


def run_main(shim, argv, candidates, environ):
    """(exit code or None, stderr, the execve calls)."""
    err, code = io.StringIO(), None
    with tempfile.TemporaryDirectory() as root:
        shim._EXE = touch(root, "_bin/m0serve")  # the binary-missing check passes
        with driven(shim, candidates, environ) as calls, contextlib.redirect_stderr(err):
            try:
                shim.main(argv)
            except SystemExit as e:
                code = e.code
    return code, err.getvalue(), calls


BASE_ENV = {"PATH": "/usr/bin:/bin", "HOME": "/tmp"}


def test_nothing_found_refuses_with_78_naming_the_variable(shim):
    code, err, calls = run_main(shim, ["m0serve", "app", "--doctor"],
                                [Path("/nonexistent/m0serve-test/libpython3.12.dylib")],
                                BASE_ENV)
    check(code == 78, f"no libpython exited {code!r}, not 78")
    check(not calls, "no libpython still exec'd the binary, which then aborts")
    check("MOJO_PYTHON_LIBRARY" in err, f"the refusal does not name the variable: {err!r}")
    check("/nonexistent/m0serve-test" in err, f"the refusal does not say where it looked: {err!r}")


def test_a_found_library_is_exported(shim):
    with tempfile.TemporaryDirectory() as root:
        lib = touch(root, "lib/libpython3.12.dylib")
        code, _, calls = run_main(shim, ["m0serve", "app"], [lib], BASE_ENV)
    check(code is None and len(calls) == 1, f"a found library did not exec (exit {code!r})")
    check(calls[0][2].get("MOJO_PYTHON_LIBRARY") == str(lib),
          f"MOJO_PYTHON_LIBRARY is {calls[0][2].get('MOJO_PYTHON_LIBRARY')!r}")


def test_the_users_own_settings_are_left_to_the_runtime(shim):
    missing = [Path("/nonexistent/m0serve-test/libpython3.12.dylib")]
    mine = dict(BASE_ENV, MOJO_PYTHON_LIBRARY="/opt/py/libpython3.12.dylib")
    code, _, calls = run_main(shim, ["m0serve", "app"], missing, mine)
    check(code is None and calls, f"a user's MOJO_PYTHON_LIBRARY was refused (exit {code!r})")
    check(calls[0][2]["MOJO_PYTHON_LIBRARY"] == "/opt/py/libpython3.12.dylib",
          "a user's MOJO_PYTHON_LIBRARY was replaced")
    other = dict(BASE_ENV, MOJO_PYTHON="/opt/py/bin/python3")
    code, _, calls = run_main(shim, ["m0serve", "app"], missing, other)
    check(code is None and calls, f"a user's MOJO_PYTHON was refused (exit {code!r})")


def test_flags_answered_without_python_are_not_refused(shim):
    missing = [Path("/nonexistent/m0serve-test/libpython3.12.dylib")]
    for flag in ("--version", "-V", "--help", "-h"):
        code, _, calls = run_main(shim, ["m0serve", flag], missing, BASE_ENV)
        check(code is None and calls, f"`m0serve {flag}` was refused (exit {code!r})")


def test_this_interpreter_resolves(shim):
    got = shim._libpython()
    check(got is not None and got.is_file(),
          f"{sys.executable}: the shim finds no libpython for the interpreter "
          f"every poe task runs m0serve under (searched "
          f"{[str(c) for c in shim._libpython_candidates()]})")
    found = subprocess.run([sys.executable, "-c", RUNTIME_LOOKUP], capture_output=True,
                           text=True)
    if found.returncode == 0:
        check(Path(found.stdout.strip()).resolve() in
              {c.resolve() for c in shim._libpython_candidates() if c.is_file()},
              f"the runtime finds {found.stdout.strip()}, which the shim's search lacks")


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]


# --- Sabotage -------------------------------------------------------------------

# (what is reverted, the exact text, its replacement, the tests written for it)
SABOTAGES = [
    ("sys.base_prefix/lib is not searched",
     'os.path.join(base_prefix, "lib") if base_prefix else None,', "None,",
     ["test_a_stale_libdir_falls_back_to_base_prefix"]),
    ("LIBPL is not searched",
     'config("LIBPL"),', "None,",
     ["test_every_path_the_runtime_tries_is_searched"]),
    ("the runtime's plain name is not searched",
     'for name in (config("INSTSONAME"), config("LDLIBRARY"), plain):',
     'for name in (config("INSTSONAME"), config("LDLIBRARY")):',
     ["test_every_path_the_runtime_tries_is_searched"]),
    ("Py_ENABLE_SHARED decides again",
     "    platform = sys.platform if platform is None else platform\n",
     "    platform = sys.platform if platform is None else platform\n"
     '    if not config("Py_ENABLE_SHARED"):\n        return []\n',
     ["test_a_framework_build_is_named",
      "test_every_path_the_runtime_tries_is_searched"]),
    ("a static archive may be named",
     'if name and not name.endswith(".a") and name not in names:',
     "if name and name not in names:",
     ["test_a_static_archive_is_never_named"]),
    ("the search's order puts sys.base_prefix first",
     "        config(\"LIBDIR\"),\n        config(\"LIBPL\"),\n",
     "        os.path.join(base_prefix, \"lib\") if base_prefix else None,\n"
     "        config(\"LIBDIR\"),\n        config(\"LIBPL\"),\n",
     ["test_a_libdir_that_holds_the_library_is_still_first"]),
    ("finding nothing does not refuse",
     "        sys.exit(78)\n", "        pass\n",
     ["test_nothing_found_refuses_with_78_naming_the_variable"]),
    ("the refusal does not name the fix",
     'f"Set MOJO_PYTHON_LIBRARY to the interpreter\'s libpython, or use "',
     'f"Use "',
     ["test_nothing_found_refuses_with_78_naming_the_variable"]),
    ("a found library is not exported",
     '            env["MOJO_PYTHON_LIBRARY"] = str(lib)\n', "            pass\n",
     ["test_a_found_library_is_exported"]),
    ("the user's MOJO_PYTHON is refused",
     '        and "MOJO_PYTHON" not in env\n', "",
     ["test_the_users_own_settings_are_left_to_the_runtime"]),
    ("--version and --help are refused",
     "        and not any(arg in _NO_PYTHON for arg in argv[1:])\n", "",
     ["test_flags_answered_without_python_are_not_refused"]),
]


def run(tests, shim):
    """Names of the tests that failed, with why."""
    failed = []
    for test in tests:
        try:
            test(shim)
        except AssertionError as e:
            failed.append((test.__name__, str(e)))
    return failed


def sabotage():
    source, ok = SHIM.read_text(), True
    by_name = {t.__name__: t for t in TESTS}
    for what, old, new, catchers in SABOTAGES:
        n = source.count(old)
        if n != 1:
            print(f"  ANCHOR   {what}: the text occurs {n} times in the shim")
            ok = False
            continue
        try:
            shim = load(source.replace(old, new))
        except SyntaxError as e:
            print(f"  MISSED   {what}: the sabotaged shim does not compile ({e})")
            ok = False
            continue
        try:
            failed = run([by_name[c] for c in catchers], shim)
        except Exception as e:  # a crash is not the assertion the rule needs
            print(f"  MISSED   {what}: a catcher crashed ({type(e).__name__}: {e})")
            ok = False
            continue
        if failed:
            print(f"  CAUGHT   {what} (by {failed[0][0]})")
        else:
            print(f"  MISSED   {what}: {', '.join(catchers)} still pass")
            ok = False
    print("wheel_shim --sabotage: " + ("every rule caught" if ok else "FAILED"))
    return ok


def main(argv):
    if argv[1:] == ["--sabotage"]:
        return 0 if sabotage() else 1
    if argv[1:]:
        print("usage: python3 scripts/wheel_shim.py [--sabotage]")
        return 2
    failed = run(TESTS, load())
    for name, why in failed:
        print(f"  FAIL  {name}: {why}")
    print(f"wheel_shim: {len(TESTS) - len(failed)} of {len(TESTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
