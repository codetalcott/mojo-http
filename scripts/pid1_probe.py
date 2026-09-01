"""`docker stop` on m0serve as PID 1: the drain's exit 0, never SIGKILL.

`docker stop` is SIGTERM to PID 1 and nothing else, and PID 1 gets no
default signal dispositions from the kernel: a SIGTERM arriving with no
handler installed is *discarded*, not fatal. This server installs its
handlers post-fork by design (`install_shutdown_signals`, and the
supervisor's `_arm_signal_propagation` inside `fork_all`), so every
in-process SIGTERM gate — `smoke-shutdown` first among them — proves the
handler works *once installed* while proving nothing about the one
environment where the default disposition cannot paper over a missing
install. This probe runs the shipped wheel exec'd as PID 1 in a container
and stops it, in both process shapes.

What each exit code means here, and why the probe names all three:

- **0** — the handler ran, the drain finished, the process left on its own.
- **137** — SIGKILL at the deadline: SIGTERM was discarded, which as PID 1
  is exactly what a missing install looks like. The elapsed time sits at
  the full grace, so the probe reports both together.
- **143** — the *default* disposition killed the process, which PID 1 never
  has: the premise failed and something else was PID 1. The probe also
  checks `/proc/1/cmdline` directly before stopping, because a gate that
  can silently run its assertions against a shell wrapper is void.

The workers shape is `smoke-shutdown`'s supervisor claim moved into the
container: the supervisor alone is signalled, and it must reap both workers
(their "exited cleanly" lines in the log — a worker killed by a propagated
signal it had no handler for prints "killed by signal" instead) and leave
promptly. "signal propagation unavailable" in the log is the degraded arm
announcing itself (`_arm_signal_propagation` declining a dead slot), which
is the honesty check available from outside the process.

Needs docker and a built Linux wheel (`poe smoke-pid1` runs it behind
`build-wheel`); `--wheel-dir` points it at a wheel built elsewhere, which is
how it runs on a Mac against colima. Timings are recorded through
`scripts/emit.py` (a no-op outside CI).
"""

import argparse
import subprocess
import sys
import tempfile
import time
import traceback
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from emit import emit  # noqa: E402

# The probe phase stamp (scripts/phase_stamp_check.py): the docker helpers
# are shared by every phase, so an unhandled error inside one would name the
# call that failed and never the phase being proven.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("pid1_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped

APP = (
    'def application(environ, start_response):\n'
    '    start_response("200 OK", [("Content-Type", "text/plain")])\n'
    '    return [b"pid1 ok"]\n'
)

# The health probe runs INSIDE the container (`--network none`, and slim
# ships neither wget nor curl — Python's urllib is the one thing a python
# image is guaranteed to have; same reasoning as release.yml's probe).
HEALTH = (
    "import urllib.request;"
    "print(urllib.request.urlopen('http://127.0.0.1:8123/', timeout=2)"
    ".read().decode())"
)

# Every process whose argv[0] names the m0serve binary — the supervisor and
# each worker. /proc is scanned rather than `ps`, which slim does not ship.
# argv[0] ONLY, never the whole cmdline: `sh -c 'pip install … m0serve …'`
# carries the binary's name inside its -c string, so a substring check over
# the full cmdline counts the shell as a server — which is exactly how the
# PID 1 premise check below first failed its own sabotage.
COUNT_PROCS = (
    "import glob;"
    "print(sum('m0serve' in open(p, 'rb').read().split(b'\\0')[0]"
    ".decode('utf-8', 'replace')"
    " for p in glob.glob('/proc/[0-9]*/cmdline')))"
)


def fail(msg):
    sys.exit(f"pid1_probe: FAIL: {PHASE}: {msg}")


def run(*argv, check=True, timeout=120):
    proc = subprocess.run(
        argv, capture_output=True, text=True, timeout=timeout
    )
    if check and proc.returncode != 0:
        fail(f"`{' '.join(argv)}` exited {proc.returncode}: {proc.stderr.strip()}")
    return proc


def docker_exec(name, *argv, check=True):
    return run("docker", "exec", name, *argv, check=check)


