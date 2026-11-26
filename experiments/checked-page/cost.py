#!/usr/bin/env python3
"""Workload 4: what the check costs, main against the branch.

    cost.py WORKDIR BINARY_MAIN BINARY_C [--writes 1000] [--rounds 2]

One loop, no pool threads, 10,000 rows. For each of the same seeded 1,000
writes (a stamped title update to a first-page row, by another process):
  after   GET /notes just after the write (the page is checked and rendered)
  idle    GET /notes again, the clock unmoved
  delta   GET /notes/changes?since=head-1
  write   the stamped update itself and its commit, by the writer (CPython)
Times are client-side round trips over loopback, so they carry the HTTP
cost; the difference between arms is the point. Arms alternate by round.
"""
import argparse
import http.client
import os
import random
import signal
import socket
import sqlite3
import statistics
import subprocess
import sys
import time

ROWS = 10_000


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(binary, db, log):
    port = free_port()
    env = dict(os.environ, M0_PORT=str(port), M0_DB=db, OS_ACTIVITY_MODE="disable")
    env.pop("M0_THREADS", None)
    env.pop("M0_BLOCKING_THREADS", None)
    proc = subprocess.Popen([binary], env=env, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                c.close()
                return proc, port
        except OSError:
            time.sleep(0.05)
    raise SystemExit("no server")


def timed(conn, path):
    t = time.perf_counter_ns()
    conn.request("GET", path)
    r = conn.getresponse()
    body = r.read()
    dt = (time.perf_counter_ns() - t) / 1000
    assert r.status == 200, (path, r.status)
    return dt, body


def one_arm(binary, workdir, name, writes, seed):
    d = os.path.join(workdir, f"cost-{name}-{seed}")
    os.makedirs(d, exist_ok=True)
    db = os.path.join(d, "notes.db")
    for s in ("", "-wal", "-shm"):
        if os.path.exists(db + s):
            os.remove(db + s)
    proc, port = start(binary, db, os.path.join(d, "server.log"))
    con = sqlite3.connect(db, timeout=30, isolation_level=None)
    con.execute("BEGIN")
    for i in range(ROWS):
        con.execute("INSERT INTO notes (title, body) VALUES (?, '')", (f"note {i:05d}",))
    con.execute("COMMIT")
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    ids = [r[0] for r in con.execute("SELECT id FROM notes ORDER BY id LIMIT 50")]
    rng = random.Random(seed)
    for _ in range(50):  # warm
        timed(conn, "/notes")
    after, idle, delta, write = [], [], [], []
    for i in range(writes):
        t = time.perf_counter_ns()
        con.execute("UPDATE notes SET title = ? WHERE id = ?", (f"w{i:06d}", rng.choice(ids)))
        write.append((time.perf_counter_ns() - t) / 1000)
        head = con.execute("SELECT seq FROM m0_stamp").fetchone()[0]
        a, body = timed(conn, "/notes")
        assert f"w{i:06d}".encode() in body, "the page missed the write"
        b, _ = timed(conn, "/notes")
        c, _ = timed(conn, f"/notes/changes?since={head - 1}")
        after.append(a)
        idle.append(b)
        delta.append(c)
    conn.close()
    con.close()
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=10)
    raises = sum(1 for line in open(os.path.join(d, "server.log")) if "raised the floor" in line)
    return after, idle, delta, write, raises


def q(xs):
    xs = sorted(xs)
    return statistics.median(xs), xs[int(len(xs) * 0.9)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workdir")
    ap.add_argument("main_bin")
    ap.add_argument("c_bin")
    ap.add_argument("--writes", type=int, default=1000)
    ap.add_argument("--rounds", type=int, default=2)
    a = ap.parse_args()
    print(f"# cost: {ROWS} rows, {a.writes} writes, one loop; sqlite {sqlite3.sqlite_version}, python {sys.version.split()[0]}")
    print("# arm  round  after p50/p90 us   idle p50/p90 us   delta p50/p90 us   write p50/p90 us   raises")
    for rnd in range(a.rounds):
        order = [("main", a.main_bin), ("C", a.c_bin)]
        if rnd % 2:
            order.reverse()
        for name, b in order:
            after, idle, delta, write, raises = one_arm(b, a.workdir, name, a.writes, 1)
            print("  %-4s %5d   %7.1f / %7.1f   %7.1f / %7.1f   %7.1f / %7.1f   %7.1f / %7.1f   %d" % (
                (name, rnd) + q(after) + q(idle) + q(delta) + q(write) + (raises,)), flush=True)


if __name__ == "__main__":
    main()
