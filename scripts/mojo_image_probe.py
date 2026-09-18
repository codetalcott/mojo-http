"""A Mojo app's image (deploy/mojo/Dockerfile), proven from outside.

    python3 scripts/mojo_image_probe.py --app blobs --build   # poe smoke-blobs-image
    python3 scripts/mojo_image_probe.py --app hello --build   # poe probe-mojo-image
    python3 scripts/mojo_image_probe.py --app blobs --image TAG

`--build` builds the image from the repository root exactly as `fly deploy`
does, with `--target-cpu` chosen from the DOCKER DAEMON's architecture
(x86-64-v2 on x86-64, generic on arm64; `M0_TARGET_CPU` overrides, never
`native`), then runs it with a published port and probes it through that
port. Nothing reaches into the container to make it work; `docker exec` is
used only to READ what outside cannot see -- PID 1's command line, the
filesystem, the RSS.

What it asserts, for every app:

  * it serves: `/health` answers through the published port;
  * the binary is PID 1: `/proc/1/cmdline` read INSIDE the container is
    exactly `/app/server` (a `sh -c` entrypoint contains the name, is not
    PID 1, and does not forward SIGTERM);
  * no interpreter is in the image: no `python3` or `python` on the path and
    no `python3.x` or `libpython` file anywhere on its filesystem;
  * the image's facts file (`/app/about.json`, written by the image's last
    layer) is true: its version is `pyproject.toml`'s, its target CPU is the
    one asked for, its architecture is the container's, it says no Python,
    and its sizes agree with `du` run now within 1 %;
  * `docker stop` is the drain: exit 0 well inside the grace, never SIGKILL
    at the deadline.

And for `blobs`, the app that does more than answer:

  * the page says what the image is: `/about` is the facts file verbatim,
    and the page's footer carries exactly the version, the "no Python" clause
    and the two sizes the file gives, formatted as the app formats them;
  * the whole of `smoke-blobs`' main run (`blobs_probe.py serve`) passes
    through the published port -- the producer thread steps, frames arrive
    at cadence and well-formed, drops reach every stream, the newest state
    at open, the pause with nobody watching;
  * a held stream through the drain: a stream that has received a frame is
    ENDED BY THE SERVER on `docker stop`, the exit is 0 within 10 s, and the
    log names nothing abandoned -- the producer was told to stop and joined.

Measured and recorded (scripts/emit.py; a no-op outside CI): the build
time, the image size the daemon reports (compressed under the containerd
image store, uncompressed under the classic one -- the probe says which),
the unpacked size, the app's own bytes, RSS idle and with connections held,
and the drain's time. RSS is summed over every process in the container.
"""

import argparse
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from emit import emit  # noqa: E402

BINARY = "/app/server"
HELD = 100
GRACE = 20
DRAIN_BOUND_S = 10

# The probe phase stamp (scripts/phase_stamp_check.py): every phase goes
# through the same docker and HTTP helpers, so an unhandled error inside one
# would name the helper and never the phase being proven.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name
    print(f"--- {name}", flush=True)


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("mojo_image_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    sys.exit(f"mojo_image_probe: FAIL: {PHASE}: {msg}")


def run(*argv, check=True, timeout=900, **kw):
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd=REPO, **kw)
    if check and proc.returncode != 0:
        fail(f"`{' '.join(argv)}` exited {proc.returncode}:\n{proc.stdout[-3000:]}\n{proc.stderr[-3000:]}")
    return proc


def logs(name):
    p = run("docker", "logs", name, check=False)
    return (p.stdout + p.stderr)[-4000:]


def root_sh(name, script):
    """Run `script` inside the container as root, for READING what it holds.

    As root because `du` over the whole filesystem meets directories the
    app's unprivileged user cannot read, and would otherwise under-count.
    """
    return run("docker", "exec", "-u", "0", name, "sh", "-c", script, check=False)


