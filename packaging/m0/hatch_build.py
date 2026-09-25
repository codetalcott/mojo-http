"""Map the framework's source into the wheel, straight from git's manifest.

Nothing is staged or copied on disk. For each of the seven source trees an
application compiles against, `git ls-files` names the files and each one is
force-included under `m0/_mojo/<import name>/` -- the tree's root renamed to
the name Mojo imports it by, so ONE `-I <site-packages>/m0/_mojo` resolves
all seven from source, with no `.mojoc` anywhere (docs/DECISIONS.md D39).
The two storage packages ride because both open their C library at run time
(SPEC O17 for libsqlite3, libpq likewise): `m0 build` takes no link flag and
`m0 test`'s `mojo run` resolves nothing from its own image, so a package
that LINKED its library could not ship here (D49).

Why `git ls-files` and not a directory walk with an exclude list: the
manifest is the tree's own. A `__pycache__`, a stray `.mojoc`, an untracked
scratch file cannot ship, and a tracked file cannot be dropped, with no list
here to rot. The cost is stated rather than hidden: no git, no wheel.
`smoke-m0-wheel` holds the result to the same manifest from outside.

The hook also writes `m0/_build_info.json`. `gated_mojo` is READ from the
root pyproject's `mojo==X` -- the pin CI ran every gate on -- and anything
but one exact `==` is refused: the CLI compares the installed toolchain to
this by string equality, so a range here would be a table nobody gated.
`gated_max` is read the same way from the root's `max` dependency group,
the one `smoke-parallel-runtime` syncs (SPEC E32): MAX is optional beside
an application, and when it is present it must be the version the host
was gated beside, because `max-core` pins its own `mojo-compiler` exactly.
"""

import json
import re
import shutil
import subprocess
import tempfile
import tomllib
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

ROOT = Path(__file__).resolve().parents[2]

# tree in the repository -> the name Mojo imports it by
TREES = {
    "packages/m0-core/src": "m0_core",
    "packages/m0-http/src": "m0_http",
    "packages/m0-http/lightbug_http": "lightbug_http",
    "packages/m0-http/m0_host": "m0_host",
    "packages/m0-datastar/src": "m0_datastar",
    "packages/m0-sqlite/src": "m0_sqlite",
    "packages/m0-postgres/src": "m0_postgres",
}

# Three, not two: relocate.py and bundle_artifact.py both import binfmt.
# Unedited, and run by the CLI as subprocesses, so their sibling imports hold.
TOOLS = ["scripts/relocate.py", "scripts/bundle_artifact.py", "scripts/binfmt.py"]

LICENSES = {
    "LICENSE": "LICENSE.mojo-http.txt",
    "licenses/LICENSE.lightbug_http.txt": "LICENSE.lightbug_http.txt",
}


def _git(*args):
    try:
        done = subprocess.run(
            ["git", "-C", str(ROOT), *args], capture_output=True, text=True
        )
    except FileNotFoundError:
        raise RuntimeError(
            "git is not installed: the m0 wheel's contents are `git ls-files` "
            "of the source trees, so it cannot be built without git"
        )
    if done.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed in {ROOT}: {done.stderr.strip()} — "
            "the m0 wheel is built from a git checkout, never an export"
        )
    return done.stdout


def gated_mojo(pyproject_text):
    """The root pin, as the one-entry list the CLI compares against."""
    deps = tomllib.loads(pyproject_text)["project"]["dependencies"]
    pins = [d for d in deps if re.match(r"mojo\b", d.strip())]
    if len(pins) != 1:
        raise RuntimeError(
            f"the root pyproject names mojo {len(pins)} times in "
            "[project].dependencies; the m0 wheel is gated on exactly one pin"
        )
    match = re.fullmatch(r"mojo==(\d+(?:\.\d+)*)", pins[0].strip())
    if match is None:
        raise RuntimeError(
            f"the root pyproject pins {pins[0]!r}; the m0 wheel records the "
            "toolchain it was gated on, which needs an exact `mojo==X`"
        )
    return [match.group(1)]


def gated_max(pyproject_text):
    """The root's `max` dependency group, as the one-entry list the CLI
    compares an installed `max-core` against. Exactly one exact pin, for
    `gated_mojo`'s reason."""
    groups = tomllib.loads(pyproject_text).get("dependency-groups", {})
    pins = [d for d in groups.get("max", []) if isinstance(d, str)]
    if len(pins) != 1:
        raise RuntimeError(
            f"the root pyproject's [dependency-groups] max names {len(pins)} "
            "entries; the m0 wheel is gated beside exactly one max-core pin"
        )
    match = re.fullmatch(r"max-core==(\d+(?:\.\d+)*)", pins[0].strip())
    if match is None:
        raise RuntimeError(
            f"the root pyproject's max group pins {pins[0]!r}; the m0 wheel "
            "records the MAX it was gated beside, which needs an exact "
            "`max-core==X`"
        )
    return [match.group(1)]


class CustomBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version, build_data):
        include = build_data["force_include"]

        for tree, name in TREES.items():
            files = [f for f in _git("ls-files", "-z", "--", tree).split("\0") if f]
            if not files:
                raise RuntimeError(f"git ls-files names nothing under {tree}")
            for rel in files:
                src = ROOT / rel
                if not src.is_file():
                    raise RuntimeError(
                        f"{rel} is tracked but missing from the working tree"
                    )
                inside = Path(rel).relative_to(tree).as_posix()
                include[str(src)] = f"m0/_mojo/{name}/{inside}"

        for rel in TOOLS:
            include[str(ROOT / rel)] = f"m0/_tools/{Path(rel).name}"
        for rel, name in LICENSES.items():
            include[str(ROOT / rel)] = f"m0/licenses/{name}"

        root_text = (ROOT / "pyproject.toml").read_text()
        info = {
            "format": 1,
            "m0": self.metadata.version,
            "gated_mojo": gated_mojo(root_text),
            "gated_max": gated_max(root_text),
            "framework": tomllib.loads(root_text)["project"]["version"],
            "commit": _git("rev-parse", "HEAD").strip(),
            "dirty": bool(_git("status", "--porcelain").strip()),
        }
        self._scratch = tempfile.mkdtemp(prefix="m0-build-info-")
        path = Path(self._scratch) / "_build_info.json"
        path.write_text(json.dumps(info) + "\n")
        include[str(path)] = "m0/_build_info.json"

    def finalize(self, version, build_data, artifact_path):
        shutil.rmtree(getattr(self, "_scratch", ""), ignore_errors=True)
