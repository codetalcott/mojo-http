"""The spec-sheet ratchet: every capability claim names evidence that exists.

    python3 scripts/spec_sheet.py            # render the rollup + spec.json
    python3 scripts/spec_sheet.py --check    # fail if either is stale
    python3 scripts/spec_sheet.py --sabotage # revert each rule, insist it fails

docs/SPEC.md is a public completeness tracker. Its value rests entirely on
`verified` meaning something, so the word is defined mechanically here: a row
may say `verified` only if it names a gate that exists AND runs, on a cadence
this file can confirm from the workflow files.

The checks are pure functions of TEXT rather than readers of paths. That is not
style: `--sabotage` follows scripts/shim_ownership.py and scripts/pool_sabotage.py
in patching sources *in memory* and insisting the suite goes red for each. Four
of the seventeen sabotages mutate pyproject.toml, test.yml or cli.mojo rather
than the sheet, so every source has to arrive as an argument.

What this CANNOT do, stated here because the page states it too: it proves a
cited gate runs, never that the gate tests the capability the row claims. No
string-matching checker reads a test's meaning. That gap is closed by review.

Deliberately NOT a rule, having been tried and found arbitrary: "wire-level
categories must cite a smoke step, not a unit test". Section B (smuggling) is
legitimately all unit tests -- rejecting a malformed frame is pure parser logic
-- so the rule would have to carve out exceptions until it meant nothing. The
degradation it was meant to stop is bounded instead by RULE 6, which forces
every wire-level CI gate to be accounted for by some row.
"""

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SHEET = REPO / "docs" / "SPEC.md"

STATUSES = ("verified", "implemented", "planned", "out of scope")
CADENCES = ("every PR", "weekly", "pre-release")
LEGEND = "How to read this page"

BEGIN = "<!-- generated: spec-rollup -- edit the tables below, not this block -->"
END = "<!-- /generated: spec-rollup -->"

# `verified` evidence: `gate` (cadence) optionally followed by an em-dash note.
_EVIDENCE = re.compile(r"^`(?P<gate>[^`]+)` \((?P<cadence>[^)]+)\)(?: — (?P<note>.+))?$")
_UNIT = re.compile(r"^(?P<file>test_[a-z0-9_]+\.mojo):(?P<fn>test_[a-z0-9_]+)$")
_FLAG = re.compile(r"`(--[a-z][a-z-]*)`")
_SKIP_GUARD = re.compile(r"python3 -c 'import (\w+)'[^\n]*exit 0")


def split_cells(line):
    """Cells of a markdown table row, splitting on UNESCAPED pipes only.

    `docs/WSGI_CONFORMANCE.md` already contains `joined with \\|` inside a cell,
    and this sheet's own vocabulary needs `M0-Hold: stream|websocket`. A naive
    `strip('|').split('|')` -- which is what check_docs.py's `_platform_table`
    does for the two-column platform tables -- mis-splits both.
    """
    out, cur, i = [], "", 0
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    while i < len(body):
        if body[i] == "\\" and i + 1 < len(body):
            cur += body[i + 1]
            i += 2
        elif body[i] == "|":
            out.append(cur.strip())
            cur = ""
            i += 1
        else:
            cur += body[i]
            i += 1
    out.append(cur.strip())
    return out


