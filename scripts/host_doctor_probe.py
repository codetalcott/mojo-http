#!/usr/bin/env python3
"""Hold the Mojo host's `--doctor` to its contract, for `poe smoke-host-doctor`.

    host_doctor_probe.py BIN BASE_PORT

The contract is m0serve's (`smoke-doctor`): `--doctor` exits with **the code
the server itself exits with for the same arguments**, having started
nothing. It is held the same way -- every row below is run BOTH ways, as
`BIN --doctor ARGS` and as `BIN ARGS`, and the two exit codes must agree with
each other and with the row. A served row is really served: the probe waits
for `/health` on the port the FLAGS name (never the environment's, where the
two differ -- that is the precedence, on the wire), then SIGTERMs it and
wants 0.

Beyond the code, per row: the doctor prints exactly one JSON object as the
LAST line of its stdout (an application may print its own banner first), its
`exit` and `ok` agree with the process's, the facts say what the row says
(port, mode, where each value came from), a refusal names its check and
carries a `fix`, and no doctor run ever logs `listening` -- nothing was
bound, which one row proves outright by doctoring a port a live server
holds.

Exits 0 printing one summary line, or 1 naming the first row that failed.
Stdlib only.
"""

from __future__ import annotations

import http.client
import json
import os
import signal
import subprocess
import sys
import time
import traceback

# Which row is running, for failures and for the crash handler: the rows
# share every helper here, and a traceback names the helper, never what was
# being proven (scripts/phase_stamp_check.py).
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("host_doctor_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("host_doctor_probe: FAIL: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


def clean_env(extra: dict) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("M0_")}
    env.update(extra)
    return env


def run_doctor(binary: str, args: list, env: dict) -> tuple:
    try:
        p = subprocess.run(
            [binary, "--doctor", *args], env=clean_env(env),
            capture_output=True, text=True, timeout=20,
        )
    except subprocess.TimeoutExpired:
        fail("--doctor had not exited after 20 s: it is serving")
    return p.returncode, p.stdout, p.stderr


def healthy(port: int) -> bool:
    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
        c.request("GET", "/health")
        ok = c.getresponse().status == 200
        c.close()
        return ok
    except OSError:
        return False


def run_server(binary: str, args: list, env: dict, port: int, log: str) -> tuple:
    """Run for real. A process that exits on its own reports its code; one
    that serves is probed on `port`, SIGTERMed, and reports its drain's."""
    with open(log, "w") as out:
        p = subprocess.Popen([binary, *args], env=clean_env(env), stdout=out, stderr=out)
        served = False
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if p.poll() is not None:
                break
            if healthy(port):
                served = True
                break
            time.sleep(0.05)
        else:
            p.kill()
            fail("neither exited nor became healthy on port %d in 30 s" % port)
        extra = None
        if served:
            extra = after_healthy(port)
            p.send_signal(signal.SIGTERM)
        try:
            code = p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            p.kill()
            fail("still running 20 s after SIGTERM")
    return code, served, open(log).read(), extra


def after_healthy(port: int) -> str:
    """One more request, so an access log has a line to show."""
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", "/instance")
    r = c.getresponse()
    r.read()
    worker = r.getheader("x-worker") or ""
    c.close()
    return worker


def report_of(stdout: str) -> dict:
    lines = [ln for ln in stdout.splitlines() if ln.strip()]
    if not lines:
        fail("the doctor printed nothing")
    try:
        doc = json.loads(lines[-1])
    except ValueError:
        fail("the doctor's last line is not JSON: %r" % lines[-1][:200])
    for ln in lines[:-1]:
        if ln.lstrip().startswith("{"):
            fail("the doctor printed more than one JSON object")
    return doc


