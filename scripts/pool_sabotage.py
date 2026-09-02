#!/usr/bin/env python3
"""Revert each rule in `mojo_pool.mojo` and insist a guard fails for every one.

Same idea as `shim_ownership.py --sabotage`: a guard nobody has broken on
purpose is a guard nobody knows works.

    python3 scripts/pool_sabotage.py
"""

from __future__ import annotations

import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# The venv's own compiler, never `uv run mojo`: a child `uv run` re-syncs the
# venv to uv.lock even under a parent `uv run --no-sync` (measured 2026-09-02:
# the child printed Mojo 1.0.0 and the venv stayed there), which on a nightly
# (`poe canary`, nightly-canary.yml) swaps the toolchain back to stable
# mid-run and reports the next step's ".mojoc is newer than the compiler" as
# a nightly break. poe's virtualenv executor puts .venv/bin first on PATH, so
# the sibling of this interpreter is the compiler every other task uses.
_SIBLING = Path(sys.executable).with_name("mojo")
MOJO = str(_SIBLING) if _SIBLING.exists() else (shutil.which("mojo") or "mojo")

POOL = Path("packages/m0-http/lightbug_http/mojo_pool.mojo")
TEST = Path("packages/m0-http/test/test_mojo_pool.mojo")

IS_LINUX = platform.system() == "Linux"

# (label, old, new, linux_only) — each reverts one load-bearing rule.
#
# `linux_only` marks a rule whose breakage is INVISIBLE on macOS, so the suite
# genuinely cannot catch it here and reporting it as an uncovered gap would be
# noise. There is exactly one, and it is not a weakness in the test: closing
# lane 0's write end wakes a blocked `recv` on macOS and does not on Linux
# (`OffloadPool.stop`'s docstring, which records the 20-minute CI timeout that
# established it). So a missing pill strands a thread only on Linux, where CI
# runs this file too.
SABOTAGES = [
    (
        "completion never sent (the loop waits forever)",
        "        pool.put_response(slot, response^, raised)\n        pool.complete(slot)",
        "        pool.put_response(slot, response^, raised)",
        False,
    ),
    (
        "one pill too few (a thread parks forever)",
        "        if zero > 0:\n            pool.stop(zero, 0)",
        "        if zero > 1:\n            pool.stop(zero - 1, 0)",
        True,
    ),
    (
        "handler built once and shared instead of per thread",
        "    var handler = T.make(PoolContext(index, block.get(BLK_USER), lane))",
        "    var handler = T.make(PoolContext(0, block.get(BLK_USER), lane))",
        False,
    ),
    (
        "poison pill ignored (join never completes)",
        "        if job.kind == JOB_STOP:\n            break",
        "        if job.kind == JOB_STOP:\n            continue",
        False,
    ),
]


def run_tests() -> tuple[bool, str]:
    p = subprocess.run(
        [MOJO, "run", "-I", "packages/m0-http", "-I",
         "packages/m0-core", str(TEST)],
        capture_output=True, text=True, timeout=300,
    )
    out = p.stdout + p.stderr
    return ("0 failed" in out and "tests run" in out and p.returncode == 0), out


def main() -> int:
    original = POOL.read_text()
    backup = Path(tempfile.mkdtemp()) / "mojo_pool.mojo"
    backup.write_text(original)

    print("baseline (unsabotaged) must PASS:")
    ok, out = run_tests()
    print(f"  {'ok' if ok else 'FAIL'}  baseline")
    if not ok:
        print(out[-1500:])
        return 1

    failures = []
    skipped = []
    for label, old, new, linux_only in SABOTAGES:
        if linux_only and not IS_LINUX:
            print(f"  skip  {label} (only observable on Linux)")
            skipped.append(label)
            continue
        if old not in original:
            print(f"  FAIL  anchor missing: {label}")
            failures.append(label)
            continue
        POOL.write_text(original.replace(old, new, 1))
        try:
            ok, out = run_tests()
        except subprocess.TimeoutExpired:
            ok, out = False, "(timed out — which is itself a failure)"
        POOL.write_text(original)
        # A sabotaged build must NOT pass.
        good = not ok
        print(f"  {'ok  ' if good else 'BAD '}  {label}")
        if not good:
            failures.append(label)

    shutil.copy(backup, POOL)
    print()
    if failures:
        print(f"{len(failures)} rule(s) not covered by any guard:")
        for f in failures:
            print(f"  - {f}")
        return 1
    n = len(SABOTAGES) - len(skipped)
    print(f"all {n} checkable rule(s) are guarded"
          + (f"; {len(skipped)} skipped on {platform.system()}" if skipped else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