def parse(sheet):
    """(rows, failures) from the sheet text.

    RULE 1 lives here: every pipe line in the file is examined. A row cannot
    hide by sitting under a heading the parser does not recognise, by being
    malformed, or by carrying a status word that matches nothing -- each is a
    named failure rather than a silent skip. `_claims_support` in check_docs.py
    classifies by substring and so has an ordering dependence ("not supported"
    contains "supported"); statuses here match whole, anchored.
    """
    rows, failures, section = [], [], None
    for n, line in enumerate(sheet.splitlines(), 1):
        heading = re.match(r"^## (.+?)\s*$", line)
        if heading:
            section = heading.group(1)
            continue
        if not line.lstrip().startswith("|"):
            continue
        cells = split_cells(line)
        if all(set(c) <= set("-: ") and c for c in cells):
            continue  # the |---|---| underline
        if section == LEGEND:
            if len(cells) != 2:
                failures.append(
                    f"docs/SPEC.md:{n}: the legend table must be 2 cells, got "
                    f"{len(cells)}"
                )
            continue
        if cells == ["capability", "status", "evidence"]:
            continue
        if len(cells) != 3:
            failures.append(
                f"docs/SPEC.md:{n}: a capability row must be exactly 3 cells "
                f"(capability, status, evidence), got {len(cells)}: {line.strip()!r}"
            )
            continue
        cat = re.match(r"^([A-Z])\. (.+)$", section or "")
        if not cat:
            failures.append(
                f"docs/SPEC.md:{n}: capability row outside a capability section "
                f"(nearest heading {section!r}) — rows must live under a "
                f"'## <Letter>. <Title>' heading so none can hide from the rollup"
            )
            continue
        capability, status, evidence = cells
        if status not in STATUSES:
            failures.append(
                f"docs/SPEC.md:{n}: unknown status word {status!r} — must be "
                f"exactly one of {', '.join(STATUSES)}. An unrecognised status "
                f"would otherwise skip every rule below it."
            )
            continue
        rows.append(
            {
                "id": cat.group(1),
                "category": section,
                "capability": capability,
                "status": status,
                "evidence": evidence,
            }
        )
    return rows, failures


def _sequences(pyproject):
    """poe sequence tasks, as name -> [referenced task]."""
    out = {}
    blocks = re.findall(
        r"^\[tool\.poe\.tasks\.([a-z0-9-]+)\]$(.*?)(?=^\[tool\.poe\.tasks\.)",
        pyproject + "\n[tool.poe.tasks.__end__]\n",
        re.M | re.S,
    )
    for name, body in blocks:
        if "sequence" in body:
            out[name] = re.findall(r'"([a-z0-9-]+)"', body)
    return out


def _reachable(pyproject, root="test-all"):
    seq, seen, queue = _sequences(pyproject), set(), [root]
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        queue.extend(seq.get(name, ()))
    return seen


def _task_bodies(pyproject):
    """smoke task name -> its shell body."""
    out = {}
    blocks = re.findall(
        r"^\[tool\.poe\.tasks\.(smoke-[a-z0-9-]+)\]$(.*?)(?=^\[tool\.poe\.tasks\.)",
        pyproject + "\n[tool.poe.tasks.__end__]\n",
        re.M | re.S,
    )
    for name, body in blocks:
        out[name] = body
    return out


def _steps(workflow):
    """test.yml step name -> (poe tasks it runs, whether it carries an `if:`).

    Steps are `- name: X` followed by `run:`; a step with no name (there is one,
    in the aarch64 job) simply contributes nothing to cite.
    """
    out, name, conditional, buf = {}, None, False, []

    def flush():
        if name and buf:
            tasks = set(re.findall(r"poe ([a-z0-9-]+)", "\n".join(buf)))
            if tasks:
                out[name] = (tasks, conditional)

    for line in workflow.splitlines():
        m = re.match(r"^\s*- name: (.+?)\s*$", line)
        if m:
            flush()
            name, conditional, buf = m.group(1), False, []
            continue
        if re.match(r"^\s*- (uses|run):", line):
            flush()
            name, conditional, buf = None, False, []
            if line.lstrip().startswith("- run:"):
                continue
        if name is not None:
            if re.match(r"^\s+if:", line):
                conditional = True
            buf.append(line)
    flush()
    return out


def _dev_group(pyproject):
    m = re.search(r"^dev = \[(.*?)\]", pyproject, re.M | re.S)
    return re.findall(r'"([A-Za-z0-9_.-]+)', m.group(1)) if m else []


