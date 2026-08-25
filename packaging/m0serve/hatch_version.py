"""Read the version from the repository, and refuse to build if it has drifted.

The repo keeps exactly two copies of the version -- `version` in the root
pyproject.toml and `M0SERVE_VERSION` in packages/m0-wsgi/src/cli.mojo -- and
`poe smoke-serve` asserts they agree. docs/RELEASING.md's rule is that nothing
else may add a third, so the wheel derives its version rather than declaring
one.

Cross-checking here rather than only trusting the root is not redundancy for
its own sake: it fails at BUILD time, before a wheel exists, where
`smoke-serve` needs a compiled binary and runs much later. A drifted version
that reaches PyPI cannot be corrected in place -- the filename is burned.
"""

import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read_version():
    pyproject = ROOT / "pyproject.toml"
    cli = ROOT / "packages" / "m0-wsgi" / "src" / "cli.mojo"

    declared = tomllib.loads(pyproject.read_text())["project"]["version"]
    match = re.search(r'comptime M0SERVE_VERSION = "([^"]+)"', cli.read_text())
    if match is None:
        raise RuntimeError(
            f"{cli} no longer declares M0SERVE_VERSION — the wheel version "
            "cannot be cross-checked, so it is not safe to build one"
        )
    if match.group(1) != declared:
        raise RuntimeError(
            f"version drift: {pyproject} says {declared!r} but "
            f"{cli} says {match.group(1)!r}. Fix both before building a wheel."
        )
    return declared