def tree_rss_kb(name):
    """VmRSS summed over every server process in the container, in kB.

    Selected by command line, because the `docker exec` doing the reading
    is itself a process in the container and would count its own shell.
    A forked worker carries its parent's command line, so a supervisor
    and its workers are all counted.
    """
    out = root_sh(
        name,
        "for d in /proc/[0-9]*; do "
        f"  [ \"$(tr '\\0' ' ' < $d/cmdline 2>/dev/null)\" = '{BINARY} ' ] || continue; "
        "  sed -n 's/^VmRSS:[[:space:]]*\\([0-9]*\\) kB/\\1/p' $d/status; "
        "done",
    ).stdout
    values = [int(x) for x in out.split() if x.isdigit()]
    if not values:
        fail(f"no process in the container runs {BINARY}; nothing to measure")
    return sum(values)


def megabytes(n):
    """As `apps/blobs/about.mojo` formats them: decimal MB, one place, half up."""
    tenths = (n + 50_000) // 100_000
    return f"{tenths // 10}.{tenths % 10} MB"


def http_get(port, path, timeout=10):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        return resp.status, resp.read()
    finally:
        conn.close()


def pyproject_version():
    for line in (REPO / "pyproject.toml").read_text().splitlines():
        if line.startswith("version = "):
            return line.split('"')[1]
    fail("pyproject.toml has no version line")


def daemon_arch():
    arch = run("docker", "info", "--format", "{{.Architecture}}").stdout.strip()
    return {"arm64": "aarch64", "amd64": "x86_64"}.get(arch, arch)


def default_target_cpu(arch):
    # As `build-serve`: the oldest CPU each platform must support. Never
    # `native` -- the machine that builds is not the machine that runs.
    return "x86-64-v2" if arch == "x86_64" else "generic"


def image_store():
    """What `docker image inspect`'s Size means on this daemon.

    Under the containerd image store it is the COMPRESSED size of the
    layers (what a registry reports and a pull moves); under the classic
    graph drivers it is the UNPACKED size. The same image reads 29 MB on one
    and about 100 MB on the other, so the recorded number says which it is.
    """
    status = run("docker", "info", "--format", "{{json .DriverStatus}}", check=False).stdout
    return "compressed" if "containerd.snapshotter" in status else "unpacked"


def hold_connections(port, app, n):
    """Open `n` connections and keep them: blobs streams, hello keep-alives.

    Raw sockets rather than a thread each; every one is shown to have been
    ANSWERED (a stream's first frame, a keep-alive's response) before it
    counts as held.
    """
    socks = []
    for _ in range(n):
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        if app == "blobs":
            s.sendall(b"GET /events HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n\r\n")
            want = b"datastar-patch-signals"
        else:
            s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
            want = b"200"
        buf = b""
        deadline = time.monotonic() + 10
        while want not in buf:
            if time.monotonic() > deadline:
                fail(f"connection {len(socks)} was never answered ({buf[:120]!r})")
            chunk = s.recv(65536)
            if not chunk:
                fail(f"connection {len(socks)} was closed before it was answered")
            buf += chunk
        socks.append(s)
    return socks


def build(args, tag, arch):
    phase("build the image")
    cpu = args.target_cpu
    t0 = time.monotonic()
    run("docker", "build", "-q", "-f", "deploy/mojo/Dockerfile",
        "--build-arg", f"APP={args.app}", "--build-arg", f"TARGET_CPU={cpu}",
        "-t", tag, ".", timeout=1800)
    took = round(time.monotonic() - t0, 1)
    print(f"built {tag} for {arch} --target-cpu {cpu} in {took}s")
    emit(f"mojo_image.{args.app}.build_s", took, unit="s", task=args.task)


