#!/usr/bin/env python3
"""Hold m0serve to SPEC E33, for `poe smoke-serve-parallel-runtime`.

    serve_parallel_probe.py BIN PLAIN BASE_PORT

`BIN` is m0serve built with `apps/serve_parallel/mount` in place of the
demo mount, so it links MAX's parallel runtime (`libAsyncRTMojoBindings`);
`PLAIN` is the shipped `bin/m0serve`, which imports nothing from MAX, and
is the control. Every run mounts the bare WSGI app at the root and the Mojo
mount at `/par` (`--mount /=bareapp.wsgi --mount /par=mojo`). Seven
phases:

  doctor refuses prefork    `--doctor --workers 2` exits 2 and the report's
                            `workers-vs-parallel-runtime` check fails, its
                            fix naming `--spawn-workers`; the report says
                            `topology.parallel_runtime` is true
  serve refuses prefork     `--workers 2` exits 2 having bound nothing --
                            this is the phase a removed refusal fails on:
                            the server SERVES, and is stopped by pid
  doctor refuses reload     `--doctor --reload` exits 2 on the same check:
                            `--reload` supervises even one worker, forked
  doctor passes spawn       `--doctor --workers 2 --spawn-workers` and
                            `--doctor --reload --spawn-workers` exit 0,
                            the check passing and saying the workers exec
  the shipped binary's      PLAIN `--doctor --workers 2` passes where the
  verdict follows its       file's own load commands lack the runtime
  image                     (Linux) and is refused where they name it --
                            on macOS `mojo build` links the runtime into
                            every binary made beside an installed
                            `max-core`, source or no source -- the doctor's
                            `parallel_runtime` agreeing either way: the
                            refusal is a fact about the image, not a rule
                            about the flag
  spawned workers serve     `--workers 2 --spawn-workers`: /par/ser and
  parallelize               /par/par agree, 16 /par/par at once all answer,
                            BOTH exec'd images answer one (by `x-pid`), and
                            SIGTERM drains the supervisor to 0
  one process serves it     no topology flag: /par/par answers from a pool
                            thread (`x-thread` >= 0)

What is never done here: a request to /par/par under two forked workers.
On the Mojo host that request never answered, the worker's loop stayed
wedged and SIGTERM did not end the process after 12 s
(docs/notes/threads-first-for-m0-apps.md); every wait below is bounded so
that a refusal which stopped refusing fails in seconds, on the served
prefork, and never hangs the job.

Prints `serve_parallel_probe OK` and two `par_us N` / `ser_us N` lines
(the job's own time on each route under the spawned workers, for the
recorder), or exits 1 naming the phase. Stdlib only.
"""
from __future__ import annotations

import http.client
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import traceback

TIMEOUT = 15.0
CHECK = "workers-vs-parallel-runtime"
RUNTIME = "libAsyncRTMojoBindings"

