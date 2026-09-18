#!/usr/bin/env python3
"""N forked workers against N loops on N threads, for a Mojo host application.

The question DECISIONS D35 answers by measurement: a Mojo app has no GIL and
no interpreter to fork before, so is its default `M0_WORKERS=N` or
`M0_THREADS=N`? One binary (`apps/ramp` under the Mojo host), three arms per
round, each a fresh server on its own port:

    workers=1    the comparator: it moves with the machine, not with the mode
    workers=N    prefork, accept sharing on
    threads=N    N loops on N threads of one process, accept sharing on

against two routes -- `/x/now`, answered on the loop, which measures the LOOP;
and `/x/search?sel=25`, the table's compute view, which measures the loop
with real work behind it -- at two connection counts. Keep-alive throughout,
with the keep-alive request cap OFF (`M0_MAX_KEEPALIVE_REQUESTS=0`): a cap is
a client reconnect per N requests, which shows as the tail and leaves
TIME_WAIT for the next arm to trip over.

Cores and RSS are summed over the server's whole process tree (the
supervisor and its workers, or the one threaded process), from `ps`: cores
as CPU seconds over wall seconds across the measured window, RSS sampled
mid-run. Summed RSS counts a page two workers share twice; the ramp's corpus
is built after the fork, so little is shared, and the column says "summed".

Each arm's accept-share lines are kept from its log: a throughput row whose
connections all sat on one loop is one loop's throughput, and the hand-off
counts are how a reader tells.

    uv run poe bench-host-modes                  # macOS, N=4
    python3 scripts/bench_host_modes.py --n 2 --wrk-threads 2 --name host_modes_linux
"""

import argparse
import pathlib
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from bench_record import write_artifact  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parent.parent
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    import traceback
    traceback.print_exception(kind, exc, tb)
    print("bench_host_modes FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def _tree(pid):
    """`pid` and its children: the supervisor and its forked workers."""
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [pid] + [int(p) for p in out.split()]


def _cpu_seconds(pids):
    total = 0.0
    for pid in pids:
        out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                             capture_output=True, text=True).stdout.strip()
        if not out:
            continue
        days, _, rest = out.rpartition("-")
        parts = [float(p) for p in rest.split(":")]
        while len(parts) < 3:
            parts.insert(0, 0.0)
        total += (int(days) if days else 0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]
    return total


def _rss_kb(pids):
    total = 0
    for pid in pids:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                             capture_output=True, text=True).stdout.strip()
        if out:
            total += int(out)
    return total


def _us(text):
    if text is None:
        return None
    for suffix, mult in (("us", 1.0), ("ms", 1000.0), ("s", 1e6)):
        if text.endswith(suffix):
            return round(float(text[: -len(suffix)]) * mult, 1)
    return None


def _wrk(url, threads, conns, secs):
    out = subprocess.run(
        ["wrk", f"-t{threads}", f"-c{conns}", f"-d{secs}s", "--latency", url],
        capture_output=True, text=True).stdout
    rps = p50 = p99 = None
    errors = 0
    for line in out.splitlines():
        s = line.split()
        if line.startswith("Requests/sec:"):
            rps = float(s[1])
        elif s and s[0] == "50%":
            p50 = s[1]
        elif s and s[0] == "99%":
            p99 = s[1]
        elif "Socket errors" in line or "Non-2xx" in line:
            errors += sum(int(n) for n in re.findall(r"\d+", line))
    return rps, p50, p99, errors


ARMS = ("workers=1", "workers=N", "threads=N")


def arm_env(arm, n):
    if arm == "workers=1":
        return {}
    if arm == "workers=N":
        return {"M0_WORKERS": str(n)}
    return {"M0_THREADS": str(n)}


def run_arm(binary, arm, n, port, url_path, wrk_threads, conns, secs):
    import os

    env = dict(os.environ)
    for k in ("M0_WORKERS", "M0_THREADS", "M0_BLOCKING_THREADS"):
        env.pop(k, None)
    env.update(arm_env(arm, n))
    env.update({"M0_PORT": str(port), "M0_MAX_KEEPALIVE_REQUESTS": "0",
                "M0_ACCESS_LOG": "0"})
    log_path = REPO / "bin" / f"bench_host_modes_{port}.log"
    log_path.parent.mkdir(exist_ok=True)
    with open(log_path, "w") as log:
        srv = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
        url = f"http://127.0.0.1:{port}{url_path}"
        try:
            for _ in range(100):
                try:
                    urllib.request.urlopen(url, timeout=5).read()
                    break
                except Exception:
                    time.sleep(0.1)
            else:
                sys.exit(f"{arm} never became healthy; it said:\n" + log_path.read_text())
            _wrk(url, wrk_threads, conns, 2)  # warm every loop
            pids = _tree(srv.pid)
            rss = []
            sampler = threading.Timer(secs / 2.0, lambda: rss.append(_rss_kb(pids)))
            sampler.start()
            c0, w0 = _cpu_seconds(pids), time.perf_counter()
            rps, p50, p99, errors = _wrk(url, wrk_threads, conns, secs)
            c1, w1 = _cpu_seconds(pids), time.perf_counter()
            sampler.join()
        finally:
            srv.terminate()
            try:
                srv.wait(timeout=15)
            except subprocess.TimeoutExpired:
                srv.kill()
    cores = (c1 - c0) / (w1 - w0)
    said = log_path.read_text()
    passed = [int(m) for m in re.findall(r"passed (\d+) connections", said)]
    got = [int(m) for m in re.findall(r"received (\d+)", said)]
    return {
        "rps": round(rps, 1) if rps else None,
        "cores": round(cores, 2),
        "rps_per_core": int(rps / cores) if rps and cores > 0 else None,
        "p50_us": _us(p50),
        "p99_us": _us(p99),
        "rss_kb_summed": rss[0] if rss else None,
        "processes": len(pids),
        "errors": errors,
        "handoffs_out": passed,
        "handoffs_in": got,
    }


