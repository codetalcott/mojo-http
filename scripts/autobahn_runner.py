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

**A thin section is RESUMED, up to three times, and only for one cause**:
wstest's own `Connection to ws://... failed (...)`, with the server still
alive and answering. The 1.8.0 release run found section 6 thin 5 times in
18 with docker idle, the old tree's binary and the new alike, each time
with that line (`User timeout caused connection failure.`: the connect
from the container to host.docker.internal never completed) beside a live
server whose log said nothing -- so the route through the VM dropped a
connect (about 1 in 300, measured with a plain Python listener in the
server's place), and wstest, which stops at the first case it cannot
connect for, exits 0 with the section cut short. A resume runs only the
cases no attempt has scored (wstest's `exclude-cases` takes exact case
ids), on the same server, so each makes fewer connects than the one before;
it used to run the whole section again, once, and 1 run in 20 still failed
having found nothing. The attempts' verdicts are merged, and the merge must
hold every case of the section exactly once: an attempt that scores a case
an earlier one scored fails the run (that is wstest not taking the
exclusions, and the second verdict would hide the first), and the section's
pinned count is asserted over the merge. Every other thin attempt fails
the run: no such line, a server that died or stopped answering, more cases
than the pinned count, or a fourth resume wanted. Every verdict any attempt
scored is compared, so a failure recorded before a drop is not hidden by
the resume passing. wstest's transcript and the server's log are printed
for every thin attempt and kept on disk (`--keep-dir`), because the runner
used to delete both, and a thin section then said nothing about why.

`--selftest` proves the comparator can fail: a doctored result set with one
new failure, one unexpected pass, one changed verdict and one missing case
must each be flagged by the rule that names it. It drives the resume the
same way, through a model of wstest that honours the exclusions it is given
unless a scenario says otherwise: a dropped connect is resumed from the
first case not reached, three drops are survived and a fourth fails, a
resume that would score a case twice or leave one out fails, and every other
cause of a thin section fails at once.
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

# How many times one section may be resumed after that failure. At about 1
# lost connect in 300, section 6 (145 connects) ran thin in 9 of 30 runs,
# and a resume makes fewer connects than the attempt before it, so a run
# that needs a fourth is not the route's ordinary loss.
RESUMES = 3


def fail(msg):
    sys.exit(f"autobahn: {msg}")


class SectionFailed(Exception):
    """A section that cannot be believed; `main` turns it into `fail`."""


def connection_failures(transcript):
    """Every line in which wstest says it could not connect, verbatim."""
    return CONNECT_FAILURE.findall(transcript)


def thin_cause(ran, expected, transcript, problem):
    """Why a section ran `ran` of `expected` cases, and whether to resume it.

    Returns (resume, cause). Only wstest's own connect failure, with the
    server alive and answering (`problem` None), earns a resume: that is a
    connection the route through the VM dropped. Anything else is about the
    server or the suite, and another run would only hide it.
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
    """Run one section; resume it, up to RESUMES times, after a dropped connect.

    `attempt(n, done)` runs wstest (n = 1, then 2, 3, ... for each resume)
    over the section's cases less `done`, the sorted ids every earlier
    attempt scored, and returns ({case: behavior}, wstest's transcript).
    `check_server()` returns None when the server is alive and answering,
    else what is wrong with it. `on_thin(n, ran, total, transcript)` keeps
    and prints the evidence of an attempt that left the section short
    (`ran` its own cases, `total` the section's so far). Returns (results,
    notes): every attempt's verdicts in one map, each case scored exactly
    once, and a note if the section was resumed. Raises SectionFailed. Pure
    over its callables, so `--selftest` drives it with a model of wstest.
    """
    results, resumed = {}, []
    for n in range(1, RESUMES + 2):
        got, transcript = attempt(n, sorted(results))
        again = sorted(set(got) & set(results))
        if again:
            on_thin(n, len(got), len(results) + len(got), transcript)
            raise SectionFailed(
                f"[section {name}] attempt {n} scored {len(again)} case(s) an "
                f"earlier attempt had already scored ({', '.join(again[:5])}"
                f"{', ...' if len(again) > 5 else ''}) — a resume runs only "
                f"the cases not reached, so wstest did not take the "
                f"exclusions, and a second verdict would hide the first")
        results.update(got)
        if len(results) == expected:
            break
        on_thin(n, len(got), len(results), transcript)
        retry, cause = thin_cause(len(results), expected, transcript,
                                  check_server())
        over = f" over {n} attempts" if n > 1 else ""
        if not retry:
            raise SectionFailed(
                f"[section {name}] ran {len(results)} cases{over}, the pinned "
                f"image runs {expected} — a thin section proves nothing; "
                f"{cause}")
        if n > RESUMES:
            raise SectionFailed(
                f"[section {name}] still thin after {RESUMES} resumes: "
                f"{len(results)} of {expected}{over}, the last cut short by "
                f"`{cause}` — a thin section proves nothing")
        say(f"[section {name}] RESUME {n} of {RESUMES}: {len(results)} of "
            f"{expected} scored and wstest said `{cause}`, with the server "
            f"alive and answering — a connect the route dropped, so the "
            f"{expected - len(results)} cases not reached run on the same "
            f"server", flush=True)
        resumed.append(f"after `{cause}` at {len(results)} of {expected}")
    if not resumed:
        return results, []
    say(f"[section {name}] the resumes reached every case: {expected} of "
        f"{expected}, each scored once", flush=True)
    return results, [
        f"section {name} was resumed {len(resumed)} time(s): "
        + "; ".join(resumed)
    ]


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
    failure = selftest_resume()
    if failure:
        return failure
    print("autobahn comparator selftest OK (and the thin-section resume)")
    return None


# wstest's words for a connect it could not make, as the pinned image
# writes them.
_DROPPED = (
    "Connection to ws://host.docker.internal:9301 failed (User timeout "
    "caused connection failure.)\n"
)


def wstest_model(cases, script, verdicts):
    """A model of wstest's fuzzing client over one section's `cases`.

    Attempt n runs the cases not in the exclusions it is given, in order,
    as the pinned image does (`parseSpecCases`: the case list less
    `exclude-cases`, sorted), and ends as `script[n - 1]` says:
    ("all",) runs them all; ("drop", k) runs k and then cannot connect,
    printing wstest's line; ("stop", k) runs k and stops with no such line;
    ("ignore",) runs the whole section, as a wstest that did not take the
    exclusions would; ("skip",) leaves out the first case it was given;
    ("extra",) runs one case the section does not hold. Every verdict is OK
    unless `verdicts[(n, case)]` says otherwise. Returns (attempt, runs),
    `runs` recording the exclusions each call was given.
    """
    runs = []

    def attempt(n, done):
        runs.append(list(done))
        if n > len(script):
            raise AssertionError(
                f"wstest was run {n} times; the scenario allows {len(script)}")
        kind, *arg = script[n - 1]
        todo = [c for c in cases if c not in done]
        if kind == "ignore":
            todo = list(cases)
        elif kind == "skip":
            todo = todo[1:]
        elif kind == "extra":
            todo = todo + ["6.9.9"]
        ran = todo[:arg[0]] if kind in ("drop", "stop") else todo
        transcript = "".join(
            f"Running test case ID {c} for agent m0serve from peer "
            f"tcp4:192.168.5.2:9301\n" for c in ran)
        if kind == "drop":
            transcript += _DROPPED
        return {c: verdicts.get((n, c), "OK") for c in ran}, transcript

    return attempt, runs


def selftest_resume():
    """`drive_section` against a model of wstest: when it resumes, and when not.

    A section of 8 cases; the server's state is fixed per scenario.
    """
    cases = [f"6.1.{i}" for i in range(1, 9)]
    alive = None
    failed = {(1, "6.1.2"): "FAILED"}
    # (name, script, verdicts, server problem, want: "pass" | "fail",
    #  wstest runs it must make, text the outcome must carry)
    scenarios = [
        ("a full first run", [("all",)], {}, alive, "pass", 1, ""),
        ("a dropped connect, resumed", [("drop", 3), ("all",)], {}, alive,
         "pass", 2, "resumed 1 time(s): after `Connection to ws://"),
        ("a drop before the first case", [("drop", 0), ("all",)], {}, alive,
         "pass", 2, "at 0 of 8"),
        ("three drops, then the rest",
         [("drop", 1), ("drop", 2), ("drop", 0), ("all",)], {}, alive,
         "pass", 4, "resumed 3 time(s)"),
        ("four drops in a row",
         [("drop", 1), ("drop", 2), ("drop", 0), ("drop", 1)], {}, alive,
         "fail", 4, "still thin after 3 resumes: 4 of 8 over 4 attempts"),
        ("a thin run with no connect failure", [("stop", 3), ("all",)], {},
         alive, "fail", 1, "wstest reported no connection failure"),
        ("a resume that stops with no connect failure",
         [("drop", 3), ("stop", 2)], {}, alive, "fail", 2,
         "ran 5 cases over 2 attempts"),
        ("a dropped connect with the server gone", [("drop", 3), ("all",)],
         {}, "exited 1", "fail", 1, "the server exited 1"),
        ("more cases than pinned", [("extra",)], {}, alive, "fail", 1,
         "more cases than the pinned image runs"),
        ("a resume that runs more than was left", [("drop", 3), ("extra",)],
         {}, alive, "fail", 2, "more cases than the pinned image runs"),
        ("a resume that would score a case twice", [("drop", 3), ("ignore",)],
         failed, alive, "fail", 2, "scored 3 case(s) an earlier attempt"),
        ("a resume that would leave a case out", [("drop", 3), ("skip",)],
         {}, alive, "fail", 2, "ran 7 cases over 2 attempts"),
        ("a failure scored before the drop", [("drop", 3), ("all",)], failed,
         alive, "pass", 2, "NEW failure: case 6.1.2"),
    ]
    for name, script, verdicts, problem, want, calls, text in scenarios:
        attempt, runs = wstest_model(cases, script, verdicts)
        kept, said = [], []

        def on_thin(n, ran, total, transcript):
            kept.append(n)

        def say(msg, **_):
            said.append(msg)

        try:
            results, notes = drive_section(
                "6", len(cases), attempt, lambda: problem, on_thin, say)
            got = "pass"
            # What the run's own comparison would then say of the section.
            outcome = " ".join(notes + compare(results, ran_sections={"6"}))
        except SectionFailed as e:
            got, outcome = "fail", str(e)
        except Exception as e:
            return f"selftest: {name}: drive_section raised {e!r}"
        if got != want or len(runs) != calls or text not in outcome:
            return (
                f"selftest: {name}: wanted {want} after {calls} wstest run(s) "
                f"carrying {text!r}; got {got} after {len(runs)}: {outcome!r}"
            )
        # Every attempt but a last one that completed the section left it
        # short, and each of those keeps its evidence.
        short = calls - 1 if want == "pass" else calls
        if kept != list(range(1, short + 1)):
            return (f"selftest: {name}: evidence kept for attempts {kept}, "
                    f"want {list(range(1, short + 1))}")
        if want == "fail":
            continue
        if sorted(results) != cases:
            return (f"selftest: {name}: the section's verdicts are "
                    f"{sorted(results)}, not each of its cases once")
        for (n, case), behavior in verdicts.items():
            if results.get(case) != behavior:
                return (f"selftest: {name}: attempt {n}'s {behavior} for "
                        f"{case} is not in the verdicts returned")
        # A resume runs only what no attempt before it scored.
        scored = []
        for n, done in enumerate(runs, 1):
            if done != sorted(scored):
                return (f"selftest: {name}: attempt {n} was told to skip "
                        f"{done}, not the {len(scored)} case(s) already "
                        f"scored")
            scored += [c for c in cases if c not in done][
                :script[n - 1][1] if script[n - 1][0] == "drop" else None]
        resumes = [s for s in said if "RESUME" in s]
        if len(resumes) != calls - 1:
            return (f"selftest: {name}: {calls - 1} resume(s) made, "
                    f"{len(resumes)} said so")
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


def run_section(name, cases, workdir, token, port, exclude=()):
    """One wstest invocation via create/cp/start/cp — no bind mounts.

    `exclude` is the case ids an earlier attempt scored: wstest's
    `exclude-cases` takes exact ids as well as patterns, and runs the case
    list less those, so a resume starts at the first case not reached.
    """
    cfgdir = workdir / f"cfg-{name}"
    cfgdir.mkdir(exist_ok=True)  # a resume writes its own config over it
    (cfgdir / "fuzzingclient.json").write_text(json.dumps({
        "options": {"failByDrop": False},
        "outdir": "/reports",
        "servers": [{"agent": "m0serve",
                     "url": f"ws://host.docker.internal:{port}"}],
        "cases": cases,
        "exclude-cases": list(exclude),
        "exclude-agent-cases": {},
    }))
    ctr = f"m0autobahn-{name.replace('-', '')}-{token}"
    run("docker", "create", "--name", ctr,
        "--add-host", "host.docker.internal:host-gateway",
        IMAGE, "wstest", "-m", "fuzzingclient", "-s", "/cfg/fuzzingclient.json")
    try:
        run("docker", "cp", str(cfgdir), f"{ctr}:/cfg")
        print(f"[section {name}] running {cases}"
              + (f" less the {len(exclude)} case(s) already scored"
                 if exclude else "") + " ...", flush=True)
        started = run("docker", "start", "-a", ctr, timeout=1800, check=False)
        transcript = f"{started.stdout}\n--- stderr ---\n{started.stderr}"
        if started.returncode != 0:
            fail(
                f"[section {name}] wstest exited {started.returncode}:\n"
                f"{started.stdout[-2000:]}{started.stderr[-2000:]}"
            )
        outdir = workdir / f"reports-{name}"
        shutil.rmtree(outdir, ignore_errors=True)  # this attempt's alone
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


def keep_thin(name, attempt, ran, total, expected, transcript, server_log,
              keep_dir):
    """Print and keep the evidence of a thin attempt: wstest's words, the log.

    `ran` is this attempt's own cases, `total` the section's so far.

    `keep_dir` is this run's own directory, made the first time a section
    runs thin, so a clean run leaves nothing behind.
    """
    keep_dir.mkdir(parents=True, exist_ok=True)
    wst = keep_dir / f"section{name}-attempt{attempt}.wstest.txt"
    wst.write_text(transcript)
    log = keep_dir / f"section{name}-attempt{attempt}.server.log"
    text = server_log.read_text(errors="replace") if server_log.exists() else ""
    log.write_text(text)
    print(f"[section {name}] thin: attempt {attempt} ran {ran} case(s), "
          f"{total} of {expected} so far", file=sys.stderr)
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
    """`attempt` (one `run_section`) under `drive_section`'s resumes."""
    def on_thin(n, ran, total, transcript):
        keep_thin(name, n, ran, total, expected, transcript, server_log,
                  keep_dir)

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
    results, notes = {}, []
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
                section, section_notes = checked_section(
                    name, expected_count,
                    lambda n, done: run_section(name, cases, workdir, token,
                                                port, exclude=done),
                    server, port, server_log, keep_dir)
                results.update(section)
                notes += section_notes
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
    # Which cases, so a tally that moves between runs can be traced to one.
    for behavior in sorted(b for b in tally if b != "OK"):
        ids = sorted((c for c, b in results.items() if b == behavior),
                     key=lambda c: tuple(int(x) for x in c.split(".")))
        print(f"autobahn: {behavior}: {' '.join(ids)}")
    for note in notes:
        print(f"autobahn: {note}")

    errors = compare(results, ran_sections={s[0] for s in sections})
    for e in errors:
        print(f"autobahn: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("autobahn OK: the baseline holds — every failure is I17's cap,"
          " and every one of I17's cases still fails"
          + (f" ({len(notes)} section(s) resumed after a dropped connect, "
             f"above)" if notes else ""))


if __name__ == "__main__":
    main()
