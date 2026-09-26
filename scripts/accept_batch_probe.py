#!/usr/bin/env python3
"""smoke-accept-batch: a burst of NEW connections does not hold the event loop
away from the connections it already serves (SPEC C8).

    python3 scripts/accept_batch_probe.py BINARY PORT

BINARY is `apps/pool_spike`, run with `func` on the loop. One
`/slow?ms=BLOCK` request parks the loop in usleep; while it sleeps, K
connections queue in the listen backlog, each carrying `/slow?ms=EACH`; then
a keep-alive connection that is already established sends `/fast`. When the
blocker is answered the loop has the backlog and the keep-alive's request
waiting at once.

No bound is in nominal milliseconds, because a runner's timers oversleep:
CI's first macOS run answered all 120 queued 10 ms requests, `/fast` inside
its bound, and failed on a burst that took 7 s. `/fast`'s bound is in what
one queued request COSTS on this box, measured first (`cost`), and every
time counts from the blocker's own answer. The burst is judged by its
widest GAP, not its length: a later macOS run measured a request at
17.3 ms and then served the burst at 49 ms a request, so a bound on the
burst's total judged the runner's timers again, while no two of its answers
were more than 100 ms apart.

  arm       the default batch (ACCEPT_BATCH, read from event_loop.mojo so the
            bound follows the constant): `/fast` answered within one and a
            half batches' cost of the blocker -- the loop served the
            connection it held before the next batch, not after the backlog
            -- and every burst connection answered with no two answers more
            than GAP_MS apart: what a batch leaves is taken by the next pass,
            neither stranded behind the edge-triggered listener nor left to a
            wait that blocks, which runs to the loop's one-second timeout
            (1012 ms measured) where the widest honest gap is one request
  negative  Linux only, `M0_ACCEPT_BATCH=0`: the old drain, which must show
            the starvation -- `/fast` behind at least two thirds of the
            burst's cost -- or the arm above proves nothing. On macOS kqueue
            reports the backlog's depth, and with accepts taken after a
            pass's other events the knob alone does not recreate the old
            order, so there it is not asserted.

The measurements are in docs/notes/the-accept-batch.md. Prints `beyond_ms N`,
`bound_ms N`, `burst_ms N`, `gap_ms N` and `cost_ms N` for the recorder.
"""

from __future__ import annotations

import http.client
import os
import platform
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

K = 120          # under the listen backlog of 128, so all of it queues at once
EACH_MS = 10     # what each queued request asks for; its COST is measured
BLOCK_MS = 600
# The widest gap two burst answers may have between them: half the loop's
# one-second wait (`run_event_loop`'s `_wait_for_events(..., 1000)`), which a
# wait that blocks between owed batches runs to. The widest honest gap is one
# request: 11 ms on Linux, 54-100 ms on the macOS runner.
GAP_MS = 500
LOOP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages",
                    "m0-http", "lightbug_http", "event_loop.mojo")


# Which phase is running, for the crash handler below: a traceback names the
# CALL that raised (a socket helper every phase shares) and never the PHASE
# being proven. scripts/phase_stamp_check.py holds every probe to it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("smoke-accept-batch: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("smoke-accept-batch: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


def accept_batch() -> int:
    """The loop's default batch, read from its source: the bound below is in
    batches, and a constant copied here would drift from the one it tests."""
    m = re.search(r"^comptime ACCEPT_BATCH = (\d+)$", open(LOOP).read(), re.M)
    if not m:
        fail("no `comptime ACCEPT_BATCH = N` in %s: re-point the probe" % LOOP)
    return int(m.group(1))


