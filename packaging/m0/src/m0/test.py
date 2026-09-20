"""`m0 test [FILE...]`: the fast loop.

`mojo run` per file -- no link and no event loop instantiated, so a test
file answers in two or three seconds where `m0 build` takes about ten. That
is also why the `c-compiler` check is skipped: `mojo run` links nothing,
measured on a machine with no compiler installed at all.

Two include roots: the framework's, and `src/`, so a test imports the
application's modules by the names `src/server.mojo` imports them by.
Files run one at a time with their output untouched.
"""

import subprocess
import sys

from m0 import checks, paths


def run(args):
    project = args.project
    failed = checks.preflight(project, skip=("c-compiler",))
    if failed is not None:
        return checks.refuse(failed)

    if args.files:
        files = list(args.files)
        missing = [f for f in files if not (project / f).is_file()]
        if missing:
            print(f"m0 test: no such file: {missing[0]}", file=sys.stderr)
            return 2
    else:
        files = sorted(
            str(p.relative_to(project)) for p in (project / "test").glob("test_*.mojo")
        )
        if not files:
            print(
                "m0: no test/test_*.mojo here (a run that tested nothing is "
                "not a pass)",
                file=sys.stderr,
            )
            return checks.REFUSED

    bad = []
    for name in files:
        cmd = [
            str(paths.mojo_bin()), "run",
            "-I", str(paths.include_root()),
            "-I", "src",
            name,
        ]
        sys.stdout.flush()
        if subprocess.run(cmd, cwd=project, env=paths.toolchain_env()).returncode != 0:
            bad.append(name)
    total = len(files)
    if bad:
        print(f"m0 test: {len(bad)} of {total} files failed: {' '.join(bad)}")
        return 1
    print(f"m0 test: {total} of {total} files passed")
    return 0
