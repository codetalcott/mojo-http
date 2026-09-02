"""The documentation site's deploy image, built and served: what a Fly machine
would run, proven here first.

    python3 scripts/site_image_probe.py --wheel-dir dist/wheels   # the tree's wheel (CI)
    python3 scripts/site_image_probe.py --version 0.17.0          # a PyPI release
    python3 scripts/site_image_probe.py                           # newest PyPI release

Builds deploy/site/Dockerfile from the repository root exactly as `fly
deploy` does, with the site rendered for the address the container will be
reached at, then asserts the served shape from OUTSIDE the container through
a published port: the server's health path and llms.txt answer, llms.txt
names the site by absolute URL, a page and the Markdown twin it advertises
both answer, the sitemap is XML, a directory named without its slash is
redirected and an unknown URL gets the site's own 404 page (the sitemap's
type and those two need the server after 0.16.0 -- the `xml` content type
and a static mount that falls through on a miss; on the older wheel this
probe passes everything else and fails at exactly that phase), m0serve is
PID 1 (`/proc/1/cmdline`, not trusted from the Dockerfile), and `docker
stop` is the drain's exit 0 well inside its grace rather than SIGKILL at the
deadline.

`--wheel-dir` stages a wheel into deploy/site/wheelhouse and builds with
`PIP_INDEX=--no-index`, so the image is proven with the server the tree has;
`poe smoke-site-image` runs it that way behind `build-wheel`. Without it the
image installs from PyPI, which is what a deployment does. Needs docker; on
a Mac, colima. Timings are recorded through `scripts/emit.py` (a no-op
outside CI).
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from emit import emit  # noqa: E402

WHEELHOUSE = REPO / "deploy" / "site" / "wheelhouse"
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name
    print(f"--- {name}")


def fail(msg):
    sys.exit(f"site_image_probe: FAIL: {PHASE}: {msg}")


def run(*argv, check=True, timeout=600, **kw):
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd=REPO, **kw)
    if check and proc.returncode != 0:
        fail(f"`{' '.join(argv)}` exited {proc.returncode}:\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}")
    return proc


def logs(name):
    p = run("docker", "logs", name, check=False)
    return (p.stdout + p.stderr)[-3000:]


def get(url, timeout=10):
    """(status, headers, body) without following redirects."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(url, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()


