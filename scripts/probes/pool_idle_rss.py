#!/usr/bin/env python3
"""What a connection slot costs before its first use, with the handler pool
and without: the measure of issue #657 and of the C20 note's figures.

usage: uv run --no-sync python scripts/probes/pool_idle_rss.py
           [--binary bin/m0serve] [--counts 1024,16384,65536] [--threads 8]
           [--rounds 3] [--json PATH] [--max-pool-bytes-per-slot B]
           [--emit TASK] [--no-realtime] [--app SPEC --app-dir DIR]
           [--versus-app SPEC --versus-app-dir DIR]
       python3 scripts/probes/pool_idle_rss.py --selftest

Each cell is a fresh `m0serve hold_app:application --app-dir scripts/smoke
--realtime --max-connections N --blocking-threads T`, asked its health path
once, left a second to settle, and its memory read five times, the median
kept: the footprint (`probelib.footprint_kb`: macOS's physical footprint,
VmRSS plus VmSwap on Linux), which a page the system compresses does not
leave. Nothing else connects, so what grows with N is what the server
reserves per slot before a connection arrives -- the tables sized by the
count -- and not a connection's buffers, which are sized on first use.

The doctor, run with the same flags, names the count a loop actually holds:
on macOS the descriptor raise stops at `kern.maxfilesperproc`, so 65536 is
fitted to about 61000 (SPEC C25), and the slope is taken over the fitted
counts, never the asked ones.

Two arms, `--blocking-threads 0` and `--blocking-threads T`, alternated
within each round so a drift across the run lands on both. Each cell's
figure is its LEAST reading over the rounds, and an arm's is the slope,
bytes a slot, between its cells at the largest count and the smallest. The
pool's share is the pooled arm's slope less the pool-less arm's.

The least, not the median, because what moves a start's idle memory only
ever adds to it, in steps the slot count does not set. Each pool thread
compiles the executor shim, which frees about 3.6 MB as it finishes, and
whether the allocator reuses those pages for the next compile is not the
slot count's doing; load makes it likelier that it does not. In 31 rounds
on CI's macOS runner two of the eight-thread arm's cells read 3.4 and
4.2 MB above their medians, and no other cell on either leg moved 0.6 MB;
the runner fits 16384 to about 9950 slots, so one round read 432 B a slot
against a bound of 128. Each start is fresh, so a cell is wrong only when
every start of it jumped. A gate (a bound given) refuses fewer than three
rounds, and a failed one names any cell whose starts spread more than half
a step. A loaded machine can leave a step in every start (on an M4 under 14
spinning processes every one of 30 did), and no count of rounds measures
there. `--selftest` replays readings CI recorded through the estimator.

`--no-realtime` drops `--realtime`, under which every handler -- the
loop's and each pool thread's -- sizes its stream registries by the count.

`--versus-app SPEC --versus-app-dir DIR` compares two applications instead
of two pool sizes, both at `--blocking-threads 0`: the share is `--app`'s
slope less the versus application's. An ASGI application against a WSGI
one is the asyncio executor's share (#682), what a slot costs for being
served by an executor rather than inline.

`--max-pool-bytes-per-slot B` (or `--max-share-bytes-per-slot B`) makes it
a gate: exit 1 when the share is above B. `--emit TASK` records both slopes and the share through
`scripts/emit.py` (a no-op without `$M0_RESULTS`), named `pool.*`, or
`executor.*` with `--versus-app`.

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


def fitted(binary, app, count, threads):
    """The count the loop holds, as the doctor reports it (C25's fit)."""
    out = subprocess.run(
        [binary, *app, *flags(count, threads), "--doctor"],
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


def measure(binary, app, count, threads, logdir):
    port = probelib.free_port()
    log = Path(logdir) / f"idle-{threads}-{count}.log"
    argv = [binary, *app, "--port", str(port), *flags(count, threads)]
    url = f"http://127.0.0.1:{port}/health"
    with probelib.server(argv, url, timeout=60.0, log=log, cwd=REPO) as proc:
        time.sleep(1.0)
        reads = []
        for _ in range(5):
            reads.append(probelib.footprint_kb(proc.pid))
            time.sleep(0.2)
    return statistics.median(reads)


def slope(points):
    """Bytes a slot between the smallest and largest fitted count."""
    lo = min(points)
    hi = max(points)
    if hi == lo:
        fail("every count fitted to the same slot count; nothing to divide by")
    return (points[hi] - points[lo]) * 1024.0 / (hi - lo)


GATE_ROUNDS = 3
"""The fewest rounds a bound is judged on: one start's jump fails a gate on
one (#702's first macOS attempt read 432 B a slot, its rerun 18)."""
COMPILE_MB = 3.6
"""What one start's pool thread can leave resident: a compile of the shim
peaks 4.16 MB above what it keeps (0.56, tracemalloc, CPython 3.14.7)."""


def least(rounds, name):
    """An arm's cells, each its least reading over `rounds`."""
    return {n: min(r[name][n] for r in rounds) for n in rounds[0][name]}


def estimate(rounds, names):
    """Each arm's bytes a slot, and the share (the second arm's less the
    first's), from `rounds`: one {arm name: {slots: KB}} a round."""
    per_slot = {name: slope(least(rounds, name)) for name in names}
    return per_slot, per_slot[names[1]] - per_slot[names[0]]


def unsettled(rounds, names):
    """The cells whose starts spread more than half a compile's step, each
    (arm, slots, MB): where the least may not be the floor."""
    out = []
    for name in names:
        for n in sorted(rounds[0][name]):
            reads = [r[name][n] for r in rounds]
            spread = (max(reads) - min(reads)) / 1024
            if spread > COMPILE_MB / 2:
                out.append((name, n, spread))
    return out


def too_few_rounds(rounds, gating):
    """Why a verdict on this many rounds cannot be believed, or None."""
    if gating and rounds < GATE_ROUNDS:
        return (f"a bound is judged on at least {GATE_ROUNDS} rounds, not {rounds}: "
                "one start's idle memory can jump by a compile's freed pages")
    return None


def emit(task, name, value, limit=None):
    cmd = [sys.executable, str(REPO / "scripts" / "emit.py"), name,
           f"{value:.0f}", "--unit", "B", "--task", task]
    if limit is not None:
        cmd += ["--limit", str(limit)]
    subprocess.run(cmd, check=False)


# Readings from CI's macOS smoke leg, MB as the probe printed them, each
# {arm: {fitted slots: MB}}: the runner fits 16384 to 9960 and 9936.
TYPICAL = {"threads 0": {1024: 33.8, 9960: 43.5}, "threads 8": {1024: 37.0, 9936: 46.9}}
"""Run 44144565659: the pool's share 23 B a slot."""
RERUN = {"threads 0": {1024: 33.9, 9960: 43.8}, "threads 8": {1024: 37.3, 9936: 47.3}}
"""#702's macOS rerun, run 44228142612 attempt 2: 18."""
JUMPED_HIGH = {"threads 0": {1024: 33.8, 9960: 43.8}, "threads 8": {1024: 37.4, 9936: 51.0}}
"""The same commit's first attempt: the pooled arm's 9936 cell 3.7 MB high,
432, a failed gate on code that measured 18 and 25."""
JUMPED_LOW = {"threads 0": {1024: 33.8, 9960: 43.4}, "threads 8": {1024: 40.4, 9936: 46.8}}
"""Run 44124414612: the pooled arm's 1024 cell 3.4 MB high, -379, which
would have hidden a regression of 500 B a slot."""
LOADED_LOW = [29.7, 40.6, 37.2]
"""An M4 under six spinning processes: the eight-thread arm's 1024 cell
over three starts, none of them at its unloaded 25.1."""


def _selftest():
    names = ["threads 0", "threads 8"]

    def kb(*rounds):
        return [{a: {n: mb * 1024 for n, mb in cells.items()} for a, cells in r.items()}
                for r in rounds]

    def plus(r, arm, slots, mb):
        out = {a: dict(cells) for a, cells in r.items()}
        out[arm][slots] += mb
        return out

    def regressed(r, per_slot=200):
        lo, hi = sorted(r["threads 8"])
        return plus(r, "threads 8", hi, per_slot * (hi - lo) / 2**20)

    problems = []

    def expect(label, rounds, passes, bound=128):
        _, share = estimate(kb(*rounds), names)
        if (share <= bound) != passes:
            problems.append(f"{label}: the share read {share:.0f} B a slot against {bound}, "
                            f"wanted it {'within' if passes else 'past'} the bound")

    expect("#702's jumped start beside two others", [JUMPED_HIGH, RERUN, TYPICAL], True)
    expect("two starts of three carrying a compile in the same cell",
           [JUMPED_HIGH, plus(RERUN, "threads 8", 9936, COMPILE_MB), TYPICAL], True)
    expect("a regression of 200 B a slot beside a jumped low cell",
           [regressed(JUMPED_LOW), regressed(TYPICAL), regressed(RERUN)], False)
    expect("a regression of 200 B a slot beside two jumped low cells",
           [regressed(JUMPED_LOW), regressed(plus(TYPICAL, "threads 8", 1024, COMPILE_MB)),
            regressed(RERUN)], False)
    expect("a regression of 200 B a slot, nothing jumped",
           [regressed(TYPICAL), regressed(RERUN), regressed(TYPICAL)], False)
    quiet = kb(TYPICAL, RERUN, TYPICAL)
    if unsettled(quiet, names):
        problems.append(f"quiet starts were called unsettled: {unsettled(quiet, names)}")
    loaded = kb(*[plus(TYPICAL, "threads 8", 1024, mb - TYPICAL["threads 8"][1024])
                  for mb in LOADED_LOW])
    if [(a, n) for a, n, _ in unsettled(loaded, names)] != [("threads 8", 1024)]:
        problems.append(f"a loaded machine's cell was not named: {unsettled(loaded, names)}")
    if too_few_rounds(1, gating=True) is None:
        problems.append("a gate on one round was not refused")
    if too_few_rounds(3, gating=True) is not None:
        problems.append("a gate on three rounds was refused")
    if too_few_rounds(1, gating=False) is not None:
        problems.append("a measurement with no bound, on one round, was refused")
    for p in problems:
        print(f"pool_idle_rss selftest FAIL: {p}")
    if problems:
        sys.exit(1)
    print("pool_idle_rss selftest OK")


def main():
    if "--selftest" in sys.argv[1:]:
        _selftest()
        return
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default="bin/m0serve")
    ap.add_argument("--counts", default="1024,16384,65536")
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--json", dest="json_path")
    ap.add_argument("--max-pool-bytes-per-slot", "--max-share-bytes-per-slot",
                    dest="max_pool_bytes_per_slot", type=float,
                    help="exit 1 when the share is above this many bytes a slot")
    ap.add_argument("--emit", dest="emit_task")
    ap.add_argument("--app", help="the application spec to serve (default hold_app:application)")
    ap.add_argument("--app-dir", help="its directory, relative to the repository")
    ap.add_argument("--no-realtime", action="store_true",
                    help="serve without --realtime, whose handler tables are sized by the count")
    ap.add_argument("--versus-app", help="compare --app with this application, both without a pool")
    ap.add_argument("--versus-app-dir", help="its directory, relative to the repository")
    args = ap.parse_args()
    refusal = too_few_rounds(args.rounds, gating=args.max_pool_bytes_per_slot is not None)
    if refusal:
        ap.error(refusal)
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
    # Each arm: (its name, the application, the pool threads). The share is
    # the second arm's slope less the first's.
    if args.versus_app:
        versus = [args.versus_app, "--app-dir", args.versus_app_dir or "."]
        arms = [(args.versus_app, versus, 0), (APP[0], list(APP), 0)]
        what, emitted = "the executor's share", "executor"
    else:
        arms = [("threads 0", list(APP), 0),
                ("threads %d" % args.threads, list(APP), args.threads)]
        what, emitted = "the pool's share", "pool"
    names = [a[0] for a in arms]

    fit = {(a[0], c): fitted(binary, a[1], c, a[2]) for a in arms for c in counts}
    load = os.getloadavg()
    print(f"binary {binary}, app {APP[0]}" + ("" if REALTIME else " (without --realtime)"))
    print(f"platform {platform.system()} {platform.machine()}, load {load[0]:.2f} {load[1]:.2f}")
    for name in names:
        print(f"{name}: counts " + ", ".join(
            f"{c}->{fit[(name, c)]}" for c in counts))

    cells = {name: {fit[(name, c)]: [] for c in counts} for name in names}
    slopes = {name: [] for name in names}
    rounds = []
    with tempfile.TemporaryDirectory(prefix="pool-idle-rss-") as logdir:
        for r in range(args.rounds):
            rounds.append({})
            order = arms if r % 2 == 0 else list(reversed(arms))
            for name, app, threads in order:
                points = {}
                for c in counts:
                    kb = measure(binary, app, c, threads, logdir)
                    points[fit[(name, c)]] = kb
                    cells[name][fit[(name, c)]].append(kb)
                rounds[-1][name] = points
                slopes[name].append(slope(points))
                print(f"round {r + 1} {name}: " + ", ".join(
                    f"{n} slots {kb / 1024:.1f} MB" for n, kb in sorted(points.items()))
                    + f"; {slopes[name][-1]:.0f} B a slot")

    per_slot, share = estimate(rounds, names)
    print()
    for name in names:
        for n, kb in sorted(least(rounds, name).items()):
            print(f"{name}, {n} slots: least {kb / 1024:.1f} MB of "
                  + ", ".join(f"{v / 1024:.1f}" for v in cells[name][n]))
    for name in names:
        spread = f"{min(slopes[name]):.0f}-{max(slopes[name]):.0f}"
        print(f"{name}: {per_slot[name]:.0f} B a slot (rounds {spread})")
    print(f"{what}: {share:.0f} B a slot")

    if args.json_path:
        Path(args.json_path).write_text(json.dumps({
            "binary": binary,
            "platform": f"{platform.system()} {platform.machine()}",
            "loadavg": load,
            "counts": counts,
            "arms": names,
            "fitted": {name: {str(c): fit[(name, c)] for c in counts} for name in names},
            "footprint_kb": {name: {str(n): v for n, v in cells[name].items()} for name in names},
            "estimator": "each cell's least reading over the rounds, then the slope",
            "bytes_per_slot_by_round": {name: slopes[name] for name in names},
            "bytes_per_slot": per_slot,
            "share_bytes_per_slot": share,
            "measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }, indent=1) + "\n")

    if args.emit_task:
        emit(args.emit_task, emitted + ".idle_bytes_per_slot", per_slot[names[1]])
        emit(args.emit_task, emitted + ".without_idle_bytes_per_slot", per_slot[names[0]])
        emit(args.emit_task, emitted + ".idle_share_bytes_per_slot", share,
             args.max_pool_bytes_per_slot)

    if args.max_pool_bytes_per_slot is not None and share > args.max_pool_bytes_per_slot:
        why = "".join(f"; {name} at {n} slots spread {mb:.1f} MB over its starts"
                      for name, n, mb in unsettled(rounds, names))
        if why:
            why += (f", more than half the {COMPILE_MB} MB a pool thread's shim compile can "
                    "leave, so its least may not be its floor: a machine this busy can leave "
                    "one in every start")
        fail(f"{what} is {share:.0f} B a slot, above "
             f"{args.max_pool_bytes_per_slot:.0f}" + why)


if __name__ == "__main__":
    main()
