#!/usr/bin/env python3
"""Ratchet the Mojo compiler warning count so a new warning cannot hide.

Reads a build/test log on stdin or from a file, counts unique warning sites,
and compares them to scripts/warning_baseline.json. Exits non-zero if the
total rises or a warning category appears that the baseline does not list.

    uv run poe check-warnings <log>        # or: ... | check-warnings -
    uv run poe check-warnings <log> --update   # rewrite the baseline

Why a script and not `grep -c`. Three things make the naive count wrong, and
each one was observed while establishing the first baseline:

1.  The same site is reported under several path spellings. `poe` runs some
    builds from inside a package (`cd packages/m0-datastar && mojo precompile
    src -I ../m0-http/`), so one site appears as `packages/m0-http/...`, as
    `../m0-http/...`, and as an absolute path, depending on who compiled it.
    Counting raw lines triples it. Paths are therefore resolved against the
    `cd` that poe echoes, then made repo-relative.

2.  `test-all` recompiles library sources once per test binary, so a single
    site is reported ~4.5 times over a run. Sites are deduplicated by
    (file, line, col).

3.  A bare-relative form (`src/multiworker.mojo`, emitted by `mojo precompile
    src`) is easy to miss with a pattern anchored on `packages/`. Four real
    library warnings hid behind exactly that mistake. Nothing here anchors on
    a leading directory name.

The baseline stores per-category counts as well as the total. Categories are
line-number independent — messages are masked of their quoted operands — so
they survive ordinary edits, which is what makes "a new *kind* of warning
appeared" a signal worth failing on even when the total happens not to rise.
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASELINE = Path(__file__).resolve().parent / "warning_baseline.json"

# poe colourises its output whenever it thinks a terminal is watching, and on
# GitHub Actions it does even though the output is piped. The escapes land in
# the middle of the very lines this parses: `\x1b[37mPoe =>\x1b[0m \x1b[94mcd
# packages/m0-datastar && ...`. Left in, `^Poe =>` never matches, the `cd`
# context is never picked up, and every `../m0-http/...` path stays unresolved
# and counts as a site distinct from its `packages/m0-http/...` self — which
# is exactly how a locally-clean 68 arrived at CI as 70.
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# A warning line: <path>:<line>:<col>: warning: <message>
WARNING_RE = re.compile(r"^(?P<path>[^\s:]+\.mojo):(?P<line>\d+):(?P<col>\d+): warning: (?P<msg>.*)$")
# poe echoes each task's command; `cd <dir> &&` tells us what relative paths
# in the warnings that follow are relative *to*.
POE_CD_RE = re.compile(r"^Poe =>\s*cd\s+(?P<dir>\S+)\s*&&")
POE_RE = re.compile(r"^Poe =>")

# Quoted operands vary per site ('Header', 'slot', "C"); the category should not.
MASK_RE = re.compile(r"'[^']*'|\"[^\"]*\"|`[^`]*`")

# A failed build emits few warnings simply because it stopped compiling. Left
# unchecked that reads as a large improvement and the ratchet passes — it was
# observed reporting "63 warning site(s) fixed" off a log whose build had died
# on line 26. A log containing errors is not evidence about warnings.
ERROR_RE = re.compile(r": error: |Sequence aborted after failed subtask|failed to parse the provided")


# Top-level directories of this repo. A relative warning path that starts with
# one of them is already repo-relative and must NOT be joined to the `cd`
# context, or a stale context turns packages/m0-http/... into
# packages/m0-datastar/packages/m0-http/... and splits one site into two.
REPO_TOPLEVEL = ("packages/", "apps/", "scripts/")


def normalise_path(raw: str, cwd: str) -> str:
    """Resolve one warning path to a stable repo-relative form."""
    if posixpath.isabs(raw):
        try:
            return Path(raw).resolve().relative_to(REPO_ROOT).as_posix()
        except ValueError:
            return raw  # outside the repo (toolchain internals); keep verbatim
    if raw.startswith(REPO_TOPLEVEL):
        return posixpath.normpath(raw)
    return posixpath.normpath(posixpath.join(cwd, raw))


def categorise(msg: str) -> str:
    return MASK_RE.sub("X", msg).strip()


def scan(lines) -> tuple[set[tuple[str, str, str]], Counter, list[str]]:
    """Return unique (file, line, col) sites, per-category counts, and errors."""
    cwd = ""
    sites: set[tuple[str, str, str]] = set()
    category_of: dict[tuple[str, str, str], str] = {}
    errors: list[str] = []

    for raw_line in lines:
        line = ANSI_RE.sub("", raw_line).rstrip("\n")
        if ERROR_RE.search(line):
            errors.append(line.strip())
        cd_match = POE_CD_RE.match(line)
        if cd_match:
            cwd = cd_match.group("dir").rstrip("/")
            continue
        if POE_RE.match(line):
            cwd = ""  # a task with no `cd` runs from the repo root
            continue
        m = WARNING_RE.match(line.strip())
        if not m:
            continue
        site = (normalise_path(m.group("path"), cwd), m.group("line"), m.group("col"))
        sites.add(site)
        category_of.setdefault(site, categorise(m.group("msg")))

    return sites, Counter(category_of.values()), errors


DOC_WARNING = "doc string summary should begin with a capital letter"


def selftest() -> int:
    """Pin the parsing rules that a silent regression here would defeat.

    Every case below is a bug that actually happened, not a hypothetical: the
    parser is a CI gate, and one that quietly stops matching would let real
    warnings through while still reporting a comfortable number.
    """
    cases: list[tuple[str, list[str], int, str]] = [
        (
            "cd-relative and absolute spellings of one site collapse",
            [
                "Poe => cd packages/m0-datastar && mojo precompile src -I ../m0-http/",
                "../m0-http/lightbug_http/http/date.mojo:35:17: warning: alloc is deprecated",
                "Poe => mojo run packages/m0-http/test/t.mojo",
                "packages/m0-http/lightbug_http/http/date.mojo:35:17: warning: alloc is deprecated",
                f"{REPO_ROOT}/packages/m0-http/lightbug_http/http/date.mojo:35:17: warning: alloc is deprecated",
            ],
            1,
            "the ../ , repo-relative and absolute forms are the same site",
        ),
        (
            "ANSI-coloured poe output still yields the cd context",
            [
                "\x1b[37mPoe =>\x1b[0m \x1b[94mcd packages/m0-datastar && mojo precompile src\x1b[0m",
                "../m0-http/lightbug_http/http/date.mojo:35:17: warning: alloc is deprecated",
                "packages/m0-http/lightbug_http/http/date.mojo:35:17: warning: alloc is deprecated",
            ],
            1,
            "colour escapes must not hide the `cd`",
        ),
        (
            "a bare-relative path is not skipped",
            [
                "Poe => cd packages/m0-http && mojo precompile src",
                f"src/multiworker.mojo:97:8: warning: {DOC_WARNING}, but this begins with 'f'",
            ],
            1,
            "anchoring on packages/ once lost four real warnings",
        ),
        (
            "a task without cd resets the context to the repo root",
            [
                "Poe => cd packages/m0-datastar && mojo precompile src",
                "Poe => mojo run packages/m0-core/test/t.mojo",
                "packages/m0-core/test/t.mojo:1:1: warning: something",
            ],
            1,
            "a stale cwd would mangle paths for every later task",
        ),
    ]

    failures = 0
    for name, lines, want, why in cases:
        sites, _, errors = scan(lines)
        got = len(sites)
        if got != want or errors:
            failures += 1
            print(f"FAIL  {name}: expected {want} site(s), got {got} — {why}", file=sys.stderr)
            for site in sorted(sites):
                print(f"        {site}", file=sys.stderr)
        else:
            print(f"ok    {name}")

    # An errored log must be rejected rather than counted.
    _, _, errors = scan(["src/x.mojo:1:1: error: boom"])
    if not errors:
        failures += 1
        print("FAIL  compiler errors must be detected", file=sys.stderr)
    else:
        print("ok    compiler errors are detected")

    print("selftest:", "FAILED" if failures else "all passed")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", nargs="?", help="build/test log to read, or - for stdin")
    ap.add_argument("--update", action="store_true", help="rewrite the baseline from this log")
    ap.add_argument("--selftest", action="store_true", help="check the parser against known cases")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.log:
        ap.error("a log is required unless --selftest is given")

    stream = sys.stdin if args.log == "-" else open(args.log, encoding="utf-8", errors="replace")
    with stream:
        sites, categories, errors = scan(stream)

    total = len(sites)

    # Check this before anything else, including --update: a broken build must
    # never be able to move the baseline down.
    if errors:
        print(
            f"FAIL: the log contains {len(errors)} compiler error line(s), so its warning\n"
            "count is meaningless — a build that stopped early simply warns less.\n"
            "Fix the build, then re-run. First few:",
            file=sys.stderr,
        )
        for line in errors[:3]:
            print(f"  {line}", file=sys.stderr)
        return 2

    if args.update:
        BASELINE.write_text(
            json.dumps({"total": total, "categories": dict(sorted(categories.items()))}, indent=2) + "\n"
        )
        print(f"baseline updated: {total} unique warning sites")
        for cat, n in sorted(categories.items(), key=lambda kv: -kv[1]):
            print(f"  {n:4d}  {cat}")
        return 0

    if not BASELINE.exists():
        print(f"no baseline at {BASELINE}; create one with --update", file=sys.stderr)
        return 2

    base = json.loads(BASELINE.read_text())
    base_total, base_cats = base["total"], base["categories"]

    print(f"unique warning sites: {total} (baseline {base_total})")
    for cat, n in sorted(categories.items(), key=lambda kv: -kv[1]):
        delta = n - base_cats.get(cat, 0)
        flag = "" if delta == 0 else f"  [{delta:+d}]"
        print(f"  {n:4d}  {cat}{flag}")

    # A run that compiled nothing would otherwise "pass" with zero warnings
    # and, worse, invite someone to --update the baseline down to zero.
    if total == 0 and base_total > 0:
        print(
            "\nFAIL: no warnings found at all. That usually means the log is empty "
            "or the build never ran, not that every warning was fixed.",
            file=sys.stderr,
        )
        return 1

    failed = False
    if total > base_total:
        print(
            f"\nFAIL: {total - base_total} new warning site(s) (total {total} > baseline {base_total}).",
            file=sys.stderr,
        )
        failed = True

    new_categories = sorted(set(categories) - set(base_cats))
    if new_categories:
        print("\nFAIL: warning categories not present in the baseline:", file=sys.stderr)
        for cat in new_categories:
            print(f"  {categories[cat]:4d}  {cat}", file=sys.stderr)
        failed = True

    if failed:
        print(
            "\nFix the new warnings, or if they are genuinely unfixable on the pinned\n"
            "toolchain, record why (NOTICE / the file's docstring) and re-run with\n"
            "--update to move the baseline.",
            file=sys.stderr,
        )
        return 1

    if total < base_total:
        print(
            f"\n{base_total - total} warning site(s) fixed. Tighten the ratchet:\n"
            f"  uv run poe check-warnings <log> --update"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