def start(binary: str, port: int, batch: str | None) -> subprocess.Popen:
    env = dict(os.environ, M0_PORT=str(port), M0_POOL_THREADS="0")
    env.pop("M0_ACCEPT_BATCH", None)
    if batch is not None:
        env["M0_ACCEPT_BATCH"] = batch
    # A file, not a pipe nobody reads: a server that logs enough to fill a
    # pipe would block on it and fake the stall this probe measures.
    log = tempfile.TemporaryFile(mode="w+")
    proc = subprocess.Popen([binary], env=env, stdout=log, stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + 20
    while time.time() < deadline:
        if proc.poll() is not None:
            log.seek(0)
            fail("the server exited %s before answering /health:\n%s"
                 % (proc.returncode, log.read()[-2000:]))
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                c.close()
                return proc
        except OSError:
            time.sleep(0.05)
    proc.kill()
    fail("the server never answered /health on :%d" % port)
    raise AssertionError


def stop(proc: subprocess.Popen) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def cost(port: int) -> float:
    """What one `/slow?ms=EACH` costs this server on this box, in ms: the
    median of five, one at a time, with nothing else in flight."""
    samples = []
    for _ in range(5):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        t0 = time.monotonic()
        c.request("GET", "/slow?ms=%d" % EACH_MS)
        c.getresponse().read()
        samples.append((time.monotonic() - t0) * 1000)
        c.close()
    samples.sort()
    return samples[len(samples) // 2]


def one_round(port: int) -> dict:
    """One blocker, one burst, one `/fast`. Times in ms from the blocker's
    answer: `beyond` to `/fast`'s, `burst` to the last burst answer, `gap`
    the widest silence between two burst answers."""
    keep = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    keep.request("GET", "/fast")
    keep.getresponse().read()           # established, and kept alive

    blocker = socket.create_connection(("127.0.0.1", port))
    blocker.settimeout(60)
    blocker.sendall(b"GET /slow?ms=%d HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % BLOCK_MS)
    t_block = time.monotonic()
    answered: list[float] = []

    def blocker_answer() -> None:
        try:
            if blocker.recv(1):
                answered.append(time.monotonic())
        except OSError:
            pass

    watcher = threading.Thread(target=blocker_answer, daemon=True)
    watcher.start()
    time.sleep(0.05)                    # the loop takes it and parks in usleep

    burst = []
    for _ in range(K):
        s = socket.create_connection(("127.0.0.1", port))
        s.sendall(b"GET /slow?ms=%d HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % EACH_MS)
        burst.append(s)
    t_sent = time.monotonic()
    if answered or (t_sent - t_block) * 1000 > BLOCK_MS * 0.8:
        fail("queueing the burst took %.0f ms of the blocker's %d: this runner is too slow "
             "for the shape the probe needs" % ((t_sent - t_block) * 1000, BLOCK_MS))

    keep.request("GET", "/fast")
    keep.getresponse().read()
    t_fast = time.monotonic()
    watcher.join(timeout=30)
    if not answered:
        fail("the blocker was never answered")
    t_blocker = answered[0]

    # Every burst connection answered: one stranded behind the listener, or
    # behind a wait that blocks while a batch is owed, times out here. One
    # deadline for all of them, or a hundred stranded sockets would each
    # wait out a timeout of their own.
    done = []
    deadline = t_sent + 60
    for s in burst:
        s.settimeout(max(0.05, deadline - time.monotonic()))
        data = b""
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
        except OSError:
            pass
        if data.startswith(b"HTTP/1.1 200"):
            done.append(time.monotonic())
        s.close()
    blocker.close()
    keep.close()
    # Read in the order they were queued, which is the order they are served,
    # so a gap between two reads is a silence of the server's -- except before
    # the first, which is the probe waiting on `/fast`, and is left out.
    gaps = [b - a for a, b in zip(done, done[1:])]
    return {
        "beyond": (t_fast - t_blocker) * 1000,
        "burst": ((done[-1] if done else time.monotonic()) - t_blocker) * 1000,
        "gap": max(gaps) * 1000 if gaps else 0.0,
        "served": len(done),
    }


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: accept_batch_probe.py BINARY PORT")
    binary, port = sys.argv[1], int(sys.argv[2])
    batch = accept_batch()

    phase("arm: start the server")
    proc = start(binary, port, None)
    try:
        phase("arm: measure what one request costs")
        each = cost(port)
        phase("arm: the burst behind the blocker")
        r = one_round(port)
    finally:
        stop(proc)
    whole = K * each
    bound = 1.5 * batch * each
    print("arm: /slow?ms=%d costs %.1f ms here; /fast %.0f ms after the blocker's answer, behind "
          "%d queued (%.0f ms of them); burst answered %d/%d, the last %.0f ms after the blocker, "
          "the widest gap %.0f ms"
          % (EACH_MS, each, r["beyond"], K, whole, r["served"], K, r["burst"], r["gap"]))
    if r["served"] != K:
        fail("%d of %d burst connections were answered: what a batch left was stranded"
             % (r["served"], K))
    if r["beyond"] > bound:
        fail("/fast waited %.0f ms after the blocker, over one and a half batches (%d requests "
             "at %.1f ms, %.0f ms): the loop took new connections before the one it already "
             "held" % (r["beyond"], batch, each, bound))
    if r["gap"] > GAP_MS:
        fail("%.0f ms passed between two burst answers, over %d (the burst took %.0f ms after "
             "the blocker, %.0f ms of work): an owed batch waited on a wait that blocks"
             % (r["gap"], GAP_MS, r["burst"], whole))

    if platform.system() == "Linux":
        phase("negative arm: start the server")
        proc = start(binary, port + 1, "0")
        try:
            phase("negative arm: measure what one request costs")
            neg_each = cost(port + 1)
            phase("negative arm: the burst behind the blocker")
            n = one_round(port + 1)
        finally:
            stop(proc)
        print("negative arm (M0_ACCEPT_BATCH=0): /slow?ms=%d costs %.1f ms; /fast %.0f ms after "
              "the blocker; burst answered %d/%d" % (EACH_MS, neg_each, n["beyond"], n["served"], K))
        if n["beyond"] < K * neg_each * 2 / 3:
            fail("with M0_ACCEPT_BATCH=0 /fast waited only %.0f ms after the blocker, under two "
                 "thirds of the burst's %.0f ms: the probe no longer sees the drain it guards "
                 "against" % (n["beyond"], K * neg_each))

    print("beyond_ms %.0f" % r["beyond"])
    print("bound_ms %.0f" % bound)
    print("burst_ms %.0f" % r["burst"])
    print("gap_ms %.0f" % r["gap"])
    print("cost_ms %.1f" % each)


if __name__ == "__main__":
    main()