def wait_healthy(name, deadline_s):
    """Poll the app through `docker exec` until it answers, or fail with logs."""
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        state = run(
            "docker", "inspect", "-f", "{{.State.Running}}", name, check=False
        ).stdout.strip()
        if state != "true":
            logs = run("docker", "logs", name, check=False)
            fail(
                f"[{name}] container exited before becoming healthy\n"
                f"{logs.stdout}{logs.stderr}"
            )
        probe = docker_exec(name, "python", "-c", HEALTH, check=False)
        if "pid1 ok" in probe.stdout:
            return
        time.sleep(0.5)
    logs = run("docker", "logs", name, check=False)
    fail(
        f"[{name}] never became healthy in {deadline_s}s\n"
        f"{logs.stdout}{logs.stderr}"
    )


def assert_pid1_is_m0serve(name):
    """The premise, checked rather than trusted: PID 1 is the server binary.

    The container command is `sh -c '... && exec m0serve ...'` and the
    console script `os.execve`s the real binary, so PID 1 must be m0serve
    itself by the time the app answers. If a future edit drops the `exec`
    or the shim stops exec'ing, the shell or the shim is PID 1, the kernel
    gives IT the default-disposition shield, and every assertion below
    passes for the wrong process — 143 in the exit code is the same failure
    observed later, this is it observed at the source.
    """
    argv0 = docker_exec(
        name, "python", "-c",
        "print(open('/proc/1/cmdline','rb').read().split(b'\\0')[0]"
        ".decode('utf-8','replace'))",
    ).stdout.strip()
    # argv[0], never the whole cmdline: sh's own cmdline CONTAINS the string
    # "m0serve" (it is inside the -c argument), so a substring check over the
    # full cmdline blesses the shell — this check's first sabotage was caught
    # by the stop deadline instead of here, which is what this fixed.
    if "m0serve" not in argv0:
        fail(
            f"[{name}] PID 1 is {argv0!r}, not m0serve — "
            f"the exec chain broke and this probe is testing the wrong process"
        )


