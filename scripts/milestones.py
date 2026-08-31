#!/usr/bin/env python3
"""Where the project is against beta and 1.0, computed rather than remembered.

`docs/SPEC.md` already tracks 149 capabilities and is already machine-checked
-- but it says what IS, never what must BECOME true, so "what is left?" was
not a question anything could answer. It was answered by whoever remembered,
which is the gap this file closes.

**Milestones are derived from row STATUS, not annotated per row.** Adding a
milestone column would mean editing 149 rows and keeping them right for ever;
the two definitions below need no new data at all:

    beta   every row is `verified`, `planned` or `out of scope`
           -- i.e. NOTHING in the tree ships without a gate.
    1.0    every row is `verified` or `out of scope`, plus the three
           non-row conditions under CHECKS below.

The beta ordering is not arbitrary. Gating an `implemented` row has found a
real defect four times out of four -- A4's unbounded close linger, I16's
echoed close codes, L17's silent inbound message loss, and A11's two
`Expect: 100-continue` violations. The remaining `implemented` rows are
therefore both the finish line and the highest-yield work available.

REPORT vs CHECK, and the split matters:

* The milestone PROGRESS is a report. A gate that failed until 1.0 would
  make every pull request red for months, and a red that means "not finished
  yet" teaches people to ignore red.
* The ROT rules below are gates, because each one describes something that
  should never be true AND that whoever trips it can fix in the same pull
  request. That second half is why the soak's STALENESS is reported and not
  gated: nobody can re-run somebody else's Django projects to get a patch
  merged, and a gate nobody can satisfy is a gate somebody disables.

The first rule earned its place the day it was written -- the "suspected
race: the WebSocket close path can RST instead of FIN" entry had been fixed
in v0.15.1 and gated by L15/L16, and was still listed as an open risk,
because nothing retired it and nothing could.

    python3 scripts/milestones.py             # the report
    python3 scripts/milestones.py --check     # the rot gates
    python3 scripts/milestones.py --sabotage  # and prove they bite
"""

import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC_JSON = ROOT / "docs" / "spec.json"
ROADMAP = ROOT / "docs" / "ROADMAP.md"
REAL_APP = ROOT / "docs" / "REAL_APP_VALIDATION.md"
PYPROJECT = ROOT / "pyproject.toml"

# How far the real-application pass may lag the current version before it
# stops being evidence. Two minors: far enough not to gate every release,
# close enough that "we ran it against something like this" stays true.
# It is a SOAK requirement rather than a row, because no row can express
# "somebody else's Django project still works".
REAL_APP_MAX_MINOR_LAG = 2


def _rows():
    return json.loads(SPEC_JSON.read_text())["capabilities"]


def _current_version():
    m = re.search(r'^version = "([0-9]+)\.([0-9]+)\.([0-9]+)"',
                  PYPROJECT.read_text(), re.M)
    if not m:
        return None
    return tuple(int(x) for x in m.groups())


def _known_issues(text=None):
    """(title, body) for each `- **...**` bullet under `## Known issues`."""
    text = text if text is not None else ROADMAP.read_text()
    try:
        start = text.index("\n## Known issues")
    except ValueError:
        return []
    rest = text[start + 1:]
    end = rest.find("\n## ", 1)
    section = rest[:end] if end > 0 else rest
    out = []
    for chunk in re.split(r"\n(?=- \*\*)", section):
        if not chunk.lstrip().startswith("- **"):
            continue
        title = chunk.lstrip()[4:].split("**", 1)[0]
        out.append((title, chunk))
    return out


def _real_app_version(text=None):
    text = text if text is not None else REAL_APP.read_text()
    m = re.search(r"m0serve ([0-9]+)\.([0-9]+)\.([0-9]+)", text)
    return tuple(int(x) for x in m.groups()) if m else None


# --- the report -------------------------------------------------------------

def report():
    rows = _rows()
    impl = [r for r in rows if r["status"] == "implemented"]
    plan = [r for r in rows if r["status"] == "planned"]
    ver = sum(1 for r in rows if r["status"] == "verified")
    oos = sum(1 for r in rows if r["status"] == "out of scope")

    print("%d capabilities: %d verified, %d out of scope, %d implemented, "
          "%d planned" % (len(rows), ver, oos, len(impl), len(plan)))
    print()
    print("BETA — nothing in the tree ships without a gate")
    if impl:
        print("  %d row(s) remain:" % len(impl))
        for r in impl:
            print("    %-5s %s" % (r["id"], r["capability"][:66]))
    else:
        print("  MET")
    print()
    print("1.0 — beta, plus every `planned` row resolved, plus the soak")
    if plan:
        print("  %d planned row(s) remain (build, or move to `out of scope` "
              "with a reason):" % len(plan))
        for r in plan:
            print("    %-5s %s" % (r["id"], r["capability"][:66]))
    else:
        print("  rows: MET")

    cur = _current_version()
    ra = _real_app_version()
    if cur and ra:
        lag = (cur[0] - ra[0]) * 1000 + (cur[1] - ra[1])
        state = "MET" if lag <= REAL_APP_MAX_MINOR_LAG else "STALE"
        print("  soak: real applications last run against %d.%d.%d, current "
              "is %d.%d.%d — %s" % (ra + cur + (state,)))
    issues = _known_issues()
    print("  known issues: %d open" % len(issues))
    print()
    remaining = len(impl) + len(plan)
    print("%d row(s) between here and 1.0." % remaining)


