#!/usr/bin/env python3
"""The machinery the sabotage harnesses share (review H1; fixes B15).

A sabotage harness breaks one rule of the tree at a time -- an EXACT source
anchor replaced by a broken version -- runs the gate that claims to guard the
rule, insists the gate FAILS, and puts the rule back. A guard nobody has
broken on purpose is a guard nobody knows works. Each harness keeps its own
rule table; this module is everything around it:

  - `Rule`, and `rule()` to turn a table row into one -- an anchor of None
    PLANTS a file that must not exist, and the restore removes it;
  - anchors that must match EXACTLY ONCE, overlapping matches counted: zero
    or two is an error naming the file and the anchor;
  - two gates: `MojoRun`, a `mojo run` judged by the driver's own words,
    and `Command`, a smoke or a probe judged by its exit status and pass
    text;
  - a backup of every file a run edits, keyed by its RELATIVE path, and a
    restore after every rule and again on the way out, in `finally`, with
    SIGINT, SIGTERM and SIGHUP turned into an exception so that path runs,
    and signals held off while a file is being written back. Once the tree
    is back, the harness dies BY that signal: it never carries on, and its
    parent sees a signal, not an exit status to step past;
  - gates run in a process group of their own, so a timeout or an
    interruption ends a smoke's server and a build's compiler, not only the
    command that started them;
  - a TMPDIR of the run's own for everything its gates start, removed on
    the way out (`own_tmpdir`), so the logs a failed smoke keeps do not
    pile up in `$TMPDIR`;
  - `--only` / `--skip`;
  - verdicts that cannot be mistaken for one another, and a tally in which
    nothing that did not run is summarised as guarded.

Verdicts
--------
    caught                     the gate ran on the sabotaged tree and failed
    MISSED                     the gate passed with the rule broken
    MISSED (does not compile)  the sabotaged tree did not build, so the gate
                               never ran and proved nothing (B15)
    MISSED (failed elsewhere)  the gate failed, but not in its own words: not
                               on the text the rule names, or with no sign
                               that it ran at all; the last lines it printed
                               follow
    NOT APPLICABLE             an anchor matches zero times or more than
                               once, or the edit changes nothing: the table
                               is stale, so re-point the anchor with the line
    SKIPPED                    not run here: this platform cannot observe it

Every verdict but `caught` and `SKIPPED` fails the run (exit 1). SKIPPED does
not fail it, and is never counted as guarded: the last line says how many
rules this run did NOT prove, and why. Grep a run for `MISSED` and
`NOT APPLICABLE`, and read its exit status; never count `caught` lines.

Telling a catch from a build failure (B15)
------------------------------------------
The older harnesses read "the gate exited non-zero" as caught, so a sabotage
that merely broke the build passed as proof that the gate guards the rule. A
catch here needs evidence that the gate RAN, taken from the gate's own words:

  - A gate with a build step of its own (`poe build-*`, `mojo build --emit
    llvm`) knows the phase directly: a failed build is `does not compile`,
    and only a failure after it can be a catch.

  - `mojo run` compiles and executes in one process, and the driver's own
    last line names the phase that failed. Measured on Mojo 1.1.0:

      compile  `<file>.mojo:<line>:<col>: error: ...`, then
               `mojo: error: failed to parse the provided Mojo source module`
               (syntax, names, types) or `mojo: error: failed to run the pass
               manager` (a failed instantiation or constraint). Nothing ran.
      run      `mojo: error: execution exited with a non-zero result: N` --
               a std.testing suite prints `FAIL [ t ] test_name` for each
               failure, and a harness its own failure text -- or
               `mojo: error: execution crashed` after an ABORT or a signal,
               when the program's own output is LOST: its stdout is
               block-buffered into the pipe.

    `MojoRun` calls a run `does not compile` only on a diagnostic with no
    sign of execution, and `caught` only with an execution line or a
    `FAIL [` line. A test that raises `Error("error: ...")` prints `error:`
    with no `file:line:col` in front, so it cannot pass for a diagnostic.

  - Two failures print nothing that places them. A timeout prints nothing
    at all (the same buffering). And a crash can take the driver's own crash
    handler with it: in ten runs on macOS, pool's "handler built once and
    shared" (a data race) killed `mojo` by SIGSEGV twice and by SIGBUS once,
    with no execution line and the suite's output lost, and failed its named
    test cleanly the other seven times. For a timeout, or a driver killed by
    a FAULT signal (SEGV, BUS, ILL, FPE, ABRT, TRAP, SYS -- never SIGKILL,
    which comes from outside, the OOM killer among others), `MojoRun` builds
    the sabotaged source on its own (`mojo build --emit llvm`, no linker): if
    that succeeds, the failure came at run time and the gate caught it; if
    it stops on a diagnostic, `does not compile`; if it cannot tell, a miss.

Any shape this module does not recognise is a miss, never a catch, so a
toolchain that changes its wording fails loud rather than green.

A rule may also name the text its catch must carry (`expect`): the fuzzer's
invariant, a smoke's assertion, the test that claims the rule. A gate that
fails without it failed elsewhere, which is a miss -- the harness has not
shown that the check claiming the rule is the one that holds it. A suite
names every test it runs, so the line of a test that did not fail (`PASS [`,
`SKIP [`) never carries the text: a run that fails in another test, with
the named one passing, failed elsewhere.

Writing a harness
-----------------
    from sabotage_lib import MojoRun, rule, run

    SABOTAGES = [(label, old, new), ...]      # the table stays the harness's
    RULES = [rule(label, PATH, old, new) for label, old, new in SABOTAGES]

    def main(argv):
        return run("sabotage-x", RULES, MojoRun(TEST), argv)

A harness with a loop of its own, not `run`, enters `own_tmpdir` itself.
Run from the repository root, as every poe task is.

    python3 scripts/sabotage_lib.py --selftest
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence

# The venv's own tools, never `uv run`: a child `uv run` re-syncs the venv to
# uv.lock even under a parent `uv run --no-sync` (measured 2026-09-02: the
# child printed Mojo 1.0.0 and the venv stayed there), which on a nightly
# (`poe canary`, nightly-canary.yml) swaps the toolchain back to stable
# mid-run and reports the next step's ".mojoc is newer than the compiler" as
# a nightly break. poe's virtualenv executor puts .venv/bin first on PATH, so
# the siblings of this interpreter are the tools every other task uses.


def _sibling(name: str) -> str:
    near = Path(sys.executable).with_name(name)
    return str(near) if near.exists() else (shutil.which(name) or name)


MOJO = _sibling("mojo")
POE = _sibling("poe")

SYSTEM = platform.system()

CAUGHT = "caught"
MISSED = "MISSED"
UNBUILT = "MISSED (does not compile)"
ELSEWHERE = "MISSED (failed elsewhere)"
NOT_APPLICABLE = "NOT APPLICABLE"
SKIPPED = "SKIPPED"
_VERDICTS = (CAUGHT, MISSED, UNBUILT, ELSEWHERE, NOT_APPLICABLE, SKIPPED)
_WIDTH = max(len(v) for v in _VERDICTS) + 2


# --- the rule record --------------------------------------------------------


@dataclass(frozen=True)
class Edit:
    """One replacement: `old` must occur exactly once in `path`. An `old` of
    None PLANTS the file instead: it must not exist, `new` is its whole
    text, and putting the tree back removes it."""

    path: Path
    old: str | None
    new: str


@dataclass(frozen=True, eq=False)
class Rule:
    """One load-bearing rule, and how to break it.

    `edits` apply in order, each to the text the one before it left, so a
    rule that takes two changes -- in one file or two -- names both. `gate`
    names one of the harness's gates when it has several. `only_on` is the
    `platform.system()` that can observe the breakage; elsewhere the rule is
    SKIPPED. `expect` is text the gate's output must carry for its failure
    to count as the catch, on a line other than a passing or skipped test's.
    Compared by identity, so two rows that happen to
    be alike are still two rules.
    """

    label: str
    edits: tuple[Edit, ...]
    gate: str = ""
    only_on: str = ""
    expect: str = ""


def rule(label: str, path, old, new, *, gate: str = "", only_on: str = "",
         expect: str = "") -> Rule:
    """A rule of one edit -- or of several, when `old` and `new` are tuples of
    the same length (and `path` is one too, if the edits span files)."""
    olds = old if isinstance(old, tuple) else (old,)
    news = new if isinstance(new, tuple) else (new,)
    paths = path if isinstance(path, tuple) else (path,) * len(olds)
    if not len(olds) == len(news) == len(paths):
        raise ValueError(f"{label}: {len(paths)} paths, {len(olds)} anchors "
                         f"and {len(news)} replacements")
    edits = tuple(Edit(Path(p), o, n) for p, o, n in zip(paths, olds, news))
    return Rule(label, edits, gate, only_on, expect)


# --- anchors ----------------------------------------------------------------


class AnchorError(Exception):
    """An anchor that does not name exactly one place, or an edit that
    changes nothing."""


def occurrences(text: str, anchor: str) -> int:
    """How many places `anchor` starts at in `text`, OVERLAPPING ones
    included. `str.count` skips an overlap: it counts "ab ab" once in
    "ab ab ab", where it starts at two places and so names neither."""
    n, at = 0, text.find(anchor)
    while at >= 0:
        n += 1
        at = text.find(anchor, at + 1)
    return n


def _shown(anchor: str) -> str:
    first = anchor.strip("\n").splitlines()[0] if anchor.strip() else anchor
    more = anchor.strip("\n").count("\n")
    return repr(first.strip()[:90]) + (f" (+{more} more line(s))" if more else "")


def apply(r: Rule, texts: Mapping[Path, str | None]) -> dict[Path, str]:
    """The texts of `r`'s files with the rule broken, or AnchorError. A file
    that does not exist is missing from `texts`, or None in it."""
    out: dict[Path, str | None] = {}
    for e in r.edits:
        if e.path not in out:
            have = texts.get(e.path)
            if have is None and e.old is not None:
                raise AnchorError(f"{e.path}: no such file")
            out[e.path] = have
    for e in r.edits:
        if e.old is None:
            if out[e.path] is not None:
                raise AnchorError(f"{e.path}: the rule plants this file, and it exists")
            out[e.path] = e.new
            continue
        if not e.old:
            raise AnchorError(f"{e.path}: the anchor is empty")
        n = occurrences(out[e.path], e.old)
        if n != 1:
            raise AnchorError(
                f"{e.path}: the anchor matches {n} time{'' if n == 1 else 's'}, "
                f"not exactly once: {_shown(e.old)}")
        out[e.path] = out[e.path].replace(e.old, e.new, 1)
    if all(out[p] == texts.get(p) for p in out):
        raise AnchorError(f"{r.edits[0].path}: the edit changes nothing")
    return out


# --- files ------------------------------------------------------------------


def read(path: Path) -> str:
    """A file's text exactly: UTF-8, with no newline translation."""
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path: Path, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def _read_or_none(path: Path) -> str | None:
    try:
        return read(path)
    except OSError:
        return None


