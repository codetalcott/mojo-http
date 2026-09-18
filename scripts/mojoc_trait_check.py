#!/usr/bin/env python3
"""An app CAN conform to a trait in one of this repo's `.mojoc`s — now.

This file spent three weeks holding the wrong diagnosis and then a week
counting down to the right one. Both halves are worth keeping, because what
it guards is a property the tree stopped being able to assume once and could
lose again.

**It was never that a trait cannot cross a precompiled package boundary**,
which is what this file claimed from 2026-08-28 (`PoolHandler`) to
2026-09-15, and what `HTTPService`, `PoolHandler`, the thin-function page
shell (D12) and the host's placement in the fork (D28) were all shaped
around. The discriminant was the package's NAME against the SOURCE
DIRECTORY it was compiled from. Identical twelve-line code, on Mojo 1.0.0:

    src/pkg/      ->  pkg.mojoc     conformance compiled
    src/pkg_src/  ->  pkg.mojoc     "struct 'app::S' does not have witness
                                     table for trait 'pkg_src::lib::T'"

A trait's identity was recorded under the directory's name while a consumer
resolved it under the package's, and when those differed nothing matched.
Every package here runs `mojo precompile src -o <name>.mojoc`, so every one
of them had the mismatch -- and the error had been saying so all along:
`trait 'src::fragment::PageShell'`.

**Fixed in Mojo 1.1.0**, which this repo pinned on 2026-09-18. All four arms
below compile there, and this check now fails if any of them stops:

    mismatch    an app conforming to `m0_http.PageShell` and passing the
                conformance through `page_or_fragment`, the real API,
                from a package built from `src/`            must COMPILE
    match       the same shape in a synthetic package whose directory and
                package name agree                          must COMPILE
    control-x   that synthetic package rebuilt from a directory with a
                different name                              must COMPILE
    control-v   `Views[S]` over an app type, a `.mojoc` generic over an app
                type, which has always worked               must COMPILE

`mismatch` and `control-x` name the SHAPE, not the outcome: both are a
package whose name differs from its directory, which is the case that used
to be refused. They are kept apart because `mismatch` is the real
`m0_http`, built by `build-http`, while `control-x` is twelve synthetic
lines -- so a failure in one and not the other says whether the problem is
the toolchain or this tree.

A failure here is not cosmetic. It means the constraint behind D12, D28 and
D7 is back, `PageShell` can no longer be an app-facing trait, `page_or_fragment`
goes back to a `thin` function over a context, and anything moved out of
the fork on the strength of the fix has to go back. Say so in
the failure, because the next session will not have read this.
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
from lightbug_http.uri import URI
from lightbug_http.http import HTTPRequest

from m0_http import PageShell, page_or_fragment


struct Site(PageShell):
    var title: String

    def __init__(out self):
        self.title = String("t")

    def wrap(self, fragment: String) raises -> String:
        return String(self.title, fragment)


def main() raises:
    var req = HTTPRequest(URI.parse("http://127.0.0.1/"))
    print(page_or_fragment(req, String("f"), Site()).status_code)
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


# The toolchain prints this on every invocation in a venv without its crash
# handler, on stderr, before anything real. Left in, it is what every failure
# message here reports instead of the compiler error -- measured while
# null-casing the flipped check.
_NOISE = ("Failed to initialize Crashpad",)


def first_line(err: str) -> str:
    """The first line of `err` that is a compiler diagnostic, not noise."""
    for line in err.strip().splitlines():
        if line.strip() and not any(n in line for n in _NOISE):
            return line
    return ""


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
        print("mojoc-trait: a package whose directory and name AGREE refuses an app "
              f"conformance: {first_line(match_err)}. That is broken beyond the "
              "name-mismatch bug this file is about -- re-probe from scratch.")
        return 1

    # The regression this exists for. Either mismatched arm refusing means the
    # 1.1.0 fix is gone on this toolchain.
    regressed = [
        (label, err)
        for label, ok, err in (
            ("m0_http (the real package, from `src`)", mismatch_ok, mismatch_err),
            ("synthetic (twelve lines, from a renamed directory)", controlx_ok, controlx_err),
        )
        if not ok
    ]
    if regressed:
        print("mojoc-trait: REGRESSED -- a package compiled from a directory named "
              "other than the package has lost its traits' witness tables again.")
        for label, err in regressed:
            print(f"  {label}: {first_line(err)}")
        if len(regressed) == 1:
            print("  Only one of the two arms refused, so this may be this tree "
                  "rather than the toolchain -- compare them before concluding.")
        print("  What this costs: the constraint behind DECISIONS D7, D12 and D28 "
              "is back. `page_or_fragment` cannot take a `PageShell` and has to "
              "go back to a `thin` function over a context, app-facing traits "
              "belong in the source-resolved fork, and anything moved out of it "
              "on the strength of Mojo 1.1.0 has to go back.")
        return 1

    print("mojoc-trait: an app conforms to a trait in a `.mojoc` whatever the "
          "source directory is named -- the real m0_http (`src` -> `m0_http`), "
          "the synthetic pair both ways, and Views[S] over an app type all "
          "compile (refused before Mojo 1.1.0)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
