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
to `apps/wsgi_bare`. Ports are taken from `--port` upward, one per mode,
and without `--port` from a free run of them.

`--app-bin PATH` measures a Mojo application on the Mojo host instead
(SPEC E22): the binary is started with `M0_PORT` and `M0_WORKERS`, must
answer `/pid` the same way, and has one worker mode, `fork` — the host
refuses `M0_SPAWN_WORKERS`.

    python3 scripts/accept_spread.py --app-bin /tmp/host_check --modes fork

Each server leads a process group of its own and is stopped with it,
`probelib.stop`'s way: SIGTERM, GRACE_S for the drain, then SIGKILL, and
reaped. A server that never listens is stopped the same way before the
probe exits (it used to be left running in its session), and one that
ignores SIGTERM costs GRACE_S rather than the CI job's cap. The per-mode
logs go to a temporary directory, removed however the probe ends.
"""
import argparse
import collections
import os
import socket
import subprocess
import sys
import tempfile
import time

from probelib import NotServing, free_port, phase, stamp, stop, wait_healthy

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# SIGTERM to SIGKILL. The probe has closed every connection before it stops a
# server, so the drain has nothing to wait for; this bounds one that hangs.
GRACE_S = 15.0

# Which phase is running, for the crash handler: a traceback names the call
# that raised, never the phase being proven (scripts/phase_stamp_check.py).
stamp("accept_spread: FAIL")


def start(bin_path, app_dir, port, workers, extra, log, app_bin=None):
    env = None
    if app_bin:
        cmd = [app_bin]
        env = dict(os.environ, M0_PORT=str(port), M0_WORKERS=str(workers))
    else:
        cmd = [bin_path, "bareapp.wsgi", "--app-dir", app_dir, "--port", str(port),
               "--workers", str(workers)] + extra
    p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True, env=env)
    try:
        wait_healthy(("127.0.0.1", port), p, timeout=60)
    except NotServing:
        exited = p.poll()
        stop(p, GRACE_S, group=True)
        if exited is not None:
            raise SystemExit("the server exited %d before it listened" % exited)
        raise SystemExit("the server did not listen on %d within 60 s" % port)
    except BaseException:
        stop(p, GRACE_S, group=True)
        raise
    time.sleep(0.3)  # every worker up, not just the first to accept
    return p


def stop_server(p):
    stop(p, GRACE_S, group=True)
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
    ap.add_argument("--app-bin", default=None,
                    help="a Mojo host application to measure instead of m0serve")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--modes", default="fork,spawn",
                    help="comma-separated: fork, spawn")
    ap.add_argument("--n", type=int, default=32, help="burst and ramp size")
    ap.add_argument("--port", type=int, default=None,
                    help="the first of one port per mode (default: a free run)")
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
    if args.app_bin:
        modes = {"fork": []}
    failed = []
    chosen = [m.strip() for m in args.modes.split(",") if m.strip()]
    port = args.port if args.port is not None else free_port(max(1, len(chosen)))
    with tempfile.TemporaryDirectory(prefix="accept-spread-") as logs:
        for mode in chosen:
            if mode not in modes:
                raise SystemExit("unknown mode %r" % mode)
            log_path = os.path.join(logs, "accept-spread-%s.log" % mode)
            phase("%s: start the server on %d" % (mode, port))
            with open(log_path, "w") as log:
                p = start(args.bin, args.app_dir, port, args.workers,
                          modes[mode] + extra_common, log, args.app_bin)
            try:
                for r in range(args.rounds):
                    phase("%s: round %d of %d" % (mode, r + 1, args.rounds))
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
                # No phase of its own: an exception in flight keeps the
                # round that raised it.
                stop_server(p)
            with open(log_path) as log:
                summary = [ln.strip() for ln in log if ln.startswith("Accept sharing:")
                           and "passed" in ln]
            for ln in summary:
                print("      " + ln)
            handed = sum(int(ln.split("passed ")[1].split()[0]) for ln in summary)
            if args.expect_handoffs and handed == 0:
                failed.append((mode, "no connection was passed between workers"))
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