def _relative(path: Path) -> Path:
    """Where a file's backup goes: its path relative to the repository root,
    so `apps/a/server.mojo` and `apps/b/server.mojo` cannot collide."""
    full = Path(os.path.abspath(path)).resolve()
    try:
        return full.relative_to(Path.cwd().resolve())
    except ValueError:
        return Path(*full.parts[1:])


# --- signals ----------------------------------------------------------------


class Interrupted(BaseException):
    """A signal asked the harness to stop. A BaseException, as
    KeyboardInterrupt is, so no `except Exception` on the way swallows it."""

    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


_SIGNALS = tuple(getattr(signal, n) for n in ("SIGINT", "SIGTERM", "SIGHUP")
                 if hasattr(signal, n))


def _raise_interrupted(signum, _frame):
    raise Interrupted(signum)


@contextmanager
def _stop_on_signals():
    """SIGINT, SIGTERM and SIGHUP raise `Interrupted` while the block runs.

    SIGTERM's and SIGHUP's default is to end the process where it stands,
    which skips every `finally` -- and a `finally` is what puts the tree
    back. A signal this process was started ignoring (`nohup`, a background
    job's SIGINT) stays ignored."""
    previous = {}
    for s in _SIGNALS:
        if signal.getsignal(s) is not signal.SIG_IGN:
            previous[s] = signal.signal(s, _raise_interrupted)
    try:
        yield
    finally:
        for s, handler in previous.items():
            signal.signal(s, handler)


@contextmanager
def _signals_held():
    """Hold those signals off while a file is written back or a gate's
    process group is ended: a handler that raised between the truncation and
    the write would leave the file empty. What arrives meanwhile is delivered
    as the block ends."""
    if not hasattr(signal, "pthread_sigmask"):
        yield
        return
    old = signal.pthread_sigmask(signal.SIG_BLOCK, _SIGNALS)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old)


# --- running a gate ---------------------------------------------------------


@dataclass(frozen=True)
class Ran:
    """What a command did: its exit status, None when it timed out, and its
    stdout and stderr merged in the order they were written."""

    returncode: int | None
    output: str

    @property
    def timed_out(self) -> bool:
        return self.returncode is None


def _text(raw) -> str:
    if not raw:
        return ""
    return raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw


def end_group(proc: subprocess.Popen, grace: float = 3.0) -> None:
    """SIGTERM to the command's whole process group, a grace period for its
    traps to tidy up, then SIGKILL for whatever is left of the group."""
    with _signals_held():
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            if sig == signal.SIGTERM:
                try:
                    proc.wait(timeout=grace)
                except subprocess.TimeoutExpired:
                    pass
        proc.wait()


