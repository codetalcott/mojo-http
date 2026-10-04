#!/usr/bin/env python3
"""Run a package's Mojo test files from ONE build, each file in its own process.

    python3 scripts/mojo_suite.py packages/m0-http -I packages/m0-http -I packages/m0-core
    python3 scripts/mojo_suite.py --selftest
    python3 scripts/mojo_suite.py --sabotage

`poe test-http`, `test-core`, `test-datastar` and `test-wsgi` run this.
`poe test-http` was `for f in test/test_*.mojo; do mojo run ... "$f"; done`,
and every `mojo run` compiled m0-http from source again: 61 whole programs,
each re-parsing and re-generating the same library for a few seconds of
tests (459-579 s of CI's cold `unit-tests` on ubuntu, 7 s of it the tests
running). This builds the files as one program and runs that program once
per file, so the library is compiled once and each file still runs in a
process of its own, as before: nothing one file does to its process
(signal dispositions, environment, threads, forks) reaches the next.

HOW. A test file cannot simply be imported by a runner: its `main()` is
refused inside a package ("'main()' is not supported within packages"), and
`test/__init__.mojo` makes `test/` one. So the runner is built in a
directory of its own, `bin/suite/<package>/`, holding a symlink to each test
file (a top-level module there, where `main()` is allowed), a symlink `src`
to the package's own `src`, and the generated `_suite.mojo`. The `src` link
keeps the package's own `src` first whatever the `-I` order, as
`test/__init__.mojo` does for `mojo run` of one file: the entry file's own
directory is searched before any `-I` root. `test_resolution.mojo` holds
both. The directory's path is stable, so Mojo's compile cache, keyed by the
whole program, hits on a re-run.

The runner registers each file's tests itself, one `suite.test[...]()` per
`def test_*(` at column 0, and never calls the file's `main()`. Calling it
was the first design, and Mojo 1.1.0's `__functions_in_module()` does not
survive it: evaluated in an imported module it registered nothing for 3 of
m0-http's 61 files, and on one of those built alone the compiler crashed.
So two rules are checked here instead of trusted: every file's `main()` is
the discovery one-liner (anything more would be skipped), and every
column-0 `def test_` is one this registers (a form it cannot read fails the
run rather than dropping the test).

An imported module is elaborated only as far as something reaches it, so a
helper nothing calls, an import nothing uses, or the file's own `main()`
would build with an error in it, where `mojo run` of the file fails. So
each file is also checked as a file of its own with `mojo doc` (every body
elaborated, no code generated), two at a time beside the build. `mojo doc`
does not warn: a warning in code no test reaches no longer reaches the
warning ratchet's log. That is the one thing the per-file loop saw and
this does not.

WHAT IT KEEPS, each checked here:
- every test runs, counted: a file's `Running N tests` must equal the tests
  it defines, and the total is printed beside the files' count;
- a failing test, a trap (a death by signal), a file that does not compile
  (in the one program, or on its own) and a file that prints no report each
  fail the run; every file still runs, and the failures are listed at the
  end;
- the output a developer reads: each file's report as the suite prints it,
  with the runner's and the symlinks' paths written back as the test
  file's own (same file, same line numbers), so a failure names
  `packages/.../test_x.mojo:LINE` and the test.

`--selftest` exercises the verdicts, the scan and the generator on canned
input, as `emit.py --selftest` does for the recorder: a parser that stopped
matching would otherwise pass a run it had not read. `--sabotage` (`poe
sabotage-mojo-suite`) breaks a tiny package one way per arm and requires
each to fail the run in this runner's own words.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENV_NAME = "SUITE_FILE"
RUNNER = "_suite.mojo"
BINARY = "suite"

# What `TestSuite.discover_tests[__functions_in_module()]()` registers: a
# module-level function whose name starts with `test_`. spec_sheet.py reads
# the same shape for a SPEC row's `test_x.mojo:test_fn`.
TEST_DEF_RE = re.compile(r"^def (test_\w+)\(", re.M)
# Anything at column 0 that could be a test; each must match the above.
LOOKS_LIKE_TEST_RE = re.compile(r"^(?:def|fn)\s+test_.*$", re.M)
MAIN_RE = re.compile(r"^def main\(\)[^\n]*:\n((?:[ \t]+\S[^\n]*\n|[ \t]*\n)*)", re.M)
DISCOVERY = "TestSuite.discover_tests[__functions_in_module()]().run()"

RUNNING_RE = re.compile(r"^Running (\d+) tests? for (.*?)\s*$", re.M)
SUMMARY_RE = re.compile(
    r"^Summary \[[^\]]*\] (\d+) tests? run: (\d+) passed , (\d+) failed , (\d+) skipped",
    re.M,
)
FAIL_RE = re.compile(r"^\s+FAIL \[[^\]]*\] (\S+)", re.M)


def scan(text: str) -> tuple[list[str], list[str]]:
    """(test names to register, problems) for one test file's source."""
    names = TEST_DEF_RE.findall(text)
    problems = []
    for line in LOOKS_LIKE_TEST_RE.findall(text):
        if not TEST_DEF_RE.match(line + "\n"):
            problems.append(f"cannot register `{line.strip()}`")
    mains = MAIN_RE.findall(text)
    if len(mains) != 1:
        problems.append(f"{len(mains)} `def main()` at column 0, not one")
    else:
        body = [ln.strip() for ln in mains[0].splitlines() if ln.strip()]
        if body != [DISCOVERY]:
            problems.append("main() is not the discovery one-liner, and this runner would skip "
                            "whatever else it does: " + " / ".join(body))
    return names, problems


