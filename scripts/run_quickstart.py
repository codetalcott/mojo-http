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

    script = [PRELUDE]
    for i, (tag, body) in enumerate(blocks, 1):
        if wheel:
            body = substitute_wheel(body, wheel)
        script.append(f'echo; echo "== block {i} ({tag}) =="')
        if tag == "serve":
            script.append("kill_server")
            script.append("(\n" + body + "\n) &")
            script.append("SERVER_PID=$!")
        else:
            script.append(body)
    script.append('echo; echo "quickstart: every block passed"')

    scratch = tempfile.mkdtemp(prefix="m0serve-quickstart-")
    print(f"run-quickstart: {len(blocks)} blocks {counts} in {scratch}"
          + (f" (local wheel: {wheel})" if wheel else " (published package)"))
    proc = subprocess.run(["bash", "-c", "\n".join(script)], cwd=scratch)
    if args.keep or proc.returncode != 0:
        print(f"run-quickstart: scratch kept at {scratch}", file=sys.stderr)
    else:
        import shutil

        shutil.rmtree(scratch, ignore_errors=True)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