def stop_and_measure(name, grace_s):
    """`docker stop`, timed. Returns (exit_code, elapsed_s, logs)."""
    t0 = time.monotonic()
    run("docker", "stop", "-t", str(grace_s), name, timeout=grace_s + 30)
    elapsed = time.monotonic() - t0
    code = int(
        run("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout
    )
    logs = run("docker", "logs", name, check=False)
    return code, elapsed, logs.stdout + logs.stderr


def assert_stopped_clean(name, code, elapsed, grace_s, shape):
    prompt = 0.8 * grace_s
    if code == 137:
        fail(
            f"[{shape}] docker stop fell through to SIGKILL at the deadline "
            f"(exit 137, {elapsed:.1f}s of a {grace_s}s grace): SIGTERM was "
            f"discarded, which as PID 1 means no handler was installed"
        )
    if code == 143:
        fail(
            f"[{shape}] exit 143 is the DEFAULT disposition acting, which "
            f"PID 1 does not have — the process stopped was not PID 1"
        )
    if code != 0:
        fail(f"[{shape}] exited {code} on docker stop, want the drain's 0")
    if elapsed >= prompt:
        fail(
            f"[{shape}] exit 0 but only after {elapsed:.1f}s of a {grace_s}s "
            f"grace — that is not the idle drain (sub-second), something "
            f"held the exit to the deadline"
        )
    print(f"[{shape}] drained and exited 0 in {elapsed:.1f}s (grace {grace_s}s)")


def start(name, image, stage, extra_env):
    env_flags = []
    for pair in extra_env:
        env_flags += ["-e", pair]
    # create + cp + start rather than `docker run -v`: a bind mount needs
    # the host path to be shareable with the daemon's VM, which a macOS
    # temp dir under colima silently is not (it mounts EMPTY). `docker cp`
    # into the created container works against any daemon.
    run(
        "docker", "create", "--name", name, "--network", "none",
        *env_flags, image, "sh", "-c",
        # `exec` is load-bearing: without it sh stays PID 1 and the test is
        # void — which assert_pid1_is_m0serve then reports rather than trusts.
        "pip install --quiet --no-index --no-deps /w/*.whl"
        " && cp /w/app.py /tmp && cd /tmp"
        " && exec m0serve app:application --port 8123",
    )
    run("docker", "cp", stage, f"{name}:/w")
    run("docker", "start", name)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--wheel-dir", default="dist/wheels")
    ap.add_argument("--image", default="python:3.12-slim")
    ap.add_argument("--grace", type=int, default=10)
    ap.add_argument("--healthy-timeout", type=int, default=120)
    ap.add_argument(
        "--shape", choices=("single", "workers", "both"), default="both",
        help="which process shape to drive — the sabotage runs use one at a "
        "time so each failure is caught by the layer that names it",
    )
    args = ap.parse_args()

    phase("preflight")
    if run("docker", "info", check=False).returncode != 0:
        fail("docker is not available (daemon not running, or not installed)")
    wheels = sorted(Path(args.wheel_dir).glob("*.whl"))
    if len(wheels) != 1:
        fail(f"want exactly one wheel in {args.wheel_dir}, found {len(wheels)}")

    token = uuid.uuid4().hex[:8]
    names = []
    with tempfile.TemporaryDirectory() as stage:
        (Path(stage) / "app.py").write_text(APP)
        (Path(stage) / wheels[0].name).write_bytes(wheels[0].read_bytes())

        try:
            # -- Shape 1: one process, no supervisor -------------------------
            if args.shape in ("single", "both"):
                phase("single: start and become healthy")
                single = f"m0pid1-single-{token}"
                names.append(single)
                start(single, args.image, stage, [])
                wait_healthy(single, args.healthy_timeout)
                assert_pid1_is_m0serve(single)
                phase("single: docker stop")
                code, elapsed, _ = stop_and_measure(single, args.grace)
                assert_stopped_clean(single, code, elapsed, args.grace, "single")
                emit("pid1_stop_ms", int(elapsed * 1000), unit="ms",
                     limit=int(args.grace * 800), task="smoke-pid1")

            if args.shape == "single":
                for name in names:
                    run("docker", "rm", "-f", name, check=False)
                print("pid1_probe OK (single only)")
                return

            # -- Shape 2: the supervisor as PID 1, reaping two workers ------
            phase("workers: start and become healthy")
            workers = f"m0pid1-workers-{token}"
            names.append(workers)
            start(workers, args.image, stage, ["M0_WORKERS=2"])
            wait_healthy(workers, args.healthy_timeout)
            assert_pid1_is_m0serve(workers)
            procs = int(docker_exec(workers, "python", "-c", COUNT_PROCS).stdout)
            if procs < 3:
                fail(
                    f"[workers] {procs} m0serve process(es) before the stop, "
                    f"want supervisor + 2 workers — the shape under test never"
                    f" existed"
                )
            phase("workers: docker stop")
            code, elapsed, logs = stop_and_measure(workers, args.grace)
            if "signal propagation unavailable" in logs:
                fail(
                    "[workers] the supervisor declined to arm signal "
                    "propagation and said so — the degraded path is running "
                    "in the container"
                )
            assert_stopped_clean(workers, code, elapsed, args.grace, "workers")
            if logs.count("exited cleanly") < 2:
                fail(
                    f"[workers] fewer than two workers reported a clean exit "
                    f"— a worker killed by a signal it had no handler for is "
                    f"not a drain\n{logs}"
                )
            if "killed by signal" in logs:
                fail(
                    f"[workers] a worker died BY the signal rather than "
                    f"draining on it — its own handler was never installed"
                    f"\n{logs}"
                )
            if "respawn" in logs:
                fail(f"[workers] a worker was respawned during shutdown\n{logs}")
            emit("pid1_workers_stop_ms", int(elapsed * 1000), unit="ms",
                 limit=int(args.grace * 800), task="smoke-pid1")
        finally:
            for name in names:
                run("docker", "rm", "-f", name, check=False)

    print("pid1_probe OK")


if __name__ == "__main__":
    main()
