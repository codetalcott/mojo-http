#!/usr/bin/env python3
"""Revert each trailer rule in `chunked.mojo` and insist a test fails for it.

Same idea as `scripts/pool_sabotage.py` and `shim_ownership.py --sabotage`: a
guard nobody has broken on purpose is a guard nobody knows works.

The trailer states were the decoder's genuinely untested region -- the
round-trip tests set `consume_trailer = True` but their wire carried no
trailer section, so every state below `IN_TRAILERS_LINE_HEAD` was reached by
no test at all (SPEC A10). Each entry here is one rule those states implement,
and every one must be caught by `test_parsing.mojo`.

    python3 scripts/trailer_sabotage.py
"""

from __future__ import annotations

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

CHUNKED = Path("packages/m0-http/lightbug_http/http/chunked.mojo")
TEST = Path("packages/m0-http/test/test_parsing.mojo")

# (label, old, new) — each reverts one load-bearing rule.
SABOTAGES = [
    (
        "consume_trailer ignored: the body ends at the zero chunk",
        """                if self.bytes_left_in_chunk == 0:
                    if self.consume_trailer:
                        self._state = DecoderState.IN_TRAILERS_LINE_HEAD
                        continue
                    else:
                        ret = buffer_len - src
                        break""",
        """                if self.bytes_left_in_chunk == 0:
                    ret = buffer_len - src
                    break""",
    ),
    (
        "consume_trailer forced on: a caller framing its own trailers loses them",
        """                if self.bytes_left_in_chunk == 0:
                    if self.consume_trailer:""",
        """                if self.bytes_left_in_chunk == 0:
                    if True:""",
    ),
    (
        "the trailer's terminating CRLF is left behind",
        """                if buf[src] == BytesConstant.LF:
                    src += 1
                    ret = buffer_len - src
                    break""",
        """                if buf[src] == BytesConstant.LF:
                    ret = buffer_len - src
                    break""",
    ),
    (
        "a trailer line is copied into the body instead of discarded",
        """            elif self._state == DecoderState.IN_TRAILERS_LINE_MIDDLE:
                while src < buffer_len:
                    if buf[src] == BytesConstant.LF:
                        break
                    src += 1""",
        """            elif self._state == DecoderState.IN_TRAILERS_LINE_MIDDLE:
                while src < buffer_len:
                    if buf[src] == BytesConstant.LF:
                        break
                    var _bp = buf.unsafe_ptr()
                    _bp[unsafe_offset = dst] = _bp[unsafe_offset = src]
                    dst += 1
                    src += 1""",
    ),
    (
        "the abuse ratio no longer bounds the trailer section",
        "            if self._total_overhead >= 100 * 1024 and self._total_read - self._total_overhead < self._total_read // 4:\n                ret = -1",
        "            if False:\n                ret = -1",
    ),
    (
        "the abuse ratio fires on every trailer",
        "            if self._total_overhead >= 100 * 1024 and self._total_read - self._total_overhead < self._total_read // 4:\n                ret = -1",
        "            if self._total_overhead > 0:\n                ret = -1",
    ),
]


def run_tests() -> tuple[bool, str]:
    p = subprocess.run(
        [MOJO, "run", "-I", "packages/m0-http", "-I",
         "packages/m0-core", str(TEST)],
        capture_output=True, text=True, timeout=600,
    )
    out = p.stdout + p.stderr
    return ("0 failed" in out and "tests run" in out and p.returncode == 0), out


def _named_failures(out: str) -> str:
    names = [ln.split("]")[-1].strip() for ln in out.splitlines() if "FAIL" in ln]
    names = [n for n in names if n.startswith("test_")]
    if not names:
        return "(build error)"
    head = ", ".join(names[:3])
    return f"{len(names)} test(s) fail: {head}" + (", ..." if len(names) > 3 else "")


def main() -> int:
    original = CHUNKED.read_text()
    backup = Path(tempfile.mkdtemp()) / "chunked.mojo"
    backup.write_text(original)

    print("baseline (unsabotaged) must PASS:")
    ok, out = run_tests()
    print(f"  {'ok' if ok else 'FAIL'}  baseline")
    if not ok:
        print(out[-1500:])
        return 1

    failures = []
    for label, old, new in SABOTAGES:
        if old not in original:
            print(f"  FAIL  anchor missing: {label}")
            failures.append(label)
            continue
        CHUNKED.write_text(original.replace(old, new, 1))
        try:
            ok, out = run_tests()
        except subprocess.TimeoutExpired:
            ok, out = False, "(timed out — which is itself a failure)"
        CHUNKED.write_text(original)
        good = not ok
        detail = f"  ({_named_failures(out)})" if good else ""
        print(f"  {'ok  ' if good else 'BAD '}  {label}{detail}")
        if not good:
            failures.append(label)

    shutil.copy(backup, CHUNKED)
    print()
    if failures:
        print(f"{len(failures)} rule(s) not covered by any guard:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"all {len(SABOTAGES)} trailer rule(s) are guarded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
