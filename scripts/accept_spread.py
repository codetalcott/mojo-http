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

`--unstarted-gap MS` measures the other half of the rule instead: that a
worker whose loop has not started is handed nothing (review AR). It
starts `m0serve --workers 2` with `M0_TEST_ARM_GAP_MS` holding worker 1
that long after its fork, before its loop starts, and inside the hold
opens a burst of keep-alive connections to worker 0 and asks `/pid` on
each at once. Every answer must come from worker 0, promptly, and at
shutdown worker 0 must report no connection passed. Handed to the held
worker, each answer waited out the hold, and a stop inside it closed them
all unanswered.

    python3 scripts/accept_spread.py --unstarted-gap 3000

`--reaped` measures the third: that a worker the supervisor reaps and does
not replace is handed nothing (review RP). It starts `--workers 2`, kills
worker 1 with SIGKILL once its loop has started -- parked, idle -- and
again as each replacement's loop starts, until the supervisor stops
respawning it (five deaths inside a second of their fork, or the respawn
budget), then opens a burst of keep-alive connections and asks `/pid` on
each at once. Every one must be answered, by worker 0. Before the
supervisor marked the index, the dead worker's page still read parked
with no load, and `pick` handed it about half of every burst, each into a
channel nothing would read again: accepted, and never answered. SIGKILL
because it is the death that leaves the page as the worker last wrote it
and writes no crash report; one mode per `--modes` entry, `--app-bin`
included.

`--reaped` then measures what was handed to such a worker BEFORE it died
(review RB), on a second server per mode, on a free port of its own, with
`M0_TEST_MAX_RESPAWNS=0` so the supervisor gives up on the first death. It
stops worker 1 with SIGSTOP once its loop has started, parked, sends a
burst of keep-alive `/pid` requests, and waits `--queued-wait` for worker
0's answers: what worker 0 handed to the stopped worker is left queued in
that worker's channel. Then it kills worker 1 with SIGKILL, and every
queued connection must read a close, EOF or a reset, within
`--queued-wait` of the kill, so its client can retry. Before the
supervisor closed them, each stayed open and unanswered until the server
stopped. A burst that queued nothing is a failure, the measurement having
measured nothing.

    python3 scripts/accept_spread.py --reaped --modes fork,spawn

Every server is measured once all its workers have started, which each
announces with its `Accept sharing: worker I of N` line: a worker that
has not started is handed nothing, so a burst sent before then measures
the startup, not the spread.

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
import re
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time

import threading

from probelib import NotServing, free_port, phase, stamp, stop, wait_healthy

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# SIGTERM to SIGKILL. The probe has closed every connection before it stops a
# server, so the drain has nothing to wait for; this bounds one that hangs.
GRACE_S = 15.0

# Which phase is running, for the crash handler: a traceback names the call
# that raised, never the phase being proven (scripts/phase_stamp_check.py).
stamp("accept_spread: FAIL")

STARTED = "Accept sharing: worker %d of %d passes"
"""What `prepare_loop` prints once a worker's loop has started."""

GAVE_UP = ("reached, not respawning", "rapid crashes detected, stopping respawn")
"""What the supervisor prints when it stops respawning (`_try_respawn`)."""

INCARNATION = re.compile(r"^\[worker (?:respawn )?(\d+)\] pid=(\d+) starting", re.M)
"""The line each worker prints as it is forked, first or respawned."""


def started_workers(log_path, workers):
    """How many of `workers` have printed their loop's start line."""
    with open(log_path, errors="replace") as log:
        text = log.read()
    return sum(1 for i in range(workers) if STARTED % (i, workers) in text)


def wait_started(p, log_path, workers, timeout=60):
    """Until every worker's loop has started, or fail naming how many had.

    Under `M0_ACCEPT_SHARE=0` (the negative arm) no worker prints the line,
    and nothing is handed to one that has not started because nothing is
    handed at all: a pause stands in, as it did for every mode before."""
    if os.environ.get("M0_ACCEPT_SHARE") == "0":
        time.sleep(0.3)
        return
    deadline = time.monotonic() + timeout
    while started_workers(log_path, workers) < workers:
        if p.poll() is not None or time.monotonic() > deadline:
            stop(p, GRACE_S, group=True)
            raise SystemExit("%d of %d workers started their loops"
                             % (started_workers(log_path, workers), workers))
        time.sleep(0.05)


