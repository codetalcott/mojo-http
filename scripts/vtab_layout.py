#!/usr/bin/env python3
"""Check vtab.mojo's hardcoded SQLite struct offsets against sqlite3.h.

`packages/m0-sqlite/src/vtab.mojo` treats four SQLite C structs as flat word
buffers, so every offset it uses is a `comptime` integer the Mojo compiler
cannot check. `test/verify_layout.c` re-derives each from the installed
sqlite3.h with `_Static_assert` -- but until this script existed it asserted
its OWN copies of the numbers (`offsetof(sqlite3_module, xBestIndex) ==
3 * 8`), so it proved the header against the C file and never looked at the
Mojo file it exists to protect. A wrong `M_BESTINDEX` in vtab.mojo compiled,
passed the guard, and corrupted rows in silence. Checking C against C,
adjacent to the thing it protects.

Now the numbers come from the Mojo source. This script:

1. extracts every `comptime NAME: Int = N` from vtab.mojo;
2. requires the two files to name the SAME closed set of layout constants --
   every `M0_NAME` macro the C file uses must be a constant vtab.mojo
   defines, and every constant vtab.mojo defines must either be asserted by
   the C file or be on the explicit list below of constants that describe
   Mojo's own allocations rather than SQLite's structs;
3. compiles the C file with each constant passed as `-DM0_NAME=N`.

`--sabotage` perturbs each layout constant in memory, one at a time, and
insists the compile fails for every one; it also breaks each rule of step 2
and insists the checker reports it. Verify by the ABSENCE of BAD / anchor
failures and the exit code, not by the count.

    python3 scripts/vtab_layout.py              # the gate (poe verify-vtab-layout)
    python3 scripts/vtab_layout.py --sabotage   # prove the gate can fail
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

VTAB = Path("packages/m0-sqlite/src/vtab.mojo")
C_FILE = Path("packages/m0-sqlite/test/verify_layout.c")

# Constants vtab.mojo defines that describe something SQLite's headers cannot
# corroborate: Mojo's own spec header (S_*), the cursor fields Mojo appends
# after the SQLite base struct (C_COUNT..C_WORDS; C_VTAB and C_DATA ARE
# checked, because the base struct's size is what places them), the element
# kinds, and the version floor, which is policy. Anything not here and not
# named by verify_layout.c is an offset nobody asserted -- the failure names
# it so the author decides which list it joins.
MOJO_OWN = {
    "S_DATA", "S_COUNT", "S_KIND", "S_WORDS",
    "C_COUNT", "C_KIND", "C_INDEX", "C_WORDS",
    "KIND_INT", "KIND_FLOAT",
    "SQLITE_MIN_VTAB_VERSION",
}

_CONST = re.compile(r"^comptime ([A-Z][A-Z0-9_]*): Int = (\d[\d_]*)\s*$", re.M)
_MACRO = re.compile(r"\bM0_([A-Z][A-Z0-9_]*)\b")


def extract_constants(vtab_text: str) -> dict[str, int]:
    """Every `comptime NAME: Int = <literal>` in vtab.mojo, by name."""
    return {m.group(1): int(m.group(2).replace("_", "")) for m in _CONST.finditer(vtab_text)}


def cross_check(consts: dict[str, int], c_text: str) -> list[str]:
    """The two closed sets must agree; returns the disagreements."""
    problems = []
    named = set(_MACRO.findall(c_text))
    for name in sorted(named - set(consts)):
        problems.append(
            f"verify_layout.c asserts M0_{name}, but vtab.mojo defines no"
            f" `comptime {name}: Int` -- the guard names a constant that does not exist"
        )
    for name in sorted(set(consts) - named - MOJO_OWN):
        problems.append(
            f"vtab.mojo defines {name} = {consts[name]}, and verify_layout.c"
            f" never asserts M0_{name}: add a CHECK for it, or list it in"
            f" MOJO_OWN if it describes a Mojo allocation rather than a SQLite struct"
        )
    for name in sorted(named & MOJO_OWN):
        problems.append(
            f"{name} is listed as Mojo-own in vtab_layout.py AND asserted by"
            f" verify_layout.c -- it must be one or the other"
        )
    return problems


def compile_check(consts: dict[str, int], c_text: str, workdir: Path) -> tuple[bool, str]:
    """`cc -fsyntax-only` over `c_text` with every constant as -DM0_NAME=N."""
    src = workdir / "verify_layout.c"
    src.write_text(c_text)
    cc = os.environ.get("CC", "cc")
    defines = [f"-DM0_{k}={v}" for k, v in sorted(consts.items())]
    p = subprocess.run(
        [cc, "-fsyntax-only", *defines, str(src)],
        capture_output=True, text=True, timeout=120,
    )
    return p.returncode == 0, p.stdout + p.stderr


def check(vtab_text: str, c_text: str, workdir: Path) -> list[str]:
    """Pure function of the two sources: the list of failures, empty if green."""
    consts = extract_constants(vtab_text)
    if not consts:
        return ["no `comptime NAME: Int = N` constants found in vtab.mojo"]
    problems = cross_check(consts, c_text)
    if problems:
        return problems
    ok, out = compile_check(consts, c_text, workdir)
    if not ok:
        return ["verify_layout.c rejects vtab.mojo's offsets:\n" + out.rstrip()]
    return []


# --- sabotage -----------------------------------------------------------------


# The allocation sizes: asserted as `sizeof(struct) <= N * 8`, never `==`.
COVERS = {"M_SLOTS", "V_WORDS"}


def _set(vtab_text: str, name: str, value: int) -> str:
    """Replace one constant's literal in memory; the anchor must exist."""
    pat = re.compile(rf"^(comptime {name}: Int = )(\d[\d_]*)(\s*)$", re.M)
    m = pat.search(vtab_text)
    if not m:
        raise KeyError(name)
    return vtab_text[: m.start()] + f"{m.group(1)}{value}{m.group(3)}" + vtab_text[m.end():]


