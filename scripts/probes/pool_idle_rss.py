#!/usr/bin/env python3
"""What a connection slot costs before its first use, with the handler pool
and without: the measure of issue #657 and of the C20 note's figures.

usage: uv run --no-sync python scripts/probes/pool_idle_rss.py
           [--binary bin/m0serve] [--counts 1024,16384,65536] [--threads 8]
           [--rounds 3] [--json PATH] [--max-pool-bytes-per-slot B]
           [--emit TASK] [--no-realtime] [--app SPEC --app-dir DIR]

Each cell is a fresh `m0serve hold_app:application --app-dir scripts/smoke
--realtime --max-connections N --blocking-threads T`, asked its health path
once, left a second to settle, and its resident set read five times, the
median kept. Nothing else connects, so what grows with N is what the server
reserves per slot before a connection arrives -- the tables sized by the
count -- and not a connection's buffers, which are sized on first use.

The doctor, run with the same flags, names the count a loop actually holds:
on macOS the descriptor raise stops at `kern.maxfilesperproc`, so 65536 is
fitted to about 61000 (SPEC C25), and the slope is taken over the fitted
counts, never the asked ones.

Two arms, `--blocking-threads 0` and `--blocking-threads T`, alternated
within each round so a drift across the run lands on both. Per arm and
round the figure is the slope, bytes a slot: the resident set at the
largest count less the smallest, over the counts' difference. The pool's
share is the pooled arm's median slope less the pool-less arm's.

`--no-realtime` drops `--realtime`, under which every handler -- the
loop's and each pool thread's -- sizes its stream registries by the count.

`--max-pool-bytes-per-slot B` makes it a gate: exit 1 when the pool's share
is above B. `--emit TASK` records both slopes and the share through
`scripts/emit.py` (a no-op without `$M0_RESULTS`).

Under `uv run`, so `bin/m0serve` embeds the venv's Python, not the first one
on a bare PATH.
"""

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import probelib  # noqa: E402

APP = ["hold_app:application", "--app-dir", "scripts/smoke"]
"""The application served; `--app SPEC --app-dir DIR` replaces it (an ASGI
app measures the asyncio executor's per-slot state beside the pool's)."""


def fail(msg):
    sys.exit(f"pool_idle_rss FAIL: {msg}")


REALTIME = ["--realtime"]


def flags(count, threads):
    return [
        *REALTIME, "--max-connections", str(count),
        "--blocking-threads", str(threads), "--health-path", "/health",
    ]


def fitted(binary, count, threads):
    """The count the loop holds, as the doctor reports it (C25's fit)."""
    out = subprocess.run(
        [binary, *APP, *flags(count, threads), "--doctor"],
        capture_output=True, text=True, cwd=REPO,
    )
    lines = out.stdout.strip().splitlines()
    if out.returncode != 0 or not lines:
        fail(f"the doctor exited {out.returncode} for {count} slots, "
             f"{threads} threads: {out.stdout[-400:]}{out.stderr[-400:]}")
    report = json.loads(lines[-1])
    got = report["topology"]["blocking_threads"]
    if got != threads:
        fail(f"asked for {threads} pool threads, the doctor reports {got}")
    return report["server"]["max_connections"]


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        fail(f"no process {pid}")
    return int(out)


def measure(binary, count, threads, logdir):
    port = probelib.free_port()
    log = Path(logdir) / f"rss-{threads}-{count}.log"
    argv = [binary, *APP, "--port", str(port), *flags(count, threads)]
    url = f"http://127.0.0.1:{port}/health"
    with probelib.server(argv, url, timeout=60.0, log=log, cwd=REPO) as proc:
        time.sleep(1.0)
        reads = []
        for _ in range(5):
            reads.append(rss_kb(proc.pid))
            time.sleep(0.2)
    return statistics.median(reads)


def slope(points):
    """Bytes a slot between the smallest and largest fitted count."""
    lo = min(points)
    hi = max(points)
    if hi == lo:
        fail("every count fitted to the same slot count; nothing to divide by")
    return (points[hi] - points[lo]) * 1024.0 / (hi - lo)


