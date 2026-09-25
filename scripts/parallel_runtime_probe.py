#!/usr/bin/env python3
"""Hold the Mojo host to SPEC E32, for `poe smoke-parallel-runtime`.

    parallel_runtime_probe.py BIN BASE_PORT

`BIN` is `apps/host_parallel/probe.mojo` built against MAX's Mojo packages,
so it links the parallel runtime (`libAsyncRTMojoBindings`). Six phases,
each one shape of the host:

  doctor refuses prefork    `--doctor --workers 2` exits 78 and the report's
                            `workers-vs-parallel-runtime` check fails, its
                            fix naming `--threads (M0_THREADS)`
  serve refuses prefork     `--workers 2` exits 78 having bound nothing --
                            this is the phase a removed refusal fails on:
                            the server SERVES, and is stopped by pid
  doctor passes threads     `--doctor --threads 2` exits 0, the check ok
  threads serve parallelize `--threads 2`: /ser and /par answer, eight
                            /par at once all answer, SIGTERM drains to 0
  pool serves parallelize   `--blocking-threads 2`: /par answers from a
                            pool thread (`x-thread` >= 0)
  one loop serves it        no flags: /par answers on the loop (-1)

What is never done here: a request to /par under two forked workers. Before
the refusal that request never answered, the worker's loop stayed wedged
and SIGTERM did not end the process after 12 s; every wait below is
bounded so that a refusal which stopped refusing fails in seconds, on the
served prefork, and never hangs the job.

Prints `parallel_runtime_probe OK` and two `par_us N` / `ser_us N` lines
(the job's own time on each route under `--threads 2`, for the recorder),
or exits 1 naming the phase. Stdlib only.
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

# Which phase is running, for failures and for the crash handler: the phases
# share every helper here, and a traceback names the helper, never what was
# being proven (scripts/phase_stamp_check.py).
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("parallel_runtime_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("parallel_runtime_probe: FAIL: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


def clean_env() -> dict:
    return {k: v for k, v in os.environ.items() if not k.startswith("M0_")}


def get(port: int, path: str, timeout: float = TIMEOUT):
    """(status, body, x-thread) for one GET, or raises."""
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        c.request("GET", path)
        r = c.getresponse()
        body = r.read().decode("utf-8", "replace")
        return r.status, body, r.getheader("x-thread")
    finally:
        c.close()


def healthy(port: int) -> bool:
    try:
        return get(port, "/health", timeout=1.0)[0] == 200
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


def doctor(binary: str, args: list) -> tuple:
    try:
        p = subprocess.run(
            [binary, "--doctor", *args], env=clean_env(),
            capture_output=True, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        fail("--doctor had not exited after 30 s: it is serving")
    return p.returncode, p.stdout, p.stderr


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
    """Run for real and wait for /health; a process that exits first is the failure."""
    out = open(log, "w")
    p = subprocess.Popen([binary, *args], env=clean_env(), stdout=out, stderr=out)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if p.poll() is not None:
            fail("%s exited %d before serving:\n%s" % (args, p.returncode, open(log).read()[-2000:]))
        if healthy(port):
            return p
        time.sleep(0.05)
    p.kill()
    fail("%s not healthy on port %d after 30 s" % (args, port))


def expect_route(port: int, path: str, prefix: str, thread: str | None) -> int:
    status, body, got = get(port, path)
    if status != 200 or not body.startswith(prefix):
        fail("%s answered %d %r" % (path, status, body[:80]))
    if thread is not None and got != thread:
        fail("%s answered from x-thread %r, wanted %r" % (path, got, thread))
    m = re.match(r"(?:par|ser)=(\d+)us sum=(\d+)", body)
    if not m:
        fail("%s body is not the route's shape: %r" % (path, body[:80]))
    return int(m.group(1)), int(m.group(2))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    binary, base = sys.argv[1], int(sys.argv[2])
    logs = os.path.dirname(os.path.abspath(binary))
    port = base

    phase("doctor refuses prefork")
    code, out, err = doctor(binary, ["--port", str(port), "--workers", "2"])
    if code != 78:
        fail("--doctor --workers 2 exited %d, wanted 78:\n%s%s" % (code, out[-1500:], err[-1500:]))
    report = report_of(out)
    if report.get("exit") != 78 or report.get("ok") is not False:
        fail("the report says exit=%r ok=%r" % (report.get("exit"), report.get("ok")))
    check = check_named(report, "workers-vs-parallel-runtime")
    if check.get("ok") is not False:
        fail("the doctor passed workers-vs-parallel-runtime at two workers: %r" % check)
    if "--threads (M0_THREADS)" not in check.get("fix", ""):
        fail("the fix does not name --threads (M0_THREADS): %r" % check.get("fix"))

    phase("serve refuses prefork")
    log = os.path.join(logs, "prefork.log")
    with open(log, "w") as lf:
        p = subprocess.Popen(
            [binary, "--port", str(port), "--workers", "2"],
            env=clean_env(), stdout=lf, stderr=lf,
        )
        deadline = time.monotonic() + 30
        served = False
        while time.monotonic() < deadline and p.poll() is None:
            if healthy(port):
                served = True
                break
            time.sleep(0.05)
        if served:
            # Never ask this server for /par: that is the hang the refusal
            # exists to prevent. Stop it by pid, bounded, and fail.
            stop(p, "the served prefork")
            fail("M0_WORKERS=2 was SERVED with the parallel runtime linked; the refusal is gone")
        if p.poll() is None:
            p.kill()
            p.wait()
            fail("--workers 2 neither exited nor served in 30 s")
    text = open(log).read()
    if p.returncode != 78:
        fail("--workers 2 exited %d, wanted 78:\n%s" % (p.returncode, text[-1500:]))
    if "M0_THREADS" not in text or "host:" not in text:
        fail("the refusal did not name the fix under `host:`:\n%s" % text[-1500:])

    phase("doctor passes threads")
    code, out, err = doctor(binary, ["--port", str(port), "--threads", "2"])
    if code != 0:
        fail("--doctor --threads 2 exited %d:\n%s%s" % (code, out[-1500:], err[-1500:]))
    check = check_named(report_of(out), "workers-vs-parallel-runtime")
    if check.get("ok") is not True or "linked" not in check.get("detail", ""):
        fail("at two loops the check should pass and say the runtime is linked: %r" % check)

    phase("threads serve parallelize")
    port += 1
    p = start(binary, ["--port", str(port), "--threads", "2"], port, os.path.join(logs, "threads.log"))
    ser_us, ser_sum = expect_route(port, "/ser", "ser=", "-1")
    par_us, par_sum = expect_route(port, "/par", "par=", "-1")
    if ser_sum != par_sum:
        fail("the two routes disagree: ser sum=%d par sum=%d" % (ser_sum, par_sum))
    errors: list = []

    def one():
        try:
            expect_route(port, "/par", "par=", None)
        except SystemExit:
            errors.append(PHASE)
        except Exception as e:  # a timeout here is the hang, reported not raised
            errors.append(repr(e))

    ts = [threading.Thread(target=one) for _ in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=TIMEOUT + 5)
    if any(t.is_alive() for t in ts):
        stop(p, "the threaded server")
        fail("a concurrent /par did not answer within %.0f s" % TIMEOUT)
    if errors:
        stop(p, "the threaded server")
        fail("concurrent /par failed: %s" % errors[:3])
    code = stop(p, "the threaded server")
    if code != 0:
        fail("--threads 2 drained with exit %d" % code)

    phase("pool serves parallelize")
    port += 1
    p = start(binary, ["--port", str(port), "--blocking-threads", "2"], port, os.path.join(logs, "pool.log"))
    status, body, thread = get(port, "/par")
    if status != 200 or not body.startswith("par=") or thread is None or int(thread) < 0:
        stop(p, "the pooled server")
        fail("/par under a pool answered %d x-thread=%r %r" % (status, thread, body[:60]))
    code = stop(p, "the pooled server")
    if code != 0:
        fail("--blocking-threads 2 drained with exit %d" % code)

    phase("one loop serves parallelize")
    port += 1
    p = start(binary, ["--port", str(port)], port, os.path.join(logs, "loop.log"))
    expect_route(port, "/par", "par=", "-1")
    code = stop(p, "the single loop")
    if code != 0:
        fail("one loop drained with exit %d" % code)

    print("par_us %d" % par_us)
    print("ser_us %d" % ser_us)
    print("parallel_runtime_probe OK: refused at two workers, served alone, at two loops and from a pool; /par %d us against /ser %d us" % (par_us, ser_us))
    return 0


if __name__ == "__main__":
    sys.exit(main())
