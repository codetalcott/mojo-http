#!/usr/bin/env python3
"""A reading view must not compile if it writes.

`Views.add_read` hands the state to a view BORROWED and `add_write` hands
it `mut`. That is the one thing this design gains over the Python it was
translated from, and it is a claim about what the compiler refuses — which
no passing test can demonstrate, because the counter-example is a file that
does not build.

So this is the shape `shim_ownership.py --sabotage` and `sabotage-spec`
use: state the rule, break it, and insist the toolchain notices. Three
cases, each compiled for real:

    control     a reading view that only reads          must COMPILE
    sabotage    the same view, writing to the state     must FAIL
    control     the same write, registered add_write    must COMPILE
    sabotage    a `mut` view handed to add_read         must FAIL

The third case is what stops the second passing for the wrong reason. If
`add_write` had the same borrowed signature, case two would fail and this
script would call it a win while the whole split did nothing. It has
already earned its keep once: with a stale `m0_http.mojoc` in the tree
every case failed to compile, and without the controls case two would
have read as a pass.

The fourth closes the other direction — the two tables must not accept
each other's views, or the split is a naming convention rather than a
type.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The compiler beside this interpreter, never a bare `mojo`: under `poe
# canary` a child that reaches a different `mojo` than the venv's reports a
# nightly break as ".mojoc is newer than the compiler", and here that is
# every case failing to build — which only the two controls would surface.
# Same block as trailer_sabotage.py, pool_sabotage.py and fuzz_sabotage.py.
_SIBLING = Path(sys.executable).with_name("mojo")
MOJO = str(_SIBLING) if _SIBLING.exists() else (shutil.which("mojo") or "mojo")

PROGRAM = """
from lightbug_http.http import HTTPRequest, HTTPResponse
from m0_http import reply
from m0_http.views import Views


struct St(Movable):
    var n: Int

    def __init__(out self):
        self.n = 0


def a_view(req: HTTPRequest, params: List[String], {mut}st: St) raises -> HTTPResponse:
{body}
    return reply.html(String("ok"))


def main() raises:
    var v = Views[St]()
    v.{add}(String("GET"), String("/x"), a_view)
    _ = v.route_count()
"""

CASES = [
    ("a reading view that only reads", "", "    _ = st.n", "add_read", True),
    ("a reading view that writes", "", "    st.n += 1", "add_read", False),
    ("the same write, registered add_write", "mut ", "    st.n += 1", "add_write", True),
    ("a mut view registered as a read", "mut ", "    st.n += 1", "add_read", False),
]


def compile_case(source: str, out_dir: Path, name: str) -> tuple[bool, str]:
    src = out_dir / f"{name}.mojo"
    src.write_text(source)
    proc = subprocess.run(
        [
            MOJO, "build",
            "-I", "packages/m0-core/",
            "-I", "packages/m0-http/",
            str(src),
            "-o", str(out_dir / name),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0, proc.stderr


def main() -> int:
    failures = []
    with tempfile.TemporaryDirectory() as td:
        out = Path(td)
        for i, (label, mut, body, add, must_compile) in enumerate(CASES):
            source = PROGRAM.format(mut=mut, body=body, add=add)
            ok, err = compile_case(source, out, f"case{i}")
            verdict = "compiles" if ok else "refused"
            if ok == must_compile:
                print(f"  ok        {label} -> {verdict}")
            else:
                want = "compile" if must_compile else "be refused"
                print(f"  MISMATCH  {label} -> {verdict}, expected to {want}")
                if err.strip():
                    first = err.strip().splitlines()[0]
                    print(f"            {first}")
                failures.append(label)

    if failures:
        print(f"sabotage-views: FAIL ({len(failures)} of {len(CASES)})")
        return 1
    print("sabotage-views: a reading view cannot write, and a writing one can")
    return 0


if __name__ == "__main__":
    sys.exit(main())
