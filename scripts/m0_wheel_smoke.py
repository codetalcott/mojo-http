"""smoke-m0-wheel: the `m0` wheel, and the CLI in it, from OUTSIDE the tree.

    python3 scripts/m0_wheel_smoke.py dist/m0 PORT

A poe task runs inside the repository, where every source tree is on disk,
so nothing run from here can show that the wheel is enough. Everything
below the contents check therefore happens in a temporary directory: a
project laid out as a user's is (`.venv/` beside `src/server.mojo`), the
wheel and the pinned toolchain installed into it, `apps/fragment_notes`
copied in as the application, and `m0` run as `.venv/bin/m0` with the
working directory there.

The phases, each of which names the rule it holds (SPEC N23-N26):

  wheel      names under m0/_mojo/ equal the mapped `git ls-files` set
             EXACTLY (this script's own spelling of the map, which is the
             point: the recipe's table and this one must agree); _tools
             byte-identical to scripts/; the build info read from the root
             pin; no Requires-Dist; a decoy planted in a source tree
             does not ship
  unit       packaging/m0/tests/test_m0.py under the installed interpreter
  build      m0 build; serve; a changed literal rebuilt WHILE the old
             binary serves (it survives, its inode untouched), timed; a build that fails
             leaves the old binary byte-identical
  test       m0 test green, red with a failing file, 78 with none
  doctor     --json green with the host's report inside; stale reported and
             not failed; `-- --workers 0` is 78 THROUGH the binary
  refusals   no network: a stub `mojo` 9.9.9 distribution whose `mojo`
             drops a marker -- the pair sentence verbatim and no marker;
             that venv's m0 run from the real project -- the prefix
             sentence; no mojo at all; no project; PATH stripped to the
             venv -- the c-compiler sentence, while `m0 test` still passes
  own prefix EVERY real command above ran with the stub `mojo` FIRST on
             PATH; the marker must not exist
  release    m0 build --release: dist/server carries no trace of the build
             venv and answers --doctor from elsewhere with no environment

The refusal sentences are asserted whole. A sentence is the product here:
it is what stands between a user and the raw compiler message.
"""

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# The map, spelled a second time on purpose. packaging/m0/hatch_build.py has
# the recipe's copy; a tree added to one and not the other fails here.
TREES = {
    "packages/m0-core/src": "m0_core",
    "packages/m0-http/src": "m0_http",
    "packages/m0-http/lightbug_http": "lightbug_http",
    "packages/m0-http/m0_host": "m0_host",
    "packages/m0-datastar/src": "m0_datastar",
}
TOOLS = ("relocate.py", "bundle_artifact.py", "binfmt.py")
APP_ENV = {"M0_NOTES_KEY": "0123456789abcdef0123456789abcdef", "M0_NOTES_PASSWORD": "pw"}


def fail(msg):
    print("smoke-m0-wheel: " + msg, file=sys.stderr)
    sys.exit(1)


def phase(name):
    print("--- " + name, flush=True)


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True,
                          capture_output=True, text=True).stdout


def root_pin():
    text = (ROOT / "pyproject.toml").read_text()
    m = re.search(r'^\s*"mojo==([0-9.]+)",\s*$', text, re.M)
    if not m:
        fail("the root pyproject pins no exact mojo")
    return m.group(1)


def emit(*args):
    subprocess.run([sys.executable, str(ROOT / "scripts" / "emit.py"), *args,
                    "--task", "smoke-m0-wheel"])


# --- the wheel ---------------------------------------------------------------

