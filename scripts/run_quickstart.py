"""Execute QUICKSTART.md, then docs/QUICKSTART_NEXT.md: the quickstart is a smoke,
and the smoke is the doc.

The launch checklist calls for "a quickstart a human or agent completes and
*verifies* without help" — which only stays true while someone re-runs it.
So instead of a doc and a separate test that drift apart, the doc IS the
test: this extracts the fenced blocks and runs them, and CI does it on every
pull request. A quickstart edit that breaks the path fails the build; a code
change that breaks the quickstart fails the same way.

Fence tags (invisible in rendered markdown — they ride the info string):

    ```bash setup     run inline; any failure fails the run
    ```bash serve     start in the background as the current server,
                      killing the previous one first (the doc says Ctrl-C;
                      this is Ctrl-C for a script)
    ```bash verify    run inline; the doc's own assertions
    ```text           expected output, display only
    ```bash           display only — NOT executed (the tag is the opt-in)

Every executed block runs in ONE bash process, so `cd`, an activated venv,
and variables (`FIRST_ID`) carry across blocks exactly as they do for a
human in one terminal.

`M0SERVE_WHEEL=/path/to.whl` substitutes the local wheel for the `m0serve`
PyPI package on `pip install` lines. CI sets it: a pull request must prove
the TREE's wheel, and must pass with no network dependence on what is
published. Run without it to rehearse the published-package path verbatim.

`M0_WHEEL=/path/to/m0-X.whl` does the same for a page that starts `uvx m0
new` (packaging/m0/QUICKSTART.md, `poe smoke-quickstart-mojo`), and three
more things, each the gate's own step and none the reader's:

  - `uvx m0 ...` becomes `uvx --from WHEEL m0 ...`, and `UV_FIND_LINKS`
    names the wheel's directory, so the project's exact `m0==` pin -- a
    local version no index serves -- resolves to the wheel under test.
  - the page's `uv sync` gains `--refresh-package m0` and is followed by
    `m0_scaffold_smoke.check_installed_is_the_wheel`: the wheel is rebuilt
    under ONE version and uv caches a version by name (smoke-scaffold once
    passed against yesterday's framework that way).
  - the blocks run in a reader's environment rather than this process's:
    `PATH` is uv's directory and the system's, and `VIRTUAL_ENV` and its
    kin are dropped, so nothing the page does not install -- this
    repository's venv, its `mojo`, its `m0` -- is reachable. `UV_PYTHON`
    names this interpreter's base, because the system `python3` on a macOS
    runner is below m0's floor and a download is a network flake; a Python
    is not a toolchain.

    python3 scripts/run_quickstart.py [--doc QUICKSTART.md --doc docs/QUICKSTART_NEXT.md] [--keep]
"""

import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile

FENCE = re.compile(r"^```bash (setup|serve|verify)\s*$")

PRELUDE = """set -euo pipefail
SERVER_PID=""
kill_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}
trap kill_server EXIT
"""


def extract(doc_path):
    blocks = []
    tag, lines = None, []
    for line in doc_path.open():
        line = line.rstrip("\n")
        if tag is None:
            m = FENCE.match(line)
            if m:
                tag, lines = m.group(1), []
        elif line.strip() == "```":
            blocks.append((tag, "\n".join(lines)))
            tag = None
        else:
            lines.append(line)
    if tag is not None:
        raise SystemExit(f"run-quickstart: unterminated ```bash {tag} block")
    return blocks


def substitute_wheel(body, wheel):
    """Point `pip install` at the local wheel instead of the PyPI name."""
    out = []
    for line in body.splitlines():
        if line.strip().startswith("pip install"):
            line = re.sub(r"(?<=\s)m0serve(?=\s|$)", shlex.quote(wheel), line)
        out.append(line)
    return "\n".join(out)


_UVX_M0 = re.compile(r"(?<![\w-])uvx m0(?=\s)")
_UV_SYNC = re.compile(r"^(\s*)uv sync\s*$")


def substitute_m0_wheel(body, wheel, repo):
    """Point `uvx m0` at the local wheel; refresh and verify at `uv sync`."""
    check = (
        # Not `python3`: on the stripped PATH that is the system's, and the
        # module imports tomllib.
        "\"$UV_PYTHON\" -c 'import sys; sys.path.insert(0, sys.argv[1]); "
        "from pathlib import Path; "
        "from m0_scaffold_smoke import check_installed_is_the_wheel as c; "
        "c(Path.cwd(), Path(sys.argv[2]))' "
        + shlex.quote(os.path.join(repo, "scripts")) + " " + shlex.quote(wheel)
    )
    out = []
    for line in body.splitlines():
        line = _UVX_M0.sub("uvx --from " + shlex.quote(wheel) + " m0", line)
        m = _UV_SYNC.match(line)
        if m:
            out.append(m.group(1) + "uv sync --refresh-package m0")
            out.append(m.group(1) + check)
            continue
        out.append(line)
    return "\n".join(out)