def _bump(vtab_text: str, name: str, delta: int) -> str:
    """Perturb one constant's literal by `delta`."""
    return _set(vtab_text, name, extract_constants(vtab_text)[name] + delta)


def sabotage(vtab_text: str, c_text: str, workdir: Path) -> int:
    consts = extract_constants(vtab_text)
    layout = sorted(set(consts) - MOJO_OWN)

    print("baseline (unsabotaged) must PASS:")
    base = check(vtab_text, c_text, workdir)
    print(f"  {'FAIL' if base else 'ok'}  baseline")
    if base:
        for b in base:
            print("   ", b)
        return 1

    cases: list[tuple[str, str, str]] = []
    # Every SQLite-layout constant, moved one word (or one byte, for the
    # byte-addressed constraint fields) -- except the two allocation sizes,
    # which are `<=` assertions: a larger buffer is legal by design (iVersion
    # bounds SQLite's reads), and one word short may still cover a struct
    # whose last word is padding, so those are set to ONE word, which covers
    # neither struct on any header.
    for name in layout:
        if name in COVERS:
            cases.append((f"{name} set to 1 word", _set(vtab_text, name, 1), c_text))
        else:
            cases.append((f"{name} off by +1", _bump(vtab_text, name, 1), c_text))
    # A new offset nobody asserted: it must be named by the guard or the list.
    cases.append((
        "an unasserted layout constant added to vtab.mojo",
        vtab_text.replace("comptime M_SLOTS: Int", "comptime M_UPDATE: Int = 13\ncomptime M_SLOTS: Int", 1),
        c_text,
    ))
    # The guard quietly dropping an assertion.
    dropped = re.sub(r'^CHECK\("M_BESTINDEX".*\n', "", c_text, count=1, flags=re.M)
    if dropped == c_text:
        print("  FAIL  anchor missing: the M_BESTINDEX CHECK line")
        return 1
    cases.append(("verify_layout.c stops asserting M_BESTINDEX", vtab_text, dropped))
    # The guard asserting a name the Mojo file does not define.
    cases.append((
        "verify_layout.c asserts a constant vtab.mojo lacks",
        vtab_text,
        c_text.replace("M0_M_BESTINDEX", "M0_M_BEST_INDEX", 1),
    ))
    # A constant on both lists at once.
    cases.append((
        "a Mojo-own constant also asserted by the C file",
        vtab_text,
        c_text + '\nCHECK("S_DATA", 0, M0_S_DATA);\n',
    ))

    failures = []
    for label, vt, ct in cases:
        problems = check(vt, ct, workdir)
        good = bool(problems)
        detail = f"  ({problems[0].splitlines()[0][:90]})" if good else ""
        print(f"  {'ok  ' if good else 'BAD '}  {label}{detail}")
        if not good:
            failures.append(label)

    print()
    if failures:
        print(f"{len(failures)} sabotage(s) not caught:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"all {len(cases)} layout sabotages are caught")
    return 0


def main(argv: list[str]) -> int:
    import tempfile

    vtab_text = VTAB.read_text()
    c_text = C_FILE.read_text()
    with tempfile.TemporaryDirectory() as d:
        workdir = Path(d)
        if "--sabotage" in argv:
            return sabotage(vtab_text, c_text, workdir)
        problems = check(vtab_text, c_text, workdir)
    if problems:
        for p in problems:
            print("FAIL:", p)
        return 1
    n = len(set(extract_constants(vtab_text)) - MOJO_OWN)
    print(f"verify-vtab-layout: {n} vtab.mojo offsets agree with sqlite3.h")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
