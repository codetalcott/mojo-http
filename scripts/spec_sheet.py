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
in patching sources *in memory* and insisting the suite goes red for each.
Fourteen of the thirty-two sabotages mutate pyproject.toml, test.yml, cli.mojo,
the host's flags.mojo or the test index rather than the sheet, so every source
has to arrive as an argument. check_docs.py's coverage checks read test.yml and
the task table through the same two readers (`workflow_steps`, `poe_tasks`),
which see only what runs.

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

import functools
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


# --- What CI RUNS: the workflow's jobs and steps, and the task table -------
# Every coverage rule here and in check_docs.py asks one question -- does CI
# run this? -- of two texts, test.yml and pyproject.toml's task table, and a
# name in a comment is not an answer. All three readers took one for an
# answer (review H4): check_docs' smoke coverage scanned test.yml whole, its
# test coverage and this file's step reader let a step's body run on through
# the comment introducing the next step or the next JOB (the aarch64 wheel
# step "ran" `test-postgres-server`, which the postgres job's header comment
# names), and the task reader took `build-wsgi`, `smoke-asgi` and `smoke-host`
# for sequences because a comment in each says the word. check_docs.py reads
# both texts through these functions too, so there is one reading of each.
# They stay pure functions of text: `--sabotage` edits the texts in memory.

# A key line may end in a trailing comment; YAML allows one after the colon.
_EOL = r"[ \t]*(?:#.*)?$"


def strip_comment_lines(text):
    """`text` without its full-line comments.

    One rule covers every text these checks read. A line whose first
    non-blank character is `#` is a comment in YAML and in TOML, and inside
    a `run:` block or a task's shell body it is a shell comment (or a Python
    one, in a heredoc) -- executed by nobody either way. A trailing comment
    is left alone: a `#` after code may sit inside a quoted string, and
    stripping one there would lose the code before it rather than a name.
    """
    return "\n".join(
        line for line in text.split("\n") if not line.lstrip().startswith("#"))


def workflow_jobs(workflow):
    """Job id -> that job's text, comments stripped, in file order.

    A job is a two-space key under the top-level `jobs:`, and its text runs
    to the next one: header, `env:` and steps. Reading one job's own text is
    what lets a rule be asked per job, where one job's line cannot answer
    for another's (B16: the postgres job never rendered its measurements,
    and the whole-file check read six other jobs' renders as its).
    """
    text = strip_comment_lines(workflow)
    m = re.search(r"^jobs:" + _EOL, text, re.M)
    if not m:
        return {}
    rest = text[m.end():]
    end = re.search(r"^\S", rest, re.M)  # the next top-level key, if any
    if end:
        rest = rest[:end.start()]
    heads = list(re.finditer(r"^  ([A-Za-z_][A-Za-z0-9_-]*):" + _EOL, rest, re.M))
    return {
        h.group(1): rest[h.end():heads[i + 1].start() if i + 1 < len(heads) else len(rest)]
        for i, h in enumerate(heads)
    }


def job_steps(job):
    """(name or None, `if:` present, text) for each item of a job's `steps:`.

    The items of the list and nothing after it, so a step never runs on
    into the job's next key or into the next job. An item is a `- ` line at
    the list's own indentation; its keys are that line's and those one level
    in, which is where `name:` and `if:` count (an `if:` nested deeper, in a
    `with:` say, is not the step's). A step's text is its lines without its
    `name:` line -- a name is a label, not something the step runs.
    """
    lines = job.split("\n")
    start = next((i for i, line in enumerate(lines)
                  if re.match(r"^ *steps:" + _EOL, line)), None)
    if start is None:
        return []
    depth = len(lines[start]) - len(lines[start].lstrip(" "))
    items, indent = [], None
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip(" ")) <= depth:
            break
        m = re.match(r"^( *)- ", line)
        if m and (indent is None or len(m.group(1)) == indent):
            indent = len(m.group(1))
            items.append([line])
        elif items:
            items[-1].append(line)
    out = []
    for item in items:
        keys = [(0, item[0][indent + 2:])] + [
            (j, line[indent + 2:]) for j, line in enumerate(item[1:], 1)
            if line.startswith(" " * (indent + 2))
            and not line[indent + 2:].startswith(" ")
        ]
        name = next(((j, m.group(1)) for j, key in keys
                     for m in [re.match(r"name:[ \t]*(\S.*?)[ \t]*$", key)] if m),
                    None)
        conditional = any(re.match(r"if:", key) for _j, key in keys)
        text = "\n".join(line for j, line in enumerate(item)
                         if name is None or j != name[0])
        out.append((name[1] if name else None, conditional, text))
    return out