def compare(rows, n):
    """threads=N over workers=N, within the round, per route and connection
    count: the two arms of a round run back to back on one machine state."""
    by = {(r["round"], r["name"]): r for r in rows}
    out = {}
    cases = sorted({r["name"].split(" ", 1)[1] for r in rows})
    for case in cases:
        thru, per, p99, rss = [], [], [], []
        for rnd in sorted({r["round"] for r in rows}):
            w = by.get((rnd, f"workers=N {case}"))
            t = by.get((rnd, f"threads=N {case}"))
            if not w or not t:
                continue
            if w["rps"] and t["rps"]:
                thru.append(t["rps"] / w["rps"])
            if w["rps_per_core"] and t["rps_per_core"]:
                per.append(t["rps_per_core"] / w["rps_per_core"])
            if w["p99_us"] and t["p99_us"]:
                p99.append(t["p99_us"] / w["p99_us"])
            if w["rss_kb_summed"] and t["rss_kb_summed"]:
                rss.append(t["rss_kb_summed"] / w["rss_kb_summed"])
        med = lambda xs: round(statistics.median(xs), 3) if xs else None  # noqa: E731
        out[case] = {"throughput": med(thru), "per_core": med(per),
                     "p99": med(p99), "rss": med(rss), "rounds": len(thru)}
    return {
        "definition": f"by_case[case]: threads={n} over workers={n}, the median "
        "across rounds of the ratio within each round; throughput and per_core "
        "above 1 favour threads, p99 and rss below 1 favour threads",
        "n": n,
        "by_case": out,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4, help="workers, and loops")
    ap.add_argument("--port", type=int, default=8870)
    ap.add_argument("--conns", default="16,256")
    ap.add_argument("--secs", type=int, default=8)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--wrk-threads", type=int, default=4)
    ap.add_argument("--gap", type=float, default=2.0)
    ap.add_argument("--name", default="host_modes")
    ap.add_argument("--binary", default="")
    ap.add_argument("--no-guard", action="store_true")
    args = ap.parse_args()

    binary = pathlib.Path(args.binary) if args.binary else REPO / "bin" / "ramp_host"
    if not args.binary:
        phase("building apps/ramp under the Mojo host")
        binary.parent.mkdir(exist_ok=True)
        subprocess.run(
            ["mojo", "build", "-I", "packages/m0-core/", "-I", "packages/m0-http/",
             "-I", "apps/", "apps/ramp/server.mojo", "-o", str(binary)],
            cwd=REPO, check=True)

    if not args.no_guard:
        phase("waiting for a quiet machine")
        guard = subprocess.run(
            [sys.executable, str(REPO / "scripts" / "bench_guard.py"), "wait",
             "--threshold", "50", "--samples", "3", "--timeout", "120"])
        if guard.returncode != 0:
            sys.exit("bench_guard: the machine did not go quiet")

    routes = (("now", "/x/now"), ("search", "/x/search?sel=25"))
    conns = [int(c) for c in args.conns.split(",")]
    rows = []
    port = args.port
    phase("measuring")
    for rnd in range(1, args.rounds + 1):
        for route, path in routes:
            for c in conns:
                for arm in ARMS:
                    port += 1  # a fresh port per server: SO_REUSEPORT lets a stray one answer
                    r = run_arm(binary, arm, args.n, port, path, args.wrk_threads, c, args.secs)
                    r.update(round=rnd, name=f"{arm} {route} c{c}")
                    rows.append(r)
                    print(f"  r{rnd} {r['name']:<24} rps={r['rps']:<10} cores={r['cores']:<5} "
                          f"/core={r['rps_per_core']:<8} p99={r['p99_us']}us "
                          f"rss={r['rss_kb_summed']}kB err={r['errors']}", flush=True)
                    time.sleep(args.gap)

    phase("writing the artifact")
    comparisons = compare(rows, args.n)
    print(f"\nthreads={args.n} / workers={args.n}, median of within-round ratios:")
    for case, c in comparisons["by_case"].items():
        print(f"  {case:<12} thru {c['throughput']}x  per core {c['per_core']}x  "
              f"p99 {c['p99']}x  rss {c['rss']}x")
    write_artifact(args.name, rows, {
        "duration": f"{args.secs}s", "connections": args.conns,
        "rounds": str(args.rounds), "n": str(args.n),
        "wrk_threads": str(args.wrk_threads),
        "subject": "apps/ramp under m0_host.serve; /x/now on the loop, /x/search?sel=25 in func",
        "keepalive_cap": "off (M0_MAX_KEEPALIVE_REQUESTS=0)",
    }, extra={"comparisons": comparisons})
    return 0


if __name__ == "__main__":
    sys.exit(main())