def run_command(cmd: Sequence, *, timeout: float, env: Mapping | None = None,
                cwd=None) -> Ran:
    """Run `cmd` in a process group of its own, stdout and stderr merged.

    A timeout, or an interruption of this harness, ends the WHOLE group --
    the server a smoke started and the compiler a build task started, not
    only the command -- so nothing is left holding a port or writing an
    artifact from a sabotaged tree after the file has been put back."""
    proc = subprocess.Popen(
        [str(c) for c in cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, env=None if env is None else dict(env),
        cwd=cwd, start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        end_group(proc)
        try:
            out, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired as exc:
            out = exc.output  # something outside the group holds the pipe
        return Ran(None, _text(out))
    except BaseException:
        end_group(proc)
        raise
    return Ran(proc.returncode, _text(out))


@dataclass(frozen=True)
class Outcome:
    """What one run of a gate showed.

      passed   the gate passed.
      failed   the gate RAN and failed; `detail` is its own failure text.
      unbuilt  the gate never ran, because the source did not build;
               `detail` is the build's first error.
      unclear  the gate failed with no sign that it ran; `detail` says what
               was seen instead.
    """

    kind: str
    detail: str = ""
    output: str = ""

    @classmethod
    def passed(cls, output: str = "") -> "Outcome":
        return cls("passed", "", output)

    @classmethod
    def failed(cls, detail: str, output: str = "") -> "Outcome":
        return cls("failed", detail, output)

    @classmethod
    def unbuilt(cls, detail: str, output: str = "") -> "Outcome":
        return cls("unbuilt", detail, output)

    @classmethod
    def unclear(cls, detail: str, output: str = "") -> "Outcome":
        return cls("unclear", detail, output)


class Gate:
    """What a harness runs to judge the tree: `run(texts)` gets the text of
    every file the rule touches -- sabotaged, or the originals for the
    baseline, where a file a rule plants is None. A gate that reads the tree
    from disk ignores it; one that compiles a copy (`run(..., write=False)`)
    reads it."""

    def run(self, texts: Mapping[Path, str]) -> Outcome:  # pragma: no cover
        raise NotImplementedError


# What `mojo run` prints, measured on Mojo 1.1.0 (the module docstring).
DIAGNOSTIC = re.compile(r"^.*\.mojo:\d+:\d+: error:.*$", re.M)
_EXECUTED = re.compile(r"execution exited with a non-zero result|execution crashed")
_TEST_FAILED = re.compile(r"^\s*FAIL \[[^\]]*\]\s*(\S+)", re.M)
# A suite's line for a test that did not fail: `PASS [ 0.001 ] test_one`, or
# `SKIP [ 0.001 ] test_one` (`TestSuite.skip`, measured the same way).
_TEST_DID_NOT_FAIL = re.compile(r"^\s*(?:PASS|SKIP) \[[^\]]*\]\s")
_ABORT = re.compile(r"^ABORT: .*$", re.M)
_RAISED = re.compile(r"Unhandled exception caught during execution: ?(.*)$", re.M)
_EXITED = re.compile(r"execution exited with a non-zero result: (-?\d+)")

# The signals a program raises against itself by faulting. A driver killed
# by one of these may have crashed at run time; one killed by anything else
# (SIGKILL from the OOM killer, a SIGTERM) was stopped from outside, and
# that is never a catch.
FAULT_SIGNALS = frozenset(
    getattr(signal, n) for n in ("SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGABRT",
                                 "SIGTRAP", "SIGSYS") if hasattr(signal, n))


def suite_passed(ran: Ran) -> bool:
    """A std.testing suite's pass: exit 0, and a summary with 0 failures."""
    return (ran.returncode == 0 and "tests run" in ran.output
            and re.search(r"(?<!\d)0 failed", ran.output) is not None)


def last_line(out: str) -> str:
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    return lines[-1][-160:] if lines else "(no output)"


def _mojo_failure(out: str) -> str:
    """The failure, in the program's own words, of a `mojo run` that ran."""
    names = _TEST_FAILED.findall(out)
    if names:
        return (f"{len(names)} test(s) fail: " + ", ".join(names[:3])
                + (", ..." if len(names) > 3 else ""))
    abort = _ABORT.search(out)
    if abort:
        return "crashed: " + abort.group(0)[-160:]
    if "execution crashed" in out:
        return "crashed"
    raised = _RAISED.search(out)
    if raised and raised.group(1).strip():
        return "raised: " + raised.group(1).strip()[:160]
    exited = _EXITED.search(out)
    return f"exited {exited.group(1)}" if exited else last_line(out)


def judge_mojo_run(ran: Ran, passed: Callable[[Ran], bool] = suite_passed) -> Outcome:
    """Which phase a finished (not timed-out) `mojo run` failed in."""
    out = ran.output
    if passed(ran):
        return Outcome.passed(out)
    executed = _EXECUTED.search(out) or _TEST_FAILED.search(out)
    diagnostic = DIAGNOSTIC.search(out)
    if diagnostic and not executed:
        return Outcome.unbuilt(diagnostic.group(0).strip(), out)
    if executed:
        return Outcome.failed(_mojo_failure(out), out)
    if ran.returncode == 0:
        return Outcome.unclear("exited 0 without the gate's pass text: "
                               + last_line(out), out)
    return Outcome.unclear(f"exit {ran.returncode} with no sign the program "
                           f"ran or failed to build: {last_line(out)}", out)


def unplaced(ran: Ran, outcome: Outcome | None, timeout: float) -> str:
    """Why a `mojo run`'s output cannot place its failure, or "" when it can:
    it timed out, or the driver died of a FAULT signal before saying which
    phase it was in. Anything else it said is judged as it stands."""
    if ran.timed_out:
        return f"hung: timed out after {timeout:g} s"
    if outcome is not None and outcome.kind == "unclear" \
            and -(ran.returncode or 0) in FAULT_SIGNALS:
        return f"crashed: the driver died of {signal.Signals(-ran.returncode).name}"
    return ""


class MojoRun(Gate):
    """`mojo run` of one file -- a std.testing suite, or a harness such as
    the fuzzer -- the way CI runs it, judged by the driver's own words."""

    def __init__(self, entry, *, includes=("packages/m0-http", "packages/m0-core"),
                 args: Sequence[str] = (), passed: Callable[[Ran], bool] = suite_passed,
                 timeout: float = 600, mojo: str | None = None):
        self.entry = str(entry)
        self.includes = tuple(str(i) for i in includes)
        self.args = tuple(args)
        self.passed = passed
        self.timeout = timeout
        self.mojo = mojo or MOJO

    def _flags(self) -> list[str]:
        return [x for inc in self.includes for x in ("-I", inc)]

    def run(self, texts: Mapping[Path, str] | None = None) -> Outcome:
        ran = run_command([self.mojo, "run", *self._flags(), self.entry, *self.args],
                          timeout=self.timeout)
        outcome = None if ran.timed_out else judge_mojo_run(ran, self.passed)
        why = unplaced(ran, outcome, self.timeout)
        return self._ask_the_compiler(why, ran) if why else outcome

    def _ask_the_compiler(self, what: str, ran: Ran) -> Outcome:
        """The output cannot place the failure, so build the sabotaged source
        alone: if it builds, the failure came at run time."""
        with tempfile.TemporaryDirectory(prefix="sabotage-build-") as td:
            built = run_command(
                [self.mojo, "build", "--emit", "llvm", *self._flags(), self.entry,
                 "-o", str(Path(td) / "gate.ll")],
                timeout=self.timeout)
        if built.returncode == 0:
            return Outcome.failed(f"{what}; the sabotaged source builds on its own",
                                  ran.output)
        if built.timed_out:
            return Outcome.unclear(f"{what}, and building it alone timed out: the "
                                   "phase cannot be told", ran.output)
        diagnostic = DIAGNOSTIC.search(built.output)
        if diagnostic:
            return Outcome.unbuilt(diagnostic.group(0).strip(), built.output)
        return Outcome.unclear(f"{what}, and building it alone failed without a "
                               f"diagnostic: {last_line(built.output)}", built.output)


class Command(Gate):
    """A command the harness runs as its gate -- a poe smoke, a probe --
    judged by its exit status and its own pass text. It reads the tree from
    disk, so it ignores the texts it is handed.

      passed   exit 0, with `passes` in the output.
      unbuilt  only with `builds=True`, for a command that compiles what the
               rules edit (`poe smoke-host` building `apps/host_check`): a
               Mojo diagnostic in the output. The sabotaged source did not
               build, so nothing after the build ran.
      failed   any other failure, with `detail(output)` as the line that
               says why -- a smoke's own assertion, which a rule's `expect`
               can insist on. A timeout is one too (`hung: ...`): a smoke
               owns its build and its timeouts, so a hang is the sabotaged
               tree's answer, as the harnesses before this one counted it.
      unclear  exit 0 without `passes`: the gate neither passed nor said
               what failed.

    `env` is laid over this process's environment as the command starts, so
    the command sees the TMPDIR `own_tmpdir` set; a value of None removes
    the name.
    """

    def __init__(self, argv: Sequence, *, passes: str,
                 env: Mapping[str, str | None] | None = None, timeout: float = 600,
                 builds: bool = False, detail: Callable[[str], str] = last_line):
        self.argv = [str(a) for a in argv]
        self.passes = passes
        self.env = dict(env or {})
        self.timeout = timeout
        self.builds = builds
        self.detail = detail

    def _environment(self) -> dict | None:
        if not self.env:
            return None
        env = dict(os.environ)
        for k, v in self.env.items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = v
        return env

    def run(self, texts: Mapping[Path, str] | None = None) -> Outcome:
        ran = run_command(self.argv, timeout=self.timeout, env=self._environment())
        out = ran.output
        if not ran.timed_out and ran.returncode == 0 and self.passes in out:
            return Outcome.passed(out)
        if self.builds:
            diagnostic = DIAGNOSTIC.search(out)
            if diagnostic:
                return Outcome.unbuilt(diagnostic.group(0).strip(), out)
        if ran.timed_out:
            return Outcome.failed(f"hung: timed out after {self.timeout:g} s", out)
        if ran.returncode == 0:
            return Outcome.unclear(f"exited 0 without {self.passes!r}: {last_line(out)}",
                                   out)
        return Outcome.failed(self.detail(out), out)


def verdict(r: Rule, o: Outcome) -> tuple[str, str]:
    """(verdict, the line that explains it) for one sabotaged run."""
    if o.kind == "passed":
        return MISSED, "the gate passed with the rule broken"
    if o.kind == "unbuilt":
        return UNBUILT, o.detail
    if o.kind != "failed":
        return ELSEWHERE, o.detail
    if r.expect:
        # Never a line that says a test passed or was skipped: it carries
        # the test's name, and a rule that expects the name would be caught
        # by any failure in the same suite.
        said = [ln.strip() for ln in (o.output + "\n" + o.detail).splitlines()
                if r.expect in ln and not _TEST_DID_NOT_FAIL.match(ln)]
        if not said:
            return ELSEWHERE, f"expected {r.expect!r}; the gate said: {o.detail}"
        return CAUGHT, said[0][:160]
    return CAUGHT, o.detail


# --- the run ----------------------------------------------------------------


class _Tree:
    """The files a run edits: the originals in memory and on disk, keyed by
    RELATIVE path, written back after every rule and again on the way out.
    A file a rule plants is None among the originals, and is removed."""

    def __init__(self, name: str, originals: Mapping[Path, str | None]):
        self.originals = dict(originals)
        self.backup = Path(tempfile.mkdtemp(prefix=f"{name}-backup-"))
        for path, text in self.originals.items():
            if text is None:
                continue
            dest = self.backup / _relative(path)
            dest.parent.mkdir(parents=True, exist_ok=True)
            write(dest, text)
        print(f"(the originals are backed up under {self.backup})", flush=True)

    def write(self, texts: Mapping[Path, str]) -> None:
        for path, text in texts.items():
            write(path, text)

    def restore(self, paths=None) -> None:
        with _signals_held():
            for path in self.originals if paths is None else paths:
                want = self.originals[path]
                if _read_or_none(path) != want:
                    if want is None:
                        path.unlink(missing_ok=True)
                    else:
                        write(path, want)

    def verified(self) -> bool:
        """Is every file back? Drops the backup if so; names it if not."""
        wrong = [p for p in self.originals if _read_or_none(p) != self.originals[p]]
        if not wrong:
            shutil.rmtree(self.backup, ignore_errors=True)
            return True
        print("\nTHE TREE IS NOT RESTORED. Put these back by hand:", flush=True)
        for p in wrong:
            if self.originals[p] is None:
                print(f"  remove {p}", flush=True)
            else:
                print(f"  {self.backup / _relative(p)} -> {p}", flush=True)
        return False


class UsageError(Exception):
    pass


def _options(argv: Sequence[str]) -> tuple[list[str], list[str]]:
    only: list[str] = []
    skip: list[str] = []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("--only", "--skip"):
            if not args:
                raise UsageError(f"{a} needs a value")
            (only if a == "--only" else skip).append(args.pop(0))
        elif a.startswith(("--only=", "--skip=")):
            key, _, value = a.partition("=")
            (only if key == "--only" else skip).append(value)
        else:
            raise UsageError(f"unknown argument {a!r}")
    return only, skip


def _matches(r: Rule, key: str, gate_names) -> bool:
    """A gate's name selects by gate; anything else is a label substring.
    (A label that happens to contain a gate's name is not that gate's.)"""
    return r.gate == key if key in gate_names else key in r.label


def _select(rules, only, skip, gate_names) -> list[Rule]:
    for key in only + skip:
        if not any(_matches(r, key, gate_names) for r in rules):
            raise UsageError(f"no rule matches {key!r} (a gate's name, "
                             f"{sorted(n for n in gate_names if n)}, or part "
                             "of a label)")
    return [r for r in rules
            if (not only or any(_matches(r, k, gate_names) for k in only))
            and not any(_matches(r, k, gate_names) for k in skip)]


@dataclass
class Report:
    status: int
    results: list  # (label, verdict, why), in table order


def _line(v: str, label: str, why: str) -> None:
    print(f"  {v:<{_WIDTH}}{label}" + (f"\n      {why}" if why else ""), flush=True)


def _said_instead(output: str, n: int = 12) -> None:
    """The last lines of a gate that failed elsewhere, so the miss can be
    read without a rerun."""
    lines = [ln[:200] for ln in output.strip().splitlines()[-n:]]
    if lines:
        print("      ... " + "\n      ... ".join(lines), flush=True)


def _baseline(rules, gates, originals) -> bool:
    print("baseline (unsabotaged) must PASS:", flush=True)
    for name in dict.fromkeys(r.gate for r in rules):
        shown = f"baseline ({name})" if name else "baseline"
        o = gates[name].run(dict(originals))
        if o.kind == "passed":
            print(f"  ok    {shown}", flush=True)
            continue
        print(f"  FAIL  {shown}: {o.kind}: {o.detail}", flush=True)
        if o.output:
            print(o.output[-2000:], flush=True)
        return False
    return True


def execute(name: str, rules: Sequence[Rule], gates, argv: Sequence[str] = (), *,
            write: bool = True,
            finish: Callable[[bool], bool] | None = None) -> Report:
    """Run a harness and report. `gates` is one Gate, or {name: Gate} with
    each rule naming its own. With `write=False` nothing on disk is touched
    and each gate compiles the texts it is handed. `finish(interrupted)`
    runs after the tree is back, when it was edited -- to rebuild artifacts
    from the restored source, say -- and returns whether that went well."""
    gates = gates if isinstance(gates, Mapping) else {"": gates}
    for r in rules:
        if r.gate not in gates:
            raise ValueError(f"{r.label}: no gate named {r.gate!r}")
    try:
        only, skip = _options(argv)
        chosen = _select(list(rules), only, skip, set(gates))
    except UsageError as exc:
        print(f"{name}: {exc}", flush=True)
        return Report(2, [])
    filters = " ".join([f"--only {k!r}" for k in only] + [f"--skip {k!r}" for k in skip])
    print(f"{name}: {len(chosen)} of {len(rules)} rule(s), on {SYSTEM}"
          + (f" ({filters})" if filters else ""), flush=True)

    files = list(dict.fromkeys(e.path for r in chosen for e in r.edits))
    planted = {e.path for r in chosen for e in r.edits if e.old is None}
    originals = {p: t for p in files
                 if (t := _read_or_none(p)) is not None or p in planted}
    results: dict[Rule, tuple[str, str]] = {}
    plans: dict[Rule, dict[Path, str]] = {}
    for r in chosen:
        try:
            plans[r] = apply(r, originals)
        except AnchorError as exc:
            results[r] = (NOT_APPLICABLE, str(exc))
            _line(NOT_APPLICABLE, r.label, str(exc))
    runnable = [r for r in chosen if r in plans and r.only_on in ("", SYSTEM)]
    for r in chosen:
        if r in plans and r not in runnable:
            results[r] = (SKIPPED, f"only observable on {r.only_on}")

    status = 0
    baseline_failed = False
    interrupted: Interrupted | None = None
    touched = list(dict.fromkeys(p for r in runnable for p in plans[r]))
    tree = None
    with _stop_on_signals():
        try:
            if write and runnable:
                tree = _Tree(name, {p: originals[p] for p in touched})
            if runnable and not _baseline(runnable, gates, originals):
                baseline_failed = True
                runnable = []
            for r in runnable:
                texts = plans[r]
                try:
                    if tree:
                        tree.write(texts)
                    outcome = gates[r.gate].run(texts)
                finally:
                    if tree:
                        tree.restore(list(texts))
                results[r] = verdict(r, outcome)
                _line(results[r][0], r.label, results[r][1])
                if results[r][0] == ELSEWHERE:
                    _said_instead(outcome.output)
        except Interrupted as exc:
            interrupted = exc
        finally:
            if tree:
                tree.restore()
                if not tree.verified():
                    status = 1
                try:
                    if finish and not finish(interrupted is not None):
                        status = 1
                except Interrupted as exc:
                    interrupted = exc
    for r in chosen:
        if results.get(r, ("",))[0] == SKIPPED:
            _line(SKIPPED, r.label, results[r][1])
    table = [(r.label, *results[r]) for r in rules if r in results]
    if interrupted is not None:
        signame = signal.Signals(interrupted.signum).name
        print(f"\n{name}: interrupted by {signame}; the tree is put back, and "
              f"{len(chosen) - len(table)} rule(s) never ran", flush=True)
        # Stop, never carry on: the tree is back, and the caller -- a
        # harness's `run`, which ends the process by the same signal --
        # must not go on to its next step as if one had merely failed.
        raise interrupted
    if baseline_failed:
        print(f"\n{name}: the unsabotaged tree does not pass its gate, so no rule "
              "was run and nothing is proven", flush=True)
        return Report(1, table)
    return Report(max(status, _tally(name, rules, chosen, table)), table)


def _tally(name, rules, chosen, table) -> int:
    counts = {v: sum(1 for _, got, _ in table if got == v) for v in _VERDICTS}
    deselected = len(rules) - len(chosen)
    parts = [f"{n} {v}" for v, n in counts.items() if n]
    if deselected:
        parts.append(f"{deselected} deselected by --only/--skip")
    print(f"\n{name}: " + "; ".join(parts), flush=True)
    bad = [(label, v) for label, v, _ in table if v not in (CAUGHT, SKIPPED)]
    if bad:
        print(f"{len(bad)} of {len(chosen)} rule(s) NOT proven guarded:", flush=True)
        for label, v in bad:
            print(f"  {v:<{_WIDTH}}{label}", flush=True)
        return 1
    caught = counts[CAUGHT]
    unproven = len(rules) - caught
    if not unproven:
        print(f"all {len(rules)} rule(s) are guarded", flush=True)
        return 0
    why = []
    if counts[SKIPPED]:
        why.append(f"{counts[SKIPPED]} skipped on {SYSTEM}")
    if deselected:
        why.append(f"{deselected} deselected")
    print(f"{caught} of {len(rules)} rule(s) proven guarded; {unproven} NOT proven "
          f"by this run ({', '.join(why)})", flush=True)
    return 0


def die_by(signum: int):
    """End this process BY `signum`, its default action restored.

    Once an interrupted run has put the tree back, it dies of the signal
    that stopped it rather than exiting 128+N: a parent then sees what
    happened -- bash abandons a loop only when a child died of SIGINT, and
    carries on past one that merely exited 130."""
    sys.stdout.flush()
    sys.stderr.flush()
    signal.signal(signum, signal.SIG_DFL)
    if hasattr(signal, "pthread_sigmask"):
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signum})
    os.kill(os.getpid(), signum)
    os._exit(128 + signum)  # only if the signal did not end the process


