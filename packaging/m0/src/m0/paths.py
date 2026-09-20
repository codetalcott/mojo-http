"""Where things are: the framework's source, the tools, the toolchain.

Nothing else in the package spells one of these paths. Two of them are
rules rather than conveniences:

- **`mojo_bin()` is `<sys.prefix>/bin/mojo`, never `PATH`'s.** The pair the
  wheel was gated on is checked against the `mojo` distribution installed in
  m0's OWN environment, so the binary that runs has to be that
  distribution's; a global `mojo` earlier on `PATH` would be a different
  compiler passing a check made about another.
- **`include_root()` is found from this file**, so it is right wherever the
  wheel is installed. `m0/_mojo` is unrelated to the toolchain's own
  top-level `_mojo` package in the same site-packages; nothing may
  hard-code either, which is what `m0 include` is for.
"""

import json
import os
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent

# The paths a project is held to. `m0 build` takes no `-o`: these are the
# contract the image stage and `m0 doctor` rely on.
ENTRY = Path("src") / "server.mojo"
BINARY = Path("bin") / "server"
BINARY_NEXT = Path("bin") / ".server.next"
RELEASE_DIR = Path("dist")


def include_root():
    return PACKAGE / "_mojo"


def tools_dir():
    return PACKAGE / "_tools"


def prefix():
    return Path(sys.prefix)


def mojo_bin():
    return prefix() / "bin" / "mojo"


def toolchain_env(extra=None):
    """The environment mojo runs in: ours, with the prefix's `bin` first.

    mojo itself is always run by absolute path (above). This is for what
    mojo looks up by NAME beside itself -- its crash handler, `lld` -- which
    it finds when a venv is activated and misses, noisily, when m0 was run
    as `.venv/bin/m0`.
    """
    env = dict(os.environ)
    env["PATH"] = str(prefix() / "bin") + os.pathsep + env.get("PATH", "")
    env.update(extra or {})
    return env


def build_info():
    """What the wheel's build recorded (packaging/m0/hatch_build.py)."""
    return json.loads((PACKAGE / "_build_info.json").read_text())
