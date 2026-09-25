"""smoke-scaffold-image: `uv run m0 image` on a scaffolded app, then the image.

    python3 scripts/m0_scaffold_image_smoke.py dist/m0 PORT

What `m0 new` writes under `deploy/` is built AS WRITTEN -- the Dockerfile
byte for byte, `uv sync --frozen` and all -- by the user's own command, and
the image is then asked from outside what the scaffold's pages claim of it.

**How the tree's wheel gets in.** A published m0 needs nothing: the lock
names the index. The wheel under test is `0.1.0+tree`, which no index
serves, so:

- the wheel is copied to `.wheels/` in the project and the HOST's sync runs
  with `UV_FIND_LINKS=.wheels`. A relative find-links is recorded
  RELATIVELY (`source = { registry = ".wheels" }`, asserted below), so the
  lock means the same thing at `/src` in the builder; an absolute one is
  recorded absolutely and `--frozen` could never be satisfied there;
- `.wheels/` reaches the builder without touching the Dockerfile or the
  `.dockerignore`: a base image that is `python:3.13-slim` plus
  `/src/.wheels`, handed to `docker build` as a named context that REPLACES
  `python:3.13-slim` -- through `m0 image`'s pass-through after `--`.

The layer cache is uv's cache hazard again (a rebuilt `0.1.0+tree` under one
name): the base image's digest changes with the wheel, which invalidates
every layer after `FROM`, and `builder` below does not take that on trust.

  new       scaffolded by `uvx --offline`; deploy/ byte-identical to the
            wheel's templates after substitution is `smoke-scaffold`'s; here
            the Dockerfile's hash is taken BEFORE the build and compared after
  refusals  no docker on PATH is exit 1 naming docker; an argument docker
            refuses is exit 1 with docker's own words; `native` is exit 2
  image     `uv run m0 image --tag T -- --build-context ...`: exit 0, the
            LAST stdout line is about.json: this app, this version,
            `"python":false`, the daemon's architecture, `libs` (the runtime
            libraries the storage packages open), and `cpu` -- what the
            builder's release build said it compiled for -- the BASELINE
  builder   the builder stage's installed m0 is byte-equal to the wheel
  serve     run with a published port: /health, PID 1 is /app/server, the
            file in the image is the line `m0 image` printed, no interpreter
            anywhere (asked as root), libsqlite3 present for m0_sqlite to
            open, and `smoke-scaffold`'s whole views wire
            -- the 422 fragment included -- through the published port
  stop      `docker stop` is exit 0 inside the drain's bound
  cpu       `m0 image --target-cpu CPU` compiles for CPU (built, not run)
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from pathlib import Path

from m0_scaffold_smoke import check_installed_is_the_wheel, clean_env, sh, wire_views
from m0_wheel_smoke import ROOT, healthy, phase

BASE_IMAGE = "python:3.13-slim"
DRAIN_BOUND_S = 10
OTHER_CPU = {"x86_64": "x86-64-v3", "aarch64": "neoverse-n1"}
BASELINE = {"x86_64": "x86-64-v2", "aarch64": "generic"}


def fail(msg):
    print("smoke-scaffold-image: " + msg, file=sys.stderr)
    sys.exit(1)


def emit(*args):
    subprocess.run([sys.executable, str(ROOT / "scripts" / "emit.py"), *args,
                    "--task", "smoke-scaffold-image"])


def docker(*argv, check=True, timeout=1800):
    done = subprocess.run(["docker", *argv], capture_output=True, text=True, timeout=timeout)
    if check and done.returncode != 0:
        fail("`docker %s` exited %d:\n%s\n%s" % (" ".join(argv), done.returncode,
                                                  done.stdout[-3000:], done.stderr[-3000:]))
    return done


def daemon_arch():
    arch = docker("info", "--format", "{{.Architecture}}").stdout.strip()
    return {"arm64": "aarch64", "amd64": "x86_64"}.get(arch, arch)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def m0_image(project, env, args, what, code=0):
    done = subprocess.run(["uv", "run", "m0", "image", *args], cwd=project, env=env,
                          capture_output=True, text=True, timeout=2400)
    if done.returncode != code:
        fail("%s exited %d, not %d:\n%s\n%s" % (what, done.returncode, code,
                                                done.stdout[-2000:], done.stderr[-4000:]))
    return done


def about_of(done, what):
    lines = done.stdout.strip().splitlines()
    try:
        return lines[-1], json.loads(lines[-1])
    except (IndexError, ValueError):
        fail("%s: the last stdout line is not about.json:\n%s" % (what, done.stdout[-1500:]))


def check_refusals(project, env):
    phase("refusals")
    m0 = project / ".venv" / "bin" / "m0"
    done = subprocess.run([str(m0), "image"], cwd=project, capture_output=True, text=True,
                          env=dict(env, PATH="/nonexistent"))
    if done.returncode != 1 or not done.stderr.startswith("m0 image: docker: "):
        fail("with no docker on PATH m0 image exited %d saying:\n%s" % (done.returncode, done.stderr))
    done = m0_image(project, env, ["--", "--m0-smoke-no-such-flag"], "m0 image with a flag docker refuses", 1)
    if "unknown flag: --m0-smoke-no-such-flag" not in done.stderr or done.stdout.strip():
        fail("docker's refusal did not come through untouched:\n%s\n%s" % (done.stdout, done.stderr))
    m0_image(project, env, ["--target-cpu", "native"], "m0 image --target-cpu native", 2)
    print("refusals: no docker is 1 naming it; docker's own refusal is 1, its words; native is 2")


def check_builder(project, whl, context, tag):
    phase("builder")
    # Every layer is cached from the build above; this only names the stage.
    docker("build", "-f", str(project / "deploy" / "Dockerfile"), "--target", "build", "-t", tag, *context,
           str(project))
    done = docker("run", "--rm", tag, "sh", "-c",
                  "cd /src/.venv/lib/python*/site-packages && find m0 -type f "
                  "! -name '*.pyc' ! -path '*.dist-info/*' -exec sha256sum {} + | sort -k2")
    have = dict(reversed(line.split(None, 1)) for line in done.stdout.strip().splitlines())
    with zipfile.ZipFile(whl) as z:
        want = {n: hashlib.sha256(z.read(n)).hexdigest() for n in z.namelist()
                if n.startswith("m0/") and not n.endswith("/")}
    wrong = sorted(n for n in want if have.get(n) != want[n])
    if wrong or not want:
        fail("the builder's %s is not the wheel's (%d of %d files differ): the image was "
             "compiled from a cached layer's m0, not the one under test"
             % (wrong[0] if wrong else "m0/", len(wrong), len(want)))
    print("builder: %d files under m0/ byte-equal to the wheel" % len(want))


def serve(tag, port, printed, arch):
    name = "m0-scaffold-image-%s" % uuid.uuid4().hex[:8]
    try:
        phase("serve")
        docker("run", "-d", "--name", name, "-p", "127.0.0.1:%d:8080" % port, tag)
        if not healthy(port, tries=120):
            fail("the container never answered /health:\n" + docker("logs", name, check=False).stderr[-3000:])
        argv = [a for a in docker("exec", name, "cat", "/proc/1/cmdline").stdout.split("\0") if a]
        if argv != ["/app/server"]:
            fail("PID 1 is %r, not exactly ['/app/server']" % argv)
        inside = docker("exec", name, "cat", "/app/about.json").stdout.strip()
        if inside != printed:
            fail("m0 image printed\n  %s\nand the image holds\n  %s" % (printed, inside))
        found = docker("exec", "-u", "0", name, "sh", "-c",
                       "command -v python3 python; find / -xdev \\( -name 'python[0-9]*' -o "
                       "-name 'libpython*' \\) \\( -type f -o -type l \\)", check=False).stdout.strip()
        if found:
            fail("about.json says \"python\":false and the image holds:\n" + found)
        # The library m0_sqlite opens at run time rides in the runtime stage
        # (the storage packages link nothing, so nothing else would miss it).
        libs = docker("exec", name, "sh", "-c", "ls /usr/lib/*/libsqlite3.so.0 2>/dev/null",
                      check=False).stdout.strip()
        if not libs:
            fail("the runtime image carries no libsqlite3.so.0, which m0_sqlite opens at run time")
        wire_views(port)

        phase("stop")
        t0 = time.monotonic()
        docker("stop", "-t", "20", name, timeout=60)
        took = time.monotonic() - t0
        code = int(docker("inspect", "-f", "{{.State.ExitCode}}", name).stdout)
        if code != 0 or took >= DRAIN_BOUND_S:
            fail("docker stop: exit %d after %.1f s (want 0 inside %d s; 137 is SIGKILL)\n%s"
                 % (code, took, DRAIN_BOUND_S, docker("logs", name, check=False).stderr[-2000:]))
        print("stop: exit 0 in %.1f s" % took)
        emit("m0.scaffold_image_stop_s", "%.1f" % took, "--unit", "s", "--limit", str(DRAIN_BOUND_S))
    finally:
        docker("rm", "-f", name, check=False)


def run(work, whl, port, tags):
    uv = shutil.which("uv")
    arch = daemon_arch()
    if arch not in BASELINE:
        fail("the docker daemon is %s; Mojo builds on x86_64 and aarch64" % arch)
    env = clean_env()
    python = os.path.realpath(sys.executable)
    name = "corner-image"

    phase("new")
    # `--refresh-package m0`, for the reason m0_scaffold_smoke.check_new gives:
    # a rebuilt wheel under one version is otherwise served from uv's cache.
    sh([uv, "tool", "run", "--offline", "--refresh-package", "m0", "--python", python, "--from", str(whl),
        "m0", "new", name], work, env, "uvx m0 new")
    project = work / name
    (project / ".wheels").mkdir()
    shutil.copy(whl, project / ".wheels")
    sh(["uv", "sync", "--refresh-package", "m0"], project, dict(env, UV_FIND_LINKS=".wheels"),
       "uv sync with a relative find-links")
    check_installed_is_the_wheel(project, whl)
    if 'source = { registry = ".wheels" }' not in (project / "uv.lock").read_text():
        fail("uv.lock does not record the find-links directory relatively; --frozen in the "
             "builder would look for a path of this machine's")
    dockerfile = sha(project / "deploy" / "Dockerfile")
    ignore = sha(project / ".dockerignore")
    print("new: scaffolded, locked against .wheels/ relatively")

    check_refusals(project, env)

    phase("image")
    unique = uuid.uuid4().hex[:8]
    base = "m0-scaffold-base:%s" % unique
    tag = "m0-scaffold-smoke:%s" % unique
    # `name` too: it is `m0 image`'s DEFAULT tag, which only a broken --tag builds.
    tags += [base, tag, tag + "-build", tag + "-cpu", name]
    basedir = work / "base"
    basedir.mkdir()
    shutil.copytree(project / ".wheels", basedir / ".wheels")
    (basedir / "Dockerfile").write_text("FROM %s\nCOPY .wheels /src/.wheels\n" % BASE_IMAGE)
    docker("build", "-t", base, str(basedir))
    context = ["--build-context", "%s=docker-image://%s" % (BASE_IMAGE, base)]

    t0 = time.time()
    done = m0_image(project, env, ["--tag", tag, "--", *context], "uv run m0 image")
    took = time.time() - t0
    if (sha(project / "deploy" / "Dockerfile"), sha(project / ".dockerignore")) != (dockerfile, ignore):
        fail("the scaffold's Dockerfile or .dockerignore changed during the gate")
    printed, about = about_of(done, "m0 image")
    # `cpu` is what the builder's `m0 build --release` SAID it compiled for,
    # carried into the image -- read there and not from docker's output, which
    # a cached layer does not repeat.
    want = {"app": name, "version": "0.1.0", "arch": arch, "cpu": BASELINE[arch],
            "base": "debian:12-slim", "libs": "libsqlite3-0", "python": False}
    got = {k: about.get(k) for k in want}
    if got != want or not about.get("app_bytes") or not about.get("image_bytes"):
        fail("about.json is %s\nwant %s and both sizes" % (printed, want))
    print("image: built in %.0f s for %s; about.json %s" % (took, BASELINE[arch], printed))
    emit("m0.scaffold_image_build_s", "%.0f" % took, "--unit", "s")
    emit("m0.scaffold_image_app_bytes", str(about["app_bytes"]), "--unit", "B")
    emit("m0.scaffold_image_bytes", str(about["image_bytes"]), "--unit", "B")

    check_builder(project, whl, context, tag + "-build")
    serve(tag, port, printed, arch)

    phase("cpu")
    cpu = OTHER_CPU[arch]
    done = m0_image(project, env, ["--tag", tag + "-cpu", "--target-cpu", cpu, "--", *context],
                    "uv run m0 image --target-cpu")
    got = about_of(done, "m0 image --target-cpu")[1].get("cpu")
    if got != cpu:
        fail("--target-cpu %s did not reach the builder's m0 build: about.json says %r" % (cpu, got))
    print("cpu: the builder compiled for %s" % cpu)


def main():
    if len(sys.argv) != 3:
        fail("usage: m0_scaffold_image_smoke.py DIST_DIR PORT")
    wheels = sorted(Path(sys.argv[1]).glob("*.whl"))
    if len(wheels) != 1:
        fail("want exactly one wheel in %s, found %d" % (sys.argv[1], len(wheels)))
    whl = wheels[0].resolve()
    if "+" not in whl.name.split("-")[1]:
        fail("the wheel carries no local label (poe build-m0-wheel sets M0_WHEEL_LOCAL)")
    if not shutil.which("docker"):
        fail("docker is not on PATH")
    work = Path(tempfile.mkdtemp(prefix="m0-scaffold-image-")).resolve()
    tags = []
    try:
        run(work, whl, int(sys.argv[2]), tags)
    finally:
        if os.environ.get("M0_SCAFFOLD_IMAGE_KEEP") != "1":
            for t in tags:
                docker("rmi", "-f", t, check=False)
        shutil.rmtree(work, ignore_errors=True)
    print("smoke-scaffold-image OK")


if __name__ == "__main__":
    main()