def start(bin_path, app_dir, port, workers, extra, log, app_bin=None,
          env_extra=None, target=None):
    """Start the server and return it once it listens (`target`, a URL,
    once that answers). The caller waits for the workers it needs."""
    env = dict(os.environ, **(env_extra or {}))
    if app_bin:
        cmd = [app_bin]
        env.update(M0_PORT=str(port), M0_WORKERS=str(workers))
    else:
        cmd = [bin_path, "bareapp.wsgi", "--app-dir", app_dir, "--port", str(port),
               "--workers", str(workers)] + extra
    p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True, env=env)
    try:
        wait_healthy(target or ("127.0.0.1", port), p, timeout=60)
    except NotServing:
        exited = p.poll()
        stop(p, GRACE_S, group=True)
        if exited is not None:
            raise SystemExit("the server exited %d before it listened" % exited)
        raise SystemExit("the server did not listen on %d within 60 s" % port)
    except BaseException:
        stop(p, GRACE_S, group=True)
        raise
    return p


def stop_server(p):
    stop(p, GRACE_S, group=True)
    time.sleep(0.3)


def pid_over(conn, send=True):
    if send:
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


def unstarted(args, logs):
    """The `--unstarted-gap` measurement: nothing is handed to a worker
    whose loop has not started. Returns a list of failures."""
    port = args.port if args.port is not None else free_port()
    gap_ms = args.unstarted_gap
    log_path = os.path.join(logs, "accept-unstarted.log")
    phase("unstarted: start the server with worker 1 held %d ms" % gap_ms)
    with open(log_path, "w") as log:
        p = start(args.bin, args.app_dir, port, 2, [], log,
                  env_extra={"M0_TEST_ARM_GAP_MS": str(gap_ms)},
                  target="http://127.0.0.1:%d/pid" % port)
    failed = []
    try:
        if started_workers(log_path, 2) != 1:
            stop(p, GRACE_S, group=True)
            raise SystemExit("worker 1 was not held unstarted (%d of 2 loops "
                             "started): M0_TEST_ARM_GAP_MS did not take, and "
                             "this phase would prove nothing" % started_workers(log_path, 2))
        phase("unstarted: a burst of %d while worker 1 is held" % args.n)
        conns = [socket.create_connection(("127.0.0.1", port), 5) for _ in range(args.n)]
        began = time.monotonic()
        for c in conns:
            c.sendall(b"GET /pid HTTP/1.1\r\nHost: x\r\n\r\n")
        # Every request is in while worker 1 is still held, or the phase
        # measures nothing.
        held = started_workers(log_path, 2) == 1
        answers = [None] * len(conns)

        def ask(i):
            conns[i].settimeout(gap_ms / 1000.0 + 10)
            try:
                who = pid_over(conns[i], send=False)
            except (OSError, SystemExit) as exc:
                who = "no answer (%s)" % exc
            answers[i] = (who, time.monotonic() - began)

        askers = [threading.Thread(target=ask, args=(i,)) for i in range(len(conns))]
        for t in askers:
            t.start()
        for t in askers:
            t.join()
        for c in conns:
            c.close()
        pids = sorted({who for who, _ in answers})
        slowest = max(took for _, took in answers)
        print("unstarted: burst %d inside a %d ms hold: answered by %s, slowest %.3f s"
              % (args.n, gap_ms, pids, slowest), flush=True)
        if not held:
            failed.append(("unstarted", "worker 1 started before the burst was "
                           "sent, so it measured nothing: lengthen --unstarted-gap"))
        if len(pids) != 1 or slowest > args.unstarted_bound:
            failed.append(("unstarted", "connections went to the worker that had "
                           "not started: answered by %s, slowest %.3f s (bound %g s)"
                           % (pids, slowest, args.unstarted_bound)))
        phase("unstarted: worker 1 starts, and the server stops")
        wait_started(p, log_path, 2, timeout=gap_ms / 1000.0 + 60)
    finally:
        stop_server(p)
    with open(log_path) as log:
        text = log.read()
    passed = [ln for ln in text.splitlines()
              if ln.startswith("Accept sharing: worker 0 passed ")]
    print("      " + (passed[0].strip() if passed else "(worker 0 printed no summary)"))
    if not passed or not passed[0].startswith("Accept sharing: worker 0 passed 0 "):
        failed.append(("unstarted", "worker 0 did not report passing nothing "
                       "while its sibling was held"))
    return failed


