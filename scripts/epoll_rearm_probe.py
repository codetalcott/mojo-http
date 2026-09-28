#!/usr/bin/env python3
"""A keep-alive request costs the event loop no `epoll_ctl` (review record R2).

    python3 scripts/epoll_rearm_probe.py BINARY

BINARY is `apps/hello`, built. Linux only, with `strace` on PATH: the count
is the kernel's, taken by `strace -f -e trace=epoll_ctl` over one server's
life, so it needs no counter in the server and cannot disagree with what the
server actually asked the kernel for.

A connection's read interest is registered once and stays. A request needs a
re-registration only when its read may have left bytes in the socket that no
edge will announce -- a read that filled the staging buffer, or the peer's
EOF -- and the loop's rule for headers (SPEC A13) used to re-register after
EVERY read: an `epoll_ctl` ADD, refused EEXIST because the descriptor is
still registered, then the MOD it falls back to, on every keep-alive request.
That is the pair 9a6651f measured out of the hot path (docs/SERVER_PERFORMANCE.md,
+10% with the idle-timer change beside it), back since b9145bf.

  keep-alive  REQUESTS small requests over CONNECTIONS keep-alive
              connections: at most BOUND `epoll_ctl` calls per request,
              counted from the first request to the last answer -- which
              includes each new connection's own registration
  control     LARGE requests of three staging buffers, on the same server:
              each read that fills the buffer must re-register, so the count
              must rise by at least one call per request. A meter that can
              read silence and nothing else proves nothing, so the meter is
              checked here, in the same process, before its silence in the
              first phase is trusted. And each must be ANSWERED, which is
              the half of A13 the rule exists for: the loop reads a slot a
              second time in the same pass (`_drain_pipelined`), so a
              request two reads long is answered with no edge at all, and
              only the third read waits on the re-registration after a full
              one -- without it the rest sits unannounced until the header
              timeout

Prints `epoll_ctl_per_request X`, `eexist_per_request X` and
`control_per_request X` for the recorder.
"""

from __future__ import annotations

import http.client
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback

CONNECTIONS = 4
REQUESTS = 2000
LARGE = 50
# One header this long: three reads of the 4096-byte staging buffer, inside
# the 32 KB header cap.
LARGE_PAD = 12000
LARGE_WAIT_S = 5
# A keep-alive request that re-registers costs TWO calls (the refused ADD and
# its MOD); the fixed loop costs none, the server's setup and each
# connection's own registration spread over REQUESTS being all that is left.
# Half a call sits far from both, and still fails a loop that re-registers
# with one call a request.
BOUND = 0.5


# Which phase is running, for the crash handler below: a traceback names the
# CALL that raised (a helper every phase shares) and never the PHASE being
# proven. scripts/phase_stamp_check.py holds every probe to it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("epoll_rearm_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("epoll_rearm_probe: %s: FAIL: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def count(trace: str) -> tuple[int, int]:
    """`epoll_ctl` calls in the trace so far, and how many were refused
    EEXIST. strace flushes a line as each call returns."""
    calls = eexist = 0
    with open(trace) as f:
        for line in f:
            if re.search(r"\bepoll_ctl\(", line):
                calls += 1
                if "EEXIST" in line:
                    eexist += 1
    return calls, eexist


def settled(trace: str) -> tuple[int, int]:
    """The count once it has stopped moving: the loop re-registers after it
    has written the answer, so the client can hold its last response before
    the call behind it has been made."""
    last, still = count(trace), 0
    deadline = time.time() + 5
    while still < 3 and time.time() < deadline:
        time.sleep(0.1)
        now = count(trace)
        still = still + 1 if now == last else 0
        last = now
    return last


def server_child(tracer: int) -> int:
    """The traced server: strace's own child."""
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % entry) as f:
                fields = f.read().rsplit(")", 1)[1].split()
        except OSError:
            continue
        if int(fields[1]) == tracer:
            return int(entry)
    return -1


