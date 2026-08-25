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


def check_version_single_source():
    """The version lives in exactly two places, and the wheel adds no third.

    docs/RELEASING.md's rule is that `version` in pyproject.toml and
    M0SERVE_VERSION in cli.mojo are the only copies. `poe smoke-serve` already
    cross-checks them, but only after a successful compile -- this catches the
    drift in seconds, and more importantly it catches the case smoke-serve
    cannot see: a literal `version` creeping into the wheel's own metadata.
    A drifted version that reaches PyPI is not correctable; the filename is
    burned permanently, even after a delete.
    """
    declared = re.search(
        r'^version = "([^"]+)"', (REPO / "pyproject.toml").read_text(), re.M
    )
    cli = re.search(
        r'comptime M0SERVE_VERSION = "([^"]+)"',
        (REPO / "packages" / "m0-wsgi" / "src" / "cli.mojo").read_text(),
    )
    if not declared or not cli:
        fail("could not read the version from pyproject.toml and/or cli.mojo")
        return
    if declared.group(1) != cli.group(1):
        fail(
            f"version drift: pyproject.toml says {declared.group(1)!r} but "
            f"cli.mojo's M0SERVE_VERSION says {cli.group(1)!r}"
        )

    wheel_pyproject = REPO / "packaging" / "m0serve" / "pyproject.toml"
    if wheel_pyproject.exists():
        text = wheel_pyproject.read_text()
        if re.search(r"^version = ", text, re.M):
            fail(
                f"{wheel_pyproject.relative_to(REPO)} declares a literal version — "
                "that is a third copy. It must stay `dynamic = [\"version\"]` and "
                "derive from the repository root."
            )
        if 'dynamic = ["version"]' not in text:
            fail(
                f"{wheel_pyproject.relative_to(REPO)} no longer derives its "
                "version from the repository root"
            )


def check_wheel_platform_claims():
    """The README's platform table must name the platforms CI actually builds.

    The table is the promise pip enforces, so it is exactly the kind of claim
    this file exists to keep honest: an entry that says "supported" for a
    platform nothing builds is a claim not backed by an artifact.
    """
    readme = (REPO / "README.md").read_text()
    if "## Install" not in readme and "pip install m0serve" not in readme:
        return  # the wheel is not documented yet; nothing to keep in step

    workflow = (REPO / ".github" / "workflows" / "test.yml").read_text()
    builds_wheel = "poe smoke-wheel" in workflow
    if not builds_wheel:
        fail(
            "README documents `pip install m0serve` but test.yml never builds "
            "a wheel — the install instructions are not backed by an artifact"
        )

    # 3.13t is a dead end (systematic object immortalization); only 3.14t is
    # tested, by py-canary.yml. The README is what a user reads first and is
    # burned into the PyPI long_description at upload time, so it must not
    # point anyone at 3.13t.
    if re.search(r"3\.13t\+|3\.13t or newer|from 3\.13t", readme):
        fail(
            "README claims free-threading works from 3.13t, but pyproject.toml "
            "and docs/WSGI_VS_ASGI.md both record 3.13t as a dead end and only "
            "3.14t is tested"
        )
    probe = (REPO / "pyproject.toml").read_text()
    m = re.search(r"uv python install (3\.\d+t)", probe)
    if m and "free-threaded" in readme and m.group(1) not in readme:
        fail(
            f"pyproject.toml probes {m.group(1)} but the README's free-threading "
            f"claim does not name it"
        )


def main():
    check_warning_counts()
    check_smoke_coverage()
    check_bench_region()
    check_version_single_source()
    check_wheel_platform_claims()
    if failures:
        print("check-docs: FAIL")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("check-docs: every machine-sourced doc fact matches its source")


if __name__ == "__main__":
    main()