def check_wheel(whl, pin):
    z = zipfile.ZipFile(whl)
    names = set(z.namelist())

    want = set()
    for tree, name in TREES.items():
        for rel in git("ls-files", "-z", "--", tree).split("\0"):
            if rel:
                want.add("m0/_mojo/%s/%s" % (name, rel[len(tree) + 1:]))
    got = {n for n in names if n.startswith("m0/_mojo/")}
    if got != want:
        fail("m0/_mojo/ is not the mapped git ls-files set: missing %r, extra %r"
             % (sorted(want - got)[:5], sorted(got - want)[:5]))
    if "m0/_mojo/lightbug_http/LICENSE" not in got:
        fail("the fork's LICENSE did not ride along")
    for n in sorted(got):
        rel = n[len("m0/_mojo/"):]
        name, inside = rel.split("/", 1)
        tree = [t for t, v in TREES.items() if v == name][0]
        if z.read(n) != (ROOT / tree / inside).read_bytes():
            fail("%s differs from the tree" % n)

    tools = {n for n in names if n.startswith("m0/_tools/")}
    if tools != {"m0/_tools/" + t for t in TOOLS}:
        fail("m0/_tools/ holds %r" % sorted(tools))
    for t in TOOLS:
        if z.read("m0/_tools/" + t) != (ROOT / "scripts" / t).read_bytes():
            fail("m0/_tools/%s is not scripts/%s byte for byte" % (t, t))

    for n, src in (("m0/licenses/LICENSE.mojo-http.txt", "LICENSE"),
                   ("m0/licenses/LICENSE.lightbug_http.txt",
                    "licenses/LICENSE.lightbug_http.txt")):
        if n not in names or z.read(n) != (ROOT / src).read_bytes():
            fail("%s is missing or differs from %s" % (n, src))

    junk = [n for n in names if n.endswith((".mojoc", ".pyc")) or "__pycache__" in n]
    if junk:
        fail("build output shipped: %r" % junk[:5])

    info = json.loads(z.read("m0/_build_info.json"))
    version = re.match(r"m0-([^-]+)-py3-none-any\.whl$", whl.name)
    if not version:
        fail("the wheel is not py3-none-any: " + whl.name)
    if list(info) != ["format", "m0", "gated_mojo", "framework", "commit", "dirty"]:
        fail("_build_info.json's keys are %r" % list(info))
    if "+" not in version.group(1):
        fail("the smoke's wheel carries no local label (M0_WHEEL_LOCAL): an exact pin on "
             "%s could be served by a PUBLISHED wheel instead of this one" % version.group(1))
    if info["format"] != 1 or info["m0"] != version.group(1):
        fail("_build_info.json says %r for wheel %s" % (info, whl.name))
    if info["gated_mojo"] != [pin]:
        fail("gated_mojo is %r and the root pins %s" % (info["gated_mojo"], pin))
    if info["commit"] != git("rev-parse", "HEAD").strip():
        fail("_build_info.json names another commit")

    meta = z.read([n for n in names if n.endswith(".dist-info/METADATA")][0]).decode()
    if "Requires-Dist" in meta:
        fail("the wheel declares a dependency; mojo is a checked pair, not a Requires-Dist (D39)")
    print("wheel: %d source files, exactly git's; tools and licences byte-identical; gated on mojo %s"
          % (len(got), pin))
    return info


# --- helpers for running m0 --------------------------------------------------