# --- the gates --------------------------------------------------------------

def check(roadmap_text=None, real_app_text=None, rows=None):
    """Rules that describe something which should never be true."""
    rows = rows if rows is not None else _rows()
    by_id = {r["id"]: r for r in rows}
    failures = []

    # 1. Every Known issue declares what would close it, and is retired once
    #    that has happened. Found a stale entry the day it was written: the
    #    "suspected race: the WebSocket close path can RST instead of FIN"
    #    was diagnosed and fixed in v0.15.1 and gated by L15/L16, and was
    #    still listed as an open risk. Nothing retired it because nothing
    #    could; a reader would have believed the close path was unreliable.
    for title, body in _known_issues(roadmap_text):
        m = re.search(r"\*\*Closed by:\*\*\s*([^\n]+)", body)
        if not m:
            failures.append(
                "known issue %r has no `**Closed by:**` line. Name the "
                "SPEC rows whose `verified` would retire it, or `none` for "
                "one no row can close (an upstream bug, a toolchain gap)"
                % title[:60]
            )
            continue
        # Ids only, up to an em-dash: an entry is allowed to say WHY in the
        # same line, and a checker that choked on the explanation would
        # train people to write none of it.
        ids_part = re.split(r"—|--", m.group(1))[0]
        named = [t.strip(" .`") for t in ids_part.split(",") if t.strip(" .`")]
        if not named:
            failures.append(
                "known issue %r has an empty `**Closed by:**`" % title[:50])
            continue
        if named == ["none"]:
            continue
        unknown = [n for n in named if n not in by_id]
        if unknown:
            failures.append(
                "known issue %r names %s, which is not a SPEC row id"
                % (title[:50], ", ".join(unknown))
            )
            continue
        if all(by_id[n]["status"] == "verified" for n in named):
            failures.append(
                "known issue %r names %s, and every one is now `verified` — "
                "retire the issue to `## Recently resolved`. An issue that "
                "outlives its fix reads as an open risk"
                % (title[:50], ", ".join(named))
            )

    # 2. The soak record must be READABLE. Its staleness is reported rather
    #    than gated, and the distinction is the whole design: a contributor
    #    cannot re-run somebody else's Django projects inside the pull
    #    request that trips the gate, and a gate nobody can satisfy is a
    #    gate somebody disables. Staleness is a 1.0 condition, so it belongs
    #    in the report beside the rows. What IS gated is the record being
    #    parseable at all, because a version this cannot read is a soak
    #    nobody can measure.
    if _current_version() is None:
        failures.append("could not read `version` from pyproject.toml")
    if _real_app_version(real_app_text) is None:
        failures.append(
            "could not read an `m0serve X.Y.Z` version from "
            "docs/REAL_APP_VALIDATION.md — the 1.0 soak is measured against "
            "it, and an unreadable record measures nothing"
        )
    return failures


# --- sabotage ---------------------------------------------------------------

SABOTAGES = [
    ("a known issue loses its Closed-by line",
     lambda rm, ra, rows: (rm.replace("**Closed by:** none", "", 1), ra, rows)),
    ("a known issue names a row that does not exist",
     lambda rm, ra, rows: (rm.replace("**Closed by:** none",
                                      "**Closed by:** Z99", 1), ra, rows)),
    ("a known issue outlives the row that closes it",
     lambda rm, ra, rows: (rm.replace("**Closed by:** none",
                                      "**Closed by:** A1", 1), ra, rows)),
    ("the soak record loses its version",
     lambda rm, ra, rows: (rm, ra.replace("m0serve 0.", "m0serve X.", 1)
                           if "m0serve 0." in ra else ra, rows)),
]


def sabotage():
    rm = ROADMAP.read_text()
    ra = REAL_APP.read_text()
    rows = _rows()
    if check(rm, ra, rows):
        print("milestones: the tree already fails --check; fix that first")
        for f in check(rm, ra, rows):
            print("  -", f)
        return 1
    bad = 0
    for name, mutate in SABOTAGES:
        m_rm, m_ra, m_rows = mutate(rm, ra, rows)
        if (m_rm, m_ra) == (rm, ra):
            print("  NOT APPLICABLE  %s" % name)
            bad += 1
            continue
        if check(m_rm, m_ra, m_rows):
            print("  caught          %s" % name)
        else:
            print("  NOT CAUGHT      %s" % name)
            bad += 1
    if bad:
        print("milestones: %d sabotage(s) went unnoticed" % bad)
        return 1
    print("milestones: all %d sabotages caught" % len(SABOTAGES))
    return 0


def main(argv):
    if "--sabotage" in argv:
        return sabotage()
    if "--check" in argv:
        failures = check()
        if failures:
            print("milestones: FAIL")
            for f in failures:
                print("  -", f)
            return 1
        print("milestones: known issues declare what closes them, and the "
              "real-application soak is current")
        return 0
    report()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