def analyse(src):
    """(rows, failures). `src` is a dict of raw texts plus a test index."""
    sheet = src["sheet"]
    if sheet is None:
        # NOT the early-return idiom check_wheel_platform_claims uses for a
        # README without an Install section: a missing sheet must be red, or
        # deleting the page is a green build.
        return [], ["docs/SPEC.md is missing — the spec sheet cannot be checked"]

    rows, failures = parse(sheet)
    pyproject, workflow = src["pyproject"], src["workflow"]
    steps = _steps(workflow)
    tasks_in_ci = {t for tasks, _ in steps.values() for t in tasks}
    smoke_bodies = _task_bodies(pyproject)
    reachable = _reachable(pyproject)
    dev = [re.sub(r"[^a-z0-9]", "", d.lower()) for d in _dev_group(pyproject)]
    cited_steps, cited_flags = set(), set()

    for row in rows:
        where = f"docs/SPEC.md row {row['capability']!r}"
        ev, status = row["evidence"], row["status"]
        cited_flags |= set(_FLAG.findall(ev))

        if status == "verified":
            m = _EVIDENCE.match(ev)
            if not m:
                failures.append(
                    f"{where}: `verified` evidence must read "
                    "``gate` (cadence)`, optionally followed by ` — note`. "
                    f"Got {ev!r}"
                )
                continue
            gate, cadence = m.group("gate"), m.group("cadence")
            if cadence not in CADENCES:
                failures.append(
                    f"{where}: unknown cadence {cadence!r} — must be one of "
                    + ", ".join(CADENCES)
                )
                continue

            unit = _UNIT.match(gate)
            if unit:
                # RULE 3. File-level evidence proves nothing (an empty
                # test_x.mojo passes), so the function must exist by name.
                fname, fn = unit.group("file"), unit.group("fn")
                index = src["tests"]
                if fname not in index:
                    failures.append(f"{where}: no packages/*/test/{fname} exists")
                elif fn not in index[fname]["fns"]:
                    failures.append(
                        f"{where}: {fname} has no `def {fn}(` — a renamed or "
                        "deleted test leaves the row claiming evidence that "
                        "no longer runs"
                    )
                else:
                    task = index[fname]["task"]
                    if task not in reachable:
                        failures.append(
                            f"{where}: {fname} is run by `poe {task}`, which is "
                            "not reachable from `poe test-all` — CI never runs it"
                        )
                if cadence != "every PR":
                    failures.append(
                        f"{where}: unit tests run inside `poe test-all` on every "
                        f"pull request; cadence {cadence!r} is wrong"
                    )
                continue

            # Otherwise the gate is a test.yml STEP NAME, not a task name.
            # RULE 2: `smoke-asgi` appears twice in test.yml (plain, and under
            # M0_INVERTED=1), so a task name cannot say which claim is meant.
            if gate in steps:
                cited_steps.add(gate)
                tasks, conditional = steps[gate]
                if cadence != "every PR":
                    failures.append(
                        f"{where}: `{gate}` is a step in test.yml, which runs on "
                        f"every pull request; cadence {cadence!r} is wrong"
                    )
                if conditional:
                    failures.append(
                        f"{where}: the step `{gate}` carries an `if:` in "
                        "test.yml, so it does not run on every pull request"
                    )
                # RULE 5. A gate that skips itself when a dependency is absent
                # is green-and-empty; the dependency has to be pinned somewhere.
                for task in tasks:
                    guard = _SKIP_GUARD.search(smoke_bodies.get(task, ""))
                    if guard:
                        mod = guard.group(1).lower()
                        if not any(mod in d for d in dev):
                            failures.append(
                                f"{where}: `poe {task}` exits 0 when `import "
                                f"{mod}` fails, and {mod!r} is not in "
                                "[dependency-groups] dev — the gate would go "
                                "green having tested nothing"
                            )
            elif cadence == "weekly":
                if gate not in src["canary"] and gate not in src["nightly"]:
                    failures.append(
                        f"{where}: cadence is `weekly` but `{gate}` appears in "
                        "neither py-canary.yml nor nightly-canary.yml"
                    )
            elif cadence == "pre-release":
                if gate not in src["releasing"]:
                    failures.append(
                        f"{where}: cadence is `pre-release` but `{gate}` is not "
                        "named in docs/RELEASING.md"
                    )
            else:
                failures.append(
                    f"{where}: `{gate}` is not a step in test.yml. `verified` "
                    "evidence must name a CI step, a test function, or a "
                    "weekly/pre-release gate."
                )

        elif status == "implemented":
            paths = [p for p in re.findall(r"`([^`]+)`", ev) if "/" in p]
            if not paths:
                failures.append(
                    f"{where}: `implemented` evidence must name a source file "
                    f"in backticks. Got {ev!r}"
                )
            for p in paths:
                if p.split(":")[0] not in src["sources"]:
                    failures.append(f"{where}: no such file {p.split(':')[0]!r}")

        elif status == "planned":
            m = re.match(r"^ROADMAP: (.+)$", ev)
            if not m:
                failures.append(
                    f"{where}: `planned` evidence must read `ROADMAP: <heading "
                    f"text>`. Got {ev!r}"
                )
            else:
                # Quoted heading TEXT, not a slug. ROADMAP's headings carry
                # backticks, em dashes, colons and parentheses, and every one
                # slugifies differently; a hand-rolled GitHub slugifier is
                # either falsely red or vacuously green.
                text = m.group(1)
                if f"### {text}" not in src["roadmap"] and f"## {text}" not in src["roadmap"]:
                    failures.append(
                        f"{where}: docs/ROADMAP.md has no heading {text!r}"
                    )

        elif status == "out of scope":
            if len(ev) < 20:
                failures.append(
                    f"{where}: `out of scope` must carry a reason, not "
                    f"{ev!r} — a refusal without one reads as an omission"
                )

    # RULE 6, the reverse direction, over two closed sets. Without it a sheet
    # can be complete-looking while omitting whatever is inconvenient.
    for gate, (tasks, _) in steps.items():
        if not any(t.startswith("smoke-") for t in tasks):
            continue
        if gate not in cited_steps:
            failures.append(
                f"test.yml step `{gate}` is cited by no row in docs/SPEC.md — "
                "a capability was gated and never recorded"
            )
    accepted = set(re.findall(r'name == "(--[a-z-]+)"', src["cli"]))
    for flag in sorted(accepted - cited_flags):
        failures.append(
            f"m0serve accepts `{flag}` and no row in docs/SPEC.md names it"
        )
    for flag in sorted(cited_flags - accepted):
        failures.append(
            f"docs/SPEC.md names `{flag}`, which cli.mojo does not accept"
        )
    return rows, failures


