#!/usr/bin/env python3
"""Do `--workers N` share a burst of keep-alive connections? (SPEC E16)

Start `m0serve --workers N` on the bare WSGI app, open a burst of keep-alive
connections, ask `/pid` on each while they are all open, and count how many
landed on each worker. A keep-alive load runs at the throughput of the
workers that hold its connections, so a burst that lands 32 to 0 is a
second worker that adds nothing — measured 2026-09-04 on macOS with two
workers, forked or spawned alike (docs/notes/accept-sharing.md).

Three shapes per worker mode, each a list of per-worker counts, largest
first:

    burst N      N connections opened as fast as `connect()` returns
    ramp N       N connections opened 50 ms apart
    burst 8      the small burst, where one accept per wakeup is the whole
                 story

The pass line is the SPEC row's: the largest share of a burst of N is at
most twice the smallest (`--assert`), for every worker mode tried. A
single worker is exempt (there is nothing to share) and refused as a
pass by construction — the probe demands N >= 2.

    python3 scripts/accept_spread.py                      # print the table
    python3 scripts/accept_spread.py --assert             # the gate
    python3 scripts/accept_spread.py --modes fork --bin ./bin/m0serve

`--bin` defaults to `bin/m0serve` relative to the repository, `--app-dir`
to `apps/wsgi_bare`. Ports are taken from `--port` upward, one per mode.
"""
import argparse
import collections
import os
import signal
import socket
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def start(bin_path, app_dir, port, workers, extra, log):
    cmd = [bin_path, "bareapp.wsgi", "--app-dir", app_dir, "--port", str(port),
           "--workers", str(workers)] + extra
    p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < 60:
        if p.poll() is not None:
            raise SystemExit("m0serve exited %d before it listened" % p.returncode)
        try:
            socket.create_connection(("127.0.0.1", port), 1).close()
            break
        except OSError:
            time.sleep(0.02)
    else:
        raise SystemExit("m0serve did not listen on %d within 60 s" % port)
    time.sleep(0.3)  # every worker up, not just the first to accept
    return p


def stop(p):
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    p.wait()
    time.sleep(0.3)


def pid_over(conn):
    conn.sendall(b"GET /pid HTTP/1.1\r\nHost: x\r\n\r\n")
    data = b""
    while True:
        head, sep, body = data.partition(b"\r\n\r\n")
        if sep:
            length = 0
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1])
            if len(body) >= length:
                return body[:length].decode()
        chunk = conn.recv(4096)
        if not chunk:
            raise SystemExit("connection closed before /pid answered")
        data += chunk


def spread(port, n, gap):
    """Open `n` keep-alive connections `gap` s apart, then ask each for
    its worker's pid while all are open. Returns per-worker counts,
    largest first."""
    conns = []
    for _ in range(n):
        conns.append(socket.create_connection(("127.0.0.1", port), 5))
        if gap:
            time.sleep(gap)
    counts = collections.Counter(pid_over(c) for c in conns)
    for c in conns:
        c.close()
    return sorted(counts.values(), reverse=True)


def within(counts, ratio, workers):
    """True when every worker took a share and the largest is at most
    `ratio` times the smallest."""
    if len(counts) < workers:
        return False
    return counts[0] <= ratio * counts[-1]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bin", default=os.path.join(REPO, "bin", "m0serve"))
    ap.add_argument("--app-dir", default=os.path.join(REPO, "apps", "wsgi_bare"))
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--modes", default="fork,spawn",
                    help="comma-separated: fork, spawn")
    ap.add_argument("--n", type=int, default=32, help="burst and ramp size")
    ap.add_argument("--port", type=int, default=8621)
    ap.add_argument("--ratio", type=float, default=2.0,
                    help="largest share may be at most this times the smallest")
    ap.add_argument("--assert", dest="assert_", action="store_true",
                    help="exit 1 unless every mode's burst is within --ratio")
    ap.add_argument("--rounds", type=int, default=1,
                    help="repeat the three shapes this many times per mode")
    ap.add_argument("--extra", default="",
                    help="extra m0serve arguments, space-separated")
    ap.add_argument("--expect-handoffs", action="store_true",
                    help="with --assert: each server's shutdown must report "
                         "at least one connection passed between workers, "
                         "so a balanced split is the mechanism, not luck")
    args = ap.parse_args()
    if args.workers < 2:
        raise SystemExit("--workers must be >= 2: one worker has nothing to share")
    extra_common = args.extra.split() if args.extra else []
    modes = {"fork": [], "spawn": ["--spawn-workers"]}
    failed = []
    port = args.port
    for mode in [m.strip() for m in args.modes.split(",") if m.strip()]:
        if mode not in modes:
            raise SystemExit("unknown mode %r" % mode)
        log_path = "accept-spread-%s.log" % mode
        with open(log_path, "w") as log:
            p = start(args.bin, args.app_dir, port, args.workers,
                      modes[mode] + extra_common, log)
        try:
            for r in range(args.rounds):
                burst = spread(port, args.n, 0)
                ramp = spread(port, args.n, 0.05)
                small = spread(port, 8, 0)
                ok = within(burst, args.ratio, args.workers)
                print("%-5s burst %d: %-12s ramp %d @50ms: %-12s burst 8: %-10s %s"
                      % (mode, args.n, burst, args.n, ramp, small,
                         "ok" if ok else "SKEWED"), flush=True)
                if not ok:
                    failed.append((mode, burst))
        finally:
            stop(p)
        with open(log_path) as log:
            summary = [ln.strip() for ln in log if ln.startswith("Accept sharing:")
                       and "passed" in ln]
        for ln in summary:
            print("      " + ln)
        handed = sum(int(ln.split("passed ")[1].split()[0]) for ln in summary)
        if args.expect_handoffs and handed == 0:
            failed.append((mode, "no connection was passed between workers"))
        try:
            os.unlink(log_path)
        except OSError:
            pass
        port += 1
    if args.assert_ and failed:
        for mode, burst in failed:
            if isinstance(burst, str):
                print("accept_spread: %s: %s" % (mode, burst))
            else:
                print("accept_spread: %s burst of %d landed %s, outside %g:1"
                      % (mode, args.n, burst, args.ratio))
        sys.exit(1)
    if args.assert_:
        print("accept_spread: every burst of %d within %g:1 across %d workers"
              % (args.n, args.ratio, args.workers))


if __name__ == "__main__":
    main()