def verdict(returncode: int, output: str, expected: int) -> tuple[bool, str]:
    """(ok, reason) for one file's run of the suite binary."""
    if returncode < 0:
        return False, f"killed by signal {-returncode}"
    running = RUNNING_RE.findall(output)
    summary = SUMMARY_RE.findall(output)
    failed_names = FAIL_RE.findall(output)
    if returncode != 0:
        if failed_names:
            return False, f"exit {returncode}; failed: {', '.join(failed_names)}"
        return False, f"exit {returncode}"
    if len(running) != 1 or len(summary) != 1:
        return False, f"no single report (Running lines {len(running)}, Summary lines {len(summary)})"
    ran = int(running[0][0])
    total, passed, failed, skipped = (int(x) for x in summary[0])
    if failed or failed_names:
        return False, f"{failed} failed but exit 0"
    if ran != expected or total != expected:
        return False, f"ran {total} of {ran} registered; the file defines {expected}"
    if passed + skipped != total:
        return False, f"{passed} passed + {skipped} skipped != {total}"
    return True, ""


def generate(tests: dict[str, list[str]]) -> str:
    """The runner: every module imported, each one's tests registered by name."""
    lines = [
        "# Generated by scripts/mojo_suite.py on every run; never edited.",
        "# Each import is a symlink beside this file to one of the package's",
        "# test files; SUITE_FILE names the one this process runs.",
        "from std.os import getenv",
        "from std.testing import TestSuite",
        "",
    ]
    lines += [f"import {m}" for m in tests]
    for m, names in tests.items():
        lines += ["", "", f"def _run_{m}() raises:", "    var suite = TestSuite()"]
        lines += [f"    suite.test[{m}.{t}]()" for t in names]
        lines += ["    suite^.run()"]
    lines += ["", "", "def main() raises:", f'    var name = getenv("{ENV_NAME}")']
    for i, m in enumerate(tests):
        kw = "if" if i == 0 else "elif"
        lines += [f'    {kw} name == "{m}":', f"        _run_{m}()"]
    lines += [
        "    else:",
        f'        raise Error("mojo_suite: {ENV_NAME}=" + name + " names no test file")',
        "",
    ]
    return "\n".join(lines)


