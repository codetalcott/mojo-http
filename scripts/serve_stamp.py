#!/usr/bin/env python3
"""`poe build-serve`'s stamp: skip the link when nothing it reads has changed.

Every smoke that serves through m0serve names `build-serve` as a poe dep,
and each smoke job builds the binary before its first smoke, so a CI leg
relinked an unchanged `bin/m0serve` about 44 times, about 8.5 s each: six
minutes a leg (review record CI2). The task now asks this script first:

    python3 scripts/serve_stamp.py check --target-cpu CPU ARGS...
    python3 scripts/serve_stamp.py write --target-cpu CPU ARGS...

ARGS are `mojo build`'s own arguments: the task sets them once, as its
positional parameters, and passes the same "$@" to the compiler and to both
calls, so the roots hashed here are the roots the compiler searches. `check`
exits 0 only when it has proved the binary current, and the task then stops.
`write` runs after the build, the relocation and the bundle have all
succeeded, and writes the stamp.

The stamp, `<binary>.stamp`, holds a digest of every input and output:

- the build's arguments: the target CPU, every `-I` root in its order, the
  entry file and the binary it writes;
- the toolchain: `mojo --version`, the `mojo` that answered, and every
  distribution installed in `.venv`. The last is what says MAX's packages
  sit beside the compiler (a macOS build there links the parallel runtime
  into the binary), and what a nightly swap changes;
- the task's own body, from pyproject.toml, which holds the flags, the
  post-link steps and MACOSX_DEPLOYMENT_TARGET;
- the scripts the body runs, their imports and this file;
- the compiler's environment: every `MOJO_*` and `MODULAR_*` variable;
- the sources: every file the compiler can load (`.mojo`, `.mojoc`,
  `.mojopkg`) under each `-I` root and beside the entry file. That is the
  `.mojoc` the binary links, the fork and `m0_host` (both resolved from
  source), the mount directory and an application's own root;
- the outputs: the binary, and each runtime library bundled beside it.

Content, never mtimes: a checkout sets every mtime. The inputs are read
BEFORE the build (`check` leaves them in `<binary>.stamp.next` for `write`),
so a file edited while the compiler runs leaves a stamp that no longer
matches rather than one that vouches for a binary built from the old text.

Only a proven match skips. No binary, no stamp, a stamp that does not parse,
any input or output that differs, or a crash in this script: the task
builds. A failed build writes no stamp. The stamp left by the last good
build names that build's outputs, so it matches only while the binary
beside it is byte for byte what that build left, which is then still the
right binary for those inputs. `write` never fails the task: a stamp it
could not write costs the next call a build, nothing more.

`--selftest` builds a stand-in tree (a stub `mojo` and `uname`, stub
post-link scripts, fake `.mojoc` and sources) and runs the task's REAL body
from pyproject.toml against it as poe does, under dash (the Linux runner's
`sh`) and under /bin/sh where that is another shell. It changes each input
and output in turn and asserts that the next run builds and names what
changed, and that the run after it skips and says so. A failed compile or
relocation must exit non-zero and leave the next run building, and a file
edited during a build must be built again. It also reads the body: the
`check` and `write` calls pass exactly the arguments `mojo build` gets, the
positional parameters are set before the check and never after, every
environment variable the body reads is one the stamp covers, and every
script it runs is hashed. `--sabotage` breaks each of those rules in a copy
of this file or of the body and insists the selftest fails for every one;
its arms run under the first shell alone.

    python3 scripts/serve_stamp.py --selftest
    python3 scripts/serve_stamp.py --sabotage
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TASK = "build-serve"
FORMAT = 1
# The scripts the task body runs and the scripts/ modules they import at
# their top level. The selftest reads the body and fails when it names a
# script, or a script imports one, that is not here.
SCRIPTS = (
    "scripts/relocate.py",
    "scripts/bundle_artifact.py",
    "scripts/binfmt.py",
    "scripts/serve_stamp.py",
)
# What the compiler can load from a root.
SOURCE_SUFFIXES = (".mojo", ".🔥", ".mojoc", ".mojopkg", ".📦")
# The toolchain's own environment.
ENV_PREFIXES = ("MOJO_", "MODULAR_")
# Every environment variable the body reads, and why the stamp covers it.
# The selftest fails on any other, which is how a new one gets a decision.
BODY_ENV = {
    "M0SERVE_MOUNT_DIR": "an -I root: in the arguments and the sources",
    "M0SERVE_INCLUDE": "an -I root: in the arguments and the sources",
    "M0SERVE_OUT": "the -o operand: in the arguments and the outputs",
}
VALUE_FLAGS = ("-I", "-o", "--target-cpu", "-D", "-Xlinker")


def parse(argv: list[str]) -> tuple[list[str], str]:
    """The roots `mojo build` searches (each `-I`, then each entry file's
    directory) and the binary it writes (`-o`)."""
    roots: list[str] = []
    entries: list[str] = []
    out = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in VALUE_FLAGS:
            if i + 1 >= len(argv):
                raise ValueError(f"{arg} takes a value")
            if arg == "-I":
                roots.append(argv[i + 1])
            elif arg == "-o":
                out = argv[i + 1]
            i += 2
            continue
        if not arg.startswith("-"):
            entries.append(arg)
        i += 1
    if out is None:
        raise ValueError("no -o: which binary?")
    for entry in entries:
        roots.append(os.path.dirname(entry) or ".")
    seen: list[str] = []
    for root in roots:
        name = os.path.normpath(root)
        if name not in seen:
            seen.append(name)
    return seen, out


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path) -> str:
    try:
        return _sha(Path(path).read_bytes())
    except OSError:
        return "missing"


def tree_digest(root: str) -> str:
    """Every file the compiler can load under `root`, by path and content."""
    base = Path(root)
    if not base.is_dir():
        return "missing"
    h = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames
                             if not d.startswith(".") and d != "__pycache__")
        for name in sorted(filenames):
            if name.endswith(SOURCE_SUFFIXES):
                path = Path(dirpath, name)
                h.update(f"{path.relative_to(base)}\0{file_digest(path)}\n".encode())
    return h.hexdigest()


def toolchain() -> str:
    mojo = shutil.which("mojo")
    try:
        said = subprocess.run([mojo, "--version"], capture_output=True, text=True,
                              timeout=120).stdout.strip() if mojo else "no mojo on PATH"
    except (OSError, subprocess.SubprocessError) as exc:
        said = f"mojo --version failed: {exc}"
    dists = sorted(glob.glob(".venv/lib/*/site-packages/*.dist-info"))
    return _sha("\n".join([str(mojo), said, *dists]).encode())


def task_body() -> str:
    import tomllib  # 3.11+

    tasks = tomllib.loads(Path("pyproject.toml").read_text())["tool"]["poe"]["tasks"]
    return tasks[TASK]["shell"]


def environment() -> str:
    pairs = sorted(f"{k}={v}" for k, v in os.environ.items() if k.startswith(ENV_PREFIXES))
    return _sha("\n".join(pairs).encode())


def inputs(argv: list[str]) -> dict[str, str]:
    """A digest of each input the build reads, by what it is."""
    roots, _ = parse(argv)
    found = {}
    found["arguments"] = _sha("\0".join(argv).encode())
    found["toolchain"] = toolchain()
    found["task body"] = _sha(task_body().encode())
    found["environment"] = environment()
    for script in SCRIPTS:
        found[script] = file_digest(script)
    for root in roots:
        found["sources under " + root] = tree_digest(root)
    return found


def outputs(out: str) -> dict[str, str]:
    """The binary, and each runtime library the bundle put beside it: the
    files beside the binary named as a file in the toolchain's lib."""
    found = {}
    found[out] = file_digest(out)
    for lib in sorted(glob.glob(".venv/lib/python*/site-packages/modular/lib"))[:1]:
        for name in sorted(os.listdir(lib)):
            beside = Path(os.path.dirname(out) or ".", name)
            if beside.is_file():
                found[str(beside)] = file_digest(beside)
    return found


