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
    1.0    every row outside section N is `verified` or `out of scope`,
           plus the non-row conditions under CHECKS below.
    layer  every section-N row is `verified` or `out of scope`, plus a
           soak on the layer: an application outside `apps/` running on
           `Views`/`Fragment`, recorded in REAL_APP_VALIDATION.md's
           application-layer section under the 1.0 soak's staleness rule.

Section N (the application layer, SPEC's "Writing an application in Mojo")
is the third milestone's and not 1.0's, because 1.0 shipped before the
section existed and its `planned` rows would otherwise read as 1.0 going
backwards. The third milestone is NOT MET until a real application runs on
the layer -- that is the honest reading of a layer proven by demos, and
the reason it is computed rather than assumed.

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

# The application layer's rows, and the heading its soak is recorded under
# in REAL_APP_VALIDATION.md. The section holds a `**Last run <date>**,
# against m0serve X.Y.Z` line once an application outside apps/ has run on
# the layer, and says "Not yet run" until then.
LAYER_SECTION = "N"
LAYER_SOAK_HEADING = "The application layer"


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


def _layer_soak_section(text=None):
    """The application layer's section of the soak record, or None."""
    text = text if text is not None else REAL_APP.read_text()
    marker = "\n## " + LAYER_SOAK_HEADING
    try:
        start = text.index(marker)
    except ValueError:
        return None
    rest = text[start + 1:]
    end = rest.find("\n## ", 1)
    return rest[:end] if end > 0 else rest


def _server_soak_text(text):
    """The record with the layer's section cut out, so the server's version
    is read from the server's own headline whatever order the sections
    end up in."""
    section = _layer_soak_section(text)
    return text if section is None else text.replace(section, "", 1)


def _real_app_version(text=None):
    """The version the server's soak last ran against, from the record's own
    `Last run ... against m0serve X.Y.Z` headline and nothing looser.

    It used to take the FIRST `m0serve X.Y.Z` anywhere in the server's half
    of the record, which was the headline until a later section's heading
    carried a version too (the 2026-09-12 production entry). The reader
    then still found the headline and nothing moved -- but the sabotage
    that blanks the headline started finding the second one instead, so
    "the soak record loses its version" stopped being caught and the
    report would have gone on printing a version the record no longer
    named. Anchoring on the headline is the property `_layer_soak_version`
    already claims for itself: a version mentioned in passing is not a
    soak.
    """
    text = text if text is not None else REAL_APP.read_text()
    m = re.search(r"Last run[^\n]*?against (?:m0serve|m0-http) "
                  r"([0-9]+)\.([0-9]+)\.([0-9]+)",
                  _server_soak_text(text))
    return tuple(int(x) for x in m.groups()) if m else None


def _layer_soak_version(text=None):
    """The version the layer's soak last ran against, or None when the
    section is missing or says it has not run. Reads the record's own
    `Last run ... against m0serve X.Y.Z` line and nothing looser, so a
    version mentioned in passing is not a soak."""
    section = _layer_soak_section(text)
    if section is None:
        return None
    m = re.search(r"Last run[^\n]*?against (?:m0serve|m0-http) "
                  r"([0-9]+)\.([0-9]+)\.([0-9]+)", section)
    return tuple(int(x) for x in m.groups()) if m else None


def _lag(cur, ran):
    return (cur[0] - ran[0]) * 1000 + (cur[1] - ran[1])


# --- the report -------------------------------------------------------------

def report():
    rows = _rows()
    impl = [r for r in rows if r["status"] == "implemented"]
    plan = [r for r in rows if r["status"] == "planned"
            and r["section"] != LAYER_SECTION]
    layer = [r for r in rows if r["section"] == LAYER_SECTION]
    layer_impl = [r for r in layer if r["status"] == "implemented"]
    layer_plan = [r for r in layer if r["status"] == "planned"]
    ver = sum(1 for r in rows if r["status"] == "verified")
    oos = sum(1 for r in rows if r["status"] == "out of scope")
    plan_all = sum(1 for r in rows if r["status"] == "planned")

    print("%d capabilities: %d verified, %d out of scope, %d implemented, "
          "%d planned" % (len(rows), ver, oos, len(impl), plan_all))
    print()
    print("BETA — nothing in the tree ships without a gate")
    if impl:
        print("  %d row(s) remain:" % len(impl))
        for r in impl:
            print("    %-5s %s" % (r["id"], r["capability"][:66]))
    else:
        print("  MET")
    print()
    print("1.0 — beta, plus every `planned` row outside section N resolved, "
          "plus the soak")
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
        state = "MET" if _lag(cur, ra) <= REAL_APP_MAX_MINOR_LAG else "STALE"
        print("  soak: real applications last run against %d.%d.%d, current "
              "is %d.%d.%d — %s" % (ra + cur + (state,)))
    issues = _known_issues()
    print("  known issues: %d open" % len(issues))
    print()
    print("APPLICATION LAYER — section N gated, its `planned` rows resolved, "
          "and a real application on it")
    if layer_impl:
        print("  %d row(s) ship without a gate:" % len(layer_impl))
        for r in layer_impl:
            print("    %-5s %s" % (r["id"], r["capability"][:66]))
    if layer_plan:
        print("  %d planned row(s) remain (build, or move to `out of scope` "
              "with a reason):" % len(layer_plan))
        for r in layer_plan:
            print("    %-5s %s" % (r["id"], r["capability"][:66]))
    if not layer_impl and not layer_plan:
        print("  rows: MET")
    ls = _layer_soak_version()
    if ls is None:
        layer_soak_met = False
        print("  soak: no application outside apps/ has run on the layer "
              "— NOT MET")
    elif cur:
        layer_soak_met = _lag(cur, ls) <= REAL_APP_MAX_MINOR_LAG
        print("  soak: the layer last ran a real application against "
              "%d.%d.%d, current is %d.%d.%d — %s"
              % (ls + cur + ("MET" if layer_soak_met else "STALE",)))
    else:
        layer_soak_met = False
    print()
    remaining = len(impl) + len(plan)
    layer_left = len(layer_impl) + len(layer_plan)
    print("%d row(s) between here and 1.0. %d row(s)%s between here and the "
          "application layer's milestone."
          % (remaining, layer_left,
             "" if layer_soak_met else " and the soak"))


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
    # 3. The application layer's soak has a section to be read from. Its
    #    STATE is reported (NOT MET is the honest answer today, and will
    #    be until a real application runs on the layer), but the section
    #    itself is gated: without it the third milestone has nothing to
    #    read, and a milestone that quietly stops being computed is worse
    #    than one that says NOT MET.
    if _layer_soak_section(real_app_text) is None:
        failures.append(
            "docs/REAL_APP_VALIDATION.md has no `## %s` section — the "
            "application layer's milestone reads its soak from there, and "
            "says NOT MET until an application outside apps/ has run on "
            "the layer; the section must exist to say so" % LAYER_SOAK_HEADING
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
    # The mutation must hit the version `_real_app_version` actually reads
    # -- the FIRST `m0serve X.Y.Z` in the file -- and must not name a
    # major. It was `ra.replace("m0serve 0.", ...)` behind an
    # `if "m0serve 0." in ra` guard, which the 1.0.0 headline turned into a
    # no-op: the string it looked for is not in the file at all any more
    # (the older sections write their versions bare, as "against 0.19.0"),
    # so the guard fell through to `ra` unchanged. `sabotage()` reports
    # that as NOT APPLICABLE and fails, which is the right end -- but a
    # sabotage that stops applying the day a version rolls is a guard with
    # an expiry date on it, so match the shape rather than the digits.
    ("the soak record loses its version",
     lambda rm, ra, rows: (
         rm, re.sub(r"m0serve \d+\.\d+\.\d+", "m0serve X.Y.Z", ra, count=1),
         rows)),
    ("the application layer's soak section is deleted",
     lambda rm, ra, rows: (
         rm, ra.replace("\n## " + LAYER_SOAK_HEADING,
                        "\n## A heading the milestone does not read", 1),
         rows)),
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