# Which phase is running, for failures and for the crash handler: the phases
# share every helper here, and a traceback names the helper, never what was
# being proven (scripts/phase_stamp_check.py).
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("serve_parallel_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("serve_parallel_probe: FAIL: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


def clean_env() -> dict:
    return {k: v for k, v in os.environ.items() if not k.startswith("M0_")}


def mounts(port: int) -> list:
    """The one mount table every phase serves, on `port`."""
    return [
        "--mount", "/=bareapp.wsgi", "--mount", "/par=mojo",
        "--app-dir", "apps/wsgi_bare", "--port", str(port),
    ]


def get(port: int, path: str, timeout: float = TIMEOUT):
    """(status, body, headers) for one GET, or raises."""
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        c.request("GET", path)
        r = c.getresponse()
        body = r.read().decode("utf-8", "replace")
        return r.status, body, {k.lower(): v for k, v in r.getheaders()}
    finally:
        c.close()


def healthy(port: int) -> bool:
    try:
        return get(port, "/", timeout=1.0)[0] == 200
    except OSError:
        return False


def report_of(stdout: str) -> dict:
    lines = [ln for ln in stdout.splitlines() if ln.strip()]
    if not lines:
        fail("the doctor printed nothing")
    try:
        return json.loads(lines[-1])
    except ValueError:
        fail("the doctor's last line is not JSON: %r" % lines[-1][:200])


def check_named(report: dict, name: str) -> dict:
    for c in report.get("checks", []):
        if c.get("name") == name:
            return c
    fail("the report has no check named %r: %s" % (name, [c.get("name") for c in report.get("checks", [])]))


def names_runtime(binary: str) -> bool:
    """Whether `binary`'s own load commands name MAX's parallel runtime.

    The fact `parallel_runtime_linked` reads off the loaded images, taken
    here from the file instead (`otool -L`, `readelf -d`; the runtime is a
    direct dependency wherever it is linked), so the doctor can be held to
    it. Without the tool, the bundle beside the binary is the closure
    `build-serve` found, and answers the same question.
    """
    argv = ["otool", "-L", binary] if sys.platform == "darwin" else ["readelf", "-d", binary]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    if out:
        return RUNTIME in out
    beside = os.path.dirname(os.path.abspath(binary))
    return any(n.startswith(RUNTIME) for n in os.listdir(beside))


def doctor(binary: str, args: list) -> tuple:
    try:
        p = subprocess.run(
            [binary, "--doctor", *args], env=clean_env(),
            capture_output=True, text=True, timeout=60,
        )
    except subprocess.TimeoutExpired:
        fail("--doctor had not exited after 60 s: it is serving")
    return p.returncode, p.stdout, p.stderr


def refused(binary: str, args: list, why: str) -> dict:
    """The doctor exits 2 on CHECK, the fix names --spawn-workers; the report."""
    code, out, err = doctor(binary, args)
    if code != 2:
        fail("--doctor %s exited %d, wanted 2 (%s):\n%s%s" % (args, code, why, out[-1500:], err[-1500:]))
    report = report_of(out)
    if report.get("exit") != 2 or report.get("ok") is not False:
        fail("the report says exit=%r ok=%r" % (report.get("exit"), report.get("ok")))
    check = check_named(report, CHECK)
    if check.get("ok") is not False:
        fail("the doctor passed %s (%s): %r" % (CHECK, why, check))
    if "--spawn-workers" not in check.get("fix", ""):
        fail("the fix does not name --spawn-workers: %r" % check.get("fix"))
    return report


def passed(binary: str, args: list, why: str) -> dict:
    """The doctor exits 0 with CHECK ok; the check."""
    code, out, err = doctor(binary, args)
    if code != 0:
        fail("--doctor %s exited %d, wanted 0 (%s):\n%s%s" % (args, code, why, out[-1500:], err[-1500:]))
    report = report_of(out)
    check = check_named(report, CHECK)
    if check.get("ok") is not True:
        fail("the doctor failed %s (%s): %r" % (CHECK, why, check))
    return report


def stop(p: subprocess.Popen, what: str) -> int:
    """SIGTERM, a bounded wait, then SIGKILL as a failure."""
    p.send_signal(signal.SIGTERM)
    try:
        return p.wait(timeout=20)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        fail("%s still running 20 s after SIGTERM" % what)


def start(binary: str, args: list, port: int, log: str) -> subprocess.Popen:
    """Run for real and wait for /; a process that exits first is the failure."""
    out = open(log, "w")
    p = subprocess.Popen([binary, *args], env=clean_env(), stdout=out, stderr=out)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if p.poll() is not None:
            fail("%s exited %d before serving:\n%s" % (args, p.returncode, open(log).read()[-2000:]))
        if healthy(port):
            return p
        time.sleep(0.05)
    p.kill()
    fail("%s not healthy on port %d after 60 s" % (args, port))


def expect_route(port: int, path: str, prefix: str) -> tuple:
    """(job us, sum, x-thread, x-pid) for one answered route."""
    status, body, headers = get(port, path)
    if status != 200 or not body.startswith(prefix):
        fail("%s answered %d %r" % (path, status, body[:80]))
    m = re.match(r"(?:par|ser)=(\d+)us sum=(\d+)", body)
    if not m:
        fail("%s body is not the route's shape: %r" % (path, body[:80]))
    return int(m.group(1)), int(m.group(2)), headers.get("x-thread"), headers.get("x-pid")


def concurrent_par(port: int, n: int, what: str) -> set:
    """`n` /par/par at once, every one answered within the bound; the pids."""
    errors: list = []
    pids: list = []

    def one():
        try:
            pids.append(expect_route(port, "/par/par", "par=")[3])
        except SystemExit:
            errors.append(PHASE)
        except Exception as e:  # a timeout here is the hang, reported not raised
            errors.append(repr(e))

    ts = [threading.Thread(target=one) for _ in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=TIMEOUT + 5)
    if any(t.is_alive() for t in ts):
        fail("a concurrent /par/par did not answer within %.0f s (%s)" % (TIMEOUT, what))
    if errors:
        fail("concurrent /par/par failed (%s): %s" % (what, errors[:3]))
    return set(pids)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    binary, plain, base = sys.argv[1], sys.argv[2], int(sys.argv[3])
    logs = os.path.dirname(os.path.abspath(binary))
    port = base

    phase("doctor refuses prefork")
    report = refused(binary, [*mounts(port), "--workers", "2"], "two forked workers")
    if report.get("topology", {}).get("parallel_runtime") is not True:
        fail("the report does not say the runtime is linked: %r" % report.get("topology"))

    phase("serve refuses prefork")
    log = os.path.join(logs, "prefork.log")
    with open(log, "w") as lf:
        p = subprocess.Popen(
            [binary, *mounts(port), "--workers", "2"],
            env=clean_env(), stdout=lf, stderr=lf,
        )
        deadline = time.monotonic() + 60
        served = False
        while time.monotonic() < deadline and p.poll() is None:
            if healthy(port):
                served = True
                break
            time.sleep(0.05)
        if served:
            # Never ask this server for /par/par: that is the hang the
            # refusal exists to prevent. Stop it by pid, bounded, and fail.
            stop(p, "the served prefork")
            fail("--workers 2 was SERVED with the parallel runtime linked; the refusal is gone")
        if p.poll() is None:
            p.kill()
            p.wait()
            fail("--workers 2 neither exited nor served in 60 s")
    text = open(log).read()
    if p.returncode != 2:
        fail("--workers 2 exited %d, wanted 2:\n%s" % (p.returncode, text[-1500:]))
    if "--spawn-workers" not in text or "m0serve:" not in text:
        fail("the refusal did not name --spawn-workers under `m0serve:`:\n%s" % text[-1500:])

    phase("doctor refuses reload")
    refused(binary, [*mounts(port), "--reload"], "--reload supervises a forked worker")

    phase("doctor passes spawn")
    for shape in (["--workers", "2", "--spawn-workers"], ["--reload", "--spawn-workers"]):
        report = passed(binary, [*mounts(port), *shape], "spawned workers exec")
        check = check_named(report, CHECK)
        if "exec" not in check.get("detail", ""):
            fail("the passing check under %s should say the workers exec: %r" % (shape, check))
        if report.get("topology", {}).get("worker_mode") != "spawn":
            fail("the report under %s does not say worker_mode=spawn: %r" % (shape, report.get("topology")))

    phase("the shipped binary's verdict follows its image")
    # bin/m0serve imports nothing from MAX. Whether its image carries the
    # runtime anyway is the toolchain's to decide, and it decides
    # differently per platform: on Linux it does not; on macOS a build
    # made beside an installed max-core links libAsyncRTMojoBindings
    # whether or not the source names it (CI, 2026-09-25: the same
    # demo-mount binary bundled three runtime files in the MAX-free
    # apple-silicon job and four after `uv sync --group max`). So the
    # control reads the file's own load commands and holds the doctor to
    # them both ways -- what it proves is that the refusal is a fact about
    # the image, not a rule about the flag.
    if not names_runtime(binary):
        fail("the MAX mount's binary does not name %s; the gate's premise is gone" % RUNTIME)
    if names_runtime(plain):
        report = refused(plain, [*mounts(port), "--workers", "2"], "the shipped binary carries the runtime here")
        if report.get("topology", {}).get("parallel_runtime") is not True:
            fail("the shipped m0serve names %s but the doctor reports it unlinked: %r" % (RUNTIME, report.get("topology")))
        print("shipped binary: names %s (built beside an installed MAX on %s); refused at two workers, as its image says" % (RUNTIME, sys.platform))
    else:
        report = passed(plain, [*mounts(port), "--workers", "2"], "the shipped m0serve links no MAX")
        if report.get("topology", {}).get("parallel_runtime") is not False:
            fail("the shipped m0serve reports the runtime as linked: %r" % report.get("topology"))
        if "not linked" not in check_named(report, CHECK).get("detail", ""):
            fail("the shipped m0serve's check should say the runtime is not linked: %r" % check_named(report, CHECK))
        print("shipped binary: does not name %s; passes at two workers, as its image says" % RUNTIME)

    phase("spawned workers serve parallelize")
    port += 1
    log = os.path.join(logs, "spawn.log")
    p = start(binary, [*mounts(port), "--workers", "2", "--spawn-workers"], port, log)
    ser_us, ser_sum, _, _ = expect_route(port, "/par/ser", "ser=")
    par_us, par_sum, _, _ = expect_route(port, "/par/par", "par=")
    if ser_sum != par_sum:
        stop(p, "the spawned server")
        fail("the two routes disagree: ser sum=%d par sum=%d" % (ser_sum, par_sum))
    # Both exec'd images must answer a parallelize, not only the one that
    # won the first accepts: rounds of 16 at once until two pids have, at
    # most ten (accept sharing skips a sibling that has not announced
    # itself yet, so one round says nothing about the other worker).
    pids: set = set()
    for _ in range(10):
        pids |= concurrent_par(port, 16, "spawned workers")
        if len(pids) >= 2:
            break
    if len(pids) != 2:
        stop(p, "the spawned server")
        fail("expected /par/par answered by 2 exec'd workers, saw pids %r" % sorted(pids))
    if str(p.pid) in pids:
        stop(p, "the spawned server")
        fail("the supervisor itself answered /par/par")
    code = stop(p, "the spawned server")
    if code != 0:
        fail("--workers 2 --spawn-workers drained with exit %d:\n%s" % (code, open(log).read()[-1500:]))

    phase("one process serves parallelize")
    port += 1
    p = start(binary, mounts(port), port, os.path.join(logs, "one.log"))
    _, _, thread, _ = expect_route(port, "/par/par", "par=")
    if thread is None or int(thread) < 0:
        stop(p, "the single process")
        fail("/par/par in one process answered from x-thread %r, wanted a pool thread" % thread)
    code = stop(p, "the single process")
    if code != 0:
        fail("one process drained with exit %d" % code)

    print("par_us %d" % par_us)
    print("ser_us %d" % ser_us)
    print("serve_parallel_probe OK: refused at two forked workers and under --reload, served by two exec'd workers and by one process, the shipped binary's verdict held to its own load commands; /par/par %d us against /par/ser %d us" % (par_us, ser_us))
    return 0


if __name__ == "__main__":
    sys.exit(main())