class Project:
    def __init__(self, path, venv, stub_bin=None):
        self.path, self.venv, self.stub_bin = path, venv, stub_bin

    def m0(self, *args, env=None, path=None, timeout=900):
        e = {k: v for k, v in os.environ.items()
             if k not in ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME")}
        # The stub `mojo` goes FIRST on PATH for every command: m0 must run
        # the one in its own prefix regardless.
        if path is not None:
            e["PATH"] = path
        elif self.stub_bin:
            e["PATH"] = str(self.stub_bin) + os.pathsep + e["PATH"]
        e.update(env or {})
        return subprocess.run([str(self.venv / "bin" / "m0"), *args], cwd=self.path,
                              env=e, capture_output=True, text=True, timeout=timeout)


def expect(done, code, what):
    if done.returncode != code:
        fail("%s exited %d, not %d:\n%s\n%s" % (what, done.returncode, code,
                                                done.stdout[-3000:], done.stderr[-3000:]))


def expect_refusal(done, sentence, what):
    expect(done, 78, what)
    if done.stderr.strip() != sentence:
        fail("%s said:\n  %s\nwant:\n  %s" % (what, done.stderr.strip(), sentence))
    if done.stdout.strip():
        fail("%s refused and still printed: %s" % (what, done.stdout.strip()))


def uv_venv(path, *install):
    subprocess.run(["uv", "venv", str(path), "--python", "3.13", "--quiet"], check=True)
    if install:
        subprocess.run(["uv", "pip", "install", "--quiet", "--python",
                        str(path / "bin" / "python"), *install], check=True)


def stub_mojo_wheel(out, marker_var):
    """A `mojo` 9.9.9 distribution zipped on the spot: no network, and a
    `mojo` script that leaves a marker if anything ever runs it."""
    whl = out / "mojo-9.9.9-py3-none-any.whl"
    script = '#!/bin/sh\ntouch "$%s"\nexit 0\n' % marker_var
    files = {
        "mojo-9.9.9.dist-info/METADATA": "Metadata-Version: 2.1\nName: mojo\nVersion: 9.9.9\n",
        "mojo-9.9.9.dist-info/WHEEL": "Wheel-Version: 1.0\nGenerator: smoke\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        "mojo-9.9.9.data/scripts/mojo": script,
    }
    with zipfile.ZipFile(whl, "w") as z:
        record = []
        for name, text in files.items():
            info = zipfile.ZipInfo(name)
            info.external_attr = (0o755 if name.endswith("/mojo") else 0o644) << 16
            z.writestr(info, text)
            record.append(name + ",,")
        record.append("mojo-9.9.9.dist-info/RECORD,,")
        z.writestr("mojo-9.9.9.dist-info/RECORD", "\n".join(record) + "\n")
    return whl


def healthy(port, tries=40):
    for _ in range(tries):
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/health" % port, timeout=2) as r:
                if r.status == 200:
                    return True
        except OSError:
            time.sleep(0.25)
    return False


def get(port, path):
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=5) as r:
        return r.read().decode()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# --- the run -----------------------------------------------------------------

def main():
    if len(sys.argv) != 3:
        fail("usage: m0_wheel_smoke.py DIST_DIR PORT")
    wheels = sorted(Path(sys.argv[1]).glob("*.whl"))
    port = int(sys.argv[2])
    if len(wheels) != 1:
        fail("want exactly one wheel in %s, found %d" % (sys.argv[1], len(wheels)))
    whl = wheels[0].resolve()
    pin = root_pin()

    phase("wheel")
    info = check_wheel(whl, pin)
    m0v = info["m0"]

    work = Path(tempfile.mkdtemp(prefix="m0-wheel-smoke-")).resolve()
    servers = []
    try:
        run(work, whl, pin, m0v, port, servers)
    finally:
        for p in servers:
            if p.poll() is None:
                p.kill()
        shutil.rmtree(work, ignore_errors=True)
    print("smoke-m0-wheel OK")


def check_untracked_cannot_ship(work):
    """A second wheel, built with a decoy planted in a source tree.

    The contents check above cannot tell the manifest from a directory walk
    while the tree holds nothing untracked, which in CI is always. The decoy
    is named `.mojoc` so it is ignored and never dirties the checkout.
    """
    decoy = ROOT / "packages/m0-http/src/m0_smoke_decoy.mojoc"
    out = work / "decoy-dist"
    try:
        decoy.write_text("not source\n")
        done = subprocess.run(["uv", "build", "--wheel", str(ROOT / "packaging/m0"), "-o", str(out)],
                              capture_output=True, text=True,
                              env=dict(os.environ, M0_WHEEL_LOCAL="decoy"))
    finally:
        decoy.unlink(missing_ok=True)
    if done.returncode != 0:
        fail("the decoy wheel would not build:\n" + done.stderr[-2000:])
    names = zipfile.ZipFile(next(out.glob("*.whl"))).namelist()
    if any("m0_smoke_decoy" in n for n in names):
        fail("an untracked file in a source tree shipped in the wheel")
    print("wheel: an untracked file planted in m0-http/src did not ship")


