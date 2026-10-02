#!/usr/bin/env python3
"""THROWAWAY (never merged): do the host's placement stalls on macOS come
from the pool's timed look (#521, SPEC E37), or from the runner?

Since #521 merged, `smoke-ramp` and `smoke-host-threads` have failed on
macOS runners with one `/health` (or `/x/now`) sample of 24 at 120-190 ms,
on arms where the LOOP answers while pool threads spin in 200 ms views.
Before it, 26 recorded macOS runs were at most 9 ms on those arms. This
runs those arms many times against two builds of `apps/host_check`:

    A   main
    B   main with `OffloadPool.next_look` answering 0: the loop no longer
        waits to a pending job's deadline, and looks once per
        `POOL_WAKE_WAIT_MS` as it did before #521
    C   A's binary with M0_POOL_ELASTIC=0 (the eager wakes)

in two shapes:

    loops2x2   M0_THREADS=2 M0_BLOCKING_THREADS=2, two connections looping
               /slow?ms=200, /health sampled  (smoke-host-threads' arm)
    lane-full  M0_BLOCKING_THREADS=2, the same load, one loop
               (smoke-host's "pool of 2, both busy"; smoke-ramp's shape)

and one more that shows B is what it says, since a patch that did nothing
would make A and B agree for the wrong reason:

    verify     M0_BLOCKING_THREADS=2, ONE connection on /slow, and
               /instance sampled: a fast request that needs a pool thread
               while the other is busy. #521 took its median from about
               1.4 ms to about 0.1 ms, so A must be fast here and B slow.

Every cell gets a fresh server on a free port, cells are interleaved, and
every sample is kept with its connect and request times apart. For a
stalled sample it also says how close its END was to the end of one of the
slow requests: a stall that ends as a view completes was released by that
completion's wake, which is what a missed wake looks like.

    stall_ab.py patch OFFLOAD_MOJO            # turn the timed look off
    stall_ab.py run OUT.json BIN_A BIN_B ROUND_S ROUNDS
"""

from __future__ import annotations

import http.client
import json
import os
import random
import signal
import socket
import subprocess
import sys
import threading
import time

HOST = "127.0.0.1"
STALL_MS = 50.0

ANCHOR = "        if not self.elastic:\n            return 0\n        var best = 0\n"
PATCHED = "        if True:\n            return 0\n        var best = 0\n"


def patch(path: str) -> None:
    src = open(path).read()
    if src.count(ANCHOR) != 1:
        sys.exit("stall_ab: the anchor in next_look matches %d times, not once" % src.count(ANCHOR))
    open(path, "w").write(src.replace(ANCHOR, PATCHED))
    print("stall_ab: next_look now answers 0 in %s" % path)


def free_port() -> int:
    s = socket.socket()
    s.bind((HOST, 0))
    port = s.getsockname()[1]
    s.close()
    return port


def start(binary: str, env_extra: dict) -> tuple:
    port = free_port()
    env = dict(os.environ)
    env.update(env_extra)
    env["M0_PORT"] = str(port)
    env["M0_HOST"] = HOST
    proc = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.monotonic() + 30
    while time.monotonic() < end:
        if proc.poll() is not None:
            raise RuntimeError("%s exited %d before it served" % (binary, proc.returncode))
        try:
            c = http.client.HTTPConnection(HOST, port, timeout=2)
            c.request("GET", "/health")
            ok = c.getresponse().status == 200
            c.close()
            if ok:
                return proc, port
        except OSError:
            time.sleep(0.05)
    proc.kill()
    raise RuntimeError("%s never answered /health" % binary)


def stop(proc) -> None:
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def slow_loop(port: int, until: float, ends: list) -> None:
    conn = http.client.HTTPConnection(HOST, port, timeout=30)
    while time.perf_counter() < until:
        conn.request("GET", "/slow?ms=200")
        conn.getresponse().read()
        ends.append(time.perf_counter())
    conn.close()