def prepare(pkg: Path, files: list[Path], farm: Path, runner_text: str) -> None:
    """(Re)build the runner's directory: links, and the generated runner."""
    farm.mkdir(parents=True, exist_ok=True)
    keep = {RUNNER, "src", BINARY} | {f.name for f in files}
    for entry in farm.iterdir():
        if entry.name not in keep:
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
    links = {"src": pkg / "src"} | {f.name: f for f in files}
    for name, target in links.items():
        link = farm / name
        rel = os.path.relpath(target, farm)
        if link.is_symlink() and os.readlink(link) == rel:
            continue
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(rel)
    runner = farm / RUNNER
    if not runner.exists() or runner.read_text() != runner_text:
        runner.write_text(runner_text)


class Rewriter:
    """Write the farm's paths back as the test files' own.

    A symlink's path becomes the file it links to (same file, same line
    numbers). The runner's own path, which the suite's `Running N tests for`
    line names because the suite is made there, becomes the file that
    process is running, and the `src` link's paths the package's own, so a
    warning in `src` reads as the build-all log spells it. Only `.mojo`
    paths: the binary stays where it is."""

    def __init__(self, farm: Path, pkg: Path):
        dirs = "|".join(re.escape(d) for d in sorted({str(farm), str(farm.resolve())}))
        self.path = re.compile(rf"(?:{dirs})/((?:src/[\w/]+|\w+)\.mojo)\b")
        self.pkg = str(pkg)
        self.current = None

    def __call__(self, text: str) -> str:
        def to_own(m):
            name = m.group(1)
            if name.startswith("src/"):
                return f"{self.pkg}/{name}"
            if name == RUNNER and self.current:
                name = self.current
            return f"{self.pkg}/test/{name}"
        return self.path.sub(to_own, text)