def bare_env(wheel):
    """A reader's terminal: uv and the system, and nothing of this tree's."""
    import shutil

    uv = shutil.which("uv")
    if not uv:
        raise SystemExit("run-quickstart: uv is not on PATH")
    env = {k: v for k, v in os.environ.items()
           if k not in ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "UV_FIND_LINKS")}
    env["PATH"] = os.pathsep.join(
        [os.path.dirname(uv), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    env["UV_FIND_LINKS"] = os.path.dirname(wheel)
    env["UV_PYTHON"] = os.path.realpath(
        getattr(sys, "_base_executable", None) or sys.executable)
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--doc", action="append",
                    help="a page to run; repeatable, in order, one scratch "
                         "directory for all of them (default: QUICKSTART.md)")
    ap.add_argument("--keep", action="store_true", help="keep the scratch dir")
    ap.add_argument(
        "--expect",
        default="",
        help="exact block counts, e.g. setup=2,serve=2,verify=2. The floor "
        "check below only catches a doc losing its LAST tag of a kind; a "
        "doc with two verify phases that loses one still passes it, and the "
        "run then silently verifies less. CI pins the exact shape.",
    )
    args = ap.parse_args()

    import pathlib

    docs = [pathlib.Path(d).resolve() for d in (args.doc or ["QUICKSTART.md"])]
    blocks = [b for d in docs for b in extract(d)]
    names = ", ".join(d.name for d in docs)
    counts = {t: sum(1 for tag, _ in blocks if tag == t) for t in ("setup", "serve", "verify")}
    # A doc edit that mangles a fence tag silently demotes the block to
    # display-only, and the run "passes" by testing less. Floor-check the
    # shape so that failure is loud instead.
    if counts["setup"] < 1 or counts["serve"] < 1 or counts["verify"] < 1:
        raise SystemExit(
            f"run-quickstart: {names} yielded {counts} executable blocks - "
            "a tagged fence has probably lost its tag"
        )
    if args.expect:
        expected = dict(kv.split("=") for kv in args.expect.split(","))
        expected = {k: int(v) for k, v in expected.items()}
        if counts != expected:
            raise SystemExit(
                f"run-quickstart: {names} has {counts} executable blocks, "
                f"--expect says {expected}. If the doc's shape changed on "
                "purpose, update the --expect in the smoke-quickstart task; "
                "if not, a fence has lost its tag and part of the quickstart "
                "silently stopped being tested."
            )

    wheel = os.environ.get("M0SERVE_WHEEL", "")
    if wheel:
        # Absolutized HERE because the script runs in a scratch directory: a
        # relative path that resolved where the caller stood dangles the
        # moment the first block cds. Found by the poe task passing
        # `dist/wheels/...` and pip failing inside the scratch dir.
        wheel = os.path.abspath(wheel)
        if not os.path.exists(wheel):
            raise SystemExit(f"run-quickstart: M0SERVE_WHEEL={wheel} does not exist")

    m0_wheel = os.environ.get("M0_WHEEL", "")
    if m0_wheel:
        m0_wheel = os.path.abspath(m0_wheel)
        if not os.path.exists(m0_wheel):
            raise SystemExit(f"run-quickstart: M0_WHEEL={m0_wheel} does not exist")
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    script = [PRELUDE]
    if m0_wheel:
        # Asked on every run, before the page's first line: the page installs
        # its own toolchain, and one already reachable would let every later
        # block lean on it. With `bare_env` reverted this fires naming this
        # repository's .venv/bin/mojo (measured).
        script.append(
            'if command -v mojo || command -v m0 || [ -n "${VIRTUAL_ENV:-}" ]; then\n'
            '  echo "run-quickstart: a toolchain or a venv is reachable before '
            'the page installed one" >&2; exit 1\nfi')
    substituted = set()
    for i, (tag, body) in enumerate(blocks, 1):
        if wheel:
            body = substitute_wheel(body, wheel)
        if m0_wheel:
            body = substitute_m0_wheel(body, m0_wheel, repo)
            substituted |= {w for w in ("uvx --from", "--refresh-package m0") if w in body}
        script.append(f'echo; echo "== block {i} ({tag}) =="')
        if tag == "serve":
            script.append("kill_server")
            script.append("(\n" + body + "\n) &")
            script.append("SERVER_PID=$!")
        else:
            script.append(body)
    script.append('echo; echo "quickstart: every block passed"')
    if m0_wheel and len(substituted) != 2:
        # A page reworded so that neither line matches would install whatever
        # the index serves and prove nothing about the tree.
        raise SystemExit(
            "run-quickstart: M0_WHEEL is set, and the page must hold both a "
            "`uvx m0 ...` line and a bare `uv sync` line for the wheel under "
            f"test to be the one built against (substituted: {sorted(substituted)})")

    scratch = tempfile.mkdtemp(prefix="m0serve-quickstart-")
    print(f"run-quickstart: {len(blocks)} blocks {counts} in {scratch}"
          + (f" (local wheel: {wheel or m0_wheel})" if wheel or m0_wheel
             else " (published package)"))
    proc = subprocess.run(["bash", "-c", "\n".join(script)], cwd=scratch,
                          env=bare_env(m0_wheel) if m0_wheel else None)
    if args.keep or proc.returncode != 0:
        print(f"run-quickstart: scratch kept at {scratch}", file=sys.stderr)
    else:
        import shutil

        shutil.rmtree(scratch, ignore_errors=True)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
