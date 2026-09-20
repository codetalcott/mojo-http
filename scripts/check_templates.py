"""check-templates: the scaffold's templates are real files, so compile them.

    python3 scripts/check_templates.py

`m0 new` substitutes with `str.replace` and nothing else, which is only
sound while every template compiles UNSUBSTITUTED: the application's name
may appear where a compiler does not look (string literals, TOML, Markdown)
and nowhere else. This holds the templates to that, in place, against the
tree -- so an API the layer changes breaks here, in `test-all`, in the pull
request that changed it, and not in the next person's first `m0 build`.

Per template: `mojo build src/server.mojo` (the artifact is thrown away) and
`mojo run` of every test file. Then, for the package as a whole:

- every file under `templates/` is named by `new.py`'s manifest, and every
  name there is a file -- a stray file would ship in the wheel and never be
  written; a missing one is a broken `m0 new`;
- `__M0_VERSION__` and `__MOJO_VERSION__` appear in `pyproject.toml` alone;
- no other `__M0_` token exists: a misspelled one would be written verbatim.

`smoke-scaffold` is the other half: what `m0 new` WRITES, outside the tree,
against the installed wheel.
"""

import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "packaging/m0/src/m0/templates"
INCLUDE = ["-I", "packages/m0-http", "-I", "packages/m0-core", "-I", "packages/m0-datastar"]
TOKENS = {"__M0_APP__", "__M0_VERSION__", "__MOJO_VERSION__"}
PYPROJECT_ONLY = {"__M0_VERSION__", "__MOJO_VERSION__"}

sys.path.insert(0, str(ROOT / "packaging/m0/src"))
from m0 import new  # noqa: E402


def compile_template(template, out):
    src = TEMPLATES / template / "src"
    jobs = [(["mojo", "build", *INCLUDE, "-I", str(src), str(src / "server.mojo"),
              "-o", str(Path(out) / template)], "build src/server.mojo")]
    for test in sorted((TEMPLATES / template / "test").glob("test_*.mojo")):
        jobs.append((["mojo", "run", *INCLUDE, "-I", str(src), str(test)], "run " + test.name))
    problems = []
    for argv, what in jobs:
        done = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
        if done.returncode != 0:
            problems.append("%s: %s failed:\n%s" % (template, what,
                                                    (done.stdout + done.stderr)[-3000:]))
        elif what.startswith("run") and "0 failed" not in done.stdout:
            problems.append("%s: %s printed no passing summary" % (template, what))
    return problems


def check_manifest():
    problems = []
    named = {("_common", n) for n in new.COMMON}
    for template, names in new.MANIFEST.items():
        named |= {(template, n) for n in names}
    on_disk = set()
    for path in TEMPLATES.rglob("*"):
        if path.is_file() and "__pycache__" not in path.parts:
            rel = path.relative_to(TEMPLATES)
            on_disk.add((rel.parts[0], "/".join(rel.parts[1:])))
    for where, name in sorted(on_disk - named):
        problems.append("templates/%s/%s is in no manifest in new.py: it would ship "
                        "and never be written" % (where, name))
    for where, name in sorted(named - on_disk):
        problems.append("new.py names templates/%s/%s, which does not exist" % (where, name))
    if sorted(new.MANIFEST) != sorted(new.TEMPLATES):
        problems.append("new.TEMPLATES and new.MANIFEST name different templates")
    return problems, on_disk


def check_tokens(on_disk):
    problems = []
    for where, name in sorted(on_disk):
        text = (TEMPLATES / where / name).read_text()
        for token in set(re.findall(r"__M[0O][A-Z_]*__", text)):
            if token not in TOKENS:
                problems.append("templates/%s/%s holds %s, which m0 new does not replace"
                                % (where, name, token))
            elif token in PYPROJECT_ONLY and name != "pyproject.toml":
                problems.append("templates/%s/%s holds %s; only pyproject.toml may"
                                % (where, name, token))
    return problems


def main():
    problems, on_disk = check_manifest()
    problems += check_tokens(on_disk)
    with tempfile.TemporaryDirectory(prefix="m0-check-templates-") as out:
        with ThreadPoolExecutor(max_workers=len(new.TEMPLATES)) as pool:
            for found in pool.map(lambda t: compile_template(t, out), new.TEMPLATES):
                problems += found
    if problems:
        print("check-templates FAILED:\n\n" + "\n\n".join(problems), file=sys.stderr)
        return 1
    print("check-templates: %s compile unsubstituted and their tests pass; %d files, "
          "every one in a manifest" % (" and ".join(new.TEMPLATES), len(on_disk)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