def render_rollup(rows):
    n = len(rows)
    by = {s: sum(1 for r in rows if r["status"] == s) for s in STATUSES}
    cad = {c: 0 for c in CADENCES}
    for r in rows:
        if r["status"] == "verified":
            m = _EVIDENCE.match(r["evidence"])
            if m and m.group("cadence") in cad:
                cad[m.group("cadence")] += 1
    return (
        f"{BEGIN}\n"
        f"**{n} capabilities: {by['verified']} verified, "
        f"{by['implemented']} implemented, {by['planned']} planned, "
        f"{by['out of scope']} out of scope.** Of the {by['verified']} "
        f"verified, {cad['every PR']} are gated on every pull request, "
        f"{cad['weekly']} weekly, and {cad['pre-release']} before a release.\n"
        f"{END}"
    )


def rewrite(sheet, rows):
    if sheet.count(BEGIN) != 1 or sheet.count(END) != 1:
        sys.exit("docs/SPEC.md must contain exactly one spec-rollup region")
    head, rest = sheet.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    return head + render_rollup(rows) + tail


def spec_json(rows):
    return json.dumps(
        {
            "note": "Generated from docs/SPEC.md by scripts/spec_sheet.py. "
                    "`verified` means a named CI gate exercises the capability "
                    "on the stated cadence, not that it is correct.",
            "capabilities": rows,
        },
        indent=2,
    ) + "\n"


