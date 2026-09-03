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
in patching sources *in memory* and insisting the suite goes red for each. Nine
of the twenty-five sabotages mutate pyproject.toml, test.yml, cli.mojo or the
test index rather than the sheet, so every source has to arrive as an argument.

Coverage is DECLARED by the gate, not merely cited by the sheet (SPEC F12;
docs/notes/traceability.md, phase 2): every `verified (every PR)` row must be
declared — a `covers: A7` line in the cited test's docstring, or a
`scripts/emit.py --covers A7` call in what the cited step runs — and the
declaration must AGREE with the citation. The citation-shape rules stay,
because they guard properties a declaration cannot: the cadence is real, the
step is unconditional, and the two closed sets (every smoke step cited, every
CLI flag named) hold in both directions. Weekly and pre-release rows keep
declared-static citations; their runs are absent from PR CI, so a recorder
call there would record nothing anyone checks.

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
CADENCES = ("every PR", "weekly", "monthly", "pre-release")
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
    rows, failures, section, ids = [], [], None, set()
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
        if cells == ["id", "capability", "status", "evidence"]:
            continue
        if len(cells) != 4:
            failures.append(
                f"docs/SPEC.md:{n}: a capability row must be exactly 4 cells "
                f"(id, capability, status, evidence), got {len(cells)}: "
                f"{line.strip()!r}"
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
        rid, capability, status, evidence = cells
        # Ids are the stable handle: prose is meant to be edited freely, and
        # anything that refers to a row from outside this file -- a sabotage, a
        # commit message, an issue -- has to survive that. Assigned once, never
        # renumbered, and never reused: a deleted row's id is retired, so an id
        # in an old commit still means what it meant. Reuse is the one rule not
        # enforced here; checking it needs a ledger of retired ids, which is a
        # second source of truth to keep in step. It is written down instead.
        if not re.fullmatch(r"[A-Z]\d+", rid):
            failures.append(
                f"docs/SPEC.md:{n}: {rid!r} is not a row id — expected a "
                "section letter followed by a number, like `A7`"
            )
            continue
        if rid[0] != cat.group(1):
            failures.append(
                f"docs/SPEC.md:{n}: row {rid} sits in section "
                f"{cat.group(1)}; its id must start with that letter"
            )
            continue
        if rid in ids:
            failures.append(
                f"docs/SPEC.md:{n}: row id {rid} is used twice — ids are "
                "permanent handles and must be unique"
            )
            continue
        ids.add(rid)
        if status not in STATUSES:
            failures.append(
                f"docs/SPEC.md:{n}: unknown status word {status!r} — must be "
                f"exactly one of {', '.join(STATUSES)}. An unrecognised status "
                f"would otherwise skip every rule below it."
            )
            continue
        rows.append(
            {
                "id": rid,
                "section": cat.group(1),
                "category": section,
                "capability": capability,
                "status": status,
                "evidence": evidence,
            }
        )
    return rows, failures


def _covers_by_fn(text):
    """fn -> row ids declared by `covers:` lines inside that test function.

    The F12 direction (docs/notes/traceability.md): the gate declares
    what it covers, next to the assertion, written by the person who knows
    what was asserted. The convention is a `covers: A7` line (ids may be
    comma-separated) in the test's docstring; the scan takes the whole
    function slice rather than parsing docstring syntax, because greppable
    is the property the convention promises.
    """
    out = {}
    defs = list(re.finditer(r"^def (test_[a-z0-9_]+)\(", text, re.M))
    for i, m in enumerate(defs):
        end = defs[i + 1].start() if i + 1 < len(defs) else len(text)
        ids = set()
        for c in re.finditer(r"^\s*covers: ([A-Z]\d+(?:\s*,\s*[A-Z]\d+)*)\s*$",
                             text[m.end():end], re.M):
            ids |= {x.strip() for x in c.group(1).split(",")}
        if ids:
            out[m.group(1)] = ids
    return out


def _all_task_bodies(pyproject):
    """EVERY poe task's raw block text, not only the smoke-* ones.

    `_task_bodies` stays smoke-scoped for the rules that are about smoke
    shape; coverage declarations may sit in any task a cited step runs
    (`fuzz-request`, `sabotage-trailers`, `test-shim` are all cited).
    """
    out = {}
    for name, body in re.findall(
        r"^\[tool\.poe\.tasks\.([a-z0-9-]+)\]$(.*?)(?=^\[tool\.poe\.tasks\.)",
        pyproject + "\n[tool.poe.tasks.__end__]\n",
        re.M | re.S,
    ):
        out[name] = body
    return out


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
    """test.yml step name -> (poe tasks it runs, `if:` present, body text).

    Steps are `- name: X` followed by `run:`; a step with no name (there is one,
    in the aarch64 job) simply contributes nothing to cite. The body text is
    what the coverage rules read `--covers` declarations out of, for the rows
    whose cited step runs a bare `python3` rather than a poe task.
    """
    out, name, conditional, buf = {}, None, False, []

    def flush():
        # Every NAMED step is citable, not only those running a poe task: a row
        # may legitimately point at `Self-test the measurement recorder`, which
        # runs a plain `python3`. `tasks` stays possibly-empty, which is what
        # the smoke-specific rules below key off.
        if name and buf:
            body = "\n".join(buf)
            tasks = set(re.findall(r"poe ([a-z0-9-]+)", body))
            out[name] = (tasks, conditional, body)

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
    tasks_in_ci = {t for tasks, _, _ in steps.values() for t in tasks}
    smoke_bodies = _task_bodies(pyproject)
    reachable = _reachable(pyproject)
    dev = [re.sub(r"[^a-z0-9]", "", d.lower()) for d in _dev_group(pyproject)]
    cited_steps, cited_flags = set(), set()
    # (id, where, kind, key) for every `verified (every PR)` row — the rows
    # RULE 10/11 below hold to declared coverage. Weekly and pre-release rows
    # keep declared-static citations: their runs are absent from PR CI, so a
    # `--covers` there would record nothing anyone checks.
    gated = []

    for row in rows:
        where = f"docs/SPEC.md {row['id']} ({row['capability']!r})"
        ev, status = row["evidence"], row["status"]
        # The whole row, not just the evidence cell: a row may name its flag
        # in the capability ('`--access-log` toggle') and carry a source path
        # as evidence. Scanning only the evidence cell made the reverse flag
        # check fire on a correctly-written `implemented` row.
        cited_flags |= set(_FLAG.findall(row['capability'] + ' ' + ev))

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
                else:
                    gated.append((row["id"], where, "unit", (fname, fn)))
                continue

            # Otherwise the gate is a test.yml STEP NAME, not a task name.
            # RULE 2: `smoke-asgi` appears twice in test.yml (plain, and under
            # M0_INVERTED=1), so a task name cannot say which claim is meant.
            if gate in steps:
                cited_steps.add(gate)
                tasks, conditional, _body = steps[gate]
                if cadence == "every PR":
                    gated.append((row["id"], where, "step", gate))
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
            elif cadence == "monthly":
                if gate not in src["citations"]:
                    failures.append(
                        f"{where}: cadence is `monthly` but `{gate}` does not "
                        "appear in citations.yml"
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
                    "weekly, monthly or pre-release gate."
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
            # A floor, not a judgement: this catches an empty or one-word cell,
            # and cannot tell a good reason from a plausible-looking one. That
            # is review's job and is stated on the page.
            if len(ev) < 20 or len(ev.split()) < 4:
                failures.append(
                    f"{where}: `out of scope` must carry a reason in words, not "
                    f"{ev!r} — a refusal without one reads as an omission"
                )

    # A duplicated capability inflates every count in the rollup and reads, to
    # anyone scanning, as two independent pieces of evidence. Cheap to add and
    # the kind of thing a 140-row hand-written table grows on its own.
    seen = {}
    for row in rows:
        key = row["capability"].strip().lower()
        if key in seen:
            failures.append(
                f"docs/SPEC.md lists {row['capability']!r} twice ({seen[key]} "
                f"and {row['id']}) — a duplicate inflates the rollup "
                "and reads as two separate pieces of evidence"
            )
        seen[key] = row["id"]

    # RULE 6, the reverse direction, over two closed sets. Without it a sheet
    # can be complete-looking while omitting whatever is inconvenient.
    for gate, (tasks, _, _) in steps.items():
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

    # --- Declared coverage (SPEC F12; docs/notes/traceability.md, phase 2) -----
    # The gate declares what it covers, next to the assertion: a
    # `covers: A7` line in a Mojo test's docstring, or a
    # `scripts/emit.py --covers A7` call in the task body (or bare `run:`
    # block) the cited step executes. The declaration is what the person who
    # wrote the assertion says it proves; the citation is what the sheet
    # says. RULE 11 requires them to AGREE, which is what makes the audit's
    # defect class — a row citing a gate that asserts something else —
    # structurally impossible for every-PR rows.
    declared = {}  # id -> [site, ...]

    for fname, info in sorted(src["tests"].items()):
        for fn, ids in sorted(info.get("covers", {}).items()):
            for rid in ids:
                declared.setdefault(rid, []).append(("unit", fname, fn))
    for task, body in sorted(_all_task_bodies(pyproject).items()):
        for m in re.finditer(r"emit\.py --covers ([A-Z]\d+)", body):
            declared.setdefault(m.group(1), []).append(("task", task))
    for step, (_tasks, _cond, body) in sorted(steps.items()):
        for m in re.finditer(r"emit\.py --covers ([A-Z]\d+)", body):
            declared.setdefault(m.group(1), []).append(("workflow", step))

    # RULE 10: a declared id must name a row that exists. A `covers:` line
    # left pointing at a retired or mistyped id is a claim about nothing.
    row_ids = {r["id"] for r in rows}
    for rid in sorted(declared):
        if rid not in row_ids:
            site = declared[rid][0]
            failures.append(
                f"{'/'.join(site[1:])} declares coverage of {rid}, and no row "
                f"carries that id — a retired or mistyped id"
            )

    # RULE 11: every `verified (every PR)` row is declared, BY its cited
    # gate. Declared elsewhere too is fine (extra coverage); declared ONLY
    # elsewhere means the citation and the declaration disagree, which is
    # the mis-citation the 2026-08-30 audit spent its time on.
    for rid, where, kind, key in gated:
        sites = declared.get(rid, [])
        if not sites:
            failures.append(
                f"{where}: verified on every PR, but no gate declares "
                f"`covers: {rid}` — coverage is asserted by the sheet alone"
            )
            continue
        if kind == "unit":
            if ("unit", key[0], key[1]) not in sites:
                failures.append(
                    f"{where}: the evidence cites {key[0]}:{key[1]}, but "
                    f"{rid}'s coverage is declared at "
                    f"{', '.join('/'.join(s[1:]) for s in sites)} — the "
                    f"citation and the declaration disagree"
                )
        else:
            step_tasks = steps.get(key, (set(), False, ""))[0]
            agrees = any(
                (s[0] == "task" and s[1] in step_tasks)
                or (s[0] == "workflow" and s[1] == key)
                for s in sites
            )
            if not agrees:
                failures.append(
                    f"{where}: the evidence cites the step `{key}`, but no "
                    f"`--covers {rid}` call sits in anything that step runs "
                    f"(declared at "
                    f"{', '.join('/'.join(s[1:]) for s in sites)}) — the "
                    f"citation and the declaration disagree"
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
        f"{cad['weekly']} weekly, {cad['monthly']} monthly, and "
        f"{cad['pre-release']} before a release. "
        f"Every pull-request-gated row's coverage is declared IN its gate "
        f"(`covers:` in the cited test, or a recorder coverage call in "
        f"what the cited step runs), and the checker requires the "
        f"declaration and the citation to agree; the weekly, monthly and "
        f"pre-release rows keep declared-static citations, their runs "
        f"being absent from PR CI.\n"
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
            text = f.read_text()
            tests[f.name] = {
                "task": task,
                "fns": {
                    m.group(1)
                    for m in re.finditer(r"^def (test_[a-z0-9_]+)\(", text, re.M)
                },
                "covers": _covers_by_fn(text),
            }
    # Every tracked file, not just packages/**/*.mojo: an `implemented` row may
    # legitimately cite a script, a workflow or a Python module, and rejecting
    # those as "no such file" would push the row into a wrong shape.
    for d in ("packages", "scripts", "apps", ".github"):
        for f in (REPO / d).rglob("*"):
            if f.is_file():
                sources.add(str(f.relative_to(REPO)))

    src = {
        "sheet": SHEET.read_text() if SHEET.exists() else None,
        "pyproject": txt("pyproject.toml"),
        "workflow": txt(".github/workflows/test.yml"),
        "roadmap": txt("docs/ROADMAP.md"),
        "releasing": txt("docs/RELEASING.md"),
        "canary": txt(".github/workflows/py-canary.yml"),
        "nightly": txt(".github/workflows/nightly-canary.yml"),
        "citations": txt(".github/workflows/citations.yml"),
        "cli": txt("packages/m0-wsgi/src/cli.mojo"),
        "tests": tests,
        "sources": sources,
    }
    src.update(override)
    return src


_ROW_LINE = re.compile(
    r"^\| [A-Z]\d+ \| .+ \| (?:" + "|".join(STATUSES) + r") \| .+ \|$", re.M)


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


def _delete_a_singly_cited_row(text):
    """Remove a row whose gate no other row cites, so the reverse rule bites."""
    rows = _ROW_LINE.findall(text)
    gates = {}
    for r in rows:
        m = re.search(r"`([^`]+)`", split_cells(r)[3])
        if m:
            gates.setdefault(m.group(1), []).append(r)
    for gate, rs in gates.items():
        if len(rs) == 1 and not gate.endswith(".mojo") and ".mojo:" not in gate:
            return text.replace(rs[0] + "\n", "", 1)
    return None


def _row_by_id(text, rid):
    """One row line, addressed by its permanent id rather than its prose."""
    m = re.search(r"^\| " + re.escape(rid) + r" \|.*$", text, re.M)
    return m.group(0) if m else None


def _first_status_row(text, status):
    m = re.search(r"^\| [A-Z]\d+ \| .+ \| " + re.escape(status) + r" \| .+ \|$",
                  text, re.M)
    return m.group(0) if m else None


def _first_unit_row(text):
    """The first row whose evidence is a `test_x.mojo:test_fn` citation."""
    m = re.search(r"`(test_[a-z0-9_]+\.mojo):(test_[a-z0-9_]+)`", text)
    return m.group(0) if m else None


def _first_section(text):
    m = re.search(r"^## [A-Z]\. .+$", text, re.M)
    return m.group(0) if m else None


def _misplace_unit_covers(idx):
    """Move one unit declaration to a function nothing cites.

    The id stays declared (so the no-gate-declares arm stays quiet) but no
    longer at the cited site — RULE 11's disagreement arm is the only rule
    that can notice.
    """
    for f, info in sorted(idx.items()):
        cov = info.get("covers") or {}
        if cov:
            fn, ids = sorted(cov.items())[0]
            moved = {k: v for k, v in cov.items() if k != fn}
            moved[fn + "_moved_by_sabotage"] = ids
            return {**idx, f: {**info, "covers": moved}}
    return None


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
    # These two test the unit-evidence rules, which need SOME unit citation and
    # not a particular one -- so they locate it by shape. Quoting a row broke
    # both the first time an audit legitimately re-pointed the test they named.
    ("unit-test file does not exist", "sheet",
     lambda t: (t.replace(_first_unit_row(t),
                          "`test_nosuchfile.mojo:" + _first_unit_row(t).split(":")[1], 1)
                if _first_unit_row(t) else None), "no packages/*/test/"),
    ("cited test function is deleted", "sheet",
     lambda t: (t.replace(_first_unit_row(t),
                          _first_unit_row(t).split(":")[0] + ":test_deleted_by_sabotage`", 1)
                if _first_unit_row(t) else None), "has no `def"),
    ("test package leaves the test-all sequence", "pyproject",
     ('"test-core", "test-http"', '"test-core"'), "not reachable from `poe test-all`"),
    # Deleting a row whose gate ANOTHER row also cites proves nothing -- the
    # rule is "cited by at least one" -- so this deletes a SINGLY-cited one,
    # found by counting rather than by quoting a row that reword would break.
    ("a live CI gate is cited by no row", "sheet",
     lambda t: _delete_a_singly_cited_row(t), "is cited by no row"),
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
    # Inserts its own planned row rather than re-pointing an existing one:
    # quoting a real row's heading broke when I13 was legitimately resolved
    # (CI's own catch, 2026-09-01), and locating "the first planned row"
    # stops working the day the last planned row is resolved — which is a
    # milestone, not an edge case. A fresh id in the first section trips
    # only the rule under test.
    ("planned row points at no roadmap heading", "sheet",
     lambda t: (t.replace(_first_row(t), _first_row(t) +
                "\n| A99 | a planned capability inserted by the sabotage | "
                "planned | ROADMAP: A tier that is not there |", 1)
                if _first_row(t) else None),
     "has no heading"),
    ("out-of-scope row loses its reason", "sheet",
     lambda t: (t.replace(_first_status_row(t, "out of scope"),
                          " | ".join(split_cells(_first_status_row(t, "out of scope"))[:3]
                                     ).join(["| ", " | none |"]), 1)
                if _first_status_row(t, "out of scope") else None),
     "must carry a reason"),
    ("a row id is malformed", "sheet",
     _mangle_first_row(lambda r: "| ZZ " + r[r.index("|", 1):]), "is not a row id"),
    ("a row id contradicts its section", "sheet",
     _mangle_first_row(lambda r: "| Z9 " + r[r.index("|", 1):]),
     "its id must start with that letter"),
    ("a row id is used twice", "sheet",
     lambda t: (t.replace(_first_row(t), _first_row(t) + "\n"
                          + _first_row(t).replace(
                              split_cells(_first_row(t))[1], "a different capability", 1), 1)
                if _first_row(t) else None), "is used twice"),
    ("a row loses a cell", "sheet",
     _mangle_first_row(lambda r: "| " + " | ".join(split_cells(r)[:2]) + " |"),
     "must be exactly 4 cells"),
    ("a row gains a cell", "sheet",
     _mangle_first_row(lambda r: "| " + " | ".join(split_cells(r) + ["x"]) + " |"),
     "must be exactly 4 cells"),
    ("a row hides under a stray heading", "sheet",
     lambda text: text.replace(_first_section(text), "## Notes", 1)
     if _first_section(text) else None,
     "outside a capability section"),
    ("a capability row is duplicated", "sheet",
     lambda t: (t.replace(_first_row(t), _first_row(t) + "\n" + _first_row(t), 1)
                if _first_row(t) else None), "is used twice"),
    # The declared-coverage rules (F12). Generic over WHICH declaration, for
    # the same reason the unit-evidence sabotages locate by shape: quoting a
    # particular test or id breaks the day it is legitimately reworked.
    ("a gate declares coverage of a retired id", "tests",
     lambda idx: (lambda f=sorted(idx)[0]: {
         **idx, f: {**idx[f], "covers": {
             **idx[f].get("covers", {}), "test_injected_by_sabotage": {"Z9"}}}
     })(), "no row carries that id"),
    ("a declaration sits in a different test than the row cites", "tests",
     _misplace_unit_covers, "the citation and the declaration disagree"),
    ("every unit gate's declarations are deleted", "tests",
     lambda idx: {f: {**info, "covers": {}} for f, info in idx.items()},
     "no gate declares"),
    ("a smoke's declaration line is deleted", "pyproject",
     lambda t: re.sub(r"^python3 scripts/emit\.py --covers [A-Z]\d+[^\n]*\n",
                      "", t, count=1, flags=re.M),
     "no gate declares"),
    ("a weekly row names a gate no weekly workflow runs", "sheet",
     lambda t: (lambda m: t.replace(m.group(0), "`no-such-gate` (weekly)", 1) if m else None)(
         re.search(r"`[^`]+` \(weekly\)", t)),
     "appears in neither"),
    ("a monthly row names a gate citations.yml does not run", "sheet",
     lambda t: (lambda m: t.replace(m.group(0), "`no-such-gate` (monthly)", 1) if m else None)(
         re.search(r"`[^`]+` \(monthly\)", t)),
     "does not appear in citations.yml"),
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