def expect(url, status, ctype=None):
    code, headers, body = get(url)
    if code != status:
        fail(f"{url}: want {status}, got {code}")
    if ctype and headers.get("content-type") != ctype:
        fail(f"{url}: want content-type {ctype!r}, got {headers.get('content-type')!r}")
    return headers, body


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--wheel-dir", help="install m0serve from this directory's wheel, not PyPI")
    ap.add_argument("--version", default="", help="pin the PyPI release (default: newest)")
    ap.add_argument("--port", type=int, default=8182)
    ap.add_argument("--keep", action="store_true", help="leave the image and container behind")
    args = ap.parse_args()

    if run("docker", "info", check=False).returncode != 0:
        fail("docker is not available (daemon not running, or not installed)")

    base = f"http://127.0.0.1:{args.port}"
    tag = f"m0serve-docs-probe:{uuid.uuid4().hex[:8]}"
    name = f"m0serve-docs-probe-{uuid.uuid4().hex[:8]}"
    staged = []
    try:
        phase("render the site for the container's address")
        run(sys.executable, "scripts/docsite.py", "--out", "dist/site", "--base-url", base)

        phase("build the image")
        build_args = []
        if args.wheel_dir:
            wheels = sorted(glob.glob(os.path.join(args.wheel_dir, "m0serve-*.whl")))
            if len(wheels) != 1:
                fail(f"--wheel-dir {args.wheel_dir}: want exactly one m0serve wheel, found {wheels}")
            dest = WHEELHOUSE / os.path.basename(wheels[0])
            shutil.copyfile(wheels[0], dest)
            staged.append(dest)
            version = re.match(r"m0serve-([^-]+)-", dest.name).group(1)
            build_args += ["--build-arg", "PIP_INDEX=--no-index", "--build-arg", f"M0SERVE_VERSION={version}"]
        elif args.version:
            build_args += ["--build-arg", f"M0SERVE_VERSION={args.version}"]
        t0 = time.monotonic()
        run("docker", "build", "-q", "-f", "deploy/site/Dockerfile", "-t", tag, *build_args, ".")
        emit("site_image.build_s", round(time.monotonic() - t0, 1), unit="s", task="smoke-site-image")

        phase("start it")
        run("docker", "run", "-d", "--name", name, "-p", f"127.0.0.1:{args.port}:8080", tag)
        # Readiness on a real file, not /health: under a mount at `/` a
        # pre-0.17.0 server answers the health path with the mount's 404,
        # and that is a finding for the fall-through phase below, not a
        # reason to never get there.
        deadline = time.monotonic() + 30
        while True:
            try:
                if get(f"{base}/robots.txt", timeout=2)[0] == 200:
                    break
            except (urllib.error.URLError, OSError, ConnectionError):
                pass
            if run("docker", "inspect", "-f", "{{.State.Running}}", name).stdout.strip() != "true":
                fail("container exited before answering:\n" + logs(name))
            if time.monotonic() > deadline:
                fail("no answer on /robots.txt within 30s:\n" + logs(name))
            time.sleep(0.5)

        phase("m0serve is PID 1")
        argv0 = run("docker", "exec", name, "python", "-c",
                    "print(open('/proc/1/cmdline','rb').read().split(b'\\0')[0].decode())").stdout.strip()
        if os.path.basename(argv0) != "m0serve":
            fail(f"PID 1 is {argv0!r}, not m0serve — the assertions below would test a wrapper")
        served = run("docker", "exec", name, "m0serve", "--version").stdout.strip()
        print(f"container serves with {served}")

        phase("llms.txt and the root text files")
        _, body = expect(f"{base}/llms.txt", 200, "text/plain; charset=utf-8")
        text = body.decode()
        if f"]({base}/docs/spec.md)" not in text:
            fail("llms.txt does not index the spec page by absolute URL")
        if "](docs/" in text:
            fail("llms.txt carries a repository-relative link")
        expect(f"{base}/llms-full.txt", 200, "text/plain; charset=utf-8")
        expect(f"{base}/robots.txt", 200, "text/plain; charset=utf-8")
        _, sitemap = expect(f"{base}/sitemap.xml", 200)
        locs = re.findall(r"<loc>([^<]+)</loc>", sitemap.decode())
        if not locs or not all(l.startswith(base + "/") for l in locs):
            fail(f"sitemap names {len(locs)} URLs, not all under {base}/")

        phase("a page and the Markdown twin it advertises")
        _, page = expect(f"{base}/docs/spec/", 200, "text/html; charset=utf-8")
        m = re.search(r'<link rel="alternate" type="text/markdown" href="([^"]+)"', page.decode())
        if not m:
            fail("/docs/spec/ advertises no Markdown twin")
        expect(m.group(1), 200, "text/plain; charset=utf-8")
        headers, _ = expect(f"{base}/", 200, "text/html; charset=utf-8")
        if "max-age=300" not in headers.get("cache-control", ""):
            fail(f"--static-cache-control not applied: {headers.get('cache-control')!r}")

        phase("what needs the server after 0.16.0: XML sitemap, and a mount that falls through")
        # The sitemap's type (`xml` joined the static content types after
        # 0.16.0; crawlers may refuse an octet-stream sitemap), then the
        # three things a mount that swallows its prefix hides: the server's
        # own /health (which is also what the Fly health check asks), the
        # redirect and the 404 from the application behind the mount.
        expect(f"{base}/sitemap.xml", 200, "application/xml")
        code, _, _ = get(f"{base}/health")
        if code != 200:
            fail(f"/health: want 200, got {code} (the image serves {served}; a static mount "
                 "that swallows its prefix is pre-0.17.0 behaviour)")
        code, headers, _ = get(f"{base}/docs/spec")
        if code != 301 or headers.get("location") != "/docs/spec/":
            fail(f"/docs/spec: want 301 to /docs/spec/, got {code} {headers.get('location')!r} "
                 f"(the image serves {served}; a static mount that swallows its prefix is pre-0.17.0 behaviour)")
        _, body = expect(f"{base}/no/such/page", 404, "text/html; charset=utf-8")
        if b'content="mojo-http scripts/docsite.py"' not in body:
            fail("the 404 is not the site's own page")

        phase("docker stop is the drain, not SIGKILL")
        grace = 10
        t0 = time.monotonic()
        run("docker", "stop", "-t", str(grace), name, timeout=grace + 30)
        elapsed = time.monotonic() - t0
        code = int(run("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout)
        emit("site_image.stop_s", round(elapsed, 1), unit="s", limit=grace, task="smoke-site-image")
        if code != 0:
            fail(f"docker stop: exit {code} after {elapsed:.1f}s (137 is SIGKILL at the deadline)")
        if elapsed > grace - 2:
            fail(f"docker stop: exit 0 only after {elapsed:.1f}s of a {grace}s grace")
        print(f"drained and exited 0 in {elapsed:.1f}s; {len(locs)} sitemap URLs; served by {served}")
        print("site_image_probe: OK")
    finally:
        for p in staged:
            p.unlink(missing_ok=True)
        if not args.keep:
            run("docker", "rm", "-f", name, check=False)
            run("docker", "rmi", "-f", tag, check=False)


if __name__ == "__main__":
    main()