def workflow_steps(workflow):
    """test.yml step name -> (poe tasks it runs, `if:` present, body text).

    Every NAMED step is citable, not only those running a poe task: a row may
    legitimately point at `Self-test the measurement recorder`, which runs a
    plain `python3`, so `tasks` may be empty, which is what the smoke-specific
    rules key off. A step with no name contributes nothing to cite. The body
    is what the coverage rules read `--covers` declarations out of, for the
    rows whose cited step runs a bare `python3` rather than a poe task. Read
    job by job and without comments; see the note above.
    """
    out = {}
    for job in workflow_jobs(workflow).values():
        for name, conditional, body in job_steps(job):
            if name and body.strip():
                out[name] = (set(re.findall(r"poe ([a-z0-9-]+)", body)),
                             conditional, body)
    return out


@functools.lru_cache(maxsize=8)
def _toml(text):
    """The parsed text, cached: several rules read one pyproject per run."""
    import tomllib  # Python 3.11+, the docs gate's floor (scripts/docs_gate.sh)

    return tomllib.loads(text)


_CODE_KEYS = ("shell", "cmd", "script", "expr")


def poe_tasks(pyproject):
    """poe task name -> (what it executes, the tasks it runs by name).

    Read as TOML, which is how poe reads it: a comment outside a string is
    gone by construction, a `help` string is not a command, and a sequence
    is its list rather than every quoted word in a block that says the word.
    Inside a body, comment lines are stripped as everywhere else. The names
    are a sequence's items (a bare string is a reference, poe's default for
    `default_item_type`), a `ref`, and `deps`, which poe runs first. The
    parse is the one poe does, so a text that is not TOML raises ValueError
    rather than being read around.
    """
    try:
        data = _toml(pyproject)
    except Exception as e:  # tomllib.TOMLDecodeError, and nothing else
        raise ValueError(f"pyproject.toml does not parse as TOML: {e}") from None
    poe = data.get("tool", {}).get("poe", {})
    default_item = poe.get("default_array_item_task_type", "ref")
    out = {}
    for name, spec in poe.get("tasks", {}).items():
        if isinstance(spec, list):
            spec = {"sequence": spec}
        elif not isinstance(spec, dict):
            spec = {"cmd": spec}
        code = [spec[k] for k in _CODE_KEYS if isinstance(spec.get(k), str)]
        refs = [spec["ref"]] if isinstance(spec.get("ref"), str) else []
        item_type = spec.get("default_item_type", default_item)
        for item in spec.get("sequence") or []:
            if isinstance(item, str) and item_type == "ref":
                refs.append(item)
            elif isinstance(item, str):
                code.append(item)
            elif isinstance(item, dict):
                code += [item[k] for k in _CODE_KEYS if isinstance(item.get(k), str)]
                if isinstance(item.get("ref"), str):
                    refs.append(item["ref"])
        refs += [d for d in spec.get("deps") or [] if isinstance(d, str)]
        out[name] = (strip_comment_lines("\n".join(code)),
                     [r.split()[0] for r in refs if r.split()])
    return out


def reachable_tasks(tasks, *roots):
    """Every task `roots` run: themselves, and their sequences and deps."""
    seen, queue = set(), list(roots)
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        queue.extend(tasks.get(name, ("", []))[1])
    return seen


