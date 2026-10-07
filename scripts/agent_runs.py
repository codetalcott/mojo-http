#!/usr/bin/env python3
"""Agent usability runs: fresh headless coding-agent sessions on a quickstart
task, with only PyPI and the docs site reachable, scored from their
transcripts.

    python3 scripts/agent_runs.py run --track python --out STAGE --archive DIR [--n 5]
    python3 scripts/agent_runs.py probe RUN_DIR          # re-run the contract probe
    python3 scripts/agent_runs.py score RUN_DIR          # re-score one run
    python3 scripts/agent_runs.py summary DIR            # table over every run under DIR

A run is one `claude -p` session (Claude Code, headless) started in an
empty directory with no settings, hooks, plugins, MCP servers or CLAUDE.md
from the machine it runs on, handed the brief in `scripts/agent_runs/
<track>.md`. The brief names the product and its documentation URL and
nothing the documentation says: no flag, no header, no module. It also
fixes a contract (`run.sh PORT`, `GET /`, `POST /messages`, SSE on
`/stream`) so that the harness, not the agent, decides whether the result
works: after the session ends, `probe` starts the application and sends
one message past two open streams.

A session runs under STAGE, which must lie outside this user's `projects`
tree (the deny rule below covers all of it, the agent's own directory
included, which the first pilot found), and the finished run moves to
`--archive DIR` once scored. What is recorded per run, under `DIR/<track>-<n>/`:

    brief.md         the prompt as sent
    transcript.jsonl the session, stream-json, every tool call and result
    result.json      the session's final result message (cost, turns, time)
    work/            the directory the agent worked in, as it left it
    probe.json       the contract probe's verdict, and the server's output
    score.json       counts read off the transcript, and the flagged results
    score.md         the same, to read

The score is counts, not judgement: tool calls to the end, calls before
the first flagged result, the flagged results themselves (an `is_error`
tool result, or a Bash result whose first lines look like a failure), the
documentation pages fetched, and any reference to a source checkout on
this machine, which the session was told not to read. Which flagged
result was the first WRONG move is read by a person from the transcript.

Isolation is three layers, none of which is a sandbox on its own:
`--setting-sources ""` so nothing of this machine's configuration loads,
an allow list of tools with WebFetch restricted to the track's domains and
WebSearch and subagents refused, a deny on reading this user's `projects`
tree, and the brief's own rule. `--sandbox-settings FILE` adds a Claude
Code sandbox settings file on top; the first pilot showed its network proxy
breaking pip's TLS (`SSLCertVerificationError` on every index request), a
failure the product never causes, so the recorded runs went without it.
Every run is scored for violations regardless: a reference to a checkout
of the product on this machine, or a fetch from GitHub.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
BRIEFS = HERE / "agent_runs"

TRACKS = {
    "python": {
        "brief": "python.md",
        "domains": ["m0serve.dev", "pypi.org"],
        "ready_s": 60,
    },
    "mojo": {
        "brief": "mojo.md",
        "domains": ["m0serve.dev", "pypi.org"],
        "ready_s": 240,  # run.sh may build first
    },
    "channels": {
        "brief": "channels.md",
        "domains": ["channels.readthedocs.io", "docs.djangoproject.com", "pypi.org"],
        "ready_s": 60,
    },
}

ALWAYS_ALLOWED = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "MultiEdit", "NotebookEdit"]
DISALLOWED = ["WebSearch", "Agent", "Task", "AskUserQuestion", "Artifact"]
DENY_READ = "Read(//Users/*/projects/**)"
SYSTEM_RULES = (
    "This session is a usability measurement. You are a developer who has never "
    "seen this product or this machine. Use only: the tools installed on the "
    "machine, packages from PyPI, the documentation URLs named in the task, and "
    "what you already know. Do not search the machine for source checkouts, "
    "notes or examples of the product, and do not read anything under this "
    "user's home directory other than your working directory and the package "
    "caches your tools use. Work alone, in this directory, until the task is "
    "done or you are certain it cannot be done; nobody will answer questions."
)

FAIL_RE = re.compile(
    r"(Traceback|Error:|error:|ERROR|No such file|not found|unrecognized|"
    r"refused|Refused|No module named|command not found|Address already in use|"
    r"exit code [1-9]|exit status [1-9]|failed|FAILED|Failed)"
)
VIOLATION_RE = re.compile(r"(mojo-http|/Users/[^/\s]+/projects/|~/projects|github\.com|githubusercontent)")


# ----------------------------------------------------------------------------
# run


def claude_env() -> dict:
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("CLAUDE"):
            del env[k]
    return env


def run_one(track: str, run_dir: Path, model: str | None, budget: float,
            timeout_s: int, sandbox_settings: Path | None) -> dict:
    cfg = TRACKS[track]
    run_dir.mkdir(parents=True, exist_ok=False)
    work = run_dir / "work"
    work.mkdir()
    brief = (BRIEFS / cfg["brief"]).read_text()
    (run_dir / "brief.md").write_text(brief)
    allowed = ALWAYS_ALLOWED + [f"WebFetch(domain:{d})" for d in cfg["domains"]]
    cmd = [
        "claude", "-p", brief,
        "--output-format", "stream-json", "--verbose",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--permission-prompts", "none",
        "--allowedTools", *allowed,
        "--disallowedTools", *DISALLOWED, DENY_READ,
        "--append-system-prompt", SYSTEM_RULES,
        "--max-budget-usd", str(budget),
    ]
    if model:
        cmd += ["--model", model]
    if sandbox_settings:
        cmd += ["--settings", str(sandbox_settings)]
    (run_dir / "command.json").write_text(json.dumps(cmd, indent=1))
    started = time.time()
    with open(run_dir / "transcript.jsonl", "wb") as out, \
            open(run_dir / "stderr.txt", "wb") as err:
        proc = subprocess.Popen(cmd, cwd=work, stdout=out, stderr=err,
                                env=claude_env(), start_new_session=True)
        timed_out = False
        try:
            proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    # Whatever the agent left running (a server it forgot) dies with its group.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    wall = time.time() - started
    result = {"exit": proc.returncode, "timed_out": timed_out, "wall_s": round(wall, 1)}
    for line in (run_dir / "transcript.jsonl").read_text(errors="replace").splitlines():
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            continue
        if m.get("type") == "result":
            for k in ("subtype", "is_error", "num_turns", "duration_ms", "total_cost_usd",
                      "permission_denials", "stop_reason", "terminal_reason"):
                if k in m:
                    result[k] = m[k]
            result["result_text"] = m.get("result", "")
        elif m.get("type") == "system" and m.get("subtype") == "init":
            result["model"] = m.get("model")
    (run_dir / "result.json").write_text(json.dumps(result, indent=1))
    return result


# ----------------------------------------------------------------------------
# probe: the harness's own verdict on the contract


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def http_get(url: str, timeout: float = 3.0):
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.headers.get("content-type", ""), r.read()


def probe(run_dir: Path, ready_s: int) -> dict:
    work = run_dir / "work"
    verdict: dict = {"ok": False, "steps": []}
    if not (work / "run.sh").exists():
        verdict["reason"] = "no run.sh"
        (run_dir / "probe.json").write_text(json.dumps(verdict, indent=1))
        return verdict
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    log = open(run_dir / "probe-server.txt", "wb")
    server = subprocess.Popen(["sh", "run.sh", str(port)], cwd=work, stdout=log,
                              stderr=subprocess.STDOUT, env=claude_env(),
                              start_new_session=True)
    streams = []
    try:
        deadline = time.time() + ready_s
        page = None
        while time.time() < deadline:
            if server.poll() is not None:
                verdict["reason"] = f"run.sh exited {server.returncode} before answering"
                return verdict
            try:
                page = http_get(base + "/")
                break
            except Exception:
                time.sleep(0.5)
        if page is None:
            verdict["reason"] = f"GET / not answered within {ready_s}s"
            return verdict
        verdict["steps"].append({"GET /": page[0], "content-type": page[1]})
        if page[0] != 200 or "html" not in page[1]:
            verdict["reason"] = "GET / is not an HTML 200"
            return verdict
        nonce = f"probe-{int(time.time())}-{os.getpid()}"
        files = []
        for i in range(2):
            f = open(run_dir / f"probe-stream{i}.txt", "wb")
            files.append(f)
            streams.append(subprocess.Popen(
                ["curl", "-sN", "--max-time", "15", base + "/stream"],
                stdout=f, stderr=subprocess.DEVNULL))
        time.sleep(1.5)
        data = urllib.parse.urlencode({"text": nonce}).encode()
        req = urllib.request.Request(base + "/messages", data=data, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                verdict["steps"].append({"POST /messages": r.status})
        except urllib.error.HTTPError as e:
            verdict["steps"].append({"POST /messages": e.code})
            if e.code >= 400:
                verdict["reason"] = f"POST /messages answered {e.code}"
                return verdict
        got = [False, False]
        deadline = time.time() + 8
        while time.time() < deadline and not all(got):
            for i, f in enumerate(files):
                f.flush()
                txt = (run_dir / f"probe-stream{i}.txt").read_bytes()
                got[i] = nonce.encode() in txt
            time.sleep(0.2)
        verdict["steps"].append({"streams received": got})
        if not all(got):
            verdict["reason"] = f"message reached {sum(got)} of 2 streams within 8s"
            return verdict
        # The stream's content type, from a fresh request's head.
        head = subprocess.run(["curl", "-sI", "--max-time", "3", base + "/stream"],
                              capture_output=True, text=True)
        ct = ""
        for line in head.stdout.splitlines():
            if line.lower().startswith("content-type:"):
                ct = line.split(":", 1)[1].strip()
        verdict["stream_content_type"] = ct
        verdict["ok"] = True
        verdict["reason"] = "contract met"
        return verdict
    finally:
        for s in streams:
            s.kill()
        try:
            os.killpg(server.pid, signal.SIGTERM)
            server.wait(timeout=10)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(server.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        log.close()
        verdict["port"] = port
        (run_dir / "probe.json").write_text(json.dumps(verdict, indent=1))


import urllib.parse  # noqa: E402  (after the functions that use it, for the docstring's sake)
import urllib.error  # noqa: E402


# ----------------------------------------------------------------------------
# score


def iter_messages(path: Path):
    for line in path.read_text(errors="replace").splitlines():
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def score(run_dir: Path) -> dict:
    calls = []          # one per tool_use, in order
    by_id = {}
    for m in iter_messages(run_dir / "transcript.jsonl"):
        if m.get("type") == "assistant":
            for b in m.get("message", {}).get("content", []):
                if b.get("type") == "tool_use":
                    c = {"n": len(calls) + 1, "tool": b["name"], "input": b.get("input", {}),
                         "id": b["id"], "error": False, "flag": None}
                    calls.append(c)
                    by_id[b["id"]] = c
        elif m.get("type") == "user":
            for b in m.get("message", {}).get("content", []):
                if b.get("type") == "tool_result" and b.get("tool_use_id") in by_id:
                    c = by_id[b["tool_use_id"]]
                    content = b.get("content", "")
                    if isinstance(content, list):
                        content = "\n".join(x.get("text", "") for x in content if isinstance(x, dict))
                    c["result_head"] = content[:400]
                    if b.get("is_error"):
                        c["error"] = True
                        c["flag"] = "is_error"
                    elif c["tool"] == "Bash" and FAIL_RE.search(content[:1500]):
                        c["flag"] = "looks failed"
    tools: dict[str, int] = {}
    for c in calls:
        tools[c["tool"]] = tools.get(c["tool"], 0) + 1
    flagged = [c for c in calls if c["flag"]]
    fetched = [c["input"].get("url") for c in calls if c["tool"] == "WebFetch"]
    for c in calls:  # a docs page read with curl is a docs page read
        if c["tool"] == "Bash":
            fetched += re.findall(r"https?://[\w.-]*(?:readthedocs\.io|djangoproject\.com|m0serve\.dev)[^\s'\"|;)]*",
                                  c["input"].get("command", ""))
    violations = []
    for c in calls:
        blob = json.dumps(c["input"])
        if VIOLATION_RE.search(blob):
            violations.append({"n": c["n"], "tool": c["tool"], "input": blob[:300]})
    bash = [c["input"].get("command", "")[:200] for c in calls if c["tool"] == "Bash"]
    flags_used = sorted(set(re.findall(r"(?<![\w-])(--[a-z][a-z-]+)", " ".join(
        c for c in bash if "m0serve" in c or "m0 " in c or "bin/server" in c))))
    result = json.loads((run_dir / "result.json").read_text()) if (run_dir / "result.json").exists() else {}
    probe_v = json.loads((run_dir / "probe.json").read_text()) if (run_dir / "probe.json").exists() else {}
    s = {
        "run": run_dir.name,
        "model": result.get("model"),
        "tool_calls": len(calls),
        "by_tool": tools,
        "calls_before_first_flag": (flagged[0]["n"] - 1) if flagged else len(calls),
        "flagged": [{"n": c["n"], "tool": c["tool"], "flag": c["flag"],
                     "command": (c["input"].get("command") or c["input"].get("url") or
                                 c["input"].get("file_path") or "")[:200],
                     "result_head": c.get("result_head", "")[:300]} for c in flagged],
        "docs_fetched": fetched,
        "server_flags_used": flags_used,
        "violations": violations,
        "num_turns": result.get("num_turns"),
        "cost_usd": result.get("total_cost_usd"),
        "wall_s": result.get("wall_s"),
        "timed_out": result.get("timed_out"),
        "subtype": result.get("subtype"),
        "probe_ok": probe_v.get("ok"),
        "probe_reason": probe_v.get("reason"),
        "report": result.get("result_text", "")[:4000],
    }
    (run_dir / "score.json").write_text(json.dumps(s, indent=1))
    lines = [f"# {s['run']}", "",
             f"model {s['model']}; {s['tool_calls']} tool calls over {s['num_turns']} turns; "
             f"${s['cost_usd']}; {s['wall_s']} s; session ended {s['subtype']}"
             f"{' (timed out)' if s['timed_out'] else ''}",
             f"probe: {'PASS' if s['probe_ok'] else 'FAIL'} ({s['probe_reason']})",
             f"by tool: {json.dumps(tools)}",
             f"calls before the first flagged result: {s['calls_before_first_flag']}",
             f"server flags used: {' '.join(flags_used) or '(none seen)'}",
             f"violations: {len(violations)}", "",
             "## docs fetched", ""] + [f"- {u}" for u in fetched] + ["", "## flagged results", ""]
    for f in s["flagged"]:
        lines += [f"### {f['n']}. {f['tool']} ({f['flag']})", "", "```", f["command"], "```",
                  "```", f["result_head"], "```", ""]
    lines += ["## the agent's report", "", s["report"]]
    (run_dir / "score.md").write_text("\n".join(lines) + "\n")
    return s


def summary(out: Path) -> str:
    rows = []
    for d in sorted(p for p in out.iterdir() if p.is_dir() and (p / "transcript.jsonl").exists()):
        s = json.loads((d / "score.json").read_text()) if (d / "score.json").exists() else score(d)
        rows.append(s)
    lines = ["| run | model | probe | tool calls | before 1st flag | flagged | docs fetched | turns | cost | wall |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for s in rows:
        lines.append(f"| {s['run']} | {s['model']} | {'PASS' if s['probe_ok'] else 'FAIL'} | "
                     f"{s['tool_calls']} | {s['calls_before_first_flag']} | {len(s['flagged'])} | "
                     f"{len(s['docs_fetched'])} | {s['num_turns']} | {s['cost_usd']} | {s['wall_s']} |")
    text = "\n".join(lines) + "\n"
    (out / "summary.md").write_text(text)
    return text


# ----------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--track", required=True, choices=sorted(TRACKS))
    r.add_argument("--out", required=True, type=Path)
    r.add_argument("--n", type=int, default=1)
    r.add_argument("--start", type=int, default=1, help="number the first run from here")
    r.add_argument("--model", default=None)
    r.add_argument("--budget", type=float, default=8.0, help="USD per session")
    r.add_argument("--timeout", type=int, default=1800, help="seconds per session")
    r.add_argument("--sandbox-settings", type=Path, default=None)
    r.add_argument("--archive", type=Path, default=None,
                   help="move each finished run here (the stage may not be under ~/projects)")
    p = sub.add_parser("probe")
    p.add_argument("run_dir", type=Path)
    p.add_argument("--ready", type=int, default=120)
    s = sub.add_parser("score")
    s.add_argument("run_dir", type=Path)
    m = sub.add_parser("summary")
    m.add_argument("out", type=Path)
    a = ap.parse_args()

    if a.cmd == "run":
        if "/projects/" in str(a.out.resolve()) + "/":
            ap.error("--out must lie outside ~/projects: the sessions are denied reads there")
        a.out.mkdir(parents=True, exist_ok=True)
        for i in range(a.start, a.start + a.n):
            run_dir = a.out / f"{a.track}-{i}"
            print(f"== {run_dir} starting {dt.datetime.now():%H:%M:%S}", flush=True)
            res = run_one(a.track, run_dir, a.model, a.budget, a.timeout, a.sandbox_settings)
            print(f"   session: {res.get('subtype')} turns={res.get('num_turns')} "
                  f"cost={res.get('total_cost_usd')} wall={res['wall_s']}s", flush=True)
            v = probe(run_dir, TRACKS[a.track]["ready_s"])
            print(f"   probe: {'PASS' if v['ok'] else 'FAIL'} ({v.get('reason')})", flush=True)
            sc = score(run_dir)
            print(f"   score: {sc['tool_calls']} calls, {len(sc['flagged'])} flagged, "
                  f"{len(sc['violations'])} violations", flush=True)
            if a.archive:
                a.archive.mkdir(parents=True, exist_ok=True)
                shutil.move(str(run_dir), str(a.archive / run_dir.name))
                print(f"   archived to {a.archive / run_dir.name}", flush=True)
        print(summary(a.archive or a.out))
    elif a.cmd == "probe":
        v = probe(a.run_dir, a.ready)
        print(json.dumps(v, indent=1))
        score(a.run_dir)
    elif a.cmd == "score":
        print(json.dumps(score(a.run_dir), indent=1))
    elif a.cmd == "summary":
        print(summary(a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
