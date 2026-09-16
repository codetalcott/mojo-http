#!/usr/bin/env python3
"""Why an app cannot conform to a trait in one of this repo's `.mojoc`s.

It is NOT that a trait cannot cross a precompiled package boundary, which is
what this file claimed from 2026-08-28 (`PoolHandler`) to 2026-09-15 and what
`HTTPService`, `PoolHandler` and the thin-function page shell (D12) were all
shaped around. **The discriminant is the package's NAME against the SOURCE
DIRECTORY it was compiled from.** Identical twelve-line code:

    src/pkg/      ->  pkg.mojoc     conformance compiles
    src/pkg_src/  ->  pkg.mojoc     "struct 'app::S' does not have witness
                                     table for trait 'pkg_src::lib::T'"

A trait's identity is recorded under the directory's name while a consumer
resolves it under the package's, and when those differ nothing matches. Every
package here runs `mojo precompile src -o <name>.mojoc`, so every one of them
has the mismatch -- and the error has been saying so all along:
`trait 'src::fragment::PageShell'`.

Fixed upstream: on Mojo nightly 1.2.0.dev2026091505 both spellings work. So
this check is a countdown to the pin moving, not a permanent limitation.

Four cases, because a one-armed probe is what let the wrong diagnosis stand
for three weeks:

    mismatch    an app conforming to `m0_http.fragment.PageShell`, whose
                package was built from `src/`               must be REFUSED
    match       the same shape in a synthetic package whose directory and
                package name agree                          must COMPILE
    control-x   that synthetic package rebuilt from a directory with a
                different name                              must be REFUSED
    control-v   `Views[S]` over an app type, a `.mojoc` generic over an app
                type, which has always worked               must COMPILE

`match` beside `control-x` is the whole argument: one source, two directory
names, opposite outcomes. `control-v` is what stops a stale or broken
`.mojoc` reading as the limitation.

The day `mismatch` and `control-x` compile, the toolchain has fixed it: this
exits 1, D12 can retire, `PageShell` becomes the API to prefer over the
thin-function shell, and `HTTPService`/`PoolHandler` no longer need to sit in
the source-resolved fork for this reason.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_SIBLING = Path(sys.executable).with_name("mojo")
MOJO = str(_SIBLING) if _SIBLING.exists() else (shutil.which("mojo") or "mojo")

MISMATCH = """
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

CONTROL_VIEWS = """
from m0_http import Views


struct Site(Movable):
    var title: String

    def __init__(out self):
        self.title = String("t")


def main() raises:
    var v = Views[Site]()
    print(v.route_count())
"""

# The synthetic pair: one source, compiled from two differently named
# directories into the same package name.
SYNTH_LIB = """
trait T:
    def f(self) -> Int:
        ...


def call[X: T](x: X) -> Int:
    return x.f()
"""

SYNTH_APP = """
from pkg.lib import T, call


struct S(T):
    def __init__(out self):
        pass

    def f(self) -> Int:
        return 1


def main() raises:
    print(call(S()))
"""


def compile_case(source: str, out_dir: Path, name: str, includes) -> tuple[bool, str]:
    src = out_dir / f"{name}.mojo"
    src.write_text(source)
    args = [MOJO, "build"]
    for inc in includes:
        args += ["-I", str(inc)]
    args += [str(src), "-o", str(out_dir / name)]
    proc = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    return proc.returncode == 0, proc.stderr


def build_synthetic(td: Path, dir_name: str) -> Path:
    """Precompile the synthetic package from `dir_name` into `pkg.mojoc`."""
    src = td / f"src_{dir_name}" / dir_name
    src.mkdir(parents=True)
    (src / "__init__.mojo").write_text("")
    (src / "lib.mojo").write_text(SYNTH_LIB)
    build = td / f"build_{dir_name}"
    build.mkdir()
    proc = subprocess.run(
        [MOJO, "precompile", str(src), "-o", str(build / "pkg.mojoc")],
        cwd=ROOT, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        first = proc.stderr.strip().splitlines()[:1]
        raise SystemExit(f"mojoc-trait: could not precompile the synthetic package: {first}")
    return build


def first_line(err: str) -> str:
    return err.strip().splitlines()[0] if err.strip() else ""


def main() -> int:
    pkgs = ["packages/m0-core/", "packages/m0-http/"]
    with tempfile.TemporaryDirectory() as td:
        out = Path(td)
        matched = build_synthetic(out, "pkg")
        mismatched = build_synthetic(out, "pkg_src")

        views_ok, views_err = compile_case(CONTROL_VIEWS, out, "control_views", pkgs)
        mismatch_ok, mismatch_err = compile_case(MISMATCH, out, "mismatch", pkgs)
        match_ok, match_err = compile_case(SYNTH_APP, out, "match", [matched])
        controlx_ok, controlx_err = compile_case(SYNTH_APP, out, "control_x", [mismatched])

    if not views_ok:
        print(f"mojoc-trait: CONTROL FAILED to compile (stale .mojoc?): {first_line(views_err)}")
        return 1

    if not match_ok:
        print("mojoc-trait: a package whose directory and name AGREE now refuses an "
              f"app conformance too: {first_line(match_err)}. The name is no longer "
              "the discriminant -- re-probe before trusting this file.")
        return 1

    if mismatch_ok and controlx_ok:
        print("mojoc-trait: the limitation has LIFTED -- a name mismatch no longer "
              "costs the witness table. Prefer PageShell over the thin-function "
              "shell in fragment.mojo (docs/DECISIONS.md D12), stop keeping "
              "app-facing traits in the fork for this reason, and retire this check.")
        return 1

    if mismatch_ok != controlx_ok:
        print(f"mojoc-trait: the two mismatched cases disagree (m0_http={mismatch_ok}, "
              f"synthetic={controlx_ok}) -- one of them is failing for another reason.")
        return 1

    for label, err in (("m0_http", mismatch_err), ("synthetic", controlx_err)):
        if "witness table" not in err:
            print(f"mojoc-trait: {label} refused, but not for the witness table: {first_line(err)}")
            return 1

    print("mojoc-trait: still present on this toolchain -- a package compiled from a "
          "directory named other than the package loses its traits' witness tables "
          "(m0_http is `src` -> `m0_http`); the same source from a matching "
          "directory compiles, and Views[S] over an app type compiles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