@contextmanager
def own_tmpdir(name: str):
    """Point TMPDIR at a directory of this run's own, and remove it on the
    way out, however the body ends.

    `scripts/smoke/lib.sh` keeps a failed smoke's `$SMOKE_DIR` (its logs)
    for CI to upload, and a harness fails its gate once per rule by design,
    so one local `sabotage-host` run left about forty `m0-smoke.*`
    directories in `$TMPDIR`. The lib's rule stands; what a harness runs
    gets a TMPDIR of its own instead, and `RUNNER_TEMP` goes for the same
    children, because the lib prefers it. What a failing gate prints is
    unchanged: the lib's `fail` prints each log it keeps. This process's own
    temporary files stay where they were -- a harness's backup must outlive
    a restore that failed -- because `tempfile` fixes its directory the first
    time it is asked, which making the scratch directory here does if nothing
    has yet.
    """
    scratch = Path(tempfile.mkdtemp(prefix=f"{name}."))
    saved = {k: os.environ.get(k) for k in ("TMPDIR", "RUNNER_TEMP")}
    os.environ["TMPDIR"] = str(scratch)
    os.environ.pop("RUNNER_TEMP", None)
    try:
        yield scratch
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(scratch, ignore_errors=True)


def run(name: str, rules: Sequence[Rule], gates, argv: Sequence[str] = (), *,
        write: bool = True, finish: Callable[[bool], bool] | None = None) -> int:
    """`execute`, for a harness's `main`, in a TMPDIR of its own
    (`own_tmpdir`): returns the exit status, or -- when SIGINT, SIGTERM or
    SIGHUP arrives -- puts the tree back and dies by it."""
    sys.stdout.reconfigure(line_buffering=True)
    try:
        with own_tmpdir(name):
            return execute(name, rules, gates, argv, write=write, finish=finish).status
    except Interrupted as exc:
        die_by(exc.signum)


