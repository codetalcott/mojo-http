#!/usr/bin/env python3
"""smoke-accept-batch: a burst of NEW connections does not hold the event loop
away from the connections it already serves (SPEC C8).

    python3 scripts/accept_batch_probe.py BINARY PORT

BINARY is `apps/pool_spike`, run with `func` on the loop. One
`/slow?ms=BLOCK` request parks the loop in usleep; while it sleeps, K
connections queue in the listen backlog, each carrying `/slow?ms=EACH`; then
a keep-alive connection that is already established sends `/fast`. When the
loop wakes, the backlog and the keep-alive's request are both waiting.

  arm       the default batch (ACCEPT_BATCH, read from event_loop.mojo so the
            bound follows the constant): `/fast` answered within one and a
            half batches of EACH beyond what was left of the blocker -- the
            loop served the connection it held before the next batch, and
            before the backlog -- and every burst connection answered, the
            last inside the work plus slack: what a batch leaves is taken by
            the next pass, neither stranded behind the edge-triggered
            listener nor left to a wait that blocks
  negative  Linux only, `M0_ACCEPT_BATCH=0`: the old drain, which must show
            the starvation -- `/fast` behind at least two thirds of K*EACH --
            or the arm above proves nothing. On macOS kqueue reports the
            backlog's depth, and with accepts taken after a pass's other
            events the knob alone does not recreate the old order, so there
            it is not asserted.

The measurements are in docs/notes/the-accept-batch.md. Prints `beyond_ms N`
and `burst_ms N` for the recorder.
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
import time

K = 120          # under the listen backlog of 128, so all of it queues at once
EACH_MS = 10     # long enough that scheduler noise is small beside a batch
BLOCK_MS = 600
LOOP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages",
                    "m0-http", "lightbug_http", "event_loop.mojo")


def fail(msg: str) -> None:
    print("smoke-accept-batch: " + msg, file=sys.stderr)
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


def one_round(port: int) -> tuple[float, float, int]:
    """(ms `/fast` waited beyond the blocker's remainder, ms from the burst
    being queued to its last answer, burst connections answered)."""
    keep = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    keep.request("GET", "/fast")
    keep.getresponse().read()           # established, and kept alive

    blocker = socket.create_connection(("127.0.0.1", port))
    blocker.sendall(b"GET /slow?ms=%d HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % BLOCK_MS)
    t_block = time.monotonic()
    time.sleep(0.05)                    # the loop takes it and parks in usleep

    burst = []
    for _ in range(K):
        s = socket.create_connection(("127.0.0.1", port))
        s.sendall(b"GET /slow?ms=%d HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % EACH_MS)
        burst.append(s)
    t_sent = time.monotonic()
    if (t_sent - t_block) * 1000 > BLOCK_MS * 0.8:
        fail("queueing the burst took %.0f ms of the blocker's %d: this runner is too slow "
             "for the shape the probe needs" % ((t_sent - t_block) * 1000, BLOCK_MS))

    keep.request("GET", "/fast")
    keep.getresponse().read()
    t_fast = time.monotonic()
    block_left = max(0.0, BLOCK_MS / 1000 - (t_sent - t_block))
    beyond_ms = ((t_fast - t_sent) - block_left) * 1000

    # Every burst connection answered: one stranded behind the listener, or
    # behind a wait that blocks while a batch is owed, times out here. One
    # deadline for all of them, or a hundred stranded sockets would each
    # wait out a timeout of their own.
    served = 0
    deadline = t_sent + (BLOCK_MS + K * EACH_MS) / 1000 + 10
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
            served += 1
        s.close()
    burst_ms = (time.monotonic() - t_sent) * 1000
    blocker.close()
    keep.close()
    return beyond_ms, burst_ms, served


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: accept_batch_probe.py BINARY PORT")
    binary, port = sys.argv[1], int(sys.argv[2])
    whole = K * EACH_MS
    batch = accept_batch()
    bound = 1.5 * batch * EACH_MS

    proc = start(binary, port, None)
    try:
        beyond, burst_ms, served = one_round(port)
    finally:
        stop(proc)
    print("arm: /fast %.0f ms beyond the blocker's remainder behind %d queued %d ms requests "
          "(K*EACH = %d ms); burst answered %d/%d, the last %.0f ms after it queued"
          % (beyond, K, EACH_MS, whole, served, K, burst_ms))
    if served != K:
        fail("%d of %d burst connections were answered: what a batch left was stranded" % (served, K))
    if beyond > bound:
        fail("/fast waited %.0f ms beyond the blocker, over one and a half batches (%d of %d "
             "ms requests, %.0f ms): the loop took new connections before the one it already "
             "held" % (beyond, batch, EACH_MS, bound))
    if burst_ms > BLOCK_MS + whole + 2000:
        fail("the burst took %.0f ms to answer, against %d ms of work: an owed batch waited "
             "on a wait that blocks" % (burst_ms, BLOCK_MS + whole))

    if platform.system() == "Linux":
        proc = start(binary, port + 1, "0")
        try:
            neg, neg_burst, neg_served = one_round(port + 1)
        finally:
            stop(proc)
        print("negative arm (M0_ACCEPT_BATCH=0): /fast %.0f ms beyond the blocker; burst answered %d/%d"
              % (neg, neg_served, K))
        if neg < whole * 2 / 3:
            fail("with M0_ACCEPT_BATCH=0 /fast waited only %.0f ms beyond the blocker, under two "
                 "thirds of the burst's %d ms: the probe no longer sees the drain it guards "
                 "against" % (neg, whole))

    print("beyond_ms %.0f" % beyond)
    print("burst_ms %.0f" % burst_ms)


if __name__ == "__main__":
    main()