def read_log(log_path):
    with open(log_path, errors="replace") as log:
        return log.read()


def incarnations(text, index):
    """The pids worker `index` has run as, in order, from the server's log."""
    return [int(m.group(2)) for m in INCARNATION.finditer(text)
            if int(m.group(1)) == index]


def kill_until_not_respawned(p, log_path, name):
    """SIGKILL worker 1 each time its loop has started, until the supervisor
    says it will not respawn it. Returns the pids killed.

    Only a pid the log names for index 1, never one already killed, and
    only while it is still in the server's process group: a number the
    kernel handed on since is not ours to signal."""
    killed = []
    deadline = time.monotonic() + 90
    while True:
        text = read_log(log_path)
        if any(g in text for g in GAVE_UP):
            return killed
        if p.poll() is not None:
            raise SystemExit("%s: the server exited %d while worker 1 was "
                             "being killed" % (name, p.returncode))
        if time.monotonic() > deadline or len(killed) > 40:
            raise SystemExit("%s: the supervisor was still respawning worker 1 "
                             "after %d deaths" % (name, len(killed)))
        pids = incarnations(text, 1)
        loops = text.count(STARTED % (1, 2))
        if not pids or pids[-1] in killed or loops < len(pids):
            time.sleep(0.01)
            continue
        try:
            if os.getpgid(pids[-1]) != p.pid:
                raise SystemExit("%s: pid %d is not in the server's group"
                                 % (name, pids[-1]))
            os.kill(pids[-1], signal.SIGKILL)
        except ProcessLookupError:
            pass
        killed.append(pids[-1])


def reaped(args, logs, mode, extra, port):
    """The `--reaped` measurement for one worker mode: a worker the
    supervisor reaps and does not replace is handed nothing. Returns a
    list of failures."""
    name = "reaped " + mode
    log_path = os.path.join(logs, "accept-reaped-%s.log" % mode)
    phase("%s: start the server on %d" % (name, port))
    with open(log_path, "w") as log:
        p = start(args.bin, args.app_dir, port, 2, extra, log, args.app_bin)
    failed = []
    try:
        wait_started(p, log_path, 2)
        phase("%s: kill worker 1 until the supervisor stops respawning it" % name)
        killed = kill_until_not_respawned(p, log_path, name)
        # Each death was after its loop's start line, with nothing sent to
        # the server, so the last one left its page parked with no load.
        text = read_log(log_path)
        worker0 = incarnations(text, 0)
        if len(worker0) != 1:
            raise SystemExit("%s: worker 0 did not stay one process: %s"
                             % (name, worker0))
        phase("%s: a burst of %d with worker 1 gone" % (name, args.n))
        conns = [socket.create_connection(("127.0.0.1", port), 5)
                 for _ in range(args.n)]
        began = time.monotonic()
        for c in conns:
            c.sendall(b"GET /pid HTTP/1.1\r\nHost: x\r\n\r\n")
        answers = [None] * len(conns)

        def ask(i):
            conns[i].settimeout(args.reaped_wait)
            try:
                who = pid_over(conns[i], send=False)
            except (OSError, SystemExit):
                who = None
            answers[i] = (who, time.monotonic() - began)

        askers = [threading.Thread(target=ask, args=(i,)) for i in range(len(conns))]
        for t in askers:
            t.start()
        for t in askers:
            t.join()
        for c in conns:
            c.close()
        unanswered = sum(1 for who, _ in answers if who is None)
        pids = sorted({who for who, _ in answers if who is not None})
        print("%s: worker 1 killed %d times, then not respawned; burst %d: "
              "%d answered by %s, %d unanswered within %g s"
              % (name, len(killed), args.n, args.n - unanswered, pids,
                 unanswered, args.reaped_wait), flush=True)
        if unanswered or pids != [str(worker0[0])]:
            failed.append((name, "%d of %d connections were never answered "
                           "(answered by %s; worker 0 is %d): they went to the "
                           "worker the supervisor had reaped"
                           % (unanswered, args.n, pids, worker0[0])))
    finally:
        stop_server(p)
    passed = [ln.strip() for ln in read_log(log_path).splitlines()
              if ln.startswith("Accept sharing: worker 0 passed ")]
    print("      " + (passed[0] if passed else "(worker 0 printed no summary)"))
    return failed