def probe(args, tag, arch):
    name = f"m0-image-probe-{uuid.uuid4().hex[:8]}"
    port = args.port
    held = []
    try:
        phase("what the daemon says about the image")
        size, iarch = run("docker", "image", "inspect", tag, "--format",
                          "{{.Size}} {{.Architecture}}").stdout.split()
        store = image_store()
        print(f"image {tag}: {int(size):,} bytes ({store}, as this daemon counts), {iarch}")
        emit(f"mojo_image.{args.app}.{store}_bytes", int(size), unit="B", task=args.task)

        phase("start it")
        run("docker", "run", "-d", "--name", name, "-p", f"127.0.0.1:{port}:8080", tag)
        deadline = time.monotonic() + 30
        while True:
            try:
                if http_get(port, "/health", timeout=2)[0] == 200:
                    break
            except (OSError, http.client.HTTPException):
                pass
            if run("docker", "inspect", "-f", "{{.State.Running}}", name).stdout.strip() != "true":
                fail("the container exited before answering:\n" + logs(name))
            if time.monotonic() > deadline:
                fail("no answer on /health within 30 s:\n" + logs(name))
            time.sleep(0.25)

        phase("the binary is PID 1")
        # Read INSIDE the container: `docker exec ... < /proc/1/cmdline` would
        # redirect from the host's own PID 1.
        argv = run("docker", "exec", name, "cat", "/proc/1/cmdline").stdout.split("\0")
        argv = [a for a in argv if a]
        if argv != [BINARY]:
            fail(f"PID 1 is {argv!r}, not exactly [{BINARY!r}] -- a wrapper is not PID 1 and "
                 "does not forward SIGTERM")

        phase("no interpreter in the image")
        found = root_sh(
            name,
            "command -v python3; command -v python; "
            "find / -xdev \\( -name 'python[0-9]*' -o -name 'libpython*' \\) "
            "\\( -type f -o -type l \\) 2>/dev/null",
        ).stdout.split()
        if found:
            fail(f"an interpreter is in the image: {found}")

        phase("the image's facts are true")
        raw = run("docker", "exec", name, "cat", "/app/about.json").stdout
        facts = json.loads(raw)
        want = {
            "app": args.app,
            "version": pyproject_version(),
            "target_cpu": args.target_cpu,
            "arch": run("docker", "exec", name, "uname", "-m").stdout.strip(),
            "python": False,
        }
        for key, value in want.items():
            if facts.get(key) != value:
                fail(f"about.json says {key}={facts.get(key)!r}; the image is {value!r}")
        unpacked = int(root_sh(name, "du -sxb / | cut -f1").stdout.split()[0])
        app_bytes = int(root_sh(name, "du -sb /app | cut -f1").stdout.split()[0])
        for key, measured in (("image_bytes", unpacked), ("app_bytes", app_bytes)):
            claimed = facts.get(key)
            if not isinstance(claimed, int) or abs(claimed - measured) > measured * 0.01:
                fail(f"about.json says {key}={claimed}; du measures {measured} now")
        print(f"unpacked {unpacked:,} bytes, {app_bytes:,} of it /app; facts agree")
        emit(f"mojo_image.{args.app}.unpacked_bytes", unpacked, unit="B", task=args.task)
        emit(f"mojo_image.{args.app}.app_bytes", app_bytes, unit="B", task=args.task)

        if args.app == "blobs":
            phase("the page says what the image is")
            status, body = http_get(port, "/about")
            if status != 200 or json.loads(body) != facts:
                fail(f"/about answered {status} {body[:200]!r}, not the image's facts file")
            status, body = http_get(port, "/")
            page = body.decode()
            line = (f"m0 {facts['version']} · pure Mojo · no Python in this image · "
                    f"{megabytes(facts['image_bytes'])} unpacked, "
                    f"{megabytes(facts['app_bytes'])} of it this app")
            if status != 200 or line not in page:
                start = page.find("<footer")
                fail(f"the page's footer is not the image's facts: want {line!r}, "
                     f"page has {page[start:start + 300]!r}")
            print(f"footer: {line}")

        phase("RSS, idle")
        idle = tree_rss_kb(name)
        print(f"RSS idle: {idle} kB")
        emit(f"mojo_image.{args.app}.rss_idle_kb", idle, unit="kB", task=args.task)

        if args.app == "blobs":
            phase("the app, through the image")
            res = run(sys.executable, str(REPO / "scripts" / "blobs_probe.py"), "serve", str(port),
                      check=False, timeout=180)
            if res.returncode != 0:
                fail(f"blobs_probe serve failed through the image:\n{res.stdout}{res.stderr}\n" + logs(name))
            print(f"serve: {res.stdout.strip()}")

        phase(f"RSS, {HELD} connections held")
        held = hold_connections(port, args.app, HELD)
        time.sleep(2)
        busy = tree_rss_kb(name)
        print(f"RSS with {HELD} {'streams' if args.app == 'blobs' else 'keep-alive connections'} held: {busy} kB")
        emit(f"mojo_image.{args.app}.rss_held_kb", busy, unit="kB", task=args.task)
        for s in held:
            s.close()
        held = []

        phase("docker stop is the drain, not SIGKILL")
        holder = None
        flag = None
        if args.app == "blobs":
            # A stream that has received a frame, so the producer is running
            # IN the image when the signal lands, and the server -- not the
            # client, not a reset -- must end it.
            flag = Path(tempfile.mkdtemp()) / "holding"
            holder = subprocess.Popen(
                [sys.executable, str(REPO / "scripts" / "blobs_probe.py"), "hold", str(port), str(flag)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            deadline = time.monotonic() + 10
            while not flag.exists():
                if holder.poll() is not None or time.monotonic() > deadline:
                    fail("the held stream never got a frame: " + (holder.stdout.read() if holder.poll() is not None else ""))
                time.sleep(0.05)
        t0 = time.monotonic()
        run("docker", "stop", "-t", str(GRACE), name, timeout=GRACE + 30)
        elapsed = time.monotonic() - t0
        code = int(run("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout)
        emit(f"mojo_image.{args.app}.stop_s", round(elapsed, 1), unit="s", limit=DRAIN_BOUND_S, task=args.task)
        text = logs(name)
        if code != 0:
            fail(f"docker stop: exit {code} after {elapsed:.1f}s (137 is SIGKILL at the deadline)\n" + text)
        if elapsed >= DRAIN_BOUND_S:
            fail(f"docker stop: exit 0 only after {elapsed:.1f}s; the drain's bound is {DRAIN_BOUND_S}s")
        if "abandoned" in text or "still running" in text:
            fail("the drain left something behind:\n" + text)
        said = ""
        if holder is not None:
            out, _ = holder.communicate(timeout=30)
            if holder.returncode != 0:
                fail(f"the held stream was not ended by the server: {out.strip()}")
            said = f"; {out.strip()}"
        print(f"drained: exit 0 in {elapsed:.1f}s{said}")
    finally:
        for s in held:
            s.close()
        if not args.keep:
            run("docker", "rm", "-f", name, check=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--app", required=True, choices=["hello", "blobs"])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--build", action="store_true", help="build deploy/mojo/Dockerfile, then probe")
    mode.add_argument("--image", help="probe an image already built")
    ap.add_argument("--target-cpu", default="", help="default: M0_TARGET_CPU, else by the daemon's arch")
    ap.add_argument("--port", type=int, default=18099)
    ap.add_argument("--task", default="", help="the poe task the measurements are recorded under")
    ap.add_argument("--keep", action="store_true", help="leave the image and container behind")
    args = ap.parse_args()
    if run("docker", "info", check=False).returncode != 0:
        fail("docker is not available (daemon not running, or not installed)")
    arch = daemon_arch()
    args.target_cpu = args.target_cpu or os.environ.get("M0_TARGET_CPU") or default_target_cpu(arch)
    if args.target_cpu == "native":
        fail("--target-cpu native builds for this machine, not the one that runs the image")
    args.task = args.task or None
    tag = args.image or f"m0-image-probe-{args.app}:{uuid.uuid4().hex[:8]}"
    try:
        if args.build:
            build(args, tag, arch)
        probe(args, tag, arch)
    finally:
        if args.build and not args.keep:
            run("docker", "rmi", "-f", tag, check=False)
    print(f"mojo_image_probe: {args.app} OK")


if __name__ == "__main__":
    main()