def stamp_path(out: str) -> str:
    return out + ".stamp"


def pending_path(out: str) -> str:
    return out + ".stamp.next"


def check(argv: list[str]) -> int:
    """0 when the stamp proves the binary current; otherwise 1, the reasons
    printed and the inputs left for `write`."""
    _, out = parse(argv)
    now = inputs(argv)
    reasons = []
    if not os.path.isfile(out):
        reasons.append(f"no binary at {out}")
    try:
        stamp = json.loads(Path(stamp_path(out)).read_text())
        if stamp["format"] != FORMAT:
            raise ValueError("another format")
        was_in, was_out = dict(stamp["inputs"]), dict(stamp["outputs"])
    except FileNotFoundError:
        reasons.append(f"no stamp at {stamp_path(out)}")
    except (OSError, ValueError, KeyError, TypeError):
        reasons.append(f"{stamp_path(out)} does not parse")
    else:
        for key in sorted(set(now) | set(was_in)):
            if now.get(key) != was_in.get(key):
                reasons.append(f"{key} changed")
        for path, digest in sorted(was_out.items()):
            if not os.path.isfile(path):
                reasons.append(f"{path} is missing")
            elif file_digest(path) != digest:
                reasons.append(f"{path} is not what the last build left")
    if not reasons:
        print(f"build-serve: {out} is up to date with {stamp_path(out)}; not rebuilt")
        return 0
    print(f"build-serve: building {out}: " + "; ".join(reasons))
    try:
        Path(pending_path(out)).write_text(
            json.dumps({"format": FORMAT, "argv": argv, "inputs": now}))
    except OSError as exc:
        print(f"build-serve: cannot keep this build's inputs ({exc}); it will not be stamped")
    return 1