def stream(cmd: list[str], env: dict | None, rewrite: Rewriter) -> tuple[int, str]:
    """Run cmd, echoing its merged output (rewritten) as it comes; return both."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=env, text=True, errors="replace", bufsize=1)
    out = []
    assert proc.stdout is not None
    for line in proc.stdout:
        line = rewrite(line)
        out.append(line)
        sys.stdout.write(line)
        sys.stdout.flush()
    return proc.wait(), "".join(out)


def say(*args, **kw):
    print(*args, **kw, flush=True)


def check_entry(mojo: str, includes: list[str], path: Path) -> tuple[int, str, float]:
    """`mojo doc` on one test file as an entry file: (status, output, seconds).

    The one program elaborates only what its tests reach, so an error in code
    no test calls -- a helper, an import nothing uses, the file's own `main()`
    -- would build, where `mojo run` of that file alone fails. `mojo doc`
    elaborates the whole file, bodies included, and generates no code: about
    a second a file."""
    cmd = [mojo, "doc"]
    for inc in includes:
        cmd += ["-I", inc]
    cmd += [str(path), "-o", os.devnull]
    t = time.monotonic()
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors="replace")
    return p.returncode, p.stdout, time.monotonic() - t


def run(pkg: Path, includes: list[str], mojo: str, farm: Path | None = None) -> int:
    from concurrent.futures import ThreadPoolExecutor

    pkg = pkg if pkg.is_absolute() else (Path.cwd() / pkg)
    rel = os.path.relpath(pkg, Path.cwd())
    files = sorted((pkg / "test").glob("test_*.mojo"))
    if not files:
        say(f"mojo_suite: FAIL: no test files under {rel}/test")
        return 1
    tests, bad = {}, []
    for f in files:
        names, problems = scan(f.read_text())
        tests[f.stem] = names
        bad += [f"{f.name}: {p}" for p in problems]
    if bad:
        say("mojo_suite: FAIL: " + "\n  ".join(["what this runner cannot run as written:"] + bad))
        return 1
    farm = farm or (REPO / "bin" / "suite" / pkg.name)
    prepare(pkg, files, farm, generate(tests))
    rewrite = Rewriter(farm, pkg)
    binary = farm / BINARY
    if binary.exists():
        binary.unlink()

    # The per-file entry checks run beside the build, which keeps about one
    # and a half cores busy: two workers on CI's four vCPUs, one on three.
    workers = max(1, min(2, (os.cpu_count() or 2) - 2))
    say(f"mojo_suite: building the {len(files)} test files of {rel} as one program, "
        f"and checking each as a file of its own ({workers} at a time beside the build)")
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pending = {f.name: pool.submit(check_entry, mojo, includes, farm / f.name) for f in files}
        cmd = [mojo, "build"]
        for inc in includes:
            cmd += ["-I", inc]
        cmd += [str(farm / RUNNER), "-o", str(binary)]
        rc, _ = stream(cmd, None, rewrite)
        built = time.monotonic() - t0
        if rc != 0:
            # The compiler has named the file; the checks not yet started
            # would only delay saying so.
            pool.shutdown(wait=True, cancel_futures=True)
        entry = {name: fut.result() for name, fut in pending.items() if not fut.cancelled()}
    checked = time.monotonic() - t0
    unchecked = [name for name, (erc, _, _) in entry.items() if erc != 0]
    for name in unchecked:
        erc, out, _ = entry[name]
        say(f"\n=== {rel}/test/{name} does not compile as a file of its own "
            f"(`mojo doc` exited {erc}):")
        sys.stdout.write(rewrite(out))
    if rc != 0 or not binary.exists():
        say(f"mojo_suite: FAIL: the build of {rel}'s tests exited {rc} after {built:.0f} s; "
            "the compiler's errors above name the file")
        return 1
    say(f"mojo_suite: built in {built:.0f} s; every file checked on its own by {checked:.0f} s "
        f"({sum(e[2] for e in entry.values()):.0f} s of checks)")

    results = []
    t1 = time.monotonic()
    for f in files:
        say(f"\n=== {os.path.relpath(f, Path.cwd())}")
        env = dict(os.environ)
        env[ENV_NAME] = f.stem
        rewrite.current = f.name
        rc, out = stream([str(binary)], env, rewrite)
        expected = len(tests[f.stem])
        ok, why = verdict(rc, out, expected)
        if f.name in unchecked:
            ok, why = False, "does not compile as a file of its own" + (f"; {why}" if why else "")
        m = RUNNING_RE.findall(out)
        ran = int(m[0][0]) if len(m) == 1 else 0
        results.append((f.name, ok, why, ran, expected))
        if not ok:
            say(f"=== FAIL {f.name}: {why}")
    rewrite.current = None
    ran_for = time.monotonic() - t1

    total_ran = sum(r[3] for r in results)
    total_expected = sum(r[4] for r in results)
    failed = [r for r in results if not r[1]]
    say(f"\nmojo_suite: {rel}, tests run / defined, per file:")
    for name, ok, why, ran, exp in results:
        say(f"  {'ok  ' if ok else 'FAIL'} {ran:4d} / {exp:<4d} {name}" + (f"  -- {why}" if why else ""))
    say(f"mojo_suite: {rel}: {total_ran} tests run of {total_expected} defined, in {len(files)} "
        f"files, {len(failed)} failed; built in {built:.0f} s, ran in {ran_for:.0f} s")
    if failed or total_ran != total_expected:
        say(f"mojo_suite: FAIL: {', '.join(r[0] for r in failed) or 'the test count'}")
        return 1
    return 0


def selftest() -> int:
    ok_out = (
        "Running 2 tests for /x/test_a.mojo \n    PASS [ 0.001 ] test_one\n"
        "    PASS [ 0.001 ] test_two\n--------\n"
        "Summary [ 0.001 ] 2 tests run: 2 passed , 0 failed , 0 skipped \n"
    )
    fail_out = (
        "Unhandled exception caught during execution: \nRunning 2 tests for /x/test_a.mojo \n"
        "    FAIL [ 0.012 ] test_one\n      At /x/test_a.mojo:5:17: AssertionError\n"
        "    PASS [ 0.001 ] test_two\n--------\n"
        "Summary [ 0.012 ] 2 tests run: 1 passed , 1 failed , 0 skipped \n"
    )
    cases = [
        ("a clean file passes", verdict(0, ok_out, 2)[0], True),
        ("a failing test fails", verdict(1, fail_out, 2)[0], False),
        ("a failing test is named", "test_one" in verdict(1, fail_out, 2)[1], True),
        ("a trap fails", verdict(-5, ok_out[:40], 2)[0], False),
        ("a SIGKILL fails", verdict(-9, "", 2)[0], False),
        ("a nonzero exit with a clean report fails", verdict(3, ok_out, 2)[0], False),
        ("no report fails", verdict(0, "hello\n", 2)[0], False),
        ("a defined test the suite did not run fails", verdict(0, ok_out, 3)[0], False),
        ("more run than defined fails", verdict(0, ok_out, 1)[0], False),
        ("two reports in one process fail", verdict(0, ok_out + ok_out, 2)[0], False),
        ("a failure reported with exit 0 fails",
         verdict(0, fail_out.replace("Unhandled exception caught during execution: \n", ""), 2)[0], False),
    ]
    main = "\n\ndef main() raises:\n    " + DISCOVERY + "\n"
    src = ("def test_a() raises:\n    pass\n\ndef helper():\n    pass\n\n"
           "    def test_nested():\n        pass\n\ndef test_b():\n    pass\n" + main)
    names, problems = scan(src)
    cases.append(("column-0 test defs are registered, nested ones are not",
                  names == ["test_a", "test_b"] and not problems, True))
    cases.append(("a parametric test def is refused, not dropped",
                  bool(scan("def test_p[T: AnyType]() raises:\n    pass\n" + main)[1]), True))
    cases.append(("an fn test is refused, not dropped",
                  bool(scan("fn test_f() raises:\n    pass\n" + main)[1]), True))
    cases.append(("a main() that does more than discover is refused",
                  bool(scan("def test_a() raises:\n    pass\n\ndef main() raises:\n    setup()\n    "
                            + DISCOVERY + "\n")[1]), True))
    cases.append(("a file with no main() is refused",
                  bool(scan("def test_a() raises:\n    pass\n")[1]), True))
    gen = generate({"test_a": ["test_one", "test_two"], "test_b": ["test_three"]})
    cases.append(("the runner imports, registers and dispatches every file",
                  all(s in gen for s in ("import test_a", "import test_b",
                                         "suite.test[test_a.test_one]()", "suite.test[test_a.test_two]()",
                                         "suite.test[test_b.test_three]()",
                                         'if name == "test_a":', "        _run_test_a()",
                                         'elif name == "test_b":', "        _run_test_b()")), True))
    cases.append(("the runner never calls a file's main()", "main()" not in gen.replace("def main()", ""), True))
    rw = Rewriter(Path("/r/bin/suite/m0-x"), Path("/r/packages/m0-x"))
    rw.current = "test_a.mojo"
    cases.append(("a symlink's path is written back as the file's own",
                  rw("At /r/bin/suite/m0-x/test_b.mojo:5:17") == "At /r/packages/m0-x/test/test_b.mojo:5:17", True))
    cases.append(("the runner's path is written back as the running file's",
                  rw("Running 2 tests for /r/bin/suite/m0-x/_suite.mojo ")
                  == "Running 2 tests for /r/packages/m0-x/test/test_a.mojo ", True))
    cases.append(("a path through the src link is written back as the package's own",
                  rw("/r/bin/suite/m0-x/src/loop/state.mojo:3:1: warning: w")
                  == "/r/packages/m0-x/src/loop/state.mojo:3:1: warning: w", True))
    cases.append(("the binary's own path is left alone",
                  rw("#4 test_a::test_one() (/r/bin/suite/m0-x/suite+0x10)")
                  == "#4 test_a::test_one() (/r/bin/suite/m0-x/suite+0x10)", True))
    bad = [name for name, got, want in cases if got is not want]
    for name, got, want in cases:
        print(f"  {'ok ' if got is want else 'BAD'} {name}")
    if bad:
        print(f"mojo_suite --selftest: FAIL: {len(bad)} case(s)")
        return 1
    print(f"mojo_suite --selftest: {len(cases)} cases ok")
    return 0


# --sabotage: a tiny package, built in a temporary directory with this
# script run on it as `poe test-http` runs it on m0-http, broken one way per
# arm -- a test file added to it, or a rule taken out of a copy of this
# script. Each arm must fail the run IN THE RUNNER'S OWN WORDS; the control
# must pass, or no arm proves anything. A decoy package whose `src` holds a
# `which_package` of its own is FIRST on the -I list throughout, so the
# control proves the package's own `src` wins and the link arm proves the
# `src` link is what makes it win.
_TINY_OK = '''from std.testing import TestSuite, assert_equal


def test_one() raises:
    assert_equal(1 + 1, 2)


def test_two() raises:
    assert_equal("a" + "b", "ab")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''
_TINY_RESOLUTION = '''from std.testing import TestSuite, assert_equal

from src.which_package import PACKAGE_NAME


def test_our_own_src_wins() raises:
    assert_equal(PACKAGE_NAME, "under-test")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''
_ARM_HEAD = "from std.ffi import c_int, external_call\nfrom std.testing import TestSuite, assert_equal\n\n\n"
_ARM_MAIN = "\n\ndef main() raises:\n    " + DISCOVERY + "\n"
_PASSING = "def test_passes() raises:\n    assert_equal(1, 1)\n"
# (label, test_arm.mojo or None, (anchor, replacement) in this script or
#  None, what the runner must say)
_ARMS = [
    ("a failing test",
     _ARM_HEAD + _PASSING + "\n\ndef test_fails() raises:\n    assert_equal(1, 2)\n" + _ARM_MAIN,
     None, "=== FAIL test_arm.mojo: exit 1; failed: test_fails"),
    ("a test that dies by a signal (SIGKILL: no crash report)",
     _ARM_HEAD + _PASSING + "\n\ndef test_dies() raises:\n"
     '    _ = external_call["kill", c_int](external_call["getpid", c_int](), c_int(9))\n' + _ARM_MAIN,
     None, "=== FAIL test_arm.mojo: killed by signal 9"),
    ("a type error in a test body",
     _ARM_HEAD + "def test_mistyped() raises:\n    var n: Int = \"one\"\n    assert_equal(n, 1)\n" + _ARM_MAIN,
     None, "mojo_suite: FAIL: the build of"),
    ("a syntax error in a helper nothing calls",
     _ARM_HEAD + _PASSING + "\n\ndef helper(:\n    pass\n" + _ARM_MAIN,
     None, "=== FAIL test_arm.mojo: does not compile as a file of its own"),
    ("a type error in a helper nothing calls",
     _ARM_HEAD + _PASSING + "\n\ndef helper() -> Int:\n    return \"one\"\n" + _ARM_MAIN,
     None, "=== FAIL test_arm.mojo: does not compile as a file of its own"),
    ("an import nothing uses that does not resolve",
     "from no_such_module import nothing\n" + _ARM_HEAD + _PASSING + _ARM_MAIN,
     None, "=== FAIL test_arm.mojo: does not compile as a file of its own"),
    ("a test def the runner cannot register",
     _ARM_HEAD + _PASSING + "\n\ndef test_parametric[n: Int]() raises:\n    assert_equal(n, n)\n" + _ARM_MAIN,
     None, "cannot register `def test_parametric"),
    ("a main() that does more than discover",
     _ARM_HEAD + _PASSING + "\n\ndef main() raises:\n    print(\"setup\")\n    " + DISCOVERY + "\n",
     None, "main() is not the discovery one-liner"),
    ("the runner without its src link",
     None, ('links = {"src": pkg / "src"} | {f.name: f for f in files}',
            'links = {f.name: f for f in files}'),
     "=== FAIL test_resolution.mojo: exit 1; failed: test_our_own_src_wins"),
    ("the runner dropping a file's last test",
     None, ('lines += [f"    suite.test[{m}.{t}]()" for t in names]',
            'lines += [f"    suite.test[{m}.{t}]()" for t in names[:-1]]'),
     "=== FAIL test_ok.mojo: ran 1 of 1 registered; the file defines 2"),
]


def _tiny_package(root: Path, arm: str | None) -> tuple[Path, Path]:
    for name, which in (("pkg", "under-test"), ("decoy", "decoy")):
        (root / name / "src").mkdir(parents=True)
        (root / name / "src" / "__init__.mojo").write_text("")
        (root / name / "src" / "which_package.mojo").write_text(f'comptime PACKAGE_NAME = "{which}"\n')
    test = root / "pkg" / "test"
    test.mkdir()
    (test / "__init__.mojo").write_text("# the tiny package's tests\n")
    (test / "test_ok.mojo").write_text(_TINY_OK)
    (test / "test_resolution.mojo").write_text(_TINY_RESOLUTION)
    if arm is not None:
        (test / "test_arm.mojo").write_text(arm)
    return root / "pkg", root / "decoy"


def sabotage(mojo: str) -> int:
    import tempfile

    # A rule's anchor is looked for, and replaced, above this section only:
    # the table below spells every anchor too.
    head, marker, tail = Path(__file__).read_text().partition("\n# --sabotage: ")
    rows = []
    for label, arm, patch, words in [("control", None, None, None)] + _ARMS:
        with tempfile.TemporaryDirectory(prefix="mojo-suite-sabotage-") as tmp:
            root = Path(tmp)
            script = root / "mojo_suite.py"
            text = head + marker + tail
            if patch is not None:
                n = head.count(patch[0])
                if n != 1:
                    rows.append((label, "NOT APPLICABLE", f"the anchor matches {n} times"))
                    continue
                text = head.replace(patch[0], patch[1]) + marker + tail
            script.write_text(text)
            pkg, decoy = _tiny_package(root, arm)
            p = subprocess.run([sys.executable, str(script), str(pkg), "-I", str(decoy), "-I", str(pkg),
                                "--farm", str(root / "farm"), "--mojo", mojo],
                               capture_output=True, text=True, errors="replace", timeout=600)
            out = p.stdout + p.stderr
            if words is None:
                ok = p.returncode == 0 and "tests run of 3 defined, in 2 files, 0 failed" in out
                rows.append((label, "passes" if ok else "FAILED", "" if ok else out[-1500:]))
            elif p.returncode != 0 and words in out:
                rows.append((label, "caught", words))
            elif p.returncode != 0:
                rows.append((label, "MISSED (failed elsewhere)", out[-1500:]))
            else:
                rows.append((label, "MISSED", out[-1500:]))
    for label, v, why in rows:
        print(f"  {v:26} {label}" + (f"\n{why}" if v not in ("caught", "passes") else ""))
    good = all(v in ("caught", "passes") for _, v, _ in rows)
    caught = sum(v == "caught" for _, v, _ in rows)
    print(f"mojo_suite --sabotage: {caught} of {len(_ARMS)} caught, the control "
          f"{rows[0][1]}" + ("" if good else "; FAIL"))
    return 0 if good else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("package", nargs="?", help="the package directory, e.g. packages/m0-http")
    ap.add_argument("-I", dest="includes", action="append", default=[],
                    help="an import root, in order, as `mojo run -I` takes it")
    ap.add_argument("--mojo", default="mojo")
    ap.add_argument("--farm", type=Path, help="where to build (default bin/suite/<package>)")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--sabotage", action="store_true",
                    help="break a tiny package one way per arm; every arm must fail the run")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.sabotage:
        # Each arm builds a program nobody builds again: compile it into a
        # cache of the run's own, not the shared one, which never evicts.
        from sabotage_lib import throwaway_mojo_cache
        with throwaway_mojo_cache():
            return sabotage(a.mojo)
    if not a.package:
        ap.error("a package directory is required")
    return run(Path(a.package), a.includes, a.mojo, a.farm)


if __name__ == "__main__":
    sys.exit(main())