def queued(args, logs, mode, extra):
    """The `--reaped` measurement's second half for one worker mode: what
    was handed to a worker before it died, and was never received, is
    closed once the supervisor gives up on it (review RB). Returns a list
    of failures."""
    name = "queued " + mode
    port = free_port()
    log_path = os.path.join(logs, "accept-queued-%s.log" % mode)
    phase("%s: start the server on %d, no respawns allowed" % (name, port))
    with open(log_path, "w") as log:
        p = start(args.bin, args.app_dir, port, 2, extra, log, args.app_bin,
                  env_extra={"M0_TEST_MAX_RESPAWNS": "0"})
    failed = []
    victim = None
    conns = []
    try:
        wait_started(p, log_path, 2)
        text = read_log(log_path)
        victim = incarnations(text, 1)[-1]
        worker0 = incarnations(text, 0)[-1]
        if os.getpgid(victim) != p.pid:
            raise SystemExit("%s: pid %d is not in the server's group"
                             % (name, victim))
        phase("%s: stop worker 1, parked, and send a burst of %d" % (name, args.n))
        os.kill(victim, signal.SIGSTOP)
        conns = [socket.create_connection(("127.0.0.1", port), 5)
                 for _ in range(args.n)]
        for c in conns:
            c.sendall(b"GET /pid HTTP/1.1\r\nHost: x\r\n\r\n")
        answers = [None] * len(conns)

        def ask(i):
            conns[i].settimeout(args.queued_wait)
            try:
                answers[i] = pid_over(conns[i], send=False)
            except socket.timeout:
                answers[i] = "queued"
            except (OSError, SystemExit):
                answers[i] = "closed"

        askers = [threading.Thread(target=ask, args=(i,)) for i in range(len(conns))]
        for t in askers:
            t.start()
        for t in askers:
            t.join()
        waiting = [i for i, a in enumerate(answers) if a == "queued"]
        kept = sum(1 for a in answers if a == str(worker0))
        if not waiting or kept + len(waiting) != len(conns):
            failed.append((name, "the burst of %d did not split between worker 0 "
                           "and the stopped worker 1: %d answered by worker 0, "
                           "%d waiting, the rest %s" % (
                               len(conns), kept, len(waiting),
                               sorted(set(a for a in answers
                                          if a not in ("queued", str(worker0)))))))
            return failed
        phase("%s: kill the stopped worker 1 with %d connections queued to it"
              % (name, len(waiting)))
        killed = time.monotonic()
        os.kill(victim, signal.SIGKILL)
        victim = None
        deadline = killed + args.queued_wait
        open_ = {conns[i]: i for i in waiting}
        closed_after = {}
        hung = []
        while open_:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select(list(open_), [], [], remaining)
            now = time.monotonic()
            for s in ready:
                i = open_.pop(s)
                try:
                    data = s.recv(4096)
                except OSError:  # a reset is a close
                    data = b""
                if data:
                    hung.append("answered %r" % data[:40])
                else:
                    closed_after[i] = now - killed
        hung += ["open"] * len(open_)
        slowest = max(closed_after.values()) if closed_after else 0.0
        print("%s: burst %d with worker 1 stopped: %d answered by worker 0, %d "
              "queued to worker 1; after its SIGKILL %d closed (slowest %.3f s), "
              "%d not within %g s" % (name, len(conns), kept, len(waiting),
                                      len(closed_after), slowest, len(hung),
                                      args.queued_wait), flush=True)
        if hung:
            failed.append((name, "%d of %d connections queued to the worker the "
                           "supervisor gave up on were not closed within %g s of "
                           "its death (%s)" % (len(hung), len(waiting),
                                               args.queued_wait, hung[0])))
        text = read_log(log_path)
        if not any(g in text for g in GAVE_UP):
            failed.append((name, "the supervisor did not give up on worker 1"))
    finally:
        # A stopped worker would hold the drain until SIGKILL anyway.
        if victim is not None:
            try:
                os.kill(victim, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for c in conns:
            c.close()
        stop_server(p)
    return failed


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
    ap.add_argument("--unstarted-gap", type=int, default=0, metavar="MS",
                    help="measure instead that a worker held MS ms before its "
                         "loop starts is handed nothing (m0serve only)")
    ap.add_argument("--unstarted-bound", type=float, default=1.0, metavar="S",
                    help="with --unstarted-gap: the slowest answer allowed")
    ap.add_argument("--expect-handoffs", action="store_true",
                    help="with --assert: each server's shutdown must report "
                         "at least one connection passed between workers, "
                         "so a balanced split is the mechanism, not luck")
    ap.add_argument("--reaped", action="store_true",
                    help="measure instead that a worker the supervisor reaps "
                         "and does not replace is handed nothing")
    ap.add_argument("--reaped-wait", type=float, default=3.0, metavar="S",
                    help="with --reaped: how long each connection waits for "
                         "its answer")
    ap.add_argument("--queued-wait", type=float, default=1.0, metavar="S",
                    help="with --reaped: how long worker 0's answers are "
                         "waited for, and then how long a connection queued "
                         "to the dead worker may stay open after its death")
    args = ap.parse_args()
    if args.workers < 2:
        raise SystemExit("--workers must be >= 2: one worker has nothing to share")
    extra_common = args.extra.split() if args.extra else []
    modes = {"fork": [], "spawn": ["--spawn-workers"]}
    if args.app_bin:
        modes = {"fork": []}
    chosen = [m.strip() for m in args.modes.split(",") if m.strip()]
    for mode in chosen:
        if mode not in modes:
            raise SystemExit("unknown mode %r" % mode)
    if args.reaped:
        if args.workers != 2:
            raise SystemExit("--reaped measures two workers")
        failed = []
        port = args.port if args.port is not None else free_port(max(1, len(chosen)))
        with tempfile.TemporaryDirectory(prefix="accept-spread-") as logs:
            for mode in chosen:
                failed += reaped(args, logs, mode, modes[mode] + extra_common, port)
                port += 1
                failed += queued(args, logs, mode, modes[mode] + extra_common)
        for mode, why in failed:
            print("accept_spread: %s: %s" % (mode, why))
        if failed:
            sys.exit(1)
        print("accept_spread: a worker the supervisor reaped and did not "
              "replace was handed nothing, and what it had been handed was "
              "closed")
        return
    if args.unstarted_gap > 0:
        if args.app_bin:
            raise SystemExit("--unstarted-gap measures m0serve, not --app-bin")
        with tempfile.TemporaryDirectory(prefix="accept-spread-") as logs:
            failed = unstarted(args, logs)
        for mode, why in failed:
            print("accept_spread: %s: %s" % (mode, why))
        if failed:
            sys.exit(1)
        print("accept_spread: a worker that had not started was handed nothing")
        return
    failed = []
    port = args.port if args.port is not None else free_port(max(1, len(chosen)))
    with tempfile.TemporaryDirectory(prefix="accept-spread-") as logs:
        for mode in chosen:
            log_path = os.path.join(logs, "accept-spread-%s.log" % mode)
            phase("%s: start the server on %d" % (mode, port))
            with open(log_path, "w") as log:
                p = start(args.bin, args.app_dir, port, args.workers,
                          modes[mode] + extra_common, log, args.app_bin)
            wait_started(p, log_path, args.workers)
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