def run_cell(binary: str, env_extra: dict, k: int, path: str, seconds: float) -> dict:
    proc, port = start(binary, env_extra)
    try:
        until = time.perf_counter() + seconds
        ends: list = []
        loaders = [threading.Thread(target=slow_loop, args=(port, until, ends), daemon=True)
                   for _ in range(k)]
        for t in loaders:
            t.start()
        time.sleep(0.3)
        samples = []
        while time.perf_counter() < until:
            conn = http.client.HTTPConnection(HOST, port, timeout=30)
            t0 = time.perf_counter()
            conn.connect()
            t1 = time.perf_counter()
            conn.request("GET", path)
            resp = conn.getresponse()
            resp.read()
            t2 = time.perf_counter()
            conn.close()
            if resp.status != 200:
                raise RuntimeError("%s answered HTTP %d" % (path, resp.status))
            samples.append((t2, (t2 - t0) * 1000.0, (t1 - t0) * 1000.0, (t2 - t1) * 1000.0))
            time.sleep(random.uniform(0.01, 0.06))
        for t in loaders:
            t.join(timeout=seconds + 30)
    finally:
        stop(proc)
    stalls = []
    for end, total, connect, request in samples:
        if total >= STALL_MS:
            nearest = min((abs(end - e) for e in ends), default=-1.0)
            stalls.append({"total_ms": round(total, 1), "connect_ms": round(connect, 1),
                           "request_ms": round(request, 1),
                           "ms_from_a_slow_request_ending": round(nearest * 1000.0, 1)})
    return {"totals": [s[1] for s in samples], "stalls": stalls, "slow_requests": len(ends)}


BUILDS = [("A", "a", {}), ("B", "b", {}), ("C", "a", {"M0_POOL_ELASTIC": "0"})]
SHAPES = [
    ("loops2x2", {"M0_THREADS": "2", "M0_BLOCKING_THREADS": "2"}, 2, "/health"),
    ("lane-full", {"M0_BLOCKING_THREADS": "2"}, 2, "/health"),
]
VERIFY = ("verify", {"M0_BLOCKING_THREADS": "2"}, 1, "/instance")


def quantile(sorted_values: list, q: float) -> float:
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * q))]


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "patch":
        patch(sys.argv[2])
        return
    if len(sys.argv) != 7 or sys.argv[1] != "run":
        sys.exit(__doc__)
    out, bins = sys.argv[2], {"a": sys.argv[3], "b": sys.argv[4]}
    round_s, rounds = float(sys.argv[5]), int(sys.argv[6])
    cells: dict = {}

    def add(shape: str, build: str, got: dict) -> None:
        cell = cells.setdefault("%s/%s" % (shape, build), {"totals": [], "stalls": [], "slow_requests": 0})
        cell["totals"] += got["totals"]
        cell["stalls"] += got["stalls"]
        cell["slow_requests"] += got["slow_requests"]

    started = time.monotonic()
    # The check on B first, and again at the end: 8 s a cell.
    for _ in range(2):
        for name, which, extra in BUILDS:
            env = dict(VERIFY[1])
            env.update(extra)
            add(VERIFY[0], name, run_cell(bins[which], env, VERIFY[2], VERIFY[3], 8.0))
    for r in range(rounds):
        order = BUILDS[r % 3:] + BUILDS[:r % 3]
        for shape, shape_env, k, path in SHAPES:
            for name, which, extra in order:
                env = dict(shape_env)
                env.update(extra)
                add(shape, name, run_cell(bins[which], env, k, path, round_s))
        print("round %d of %d done, %.0f s in" % (r + 1, rounds, time.monotonic() - started), flush=True)

    lines = ["| cell | samples | p50 ms | p99 ms | max ms | >= 50 ms | >= 100 ms |",
             "|---|---|---|---|---|---|---|"]
    summary = {}
    for key in sorted(cells):
        totals = sorted(cells[key]["totals"])
        row = {"samples": len(totals), "p50_ms": round(quantile(totals, 0.5), 2),
               "p99_ms": round(quantile(totals, 0.99), 2), "max_ms": round(totals[-1], 1),
               "ge_50": sum(1 for t in totals if t >= 50), "ge_100": sum(1 for t in totals if t >= 100),
               "stalls": cells[key]["stalls"], "slow_requests": cells[key]["slow_requests"]}
        summary[key] = row
        lines.append("| %s | %d | %.2f | %.2f | %.1f | %d | %d |" % (
            key, row["samples"], row["p50_ms"], row["p99_ms"], row["max_ms"], row["ge_50"], row["ge_100"]))
    text = "\n".join(lines)
    print(text)
    for key in sorted(summary):
        for s in summary[key]["stalls"][:40]:
            print("stall %s: total %s ms (connect %s, request %s), %s ms from a slow request ending" % (
                key, s["total_ms"], s["connect_ms"], s["request_ms"], s["ms_from_a_slow_request_ending"]))
    json.dump({"cpus": os.cpu_count(), "platform": sys.platform, "round_s": round_s,
               "rounds": rounds, "cells": summary}, open(out, "w"), indent=1)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as f:
            f.write("### stall_ab on %s, %s CPUs\n\n%s\n" % (sys.platform, os.cpu_count(), text))


main()
