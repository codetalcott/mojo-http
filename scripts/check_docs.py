"""The doc-fact ratchet: prose numbers must match their machine sources.

    python3 scripts/check_docs.py        # exit 1 on any mismatch, naming it
    python3 scripts/check_docs.py --selftest   # the citation rule can fire

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

One deliberate widening, recorded rather than drifted into: check_spec_sheet
covers docs/SPEC.md, whose `implemented`, `planned` and `out of scope` rows
are claims with no machine source to compare against. They are admitted
because the rule enforced is still mechanical -- an `implemented` row must
name a file that exists, a `planned` row a roadmap heading that resolves, an
`out of scope` row a reason at all -- and because the alternative was a
public page whose green rows nothing checked. What is NOT admitted, and is
stated on the page: no check here can tell whether a cited gate exercises the
capability its row claims. check_decisions_ledger is the second widening
of that kind, for docs/DECISIONS.md: a standing decision is a claim, and
what is mechanical about it is that the note it says records it exists,
its retiring condition is written down, and its id is one nobody else
holds. Whether the decision is still right is the retiring condition's job.

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


def check_test_coverage():
    """Every test-* poe task must be reachable from `test-all`.

    `check_smoke_coverage`'s twin, for the other half of CI. Smokes are
    listed one by one in test.yml and so are checked against it; the Mojo
    and shim tests are run as ONE step (`uv run poe test-all`), so a test
    task drops out of CI simply by leaving that sequence -- no ghost step,
    no red tick, nothing to notice. Sequences nest (`test-sqlite` refers to
    `test-sqlite-mojo`), so this follows them.
    """
    toml = (REPO / "pyproject.toml").read_text()
    tasks = set(re.findall(r"^\[tool\.poe\.tasks\.(test-[a-z0-9-]+)\]", toml, re.M))
    sequences = {
        name: re.findall(r'"([a-z0-9-]+)"', body)
        for name, body in re.findall(
            r"^\[tool\.poe\.tasks\.([a-z0-9-]+)\]$(.*?)(?=^\[tool\.poe\.tasks\.)",
            toml + "\n[tool.poe.tasks.__end__]\n",
            re.M | re.S,
        )
        for _ in [0]
        if "sequence" in body
    }
    reached, queue = set(), ["test-all"]
    while queue:
        name = queue.pop()
        if name in reached:
            continue
        reached.add(name)
        queue.extend(sequences.get(name, ()))
    missing = sorted(tasks - reached)
    if missing:
        fail(
            "test task(s) defined but not reachable from `poe test-all`, "
            "which is what CI runs: " + ", ".join(missing)
        )


def check_release_branches_cleaned():
    """A `release/v*` branch whose tag exists is finished — delete it.

    RELEASING.md step 4 ends "Delete the branch afterwards", and nothing
    checked that it happened: four of them (v0.1.0, v0.2.0, v0.3.0,
    v0.9.0) sat on the remote until someone happened to list branches.
    Same class of miss as the smoke and test coverage guards above — a
    step that is remembered rather than enforced eventually is not.

    Both halves come from `git ls-remote`, deliberately. The remote is the
    only place these branches live, and a CI checkout has neither the
    branch refs nor (at the default fetch depth) the tags — a check that
    read local `git tag` would find nothing to compare against and could
    never fire, which is the failure mode this file exists to prevent.

    Network, unlike every other check here, so a failure to ASK is a skip
    rather than a failure: an offline tree, a clone with no `origin`, or a
    sandbox without credentials must not turn this into a red build over
    something it cannot see.

    One narrow false positive, self-correcting: the Release workflow
    creates the tag from the branch, so both exist for the ~15 minutes a
    release takes. `Tests` runs only on pushes and PRs to `main`, never on
    a `release/v*` push, so only a PR opened inside that window sees it —
    and what it asks for is what the release ends with anyway.
    """
    def ls_remote(*args):
        try:
            r = subprocess.run(
                ["git", "ls-remote", *args, "origin"],
                capture_output=True, text=True, timeout=30, cwd=REPO,
            )
        except Exception:
            return None
        return r.stdout if r.returncode == 0 else None

    heads = ls_remote("--heads")
    if heads is None:
        return
    branches = [
        line.split("refs/heads/", 1)[1]
        for line in heads.splitlines()
        if "refs/heads/release/v" in line
    ]
    if not branches:
        return
    tag_out = ls_remote("--tags")
    if tag_out is None:
        return
    # `^{}` entries are an annotated tag's dereferenced commit; the tag
    # name is the same either way, so strip the suffix and dedupe.
    tags = {
        line.split("refs/tags/", 1)[1].removesuffix("^{}")
        for line in tag_out.splitlines()
        if "refs/tags/" in line
    }
    stale = sorted(b for b in branches if b[len("release/"):] in tags)
    if stale:
        fail(
            "release branch(es) still on the remote after their release: "
            + ", ".join(stale)
            + " — RELEASING.md step 4 ends 'Delete the branch afterwards'. "
            + "Run `git push origin --delete " + " ".join(stale) + "`. "
            + "(If a release is running right now, wait for it to finish "
            "and delete the branch then.)"
        )


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


def check_shim_rendered():
    """The executor shim's Mojo constant must be the rendering of its `.py`.

    `packages/m0-wsgi/shim/m0_shim.py` is the shim's source of truth and
    `packages/m0-wsgi/src/shim_source.mojo` is what the binary embeds
    (`scripts/render_shim.py`; `poe render-shim`). An edit to the `.py`
    that is not re-rendered ships the OLD program while `poe test-shim`
    tests the new one, which is the drift this exists to refuse; the same
    `--check` proves the literal decodes back to the file byte for byte.
    Here rather than in test.yml so a pull request that edits only the
    `.py` -- which test.yml runs -- and one that edits only docs both see
    it. `render_shim.py --selftest` (in the check-docs task and docs.yml)
    proves this check can fail.
    """
    r = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "render_shim.py"), "--check"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        fail((r.stdout + r.stderr).strip() or "render_shim --check failed")


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

    # QUICKSTART.md echoes `m0serve --version`, and that echo is a claim about
    # the CURRENT release rather than a record of an old one -- the doc opens
    # by promising every command in it is executed by CI. The promise has one
    # hole: run_quickstart.py runs ```bash blocks and treats ```text as
    # display-only, which is right (the other text block interleaves output
    # from three commands and is not byte-stable), so no amount of executing
    # the doc can notice the number. It shipped saying 0.10.0 against a 0.11.0
    # tree for exactly that reason. Checked here instead, where prose facts
    # with a machine source belong.
    quickstart = REPO / "QUICKSTART.md"
    if quickstart.exists():
        for shown in set(re.findall(r"^m0serve (\d+\.\d+\.\d+\S*)$",
                                    quickstart.read_text(), re.M)):
            if shown != declared.group(1):
                fail(
                    f"QUICKSTART.md shows `m0serve {shown}` as the output of "
                    f"`m0serve --version`, but pyproject.toml declares "
                    f"{declared.group(1)!r} — the quickstart claims every "
                    "command in it is executed, so its output must be current"
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


def _platform_table(readme):
    """The `| platform | status |` rows of a README, as (platform, status).

    Both READMEs carry one such table and nothing else in either is a
    two-column table, so this stays a local helper rather than a markdown
    dependency.
    """
    rows = []
    for line in readme.splitlines():
        line = line.strip()
        if not line.startswith("|") or not line.endswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != 2:
            continue
        if cells[0].lower() == "platform" or set(cells[1]) <= set("-: "):
            continue  # header and its underline
        rows.append((cells[0], cells[1]))
    return rows


def _claims_support(status):
    """Does a status cell promise a wheel, or decline to?

    "not supported" and "not possible" both contain the word, so the negative
    forms are tested first.
    """
    s = status.lower().replace("*", "").strip()
    if s.startswith("not ") or "not supported" in s or "not possible" in s:
        return False
    return "supported" in s


def _matches(platform_cell, plat):
    """Does a table row describe the release matrix's `plat` slug?

    Derived from the slug rather than a hand-kept mapping: `linux-aarch64`
    requires both "linux" and "aarch64" in the platform cell, which the
    current slugs (`macos-arm64`, `linux-x86_64`, `linux-aarch64`) separate
    unambiguously. A new slug whose words do not appear in the prose will
    fail loudly here rather than pass silently, which is the right way round.
    """
    cell = platform_cell.lower()
    return all(token in cell for token in plat.split("-"))

def _bench(kind):
    """The newest artifact of one bench kind, or None."""
    files = sorted((REPO / "bench" / "results").glob(f"{kind}-*.json"))
    return json.loads(files[-1].read_text()) if files else None


def check_hybrid_p99_consistent():
    """The mounted-isolation p99 is quoted twice in README.md; they must agree.

    Not artifact-backed — `scripts/hybrid_isolation.py` asserts a ceiling
    (`ISOLATION_BUDGET_MS`, generous on purpose so CI is not flaky) rather
    than recording the figure, so no file to recompute it from. What CAN be
    checked is that the two copies say the same thing: the first screen
    makes the claim and the mounts section explains it, and a number edited
    in one place and not the other is the ordinary way a README starts
    contradicting itself.

    If this ever gets an artifact, give the two copies `num:` spans in
    render_bench_docs.py's QUANTITIES and delete this.
    """
    quoted = set(
        re.findall(r"async mount(?:'s p99)? still answers at p99 ([\d.]+) ms",
                   re.sub(r"\s+", " ", (REPO / "README.md").read_text()))
    )
    if not quoted:
        fail(
            "README.md no longer states the mounted-isolation p99 —"
            " check_hybrid_p99_consistent's pattern does not match. If the"
            " claim moved, update the pattern rather than dropping it."
        )
    elif len(quoted) > 1:
        fail(
            "README.md quotes the mounted-isolation p99 as "
            + " and ".join(sorted(quoted))
            + " ms in different places — one was edited and the other was not"
        )


def check_wheel_platform_claims():
    """Both READMEs' platform tables vs the platforms release.yml actually builds.

    The table is the promise pip enforces, so it is exactly the kind of claim
    this file exists to keep honest -- and it has to hold in both directions.
    A row that says "supported" for a platform nothing builds is a claim with
    no artifact behind it. A platform that IS built but reads "not yet
    shipped" is the same defect mirrored, and it sends users away from a wheel
    already sitting on PyPI.

    The second direction is not hypothetical. packaging/m0serve/README.md told
    aarch64 users the wheel did not exist for the whole of 0.11.0 -- which
    shipped an aarch64 wheel -- because the row was written before the release
    matrix grew its third entry and nothing ever compared the two.

    Two READMEs, because they are read by different people arriving different
    ways. The repository's own is what a visitor sees on GitHub;
    packaging/m0serve/README.md is the `readme` named by the wheel's
    pyproject.toml and therefore the PyPI project page -- the first screen for
    everyone who arrives by `pip install`, and the one whose staleness is
    published rather than merely committed.

    A coverage asymmetry worth knowing, because it is the opposite of the
    guess: test.yml's `paths-ignore` lists `*.md`, and a GitHub path glob's
    `*` does not cross `/`. So a PR touching only the root README.md skips
    CI and is never checked here, while one touching only
    packaging/m0serve/README.md runs the full suite. The file that reaches
    the most people is the one that is actually guarded.
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

    # The release matrix is the source of truth for what users can install:
    # a `plat` here is a wheel uploaded to PyPI, and nothing else is.
    release = (REPO / ".github" / "workflows" / "release.yml").read_text()
    built = re.findall(r"^\s*(?:-\s+)?plat: (\S+)\s*$", release, re.M)
    if not built:
        fail(
            ".github/workflows/release.yml declares no `plat:` entries — the "
            "wheel build matrix is what the platform tables are checked "
            "against, and it can no longer be read"
        )

    wheel_readme_path = REPO / "packaging" / "m0serve" / "README.md"
    tables = {"README.md": readme}
    if wheel_readme_path.exists():
        tables["packaging/m0serve/README.md"] = wheel_readme_path.read_text()
    else:
        fail(
            "packaging/m0serve/README.md is missing — it is the wheel's "
            "`readme` and therefore the PyPI project page"
        )

    for name, text in tables.items():
        rows = _platform_table(text)
        if not rows:
            fail(f"{name} has no `| platform | status |` table to check")
            continue
        for plat in built:
            row = next((r for r in rows if _matches(r[0], plat)), None)
            if row is None:
                fail(
                    f"{name}'s platform table has no row for {plat}, which "
                    "release.yml builds and uploads — a shipped wheel users "
                    "are never told about"
                )
            elif not _claims_support(row[1]):
                fail(
                    f"{name} says {plat} is {row[1]!r}, but release.yml builds "
                    "and uploads that wheel — the row sends users away from a "
                    "distribution that exists"
                )
        for platform, status in rows:
            if not _claims_support(status):
                continue
            if not any(_matches(platform, plat) for plat in built):
                fail(
                    f"{name} claims {platform!r} is supported, but release.yml "
                    f"builds only {', '.join(built)} — a promise with no wheel "
                    "behind it"
                )

    # 3.13t is a dead end (systematic object immortalization); only 3.14t is
    # tested, by py-canary.yml. Neither README may point anyone at it — the
    # wheel's least of all, since PyPI serves that one to people who have
    # already installed.
    for name, text in tables.items():
        if re.search(r"3\.13t\+|3\.13t or newer|from 3\.13t", text):
            fail(
                f"{name} claims free-threading works from 3.13t, but "
                "pyproject.toml and docs/WSGI_VS_ASGI.md both record 3.13t as "
                "a dead end and only 3.14t is tested"
            )
    probe = (REPO / "pyproject.toml").read_text()
    m = re.search(r"uv python install (3\.\d+t)", probe)
    if m and "free-threaded" in readme and m.group(1) not in readme:
        fail(
            f"pyproject.toml probes {m.group(1)} but the README's free-threading "
            f"claim does not name it"
        )


