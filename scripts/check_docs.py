"""The doc-fact ratchet: prose numbers must match their machine sources.

    python3 scripts/check_docs.py        # exit 1 on any mismatch, naming it

Same philosophy as the warning ratchet: a fact with a machine-readable
source of truth is never trusted from prose. This exists because the drift
is not hypothetical — CLAUDE.md carried a warning count one off from
scripts/warning_baseline.json for weeks, and a smoke task shipped that CI
never ran because .github/workflows/test.yml lists tasks explicitly and
nothing checked the list.

Deliberately small. Only facts that are CURRENT and machine-derivable
belong here; historical numbers in narrative (old benchmark rows, version
mentions in dated sections) are records of what was measured, not claims
about the present, and a linter that flagged them would teach people to
ignore it. Benchmark freshness is delegated to render_bench_docs --check,
which compares the generated table against the newest committed artifact.

CI runs this via `uv run poe check-docs` on code changes. test.yml ignores
*.md, so a doc-only edit is not re-checked — acceptable, because drift is
caused by code moving, not by doc edits.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
failures = []


def fail(msg):
    failures.append(msg)


def check_warning_counts():
    """CLAUDE.md's warning-ratchet narrative vs scripts/warning_baseline.json."""
    baseline = json.loads((REPO / "scripts" / "warning_baseline.json").read_text())
    total = baseline["total"]
    docstring = next(
        (v for k, v in baseline["categories"].items() if "doc string" in k), 0
    )
    other = total - docstring

    text = (REPO / "CLAUDE.md").read_text()
    m = re.search(r"The (\d+) warnings the baseline records", text)
    if not m:
        return fail("CLAUDE.md: the warning-ratchet paragraph is gone or reworded")
    if int(m.group(1)) != total:
        fail(
            f"CLAUDE.md says the baseline records {m.group(1)} warnings;"
            f" warning_baseline.json says {total}"
        )
    m = re.search(r"(\d+) are doc-string", text)
    if m and int(m.group(1)) != docstring:
        fail(
            f"CLAUDE.md says {m.group(1)} are doc-string;"
            f" warning_baseline.json says {docstring}"
        )
    m = re.search(r"The other (\d+) warn", text)
    if m and int(m.group(1)) != other:
        fail(
            f"CLAUDE.md says 'the other {m.group(1)}';"
            f" warning_baseline.json implies {other}"
        )


def check_smoke_coverage():
    """Every smoke-* poe task must be run by .github/workflows/test.yml.

    The guard for the class of miss where a smoke exists, passes locally,
    and a green tick ships without ever running it (that happened; the
    task was smoke-sendfile).
    """
    tasks = set(
        re.findall(
            r"^\[tool\.poe\.tasks\.(smoke-[a-z0-9-]+)\]",
            (REPO / "pyproject.toml").read_text(),
            re.M,
        )
    )
    workflow = (REPO / ".github" / "workflows" / "test.yml").read_text()
    run = set(re.findall(r"poe (smoke-[a-z0-9-]+)", workflow))
    missing = sorted(tasks - run)
    if missing:
        fail(
            "smoke task(s) defined but never run by test.yml: "
            + ", ".join(missing)
        )
    ghosts = sorted(run - tasks)
    if ghosts:
        fail("test.yml runs smoke task(s) that do not exist: " + ", ".join(ghosts))


def check_bench_region():
    """The generated table must match the newest committed artifact."""
    results = REPO / "bench" / "results"
    if not results.exists() or not any(results.glob("layer-split-*.json")):
        return  # nothing to be stale against yet
    r = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "render_bench_docs.py"), "--check"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        fail((r.stdout + r.stderr).strip() or "render_bench_docs --check failed")


def main():
    check_warning_counts()
    check_smoke_coverage()
    check_bench_region()
    if failures:
        print("check-docs: FAIL")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("check-docs: every machine-sourced doc fact matches its source")


if __name__ == "__main__":
    main()