def emit(task, name, value, limit=None):
    cmd = [sys.executable, str(REPO / "scripts" / "emit.py"), name,
           f"{value:.0f}", "--unit", "B", "--task", task]
    if limit is not None:
        cmd += ["--limit", str(limit)]
    subprocess.run(cmd, check=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default="bin/m0serve")
    ap.add_argument("--counts", default="1024,16384,65536")
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--json", dest="json_path")
    ap.add_argument("--max-pool-bytes-per-slot", type=float)
    ap.add_argument("--emit", dest="emit_task")
    ap.add_argument("--app", help="the application spec to serve (default hold_app:application)")
    ap.add_argument("--app-dir", help="its directory, relative to the repository")
    ap.add_argument("--no-realtime", action="store_true",
                    help="serve without --realtime, whose handler tables are sized by the count")
    args = ap.parse_args()
    if args.no_realtime:
        REALTIME.clear()
    if args.app:
        APP[:] = [args.app, "--app-dir", args.app_dir or "."]

    binary = str((REPO / args.binary).resolve()) if not os.path.isabs(args.binary) else args.binary
    if not os.access(binary, os.X_OK):
        fail(f"no executable at {binary}")
    counts = [int(c) for c in args.counts.split(",")]
    if len(counts) < 2:
        fail("--counts needs at least two counts")
    arms = [0, args.threads]

    fit = {(t, c): fitted(binary, c, t) for t in arms for c in counts}
    load = os.getloadavg()
    print(f"binary {binary}, app {APP[0]}" + ("" if REALTIME else " (without --realtime)"))
    print(f"platform {platform.system()} {platform.machine()}, load {load[0]:.2f} {load[1]:.2f}")
    for t in arms:
        print(f"threads {t}: counts " + ", ".join(
            f"{c}->{fit[(t, c)]}" for c in counts))

    cells = {t: {fit[(t, c)]: [] for c in counts} for t in arms}
    slopes = {t: [] for t in arms}
    with tempfile.TemporaryDirectory(prefix="pool-idle-rss-") as logdir:
        for r in range(args.rounds):
            order = arms if r % 2 == 0 else list(reversed(arms))
            for t in order:
                points = {}
                for c in counts:
                    kb = measure(binary, c, t, logdir)
                    points[fit[(t, c)]] = kb
                    cells[t][fit[(t, c)]].append(kb)
                slopes[t].append(slope(points))
                print(f"round {r + 1} threads {t}: " + ", ".join(
                    f"{n} slots {kb / 1024:.1f} MB" for n, kb in sorted(points.items()))
                    + f"; {slopes[t][-1]:.0f} B a slot")

    per_slot = {t: statistics.median(slopes[t]) for t in arms}
    share = per_slot[args.threads] - per_slot[0]
    print()
    print(f"{'slots':>8}  " + "  ".join(f"{'threads ' + str(t):>12}" for t in arms))
    for c in counts:
        row = [statistics.median(cells[t][fit[(t, c)]]) / 1024 for t in arms]
        print(f"{c:>8}  " + "  ".join(f"{mb:>9.1f} MB" for mb in row))
    for t in arms:
        spread = f"{min(slopes[t]):.0f}-{max(slopes[t]):.0f}"
        print(f"threads {t}: {per_slot[t]:.0f} B a slot (rounds {spread})")
    print(f"the pool's share: {share:.0f} B a slot")

    if args.json_path:
        Path(args.json_path).write_text(json.dumps({
            "binary": binary,
            "platform": f"{platform.system()} {platform.machine()}",
            "loadavg": load,
            "counts": counts,
            "fitted": {str(t): {str(c): fit[(t, c)] for c in counts} for t in arms},
            "rss_kb": {str(t): {str(n): v for n, v in cells[t].items()} for t in arms},
            "bytes_per_slot": {str(t): slopes[t] for t in arms},
            "pool_bytes_per_slot": share,
            "measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }, indent=1) + "\n")

    if args.emit_task:
        emit(args.emit_task, "pool.idle_bytes_per_slot", per_slot[args.threads])
        emit(args.emit_task, "loop.idle_bytes_per_slot", per_slot[0])
        emit(args.emit_task, "pool.idle_share_bytes_per_slot", share,
             args.max_pool_bytes_per_slot)

    if args.max_pool_bytes_per_slot is not None and share > args.max_pool_bytes_per_slot:
        fail(f"the pool reserves {share:.0f} B a slot, above "
             f"{args.max_pool_bytes_per_slot:.0f}")


if __name__ == "__main__":
    main()