def write(argv: list[str]) -> int:
    """Stamp a build that succeeded, with the inputs its `check` read."""
    _, out = parse(argv)
    pending = Path(pending_path(out))
    try:
        seen = json.loads(pending.read_text())
        read = dict(seen["inputs"])
        checked = seen["argv"]
    except (OSError, ValueError, KeyError, TypeError):
        print(f"build-serve: no inputs from this build's check; {out} is not stamped")
        return 0
    if checked != argv:
        print(f"build-serve: the check was handed other arguments; {out} is not stamped")
        return 0
    stamp = {"format": FORMAT, "inputs": read, "outputs": outputs(out)}
    tmp = Path(stamp_path(out) + ".tmp")
    tmp.write_text(json.dumps(stamp, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, stamp_path(out))
    pending.unlink()
    return 0


# --- The selftest --------------------------------------------------------

STUB_MOJO = r"""#!/bin/sh
# serve_stamp.py --selftest's stand-in compiler.
case "$1" in
  --version) echo "Mojo ${STUB_MOJO_VERSION:-1.1.0} (stand-in)"; exit 0 ;;
  build) shift ;;
  *) echo "stand-in mojo: unexpected: $*" >&2; exit 97 ;;
esac
[ -z "${STUB_MOJO_FAIL:-}" ] || { echo "stand-in mojo: failing, as asked" >&2; exit 1; }
out=
while [ $# -gt 0 ]; do
  [ "$1" != "-o" ] || out=$2
  shift
done
[ -n "$out" ] || { echo "stand-in mojo: no -o" >&2; exit 98; }
echo build >> "$STUB_LOG"
printf 'binary %s\n' "$(wc -l < "$STUB_LOG")" > "$out"
[ -z "${STUB_EDIT_DURING_BUILD:-}" ] || echo "# edited while the compiler ran" >> "$STUB_EDIT_DURING_BUILD"
exit 0
"""

STUB_UNAME = r"""#!/bin/sh
if [ "$1" = "-m" ]; then echo "${STUB_UNAME_M:-x86_64}"; else echo Linux; fi
"""

STUB_RELOCATE = """import os, sys
if os.environ.get("STUB_RELOCATE_FAIL"):
    sys.exit("stand-in relocate: failing, as asked")
with open(sys.argv[-1], "a") as f:
    f.write("relocated\\n")
"""

STUB_BUNDLE = """import glob, os, shutil, sys
art, outdir = sys.argv[-2:]
for lib in glob.glob(".venv/lib/python*/site-packages/modular/lib/*"):
    shutil.copyfile(lib, os.path.join(outdir, os.path.basename(lib)))
"""

SITE = ".venv/lib/python3.13/site-packages"
TREE = {
    "packages/m0-core/m0_core.mojoc": "core artifact\n",
    "packages/m0-core/src/json.mojo": "def escape(): pass\n",
    "packages/m0-http/m0_http.mojoc": "http artifact\n",
    "packages/m0-http/src/router.mojo": "def route(): pass\n",
    "packages/m0-http/lightbug_http/__init__.mojo": "\n",
    "packages/m0-http/lightbug_http/server.mojo": "struct Server: pass\n",
    "packages/m0-http/m0_host/host.mojo": "def serve(): pass\n",
    "packages/m0-http/test/test_router.mojo": "def test(): pass\n",
    "packages/m0-postgres/m0_postgres.mojoc": "postgres artifact\n",
    "packages/m0-wsgi/m0_wsgi.mojoc": "wsgi artifact\n",
    "packages/m0-wsgi/m0serve.mojo": "def main(): pass\n",
    "packages/m0-wsgi/mount/m0serve_mount.mojo": "struct MojoMount: pass\n",
    "packages/m0-wsgi/mount_fixture/m0serve_mount.mojo": "struct MojoMount: pass\n",
    "apps/ramp/views.mojo": "def index(): pass\n",
    SITE + "/mojo-1.1.0.dist-info/METADATA": "Name: mojo\n",
    SITE + "/modular/lib/libStubRuntime.so": "runtime\n",
    "scripts/relocate.py": STUB_RELOCATE,
    "scripts/bundle_artifact.py": STUB_BUNDLE,
}
BIN = "bin/m0serve"
LIB = "bin/libStubRuntime.so"


def body_of(pyproject_text: str) -> str:
    import tomllib  # 3.11+

    return tomllib.loads(pyproject_text)["tool"]["poe"]["tasks"][TASK]["shell"]


def _script_imports(text: str) -> set[str]:
    """The modules a script imports at its top level, which is what it
    loads to run (a function-local import is a selftest's, like this
    file's own)."""
    names = set()
    for m in re.finditer(r"^(?:from\s+([\w.]+)\s+import|import\s+([\w., ]+))", text, re.M):
        for name in (m.group(1) or m.group(2)).split(","):
            names.add(name.strip().split(".")[0].split(" ")[0])
    return names


def wiring(body: str, scripts_dir: Path) -> list[str]:
    """What the body reads that the stamp must cover, read from its text.

    Pure but for the scripts it follows, so `--sabotage` can hand it a
    doctored body."""
    from check_task_shells import code_only

    code = code_only(body, keep_double_quoted=True)
    problems = []
    builds = re.findall(r"^[ \t]*mojo build[ \t]+(.*?)[ \t]*(?:\|\||$)", code, re.M)
    calls = re.findall(r"scripts/serve_stamp\.py[ \t]+(check|write)[ \t]+(.*?)[ \t]*(?:;|&&|\|\||$)",
                       code, re.M)
    if len(builds) != 1:
        problems.append(f"{TASK} runs `mojo build` {len(builds)} times; the stamp covers exactly one")
    kinds = sorted(kind for kind, _ in calls)
    if kinds != ["check", "write"]:
        problems.append(f"{TASK} calls serve_stamp.py {kinds or 'never'}; it must `check` once and "
                        "`write` once")
    for kind, args in calls:
        if builds and args != builds[0]:
            problems.append(f"serve_stamp.py {kind} is passed `{args}` but `mojo build` gets "
                            f"`{builds[0]}`: the stamp would hash other roots than the compiler reads")
    check_at = code.find("serve_stamp.py check")
    for m in re.finditer(r"(?:^|[;&|{(]|\bthen\b|\bdo\b)[ \t]*set[ \t]+--", code, re.M):
        if check_at >= 0 and m.start() > check_at:
            problems.append(f"{TASK} sets its positional parameters after the check, so the "
                            "compiler can be handed arguments the stamp never saw")
    for var in sorted(set(re.findall(r"\$\{?([A-Z_][A-Z0-9_]*)", code)) - set(BODY_ENV)):
        problems.append(f"{TASK} reads ${var}, which its stamp does not cover: pass it in the "
                        "compiler's arguments or add it to the inputs, then to BODY_ENV")
    todo = set(re.findall(r"\bscripts/[\w-]+\.py\b", code))
    closure: set[str] = set()
    while todo:
        script = todo.pop()
        if script in closure:
            continue
        closure.add(script)
        try:
            text = (scripts_dir.parent / script).read_text()
        except OSError:
            continue
        for name in _script_imports(text):
            if (scripts_dir / f"{name}.py").is_file():
                todo.add(f"scripts/{name}.py")
    for script in sorted(closure - set(SCRIPTS)):
        problems.append(f"{TASK} runs {script}, which its stamp does not hash: add it to SCRIPTS")
    return problems


class Stand:
    """A stand-in tree the real body builds in, with a stub toolchain, run
    by `shell` as poe runs a task: the unindented body on its stdin."""

    def __init__(self, tmp: Path, body: str, shell: str):
        self.tmp = tmp
        self.shell = shell
        for rel, text in TREE.items():
            path = tmp / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        for script in SCRIPTS:
            path = tmp / script
            if not path.exists():
                path.write_text("# stand-in\n")
        (tmp / "scripts/serve_stamp.py").write_text(Path(__file__).read_text())
        stubs = tmp / "stubbin"
        stubs.mkdir()
        for name, text in (("mojo", STUB_MOJO), ("uname", STUB_UNAME)):
            (stubs / name).write_text(text)
            (stubs / name).chmod(0o755)
        self.set_body(body)
        self.log = tmp / "stub.log"
        self.log.write_text("")
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("M0SERVE_", "STUB_") + ENV_PREFIXES)}
        env["PATH"] = f"{stubs}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_LOG"] = str(self.log)
        self.env = env

    def set_body(self, body: str) -> None:
        (self.tmp / "pyproject.toml").write_text(
            f"[tool.poe.tasks.{TASK}]\nshell = {json.dumps(body, ensure_ascii=False)}\n")

    def body(self) -> str:
        return body_of((self.tmp / "pyproject.toml").read_text())

    def builds(self) -> int:
        return len(self.log.read_text().splitlines())

    def run(self, **env) -> tuple[int, str, bool]:
        from check_task_shells import unindent

        before = self.builds()
        p = subprocess.run([self.shell], input=unindent(self.body()) + "\n", cwd=self.tmp,
                           env={**self.env, **env}, capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout + p.stderr, self.builds() > before

    def edit(self, rel: str) -> None:
        with open(self.tmp / rel, "a") as f:
            f.write("# edited by the selftest\n")


def _tail(out: str) -> str:
    return " | ".join(out.strip().splitlines()[-3:])[:400]


def scenarios(t: Stand):
    """(what changes, how, what the check must name). Applied in order, and
    each leaves its change in place for the ones after it."""
    yield "nothing built yet", lambda: None, "no stamp"
    yield "the entry file", lambda: t.edit("packages/m0-wsgi/m0serve.mojo"), \
        "sources under packages/m0-wsgi changed"
    for pkg in ("core", "http", "postgres", "wsgi"):
        yield f"m0_{pkg}.mojoc", (lambda p=pkg: t.edit(f"packages/m0-{p}/m0_{p}.mojoc")), \
            f"sources under packages/m0-{pkg} changed"
    yield "a fork module (source-resolved)", \
        lambda: t.edit("packages/m0-http/lightbug_http/server.mojo"), \
        "sources under packages/m0-http changed"
    yield "a new fork module", \
        lambda: (t.tmp / "packages/m0-http/lightbug_http/extra.mojo").write_text("\n"), \
        "sources under packages/m0-http changed"
    yield "m0_host (source-resolved)", lambda: t.edit("packages/m0-http/m0_host/host.mojo"), \
        "sources under packages/m0-http changed"
    yield "the mount module", lambda: t.edit("packages/m0-wsgi/mount/m0serve_mount.mojo"), \
        "sources under packages/m0-wsgi/mount changed"
    yield "another mount directory with the same text", \
        lambda: t.env.update(M0SERVE_MOUNT_DIR="packages/m0-wsgi/mount_fixture"), \
        "arguments changed"
    yield "an application's include root", lambda: t.env.update(M0SERVE_INCLUDE="apps"), \
        "arguments changed"
    yield "a module under that root", lambda: t.edit("apps/ramp/views.mojo"), \
        "sources under apps changed"
    yield "the target CPU", lambda: t.env.update(STUB_UNAME_M="aarch64"), "arguments changed"
    yield "the compiler's version", lambda: t.env.update(STUB_MOJO_VERSION="9.9.9"), \
        "toolchain changed"
    yield "MAX's packages installed beside the compiler", \
        lambda: (t.tmp / SITE / "max_core-26.1.dist-info").mkdir(), "toolchain changed"
    yield "the compiler's environment", lambda: t.env.update(MODULAR_STUB_KNOB="1"), \
        "environment changed"
    yield "the task body", lambda: t.set_body(t.body() + "\n# edited by the selftest\n"), \
        "task body changed"
    for script in SCRIPTS:
        yield script, (lambda s=script: t.edit(s)), f"{script} changed"
    yield "the binary", lambda: t.edit(BIN), f"{BIN} is not what the last build left"
    yield "the binary removed", lambda: (t.tmp / BIN).unlink(), f"no binary at {BIN}"
    yield "a bundled runtime library", lambda: t.edit(LIB), f"{LIB} is not what the last build left"
    yield "a bundled runtime library removed", lambda: (t.tmp / LIB).unlink(), f"{LIB} is missing"
    yield "the stamp removed", lambda: (t.tmp / (BIN + ".stamp")).unlink(), "no stamp"
    yield "a stamp that does not parse", \
        lambda: (t.tmp / (BIN + ".stamp")).write_text("{not json"), "does not parse"


def exercise(t: Stand) -> list[str]:
    """Drive the real body through every scenario; the first failure ends it."""

    def built(label: str, reason: str, **env) -> str | None:
        rc, out, did = t.run(**env)
        if rc != 0 or not did:
            return f"{label}: the next build-serve did not build (exit {rc}): {_tail(out)}"
        if reason not in out:
            return f"{label}: it built, but the check did not name '{reason}': {_tail(out)}"
        return None

    def skipped(label: str) -> str | None:
        rc, out, did = t.run()
        if rc != 0 or did:
            return f"after {label}: the run after a build built again (exit {rc}): {_tail(out)}"
        if f"{BIN} is up to date" not in out:
            return f"after {label}: build-serve skipped without saying so: {_tail(out)}"
        return None

    for label, change, reason in scenarios(t):
        change()
        problem = built(label, reason) or skipped(label)
        if problem:
            return [problem]

    # A failed compile, then a failed relocation: each exits non-zero, and
    # the call after it builds.
    for label, knob in (("a failed compile", "STUB_MOJO_FAIL"),
                        ("a failed relocation", "STUB_RELOCATE_FAIL")):
        t.edit("packages/m0-http/lightbug_http/server.mojo")
        rc, out, _ = t.run(**{knob: "1"})
        if rc == 0:
            return [f"{label}: build-serve exited 0: {_tail(out)}"]
        problem = (built(f"the call after {label}", "sources under packages/m0-http changed")
                   or skipped(label))
        if problem:
            return [problem]

    # A source edited while the compiler runs is built again: the stamp
    # holds what the check read, not what the tree says after the build.
    t.edit("packages/m0-http/lightbug_http/server.mojo")
    problem = (built("an edit before a build", "sources under packages/m0-http changed",
                     STUB_EDIT_DURING_BUILD=str(t.tmp / "packages/m0-http/lightbug_http/server.mojo"))
               or built("an edit made while the compiler ran",
                        "sources under packages/m0-http changed")
               or skipped("an edit made while the compiler ran"))
    return [problem] if problem else []


def selftest(repo: Path, body: str | None = None, use: list[str] | None = None) -> int:
    """The wiring rules, then the body exercised under each shell: dash,
    which is the Linux runner's `sh`, and /bin/sh where that is another."""
    from check_task_shells import shells

    body = body if body is not None else body_of((repo / "pyproject.toml").read_text())
    use = use or shells() or ["sh"]
    problems = wiring(body, repo / "scripts")
    for shell in use if not problems else []:
        with tempfile.TemporaryDirectory(prefix="serve-stamp-") as tmp:
            problems = [f"under {shell}: {p}" for p in exercise(Stand(Path(tmp), body, shell))]
        if problems:
            break
    for problem in problems:
        print(f"serve_stamp selftest: FAIL: {problem}")
    if not problems:
        print(f"serve_stamp selftest: PASS, under {', '.join(use)}")
    return 1 if problems else 0


# --- The sabotage --------------------------------------------------------

# (label, old, new): each breaks one rule in a copy of THIS file, and the
# copy's own selftest must fail.
SELF_SABOTAGES = [
    ("the build's arguments are not an input",
     '    found["arguments"] = _sha("\\0".join(argv).encode())\n', ""),
    ("the toolchain is not an input",
     '    found["toolchain"] = toolchain()\n', ""),
    ("the distributions beside the compiler are not read",
     'return _sha("\\n".join([str(mojo), said, *dists]).encode())',
     'return _sha("\\n".join([str(mojo), said]).encode())'),
    ("the task body is not an input",
     '    found["task body"] = _sha(task_body().encode())\n', ""),
    ("the compiler's environment is not an input",
     '    found["environment"] = environment()\n', ""),
    ("the post-link scripts are not inputs",
     "        found[script] = file_digest(script)\n", "        pass\n"),
    ("the sources are not inputs",
     '        found["sources under " + root] = tree_digest(root)\n', "        pass\n"),
    ("a .mojoc is not a source",
     '\nSOURCE_SUFFIXES = (".mojo", ".🔥", ".mojoc", ".mojopkg", ".📦")',
     '\nSOURCE_SUFFIXES = (".mojo", ".🔥", ".mojopkg", ".📦")'),
    ("the binary is not an output",
     "    found[out] = file_digest(out)\n", ""),
    ("the bundled runtime is not an output",
     "                found[str(beside)] = file_digest(beside)\n", "                pass\n"),
    ("the stamp takes its inputs after the build",
     '        read = dict(seen["inputs"])\n', "        read = inputs(argv)\n"),
]

# (label, old, new): each breaks one rule in a copy of the task body.
BODY_SABOTAGES = [
    ("a failed compile goes on to be stamped",
     'mojo build --target-cpu "$tcpu" "$@" || exit 1',
     'mojo build --target-cpu "$tcpu" "$@" || true'),
    ("the check's answer is ignored",
     '"$@"; then exit 0; fi', '"$@"; then :; fi'),
    ("the compiler gets a root the check never hashed",
     'mojo build --target-cpu "$tcpu" "$@"',
     'mojo build --target-cpu "$tcpu" "$@" -I packages/m0-datastar/'),
    ("the arguments are changed after the check",
     'mojo build --target-cpu "$tcpu" "$@"',
     'set -- "$@" -I packages/m0-datastar/\nmojo build --target-cpu "$tcpu" "$@"'),
    ("the body reads a variable the stamp does not cover",
     "python3 scripts/relocate.py ", "python3 scripts/relocate.py ${M0SERVE_RPATH:-} "),
    ("the body runs a script the stamp does not hash",
     "python3 scripts/bundle_artifact.py ",
     'python3 scripts/strip_symbols.py "$out" || exit 1\npython3 scripts/bundle_artifact.py '),
]


def sabotage(repo: Path) -> int:
    this = Path(__file__).read_text()
    body = body_of((repo / "pyproject.toml").read_text())
    env = {**os.environ, "PYTHONPATH": str(repo / "scripts")}
    from check_task_shells import shells

    first = (shells() or ["sh"])[0]
    if selftest(repo, body) != 0:
        print("serve_stamp sabotage: the selftest fails on the unsabotaged tree")
        return 1
    bad = 0
    with tempfile.TemporaryDirectory(prefix="serve-stamp-sabotage-") as tmp:
        copy = Path(tmp, "serve_stamp.py")
        body_file = Path(tmp, "body.sh")
        arms = [("self", *s) for s in SELF_SABOTAGES] + [("body", *s) for s in BODY_SABOTAGES]
        for kind, label, old, new in arms:
            source = this if kind == "self" else body
            if source.count(old) != 1:
                print(f"NOT APPLICABLE  {label}: its anchor matches {source.count(old)} times")
                bad += 1
                continue
            doctored = source.replace(old, new)
            copy.write_text(doctored if kind == "self" else this)
            body_file.write_text(doctored if kind == "body" else body)
            p = subprocess.run([sys.executable, str(copy), "--selftest", "--repo", str(repo),
                                "--body-file", str(body_file), "--shell", first],
                               capture_output=True, text=True, env=env, timeout=600)
            said = [ln for ln in p.stdout.splitlines() if "FAIL: " in ln]
            if p.returncode != 0 and said:
                print(f"caught          {label}: {said[0].split('FAIL: ', 1)[1][:160]}")
            else:
                print(f"MISSED          {label}: the selftest exited {p.returncode}: "
                      f"{_tail(p.stdout + p.stderr)}")
                bad += 1
    print(f"serve_stamp sabotage: {len(arms) - bad} of {len(arms)} caught")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    repo = Path(__file__).resolve().parent.parent
    if "--repo" in argv:
        repo = Path(argv[argv.index("--repo") + 1])
    if argv[:1] == ["--selftest"]:
        body = None
        if "--body-file" in argv:
            body = Path(argv[argv.index("--body-file") + 1]).read_text()
        use = [argv[argv.index("--shell") + 1]] if "--shell" in argv else None
        return selftest(repo, body, use)
    if argv[:1] == ["--sabotage"]:
        return sabotage(repo)
    if len(argv) < 2 or argv[0] not in ("check", "write"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        return check(argv[1:]) if argv[0] == "check" else write(argv[1:])
    except Exception as exc:  # a crash must build, never skip, and never fail a build
        print(f"build-serve: the stamp's {argv[0]} failed ({type(exc).__name__}: {exc})")
        return 1 if argv[0] == "check" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
