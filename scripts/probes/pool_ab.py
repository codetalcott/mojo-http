#!/usr/bin/env python3
"""Arm A against arm B of the handler pool, alternated, on a quiet machine:
the runner for scripts/probes/quiet-machine-ab.md.

usage: uv run --no-sync python scripts/probes/pool_ab.py B [--rounds 5]
                                     [--fast-requests 300] [--out DIR]

B names arm B's binaries: `bin/pool_spike-A` and `bin/m0serve-A` against
`bin/pool_spike-B` and `bin/m0serve-B` (B is the record, LF24 or LF22). Each
round runs both arms, A first, and each arm two measures:

  - the pooled row of `poe probe-pool`: `/fast`'s p50 on a pool of four
    beside 0, 1 and 2 blocked threads (`pool_spike_probe.run_config`);
  - the fair arm of `poe probe-pool-fairness`: five threads, twenty
    connections, a CPU-bound view; `ms_per_request`, `p99_ms`, `long_waits`.

Before every cell, `uptime` and the busiest processes (`ps -Ao pcpu,comm -r`)
are recorded beside it. Everything goes to DIR/pool-ab-B-<UTC>.json
(default `bench/results/pool-ab-<YYYY-MM>/`, a subdirectory, which the
bench renderer does not read), and the summary applies the one rule:

  a measure DIFFERS when the two arms' ranges over the rounds do not
  overlap; B SHOWS when it differs from A in the same direction at slow 1
  and slow 2 (the cells where a parked thread is woken), or in the fair
  arm's ms_per_request.

Under `uv run`, so `bin/m0serve` embeds the venv's Python, not the first one
on a bare PATH.
"""

import argparse
import datetime
import json
import os
import platform
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from pool_spike_probe import run_config  # noqa: E402
from probelib import free_port, server  # noqa: E402

SLOWS = (0, 1, 2)
FAIR = ("ms_per_request", "p99_ms", "long_waits", "long_waits_bound")


def machine():
    """What else was running, recorded beside the cell it preceded."""
    up = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    ps = subprocess.run(["ps", "-Ao", "pcpu,comm", "-r"], capture_output=True, text=True)
    return {"uptime": up, "ps": ps.stdout.splitlines()[:8]}


def pooled(arm, slow, fast_requests):
    got = run_config(os.path.join(ROOT, "bin", "pool_spike-" + arm), 4, slow, fast_requests)
    return {"p50_ms": got["p50"], "p99_ms": got["p99"], "n": got["n"]}


def fair(arm):
    port = free_port()
    argv = [os.path.join(ROOT, "bin", "m0serve-" + arm), "bareapp.wsgi:application",
            "--app-dir", os.path.join(ROOT, "apps", "wsgi_bare"),
            "--port", str(port), "--blocking-threads", "5"]
    with server(argv, "http://127.0.0.1:%d/" % port, cwd=ROOT):
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "pool_fairness_probe.py"),
                              str(port)], capture_output=True, text=True, cwd=ROOT).stdout
    got = {}
    for key in FAIR:
        m = re.search(r"^%s (\S+)$" % key, out, re.M)
        got[key] = float(m.group(1)) if m else None
    got["in_order"] = "pool_fairness_probe: PASS" in out
    return got


def spread(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def differs(a, b):
    """-1 when B's range sits wholly below A's, 1 wholly above, 0 when they
    overlap."""
    if b["max"] < a["min"]:
        return -1
    if b["min"] > a["max"]:
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("b", help="arm B's name: bin/pool_spike-B and bin/m0serve-B")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--fast-requests", type=int, default=300)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    arms = ("A", args.b)
    now = datetime.datetime.now(datetime.timezone.utc)
    out_dir = args.out or os.path.join(ROOT, "bench", "results", "pool-ab-" + now.strftime("%Y-%m"))

    def git(*a):
        return subprocess.run(["git", *a], capture_output=True, text=True, cwd=ROOT).stdout

    record = {
        "b": args.b, "rounds": args.rounds, "fast_requests": args.fast_requests,
        "environment": {"git_sha": git("rev-parse", "HEAD").strip(),
                        "git_dirty": bool(git("status", "--porcelain").strip()),
                        "os": platform.platform(), "machine": platform.machine(),
                        "recorded_utc": now.isoformat()},
        "cells": [],
    }
    for r in range(args.rounds):
        for arm in arms:
            for slow in SLOWS:
                cell = {"round": r + 1, "arm": arm, "measure": "pooled_slow%d" % slow,
                        "machine": machine()}
                cell.update(pooled(arm, slow, args.fast_requests))
                record["cells"].append(cell)
                print("round %d %-5s slow=%d p50 %.4f ms   %s" % (
                    r + 1, arm, slow, cell["p50_ms"], cell["machine"]["uptime"]), flush=True)
            cell = {"round": r + 1, "arm": arm, "measure": "fair", "machine": machine()}
            cell.update(fair(arm))
            record["cells"].append(cell)
            print("round %d %-5s fair ms_per_request %s long_waits %s in_order %s" % (
                r + 1, arm, cell["ms_per_request"], cell["long_waits"], cell["in_order"]),
                flush=True)

    def values(arm, measure, key):
        return [c[key] for c in record["cells"]
                if c["arm"] == arm and c["measure"] == measure and c.get(key) is not None]

    summary, signs = {}, {}
    for measure, key in [("pooled_slow%d" % s, "p50_ms") for s in SLOWS] + [("fair", "ms_per_request")]:
        a, b = spread(values("A", measure, key)), spread(values(args.b, measure, key))
        signs[measure] = differs(a, b)
        summary[measure] = {"key": key, "A": a, args.b: b, "b_vs_a": signs[measure]}
        print("%-14s %-15s A median %.4f (%.4f-%.4f)  %s median %.4f (%.4f-%.4f)  %s" % (
            measure, key, a["median"], a["min"], a["max"], args.b, b["median"], b["min"], b["max"],
            {-1: "B lower", 0: "overlap", 1: "B higher"}[signs[measure]]))
    # The one rule: slow 1 and slow 2 agreeing, or the fair arm.
    woken = signs["pooled_slow1"] if signs["pooled_slow1"] == signs["pooled_slow2"] else 0
    if woken and signs["fair"] and woken != signs["fair"]:
        verdict = "mixed: the woken cells and the fair arm disagree"
    else:
        verdict = {-1: "B faster", 0: "no difference", 1: "B slower"}[woken or signs["fair"]]
    record["summary"] = summary
    record["verdict"] = verdict
    print("verdict:", verdict)

    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "pool-ab-%s-%s.json" % (args.b, now.strftime("%Y%m%dT%H%M%SZ")))
    with open(path, "w") as fh:
        json.dump(record, fh, indent=1)
    print("wrote", os.path.relpath(path, ROOT) if path.startswith(ROOT + os.sep) else path)


if __name__ == "__main__":
    main()
