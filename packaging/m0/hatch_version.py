"""Read the wheel's version from its one home, `src/m0/__init__.py`.

`m0` is versioned apart from the repository (docs/DECISIONS.md D43): the
root pyproject's version is m0serve's served contract, and the Mojo API this
wheel carries does not have that stability yet. So nothing here reads the
root; the tree the wheel was cut from is recorded in `_build_info.json`
instead.

`M0_WHEEL_LOCAL=tree` appends a PEP 440 local label (`0.1.0+tree`). The
smokes build with it so that an exact pin on the result can never be
satisfied by a PUBLISHED wheel of the same number -- an index cannot serve a
local version.
"""

import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent


def read_version():
    init = HERE / "src" / "m0" / "__init__.py"
    match = re.search(r'^__version__ = "([^"]+)"$', init.read_text(), re.M)
    if match is None:
        raise RuntimeError(
            f"{init} no longer declares __version__ — the wheel has no version"
        )
    version = match.group(1)
    local = os.environ.get("M0_WHEEL_LOCAL", "")
    if local:
        if not re.fullmatch(r"[a-z0-9]+(\.[a-z0-9]+)*", local):
            raise RuntimeError(
                f"M0_WHEEL_LOCAL={local!r} is not a PEP 440 local label "
                "(lowercase letters and digits, dot-separated)"
            )
        version = f"{version}+{local}"
    return version
