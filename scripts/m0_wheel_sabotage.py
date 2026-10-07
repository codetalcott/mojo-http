#!/usr/bin/env python3
"""Revert each rule the `m0` wheel and CLI keep, and insist the smoke fails.

`host_sabotage.py`'s shape: each entry replaces one EXACT source block,
runs `poe smoke-m0-wheel` (which rebuilds the wheel from the edited source),
and restores the file. A rule is caught only if the smoke fails AND says
the expected thing -- a smoke that fails somewhere else has not shown that
the arm claiming the rule holds it, and is MISSED (failed elsewhere). Every
MISSED and NOT APPLICABLE (an anchor that does not match exactly once)
exits 1; re-point the anchor with the line. `sabotage_lib.py` owns
everything around the table: the baseline each gate must pass first, the
restore on SIGINT or SIGTERM, and the wheel rebuilt from the restored tree
at the end.

Rules the smoke's ARMS hold run with `M0_SMOKE_SKIP_UNIT=1`: the unit tests
come first in the smoke and would catch several of these on their own,
which is a catch, but not the one being asked about -- "does the refusal
arm fail when its check is reverted?" The rules only a unit test can hold
(a platform nothing here runs on, a doctor format from another m0) run
with the unit phase on, and say so.

Not here, and why:

- The build RENAMED onto `bin/server` rather than written with `-o`.
  MEASURED as missed on macOS: mojo 1.1.0's link step replaces an existing
  output itself (a new inode; the old one's bytes intact, read through a
  hard link), so a server running the old binary survives either way and
  the smoke's live-server and old-inode assertions both pass with the rule
  reverted. The premise "a killed process on macOS" did not reproduce.
  Linux (ETXTBSY) is not measured here. The rename stays because it does
  not depend on what a linker does with its output, and the assertions
  stay because they hold the OUTCOME on every leg; what is not claimed is
  that they hold the mechanism.
- `--release` compiling for the HOST rather than the baseline. The artifact
  works where it was built, which is where this runs; no gate on one
  machine can see it. `check_target_cpu_pinned`'s reasoning, unguarded for
  the CLI, and said so in SPEC N24.
- `--release` without `relocate.py`. MEASURED as missed: `bundle_artifact.py`
  strips foreign search paths from what it bundles too (the "belt" the
  image's Dockerfile mentions), so the smoke's rpath assertion still holds.
  The call stays because it is the image recipe's, not because it is gated.

    uv run poe sabotage-m0-wheel
    uv run poe sabotage-m0-wheel --only "own prefix"    one rule, by label substring
"""

import sys

from sabotage_lib import POE, Command, run, run_command, rule

M0 = "packaging/m0/src/m0/"
ARM, UNIT = "arm", "unit"