def _dev_group(pyproject):
    """The `dev` dependency group's package names, read as TOML -- so a name
    in a comment inside the list is not a dependency (review H4). The regex
    this replaced listed `server`, from a comment quoting "server never
    became healthy"; a gate skipping on `import server` would have passed."""
    try:
        group = _toml(pyproject).get("dependency-groups", {}).get("dev", [])
    except Exception:
        return []
    return [m.group(0) for d in group if isinstance(d, str)
            for m in [re.match(r"[A-Za-z0-9_.-]+", d)] if m]


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
    try:
        table = poe_tasks(pyproject)
    except ValueError as e:
        # Every rule below reads the task table; poe could not run a task
        # either, so this is the failure, not one of many downstream of it.
        return rows, failures + [str(e)]
    steps = workflow_steps(workflow)
    smoke_bodies = {n: body for n, (body, _r) in table.items()
                    if n.startswith("smoke-")}
    reachable = reachable_tasks(table, "test-all")
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
    # The Mojo host has a command line of its own (`m0_host/flags.mojo`), a
    # second closed set held to the same two directions. Most of its flags
    # are m0serve's by name, so a row naming one covers both; the ones that
    # are the host's alone are what this adds.
    hosted = set(re.findall(r'name == "(--[a-z-]+)"', src["host_flags"]))
    for flag in sorted(hosted - cited_flags):
        failures.append(
            f"the Mojo host accepts `{flag}` and no row in docs/SPEC.md names it"
        )
    for flag in sorted(cited_flags - accepted - hosted):
        failures.append(
            f"docs/SPEC.md names `{flag}`, which cli.mojo does not accept"
            " (nor m0_host/flags.mojo)"
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
    for task, (body, _refs) in sorted(table.items()):
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
        "host_flags": txt("packages/m0-http/m0_host/flags.mojo"),
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


def _drop_a_sole_covers_line(text):
    """Delete a coverage call for a row NO other task declares.

    The first one, which this used to take, stops discriminating the moment
    any row is legitimately declared twice: deleting one of two leaves the
    row declared, the checker stays quiet, and the sabotage reports MISSED
    for a rule that is working. (I22 is declared by both the notify smoke
    and the wheel smoke, which is what found this.) Picking a sole
    declaration keeps the sabotage testing what it names.
    """
    return _edit_a_sole_covers_line(text, lambda line: [])


def _comment_out_a_sole_covers_line(text):
    """The same declaration, commented out rather than deleted.

    How a declaration is really switched off, and what the task reader used
    to miss: it read a task's raw block, so `# python3 scripts/emit.py
    --covers X` still declared X (review H4).
    """
    return _edit_a_sole_covers_line(text, lambda line: ["# " + line])


def _edit_a_sole_covers_line(text, edit):
    lines = text.split("\n")
    counts = {}
    for line in lines:
        m = re.match(r"^python3 scripts/emit\.py --covers ([A-Z]\d+)", line)
        if m:
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    for i, line in enumerate(lines):
        m = re.match(r"^python3 scripts/emit\.py --covers ([A-Z]\d+)", line)
        if m and counts[m.group(1)] == 1:
            return "\n".join(lines[:i] + edit(line) + lines[i + 1:])
    return None


def _test_all_member_in_a_comment(text):
    """`test-http` out of test-all's sequence, still quoted in a comment.

    The old reader called any task block holding the word `sequence` a
    sequence and took every quoted word in the block for a member, comments
    included, so the package stayed "reachable" and its rows stayed green.
    """
    old = '"test-core", "test-http"'
    if old not in text:
        return None
    at = text.index(old)
    eol = text.index("\n", at)
    return (text[:at] + '"test-core"' + text[at + len(old):eol]
            + '\n# "test-http" is out of the sequence while it is reworked'
            + text[eol:])


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


def _every_pr_citations(sheet):
    """(unit, steps) for the sheet's `verified (every PR)` rows: `unit` holds
    (file, fn, id) for each row citing a test function, `steps` the ids of
    the rows citing a test.yml step, in sheet order."""
    unit, steps = set(), []
    for r in parse(sheet)[0]:
        m = _EVIDENCE.match(r["evidence"]) if r["status"] == "verified" else None
        if not m or m.group("cadence") != "every PR":
            continue
        u = _UNIT.match(m.group("gate"))
        if u:
            unit.add((u.group("file"), u.group("fn"), r["id"]))
        else:
            steps.append(r["id"])
    return unit, steps


def _misplace_unit_covers(idx, sheet):
    """Move one CITED unit declaration to a function nothing cites.

    The id stays declared (so the no-gate-declares arm stays quiet) but no
    longer at the cited site — RULE 11's disagreement arm is the only rule
    that can notice. Which declaration moves is the whole of it. This used
    to take the first one in the first file that had any, and one there can
    be extra coverage of a row that cites a STEP (#426 put `covers: E16` in
    test_accept_share.mojo, which sorts first): moved, it disagrees with
    nothing, so the arm rightly stayed quiet and the sabotage reported
    MISSED for a working rule. So the one moved is one a unit-cited row
    names, and a declaration of the other kind is planted first, where the
    old choice landed -- the first file's first function -- so a choice that
    regresses is MISSED here, not on the day the tree next grows such a line.
    """
    unit, steps = _every_pr_citations(sheet)
    if not idx or not steps:
        return None
    first = sorted(idx)[0]
    idx = {**idx, first: {**idx[first], "covers": {
        **idx[first].get("covers", {}),
        "test_0_extra_coverage_planted_by_sabotage": {steps[0]}}}}
    for f, info in sorted(idx.items()):
        for fn, ids in sorted(info.get("covers", {}).items()):
            for rid in sorted(ids):
                if (f, fn, rid) not in unit:
                    continue
                moved = {k: v for k, v in info["covers"].items() if k != fn}
                if ids - {rid}:
                    moved[fn] = ids - {rid}
                moved[fn + "_moved_by_sabotage"] = {rid}
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
    # The comment-blind twins of rules above (review H4): each lapse leaves
    # the name it removed in a comment, which the old readers counted.
    ("a test package leaves test-all, named only in a comment", "pyproject",
     _test_all_member_in_a_comment, "not reachable from `poe test-all`"),
    # Deleting a row whose gate ANOTHER row also cites proves nothing -- the
    # rule is "cited by at least one" -- so this deletes a SINGLY-cited one,
    # found by counting rather than by quoting a row that reword would break.
    ("a live CI gate is cited by no row", "sheet",
     lambda t: _delete_a_singly_cited_row(t), "is cited by no row"),
    ("a new CLI flag is named by no row", "cli",
     ('name == "--metrics"', 'name == "--metrics"\n        or name == "--nitro"'),
     "and no row in docs/SPEC.md names it"),
    ("a new Mojo-host flag is named by no row", "host_flags",
     ('name == "--qos"', 'name == "--qos"\n        or name == "--nitro"'),
     "the Mojo host accepts `--nitro` and no row"),
    ("a row names a flag the CLI does not accept", "sheet",
     ("`--max-body`", "`--max-corpus`"), "which cli.mojo does not accept"),
    ("a self-skipping gate loses its dependency", "pyproject",
     ('"flask>=3.0",\n', ""), "is not in [dependency-groups] dev"),
    ("a self-skipping gate's dependency survives only in a comment", "pyproject",
     ('"flask>=3.0",\n', '# "flask>=3.0",\n'), "is not in [dependency-groups] dev"),
    ("a cited step becomes conditional", "workflow",
     ("      - name: Smoke test pipelined requests\n",
      "      - name: Smoke test pipelined requests\n        if: runner.os == 'Linux'\n"),
     "carries an `if:`"),
    # A smoke named only in a comment is not run, so the row citing its step
    # is uncovered: the declaration in the smoke no longer sits in anything
    # the step runs.
    ("a cited smoke step names its smoke only in a comment", "workflow",
     ("      - name: Smoke test pipelined requests\n"
      "        run: uv run poe smoke-pipelining\n",
      "      - name: Smoke test pipelined requests\n"
      "        # run: uv run poe smoke-pipelining\n"
      "        run: echo skipped\n"),
     "the citation and the declaration disagree"),
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
    # Edits the test index; reads the sheet to learn which declarations a
    # row cites (a tuple key: the patch edits the first, reads the rest).
    ("a declaration sits in a different test than the row cites", ("tests", "sheet"),
     _misplace_unit_covers, "the citation and the declaration disagree"),
    ("every unit gate's declarations are deleted", "tests",
     lambda idx: {f: {**info, "covers": {}} for f, info in idx.items()},
     "no gate declares"),
    ("a smoke's declaration line is deleted", "pyproject",
     _drop_a_sole_covers_line, "no gate declares"),
    ("a smoke's declaration line is commented out", "pyproject",
     _comment_out_a_sole_covers_line, "no gate declares"),
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
        key, *reads = key if isinstance(key, tuple) else (key,)
        if patch is None:
            src[key] = None
        elif callable(patch):
            edited = patch(src[key], *(src[r] for r in reads))
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