def read_sources(**override):
    """Every text the checks need, with in-memory overrides for --sabotage."""
    def txt(rel):
        p = REPO / rel
        return p.read_text() if p.exists() else ""

    tests, sources = {}, set()
    for pkg in sorted((REPO / "packages").iterdir()):
        for f in sorted((pkg / "test").glob("test_*.mojo")) if (pkg / "test").is_dir() else []:
            name = pkg.name[3:]  # m0-http -> http
            task = f"test-{name}" if name != "sqlite" else "test-sqlite-mojo"
            tests[f.name] = {
                "task": task,
                "fns": {
                    m.group(1)
                    for m in re.finditer(r"^def (test_[a-z0-9_]+)\(", f.read_text(), re.M)
                },
            }
    for p in REPO.glob("packages/*/**/*.mojo"):
        sources.add(str(p.relative_to(REPO)))

    src = {
        "sheet": SHEET.read_text() if SHEET.exists() else None,
        "pyproject": txt("pyproject.toml"),
        "workflow": txt(".github/workflows/test.yml"),
        "roadmap": txt("docs/ROADMAP.md"),
        "releasing": txt("docs/RELEASING.md"),
        "canary": txt(".github/workflows/py-canary.yml"),
        "nightly": txt(".github/workflows/nightly-canary.yml"),
        "cli": txt("packages/m0-wsgi/src/cli.mojo"),
        "tests": tests,
        "sources": sources,
    }
    src.update(override)
    return src


_ROW_LINE = re.compile(
    r"^\| .+ \| (?:" + "|".join(STATUSES) + r") \| .+ \|$", re.M)


def _first_row(text):
    """The first capability row, found structurally rather than quoted.

    A sabotage that quotes a row verbatim breaks the moment that row is
    legitimately edited, and then reports NOT APPLICABLE -- correct for a rule
    that was removed, noise for one that merely needs "some row". The generic
    shape sabotages below therefore locate a row by its shape. (This is not a
    hypothetical tidy-up: a spot-audit re-pointed the row one of them quoted,
    and CI failed on the sabotage rather than on anything real.)
    """
    m = _ROW_LINE.search(text)
    return m.group(0) if m else None


def _mangle_first_row(fn):
    def patch(text):
        row = _first_row(text)
        return text.replace(row, fn(row), 1) if row else None
    return patch


def _first_section(text):
    m = re.search(r"^## [A-Z]\. .+$", text, re.M)
    return m.group(0) if m else None


