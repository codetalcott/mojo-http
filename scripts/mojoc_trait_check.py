#!/usr/bin/env python3
"""A trait defined in a precompiled package cannot be conformed to by an app.

Observed twice on Mojo 1.0.0 (`PoolHandler`, 2026-08-28; `PageShell`,
2026-09-10), both times with the generic consumer inside the same
`.mojoc`: the app's conformance is accepted and the witness table is
never emitted -- "struct 'X' does not have witness table for trait". It is
why `HTTPService` and `PoolHandler` live in the source-resolved fork and
why `page_or_fragment` takes a `thin` function over a context instead of
a `PageShell`.

That is a claim about the toolchain, generalised from two experiments, and
the repo's rule for such claims is a probe that can flip. This compiles
two programs against the built packages, like `sabotage_views.py`:

    limitation   an app struct conforming to `m0_http.fragment.PageShell`,
                 passed to the `.mojoc` generic `wrap_with`        must be REFUSED
    control      the same struct as the state type of `Views[S]`,
                 a `.mojoc` generic over an app type                must COMPILE

The control is what stops a stale `.mojoc` reading as the limitation. The
day the first case compiles, this exits 1 saying so: `PageShell` becomes
the API to prefer and the thin-function shell can go.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_SIBLING = Path(sys.executable).with_name("mojo")
MOJO = str(_SIBLING) if _SIBLING.exists() else (shutil.which("mojo") or "mojo")

LIMITATION = """
from m0_http.fragment import PageShell, wrap_with


struct Site(PageShell):
    var title: String

    def __init__(out self):
        self.title = String("t")

    def wrap(self, fragment: String) raises -> String:
        return String(self.title, fragment)


def main() raises:
    print(wrap_with(Site(), String("f")))
"""

CONTROL = """
from m0_http import Views


struct Site(Movable):
    var title: String

    def __init__(out self):
        self.title = String("t")


def main() raises:
    var v = Views[Site]()
    print(v.route_count())
"""


def compile_case(source: str, out_dir: Path, name: str) -> tuple[bool, str]:
    src = out_dir / f"{name}.mojo"
    src.write_text(source)
    proc = subprocess.run(
        [MOJO, "build", "-I", "packages/m0-core/", "-I", "packages/m0-http/",
         str(src), "-o", str(out_dir / name)],
        cwd=ROOT, capture_output=True, text=True,
    )
    return proc.returncode == 0, proc.stderr


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        out = Path(td)
        control_ok, control_err = compile_case(CONTROL, out, "control")
        limit_ok, limit_err = compile_case(LIMITATION, out, "limitation")
    if not control_ok:
        first = control_err.strip().splitlines()[0] if control_err.strip() else ""
        print(f"mojoc-trait: CONTROL FAILED to compile (stale .mojoc?): {first}")
        return 1
    if limit_ok:
        print("mojoc-trait: the limitation has LIFTED -- an app conformance to a "
              "trait in a .mojoc now compiles. Prefer PageShell over the "
              "thin-function shell in fragment.mojo, and retire this check.")
        return 1
    if "witness table" not in limit_err:
        first = limit_err.strip().splitlines()[0] if limit_err.strip() else ""
        print(f"mojoc-trait: refused, but not for the witness table: {first}")
        return 1
    print("mojoc-trait: still present -- an app conformance to a .mojoc trait "
          "has no witness table; the control over Views[S] compiles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