# --- selftest ---------------------------------------------------------------

# `mojo run`'s output for each phase, captured from Mojo 1.1.0 on probe files
# (a pass, a failed assert, an unknown name, a failed constraint, an abort,
# and a test raising an Error whose text starts with `error:`). Paths are
# shortened, and the driver's Crashpad start-up line and all but one frame
# of the abort's stack dump are left out; nothing else is edited.
_MEASURED = {
    "pass": (0, """\
Running 2 tests for /w/bin/probe/test_pass.mojo
    PASS [ 0.001 ] test_one
    PASS [ 0.001 ] test_two
--------
Summary [ 0.001 ] 2 tests run: 2 passed , 0 failed , 0 skipped
"""),
    "assert": (1, """\
stack trace was not collected. Enable stack trace collection with environment variable `MODULAR_DEBUG=stack-trace-on-error`
Unhandled exception caught during execution:
Running 2 tests for /w/bin/probe/test_fail.mojo
    PASS [ 0.001 ] test_one
    FAIL [ 0.029 ] test_two
      At /w/bin/probe/test_fail.mojo:9:17: AssertionError: `left == right` comparison failed:
         left: 2
        right: 3
--------
Summary [ 0.029 ] 2 tests run: 1 passed , 1 failed , 0 skipped
Test suite' /w/bin/probe/test_fail.mojo 'failed!

/w/.venv/bin/mojo: error: execution exited with a non-zero result: 1
"""),
    "unknown name": (1, """\
/w/bin/probe/test_compile.mojo:5:21: error: use of unknown declaration 'undefined_name'
    assert_equal(1, undefined_name)
                    ^~~~~~~~~~~~~~
/w/.venv/bin/mojo: error: failed to parse the provided Mojo source module
"""),
    "constraint": (1, """\
/w/bin/probe/test_elab.mojo:13:5: error: function instantiation failed
def main() raises:
    ^
/w/bin/probe/test_elab.mojo:5:5: note: constraint failed: n must be positive
    comptime assert n > 0, "n must be positive"
    ^
/w/.venv/bin/mojo: error: failed to run the pass manager
"""),
    "abort": (1, """\
ABORT: /w/bin/probe/test_crash.mojo:10:10: boom
Stack dump without symbol names (ensure you have llvm-symbolizer in your PATH or set the environment var `LLVM_SYMBOLIZER_PATH` to point to it):
0  libKGENCompilerRTShared.dylib 0x000000011a9d12f0
/w/.venv/bin/mojo: error: execution crashed
"""),
    "raised error:": (1, """\
Unhandled exception caught during execution:
Running 2 tests for /w/bin/probe/test_raise.mojo
    PASS [ 0.001 ] test_one
    FAIL [ 0.001 ] test_two
      error: a message that looks like a diagnostic
--------
Summary [ 0.001 ] 2 tests run: 1 passed , 1 failed , 0 skipped
/w/.venv/bin/mojo: error: execution exited with a non-zero result: 1
"""),
}