def check_m0pub_twins():
    """The two copies of m0pub.py and of grant.py must stay byte-identical.

    Each module ships inside the wheel (`m0serve.m0pub`, `m0serve.grant`)
    and lives in the demo app (`apps/django_realtime/`), because each must
    work where the other cannot: pip users have no source tree, and the
    demo runs from a source tree where the wheel is deliberately not
    installed. Two copies with no guard is how they drift -- a fix landing
    in the demo and never reaching users, invisible until someone diffs
    them.
    """
    for name in ("m0pub.py", "grant.py"):
        demo = REPO / "apps" / "django_realtime" / name
        wheel = REPO / "packaging" / "m0serve" / "src" / "m0serve" / name
        if not wheel.exists():
            fail(f"packaging/m0serve/src/m0serve/{name} is missing — the wheel "
                 "would ship without a helper the quickstart imports")
            continue
        if not demo.exists():
            fail(f"apps/django_realtime/{name} is missing — the demo runs where "
                 "the wheel is not installed and needs its own copy")
            continue
        if demo.read_bytes() != wheel.read_bytes():
            fail(f"{name} has drifted between apps/django_realtime and the wheel "
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


# toml-rb 4.2.0's escape handling, replayed. Its MultilineString#value strips
# `\\` + newline + indent with a regex that cannot see that the backslash was
# itself escaped, then rejects whatever escape the join produces.
_TOMLRB_JOIN = re.compile(r"\\\r?\n[\n\t\r ]*")
_TOMLRB_ESCAPE = re.compile(r"\\(u[\da-fA-F]{4}|U[\da-fA-F]{8}|.)")
_TOMLRB_KNOWN = {"\\0", "\\t", "\\b", "\\f", "\\n", "\\r", '\\"', "\\\\"}


def check_pyproject_parses_for_consumers():
    """A pyproject.toml every parser accepts, not just the one we run.

    Our own tools read this file with tomllib, which is correct; GitHub's
    dependency graph reads it with Ruby's toml-rb, which is not. A line
    ending in `\\` -- an escaped backslash, i.e. a shell line continuation
    that survives TOML -- is joined by toml-rb as if the backslash were the
    continuation, and the leftover backslash fuses with the next line's
    first character into a reserved escape.

    That is how `smoke-threads` broke the `update-uv-graph` job for five
    days and sixty runs: `... 'bare wsgi app' \\` over `|| fail ...` became
    `\\|`. Nothing in this repo could see it -- tomllib, uv and poe all
    parse the file -- and the failing workflow is not `Tests`, so no PR
    ever went red. The file's own idiom is a single trailing `\\`, which
    TOML joins itself and every parser agrees on; this keeps it that way.
    """
    for rel in ("pyproject.toml", "packaging/m0serve/pyproject.toml"):
        text = (REPO / rel).read_text()
        for block in re.finditer(r'"""(.*?)"""', text, re.S):
            line = text[: block.start()].count("\n") + 1
            joined = _TOMLRB_JOIN.sub("", block.group(1))
            for esc in _TOMLRB_ESCAPE.finditer(joined):
                token = esc.group(0)
                if len(token) == 2 and token not in _TOMLRB_KNOWN:
                    fail(
                        f"{rel}: the multiline string at line {line} yields the "
                        f"reserved escape {token!r} under toml-rb -- a line ending "
                        "in a doubled backslash. Use a single trailing backslash "
                        "and let TOML join the lines"
                    )


def check_test_counts():
    """README's "What's in the box" table quotes a test count per package and a
    total, and the commands block quotes the total again; all of them are
    counted from the tree here (`def test_` per `packages/*/test/*.mojo`,
    which is what `TestSuite.discover_tests` runs). The table sat at 618
    while the tree held 928 — the number a reader would quote back.
    """
    counts = {}
    for pkg in sorted((REPO / "packages").iterdir()):
        tests = pkg / "test"
        if not tests.is_dir():
            continue
        n = 0
        for f in tests.glob("*.mojo"):
            n += sum(1 for line in f.read_text().splitlines()
                     if line.startswith("def test_"))
        counts[pkg.name] = n
    total = sum(counts.values())
    readme = (REPO / "README.md").read_text()
    for name, n in counts.items():
        m = re.search(r"^\| `%s` \|[^|]*\| (\d+) \|$" % re.escape(name),
                      readme, re.M)
        if not m:
            fail(f"README.md: no test-count table row for `{name}`")
        elif int(m.group(1)) != n:
            fail(f"README.md says `{name}` has {m.group(1)} tests; the tree"
                 f" has {n}")
    m = re.search(r"^\| \*\*Total\*\* \| \| \*\*(\d+)\*\* \|$", readme, re.M)
    if not m:
        fail("README.md: the test-count table has no Total row")
    elif int(m.group(1)) != total:
        fail(f"README.md's test total says {m.group(1)}; the tree has {total}")
    m = re.search(r"poe test-all\s+# (\d+) unit tests", readme)
    if not m:
        fail("README.md: the commands block no longer quotes the test total")
    elif int(m.group(1)) != total:
        fail(f"README.md's commands block says {m.group(1)} unit tests; the"
             f" tree has {total}")


def check_backend_seam():
    """`lightbug_http/c/platform.mojo` is the ONE place an OS backend is chosen.

    `PlatformBackend` (kqueue on macOS, epoll on Linux) used to be selected
    at five sites, each a `comptime if CompilationTarget.is_macos()` with
    the import inside the branch, plus three private copies of
    `MSG_DONTWAIT`. A Darwin-specific variant of one backend would have had
    to be threaded through every site. The seam holds only while nothing
    else imports or constructs a backend by name; this is that rule, over
    the tree's text. The backend modules themselves and the tests (which
    may drive one backend on purpose) are the only exemptions.
    """
    allowed = {
        "packages/m0-http/lightbug_http/c/platform.mojo",
        "packages/m0-http/lightbug_http/c/kqueue_backend.mojo",
        "packages/m0-http/lightbug_http/c/epoll_backend.mojo",
    }
    chooses = re.compile(
        r"^\s*from lightbug_http\.c\.(?:kqueue|epoll)_backend import"
        r"|\b(?:KqueueBackend|EpollBackend)\(",  # a call, not prose like `KqueueBackend (macOS)`
        re.M,
    )
    for root in ("packages", "apps"):
        for f in sorted((REPO / root).rglob("*.mojo")):
            rel = f.relative_to(REPO).as_posix()
            if rel in allowed or "/test/" in rel:
                continue
            if chooses.search(f.read_text()):
                fail(
                    f"{rel}: chooses an OS backend itself (imports or"
                    " constructs KqueueBackend/EpollBackend); go through"
                    " lightbug_http/c/platform.mojo's PlatformBackend"
                )


def check_spec_sheet():
    """docs/SPEC.md's capability claims vs the gates they name.

    The sheet is a public completeness tracker, so `verified` has to mean
    something mechanical: a row may claim it only by naming a CI step, a test
    function, or a weekly, monthly or pre-release gate that this repo can be shown to run.
    The rules, the both-ways cross-references and the seventeen sabotages that
    prove each of them live in scripts/spec_sheet.py, which is written as a
    pure function of text so `--sabotage` can revert a rule in memory. This is
    the four-line wrapper that reads the files and forwards what it says.
    """
    import spec_sheet

    src = spec_sheet.read_sources()
    rows, problems = spec_sheet.analyse(src)
    for p in problems:
        fail(p)
    if problems:
        return  # a stale rollup is not news while the rows themselves are wrong
    if spec_sheet.rewrite(src["sheet"], rows) != src["sheet"]:
        fail("docs/SPEC.md's rollup is stale — run: python3 scripts/spec_sheet.py")
    out = REPO / "docs" / "spec.json"
    if not out.exists() or out.read_text() != spec_sheet.spec_json(rows):
        fail("docs/spec.json is stale — run: python3 scripts/spec_sheet.py")


# The context the `main` ruleset requires. Ruleset 21614787 carries a
# required_status_checks rule naming exactly this string, pinned to the GitHub
# Actions app (integration_id 15368). GitHub matches a required check against
# the JOB name, not the workflow name -- the workflow is called `Docs` and the
# check run is called `check-docs`.
REQUIRED_CONTEXT = "check-docs"


def check_required_context_intact():
    """docs.yml must keep reporting the status check `main` requires.

    This is the one guard here whose failure mode is a HANG rather than a red
    build, which is why it is worth its own check. A required status check that
    stops reporting does not fail: every pull request sits forever on
    "Expected - Waiting for status to be reported", with nothing anywhere
    saying why, and the only fix is editing a repository setting that is not in
    this tree. The ruleset has no bypass actors, so nobody can merge past it.

    Three edits cause it, and all three look harmless in review:

    - renaming the job, because the check run is named after the job;
    - giving the job a matrix, because that suffixes the context
      (`check-docs (ubuntu-latest)`), which is a different string;
    - adding a `paths`/`paths-ignore` filter, because a filtered workflow does
      not report on the pull requests it filters out -- which is the whole
      reason docs.yml is unfiltered and eligible to be required at all, while
      test.yml is not.

    Sabotaged three ways while writing it: each edit made this fire, and the
    message names the ruleset rather than only the file, because the person
    reading it will be looking at a stuck pull request.
    """
    path = REPO / ".github" / "workflows" / "docs.yml"
    if not path.exists():
        fail(
            ".github/workflows/docs.yml is gone, but the `main` ruleset still "
            f"requires the status check {REQUIRED_CONTEXT!r} — every pull "
            "request will wait forever for a check nothing produces"
        )
        return
    text = path.read_text()

    job = re.search(
        r"^  " + re.escape(REQUIRED_CONTEXT) + r":\s*$(.*?)(?=^  \S|\Z)",
        text,
        re.M | re.S,
    )
    if not job:
        fail(
            f"docs.yml no longer defines a job named {REQUIRED_CONTEXT!r}. That "
            "string is the status check the `main` ruleset requires, and a "
            "check run is named after its JOB, not its workflow — renaming it "
            "does not fail CI, it makes every pull request hang on a status "
            "that will never be reported."
        )
    elif re.search(r"^\s+(strategy|matrix):", job.group(1), re.M):
        fail(
            f"docs.yml's {REQUIRED_CONTEXT!r} job has a matrix, which suffixes "
            f"the check run name (`{REQUIRED_CONTEXT} (ubuntu-latest)`). The "
            f"`main` ruleset requires the bare string {REQUIRED_CONTEXT!r}, so "
            "the required check would never report again."
        )

    on = re.search(r"^on:\s*$(.*?)(?=^\S)", text, re.M | re.S)
    if not on:
        fail("docs.yml has no `on:` block to check for path filters")
    elif re.search(r"^\s+paths(-ignore)?:", on.group(1), re.M):
        fail(
            "docs.yml has acquired a `paths`/`paths-ignore` filter. It is "
            "deliberately unfiltered: a filtered workflow does not report on "
            "the pull requests it skips, and this one is a REQUIRED check on "
            "`main`, so those pull requests would hang unmergeable. That is "
            "the defect test.yml has and the reason this workflow exists."
        )


def check_bench_kinds_do_not_shadow():
    """No bench artifact kind may be a dash-prefix of another.

    `render_bench_docs.newest(kind)` and this file's `_bench(kind)` both resolve
    "the newest artifact of a kind" as `glob(f"{kind}-*.json")` sorted
    LEXICOGRAPHICALLY, taking the last. That is correct only while no kind's
    name is a prefix of another's, because the shorter kind's glob matches the
    longer kind's files too -- and a stamp sorts below every letter, so the
    intruder wins:

        asgi-wrk-hello-20260829T120000Z.json           the real newest
        asgi-wrk-hello-inverted-20260828T120000Z.json  sorts LAST ('i' > '2')

    The result is silent and public: docs/BENCHMARKS.md would render an older
    run of a DIFFERENT experiment as the current headline figure, and
    the prose spans would then hold the surrounding sentences to it.

    Today the rule is kept by a convention -- A/B variants live in
    subdirectories (`inverted-ab/`, `outbox-sweep/`, `parse-lever-ab/`), which
    the non-recursive glob correctly cannot see. A convention is exactly what
    this file exists to turn into an invariant, and the cost of getting it
    wrong is a wrong number on the page rather than a failure.

    Deliberately NOT a generated index of artifacts, which was the first design:
    an index is a second source of truth to keep in step, and the naming rule
    is the thing that actually has to hold.

    Registered in `main()` BEFORE `check_bench_region`,
    which is load-bearing rather than tidy: it CONSUMES the artifacts
    this validates. Sabotaging it revealed the ordering -- a shadow file made
    `_bench("asgi-wrk-hello")` read the intruder and die on a JSONDecodeError
    traceback before this check ever ran. A guard on the shape of an input has
    to run ahead of everything that reads it.
    """
    results = REPO / "bench" / "results"
    if not results.is_dir():
        return
    stamped = re.compile(r"^(?P<kind>[a-z0-9-]+?)-\d{8}T\d{6}Z\.json$")
    kinds = set()
    for f in sorted(results.glob("*.json")):
        m = stamped.match(f.name)
        if not m:
            fail(
                f"bench/results/{f.name} is not named `<kind>-<YYYYmmddTHHMMSSZ>.json`. "
                "Both readers of these artifacts derive the kind from the "
                "filename, so an unparseable name is either invisible or "
                "captured by another kind's glob."
            )
            continue
        kinds.add(m.group("kind"))
    for short in sorted(kinds):
        for long in sorted(kinds):
            if long.startswith(short + "-"):
                fail(
                    f"bench artifact kind {long!r} is a dash-prefix extension of "
                    f"{short!r}, so `glob('{short}-*.json')` matches {long!r}'s "
                    "files as well. Sorted lexicographically a stamp loses to "
                    "any letter, so the newest "
                    f"{short!r} silently becomes an older {long!r} run on "
                    "docs/BENCHMARKS.md. Put the variant in a subdirectory, as "
                    "inverted-ab/ and outbox-sweep/ already do."
                )


def check_site_corpus():
    """Every relative link in the pages the docs site renders resolves, every
    fragment names a heading, and every docs/*.md is listed with a title.

    scripts/docsite.py owns the rules (its `--check` is this same call, and
    its `--selftest` proves each can fail); running them here puts them on
    doc-only pull requests, which run this file and nothing that needs the
    dev group. A broken link used to be found by a reader, and a new docs
    page could ship with no way to reach it.
    """
    sys.path.insert(0, str(REPO / "scripts"))
    import docsite

    for problem in docsite.Site(REPO).check():
        fail("docsite: " + problem)


def check_rfc_citations():
    """Every `RFC nnnn` the tree cites is a current document, by the
    committed snapshot of the RFC Editor's answers.

    scripts/check_citations.py owns the rules (`--selftest` proves each can
    fail, `--sabotage` reverts each against the real tree); running them
    here puts them on doc-only pull requests, and needs no network. The
    monthly citations.yml is the half that asks the RFC Editor whether the
    snapshot is still true. First run, the tree cited RFC 7230 and RFC 7231
    in the parser, the chunked decoder and the date formatter, four years
    after RFC 9110 and RFC 9112 replaced them.
    """
    sys.path.insert(0, str(REPO / "scripts"))
    import check_citations

    for problem in check_citations.check(REPO):
        fail("citations: " + problem)


def check_ci_measurements_are_collected():
    """A measurement a task records must have somewhere to go, and be kept.

    `scripts/emit.py` is a no-op unless `$M0_RESULTS` names a file, which is
    what makes it safe to call from inside a task body. The same property is
    how the whole thing silently becomes decorative: delete the `env:` block
    from the workflow and every call site still runs, still exits 0, and
    records nothing anywhere. Nothing goes red. The job log looks identical,
    because the tasks still `echo` the number beside the emit call.

    That is the `smoke-sendfile` class of miss again -- a thing that exists,
    passes locally, and is never actually run by CI -- so it is checked here
    rather than trusted, in the same both-ways shape as check_smoke_coverage.

    Three ways it can lapse, all silent:

    - the tasks emit but the workflow sets no `M0_RESULTS`, so every write is
      skipped;
    - the workflow collects but never uploads or renders, so the file dies
      with the runner;
    - the recorder's own selftest stops running, so a regression that drops
      records is invisible (the reason `warning_ratchet.py --selftest` and
      `binfmt.py --selftest` are CI steps and not a convention).
    """
    emitters = sorted(set(re.findall(
        r"^(?!#).*python3 scripts/emit\.py (?!--)([a-z0-9_.]+)",
        (REPO / "pyproject.toml").read_text(), re.M)))
    workflow = (REPO / ".github" / "workflows" / "test.yml").read_text()

    if not emitters:
        if "scripts/emit.py --summary" in workflow:
            fail(
                "test.yml renders CI measurements but no poe task records any "
                "— the summary will always be empty"
            )
        return

    if not re.search(r"^\s+M0_RESULTS:", workflow, re.M):
        fail(
            f"{len(emitters)} poe task measurement(s) call `scripts/emit.py` "
            f"({', '.join(emitters[:3])}...), but test.yml sets no M0_RESULTS. "
            "emit.py is a deliberate no-op without it, so every one of those "
            "calls would run, exit 0 and record nothing — with no failure and "
            "an identical job log, because the tasks still echo the number."
        )
    if "scripts/emit.py --summary" not in workflow:
        fail(
            "test.yml collects CI measurements but never renders them — "
            "add the `--summary` step, or the file is written and never read"
        )
    if not re.search(r"name: ci-results-", workflow):
        fail(
            "test.yml records CI measurements but uploads no `ci-results-*` "
            "artifact, so they die with the runner and no run can be compared "
            "against the next"
        )
    if "scripts/emit.py --selftest" not in workflow:
        fail(
            "scripts/emit.py --selftest is not run by test.yml. A silent "
            "regression in the recorder drops measurements rather than "
            "failing, exactly like the warning parser and the binary parser "
            "whose selftests are CI steps for this reason."
        )


# Prose may cite a path under these roots only if git tracks it. `.claude/`
# is where sessions leave drafts and instruments untracked, and the
# engineering record cited five instruments there by path before any of
# them was in the tree (docs/notes/elastic-pool.md, 2026-09-06) -- a record
# citing a file nobody else can open is a record with a hole. Other roots
# are not this rule's: a historical `/tmp/soak/` is a description of where
# a checkout was, not a citation of the record.
CITATION_ROOTS = (".claude/",)
PROSE = ("README.md", "CLAUDE.md", "CHANGELOG.md")   # plus every docs/**/*.md


def untracked_citations(docs, tracked):
    """Pure: {doc: text} and the set of tracked paths -> failure messages.

    A backticked token under a watched root must be a tracked file, or a
    directory with tracked files under it. Two shapes are mentions of a
    convention rather than citations of a record and are left alone: a
    glob (`.claude/**` in a paths-ignore list) and an AREA named on its
    own (`.claude/worktrees/`, `.claude/handoffs/` -- one segment under
    the root). A THING inside an area (`.claude/handoffs/soak-2026-09-04/`,
    `.claude/handoffs/loop-user-space/herd.c`) is the record naming a
    specific artifact, and that is what must be in the tree.
    """
    out = []
    for doc, text in sorted(docs.items()):
        for cited in re.findall(r"`([^`\n]+)`", text):
            if not cited.startswith(CITATION_ROOTS):
                continue
            if any(ch in cited for ch in "*?["):
                continue
            path = cited.rstrip("/")
            if len(path.split("/")) < 3:
                continue
            if path in tracked or any(t.startswith(path + "/") for t in tracked):
                continue
            out.append(
                f"{doc} cites `{cited}`, which is not in the tree (git ls-files "
                "does not know it). The record cannot cite a file nobody else can "
                "open: move it under scripts/probes/ or bench/ and cite that path, "
                "or drop the citation"
            )
    return out


# A capability row's STATUS, restated in prose. docs/SPEC.md is the source of
# truth for whether a row is verified, implemented, planned or out of scope,
# but pages elsewhere describe rows in passing -- "SPEC D9 (`planned`)" in a
# validation record's triage column, say -- and that sentence goes stale the
# moment the row is built. It did: D9 was gated and the record still called it
# planned and open, which is the most misleading kind of drift because the page
# reads as a live status board.
#
# Every other ratchet here covers a machine-sourced NUMBER. This one covers a
# claim, which is why it exists separately and why it is narrow: it fires only
# where prose presents a status as a token beside a row id -- backticked, or
# parenthesised -- and never on a status word that merely happens to be in the
# same sentence. The sheet itself is excluded, being the source.
_ROW_STATUS = re.compile(
    r"\b([A-Z]\d{1,2})\b"                      # a row id
    r"[^A-Za-z0-9\n]{0,4}"                      # a light connector: — , : is
    r"(?:is\s+|was\s+)?"
    r"(?:\(\s*`(verified|implemented|planned|out of scope)`\s*\)"   # (`x`)
    r"|`(verified|implemented|planned|out of scope)`"                # `x`
    r"|\(\s*(verified|implemented|planned|out of scope)\s*\))"      # (x)
)


def stale_row_statuses(docs, statuses):
    """Prose that gives a SPEC row a status the sheet disagrees with.

    `docs` maps path -> text; `statuses` maps row id -> the sheet's word. A
    pure function of both, so the selftest can hand it doctored inputs and
    `--sabotage` could revert the rule in memory.
    """
    out = []
    for path in sorted(docs):
        if path.endswith("SPEC.md"):
            continue
        for m in _ROW_STATUS.finditer(docs[path]):
            row = m.group(1)
            claimed = m.group(2) or m.group(3) or m.group(4)
            actual = statuses.get(row)
            if actual is None:
                out.append(f"{path} gives `{row}` the status `{claimed}`, and "
                           f"docs/SPEC.md has no row `{row}`")
            elif actual != claimed:
                out.append(f"{path} calls `{row}` `{claimed}`; docs/SPEC.md "
                           f"says `{actual}`")
    return out


def check_row_statuses_in_prose():
    """A page describing a SPEC row's status agrees with the sheet."""
    import spec_sheet

    rows, _ = spec_sheet.analyse(spec_sheet.read_sources())
    statuses = {r["id"]: r["status"] for r in rows}
    docs = {}
    for rel in PROSE:
        if (REPO / rel).exists():
            docs[rel] = (REPO / rel).read_text()
    for path in sorted((REPO / "docs").rglob("*.md")):
        docs[str(path.relative_to(REPO))] = path.read_text()
    for msg in stale_row_statuses(docs, statuses):
        fail(msg)


def check_docs_cite_tracked_paths():
    """Every `.claude/...` path the prose cites is tracked by git."""
    r = subprocess.run(["git", "-C", str(REPO), "ls-files"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return fail("check_docs_cite_tracked_paths: `git ls-files` failed, so "
                    "tracked paths cannot be told from untracked ones")
    tracked = set(filter(None, r.stdout.split("\n")))
    docs = {}
    for rel in PROSE:
        if (REPO / rel).exists():
            docs[rel] = (REPO / rel).read_text()
    for path in sorted((REPO / "docs").rglob("*.md")):
        docs[str(path.relative_to(REPO))] = path.read_text()
    for msg in untracked_citations(docs, tracked):
        fail(msg)


# The public benchmark page. A figure in its prose is either a span the
# renderer recomputes from the newest artifact, or sits in a block whose
# marker says where it was observed. Bare figures are how the page drifted:
# four hand-typed numbers, each correct when written, each outliving the
# artifact it described, one contradicting the span eight lines above it.
BENCH_PAGE = "docs/BENCHMARKS.md"

# Pages the bare-figure rule reads. It began as the benchmark page's rule
# alone, and the gap was found the way gaps like this always are: the
# roadmap's "Not planned, and why" section frames every refusal with the
# rps figures, and by 1.0.0 they were roughly half their true values
# (116k against 192k on the hello row, 61k against 81k on the executor)
# while the arguments resting on them stayed correct. The page had drifted
# BECAUSE it sat outside the rule -- nothing recomputed its numbers and
# nothing refused a hand-typed one. Adding a page here is the whole of the
# fix; the page's own figures then have to become spans or carry an
# `<!-- observed: WHERE -->` marker.
#
# Still outside, with their bare-figure counts at the time of writing:
# README.md (29), docs/SPEC.md (11), docs/RUNNING.md (3). Each is a real
# claim needing a span or a marker one at a time, so they are recorded
# here rather than half-done; `_page_figure_counts` in the selftest prints
# them, so the number cannot rot into a claim of its own.
FIGURE_PAGES = (BENCH_PAGE, "docs/ROADMAP.md")
_REGION = re.compile(
    r"<!-- generated: ([a-z0-9-]+) -- .*?-->.*?<!-- /generated: \1 -->", re.S)
_NUM_SPAN = re.compile(r"<!-- num:[a-z0-9-]+@\d -->.*?<!-- /num -->", re.S)
_OBSERVED = re.compile(r"<!-- observed\b(?::\s*(.*?))?\s*-->")
_UNITS = r"(?:µs|us|ms|ns|s|x|%|k|rps|cores?|bytes|KB|MB|GB)"
_FIGURE = re.compile(
    r"(?<![\w.\-/])~?\d[\d,]*(?:\.\d+)?"       # 1.44  ~100  1,638,400
    r"(?:\s*[–-]\s*\d[\d,]*(?:\.\d+)?)?"      # an optional range: 16–45
    r"\s?" + _UNITS + r"(?!\w)"                 # then a unit or multiplier
)
_ITEM = re.compile(r"\s*(?:[-*]|\d+\.)\s+")


def _blocks(lines):
    """(first line number, text) per paragraph or list item. A list item
    is its own block even with no blank line before it, so a marker on one
    bullet vouches for that bullet alone."""
    out, cur, start = [], [], None
    for n, line in enumerate(lines, 1):
        if not line.strip() or (_ITEM.match(line) and cur):
            if cur:
                out.append((start, "\n".join(cur)))
            cur, start = [], None
            if not line.strip():
                continue
        if not cur:
            start = n
        cur.append(line)
    if cur:
        out.append((start, "\n".join(cur)))
    return out


def unsourced_figures(text, page=BENCH_PAGE):
    """Pure: the page's text -> failure messages, one per bare figure.

    `page` names the file in the messages only; it is what lets one rule
    read several pages (FIGURE_PAGES) and still say which one is wrong.

    Generated regions and num spans are blanked first (the renderer checks
    those), then every remaining block is scanned for a number carrying a
    unit or multiplier. A block holding `<!-- observed: WHERE -->` is
    exempt -- the page's way of saying no artifact backs the figure and
    where it came from -- and a marker with no WHERE is itself a failure,
    because an unexplained exemption is a bare figure with extra steps.
    Versions, dates, counts and percentiles carry no unit and are not
    figures here; the selftest holds that line.
    """
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    text = _NUM_SPAN.sub(blank, _REGION.sub(blank, text))
    out = []
    for start, block in _blocks(text.split("\n")):
        marker = _OBSERVED.search(block)
        if marker:
            if not (marker.group(1) or "").strip():
                out.append(
                    f"{page}:{start}: an `<!-- observed: ... -->` marker "
                    "must say where the figure was observed (a note, an "
                    "artifact, a date); an unexplained exemption is a bare "
                    "figure with extra steps")
            continue
        for off, line in enumerate(block.split("\n")):
            for fig in _FIGURE.findall(line):
                out.append(
                    f"{page}:{start + off}: `{fig}` is a figure outside "
                    "any num span and any block marked `<!-- observed: ... -->`. "
                    "A number an artifact can compute is a span (add the "
                    "quantity to render_bench_docs.py's compute_quantities); "
                    "one no artifact backs sits in a block whose marker says "
                    "where it was observed")
    return out


def figures_in_pages(pages):
    """Pure: {page path: its text} -> every failure message, page by page.

    The wiring is a pure function of the mapping so the selftest can drive
    the SAME code the checker runs, with one page doctored. Testing
    `unsourced_figures` alone would only prove the scanner works -- which
    it did, on the one page it was pointed at, while the roadmap drifted
    beside it.
    """
    out = []
    for rel in sorted(pages):
        out.extend(unsourced_figures(pages[rel], rel))
    return out


def figure_page_texts(pages=FIGURE_PAGES):
    """The FIGURE_PAGES that exist, as {path: text}."""
    return {rel: (REPO / rel).read_text()
            for rel in pages if (REPO / rel).exists()}


def check_bench_prose_figures():
    """No bare figure in the prose of any FIGURE_PAGES page.

    The name still says `bench` because the 1.0.0 changelog entry that
    introduced the rule names it, and a record should keep pointing at
    something that exists. What it reads is the list, not one page.
    """
    for msg in figures_in_pages(figure_page_texts()):
        fail(msg)


# The decisions ledger. docs/DECISIONS.md is one row per standing decision
# about the application layer: a permanent id, the decision, where it is
# recorded, its status and what would retire it. The strategy that produced
# each row lives outside the tree; the ledger is what carries the constraint
# into it, so a session that never reads the strategy still meets it. The
# rules are the SPEC sheet's, applied to decisions: an id is assigned once
# and never reused, a claim names where it is recorded and that place
# exists, and a row that cannot say what would retire it is not a decision
# but an omission. Pure functions of text, so the selftest can revert each
# rule in memory and insist it is caught.
LEDGER = "docs/DECISIONS.md"
LEDGER_HEADER = "| id | decision | recorded in | status | retired by |"
_LEDGER_ID = re.compile(r"^D(\d+)$")
_LEDGER_STATUS = re.compile(
    r"^(?:standing|superseded by (D\d+)|retired (\d{4}-\d{2}-\d{2}))$")
_LEDGER_NOTE = re.compile(r"^\[[^\]]+\]\(notes/([A-Za-z0-9._-]+\.md)(?:#[^)]*)?\)$")
_LEDGER_CLAUDE = re.compile(r"^CLAUDE\.md: (.+)$")


def claude_headings(text):
    """The `##` and `###` heading texts of CLAUDE.md, for `CLAUDE.md: <heading>`."""
    return {m.group(1).strip() for m in re.finditer(r"^#{2,3} (.+)$", text, re.M)}


def _ledger_rows(text):
    """(line number, cells) for every row of every table under LEDGER_HEADER."""
    import spec_sheet

    rows = []
    in_table = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.strip() == LEDGER_HEADER:
            in_table = True
            continue
        if not in_table:
            continue
        if not line.startswith("|"):
            in_table = False
            continue
        if re.match(r"^\|\s*-+", line):
            continue
        rows.append((n, spec_sheet.split_cells(line)))
    return rows


def ledger_problems(text, notes, headings):
    """Pure: the ledger's text (None if the page is missing), the file names
    under docs/notes/, and CLAUDE.md's heading texts -> failure strings.

    Each rule is one a row can break on its own, and each has a sabotage in
    the selftest: five cells; an id `Dn` strictly greater than the row
    before it (which is both "never reused" and "never renumbered" as far
    as text can say); a decision in words; a `recorded in` that is a link
    to a note under docs/notes/ that exists, or `CLAUDE.md: <heading>` for
    a heading CLAUDE.md has; a status that is `standing`, `superseded by
    Dn` for a row in the table, or `retired YYYY-MM-DD`; and a retiring
    condition, where `—` is the explicit "none foreseeable" and an empty
    cell is the omission this exists to refuse.
    """
    where = LEDGER
    if text is None:
        return [f"{where} is missing. The application layer's standing "
                "decisions are ledgered there, and a page that is gone is "
                "every decision reopened at once"]
    rows = _ledger_rows(text)
    if not rows:
        return [f"{where} has no table headed `{LEDGER_HEADER}`; the ledger "
                "is read by that header and nothing else"]
    out = []
    ids = {}
    for n, cells in rows:
        if cells and _LEDGER_ID.match(cells[0]):
            ids.setdefault(cells[0], n)
    last = 0
    for n, cells in rows:
        at = f"{where}:{n}"
        if len(cells) != 5:
            out.append(f"{at}: a ledger row must be exactly 5 cells "
                       f"(id, decision, recorded in, status, retired by); "
                       f"got {len(cells)}")
            continue
        rid, decision, recorded, status, retire = cells
        m = _LEDGER_ID.match(rid)
        if not m:
            out.append(f"{at}: {rid!r} is not a decision id (`D` and a number)")
        else:
            num = int(m.group(1))
            if num <= last:
                out.append(
                    f"{at}: {rid} follows D{last}; ids are assigned once, "
                    "in order, and never reused — a new decision takes the "
                    "next number and a retired one keeps its line")
            last = max(last, num)
        if not decision.strip():
            out.append(f"{at}: {rid} has no decision in its decision cell")
        note = _LEDGER_NOTE.match(recorded)
        heading = _LEDGER_CLAUDE.match(recorded)
        if note:
            if note.group(1) not in notes:
                out.append(f"{at}: {rid} is recorded in `notes/{note.group(1)}`, "
                           "which does not exist under docs/notes/")
        elif heading:
            if heading.group(1).strip() not in headings:
                out.append(f"{at}: {rid} is recorded under CLAUDE.md heading "
                           f"{heading.group(1).strip()!r}, which CLAUDE.md "
                           "does not have")
        else:
            out.append(f"{at}: {rid}'s `recorded in` must be a link to a note "
                       "under docs/notes/ or `CLAUDE.md: <heading>`; got "
                       f"{recorded!r}")
        s = _LEDGER_STATUS.match(status)
        if not s:
            out.append(f"{at}: {rid}'s status must be `standing`, `superseded "
                       f"by Dn` or `retired YYYY-MM-DD`; got {status!r}")
        elif s.group(1):
            if s.group(1) not in ids:
                out.append(f"{at}: {rid} is superseded by {s.group(1)}, which "
                           "is not a row of the ledger")
            elif s.group(1) == rid:
                out.append(f"{at}: {rid} is superseded by itself")
        if not retire.strip():
            out.append(f"{at}: {rid} has no retiring condition. Write what "
                       "would reopen it, or `—` for none foreseeable; an "
                       "empty cell reads as a decision nobody can revisit")
    return out


def check_decisions_ledger():
    """docs/DECISIONS.md: every decision is recorded somewhere that exists,
    and says what would retire it."""
    path = REPO / LEDGER
    text = path.read_text() if path.exists() else None
    notes = {p.name for p in (REPO / "docs" / "notes").glob("*.md")}
    headings = claude_headings((REPO / "CLAUDE.md").read_text())
    for msg in ledger_problems(text, notes, headings):
        fail(msg)


def _ledger_cases():
    """The ledger rules reverted one at a time against the committed page.

    Each mutation is applied to the real docs/DECISIONS.md in memory, so a
    case that no longer matches the page (NOT APPLICABLE) fails the selftest
    rather than going quiet -- a rule renamed out of existence is the
    failure this is for. Returns (label, text, must_fire).
    """
    real = (REPO / LEDGER).read_text()
    lines = real.splitlines(keepends=True)
    first = next(i for i, l in enumerate(lines) if l.startswith("| D"))
    second = next(i for i, l in enumerate(lines) if l.startswith("| D") and i > first)
    row = lines[first]
    import spec_sheet
    cells = spec_sheet.split_cells(row)

    def with_cells(new_cells, at=first):
        edited = list(lines)
        edited[at] = "| " + " | ".join(new_cells) + " |\n"
        return "".join(edited)

    def swapped():
        edited = list(lines)
        edited[first], edited[second] = edited[second], edited[first]
        return "".join(edited)

    def duplicated():
        edited = list(lines)
        edited.insert(first + 1, row)
        return "".join(edited)

    dash_row = [c if i != 4 else "—" for i, c in enumerate(cells)]
    return [
        ("(control: the ledger as committed)", real, False),
        ("a decision recorded in a note that does not exist",
         real.replace("(notes/mojo-handler-pool.md)", "(notes/no-such-note.md)", 1), True),
        ("a decision recorded under a CLAUDE.md heading that does not exist",
         with_cells([c if i != 2 else "CLAUDE.md: A heading that is not there"
                     for i, c in enumerate(cells)]), True),
        ("(control: a CLAUDE.md heading that exists resolves)",
         with_cells([c if i != 2 else "CLAUDE.md: Runtime constraints"
                     for i, c in enumerate(cells)]), False),
        ("a recorded-in that is neither a note nor a heading",
         with_cells([c if i != 2 else "the design record"
                     for i, c in enumerate(cells)]), True),
        ("an empty retiring condition",
         with_cells([c if i != 4 else "" for i, c in enumerate(cells)]), True),
        ("(control: a dash is the explicit none)", with_cells(dash_row), False),
        ("an id used twice", duplicated(), True),
        ("an id out of order", swapped(), True),
        ("an id that is not a decision id",
         with_cells(["A1"] + cells[1:]), True),
        ("a status outside the three",
         with_cells([c if i != 3 else "pending" for i, c in enumerate(cells)]), True),
        ("superseded by an id that is not in the ledger",
         with_cells([c if i != 3 else "superseded by D99" for i, c in enumerate(cells)]), True),
        ("superseded by itself",
         with_cells([c if i != 3 else "superseded by " + cells[0]
                     for i, c in enumerate(cells)]), True),
        ("(control: superseded by a row that is here)",
         with_cells([c if i != 3 else "superseded by D2" for i, c in enumerate(cells)]), False),
        ("retired without a date",
         with_cells([c if i != 3 else "retired" for i, c in enumerate(cells)]), True),
        ("(control: retired on a date)",
         with_cells([c if i != 3 else "retired 2026-09-11"
                     for i, c in enumerate(cells)]), False),
        ("an empty decision cell",
         with_cells([c if i != 1 else "" for i, c in enumerate(cells)]), True),
        ("a row loses a cell", with_cells(cells[:4]), True),
        ("the table header is reworded",
         real.replace(LEDGER_HEADER, "| id | decision | where | status | retired by |", 1), True),
        ("the page is missing", None, True),
    ]


def selftest():
    """The citation rule must be able to fire: one doctored input per case."""
    tracked = {".claude/handoffs/soak-design.md", "scripts/probes/herd.c",
               ".claude/handoffs/kept/one.out"}
    cases = [
        ("a citation of an untracked draft",
         {"docs/notes/x.md": "measured with `.claude/handoffs/loop-user-space/herd.c` here"}, True),
        ("an untracked directory",
         {"docs/x.md": "raw outputs are in `.claude/handoffs/soak-2026-09-04/`."}, True),
        ("(control: a tracked file under .claude)",
         {"docs/x.md": "the design is `.claude/handoffs/soak-design.md`"}, False),
        ("(control: a directory with tracked files under it)",
         {"docs/x.md": "the kept outputs are in `.claude/handoffs/kept/`"}, False),
        ("(control: an area named on its own, nothing tracked under it)",
         {"CHANGELOG.md": "worktrees live in `.claude/worktrees/`"}, False),
        ("(control: a glob is a pattern, not a record)",
         {"CLAUDE.md": "test.yml ignores `*.md`, `docs/**` and `.claude/**`"}, False),
        ("an untracked file inside an area",
         {"docs/x.md": "the driver is `.claude/handoffs/soak-2026-09-04/bakerydemo-asgi.py`"}, True),
        ("(control: paths outside the watched roots are not this rule's)",
         {"docs/x.md": "checkouts under `/tmp/soak/`, and `scripts/nothing.py`"}, False),
    ]
    ok = True
    for label, docs, must_fire in cases:
        got = untracked_citations(docs, tracked)
        fired = bool(got)
        named = (not fired) or all(d in g for d in docs for g in got)
        good = fired == must_fire and named
        print(f"  {'caught' if good else 'MISSED'}          {label}" + ("" if good else f" -- got {got}"))
        ok &= good
    # The bare-figure rule: fires on a hand-typed figure, stays quiet for
    # a span, a generated region and a marked observation, and treats a
    # marker without a source as a failure of its own.
    figure_cases = [
        ("a bare figure in a paragraph",
         "the bridge costs 1.44x on the inline row\n", True),
        ("(control: the same figure inside a num span)",
         "the bridge costs <!-- num:bridge-tax@2 -->1.44<!-- /num -->x on the inline row\n", False),
        ("(control: a figure inside a generated region)",
         "<!-- generated: layer-split -- edit bench/results, not this table -->\n| row | 1.73 cores |\n<!-- /generated: layer-split -->\n", False),
        ("(control: a figure in a block that says where it was observed)",
         "<!-- observed: notes/detached-loop.md, 2026-09-04 -->\nthe loop was blocked 16–45 % of wall time\n", False),
        ("an observed marker with no source",
         "<!-- observed -->\nthe loop was blocked 16–45 % of wall time\n", True),
        ("an observed marker with an empty source",
         "<!-- observed: -->\nthe loop was blocked 16–45 % of wall time\n", True),
        ("a marker on one bullet does not cover the next",
         "- <!-- observed: pre-artifact, 2026-08 -->moves ~1.5x across sessions\n- an E-core serves 18.6k rps\n", True),
        ("a range with a unit",
         "it used to lose it at 0.83–0.90 cores\n", True),
        ("(control: versions, dates, counts and percentiles are not figures)",
         "CPython 3.13 and 3.14t, Granian 2.8.2, on 2026-09-05, at 256 connections, the p99 of HTTP/1.1, 4 workers, 2 sessions, `/slow?ms=200`\n", False),
    ]
    for label, text, must_fire in figure_cases:
        got = unsourced_figures(text)
        good = bool(got) == must_fire
        print(f"  {'caught' if good else 'MISSED'}          {label}" + ("" if good else f" -- got {got}"))
        ok &= good
    # COVERAGE, which is a different question from whether the scanner
    # works. The cases above would all have passed on the day the roadmap's
    # figures were half their true values, because the rule was only ever
    # pointed at one page. So: drive the real pages through the real
    # wiring, one doctored at a time, and insist the failure names the page
    # that was doctored. A page silently dropped from FIGURE_PAGES, or one
    # renamed on disk, fails here rather than going quiet.
    # The list's MEMBERSHIP is pinned here, because every case below
    # iterates FIGURE_PAGES: a page quietly removed from it would simply
    # stop being tested, which is the failure this whole block exists to
    # prevent. Add a page to the rule and to this set together.
    expected_pages = {"docs/BENCHMARKS.md", "docs/ROADMAP.md"}
    good = set(FIGURE_PAGES) == expected_pages
    print(f"  {'caught' if good else 'MISSED'}          "
          "(the pages the figure rule reads are the pages it is meant to)"
          + ("" if good else f" -- {sorted(set(FIGURE_PAGES))} != {sorted(expected_pages)}"))
    ok &= good
    real = figure_page_texts()
    for rel in FIGURE_PAGES:
        if rel not in real:
            print(f"  MISSED          {rel} is in FIGURE_PAGES and does not exist")
            ok = False
            continue
        doctored = dict(real)
        doctored[rel] = real[rel] + "\n\nthe handoff costs 1.44x per request\n"
        got = figures_in_pages(doctored)
        good = any(g.startswith(rel + ":") for g in got)
        print(f"  {'caught' if good else 'MISSED'}          a bare figure in {rel}"
              + ("" if good else f" -- got {got}"))
        ok &= good
    # And the list itself is load-bearing: revert the rule the way the
    # other doc rules are sabotaged -- drop a page from FIGURE_PAGES in
    # memory -- and the same doctored text must go unnoticed. Without this
    # the case above passes whether or not the page is really in the list.
    for rel in FIGURE_PAGES:
        if rel not in real:
            continue
        reverted = {k: v for k, v in real.items() if k != rel}
        reverted[rel + ".not-listed"] = (
            real[rel] + "\n\nthe handoff costs 1.44x per request\n")
        got = [g for g in figures_in_pages(reverted) if g.startswith(rel + ":")]
        good = not got
        print(f"  {'caught' if good else 'MISSED'}          "
              f"(sabotage: {rel} dropped from FIGURE_PAGES goes unnoticed)"
              + ("" if good else f" -- got {got}"))
        ok &= good
    # The pages still outside the rule, counted live so the number in
    # FIGURE_PAGES' comment cannot rot into a claim of its own. Printed,
    # never asserted: these are a backlog, not a failure.
    outside = {}
    for rel in ("README.md", "docs/SPEC.md", "docs/RUNNING.md"):
        if (REPO / rel).exists():
            outside[rel] = len(unsourced_figures((REPO / rel).read_text(), rel))
    print("  outside the rule: "
          + ", ".join(f"{k} ({v})" for k, v in sorted(outside.items())))
    # The row-status rule: fires when prose disagrees with the sheet, and the
    # controls matter more than usual here, because the rule reads ordinary
    # sentences rather than a generated region. A status word loose in a
    # sentence is not a claim about a row, and the sheet itself is the source
    # and never its own violation.
    status_sheet = {"D9": "verified", "L18": "verified", "C6": "out of scope"}
    status_cases = [
        ("prose calling a verified row planned",
         {"docs/x.md": "triage | **open** -- SPEC D9 (`planned`), gate-to-be"}, True),
        ("the same claim without backticks",
         {"docs/x.md": "SPEC D9 (planned) is the row"}, True),
        ("a row id that the sheet does not have",
         {"docs/x.md": "covered by Z99 (`verified`)"}, True),
        ("(control: a restatement that agrees)",
         {"docs/x.md": "D9 (`verified`) since 0.19.0"}, False),
        ("(control: an out-of-scope row said to be out of scope)",
         {"docs/x.md": "rate limiting is C6 (`out of scope`), a proxy's job"}, False),
        ("(control: a status word loose in a sentence is not a claim)",
         {"docs/x.md": "L18 keeps the refusal honest until the fix is `verified`"}, False),
        ("(control: the sheet itself is the source, not a violation)",
         {"docs/SPEC.md": "| D9 | the drain reads a body | planned | ... |"}, False),
    ]
    for label, docs, must_fire in status_cases:
        got = stale_row_statuses(docs, status_sheet)
        fired = bool(got)
        good = fired == must_fire
        print(f"  {'caught' if good else 'MISSED'}          {label}" + ("" if good else f" -- got {got}"))
        ok &= good
    # The decisions ledger: each rule reverted against the committed page.
    # The controls are as load-bearing as the sabotages -- a checker that
    # fails the real ledger, or a dash, or a valid supersession, is one
    # people learn to route around. A mutation that leaves the page
    # unchanged is NOT APPLICABLE and counts as MISSED, so a rule whose
    # anchor text is edited away fails here rather than going quiet.
    real_ledger = (REPO / LEDGER).read_text()
    notes = {p.name for p in (REPO / "docs" / "notes").glob("*.md")}
    headings = claude_headings((REPO / "CLAUDE.md").read_text())
    for label, text, must_fire in _ledger_cases():
        if must_fire and text == real_ledger:
            print(f"  MISSED          {label} -- NOT APPLICABLE, the mutation left the page unchanged")
            ok = False
            continue
        got = ledger_problems(text, notes, headings)
        good = bool(got) == must_fire
        print(f"  {'caught' if good else 'MISSED'}          {label}" + ("" if good else f" -- got {got}"))
        ok &= good
    print("check_docs selftest: " + ("PASS" if ok else "FAIL"))
    return ok


def main():
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    check_warning_counts()
    check_smoke_coverage()
    check_test_coverage()
    check_release_branches_cleaned()
    # The artifact consumers below are SKIPPED when the naming guard has
    # already failed. `fail()` only accumulates, so without this a malformed
    # artifact still reaches `_bench`, which either dies on a JSONDecodeError
    # traceback before main() can print anything, or -- worse, and the case
    # that matters -- succeeds against the wrong file and buries the real
    # cause under a list of prose-drift failures pointing at innocent
    # sentences. Both were observed while sabotaging the guard.
    _artifacts_ok = len(failures)
    check_bench_kinds_do_not_shadow()
    _artifacts_ok = len(failures) == _artifacts_ok
    if _artifacts_ok:
        check_bench_region()
    check_shim_rendered()
    check_version_single_source()
    check_wheel_platform_claims()
    check_m0pub_twins()
    check_hybrid_p99_consistent()
    check_target_cpu_pinned()
    check_consumer_jobs_stay_clean()
    check_pyproject_parses_for_consumers()
    check_test_counts()
    check_backend_seam()
    check_spec_sheet()
    check_required_context_intact()
    check_ci_measurements_are_collected()
    check_site_corpus()
    check_rfc_citations()
    check_docs_cite_tracked_paths()
    check_row_statuses_in_prose()
    check_decisions_ledger()
    check_bench_prose_figures()
    if failures:
        print("check-docs: FAIL")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("check-docs: every machine-sourced doc fact matches its source")


if __name__ == "__main__":
    main()
