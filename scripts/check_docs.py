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

    # uv.lock records it a third time. RELEASING.md says "run uv lock" after
    # a bump and nothing checked that it happened -- a stale lock is invisible
    # until someone notices the wrong version in a resolved environment.
    lock = (REPO / "uv.lock").read_text()
    m = re.search(r'name = "mojo-http"\nversion = "([^"]+)"', lock)
    if m and m.group(1) != declared.group(1):
        fail(
            f"uv.lock still records version {m.group(1)!r} but pyproject.toml "
            f"says {declared.group(1)!r} — run `uv lock`"
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


def _bench(kind):
    """The newest artifact of one bench kind, or None."""
    files = sorted((REPO / "bench" / "results").glob(f"{kind}-*.json"))
    return json.loads(files[-1].read_text()) if files else None


def _agrees(shown, computed):
    """Does prose `shown` round-trip to `computed` at the precision written?

    The prose rounds — "0.83x", "~1.2x", "121.0k" — so an exact compare is
    wrong and a fixed tolerance is arbitrary. Rounding the computed value to
    the precision the sentence actually claims is neither: "~1.2x" passes at
    1.206 and fails at 1.35, while "1.21x" passes only at 1.205-1.214.
    The doc chooses its own strictness by how precisely it writes.
    """
    text = shown.replace(",", "")
    decimals = len(text.split(".")[1]) if "." in text else 0
    return round(computed, decimals) == float(text)


def check_bench_prose():
    """Prose figures derived from bench artifacts, recomputed from them.

    `render_bench_docs` keeps the TABLES honest and nothing kept the
    sentences around them honest — while the sentences are where the
    headline claims live. A reader meets "0.83x Granian per core" in a
    paragraph, not in a table cell.

    That gap produced a real error. docs/WSGI_PERFORMANCE.md stated the
    result as "roughly 1.0x HTTP layer x ~1.35x bridge", which does not
    reconcile with the artifact underneath it: the measured per-core gap is
    1.21x, and a 1.35x bridge term needs an HTTP layer term of 0.89x — this
    server's HTTP layer *slower* than the comparator's, which the same
    sentence denies. It was a structural mistake, not an arithmetic one (a
    two-sided decomposition needs both sides measured, and there is no
    Granian-without-Python row), and it had been copied into README.md and
    docs/BENCHMARKS.md before anyone divided it out.

    So: every figure below is recomputed from the newest artifact and
    compared at the precision the prose claims. Deliberately not exhaustive
    — it pins the load-bearing comparisons, the ones a reader would quote
    back. Numbers sourced from measurements that never became artifacts
    (the E-core/P-core split, the mixed-workload p99s) cannot be checked
    here and are marked as such on the page itself.
    """
    layer, asgi = _bench("layer-split"), _bench("asgi-wrk-hello")
    if not layer or not asgi:
        return  # nothing recorded yet; the tables render an absence too

    try:
        lm = layer["medians"]
        hello = lm["hello(no python,1proc)"]["rps_per_core"]
        m0 = lm["m0serve+bare w1"]["rps_per_core"]
        gran = lm["granian+bare w1"]["rps_per_core"]
        gran_cores = lm["granian+bare w1"]["cores"]
        am0 = asgi["medians"]["m0serve asgi-executor"]
        auv = asgi["medians"]["uvicorn asyncio"]
    except KeyError as missing:
        fail(
            f"a bench artifact no longer has the row {missing} that the docs"
            " quote — check_bench_prose cannot verify the prose figures"
        )
        return

    q = {
        "hello/1000": hello / 1000,
        "m0/1000": m0 / 1000,
        "gran/1000": gran / 1000,
        "m0÷gran": m0 / gran,
        "gran÷m0": gran / m0,
        "hello÷m0 (this server's bridge tax)": hello / m0,
        "granian's measured cores at --workers 1": gran_cores,
        "asgi rps ratio m0÷uvicorn": am0["rps"] / auv["rps"],
        "asgi per-core gap uvicorn÷m0": auv["rps_per_core"] / am0["rps_per_core"],
    }

    # (document, what it is, pattern with ONE capture group, key in q)
    # Patterns run against whitespace-normalized text, so re-wrapping a
    # paragraph never breaks one.
    claims = [
        ("docs/BENCHMARKS.md", "the WSGI verdict row",
         r"Granian, by ~([\d.]+)x", "gran÷m0"),
        ("docs/BENCHMARKS.md", "the ASGI verdict row",
         r"uvicorn, by ~([\d.]+)x", "asgi per-core gap uvicorn÷m0"),
        ("docs/BENCHMARKS.md", "the hello row quoted in prose",
         r"runs at \*\*([\d.]+)k\s*rps/core\*\*", "hello/1000"),
        ("docs/BENCHMARKS.md", "Granian's end-to-end rate quoted in prose",
         r"above Granian's end-to-end \*\*([\d.]+)k\*\*", "gran/1000"),
        ("docs/BENCHMARKS.md", "m0serve's WSGI rate quoted in prose",
         r"m0serve runs at \*\*([\d.]+)k\s*rps/core\*\*", "m0/1000"),
        ("docs/BENCHMARKS.md", "this server's bridge tax",
         r"its own bridge costs ([\d.]+)x", "hello÷m0 (this server's bridge tax)"),
        ("docs/BENCHMARKS.md", "the net per-core ratio",
         r"m0serve is \*\*([\d.]+)x Granian per core\*\*", "m0÷gran"),
        ("docs/BENCHMARKS.md", "the gap restated the other way",
         r"Granian is ([\d.]+)x ahead", "gran÷m0"),
        ("docs/BENCHMARKS.md", "the gap in the correction note",
         r"the measured gap is ([\d.]+)x", "gran÷m0"),
        ("docs/BENCHMARKS.md", "the comparator's measured cores",
         r"running ~([\d.]+) cores", "granian's measured cores at --workers 1"),
        ("docs/BENCHMARKS.md", "the ASGI throughput ratio",
         r"Under wrk the ratio is ([\d.]+)x", "asgi rps ratio m0÷uvicorn"),

        ("README.md", "m0serve's WSGI rate",
         r"([\d.]+)k against [\d.]+k rps/core", "m0/1000"),
        ("README.md", "Granian's WSGI rate",
         r"[\d.]+k against ([\d.]+)k rps/core", "gran/1000"),
        ("README.md", "the net per-core ratio",
         r"a bare callable — about ([\d.]+)x", "m0÷gran"),
        ("README.md", "the hello row",
         r"runs at ([\d.]+)k rps/core", "hello/1000"),
        ("README.md", "this server's bridge tax",
         r"own bridge costs ([\d.]+)x", "hello÷m0 (this server's bridge tax)"),

        ("docs/WSGI_PERFORMANCE.md", "the corrected per-core gap",
         r"gap is \*\*([\d.]+)x\*\*", "gran÷m0"),
        ("docs/WSGI_PERFORMANCE.md", "this server's bridge tax",
         r"costs \*\*([\d.]+)x\*\*", "hello÷m0 (this server's bridge tax)"),
        ("docs/WSGI_PERFORMANCE.md", "the net per-core ratio",
         r"the net is \*\*([\d.]+)x\*\*", "m0÷gran"),
    ]

    for doc, what, pattern, key in claims:
        path = REPO / doc
        if not path.exists():
            continue
        text = re.sub(r"\s+", " ", path.read_text())
        m = re.search(pattern, text)
        if not m:
            fail(
                f"{doc}: could not find {what} — check_bench_prose's pattern"
                f" /{pattern}/ no longer matches. If the sentence was"
                " reworded on purpose, update the pattern; do not delete the"
                " claim from the list."
            )
            continue
        if not _agrees(m.group(1), q[key]):
            fail(
                f"{doc} says {what} is {m.group(1)}, but {key} computes to"
                f" {q[key]:.4f} from the newest artifact"
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


def check_m0pub_twins():
    """The two copies of m0pub.py must stay byte-identical.

    The module ships inside the wheel (`m0serve.m0pub`) and lives in the demo
    app (`apps/django_realtime/m0pub.py`), because each must work where the
    other cannot: pip users have no source tree, and the demo runs from a
    source tree where the wheel is deliberately not installed. Two copies
    with no guard is how they drift -- a fix landing in the demo and never
    reaching users, invisible until someone diffs them.
    """
    demo = REPO / "apps" / "django_realtime" / "m0pub.py"
    wheel = REPO / "packaging" / "m0serve" / "src" / "m0serve" / "m0pub.py"
    if not wheel.exists():
        fail("packaging/m0serve/src/m0serve/m0pub.py is missing — the wheel "
             "would ship without the publish helper the quickstart imports")
        return
    if demo.read_bytes() != wheel.read_bytes():
        fail("m0pub.py has drifted between apps/django_realtime and the wheel "
             "package — edit one, copy to the other (they are byte-identical "
             "on purpose; each runs where the other cannot)")


def check_target_cpu_pinned():
    """Every task that emits a distributable binary must pin --target-cpu.

    `mojo build` defaults it to the host CPU, so an unpinned build is
    compiled for whatever machine produced it and dies with SIGILL on
    anything older. The first real release run proved it: "Illegal
    instruction (core dumped)" in a clean container, having passed on the
    runner that built it.

    This is checked here rather than left to review because the defect is
    invisible from the build machine BY CONSTRUCTION -- every test that runs
    where the binary was compiled passes. The clean-consumer jobs catch it
    behaviourally; this catches it before a release run has to.
    """
    text = (REPO / "pyproject.toml").read_text()
    for task in ("build-ffi", "build-serve"):
        m = re.search(
            r"^\[tool\.poe\.tasks\." + re.escape(task) + r"\]$(.*?)(?=^\[tool\.poe\.tasks\.)",
            text,
            re.M | re.S,
        )
        if not m:
            fail(f"could not find the {task} task to check its target CPU")
            continue
        # The COMMAND, not the section: the comment above it explains what
        # --target-cpu is for, so a substring search over the whole task
        # passes even with the flag deleted. (Found by sabotaging it, which
        # is the only reason this reads the way it does.)
        body = m.group(1)
        body = re.sub(r"\\\n\s*", " ", body)          # join continuations
        commands = [
            ln for ln in body.splitlines()
            if ln.lstrip().startswith("mojo build")
        ]
        if not commands:
            fail(f"poe {task} no longer contains a `mojo build` command to check")
            continue
        for cmd in commands:
            if "--target-cpu" not in cmd:
                fail(
                    f"poe {task} invokes `mojo build` without --target-cpu, so it "
                    "compiles for the build machine's own CPU. That binary "
                    "crashes with SIGILL on an older one, and nothing running on "
                    "the build machine can tell."
                )


def check_consumer_jobs_stay_clean():
    """The wheel consume jobs must not acquire a checkout or the toolchain.

    Their entire value is that they run somewhere the wheel was NOT built.
    That property is invisible when it breaks: someone adds
    `actions/checkout` to get a test fixture, the job still passes, and the
    proof quietly reverts to build-machine conditions with a green tick --
    which is precisely how a broken libm0core shipped for seven releases.
    So it is asserted here rather than trusted to review.

    `wheel-inspect` is the deliberate exception: it needs scripts/ to run the
    portability checker, and it never executes the binary.
    """
    path = REPO / ".github" / "workflows" / "release.yml"
    if not path.exists():
        return
    text = path.read_text()
    jobs = re.split(r"\n  (?=[a-z][a-z0-9-]*:\n)", text)
    seen = []
    for block in jobs:
        name = re.match(r"\s*([a-z][a-z0-9-]*):", block)
        if not name or not name.group(1).startswith("wheel-consume"):
            continue
        seen.append(name.group(1))
        for forbidden, why in (
            ("actions/checkout", "a repository checkout"),
            ("astral-sh/setup-uv", "uv, which brings the Mojo toolchain"),
            ("poe ", "a poe task, which only exists in the repo"),
        ):
            if forbidden in block:
                fail(
                    f"release.yml job {name.group(1)!r} uses {why} — that puts the "
                    "wheel back on a machine that could have built it, and the "
                    "job stops proving anything"
                )
        if "did not build the wheel" not in block:
            fail(
                f"release.yml job {name.group(1)!r} no longer asserts its own "
                "cleanliness before testing the wheel"
            )
    if not seen:
        fail("release.yml has no wheel-consume-* job: nothing installs the wheel off the build machine")


def main():
    check_warning_counts()
    check_smoke_coverage()
    check_bench_region()
    check_version_single_source()
    check_wheel_platform_claims()
    check_m0pub_twins()
    check_bench_prose()
    check_target_cpu_pinned()
    check_consumer_jobs_stay_clean()
    if failures:
        print("check-docs: FAIL")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("check-docs: every machine-sourced doc fact matches its source")


if __name__ == "__main__":
    main()