# Each sabotage reverts ONE rule. `must` is asserted against the failure text,
# never against the exit code: check_docs.py's fourteen checks share one
# sys.exit(1), so "it went red" is not evidence that THIS rule bit.
SABOTAGES = [
    ("status word is not classified", "sheet",
     ("| Persistent connections (keep-alive) | verified |",
      "| Persistent connections (keep-alive) | Verified |"), "unknown status word"),
    ("verified row names a task that does not exist", "sheet",
     ("`Smoke test pipelined requests` (every PR)",
      "`Smoke test nothing at all` (every PR)"), "is not a step in test.yml"),
    ("cited step is reworded in the workflow", "workflow",
     ("- name: Smoke test pipelined requests",
      "- name: Smoke test pipelined requests, renamed"), "is not a step in test.yml"),
    ("unit-test file does not exist", "sheet",
     ("`test_parsing.mojo:test_chunked_body_decodes`",
      "`test_nosuch.mojo:test_chunked_body_decodes`"), "no packages/*/test/"),
    ("cited test function is deleted", "sheet",
     ("`test_parsing.mojo:test_chunked_body_decodes`",
      "`test_parsing.mojo:test_chunked_body_gone`"), "has no `def"),
    ("test package leaves the test-all sequence", "pyproject",
     ('"test-core", "test-http"', '"test-core"'), "not reachable from `poe test-all`"),
    # Deleting a row whose gate ANOTHER row also cites proves nothing -- the
    # rule is "cited by at least one". `Smoke test the HTTP client` is cited
    # exactly once, which is what makes it the honest sabotage here.
    ("a live CI gate is cited by no row", "sheet",
     ("| An HTTP client in Mojo, for server-to-server calls | verified | `Smoke test the HTTP client` (every PR) |\n", ""),
     "is cited by no row"),
    ("a new CLI flag is named by no row", "cli",
     ('name == "--metrics"', 'name == "--metrics"\n        or name == "--nitro"'),
     "and no row in docs/SPEC.md names it"),
    ("a row names a flag the CLI does not accept", "sheet",
     ("`--max-body`", "`--max-corpus`"), "which cli.mojo does not accept"),
    ("a self-skipping gate loses its dependency", "pyproject",
     ('"flask>=3.0",\n', ""), "is not in [dependency-groups] dev"),
    ("a cited step becomes conditional", "workflow",
     ("      - name: Smoke test pipelined requests\n",
      "      - name: Smoke test pipelined requests\n        if: runner.os == 'Linux'\n"),
     "carries an `if:`"),
    ("planned row points at no roadmap heading", "sheet",
     ("ROADMAP: A conformance-suite tier", "ROADMAP: A tier that is not there"),
     "has no heading"),
    ("out-of-scope row loses its reason", "sheet",
     ("| HTTP/2 | out of scope | terminate at a proxy — gunicorn's answer, and the same one applies here |",
      "| HTTP/2 | out of scope | none |"), "must carry a reason"),
    ("a row loses a cell", "sheet",
     _mangle_first_row(lambda r: "| " + " | ".join(split_cells(r)[:2]) + " |"),
     "must be exactly 3 cells"),
    ("a row gains a cell", "sheet",
     _mangle_first_row(lambda r: "| " + " | ".join(split_cells(r) + ["x"]) + " |"),
     "must be exactly 3 cells"),
    ("a row hides under a stray heading", "sheet",
     lambda text: text.replace(_first_section(text), "## Notes", 1)
     if _first_section(text) else None,
     "outside a capability section"),
    ("the sheet is deleted", "sheet", None, "docs/SPEC.md is missing"),
]


def run_sabotages():
    ok = True
    for label, key, patch, must in SABOTAGES:
        src = read_sources()
        if patch is None:
            src[key] = None
        elif callable(patch):
            edited = patch(src[key])
            if edited is None or edited == src[key]:
                print(f"  NOT APPLICABLE  {label}\n     nothing in {key} matched the shape to sabotage")
                ok = False
                continue
            src[key] = edited
        else:
            old, new = patch
            if old not in src[key]:
                print(f"  NOT APPLICABLE  {label}\n     patch no longer matches: {old!r}")
                ok = False
                continue
            src[key] = src[key].replace(old, new, 1)
        _, failures = analyse(src)
        if any(must in f for f in failures):
            print(f"  caught          {label}")
        else:
            print(f"  MISSED          {label}\n     expected a failure containing {must!r}")
            if failures:
                print("     got: " + "; ".join(failures[:3]))
            ok = False
    return ok


def main():
    args = sys.argv[1:]
    if "--sabotage" in args:
        print("spec_sheet: reverting each rule in turn")
        sys.exit(0 if run_sabotages() else 1)

    src = read_sources()
    rows, failures = analyse(src)
    if failures:
        print("spec-sheet: FAIL")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)

    new_sheet = rewrite(src["sheet"], rows)
    new_json = spec_json(rows)
    out = REPO / "docs" / "spec.json"
    current_json = out.read_text() if out.exists() else None
    if "--check" in args:
        if new_sheet != src["sheet"] or new_json != current_json:
            sys.exit(
                "docs/SPEC.md's rollup or docs/spec.json is stale — run: "
                "python3 scripts/spec_sheet.py"
            )
        print(f"spec-sheet: {len(rows)} rows, rollup and spec.json current")
        return
    SHEET.write_text(new_sheet)
    out.write_text(new_json)
    print(f"spec-sheet: rendered {len(rows)} rows into docs/SPEC.md and docs/spec.json")


if __name__ == "__main__":
    main()
