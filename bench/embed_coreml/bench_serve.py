"""bench/embed_coreml/bench_serve.py — one server, one load shape, one table row.

Starts app.py under m0serve or uvicorn, warms every worker, drives it with
wrk (POST /embed, a fixed sentence so every request lands in the same Core ML
bucket), and prints requests/s, sentences/s, p50 and p99. Kills the server
on exit. Drive it from Python, one configuration per process, so the two
servers never share a machine at the same moment:

    python bench_serve.py --server m0serve --instances 2 --workers 1 --blocking-threads 2 \
        --m0serve /path/to/bin/m0serve --python-bin /path/to/venv/bin
    python bench_serve.py --server uvicorn --workers 2 --python-bin /path/to/venv/bin

`--python-bin` is prepended to PATH: m0serve embeds the python3 it finds
there, and uvicorn runs from it, so both servers use the SAME interpreter
and the same coremltools. Requires wrk (brew install wrk), the converted
models (`npm run convert:coreml` in mojo-addon-examples/packages/embed) and
QKSTAT_EMBED_DIR if that checkout is not the sibling of this one. The rows
in docs/notes/coreml-embeddings.md were driven by a script that ran these
one at a time on an idle machine; never two at once (SO_REUSEPORT lets a
second server take the port, and the row then measures neither).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
QUERY = "how does authentication work in a web application"

LUA = """
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.body = %s
"""


def wait_health(url: str, timeout: float) -> None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            with urllib.request.urlopen(url + "/health", timeout=1) as r:
                if r.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise SystemExit(f"server at {url} never answered /health")


def post(url: str, body: bytes) -> dict:
    req = urllib.request.Request(url + "/embed", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())


def parse_wrk(out: str) -> dict:
    d = {}
    m = re.search(r"Requests/sec:\s+([\d.]+)", out)
    d["rps"] = float(m.group(1)) if m else float("nan")
    for pct in ("50", "99"):
        m = re.search(rf"^\s+{pct}%\s+([\d.]+)(us|ms|s)\s*$", out, re.M)
        if m:
            v, unit = float(m.group(1)), m.group(2)
            d[f"p{pct}_ms"] = v / 1000 if unit == "us" else v * 1000 if unit == "s" else v
        else:
            d[f"p{pct}_ms"] = float("nan")
    m = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", out)
    d["errors"] = int(m.group(1)) if m else 0
    m = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", out)
    d["socket_errors"] = sum(int(x) for x in m.groups()) if m else 0
    return d


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", choices=["m0serve", "uvicorn"], required=True)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--instances", type=int, default=1,
                    help="independent server processes on the same port (m0serve: Core ML cannot run in a forked worker)")
    ap.add_argument("--blocking-threads", type=int, default=2, help="m0serve only")
    ap.add_argument("--m0serve", default="m0serve")
    ap.add_argument("--python-bin", required=True, help="venv bin dir with python3, uvicorn, coremltools")
    ap.add_argument("--wrk", default="/opt/homebrew/bin/wrk")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--backend", default="coreml")
    ap.add_argument("--texts", type=int, default=1, help="sentences per request")
    ap.add_argument("--connections", type=int, default=8)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--duration", type=int, default=15)
    ap.add_argument("--warm", type=int, default=200, help="warm requests before wrk")
    ap.add_argument("--extra", default="", help="extra server args, space-separated")
    ap.add_argument("--env", action="append", default=[], metavar="KEY=VAL",
                    help="extra server environment (the max backend needs MODULAR_HOME and CONDA_PREFIX as `pixi run` sets them)")
    ap.add_argument("--json", help="append the result as one JSON line here")
    args = ap.parse_args()

    env = dict(os.environ)
    env["PATH"] = args.python_bin + os.pathsep + env.get("PATH", "")
    env["QKSTAT_EMBED_BACKEND"] = args.backend
    env["TOKENIZERS_PARALLELISM"] = "false"
    for kv in args.env:
        k, _, v = kv.partition("=")
        env[k] = v
    python = os.path.join(args.python_bin, "python3")
    if args.server == "m0serve":
        cmd = [args.m0serve, "--app-dir", HERE, "app:application", "--host", "127.0.0.1", "--port", str(args.port),
               "--workers", str(args.workers), "--blocking-threads", str(args.blocking_threads)]
    else:
        cmd = [python, "-m", "uvicorn", "--app-dir", HERE, "--interface", "wsgi", "app:application",
               "--host", "127.0.0.1", "--port", str(args.port), "--workers", str(args.workers), "--log-level", "warning"]
    cmd += args.extra.split()
    url = f"http://127.0.0.1:{args.port}"
    # A stray server on the port would take a share of the connections (or all
    # of them, on macOS) and the row would measure something else.
    try:
        urllib.request.urlopen(url + "/health", timeout=1)
        raise SystemExit(f"port {args.port} already answers /health: kill the stray first")
    except SystemExit:
        raise
    except Exception:
        pass
    body = json.dumps({"texts": [QUERY] * args.texts}).encode()

    log_path = os.path.join(tempfile.gettempdir(), f"bench_serve_{args.server}_{args.port}.log")
    log = open(log_path, "wb")
    procs = [subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, cwd=HERE, start_new_session=True)
             for _ in range(args.instances)]
    try:
        wait_health(url, 60)
        # Warm: every worker must load its engine before the timed run. The
        # warm requests are also the measurement of how connections spread
        # across processes (one connection per request here).
        first = post(url, body)
        assert len(first["embeddings"]) == args.texts and len(first["embeddings"][0]) == 384, first.keys()
        with ThreadPoolExecutor(8) as ex:
            pids = list(ex.map(lambda _: post(url, body).get("pid"), range(args.warm)))
        spread = {str(p): pids.count(p) for p in sorted(set(pids), key=lambda p: -pids.count(p))}
        lua = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False)
        lua.write(LUA % json.dumps(body.decode()))
        lua.close()
        wrk_cmd = [args.wrk, "-t", str(args.threads), "-c", str(args.connections), "-d", f"{args.duration}s",
                   "--latency", "-s", lua.name, url + "/embed"]
        out = subprocess.run(wrk_cmd, capture_output=True, text=True, timeout=args.duration + 60).stdout
        r = parse_wrk(out)
        row = {
            "server": args.server, "workers": args.workers, "instances": args.instances,
            "blocking_threads": args.blocking_threads if args.server == "m0serve" else None,
            "backend": first.get("backend"), "shape": first.get("shape"), "texts": args.texts,
            "connections": args.connections, "rps": round(r["rps"], 1),
            "sentences_per_s": round(r["rps"] * args.texts, 1),
            "p50_ms": round(r["p50_ms"], 3), "p99_ms": round(r["p99_ms"], 3),
            "errors": r["errors"], "socket_errors": r["socket_errors"], "extra": args.extra,
            "warm_pid_spread": spread,
        }
        print(json.dumps(row))
        if args.json:
            with open(args.json, "a") as f:
                f.write(json.dumps(row) + "\n")
        if r["errors"] or r["socket_errors"]:
            print(out, file=sys.stderr)
            return 1
        return 0
    finally:
        for proc in procs:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass  # already gone (a failed bind, a crash): nothing to signal
        for proc in procs:
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                proc.wait()
        log.close()


if __name__ == "__main__":
    sys.exit(main())
