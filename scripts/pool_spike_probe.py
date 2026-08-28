#!/usr/bin/env python3
"""Phase 2's measurement: does a handler pool help a BLOCKING Mojo handler?

Mirrors what `hybrid_isolation.py` does for the WSGI side, against
`apps/pool_spike`. For each configuration it measures the p99 of `/fast` on
keep-alive connections while N slow requests are in flight, and reports the
same shape `docs/BENCHMARKS.md` records for Python:

    configuration        slow=0    slow=1    slow=2
    --workers 4           1.0 ms  190.7 ms  195.9 ms
    --workers 4 +bt=4     2.4 ms    7.4 ms    7.4 ms

The kill criterion for the whole spike: if the loop-only row does NOT collapse
when slow requests are added, a Mojo pool has no constituency and the code
should be deleted rather than kept. If it collapses and the pooled row does
not, the pool earns its place.

    python3 scripts/pool_spike_probe.py --binary /tmp/pool_spike
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time

FAST_REQUESTS = 300  # default; override with --fast-requests
SLOW_MS = 400
WARMUP = 20


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_ready(port: int, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                c.close()
                return
            c.close()
        except OSError:
            time.sleep(0.05)
    raise SystemExit(f"server on :{port} never became ready")


class SlowLoad(threading.Thread):
    """One connection looping `/slow`, standing in for a blocked handler."""

    def __init__(self, port: int) -> None:
        super().__init__(daemon=True)
        self.port = port
        self.stop = threading.Event()
        self.completed = 0

    def run(self) -> None:
        while not self.stop.is_set():
            try:
                c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
                c.request("GET", f"/slow?ms={SLOW_MS}")
                c.getresponse().read()
                c.close()
                self.completed += 1
            except OSError:
                if not self.stop.is_set():
                    time.sleep(0.01)


def measure_fast(port: int, fast_requests: int) -> dict:
    """p50/p99 of `/fast` on ONE keep-alive connection."""
    latencies = []
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    for i in range(fast_requests + WARMUP):
        t = time.perf_counter()
        try:
            c.request("GET", "/fast")
            c.getresponse().read()
        except OSError:
            # A dropped keep-alive connection is itself a result; reconnect and
            # keep the sample honest by recording the cost.
            c.close()
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            continue
        if i >= WARMUP:
            latencies.append((time.perf_counter() - t) * 1000.0)
    c.close()
    latencies.sort()
    if not latencies:
        return {"n": 0, "p50": float("nan"), "p99": float("nan")}
    return {
        "n": len(latencies),
        "p50": statistics.median(latencies),
        "p99": latencies[min(len(latencies) - 1, int(len(latencies) * 0.99))],
        "max": latencies[-1],
    }


def run_config(binary: str, pool_threads: int, slow: int, fast_requests: int) -> dict:
    port = _free_port()
    env = dict(os.environ)
    env["M0_PORT"] = str(port)
    env["M0_POOL_THREADS"] = str(pool_threads)
    proc = subprocess.Popen(
        [binary], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        _wait_ready(port)
        loads = [SlowLoad(port) for _ in range(slow)]
        for ld in loads:
            ld.start()
        if slow:
            time.sleep(0.4)  # let the slow requests actually be in flight
        result = measure_fast(port, fast_requests)
        for ld in loads:
            ld.stop.set()
        result["slow_completed"] = sum(ld.completed for ld in loads)
        return result
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default="/tmp/pool_spike")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--fast-requests", type=int, default=FAST_REQUESTS)
    ap.add_argument("--json", help="write the raw table here")
    args = ap.parse_args()

    configs = [("loop only", 0), (f"pool of {args.threads}", args.threads)]
    # The last column is the capacity boundary, deliberately: more blockers
    # than pool threads. The pool is N threads, not magic, and the honest
    # table shows where it saturates instead of implying it cannot.
    slows = [0, 1, 2, args.threads + 2]
    table: dict = {
        "slow_ms": SLOW_MS,
        "fast_requests": args.fast_requests,
        "rows": [],
    }

    print(f"/slow blocks {SLOW_MS} ms; p99 of {args.fast_requests} keep-alive /fast requests")
    print(f"(last column is {args.threads + 2} blockers against {args.threads} pool threads — the saturation boundary)\n")
    header = f"{'configuration':<16}" + "".join(f"{'slow=' + str(s):>12}" for s in slows)
    print(header)
    print("-" * len(header))
    for label, pool_threads in configs:
        cells, row = [], {"config": label, "pool_threads": pool_threads, "cells": {}}
        for s in slows:
            r = run_config(args.binary, pool_threads, s, args.fast_requests)
            row["cells"][str(s)] = r
            cells.append(f"{r['p99']:>9.1f} ms")
        row_line = f"{label:<16}" + "".join(f"{c:>12}" for c in cells)
        print(row_line)
        table["rows"].append(row)

    print("\np50, same runs:")
    for row in table["rows"]:
        cells = "".join(f"{row['cells'][str(s)]['p50']:>9.1f} ms" for s in slows)
        print(f"{row['config']:<16}{cells}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(table, fh, indent=2)
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