# (label, file, old, new, the smoke must say, which phase holds it)
SABOTAGES = [
    ("own prefix: mojo from PATH",
     M0 + "paths.py",
     '    return prefix() / "bin" / "mojo"\n',
     '    import shutil\n    return Path(shutil.which("mojo") or "/nonexistent")\n',
     "not the one in its own prefix", ARM),
    ("mojo-gated reverted",
     M0 + "checks.py",
     "    if installed not in gated:\n",
     "    if False:\n",
     "m0 build beside mojo 9.9.9", ARM),
    ("the foreign-prefix question reverted",
     M0 + "checks.py",
     "    if project_venv_has_mojo and not in_project_venv:\n",
     "    if False:\n",
     "a foreign m0 in the project", ARM),
    ("mojo-installed reverted",
     M0 + "checks.py",
     "    if installed is None or not binary_exists:\n",
     "    if False:\n",
     "m0 build with no mojo", ARM),
    ("c-compiler: a missing cc passes",
     M0 + "checks.py",
     "    if cc is None:\n        if other:\n",
     "    if False:\n        if other:\n",
     "m0 build with no cc", ARM),
    ("c-compiler: gcc is accepted for cc",
     M0 + "checks.py",
     '    cc = shutil.which("cc")\n',
     '    cc = shutil.which("cc") or shutil.which("gcc")\n',
     "m0 build with gcc and no cc", ARM),
    ("c-compiler: no link test",
     M0 + "checks.py",
     "    if link_error:\n",
     "    if False:\n",
     "m0 build with a cc that cannot link", ARM),
    ("project reverted",
     M0 + "checks.py",
     "    if (project / paths.ENTRY).is_file():\n",
     "    if True:\n",
     "m0 build outside a project", ARM),
    ("m0 test asks for a C compiler",
     M0 + "test.py",
     '    failed = checks.preflight(project, skip=("c-compiler",))\n',
     "    failed = checks.preflight(project)\n",
     "m0 test with no cc on PATH", ARM),
    ("m0 test passes having tested nothing",
     M0 + "test.py",
     "            return checks.REFUSED\n",
     "            return 0\n",
     "m0 test with no tests", ARM),
    ("the doctor swallows the app's exit",
     M0 + "doctor.py",
     '        return app["exit"]\n',
     "        return 0\n",
     "m0 doctor -- --workers 0", ARM),
    ("the doctor never says stale",
     M0 + "doctor.py",
     '        "stale": _stale(project, binary),\n',
     '        "stale": False,\n',
     "does not say stale", ARM),
    ("the release bundles no runtime",
     M0 + "build.py",
     '        if _tool(project, "bundle_artifact.py", "--layout", "flat", str(rel),\n'
     "                 str(stage.relative_to(project))) != 0:\n"
     "            return 1\n",
     '        os.replace(project / rel, stage / "server")\n',
     "no Mojo runtime was bundled", ARM),
    ("the wheel drops a tree",
     "packaging/m0/hatch_build.py",
     '    "packages/m0-datastar/src": "m0_datastar",\n',
     "",
     "not the mapped git ls-files set", ARM),
    ("the wheel drops the storage trees",
     "packaging/m0/hatch_build.py",
     '    "packages/m0-sqlite/src": "m0_sqlite",\n',
     "",
     "not the mapped git ls-files set", ARM),
    ("max-gated reverted",
     M0 + "checks.py",
     "    if installed != gated[0]:\n",
     "    if False:\n",
     "m0 build beside max-core 9.9.9", ARM),
    ("gated_max is written, not read from the root's max group",
     "packaging/m0/hatch_build.py",
     '            "gated_max": gated_max(root_text),\n',
     '            "gated_max": ["1.0.0"],\n',
     "gated_max is", ARM),
    ("the wheel walks the directory instead of git's manifest",
     "packaging/m0/hatch_build.py",
     '            files = [f for f in _git("ls-files", "-z", "--", tree).split("\\0") if f]\n',
     "            files = [str(p.relative_to(ROOT)) for p in (ROOT / tree).rglob('*') if p.is_file()]\n",
     "an untracked file in a source tree shipped", ARM),
    ("the wheel drops binfmt",
     "packaging/m0/hatch_build.py",
     'TOOLS = ["scripts/relocate.py", "scripts/bundle_artifact.py", "scripts/binfmt.py"]\n',
     'TOOLS = ["scripts/relocate.py", "scripts/bundle_artifact.py"]\n',
     "m0/_tools/ holds", ARM),
    ("gated_mojo is written, not read from the root pin",
     "packaging/m0/hatch_build.py",
     '            "gated_mojo": gated_mojo(root_text),\n',
     '            "gated_mojo": ["1.0.0"],\n',
     "gated_mojo is", ARM),
    ("M0_WHEEL_LOCAL is ignored",
     "packaging/m0/hatch_version.py",
     '    local = os.environ.get("M0_WHEEL_LOCAL", "")\n',
     '    local = ""\n',
     "carries no local label", ARM),
    ("the wheel depends on mojo",
     "packaging/m0/pyproject.toml",
     "dependencies = []\n",
     'dependencies = ["mojo==1.1.0"]\n',
     "declares a dependency", ARM),
    ("platform reverted (unit)",
     M0 + "checks.py",
     '    what = f"{system} {machine}" + (f" {libc}" if system == "linux" else "")\n',
     '    return Result("platform", True, system)\n'
     '    what = f"{system} {machine}" + (f" {libc}" if system == "linux" else "")\n',
     "test_m0.py failed", UNIT),
    ("another doctor format is half-read (unit)",
     M0 + "doctor.py",
     '    if report["m0_host"] != HOST_FORMAT:\n',
     "    if False:\n",
     "test_m0.py failed", UNIT),
    ("--release --target-cpu native is accepted (unit)",
     M0 + "cli.py",
     '    if args.command == "build" and args.release and args.target_cpu == "native":\n',
     "    if False:\n",
     "test_m0.py failed", UNIT),
    ("a default taken names no other template (unit)",
     M0 + "new.py",
     "    if args.template is None:\n",
     "    if False:\n",
     "test_m0.py failed", UNIT),
]


def _said(out: str) -> str:
    """The smoke's own last word: its last `smoke-m0-wheel:` line."""
    line = [ln for ln in out.splitlines() if ln.startswith("smoke-m0-wheel:")]
    return line[-1][:200] if line else "(no line of the smoke's own)"


# Named for what they run, so `--only unit` still selects by label: the
# four unit-held rules say "(unit)". A rule the smoke's ARMS hold runs with
# the unit phase off; one only a unit test can hold, with it on.
GATES = {
    ARM: "smoke-m0-wheel",
    UNIT: "smoke-m0-wheel (unit phase on)",
}
_SKIP_UNIT = {ARM: "1", UNIT: None}

RULES = [rule(label, rel, old, new, gate=GATES[holder], expect=want)
         for label, rel, old, new, want, holder in SABOTAGES]


def finish(interrupted: bool) -> bool:
    """Leave `dist/m0` holding a wheel of the restored tree: the smoke built
    the last one from a sabotaged source."""
    if interrupted:
        print("dist/m0 may still hold a sabotaged wheel: run `uv run poe build-m0-wheel`",
              flush=True)
        return False
    built = run_command([POE, "build-m0-wheel"], timeout=1800)
    if built.returncode != 0:
        print("rebuilding the wheel from the restored tree FAILED", flush=True)
        return False
    return True


def main(argv: list[str]) -> int:
    gates = {GATES[h]: Command([POE, "smoke-m0-wheel"], passes="smoke-m0-wheel OK",
                               env={"M0_SMOKE_SKIP_UNIT": _SKIP_UNIT[h]}, timeout=3600,
                               detail=_said)
             for h in GATES}
    return run("sabotage-m0-wheel", RULES, gates, argv, finish=finish)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