# A stand-in for `mojo`, driven by the file it is asked to run: markers in
# the source pick which measured output it prints, so MojoRun is exercised
# through `run_command` exactly as against the real driver.
_FAKE_MOJO = r'''
import os, sys, time
sys.path.insert(0, {scripts!r})
from sabotage_lib import _MEASURED

def say(shape):
    rc, out = _MEASURED[shape]
    sys.stdout.write(out)
    sys.exit(rc)

entry = [a for a in sys.argv[2:] if a.endswith(".mojo")][0]
src = open(entry).read()
if sys.argv[1] == "build":
    if "SLOW_BUILD" in src:
        time.sleep(30)
    if "BROKEN" in src:
        say("unknown name")
    sys.exit(0)
if "HANG" in src:
    import subprocess
    server = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    open("gate.pid", "w").write(f"{{os.getpid()}} {{server.pid}}")
    time.sleep(60)
if "KILLED" in src:
    # SIGKILL, never a fault signal: on macOS every SEGV/BUS/ABRT death of
    # a Python writes a crash report, and can put a dialog in front of the
    # machine's owner. The fault path is pinned through `unplaced` instead.
    import signal
    os.kill(os.getpid(), signal.SIGKILL)
if "BROKEN" in src:
    say("unknown name")
if "CONSTRAINT" in src:
    say("constraint")
if "ABORT" in src:
    say("abort")
if "keep_a()" not in src:
    say("assert")
say("pass")
'''

_SOURCE = """\
def rule_a(): keep_a()
def rule_b(): keep_b()
def unguarded(): nothing_checks_this()
def dup(): same()
def dup(): same()
"""


def _default_signals() -> None:
    """In a child before exec: SIGINT and SIGTERM at their defaults, whatever
    this process inherited (a background job starts with SIGINT ignored)."""
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)


def _ended(pid: int, within: float = 3.0) -> bool:
    """Has `pid` exited within a few seconds? A zombie counts: on Linux its
    new parent may reap it late, and `kill(pid, 0)` still answers for it."""
    import time
    deadline = time.time() + within
    while time.time() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except OSError:
            return False
        try:
            with open(f"/proc/{pid}/stat") as f:
                if f.read().rsplit(")", 1)[1].split()[0] == "Z":
                    return True
        except (OSError, IndexError):
            pass
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)  # tidy up what the check found alive
    except OSError:
        pass
    return False


class _Raises(Gate):
    """A gate that passes its baseline, then raises `exc` on the sabotaged
    tree: a bug in it, or a signal's `Interrupted` arriving mid-run."""

    def __init__(self, inner: Gate, exc: BaseException):
        self.inner, self.exc, self.calls = inner, exc, 0

    def run(self, texts):
        self.calls += 1
        if self.calls > 1:
            raise self.exc
        return self.inner.run(texts)


