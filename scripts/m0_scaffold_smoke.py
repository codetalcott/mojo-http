"""smoke-scaffold: `m0 new`, and what it writes, from OUTSIDE the tree.

    python3 scripts/m0_scaffold_smoke.py dist/m0 PORT [TEMPLATE...]

`poe check-templates` compiles the template files where they lie, against
the tree. That cannot show that what `m0 new` WRITES -- substituted,
renamed, in a directory of its own, against the installed wheel -- is an
application. This does, per template, as a user would:

  new       `uvx --offline --from <wheel> m0 new NAME`: no network, and no
            toolchain anywhere -- PATH holds uv's directory and the system's
            alone. The written tree EQUALS this script's own spelling of the
            manifest (`new.py` has the recipe's; the two must agree), holds
            both exact pins and no `__M0_` token, and smoke.sh is executable
  again     `m0 new` onto what it just wrote is exit 2, its sentence whole,
            and the tree untouched; an unusable name is exit 2 and writes
            nothing
  build     `uv sync`, refreshing m0 (the gate's own step: uv caches a
            version, and this wheel is rebuilt under one), the venv's m0
            byte-equal to the wheel under test, then the user's literal
            `UV_FIND_LINKS=<dist> uv run m0 build`
  test      `uv run m0 test` green; red, exit 1, with a failing test appended
  wire      served on a port of this run's own, stopped by pid.
            views: a document with the pinned htmx 4 tag; `HX-Request-Type:
            partial` a bare fragment under its root id; `Vary`'s five names;
            an empty POST a 422 `Unprocessable Content` whose body is the
            FRAGMENT holding role="alert", not problem+json; create; detail;
            a missing item a 404 fragment; delete.
            live: the document holds the fragment and the pinned Datastar
            tag; two DIFFERING datastar-patch-elements frames for the root id
            inside five seconds; a kick counted; nothing refused by the bus
  doctor    `uv run m0 doctor --json`: green, the host's report inside it
  smoke.sh  the scaffold's own gate is green, on another port

Resolution is online by design (the handoff's §10.2 measured that a
scaffold's `uv sync` cannot resolve offline from a cache a locked sync
left), with every wheel already cached by the job's own sync. `m0` itself
can never come from the index: the tree's wheel is `0.1.0+tree`, a local
label no index serves, and the scaffold pins it exactly.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from m0_wheel_smoke import ROOT, healthy, phase, root_pin

# The manifest, spelled a second time on purpose: packaging/m0/src/m0/new.py
# has the recipe's copy, and a file added to one and not the other fails here.
COMMON = [
    ".dockerignore", ".github/workflows/test.yml", ".gitignore", "AGENTS.md",
    "CLAUDE.md", "README.md", "deploy/Dockerfile", "deploy/README.md",
    "deploy/fly.toml", "pyproject.toml", "smoke.sh",
]
WRITES = {
    "views": COMMON + ["src/pages.mojo", "src/server.mojo", "src/views.mojo",
                       "test/test_views.mojo"],
    "live": COMMON + ["src/board.mojo", "src/pages.mojo", "src/server.mojo",
                      "src/views.mojo", "src/wave.mojo", "test/test_live.mojo"],
}
TEST_FILE = {"views": "test/test_views.mojo", "live": "test/test_live.mojo"}

HTMX_TAG = '<script src="https://cdn.jsdelivr.net/npm/htmx.org@4.0.0/dist/htmx.min.js"></script>'
DATASTAR_TAG = ('<script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/'
                'datastar@v1.0.3/bundles/datastar.js"></script>')
VARY = "HX-Request, HX-History-Restore-Request, HX-Boosted, Datastar-Request, HX-Request-Type"
PARTIAL = {"HX-Request-Type": "partial"}
FORM = dict(PARTIAL, **{"Content-Type": "application/x-www-form-urlencoded"})

RED_TEST = '''

def test_m0_smoke_scaffold_red() raises:
    assert_true(False)
'''


def fail(msg):
    print("smoke-scaffold: " + msg, file=sys.stderr)
    sys.exit(1)


def emit(*args):
    subprocess.run([sys.executable, str(ROOT / "scripts" / "emit.py"), *args,
                    "--task", "smoke-scaffold"])


def clean_env(**extra):
    e = {k: v for k, v in os.environ.items()
         if k not in ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "UV_FIND_LINKS")}
    e.update(extra)
    return e


def sh(argv, cwd, env, what, code=0, timeout=1200):
    done = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True,
                          timeout=timeout)
    if done.returncode != code:
        fail("%s exited %d, not %d:\n%s\n%s" % (what, done.returncode, code,
                                                done.stdout[-3000:], done.stderr[-3000:]))
    return done


def request(port, method, path, headers=None, body=None):
    """(status, reason, headers, body) -- a 4xx is an answer here, not an error."""
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=body,
                                 headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.reason, r.headers, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.reason, e.headers, e.read().decode()


def tree_of(path):
    return sorted(str(p.relative_to(path)) for p in path.rglob("*") if p.is_file())


# --- new ---------------------------------------------------------------------

def check_new(work, whl, template, name, pin, m0v):
    uv = shutil.which("uv")
    if not uv:
        fail("uv is not on PATH")
    # No toolchain anywhere: uv's own directory and the system's. A `mojo`
    # or a venv reachable from here would let `new` lean on one unnoticed.
    bare = clean_env(PATH=os.pathsep.join([str(Path(uv).parent), "/usr/bin", "/bin"]))
    # The interpreter is named: with PATH stripped, an offline uv otherwise
    # takes the system's python3 (3.9 on a macOS runner, below m0's floor)
    # and cannot download another. A Python is not a toolchain; the base
    # interpreter under this script's own venv has no mojo beside it.
    python = os.path.realpath(sys.executable)
    new = [uv, "tool", "run", "--offline", "--python", python, "--from", str(whl), "m0", "new"]

    done = sh(new + ["Not_A_Name", "--template", template], work, bare, "m0 new Not_A_Name", code=2)
    want = ("m0 new: 'Not_A_Name' is not a usable name (lowercase letters, digits and "
            "hyphens, starting with a letter, at most 40)")
    if done.stderr.strip().splitlines()[-1] != want:
        fail("an unusable name said:\n  %s\nwant:\n  %s" % (done.stderr.strip(), want))
    if (work / "Not_A_Name").exists():
        fail("m0 new wrote something for a name it refused")

    done = sh(new + [name, "--template", template], work, bare, "uvx --offline m0 new")
    project = work / name
    for line in ("cd " + name, "uv sync", "uv run m0 build && bin/server --port 8080"):
        if line not in done.stdout:
            fail("m0 new did not print the next command %r:\n%s" % (line, done.stdout))

    wrote = tree_of(project)
    if wrote != sorted(WRITES[template]):
        fail("m0 new --template %s wrote\n  %s\nand the manifest is\n  %s\n(differing: %s)" % (
            template, wrote, sorted(WRITES[template]),
            sorted(set(wrote) ^ set(WRITES[template]))))
    for rel in wrote:
        text = (project / rel).read_text()
        if "__M0_" in text:
            fail("%s still holds a template token" % rel)
    pins = (project / "pyproject.toml").read_text()
    for want in ('name = "%s"' % name, '"mojo==%s"' % pin, '"m0==%s"' % m0v):
        if want not in pins:
            fail("the scaffold's pyproject.toml lacks %s:\n%s" % (want, pins))
    if "build-system" in tomllib.loads(pins):
        fail("the scaffold's pyproject.toml has a [build-system]")
    if not os.access(project / "smoke.sh", os.X_OK):
        fail("smoke.sh is not executable")
    for rel in ("AGENTS.md", "deploy/fly.toml", "src/server.mojo"):
        if name not in (project / rel).read_text():
            fail("%s does not carry the application's name" % rel)

    before = {rel: (project / rel).read_bytes() for rel in wrote}
    done = sh(new + [name], work, bare, "m0 new onto its own output", code=2)
    want = "m0 new: ./%s exists and is not empty (choose another name, or empty it)" % name
    if done.stderr.strip().splitlines()[-1] != want:
        fail("a second m0 new said:\n  %s\nwant:\n  %s" % (done.stderr.strip(), want))
    if {rel: (project / rel).read_bytes() for rel in tree_of(project)} != before:
        fail("a refused m0 new changed the tree")
    print("new[%s]: %d files, both pins, no token; a second run and a bad name are 2" % (
        template, len(wrote)))
    return project


def check_installed_is_the_wheel(project, whl):
    """Every file the wheel carries under m0/ is what the venv holds.

    The wheel under test is rebuilt under ONE version, `0.1.0+tree`, and a
    resolver that has met that version before may hand back the one it
    cached. The application's own files come from `m0 new`, through a path,
    so a stale framework underneath them shows nowhere: this gate once
    passed with the layer's reason-phrase fix reverted.
    """
    site = next((project / ".venv" / "lib").glob("python*/site-packages"))
    with zipfile.ZipFile(whl) as z:
        for name in z.namelist():
            if not name.startswith("m0/") or name.endswith("/"):
                continue
            have = site / name
            if not have.is_file() or have.read_bytes() != z.read(name):
                fail("the venv's %s is not the wheel's: uv installed an m0 %s it had "
                     "cached, not the one under test" % (name, whl.name.split("-")[1]))


# --- the wire ----------------------------------------------------------------

def wire_views(port):
    status, _, headers, body = request(port, "GET", "/items")
    if status != 200 or not body.startswith("<!doctype html>"):
        fail("GET /items is not a document: %d %s" % (status, body[:200]))
    if HTMX_TAG not in body:
        fail("the document does not carry the pinned htmx 4 tag")
    if headers.get("Vary") != VARY:
        fail("the document's Vary is %r" % headers.get("Vary"))

    status, _, headers, body = request(port, "GET", "/items", PARTIAL)
    if status != 200 or not body.startswith('<section id="items"') or "<html" in body:
        fail("a partial GET /items is not the bare fragment: %s" % body[:200])
    if headers.get("Vary") != VARY:
        fail("the fragment's Vary is %r" % headers.get("Vary"))

    status, reason, headers, body = request(port, "POST", "/items", FORM, b"title=")
    if (status, reason) != (422, "Unprocessable Content"):
        fail("an empty title answered %d %s" % (status, reason))
    if not headers.get("Content-Type", "").startswith("text/html"):
        fail("the 422 is %s, not a fragment" % headers.get("Content-Type"))
    if not body.startswith('<section id="items"') or 'role="alert"' not in body:
        fail("the 422's body is not the fragment holding an alert: %s" % body[:300])

    status, _, _, body = request(port, "POST", "/items", FORM, b"title=milk+%3Cb%3E")
    if status != 200 or "milk &lt;b&gt;" not in body or 'hx-delete="/items/1"' not in body:
        fail("create did not answer the list with the item escaped: %s" % body[:400])
    status, _, _, body = request(port, "GET", "/items/1", PARTIAL)
    if status != 200 or "milk &lt;b&gt;" not in body:
        fail("GET /items/1: %d %s" % (status, body[:200]))
    status, reason, _, body = request(port, "GET", "/items/9", PARTIAL)
    if (status, reason) != (404, "Not Found") or not body.startswith('<section id="items"'):
        fail("a missing item is not a 404 fragment: %d %s %s" % (status, reason, body[:200]))
    status, _, _, body = request(port, "DELETE", "/items/1", PARTIAL)
    if status != 200 or "milk" in body or not body.startswith('<section id="items"'):
        fail("DELETE /items/1: %d %s" % (status, body[:300]))
    print("wire[views]: document, fragment, Vary, 422 fragment with an alert, create, 404, delete")


def wire_live(port):
    status, _, _, body = request(port, "GET", "/")
    if status != 200 or '<section id="live"' not in body or DATASTAR_TAG not in body:
        fail("GET / lacks the fragment or the pinned Datastar tag: %s" % body[:300])

    frames, deadline = [], time.time() + 5
    with urllib.request.urlopen("http://127.0.0.1:%d/events" % port, timeout=5) as stream:
        event = None
        while time.time() < deadline and len(set(frames)) < 2:
            line = stream.readline().decode().rstrip("\n")
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: elements ") and event == "datastar-patch-elements":
                if line.startswith('data: elements <section id="live"'):
                    frames.append(line)
    if len(set(frames)) < 2:
        fail("%d differing patch-elements frame(s) for #live inside five seconds" % len(set(frames)))

    status, _, _, _ = request(port, "POST", "/kick", {"Datastar-Request": "true"}, b"{}")
    if status != 204:
        fail("POST /kick answered %d" % status)
    stats = json.loads(request(port, "GET", "/stats")[3])
    if stats["kicks"] != 1 or stats["refused"] != 0 or stats["steps"] < 2:
        fail("after one kick /stats says %s" % stats)
    print("wire[live]: the fragment at first paint, %d differing frames, a kick counted, 0 refused"
          % len(set(frames)))


WIRE = {"views": wire_views, "live": wire_live}


# --- one template ------------------------------------------------------------

def run_template(work, whl, template, port, pin, m0v, servers):
    name = "corner-%s" % template
    phase("new [%s]" % template)
    project = check_new(work, whl, template, name, pin, m0v)
    env = clean_env(UV_FIND_LINKS=str(whl.parent))

    phase("build [%s]" % template)
    # The gate's own step, not the user's: only a gate rebuilds a wheel under
    # one version, and uv then serves the `0.1.0+tree` it cached (measured:
    # a reverted layer fix passed). A published version is immutable.
    t0 = time.time()
    sh(["uv", "sync", "--refresh-package", "m0"], project, env, "uv sync")
    synced = time.time() - t0
    check_installed_is_the_wheel(project, whl)
    t0 = time.time()
    built = sh(["uv", "run", "m0", "build"], project, env, "uv run m0 build")
    took = time.time() - t0
    if not os.access(project / "bin" / "server", os.X_OK):
        fail("uv run m0 build left no bin/server")
    # A person's first build is the product's first impression, and the
    # templates compile UNSUBSTITUTED in check-templates: `__M0_APP__` opening
    # a docstring passes the summary lint there and `corner-views` does not.
    # Only the written project can show it (found by smoke-quickstart-mojo).
    noise = [l for l in (built.stdout + built.stderr).splitlines() if "warning:" in l]
    if noise:
        fail("the first build of a fresh %s scaffold warns:\n  %s" % (template, "\n  ".join(noise)))
    print("build[%s]: sync %.1f s, first build %.1f s" % (template, synced, took))
    emit("m0.scaffold_%s_sync_s" % template, "%.1f" % synced, "--unit", "s")
    emit("m0.scaffold_%s_first_build_s" % template, "%.1f" % took, "--unit", "s")

    if os.environ.get("M0_SCAFFOLD_SKIP_TEST") == "1":
        # sabotage-scaffold's wire rules: the template's own tests would
        # catch several of them first, which is a catch but not an answer to
        # "does the WIRE assertion fail?"
        print("test[%s]: SKIPPED (M0_SCAFFOLD_SKIP_TEST)" % template)
    else:
        check_test(project, env, template)
    serve_and_probe(project, env, template, name, port, pin, m0v, servers)


def check_test(project, env, template):
    phase("test [%s]" % template)
    t0 = time.time()
    done = sh(["uv", "run", "m0", "test"], project, env, "uv run m0 test")
    took = time.time() - t0
    if "0 failed" not in done.stdout:
        fail("m0 test printed no passing summary:\n" + done.stdout[-1500:])
    emit("m0.scaffold_%s_test_s" % template, "%.1f" % took, "--unit", "s")
    test_file = project / TEST_FILE[template]
    green = test_file.read_text()
    marker = "\n\ndef main() raises:"
    if marker not in green:
        fail("%s has no main to append a test before" % TEST_FILE[template])
    test_file.write_text(green.replace(marker, RED_TEST + marker))
    sh(["uv", "run", "m0", "test"], project, env, "m0 test with a failing test", code=1)
    test_file.write_text(green)
    print("test[%s]: green in %.1f s, red (exit 1) with a failing test appended" % (template, took))


def serve_and_probe(project, env, template, name, port, pin, m0v, servers):
    phase("wire [%s]" % template)
    server = subprocess.Popen([str(project / "bin" / "server"), "--port", str(port)],
                              cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True)
    servers.append(server)
    if not healthy(port):
        server.kill()
        fail("the scaffolded server never answered /health:\n" + server.communicate()[0][-2000:])
    WIRE[template](port)
    server.terminate()
    code = server.wait(timeout=15)
    banner = server.stdout.read()
    if code != 0:
        fail("the server exited %d on SIGTERM:\n%s" % (code, banner[-1500:]))
    if name not in banner:
        fail("the server's banner does not carry the application's name:\n" + banner[:500])

    phase("doctor [%s]" % template)
    done = sh(["uv", "run", "m0", "doctor", "--json"], project, env, "uv run m0 doctor --json")
    report = json.loads(done.stdout.strip().splitlines()[-1])
    if not report["ok"] or report["app"] is None or report["app"]["report"].get("m0_host") != "1":
        fail("m0 doctor --json is not green with the host's report inside:\n" + done.stdout[-1500:])
    if report["versions"]["m0"] != m0v or report["versions"]["mojo"] != pin:
        fail("m0 doctor names %s" % report["versions"])
    print("doctor[%s]: green, the host's report inside" % template)

    phase("smoke.sh [%s]" % template)
    done = sh(["./smoke.sh", str(port + 10)], project, env, "the scaffold's own smoke.sh")
    if "smoke: ok" not in done.stdout:
        fail("smoke.sh exited 0 without saying ok:\n" + done.stdout[-1500:])
    print("smoke.sh[%s]: %s" % (template, done.stdout.strip().splitlines()[-1]))


def main():
    if len(sys.argv) < 3:
        fail("usage: m0_scaffold_smoke.py DIST_DIR PORT [TEMPLATE...]")
    wheels = sorted(Path(sys.argv[1]).glob("*.whl"))
    if len(wheels) != 1:
        fail("want exactly one wheel in %s, found %d" % (sys.argv[1], len(wheels)))
    whl = wheels[0].resolve()
    port = int(sys.argv[2])
    templates = sys.argv[3:] or sorted(WRITES)
    m0v = whl.name.split("-")[1]
    if "+" not in m0v:
        fail("the wheel is %s: without a local label the scaffold's exact pin could "
             "resolve to a PUBLISHED m0 (poe build-m0-wheel sets M0_WHEEL_LOCAL)" % m0v)
    pin = root_pin()

    work = Path(tempfile.mkdtemp(prefix="m0-scaffold-smoke-")).resolve()
    servers = []
    try:
        for i, template in enumerate(templates):
            run_template(work, whl, template, port + i, pin, m0v, servers)
    finally:
        for p in servers:
            if p.poll() is None:
                p.kill()
        shutil.rmtree(work, ignore_errors=True)
    print("smoke-scaffold OK")


if __name__ == "__main__":
    main()
