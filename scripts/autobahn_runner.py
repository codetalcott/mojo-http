"""Autobahn|Testsuite against the ASGI echo, compared to the pinned baseline.

The pre-release conformance run (SPEC I13). docs/notes/conformance-suite-tier.md ("A conformance-suite
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

**A thin section earns ONE retry, and only for one cause**: wstest's own
`Connection to ws://... failed (...)`, with the server still alive and
answering. The 1.8.0 release run found section 6 thin 5 times in 18 with
docker idle, the old tree's binary and the new alike, each time with that
line (`User timeout caused connection failure.`: the connect from the
container to host.docker.internal never completed) beside a live server
whose log said nothing -- so the route through the VM dropped a connect,
and wstest, which stops at the first case it cannot connect for, exits 0
with the section cut short. The retry runs the whole section again on the
same server; a second thin run fails, and so does a thin run with any other
cause (no such line, a server that died or stopped answering, more cases
than the pinned count). What the thin attempt did score is still compared,
so a failure it recorded is not hidden by the retry passing. wstest's
transcript and the server's log are printed for every thin attempt and kept
on disk (`--keep-dir`), because the runner used to delete both, and a thin
section then said nothing about why.

`--selftest` proves the comparator can fail: a doctored result set with one
new failure, one unexpected pass, one changed verdict and one missing case
must each be flagged by the rule that names it. It drives the retry the
same way, through a fake wstest: a connect failure is retried once and a
second one fails, and every other cause of a thin section fails at once.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from pathlib import Path

from probelib import free_port

# Pinned by version, which is what lets the per-section case counts be
# asserted exactly. 25.10.1 is digest-identical to the image the 2026-08-30
# baseline was measured with (sha256:519915fb...).
IMAGE = "crossbario/autobahn-testsuite:25.10.1"

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


# wstest's own words when it cannot open a case's connection (Twisted's
# connection-failure reason in the brackets), after which it runs nothing
# more and still exits 0. Measured on the pinned image, 2026-09-29:
# "Connection to ws://host.docker.internal:9301 failed (User timeout caused
# connection failure.)".
CONNECT_FAILURE = re.compile(r"Connection to \S+ failed \(.*\)")


def fail(msg):
    sys.exit(f"autobahn: {msg}")


class SectionFailed(Exception):
    """A section that cannot be believed; `main` turns it into `fail`."""


def connection_failures(transcript):
    """Every line in which wstest says it could not connect, verbatim."""
    return CONNECT_FAILURE.findall(transcript)


def thin_cause(ran, expected, transcript, problem):
    """Why a section ran `ran` of `expected` cases, and whether to retry it.

    Returns (retry, cause). Only wstest's own connect failure, with the
    server alive and answering (`problem` None), earns the retry:
    that is a connection the route through the VM dropped. Anything else
    is about the server or the suite, and a second run would only hide it.
    """
    if ran > expected:
        return False, (
            "it ran more cases than the pinned image runs, so the image or "
            "the case list changed")
    if problem is not None:
        return False, f"the server {problem}"
    failures = connection_failures(transcript)
    if not failures:
        return False, (
            "wstest reported no connection failure, so the cause is not a "
            "dropped connect")
    return True, failures[-1]


def drive_section(name, expected, attempt, check_server, on_thin, say=print):
    """Run one section; retry it ONCE if it ran thin because a connect failed.

    `attempt(n)` runs wstest (n = 1, then 2 for the retry) and returns
    ({case: behavior}, wstest's transcript). `check_server()` returns None
    when the server is alive and answering, else what is wrong with it.
    `on_thin(n, ran, transcript)` keeps and prints the evidence of a thin
    attempt. Returns (results, notes, errors): the complete run's verdicts,
    a note for a retry, and the comparator's defects in a thin first
    attempt's own verdicts, which the retry must not hide. Raises
    SectionFailed. Pure over its callables, so `--selftest` drives it with
    a fake wstest.
    """
    first, transcript = attempt(1)
    if len(first) == expected:
        return first, [], []
    on_thin(1, len(first), transcript)
    retry, cause = thin_cause(len(first), expected, transcript,
                              check_server())
    if not retry:
        raise SectionFailed(
            f"[section {name}] ran {len(first)} cases, the pinned image runs "
            f"{expected} — a thin section proves nothing; {cause}")
    say(f"[section {name}] RETRY, once: ran {len(first)} of {expected} and "
        f"wstest said `{cause}`, with the server alive and answering — a "
        f"connect the route dropped, so the whole section runs again on the "
        f"same server. A second thin run fails.", flush=True)
    second, transcript2 = attempt(2)
    if len(second) != expected:
        on_thin(2, len(second), transcript2)
        _, cause2 = thin_cause(len(second), expected, transcript2,
                               check_server())
        raise SectionFailed(
            f"[section {name}] the retry ran thin too: {len(second)} of "
            f"{expected} ({cause2}) — a thin section proves nothing")
    say(f"[section {name}] the retry ran {expected} of {expected}", flush=True)
    errors = [f"(section {name}'s thin first attempt) {e}"
              for e in compare(first, partial=True)]
    return second, [
        f"section {name} was retried once after `{cause}` "
        f"(ran {len(first)} of {expected} first)"
    ], errors


def compare(results, ran_sections=None, partial=False):
    """Defects in one merged {case: behavior} map, as a list of messages.

    Pure over its arguments so `--selftest` can feed it doctored maps.
    `ran_sections` limits the must-have-failed check to the sections that
    actually ran (a partial `--sections` run must not report section 10's
    expected failure as missing). `partial` is a section cut short: what it
    scored is judged, and a case it never reached is not missing.
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
        if behavior is None and partial:
            continue
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
    cut_short = {"1.1.1": "OK", "1.1.6": "FAILED"}
    if compare(cut_short, partial=True):
        return (
            "selftest: a section cut short reported the cases it never "
            f"reached as missing: {compare(cut_short, partial=True)}"
        )
    for name, results, expect in [
        ("a new failure", dict(cut_short, **{"1.1.2": "FAILED"}),
         "NEW failure: case 1.1.2"),
        ("an unexpected pass", {"1.1.6": "OK"}, "UNEXPECTED PASS: case 1.1.6"),
    ]:
        if not any(expect in e for e in compare(results, partial=True)):
            return (
                f"selftest: {name} in a section cut short was not flagged "
                f"(got: {compare(results, partial=True)})"
            )
    failure = selftest_retry()
    if failure:
        return failure
    print("autobahn comparator selftest OK (and the thin-section retry)")
    return None


# A thin section's transcripts, as the pinned image writes them.
_DROPPED = (
    "Running test case ID 6.22.21 for agent m0serve from peer "
    "tcp4:192.168.5.2:9301\nConnection to ws://host.docker.internal:9301 "
    "failed (User timeout caused connection failure.)\n"
)
_STOPPED = (
    "Running test case ID 6.22.21 for agent m0serve from peer "
    "tcp4:192.168.5.2:9301\n"
)


def selftest_retry():
    """`drive_section` against a fake wstest: when it retries, and when not.

    Each script is the (results, transcript) the fake returns per attempt;
    the server's state is fixed per scenario. A section of 4 cases, so a
    thin run is any map of fewer.
    """
    full = {f"6.1.{i}": "OK" for i in range(1, 5)}
    thin = {"6.1.1": "OK"}
    thin_with_failure = {"6.1.1": "FAILED"}
    alive = None
    # (name, attempts, server problem, want: "pass" | "fail",
    #  attempts it must make, text the outcome must carry)
    scenarios = [
        ("a full first run", [(full, "")], alive, "pass", 1, ""),
        ("a dropped connect", [(thin, _DROPPED), (full, "")], alive, "pass",
         2, "retried once after `Connection to ws://host.docker.internal"),
        ("a dropped connect twice", [(thin, _DROPPED), (thin, _DROPPED)],
         alive, "fail", 2, "the retry ran thin too"),
        ("a thin run with no connect failure", [(thin, _STOPPED), (full, "")],
         alive, "fail", 1, "wstest reported no connection failure"),
        ("a dropped connect with the server gone",
         [(thin, _DROPPED), (full, "")], "exited 1", "fail", 1,
         "the server exited 1"),
        ("more cases than pinned", [(dict(full, **{"6.9.9": "OK"}), _DROPPED)],
         alive, "fail", 1, "more cases than the pinned image runs"),
        ("a failure scored before the drop",
         [(thin_with_failure, _DROPPED), (full, "")], alive, "pass", 2,
         "(section 6's thin first attempt) NEW failure: case 6.1.1"),
    ]
    for name, attempts, problem, want, calls, text in scenarios:
        made, kept, said = [], [], []

        def attempt(n):
            made.append(n)
            if n > len(attempts):
                raise AssertionError(
                    f"wstest was run {n} times: a section is retried once "
                    f"at most")
            return attempts[n - 1]

        def on_thin(n, ran, transcript):
            kept.append(n)

        def say(msg, **_):
            said.append(msg)

        try:
            results, notes, errors = drive_section(
                "6", len(full), attempt, lambda: problem, on_thin, say)
            got, outcome = "pass", " ".join(notes + errors)
        except SectionFailed as e:
            got, outcome = "fail", str(e)
        except Exception as e:
            return f"selftest: {name}: drive_section raised {e!r}"
        if got != want or len(made) != calls or text not in outcome:
            return (
                f"selftest: {name}: wanted {want} after {calls} attempt(s) "
                f"carrying {text!r}; got {got} after {len(made)}: {outcome!r}"
            )
        if len(kept) != sum(1 for n in made if len(attempts[n - 1][0]) != len(full)):
            return f"selftest: {name}: a thin attempt's evidence was not kept"
        if want == "pass" and results != full:
            return f"selftest: {name}: the retry's verdicts were not the ones returned"
        if calls == 2 and not any("RETRY, once" in s for s in said):
            return f"selftest: {name}: the retry did not say so"
    return None


def run(*argv, check=True, timeout=120):
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if check and proc.returncode != 0:
        fail(f"`{' '.join(argv)}` exited {proc.returncode}: {proc.stderr.strip()}")
    return proc


def wait_healthy(deadline_s, server, port):
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        if server.poll() is not None:
            fail(f"the server exited {server.returncode} before becoming healthy")
        try:
            body = urllib.request.urlopen(
                f"http://127.0.0.1:{port}/", timeout=1).read()
            if b"autobahn echo ok" in body:
                return
        except Exception:
            pass
        time.sleep(0.5)
    fail(f"the echo server never became healthy in {deadline_s}s")


def run_section(name, cases, workdir, token, port):
    """One wstest invocation via create/cp/start/cp — no bind mounts."""
    cfgdir = workdir / f"cfg-{name}"
    cfgdir.mkdir(exist_ok=True)  # a retry writes the same config again
    (cfgdir / "fuzzingclient.json").write_text(json.dumps({
        "options": {"failByDrop": False},
        "outdir": "/reports",
        "servers": [{"agent": "m0serve",
                     "url": f"ws://host.docker.internal:{port}"}],
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
        transcript = f"{started.stdout}\n--- stderr ---\n{started.stderr}"
        if started.returncode != 0:
            fail(
                f"[section {name}] wstest exited {started.returncode}:\n"
                f"{started.stdout[-2000:]}{started.stderr[-2000:]}"
            )
        outdir = workdir / f"reports-{name}"
        shutil.rmtree(outdir, ignore_errors=True)  # a retry's, not the first's
        run("docker", "cp", f"{ctr}:/reports", str(outdir), check=False)
        index_file = outdir / "index.json"
        index = json.loads(index_file.read_text()) if index_file.exists() else {}
    finally:
        run("docker", "rm", "-f", ctr, check=False)
    # ({case: behavior}, wstest's own output). A run cut short before its
    # first report leaves no index: zero cases, and drive_section decides.
    if not index:
        return {}, transcript
    agents = list(index.keys())
    if len(agents) != 1:
        fail(f"[section {name}] index.json names {agents}, want one agent")
    return {
        case: entry["behavior"]
        for case, entry in index[agents[0]].items()
    }, transcript


def server_problem(server, port):
    """None when the server is alive and answers the echo app, else why not."""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if server.poll() is not None:
            return f"exited {server.returncode}"
        try:
            body = urllib.request.urlopen(
                f"http://127.0.0.1:{port}/", timeout=1).read()
            if b"autobahn echo ok" in body:
                return None
        except Exception:
            pass
        time.sleep(0.5)
    return "is alive but did not answer the echo app in 10 s"


def keep_thin(name, attempt, ran, expected, transcript, server_log, keep_dir):
    """Print and keep the evidence of a thin attempt: wstest's words, the log.

    `keep_dir` is this run's own directory, made the first time a section
    runs thin, so a clean run leaves nothing behind.
    """
    keep_dir.mkdir(parents=True, exist_ok=True)
    wst = keep_dir / f"section{name}-attempt{attempt}.wstest.txt"
    wst.write_text(transcript)
    log = keep_dir / f"section{name}-attempt{attempt}.server.log"
    text = server_log.read_text(errors="replace") if server_log.exists() else ""
    log.write_text(text)
    print(f"[section {name}] thin: ran {ran} of {expected}", file=sys.stderr)
    failures = connection_failures(transcript)
    for line in failures:
        print(f"[section {name}] wstest said: {line}", file=sys.stderr)
    if not failures:
        tail = [ln for ln in transcript.splitlines() if ln.strip()][-12:]
        print(f"[section {name}] wstest reported no connection failure; its "
              f"last lines:", file=sys.stderr)
        for ln in tail:
            print(f"    {ln}", file=sys.stderr)
    lines = text.splitlines()
    print(f"[section {name}] the server's log so far ({len(lines)} lines"
          f"{', the last 20' if len(lines) > 20 else ''}):", file=sys.stderr)
    for ln in lines[-20:]:
        print(f"    {ln}", file=sys.stderr)
    print(f"[section {name}] kept: {wst} and {log}", file=sys.stderr)


def checked_section(name, expected, attempt, server, port, server_log,
                    keep_dir):
    """`attempt` (one `run_section`) under `drive_section`'s one retry."""
    def on_thin(n, ran, transcript):
        keep_thin(name, n, ran, expected, transcript, server_log, keep_dir)

    try:
        return drive_section(name, expected, attempt,
                             lambda: server_problem(server, port), on_thin)
    except SectionFailed as e:
        fail(str(e))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument(
        "--sections", default=None,
        help="comma-separated subset of section names "
        f"({','.join(s[0] for s in SECTIONS)}); default all",
    )
    ap.add_argument("--serve", default="bin/m0serve")
    ap.add_argument(
        "--keep-dir", default="bin/logs/autobahn",
        help="where a thin section's wstest output and server log are kept, "
        "in a directory of the run's own made only when one runs thin "
        "(default: %(default)s)",
    )
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
    # A port of this run's own: the echo server listens on the host, where
    # a fixed one is shared with every other run on the machine. SO_REUSEPORT
    # means a stale listener would silently answer a share of the suite's
    # connections (smoke-wheel's lesson, verbatim), so it is asked again.
    port = free_port()
    if shutil.which("lsof"):
        stale = run("lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t",
                    check=False).stdout.split()
        if stale:
            fail(
                f"port {port} already has a listener (pids: {' '.join(stale)})"
                f" — SO_REUSEPORT would let it answer this run's connections"
            )

    token = uuid.uuid4().hex[:8]
    keep_dir = Path(args.keep_dir) / f"{time.strftime('%Y%m%dT%H%M%S')}-{token}"
    results, notes, errors = {}, [], []
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        (workdir / "echoapp.py").write_text(ECHO_APP)
        # To a file, never an unread pipe: a thin section prints and keeps
        # it, and a server that filled a pipe's buffer would block writing.
        server_log = workdir / "server.log"
        with open(server_log, "w") as log_out:
            server = subprocess.Popen(
                [args.serve, "echoapp:application", "--app-dir", str(workdir),
                 "--port", str(port)],
                stdout=log_out, stderr=subprocess.STDOUT,
            )
        try:
            wait_healthy(60, server, port)
            for name, cases, expected_count in sections:
                section, section_notes, section_errors = checked_section(
                    name, expected_count,
                    lambda n: run_section(name, cases, workdir, token, port),
                    server, port, server_log, keep_dir)
                results.update(section)
                notes += section_notes
                errors += section_errors
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
    for note in notes:
        print(f"autobahn: {note}")

    errors = compare(results, ran_sections={s[0] for s in sections}) + errors
    for e in errors:
        print(f"autobahn: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("autobahn OK: the baseline holds — every failure is I17's cap,"
          " and every one of I17's cases still fails"
          + (f" ({len(notes)} section(s) retried once, above)" if notes else ""))


if __name__ == "__main__":
    main()