def get(conn: http.client.HTTPConnection, path: str, headers=None) -> bytes:
    conn.request("GET", path, headers=headers or {})
    resp = conn.getresponse()
    body = resp.read()
    if resp.status != 200:
        fail("GET %s answered %d" % (path, resp.status))
    if resp.getheader("Connection", "").lower() == "close":
        fail("GET %s closed its connection; every request here is keep-alive" % path)
    return body


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    binary = sys.argv[1]
    if platform.system() != "Linux":
        # Not a skip: this probe measures epoll, and a green run that counted
        # nothing would read as a pass. The task runs it on Linux only.
        print("epoll_rearm_probe: epoll is Linux's; refusing to run on %s"
              % platform.system(), file=sys.stderr)
        sys.exit(2)
    strace = shutil.which("strace")
    if strace is None:
        fail("strace is not on PATH (apt-get install strace): the count is "
             "the kernel's, and nothing else here can take it")

    phase("start the server under strace")
    port = free_port()
    work = tempfile.mkdtemp(prefix="epoll-rearm-")
    trace = os.path.join(work, "trace")
    # No request cap (a close would open a fresh connection the count then
    # charges to its requests) and no access log.
    env = dict(os.environ, M0_PORT=str(port), M0_HOST="127.0.0.1",
               M0_MAX_KEEPALIVE_REQUESTS="0")
    env.pop("M0_ACCESS_LOG", None)
    log = open(os.path.join(work, "server.log"), "w+")
    tracer = subprocess.Popen(
        [strace, "-f", "-qq", "-e", "trace=epoll_ctl", "-o", trace, binary],
        env=env, stdout=log, stderr=subprocess.STDOUT,
    )
    child = -1
    try:
        deadline = time.time() + 60
        while True:
            if tracer.poll() is not None:
                log.seek(0)
                fail("strace exited %s before the server answered /health:\n%s"
                     % (tracer.returncode, log.read()[-2000:]))
            try:
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                get(c, "/health")
                c.close()
                break
            except OSError:
                if time.time() > deadline:
                    log.seek(0)
                    fail("no answer on :%d within 60 s:\n%s" % (port, log.read()[-2000:]))
                time.sleep(0.1)
        child = server_child(tracer.pid)
        setup = settled(trace)
        if setup[0] == 0:
            fail("the trace holds no epoll_ctl at all after startup -- the "
                 "listener alone registers one, so strace is not seeing the server")

        phase("keep-alive requests")
        conns = [http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                 for _ in range(CONNECTIONS)]
        for i in range(REQUESTS):
            body = get(conns[i % CONNECTIONS], "/")
            if body != b"hello from m0":
                fail("request %d answered %r" % (i, body))
        small = settled(trace)
        calls = small[0] - setup[0]
        eexist = small[1] - setup[1]
        per_request = calls / REQUESTS

        phase("control: requests three reads long")
        big = http.client.HTTPConnection("127.0.0.1", port, timeout=LARGE_WAIT_S)
        pad = {"X-Pad": "p" * LARGE_PAD}
        for i in range(LARGE):
            try:
                body = get(big, "/", pad)
            except TimeoutError:
                fail("large request %d was not answered within %d s: a read "
                     "that filled the buffer did not re-register, and the rest "
                     "of the request sat in the socket with no edge left to "
                     "announce it (SPEC A13)" % (i, LARGE_WAIT_S))
            if body != b"hello from m0":
                fail("large request %d answered %r" % (i, body))
        control = settled(trace)
        control_calls = control[0] - small[0]
        control_per_request = control_calls / LARGE

        phase("stop the server")
        for c in conns + [big]:
            c.close()
    finally:
        if child <= 0 and tracer.poll() is None:
            child = server_child(tracer.pid)
        if child > 0:
            try:
                os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            tracer.wait(timeout=20)
        except subprocess.TimeoutExpired:
            for pid in (child, tracer.pid):
                if pid > 0:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            tracer.wait()

    print("setup: %d epoll_ctl before the first request" % setup[0])
    print("keep-alive: %d epoll_ctl (%d refused EEXIST) over %d requests on %d connections"
          % (calls, eexist, REQUESTS, CONNECTIONS))
    print("control: %d epoll_ctl over %d requests of %d+ bytes"
          % (control_calls, LARGE, LARGE_PAD))
    print("epoll_ctl_per_request %.4f" % per_request)
    print("eexist_per_request %.4f" % (eexist / REQUESTS))
    print("control_per_request %.4f" % control_per_request)

    phase("verdict")
    if control_calls < LARGE:
        fail("%d epoll_ctl over %d requests larger than the staging buffer: each "
             "read that fills it must re-register, so the meter is not reading "
             "the loop and its count of the keep-alive phase means nothing"
             % (control_calls, LARGE))
    if per_request > BOUND:
        fail("%.3f epoll_ctl per keep-alive request (bound %.1f): %d calls, %d of "
             "them refused EEXIST -- the loop is re-registering read interest a "
             "connection already holds (review record R2)"
             % (per_request, BOUND, calls, eexist))
    shutil.rmtree(work, ignore_errors=True)
    print("epoll_rearm_probe: OK")


if __name__ == "__main__":
    main()
