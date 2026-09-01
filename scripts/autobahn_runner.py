"""Autobahn|Testsuite against the ASGI echo, compared to the pinned baseline.

The pre-release conformance run (SPEC I13). ROADMAP's "A conformance-suite
tier" records what the suite can and cannot see here — it found close codes
echoed rather than validated (I16, since fixed) and it cannot reach the
app-initiated close path at all (`ws_probe.py`'s territory) — and where it
should live: pre-release, beside `stress-asgi`, because it needs Docker and
~ten minutes and its unique value is a defect fixed once rather than a
regression that recurs.

The baseline is pinned, not aspirational: **240 of 247 outside the
performance section, every failure being I17's >=64 KB outbox cap** —
1.1.6-1.1.8, 1.2.6-1.2.8 and 10.1.1, and nothing else. So the comparison
runs in both directions:

- a case failing OUTSIDE that set is a NEW failure and fails the run;
- an I17 case unexpectedly PASSING also fails the run, loudly — it means
  the cap moved, which contradicts I17's row, and silently absorbing it
  would leave the sheet wrong.

Sections are driven SEPARATELY, one `wstest` invocation each, because a
single pass wedged at case 6.21.6 on 2026-08-30 and never recovered:
section 1's >=64 KB cases end their connections and the next case lands on
the recycled slot, so one pass understates the server. 12 and 13 are
excluded (`permessage-deflate`, I14); 9 is performance and is skipped —
every one of its cases exceeds the cap by design. The suite image is
version-pinned, which is what lets the per-section case counts be asserted
exactly: a section that silently ran thin is the fuzzer's "green having
tested nothing" trap.

The server is the runner's own ~25-line PURE echo ASGI app (asgi_bare's
`/ws` prefix-echoes text for its probe's benefit, which Autobahn's
byte-identity cases would score as failures), served by `bin/m0serve`.
Config and reports cross the container boundary with `docker create`/`cp`,
never a bind mount — a macOS temp dir under colima mounts EMPTY, silently.

`--selftest` proves the comparator can fail: a doctored result set with one
new failure, one unexpected pass, one changed verdict and one missing case
must each be flagged by the rule that names it.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from pathlib import Path

# Pinned by version, which is what lets the per-section case counts be
# asserted exactly. 25.10.1 is digest-identical to the image the 2026-08-30
# baseline was measured with (sha256:519915fb...).
IMAGE = "crossbario/autobahn-testsuite:25.10.1"
PORT = 9301

# I17's seven: the >=64 KB outbox cap, deliberate and documented. Nothing
# else may fail, and every one of these MUST — see the module docstring.
EXPECTED_FAILURES = {
    "1.1.6", "1.1.7", "1.1.8", "1.2.6", "1.2.7", "1.2.8", "10.1.1",
}

# Verdicts that count as passing. NON-STRICT is the suite's "allowed but
# not ideal"; INFORMATIONAL cases carry no verdict at all.
PASSING = {"OK", "NON-STRICT", "INFORMATIONAL"}

# (name, wstest case specs, case count under the pinned image).
SECTIONS = (
    ("1", ["1.*"], 16),
    ("2-5", ["2.*", "3.*", "4.*", "5.*"], 48),
    ("6", ["6.*"], 145),
    ("7", ["7.*"], 37),
    ("10", ["10.*"], 1),
)

ECHO_APP = '''\
async def application(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            m = await receive()
            if m["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif m["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    if scope["type"] == "websocket":
        await send({"type": "websocket.accept"})
        while True:
            m = await receive()
            if m["type"] == "websocket.disconnect":
                return
            if m["type"] == "websocket.receive":
                if m.get("text") is not None:
                    await send({"type": "websocket.send", "text": m["text"]})
                else:
                    await send({"type": "websocket.send",
                                "bytes": bytes(m.get("bytes") or b"")})
        return
    body = b"autobahn echo ok"
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain"),
                            (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})
'''


def fail(msg):
    sys.exit(f"autobahn: {msg}")


def compare(results, ran_sections=None):
    """Defects in one merged {case: behavior} map, as a list of messages.

    Pure over its arguments so `--selftest` can feed it doctored maps.
    `ran_sections` limits the must-have-failed check to the sections that
    actually ran (a partial `--sections` run must not report section 10's
    expected failure as missing).
    """
    errors = []
    for case, behavior in sorted(results.items()):
        if case in EXPECTED_FAILURES:
            continue
        if behavior not in PASSING:
            errors.append(
                f"NEW failure: case {case} scored {behavior} — the baseline "
                f"says every failure outside section 9 is I17's cap, so this "
                f"is not the cap"
            )
    for case in sorted(EXPECTED_FAILURES):
        if ran_sections is not None and case.split(".")[0] not in ran_sections:
            continue
        behavior = results.get(case)
        if behavior is None:
            errors.append(
                f"expected failure {case} never ran — absence is not a pass"
            )
        elif behavior in PASSING:
            errors.append(
                f"UNEXPECTED PASS: case {case} scored {behavior}. This case "
                f"is I17's >=64 KB outbox cap and its failure is pinned — a "
                f"pass means the cap MOVED, which contradicts SPEC I17. Do "
                f"not absorb this silently: re-measure the cap and fix "
                f"whichever of the two is now wrong"
            )
        elif behavior != "FAILED":
            errors.append(
                f"expected failure {case} scored {behavior}, not FAILED — "
                f"the failure mode changed; re-read the report"
            )
    return errors


def selftest():
    """The comparator must be able to fail, one doctored map per rule."""
    good = {c: "FAILED" for c in EXPECTED_FAILURES}
    good.update({"1.1.1": "OK", "2.1.1": "NON-STRICT", "7.1.1": "INFORMATIONAL"})
    if compare(good):
        return f"selftest: a baseline-conforming result was flagged: {compare(good)}"

    doctored = [
        ("a new failure", dict(good, **{"6.4.1": "FAILED"}), "NEW failure: case 6.4.1"),
        ("an unexpected pass", dict(good, **{"1.1.6": "OK"}), "UNEXPECTED PASS: case 1.1.6"),
        ("a changed verdict", dict(good, **{"10.1.1": "UNIMPLEMENTED"}), "not FAILED"),
        ("a missing expected case",
         {c: "FAILED" for c in EXPECTED_FAILURES if c != "1.2.6"},
         "1.2.6 never ran"),
        ("an unknown verdict", dict(good, **{"3.2.1": "WRONG CODE"}), "scored WRONG CODE"),
    ]
    for name, results, expect in doctored:
        errors = compare(results)
        if not any(expect in e for e in errors):
            return (
                f"selftest: {name} was not flagged by the rule that names it "
                f"(got: {errors})"
            )
    partial = compare({"6.1.1": "OK"}, ran_sections={"6"})
    if partial:
        return (
            f"selftest: a section-6-only run reported other sections' "
            f"expected failures as missing: {partial}"
        )
    one_pass_in_partial = compare({"1.1.6": "OK"}, ran_sections={"1"})
    if not any("UNEXPECTED PASS" in e for e in one_pass_in_partial):
        return (
            "selftest: an unexpected pass inside a partial run was not "
            f"flagged (got: {one_pass_in_partial})"
        )
    print("autobahn comparator selftest OK")
    return None


def run(*argv, check=True, timeout=120):
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if check and proc.returncode != 0:
        fail(f"`{' '.join(argv)}` exited {proc.returncode}: {proc.stderr.strip()}")
    return proc


def wait_healthy(deadline_s, server):
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        if server.poll() is not None:
            fail(f"the server exited {server.returncode} before becoming healthy")
        try:
            body = urllib.request.urlopen(
                f"http://127.0.0.1:{PORT}/", timeout=1).read()
            if b"autobahn echo ok" in body:
                return
        except Exception:
            pass
        time.sleep(0.5)
    fail(f"the echo server never became healthy in {deadline_s}s")


def run_section(name, cases, workdir, token):
    """One wstest invocation via create/cp/start/cp — no bind mounts."""
    cfgdir = workdir / f"cfg-{name}"
    cfgdir.mkdir()
    (cfgdir / "fuzzingclient.json").write_text(json.dumps({
        "options": {"failByDrop": False},
        "outdir": "/reports",
        "servers": [{"agent": "m0serve",
                     "url": f"ws://host.docker.internal:{PORT}"}],
        "cases": cases,
        "exclude-cases": [],
        "exclude-agent-cases": {},
    }))
    ctr = f"m0autobahn-{name.replace('-', '')}-{token}"
    run("docker", "create", "--name", ctr,
        "--add-host", "host.docker.internal:host-gateway",
        IMAGE, "wstest", "-m", "fuzzingclient", "-s", "/cfg/fuzzingclient.json")
    try:
        run("docker", "cp", str(cfgdir), f"{ctr}:/cfg")
        print(f"[section {name}] running {cases} ...", flush=True)
        started = run("docker", "start", "-a", ctr, timeout=1800, check=False)
        if started.returncode != 0:
            fail(
                f"[section {name}] wstest exited {started.returncode}:\n"
                f"{started.stdout[-2000:]}{started.stderr[-2000:]}"
            )
        outdir = workdir / f"reports-{name}"
        run("docker", "cp", f"{ctr}:/reports", str(outdir))
        index = json.loads((outdir / "index.json").read_text())
    finally:
        run("docker", "rm", "-f", ctr, check=False)
    agents = list(index.keys())
    if len(agents) != 1:
        fail(f"[section {name}] index.json names {agents}, want one agent")
    return {
        case: entry["behavior"]
        for case, entry in index[agents[0]].items()
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument(
        "--sections", default=None,
        help="comma-separated subset of section names "
        f"({','.join(s[0] for s in SECTIONS)}); default all",
    )
    ap.add_argument("--serve", default="bin/m0serve")
    args = ap.parse_args()

    if args.selftest:
        failure = selftest()
        if failure:
            sys.exit(failure)
        return

    wanted = None if args.sections is None else set(args.sections.split(","))
    sections = [s for s in SECTIONS if wanted is None or s[0] in wanted]
    if wanted is not None and len(sections) != len(wanted):
        fail(f"unknown section in {sorted(wanted)}")

    if run("docker", "info", check=False).returncode != 0:
        fail("docker is not available (daemon not running, or not installed)")
    if not Path(args.serve).exists():
        fail(f"{args.serve} does not exist — run `poe build-serve` first")
    # SO_REUSEPORT means a stale listener would silently answer a share of
    # the suite's connections (smoke-wheel's lesson, verbatim).
    if shutil.which("lsof"):
        stale = run("lsof", "-nP", f"-iTCP:{PORT}", "-sTCP:LISTEN", "-t",
                    check=False).stdout.split()
        if stale:
            fail(
                f"port {PORT} already has a listener (pids: {' '.join(stale)})"
                f" — SO_REUSEPORT would let it answer this run's connections"
            )

    token = uuid.uuid4().hex[:8]
    results = {}
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        (workdir / "echoapp.py").write_text(ECHO_APP)
        server = subprocess.Popen(
            [args.serve, "echoapp:application", "--app-dir", str(workdir),
             "--port", str(PORT)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            wait_healthy(60, server)
            for name, cases, expected_count in sections:
                section = run_section(name, cases, workdir, token)
                if len(section) != expected_count:
                    fail(
                        f"[section {name}] ran {len(section)} cases, the "
                        f"pinned image runs {expected_count} — a thin section"
                        f" proves nothing"
                    )
                results.update(section)
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()

    tally = {}
    for behavior in results.values():
        tally[behavior] = tally.get(behavior, 0) + 1
    print(f"autobahn: {len(results)} cases: " + ", ".join(
        f"{k} {v}" for k, v in sorted(tally.items())))

    errors = compare(results, ran_sections={s[0] for s in sections})
    for e in errors:
        print(f"autobahn: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("autobahn OK: the baseline holds — every failure is I17's cap,"
          " and every one of I17's cases still fails")


if __name__ == "__main__":
    main()