def run(work, whl, pin, m0v, port, servers):
    check_untracked_cannot_ship(work)
    marker = work / "stub-mojo-ran"
    os.environ["M0_STUB_MARKER"] = str(marker)
    stub_whl = stub_mojo_wheel(work, "M0_STUB_MARKER")

    # The stub's `mojo`, as a directory to put first on PATH.
    stub_venv = work / "stubvenv"
    uv_venv(stub_venv, str(whl), str(stub_whl))
    stub_bin = work / "stubbin"
    stub_bin.mkdir()
    shutil.copy2(stub_venv / "bin" / "mojo", stub_bin / "mojo")

    # The project, laid out as a user's: .venv beside src/.
    proj = work / "proj"
    (proj / "src").mkdir(parents=True)
    (proj / "test").mkdir()
    shutil.copy2(ROOT / "apps/fragment_notes/server.mojo", proj / "src/server.mojo")
    # A module tree of the application's own and a test that imports it AND
    # the framework: both include roots, in one file.
    shutil.copytree(ROOT / "apps/blobs", proj / "src/blobs",
                    ignore=shutil.ignore_patterns("test", "server.mojo"))
    shutil.copy2(ROOT / "apps/blobs/test/test_board.mojo", proj / "test/test_board.mojo")
    uv_venv(proj / ".venv", str(whl), "mojo==" + pin)
    real = Project(proj, proj / ".venv", stub_bin)

    phase("unit")
    # M0_SMOKE_SKIP_UNIT is the sabotage runner's: a reverted rule that a unit
    # test catches first would never reach the arm that claims to hold it.
    done = None if os.environ.get("M0_SMOKE_SKIP_UNIT") else subprocess.run([str(proj / ".venv/bin/python"),
                           str(ROOT / "packaging/m0/tests/test_m0.py")],
                          cwd=work, capture_output=True, text=True)
    if done is None:
        print("unit: SKIPPED by M0_SMOKE_SKIP_UNIT")
    elif done.returncode != 0:
        fail("packaging/m0/tests/test_m0.py failed:\n" + done.stderr[-4000:])
    else:
        print(done.stderr.strip().splitlines()[-3])

    phase("build")
    inc = real.m0("include")
    expect(inc, 0, "m0 include")
    include = Path(inc.stdout.strip())
    if not (include / "m0_http" / "views.mojo").is_file() or work not in include.parents:
        fail("m0 include printed %s, which is not the installed source" % include)

    t0 = time.time()
    done = real.m0("build")
    # Asked BEFORE the exit code: a stub that ran built nothing, so the build
    # fails too, and "exited 1" would bury the reason.
    if marker.exists():
        fail("m0 build ran the `mojo` first on PATH, not the one in its own prefix")
    expect(done, 0, "m0 build")
    cold = time.time() - t0
    binary = proj / "bin/server"
    if not binary.is_file() or (proj / "bin/.server.next").exists():
        fail("m0 build left bin/ as %r" % sorted(p.name for p in (proj / "bin").iterdir()))
    if marker.exists():
        fail("m0 build ran the `mojo` first on PATH, not the one in its own prefix")

    env = dict(os.environ, M0_PORT=str(port), **APP_ENV)
    old = subprocess.Popen([str(binary)], cwd=proj, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    servers.append(old)
    if not healthy(port):
        fail("the binary m0 built never answered /health")
    if "Sign in" not in get(port, "/login"):
        fail("the login page does not say Sign in")

    # Rename into place: rebuild a CHANGED LITERAL while the old binary
    # serves. -o onto it is ETXTBSY on Linux and a killed process on macOS.
    src = proj / "src/server.mojo"
    text = src.read_text()
    if text.count('"Sign in"') != 1:
        fail("the literal this smoke edits is no longer unique in fragment_notes")
    src.write_text(text.replace('"Sign in"', '"Sign in, rebuilt"'))
    before = sha(binary)
    # A second name for the running binary's inode: a rename never writes to
    # it, whatever the platform's linker does with an existing output.
    kept = proj / "bin/kept"
    os.link(binary, kept)
    t0 = time.time()
    done = real.m0("build")
    expect(done, 0, "m0 build over a running server")
    edit = time.time() - t0
    if sha(kept) != before or kept.stat().st_ino == binary.stat().st_ino:
        fail("the rebuild wrote into the running binary's inode instead of renaming over its name")
    kept.unlink()
    if old.poll() is not None:
        fail("rebuilding killed the running server (exit %r): the build was not renamed into place" % old.returncode)
    if "rebuilt" in get(port, "/login"):
        fail("the OLD process serves the new literal")
    if sha(binary) == before:
        fail("bin/server did not change after an edit")
    old.send_signal(signal.SIGTERM)
    old.wait(timeout=15)
    new = subprocess.Popen([str(binary)], cwd=proj, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    servers.append(new)
    if not healthy(port) or "Sign in, rebuilt" not in get(port, "/login"):
        fail("the rebuilt binary does not serve the edited literal")
    new.send_signal(signal.SIGTERM)
    new.wait(timeout=15)

    # A failing build: exit 1, the compiler's words, the old binary intact.
    good = src.read_text()
    src.write_text(good + "\ndef broken(:\n")
    before = sha(binary)
    done = real.m0("build")
    expect(done, 1, "m0 build of a syntax error")
    if sha(binary) != before or (proj / "bin/.server.next").exists():
        fail("a failed build touched bin/")
    if "error" not in done.stderr + done.stdout:
        fail("a failed build did not show the compiler's output")
    src.write_text(good)
    print("build: first %.1f s, after a changed literal %.1f s; renamed under a live server; a failed build left bin/ alone"
          % (cold, edit))
    emit("m0.build_first_s", "%.1f" % cold, "--unit", "s")
    emit("m0.build_after_edit_s", "%.1f" % edit, "--unit", "s")

    phase("test")
    t0 = time.time()
    done = real.m0("test")
    expect(done, 0, "m0 test")
    took = time.time() - t0
    if "m0 test: 1 of 1 files passed" not in done.stdout:
        fail("m0 test's summary is missing:\n" + done.stdout[-1000:])
    (proj / "test/test_zfails.mojo").write_text(
        "from std.testing import assert_equal, TestSuite\n\n\n"
        "def test_no() raises:\n    assert_equal(1, 2)\n\n\n"
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n")
    done = real.m0("test")
    expect(done, 1, "m0 test with a failing file")
    if "m0 test: 1 of 2 files failed: test/test_zfails.mojo" not in done.stdout:
        fail("a failing file is not named:\n" + done.stdout[-1000:])
    expect(real.m0("test", "test/test_board.mojo"), 0, "m0 test FILE")
    expect(real.m0("test", "test/nope.mojo"), 2, "m0 test of a missing file")
    (proj / "test/test_zfails.mojo").unlink()
    shutil.move(proj / "test", proj / "test.away")
    expect_refusal(real.m0("test"),
                   "m0: no test/test_*.mojo here (a run that tested nothing is not a pass)",
                   "m0 test with no tests")
    shutil.move(proj / "test.away", proj / "test")
    print("test: green in %.1f s, red names the file, none is 78" % took)
    emit("m0.test_s", "%.1f" % took, "--unit", "s")

    phase("doctor")
    # The edit-and-restore above left src/ newer than the binary.
    done = real.m0("doctor", "--json", env=APP_ENV)
    expect(done, 0, "m0 doctor --json")
    doc = json.loads(done.stdout.strip().splitlines()[-1])
    if list(doc) != ["m0", "ok", "exit", "versions", "paths", "checks", "app"] or doc["m0"] != "1":
        fail("the report's shape is %r" % list(doc))
    if not doc["app"]["stale"]:
        fail("src/ is newer than bin/server and the doctor does not say stale")
    expect(real.m0("build"), 0, "m0 build")
    done = real.m0("doctor", "--json", env=APP_ENV)
    expect(done, 0, "m0 doctor --json")
    doc = json.loads(done.stdout.strip().splitlines()[-1])
    if not doc["ok"] or doc["exit"] != 0 or doc["app"]["stale"]:
        fail("a good project is not green: %r" % doc)
    if [c["name"] for c in doc["checks"]] != ["platform", "mojo-installed", "mojo-gated", "c-compiler", "project"]:
        fail("the checks are %r" % [c["name"] for c in doc["checks"]])
    report = doc["app"]["report"]
    if next(iter(report)) != "m0_host" or report["m0_host"] != "1" or "topology" not in report:
        fail("the host's report is not inside the doctor's: %r" % report)
    v = doc["versions"]
    if v["m0"] != m0v or v["mojo"] != pin or v["gated_mojo"] != [pin]:
        fail("versions: %r" % v)
    if doc["paths"]["mojo"] != str(proj / ".venv/bin/mojo"):
        fail("paths.mojo is %r" % doc["paths"]["mojo"])

    done = real.m0("doctor", "--json", "--", "--workers", "0", env=APP_ENV)
    expect(done, 78, "m0 doctor -- --workers 0")
    doc = json.loads(done.stdout.strip().splitlines()[-1])
    if not all(c["ok"] for c in doc["checks"]) or doc["app"]["exit"] != 78 or doc["ok"]:
        fail("the 78 did not come THROUGH the binary: %r" % doc)
    if not [c for c in doc["app"]["report"]["checks"] if not c["ok"]]:
        fail("the host's report names no failed check")
    # An app whose own main refuses before serve prints no report: recorded.
    done = real.m0("doctor", "--json")
    expect(done, 78, "m0 doctor of an app that refuses to start")
    doc = json.loads(done.stdout.strip().splitlines()[-1])
    if doc["app"]["report"] is not None or "M0_NOTES_KEY" not in doc["app"]["output"]:
        fail("an app's own refusal is not recorded: %r" % doc["app"])
    text = real.m0("doctor", env=APP_ENV)
    expect(text, 0, "m0 doctor")
    if "ok   app: " not in text.stdout or "ok   c-compiler" not in text.stdout:
        fail("the plain doctor:\n" + text.stdout)
    print("doctor: green with the host's report inside; stale reported; --workers 0 is 78 through the binary")

    phase("refusals")
    fix = "uv add --dev 'mojo==%s'" % pin
    bare = work / "bare"
    (bare / "src").mkdir(parents=True)
    (bare / "src/server.mojo").write_text("def main():\n    pass\n")
    stub = Project(bare, stub_venv)
    pair = "m0: m0 %s is gated on mojo %s and this environment has mojo 9.9.9 (%s)" % (m0v, pin, fix)
    expect_refusal(stub.m0("build"), pair, "m0 build beside mojo 9.9.9")
    expect_refusal(stub.m0("test"), pair, "m0 test beside mojo 9.9.9")
    done = stub.m0("doctor", "--json")
    expect(done, 78, "m0 doctor beside mojo 9.9.9")
    doc = json.loads(done.stdout.strip().splitlines()[-1])
    bad = [c for c in doc["checks"] if not c["ok"]]
    if [c["name"] for c in bad] != ["mojo-gated"] or bad[0]["fix"] != fix or bad[0]["exit"] != 78:
        fail("the doctor beside mojo 9.9.9 failed %r" % bad)

    # The `uvx m0 build` mistake: a foreign m0 in a project with a toolchain.
    foreign = Project(proj, stub_venv)
    expect_refusal(foreign.m0("build"),
                   "m0: this m0 runs from %s, not this project's .venv (uv run m0 <command>)" % stub_venv,
                   "a foreign m0 in the project")

    none_venv = work / "nonevenv"
    uv_venv(none_venv, str(whl))
    expect_refusal(Project(bare, none_venv).m0("build"),
                   "m0: mojo is not installed in this environment (%s)" % fix,
                   "m0 build with no mojo")

    empty = work / "empty"
    empty.mkdir()
    # The real toolchain, so `project` is the first check that can fail.
    done = Project(empty, proj / ".venv").m0("build")
    expect_refusal(done,
                   "m0: there is no src/server.mojo in %s (run m0 from the application's root)" % empty,
                   "m0 build outside a project")

    # No cc: PATH stripped to the venv. mojo looks for the NAME cc.
    stripped = str(proj / ".venv/bin")
    if sys.platform == "darwin":
        want = "m0: mojo links with cc and there is no cc on PATH (add /usr/bin to PATH)"
    else:
        want = ("m0: mojo links with cc and there is no cc on PATH (install a C toolchain: "
                "apt-get install build-essential, or dnf install gcc glibc-devel)")
    before = sha(binary)
    expect_refusal(real.m0("build", path=stripped), want, "m0 build with no cc")
    if sha(binary) != before:
        fail("a refused build touched bin/server")
    # gcc without the NAME cc is still no compiler to mojo, and the sentence
    # says which name it wants.
    tools = work / "tools"
    for name, body in (("gccdir/gcc", "exit 0"),
                       ("ccdir/cc", 'echo "ld: cannot find crti.o: No such file or directory" >&2; exit 1')):
        f = tools / name
        f.parent.mkdir(parents=True)
        f.write_text("#!/bin/sh\n%s\n" % body)
        f.chmod(0o755)
    expect_refusal(real.m0("build", path=stripped + os.pathsep + str(tools / "gccdir")),
                   "m0: mojo links with a compiler named cc and finds no other name; gcc is "
                   "installed and cc is not on PATH (ln -s \"$(command -v gcc)\" /usr/local/bin/cc)",
                   "m0 build with gcc and no cc")
    # A cc that exists and cannot link passes any PATH check, and mojo would
    # find out after the whole compile.
    cc = tools / "ccdir/cc"
    fix = "xcode-select --install" if sys.platform == "darwin" else (
        "install a C toolchain: apt-get install build-essential, or dnf install gcc glibc-devel")
    expect_refusal(real.m0("build", path=stripped + os.pathsep + str(cc.parent)),
                   "m0: %s cannot link a C program: ld: cannot find crti.o: No such file or directory (%s)"
                   % (cc, fix),
                   "m0 build with a cc that cannot link")
    if sha(binary) != before:
        fail("a refused build touched bin/server")
    # ...and m0 test needs none: mojo run links nothing.
    expect(real.m0("test", path=stripped), 0, "m0 test with no cc on PATH")
    if marker.exists():
        fail("a refused command ran mojo")
    print("refusals: the pair, the foreign prefix, no mojo, no project, no cc -- each its sentence, 78, and nothing run")

    phase("own prefix")
    if marker.exists():
        fail("the stub `mojo` first on PATH was run")
    # The stub really is what PATH finds, or the phase above proved nothing.
    probe = subprocess.run(["mojo"], env=dict(os.environ, PATH=str(stub_bin) + os.pathsep + os.environ["PATH"]),
                           capture_output=True)
    if probe.returncode != 0 or not marker.exists():
        fail("the stub on PATH is not runnable, so its marker's absence meant nothing")
    marker.unlink()
    print("own prefix: every build and test ran <prefix>/bin/mojo with a stub first on PATH")

    phase("release")
    done = real.m0("build", "--release")
    expect(done, 0, "m0 build --release")
    dist = proj / "dist"
    shipped = dist / "server"
    if not shipped.is_file() or (proj / ".dist.next").exists() or (dist / ".build").exists():
        fail("dist/ is %r" % sorted(p.name for p in dist.iterdir()))
    if len(list(dist.iterdir())) < 2:
        fail("no Mojo runtime was bundled beside dist/server")
    # The SEARCH PATH, not the bytes: a binary built from source carries its
    # source files' paths for error locations, which load nothing.
    if sys.platform == "darwin":
        loads = subprocess.run(["otool", "-l", str(shipped)], capture_output=True, text=True).stdout
        rpaths = re.findall(r"cmd LC_RPATH\n.*\n\s+path (\S+)", loads)
    else:
        rpaths = subprocess.run(["patchelf", "--print-rpath", str(shipped)],
                                capture_output=True, text=True).stdout.strip().split(":")
    if not rpaths or any(not r.startswith(("@loader_path", "$ORIGIN")) for r in rpaths):
        fail("dist/server searches %r: the build venv was not relocated out" % rpaths)
    # From elsewhere, with nothing in the environment pointing back.
    away = work / "away"
    shutil.copytree(dist, away)
    shutil.move(proj / ".venv", work / "venv.moved")
    try:
        clean = {"PATH": "/usr/bin:/bin", **APP_ENV}
        done = subprocess.run([str(away / "server"), "--doctor"], cwd=away, env=clean,
                              capture_output=True, text=True, timeout=60)
    finally:
        shutil.move(work / "venv.moved", proj / ".venv")
    if done.returncode != 0 or '"m0_host":"1"' not in done.stdout:
        fail("the released bundle does not run away from its build venv (exit %d):\n%s"
             % (done.returncode, done.stderr[-2000:]))
    print("release: dist/ runs with the build venv moved away")
    if marker.exists():
        fail("the release build ran the stub mojo")


if __name__ == "__main__":
    main()
