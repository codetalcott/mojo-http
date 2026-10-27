#!/usr/bin/env python3
"""Two builds of `apps/hello`, interleaved in one session: did a change move it?

    python3 scripts/bench_hello_ab.py BEFORE_BIN AFTER_BIN --name hello_zstd_ab

The HTTP layer's own row (docs/BENCHMARKS.md's `apps/hello`) is the
figure a change to the loop's per-request or per-pass path could move, and
a change that adds a branch to every drain and every finished response
must show it did not. Across sessions an identical binary moves ~1.5x on
this machine, so the old artifact is no baseline: the two builds run here,
alternating (ABBA, so a drift across the run lands on both), each a fresh
server on the same fixed port under `wrk -t2 -cC -dS` after a 2 s warm-up,
with keep-alive throughout.

Cores are the server's CPU seconds over the window's wall seconds, from
`ps -o cputime` before and after (the server is one process). The machine
is refused while anything else is busy (`bench_guard.py`), checked before
every round. Writes `bench/results/<name>-*.json` through bench_record:
per row its rps, cores and wrk's p50 and p99; `comparisons` holds the
after/before ratio of each, the median over rounds.
"""

import argparse
import re
import statistics
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from bench_record import write_artifact  # noqa: E402

PORT = 8080
URL = f"http://127.0.0.1:{PORT}/"
_UNIT = {"us": 1.0, "ms": 1000.0, "s": 1_000_000.0}


def fail(msg):
    sys.exit(f"bench_hello_ab FAIL: {msg}")


def cputime_s(pid):
    """`ps -o cputime` as seconds: [[dd-]hh:]mm:ss.cc."""
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        fail(f"no process {pid}")
    days, _, rest = out.rpartition("-")
    parts = [float(x) for x in rest.split(":")]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return secs + (int(days) * 86400 if days else 0)


def latency_us(text, label):
    m = re.search(rf"^\s+{label}\s+([\d.]+)(us|ms|s)\s*$", text, re.M)
    return round(float(m.group(1)) * _UNIT[m.group(2)], 1) if m else None


def measure(binary, conns, secs):
    proc = subprocess.Popen([binary], env={"M0_PORT": str(PORT), "PATH": "/usr/bin:/bin"},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 15
        while True:
            try:
                urllib.request.urlopen(URL, timeout=1).read()
                break
            except OSError:
                if proc.poll() is not None or time.monotonic() > deadline:
                    fail(f"{binary} never answered on {URL}")
                time.sleep(0.1)
        subprocess.run(["wrk", "-t2", f"-c{conns}", "-d2s", URL], capture_output=True)
        c0, t0 = cputime_s(proc.pid), time.monotonic()
        out = subprocess.run(["wrk", "-t2", f"-c{conns}", f"-d{secs}s", "--latency", URL],
                             capture_output=True, text=True).stdout
        c1, t1 = cputime_s(proc.pid), time.monotonic()
        m = re.search(r"Requests/sec:\s+([\d.]+)", out)
        if not m or "Socket errors" in out:
            fail(f"wrk did not measure cleanly:\n{out}")
        return {"rps": float(m.group(1)), "cores": round((c1 - c0) / (t1 - t0), 3),
                "p50_us": latency_us(out, "50%"), "p99_us": latency_us(out, "99%")}
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        time.sleep(1.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--rounds", type=int, default=4)
    ap.add_argument("--secs", type=int, default=10)
    ap.add_argument("--conns", type=int, default=16)
    ap.add_argument("--name", default="hello_ab")
    ap.add_argument("--subject", default="", help="what the two builds are, for the artifact")
    args = ap.parse_args()
    for b in (args.before, args.after):
        if not Path(b).is_file():
            fail(f"no binary at {b}")
    rows = []
    for rnd in range(1, args.rounds + 1):
        guard = subprocess.run([sys.executable, str(REPO / "scripts" / "bench_guard.py"), "wait",
                                "--threshold", "50", "--samples", "3", "--timeout", "120"])
        if guard.returncode != 0:
            fail("refusing to record on a busy machine; no artifact is written")
        order = [("before", args.before), ("after", args.after)]
        if rnd % 2 == 0:
            order.reverse()
        for label, binary in order:
            r = {"round": rnd, "name": f"hello {label}", **measure(binary, args.conns, args.secs)}
            r["rps_per_core"] = round(r["rps"] / max(r["cores"], 0.01))
            rows.append(r)
            print(f"  r{rnd} {r['name']:<13} rps {r['rps']:>10,.0f} cores {r['cores']:.2f} "
                  f"p50 {r['p50_us']}us p99 {r['p99_us']}us", flush=True)
    ratios = {"rps": [], "cores": [], "rps_per_core": [], "p50_us": [], "p99_us": []}
    for rnd in range(1, args.rounds + 1):
        b = next(r for r in rows if r["round"] == rnd and r["name"] == "hello before")
        a = next(r for r in rows if r["round"] == rnd and r["name"] == "hello after")
        for k in ratios:
            if a.get(k) and b.get(k):
                ratios[k].append(a[k] / b[k])
    comparisons = {"definition": "after / before, each round's own ratio, then the median and the range",
                   **{k: {"median": round(statistics.median(v), 3), "min": round(min(v), 3),
                          "max": round(max(v), 3)} for k, v in ratios.items() if v}}
    for k, v in comparisons.items():
        if k != "definition":
            print(f"  after/before {k:<13} {v['median']}x ({v['min']}-{v['max']})")
    write_artifact(args.name, rows, {
        "before": args.before, "after": args.after, "subject": args.subject,
        "wrk": f"-t2 -c{args.conns} -d{args.secs}s after a 2s warm-up", "rounds": str(args.rounds),
        "order": "ABBA: before first in odd rounds, after first in even",
    }, extra={"comparisons": comparisons})


if __name__ == "__main__":
    main()