def main() -> int:
    binary, base = sys.argv[1], int(sys.argv[2])
    out_dir = os.path.dirname(binary)
    ports = iter(range(base, base + 40))

    def P() -> int:
        return next(ports)

    # (name, args, env, want_code, expect) -- `expect` checks the report.
    rows = []
    p = P()
    rows.append(("no flags: the environment alone", [], {"M0_PORT": str(p)}, 0,
                 {"port": p, "mode": "single", "sources": {"port": "env", "workers": "default"}}))
    p, shadowed = P(), P()
    rows.append(("a flag outranks its variable", ["--port", str(p), "--access-log"],
                 {"M0_PORT": str(shadowed)}, 0,
                 {"port": p, "not_port": shadowed, "access_log": True,
                  "sources": {"port": "flag", "access_log": "flag"}}))
    # The same, in the application shape `serve(AppConfig())`: the gate app
    # otherwise takes `host_config()`, which has applied the command line
    # before `serve` sees it and would hide whether `serve` applies it.
    p, shadowed = P(), P()
    rows.append(("serve(AppConfig()) applies the command line itself",
                 ["--port", str(p), "--access-log"],
                 {"M0_PORT": str(shadowed), "M0_HOSTCHECK_ENV_CONFIG": "1"}, 0,
                 {"port": p, "not_port": shadowed, "access_log": True,
                  "sources": {"port": "flag", "access_log": "flag"}}))
    p = P()
    rows.append(("two workers by flag", ["--port=%d" % p, "--workers=2"], {}, 0,
                 {"port": p, "mode": "prefork", "loops": 2, "banner": "2 worker(s)",
                  "sources": {"workers": "flag"}}))
    p = P()
    rows.append(("loops on threads, pooled, by flag",
                 ["--port", str(p), "--threads", "2", "--blocking-threads", "2"], {}, 0,
                 {"port": p, "mode": "threads", "loops": 2, "handler_threads": 4,
                  "log": "2 loops on 2 threads"}))
    p = P()
    rows.append(("both modes, by flag", ["--port", str(p), "--workers", "2", "--threads", "2"],
                 {}, 78, {"check": "workers-vs-threads"}))
    p = P()
    rows.append(("both modes, one from each source", ["--port", str(p), "--threads", "2"],
                 {"M0_WORKERS": "2"}, 78,
                 {"check": "workers-vs-threads", "sources": {"workers": "env", "threads": "flag"}}))
    p = P()
    rows.append(("--threads 0", ["--port", str(p), "--threads", "0"], {}, 78,
                 {"check": "threads-count"}))
    p = P()
    rows.append(("--workers 0", ["--port", str(p), "--workers", "0"], {}, 78,
                 {"check": "workers-count"}))
    p = P()
    rows.append(("more workers than the application serves", ["--port", str(p), "--workers", "2"],
                 {"M0_HOSTCHECK_MAX_WORKERS": "1"}, 78,
                 {"check": "workers-vs-application", "max_workers": 1}))
    p = P()
    rows.append(("more loops than the application serves", ["--port", str(p), "--threads", "2"],
                 {"M0_HOSTCHECK_MAX_WORKERS": "1"}, 78, {"check": "threads-vs-application"}))
    # Two failures at once: the doctor's FIRST failed check is the one the
    # server refuses by, because both read `host_checks` in order.
    p = P()
    rows.append(("two refusals, and both name the first",
                 ["--port", str(p), "--workers", "2", "--threads", "2"],
                 {"M0_HOSTCHECK_MAX_WORKERS": "1"}, 78, {"check": "workers-vs-application"}))
    p = P()
    rows.append(("--spawn-workers", ["--port", str(p), "--spawn-workers"], {}, 78,
                 {"check": "spawn-workers"}))
    # Usage errors: 2 both ways, the usage text, and no report at all.
    for name, args in (
        ("an unknown flag", ["--prot", "9"]),
        ("a port that is not a number", ["--port", "abc"]),
        ("a port out of range", ["--port", "70000"]),
        ("a flag with no value", ["--workers"]),
        ("a value on a boolean", ["--qos=1"]),
        ("a positional", ["notes.db"]),
    ):
        rows.append((name, args, {"M0_PORT": str(P())}, 2, None))
    # The application's OWN check runs in its main before serve, so it is
    # the same 78 both ways and the doctor never runs.
    rows.append(("the application's own refusal", [],
                 {"M0_PORT": str(P()), "M0_HOSTCHECK_REFUSES": "1"}, 78, "app"))

    for name, args, env, want, expect in rows:
        phase(name)
        dcode, dout, derr = run_doctor(binary, args, env)
        if "listening" in (dout + derr).lower() or "Event loop started" in dout + derr:
            fail("the doctor started a server:\n" + dout + derr)
        port = expect["port"] if isinstance(expect, dict) and "port" in expect else int(env.get("M0_PORT", "0") or 0)
        log = os.path.join(out_dir, "row.log")
        scode, served, slog, worker = run_server(binary, args, env, port, log)
        if dcode != scode:
            fail("--doctor exited %d, the server %d, for the same arguments\n--- doctor\n%s%s--- server\n%s"
                 % (dcode, scode, dout, derr, slog))
        if dcode != want:
            fail("both exited %d, want %d\n--- doctor\n%s%s--- server\n%s" % (dcode, want, dout, derr, slog))
        if served != (want == 0):
            fail("exit %d but served=%s" % (scode, served))

        if want == 2:
            for text, who in ((dout, "the doctor"), (slog, "the server")):
                if "usage:" not in text or "host: " not in text:
                    fail("%s did not print the usage and the reason:\n%s" % (who, text))
            if any(ln.lstrip().startswith("{") for ln in dout.splitlines()):
                fail("a usage error printed a report")
            continue
        if expect == "app":
            if "M0_HOSTCHECK_REFUSES" not in dout or "M0_HOSTCHECK_REFUSES" not in slog:
                fail("the application's refusal is not named both ways")
            continue

        doc = report_of(dout)
        if doc.get("m0_host") != "1":
            fail("the report does not open with its format: %r" % list(doc)[:1])
        if doc["exit"] != dcode or doc["ok"] != (dcode == 0):
            fail("the report says exit=%r ok=%r, the process exited %d" % (doc["exit"], doc["ok"], dcode))
        failed = [c for c in doc["checks"] if not c["ok"]]
        if want == 0:
            if failed:
                fail("a served configuration has failed checks: %r" % failed)
        else:
            if not failed or failed[0]["name"] != expect["check"]:
                fail("want the first failed check to be %r, got %r" % (expect["check"], failed[:1]))
            if not failed[0].get("fix") or failed[0].get("exit") != 78:
                fail("a failed check without a fix or its exit: %r" % failed[0])
            # The server's own line is the same finding, and names the fix.
            if failed[0]["detail"] not in slog or failed[0]["fix"] not in slog:
                fail("the server's refusal is not the doctor's check:\n%s\n%r" % (slog, failed[0]))
            if "listening" in slog.lower():
                fail("a refused configuration was bound first:\n" + slog)
        cfg, topo = doc["config"], doc["topology"]
        if "port" in expect and cfg["port"] != expect["port"]:
            fail("config.port is %r, want %r" % (cfg["port"], expect["port"]))
        if "not_port" in expect and healthy(expect["not_port"]):
            fail("something answers on the environment's port %d" % expect["not_port"])
        for key in ("mode", "loops", "handler_threads"):
            if key in expect and topo[key] != expect[key]:
                fail("topology.%s is %r, want %r" % (key, topo[key], expect[key]))
        if "max_workers" in expect and doc["application"]["max_workers"] != expect["max_workers"]:
            fail("application.max_workers is %r" % doc["application"]["max_workers"])
        for key, src in expect.get("sources", {}).items():
            if doc["sources"][key] != src:
                fail("sources.%s is %r, want %r" % (key, doc["sources"][key], src))
        if expect.get("access_log"):
            if not cfg["access_log"]:
                fail("config.access_log is false under --access-log")
            if "/instance" not in slog:
                fail("--access-log logged no request:\n" + slog)
        for key in ("banner", "log"):
            if key in expect and expect[key] not in slog:
                fail("the server's log lacks %r:\n%s" % (expect[key], slog))
        if "api_key" in json.dumps(doc):
            fail("the report names the API key")

    # --help: the usage, 0, nothing started -- with and without --doctor.
    phase("--help")
    for args in (["--help"], ["-h"], ["--doctor", "--help"]):
        h = subprocess.run([binary, *args], env=clean_env({"M0_PORT": str(P())}),
                           capture_output=True, text=True, timeout=20)
        if h.returncode != 0 or not h.stdout.startswith("usage: host_check [OPTIONS]"):
            fail("%r exited %d:\n%s" % (args, h.returncode, h.stdout))
        if "--max-keepalive-requests" not in h.stdout or "M0_BLOCKING_THREADS" not in h.stdout:
            fail("the usage does not name every flag and its variable")

    # Nothing is bound: doctor a port a live server is holding.
    phase("the doctor binds nothing")
    held = P()
    live = subprocess.Popen([binary, "--port", str(held)], env=clean_env({}),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        t0 = time.monotonic()
        while not healthy(held):
            if time.monotonic() - t0 > 30:
                fail("the holder never became healthy")
            time.sleep(0.05)
        code, dout, derr = run_doctor(binary, ["--port", str(held)], {})
        if code != 0 or report_of(dout)["config"]["port"] != held:
            fail("doctoring a held port exited %d:\n%s%s" % (code, dout, derr))
    finally:
        live.send_signal(signal.SIGTERM)
        try:
            live.wait(timeout=20)
        except subprocess.TimeoutExpired:
            live.kill()

    print("host_doctor_probe: %d configurations agree both ways" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