def _selftest() -> int:
    import io
    import time
    from contextlib import redirect_stdout

    failures: list[str] = []

    def check(ok: bool, what: str) -> None:
        print(f"  {'ok  ' if ok else 'FAIL'}  {what}", flush=True)
        if not ok:
            failures.append(what)

    print("the `mojo run` phase rule, on measured output:")
    kinds = {shape: judge_mojo_run(Ran(rc, out)).kind
             for shape, (rc, out) in _MEASURED.items()}
    check(kinds["pass"] == "passed", "a passing suite is passed")
    check(kinds["assert"] == "failed", "a failed assert is a catch")
    check(kinds["unknown name"] == "unbuilt", "an unknown name does not compile")
    check(kinds["constraint"] == "unbuilt", "a failed constraint does not compile")
    check(kinds["abort"] == "failed", "an abort at run time is a catch")
    check(kinds["raised error:"] == "failed",
          "a test raising `error: ...` is a failing test, not a diagnostic")
    check("test_two" in judge_mojo_run(Ran(*_MEASURED["assert"])).detail,
          "a catch names the failing test")
    check(judge_mojo_run(Ran(-9, "")).kind == "unclear",
          "a driver killed with no output is unclear, never a catch")
    check(judge_mojo_run(Ran(0, "hello\n")).kind == "unclear",
          "exit 0 without the pass text is unclear, never a catch")

    print("anchors:")
    t = {Path("f"): "ab ab ab\n"}
    check(occurrences("ab ab ab", "ab ab") == 2, "overlapping matches are counted")
    for label, old, new, want in (
        ("zero", "nowhere", "x", "matches 0 times"),
        ("two", "ab ab", "x", "matches 2 times"),
        ("no-op", "ab ab ab", "ab ab ab", "changes nothing"),
    ):
        try:
            apply(rule(label, "f", old, new), t)
            check(False, f"{label}: an error")
        except AnchorError as exc:
            check(want in str(exc) and str(exc).startswith("f:"), f"{label}: {exc}")

    work = Path(tempfile.mkdtemp(prefix="sabotage-lib-selftest-"))
    here = Path.cwd()
    try:
        os.chdir(work)
        fake = work / "fake_mojo.py"
        write(fake, f"#!{sys.executable}\n"
              + _FAKE_MOJO.format(scripts=str(Path(__file__).resolve().parent)))
        fake.chmod(0o755)
        for d in ("a", "b"):
            Path(d).mkdir()
            write(Path(d) / "src.mojo", _SOURCE)
        A, B = Path("a/src.mojo"), Path("b/src.mojo")
        gate = MojoRun(A, includes=(), mojo=str(fake), timeout=20)

        def ran(rules, argv=(), gates=gate, **kw):
            buf = io.StringIO()
            with redirect_stdout(buf):
                rep = execute("selftest", rules, gates, argv, **kw)
            return rep, buf.getvalue()

        print("verdicts, end to end through a stand-in `mojo`:")
        rules = [
            rule("caught", A, "keep_a()", "gone()"),
            rule("unguarded", A, "nothing_checks_this()", "still_nothing()"),
            rule("broken", A, "keep_b()", "keep_b() BROKEN"),
            rule("crash", A, "keep_b()", "keep_b() ABORT"),
            rule("constraint", A, "keep_b()", "keep_b() CONSTRAINT"),
            rule("double", A, "def dup(): same()", "def dup(): other()"),
            rule("expect", A, "keep_a()", "gone()", expect="test_rule_a_invariant"),
            rule("expect the failing test", A, "keep_a()", "gone()", expect="test_two"),
            rule("expect the passing test", A, "keep_a()", "gone()", expect="test_one"),
            rule("elsewhere only", A, "keep_b()", "keep_b()  # other", only_on="Plan9"),
        ]
        rep, out = ran(rules)
        got = {label: v for label, v, _ in rep.results}
        check(got.get("caught") == CAUGHT, "a gate that fails at run time: caught")
        check(got.get("unguarded") == MISSED, "a gate that passes: MISSED")
        check(got.get("broken") == UNBUILT,
              "a sabotage that does not compile: MISSED (does not compile)")
        check(got.get("crash") == CAUGHT, "a crash at run time: caught")
        check(got.get("constraint") == UNBUILT,
              "a failed constraint: MISSED (does not compile)")
        check(got.get("double") == NOT_APPLICABLE
              and "a/src.mojo: the anchor matches 2 times" in out
              and "def dup(): same()" in out,
              "a double anchor: NOT APPLICABLE, naming the file and the anchor")
        check(got.get("expect") == ELSEWHERE,
              "a catch without the text the rule names: MISSED (failed elsewhere)")
        check(got.get("expect the failing test") == CAUGHT,
              "a catch in the test the rule names: caught")
        check(got.get("expect the passing test") == ELSEWHERE,
              "a catch while the test the rule names PASSES: MISSED (failed elsewhere)")
        skipped = Outcome.failed("1 test(s) fail: test_two",
                                 _MEASURED["assert"][1].replace("PASS [", "SKIP ["))
        check(verdict(rule("skip", A, "a", "b", expect="test_one"), skipped)[0] == ELSEWHERE
              and verdict(rule("skip", A, "a", "b", expect="test_two"), skipped)[0] == CAUGHT,
              "a skipped test's line is no catch either; the failing one's is")
        check(got.get("elsewhere only") == SKIPPED, "another platform's rule: SKIPPED")
        check(rep.status == 1, "any miss fails the run")
        check(read(A) == _SOURCE and read(B) == _SOURCE, "the tree is put back")
        backup = re.search(r"backed up under (\S+)\)", out)
        check(backup is not None and not Path(backup.group(1)).exists(),
              "the backup is dropped once the tree is verified")

        rep, out = ran([rules[0], rules[-1]])
        last = out.strip().splitlines()[-1]
        check(rep.status == 0, "caught and SKIPPED alone pass")
        check(not last.startswith("all ") and "NOT proven" in last,
              f"a SKIPPED rule is never summarised as guarded: {last!r}")
        rep, out = ran(rules[:2])
        check(rep.status == 1 and out.strip().splitlines()[-1].strip().endswith("unguarded"),
              "a run with a MISSED rule lists it last")
        rep, out = ran(rules, ["--only", "unguarded"])
        check([v for _, v, _ in rep.results] == [MISSED], "--only takes a label substring")
        rep, out = ran([rules[0], rules[1]], ["--skip", "unguarded"])
        check(rep.status == 0 and "1 deselected" in out and "NOT proven" in out,
              "--skip deselects, and says so")
        rep, _ = ran(rules, ["--only", "no such rule"])
        check(rep.status == 2, "a filter that matches nothing is a usage error")
        rep, _ = ran(rules, ["--ony", "caught"])
        check(rep.status == 2, "an unknown argument is a usage error")
        by_gate = [rule("a unit rule's label", A, "keep_a()", "x()", gate="smoke"),
                   rule("the unit rule", A, "keep_a()", "y()", gate="unit")]
        rep, _ = ran(by_gate, ["--only", "unit"], gates={"smoke": gate, "unit": gate})
        check([label for label, _, _ in rep.results] == ["the unit rule"],
              "a gate's name selects by gate, not by label")

        print("a failure the output cannot place asks the compiler:")
        # Long enough for the stand-in's own start on a slow runner: a build
        # that times out for that reason would read as a hang nothing places.
        quick = MojoRun(A, includes=(), mojo=str(fake), timeout=3)
        for marker, want, what in (
            ("HANG", "failed", "a hang in a source that builds: caught"),
            ("HANG BROKEN", "unbuilt", "a hang in a source that does not build: does not compile"),
            ("HANG SLOW_BUILD", "unclear", "a timeout nothing can place: a miss"),
            ("KILLED", "unclear", "a driver SIGKILLed from outside: a miss, never a catch"),
        ):
            write(A, _SOURCE + f"# {marker}\n")
            check(quick.run({}).kind == want, what)
        write(A, _SOURCE)
        # A fault signal's path, on synthetic results: no real SEGV here.
        for rc, said, want, what in (
            (-int(signal.SIGSEGV), "", "crashed: the driver died of SIGSEGV",
             "a driver dead of SIGSEGV with nothing said: asks the compiler"),
            (-int(signal.SIGBUS), "UniversalExceptionRaise: (os/kern) failure (5)\n",
             "crashed: the driver died of SIGBUS",
             "a driver dead of SIGBUS, crash handler and all (measured): asks the compiler"),
            (-int(signal.SIGKILL), "", "",
             "a driver dead of SIGKILL: judged as it stands, a miss"),
            (1, _MEASURED["assert"][1], "", "a run that said its phase: judged as it stands"),
        ):
            ran_ = Ran(rc, said)
            check(unplaced(ran_, judge_mojo_run(ran_), 5) == want, what)
        check(unplaced(Ran(None, ""), None, 5).startswith("hung"),
              "a timeout: asks the compiler")

        print("relative-path backups:")
        buf = io.StringIO()
        with redirect_stdout(buf):
            tree = _Tree("selftest", {A: _SOURCE, B: _SOURCE + "# b\n"})
        check(_read_or_none(tree.backup / "a/src.mojo") == _SOURCE
              and _read_or_none(tree.backup / "b/src.mojo") == _SOURCE + "# b\n",
              "two files named src.mojo are backed up apart")
        shutil.rmtree(tree.backup)
        both = rule("both", (A, B), ("keep_a()", "keep_a()"), ("x()", "y()"))
        rep, _ = ran([both])
        check(rep.results[0][1] == CAUGHT and read(A) == _SOURCE and read(B) == _SOURCE,
              "a rule across two files is caught and puts both back")

        print("a command as the gate:")

        def sh(script, **kw):
            return Command(["sh", "-c", script], passes="gate OK", **kw)

        for script, kw, want, what in (
            ("echo gate OK", {}, "passed", "exit 0 with its pass text: passed"),
            ("echo done", {}, "unclear",
             "exit 0 without its pass text: neither a pass nor a catch"),
            ("echo 'x.mojo:3:4: error: no'; exit 1", {"builds": True}, "unbuilt",
             "a diagnostic from a command that builds the rule's source: does not compile"),
            ("echo 'x.mojo:3:4: error: no'; exit 1", {}, "failed",
             "the same where the compile IS the gate: a failure"),
        ):
            check(sh(script, **kw).run({}).kind == want, what)
        hung = sh("sleep 30", timeout=1).run({})
        check(hung.kind == "failed" and hung.detail.startswith("hung"),
              "a command that hangs: the gate's failure, saying so")
        said = sh("echo the assertion; echo '=== a.log ==='; echo booted; exit 1",
                  detail=lambda out: out.splitlines()[0]).run({})
        check(said.kind == "failed" and said.detail == "the assertion",
              "a failure is explained in the gate's own words")
        os.environ["SABOTAGE_SELFTEST_B"] = "inherited"
        try:
            said = sh('echo "$SABOTAGE_SELFTEST_A-${SABOTAGE_SELFTEST_B-unset}"; exit 1',
                      env={"SABOTAGE_SELFTEST_A": "set", "SABOTAGE_SELFTEST_B": None}).run({})
        finally:
            del os.environ["SABOTAGE_SELFTEST_B"]
        check(said.detail == "set-unset", f"env sets one name and removes another: {said.detail!r}")
        on_disk = sh("grep -q 'keep_a()' a/src.mojo && echo gate OK || "
                     "{ echo 'rule_a is gone'; exit 1; }")
        rep, _ = ran([rule("on disk", A, "keep_a()", "gone()", expect="rule_a is gone")],
                     gates=on_disk)
        check(rep.results[0][1] == CAUGHT and read(A) == _SOURCE,
              "a command reads the sabotaged tree from disk: caught, and put back")
        rep, out = ran([rule("elsewhere", A, "keep_a()", "gone()", expect="not this")],
                       gates=on_disk)
        check(rep.results[0][1] == ELSEWHERE and "... rule_a is gone" in out,
              "a gate that failed elsewhere: what it said instead is shown")

        print("a rule that plants a file:")
        planted = Path("a/planted.mojo")
        absent = sh("test -e a/planted.mojo && { echo 'a stray file'; exit 1; } "
                    "|| echo gate OK")
        plant = rule("plant", planted, None, "def stray(): pass\n")

        def verdict_of(rep):
            return {label: v for label, v, _ in rep.results}.get("plant")

        rep, _ = ran([plant], gates=absent)
        check(verdict_of(rep) == CAUGHT and not planted.exists(),
              "a planted file is caught, then removed")
        write(planted, "already here\n")
        rep, out = ran([plant], gates=absent)
        check(verdict_of(rep) == NOT_APPLICABLE and "it exists" in out
              and read(planted) == "already here\n",
              "a file the rule would plant exists: NOT APPLICABLE, and left alone")
        planted.unlink()
        try:
            ran([plant], gates=_Raises(absent, Interrupted(signal.SIGTERM)))
            check(False, "an interruption mid-plant is re-raised")
        except Interrupted:
            check(not planted.exists(), "an interruption mid-plant removes the file")

        print("a TMPDIR of the run's own:")
        # This process's temporary directory moves into `work` for the
        # section, so an `own_tmpdir` that leaks leaks nothing real.
        lib = Path(__file__).resolve().parent / "smoke" / "lib.sh"
        home, runner = work / "tmp", work / "runner"
        home.mkdir()
        runner.mkdir()
        env_before = {k: os.environ.get(k) for k in ("TMPDIR", "RUNNER_TEMP")}
        tempdir_before = tempfile.tempdir
        os.environ["TMPDIR"], os.environ["RUNNER_TEMP"] = str(home), str(runner)
        tempfile.tempdir = None  # a harness that has not asked for it yet
        try:
            with own_tmpdir("selftest") as scratch:
                smoke = subprocess.run(["sh", "-c", f". {lib}\nexit 1"],
                                       capture_output=True, text=True, timeout=60)
                kept = list(scratch.glob("m0-smoke.*"))
                own = Path(tempfile.mkdtemp(prefix="backup-"))
            check(smoke.returncode == 1 and len(kept) == 1,
                  "a lib smoke that fails keeps its directory in the run's own")
            check(not list(home.glob("m0-smoke.*")) and not list(runner.glob("m0-smoke.*")),
                  "not in TMPDIR, nor in RUNNER_TEMP, which the lib prefers")
            check(not scratch.exists(), "the run's directory is gone once it ends")
            check(own.parent == home and own.exists(),
                  "this process's own temporary files stay outside it, and outlive it")
            check(os.environ.get("TMPDIR") == str(home)
                  and os.environ.get("RUNNER_TEMP") == str(runner),
                  "TMPDIR and RUNNER_TEMP are put back")
            try:
                with own_tmpdir("selftest") as scratch:
                    raise RuntimeError("a harness with a bug in it")
            except RuntimeError:
                check(not scratch.exists(), "the directory goes when the run raises, too")
        finally:
            tempfile.tempdir = tempdir_before
            for k, v in env_before.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

        print("the tree is put back whatever stops the run:")
        try:
            ran([both], gates=_Raises(gate, RuntimeError("a gate with a bug in it")))
            check(False, "a gate that raises: the error reaches the caller")
        except RuntimeError:
            check(read(A) == _SOURCE and read(B) == _SOURCE,
                  "a gate that raises: both files are back")
        try:
            ran([both], gates=_Raises(gate, Interrupted(signal.SIGTERM)))
            check(False, "an interruption is re-raised, never returned as a status")
        except Interrupted:
            check(read(A) == _SOURCE and read(B) == _SOURCE,
                  "an interruption is re-raised after both files are back, never "
                  "returned for the caller to carry on past")
        driver = work / "driver.py"
        write(driver, (
            "import sys\n"
            f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
            "from sabotage_lib import MojoRun, rule, run\n"
            f"gate = MojoRun('a/src.mojo', includes=(), mojo={str(fake)!r}, timeout=60)\n"
            "r = rule('hang', ('a/src.mojo', 'b/src.mojo'),"
            " ('keep_b()', 'keep_a()'), ('keep_b() HANG', 'gone()'))\n"
            "sys.exit(run('selftest', [r], gate, sys.argv[1:]))\n"))
        for sig in (signal.SIGINT, signal.SIGTERM):
            name = signal.Signals(sig).name
            Path("gate.pid").unlink(missing_ok=True)
            proc = subprocess.Popen([sys.executable, str(driver)], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, preexec_fn=_default_signals)
            deadline = time.time() + 30
            while not Path("gate.pid").exists() and time.time() < deadline:
                time.sleep(0.05)
            time.sleep(0.1)
            sabotaged = read(A) != _SOURCE and read(B) != _SOURCE
            proc.send_signal(sig)
            try:
                said = _text(proc.communicate(timeout=30)[0])
            except subprocess.TimeoutExpired:
                proc.kill()
                said = "(the driver did not stop)"
            pids = [int(p) for p in read(Path("gate.pid")).split()] \
                if Path("gate.pid").exists() else []
            check(sabotaged, f"{name}: both files were sabotaged when it arrived")
            check(proc.returncode == -sig and f"interrupted by {name}" in said,
                  f"{name}: the harness says why, then dies BY {name} "
                  f"(got {proc.returncode})")
            check(read(A) == _SOURCE and read(B) == _SOURCE,
                  f"{name}: both files are back")
            check(len(pids) == 2 and all(_ended(p) for p in pids),
                  f"{name}: the gate AND the server it started end with the harness")
            if proc.returncode != -sig:
                print(said)
    finally:
        os.chdir(here)
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        print(f"sabotage_lib selftest: {len(failures)} check(s) FAILED")
        return 1
    print("sabotage_lib selftest OK")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        try:
            sys.exit(_selftest())
        except Interrupted as exc:
            die_by(exc.signum)
    print(__doc__)
    sys.exit(2)
