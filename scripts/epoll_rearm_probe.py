#!/usr/bin/env python3
"""A keep-alive request, and a read of an upload, cost the event loop no
`epoll_ctl` (review record R2).

    python3 scripts/epoll_rearm_probe.py BINARY

BINARY is `apps/hello`, built. Linux only, with `strace` on PATH: the count
is the kernel's, taken by `strace -f -e trace=epoll_ctl,recvfrom` over one
server's life, so it needs no counter in the server and cannot disagree with
what the server actually asked the kernel for. The loop's reads are counted
from the same trace (libc's `recv` is the `recvfrom` system call on Linux),
with those that filled the buffer they were given.

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
              the half of A13 the rule exists for: the loop takes ONE read
              per event (the drain reads nothing, LF72), so each read that
              fills the buffer leaves the rest to an event only its
              re-registration brings -- without it the rest sits
              unannounced until the header timeout

The same rule holds a request BODY, read one `recv` per event like the
headers, and it re-registered after every read of one: R2's pair on each
read of an upload still arriving, where the headers' was once a request.

  dribble     a body of DRIBBLE pieces of DRIBBLE_PIECE bytes, each sent
              DRIBBLE_GAP_S after the last, so each is a short read of its
              own: at most BOUND `epoll_ctl` calls per read, counted over
              the reads the trace shows
  upload      UPLOADS bodies of UPLOAD_BYTES in one write each, and the
              control of the phase above: each must be ANSWERED within
              UPLOAD_WAIT_S (a read that fills the buffer must re-register,
              or the rest of the body sits unannounced until the body
              timeout), and the count must rise by at least one call for
              each read that filled the buffer, so the meter is seen to read
              a body's re-registration before the dribble's silence is
              trusted
  half-close  a body cut short, its last bytes arriving with the client's
              FIN in one segment: the read that takes them spends the EOF's
              one edge, and only re-registering after it reports the EOF
              again, so the connection must be closed within
              HALF_CLOSE_WAIT_S rather than held until the body timeout

Prints `epoll_ctl_per_request X`, `eexist_per_request X`,
`control_per_request X` and `epoll_ctl_per_body_read X` for the recorder.
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

from probelib import NotServing, fail, free_port, phase, stamp, wait_healthy

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
DRIBBLE = 100
DRIBBLE_PIECE = 64
# Far longer than the loop takes to read a piece, even under strace.
DRIBBLE_GAP_S = 0.01
UPLOADS = 3
# 256 staging buffers, inside the 4 MB body cap.
UPLOAD_BYTES = 1 << 20
# Both far inside the 30 s body timeout that a stalled upload runs to.
UPLOAD_WAIT_S = 10
HALF_CLOSE_WAIT_S = 5
# What the half-closed request declares, and the part of it sent.
HALF_CLOSE_DECLARED = 20000
HALF_CLOSE_SENT = 3000


# Which phase is running, for the crash handler: a traceback names the CALL
# that raised (a helper every phase shares) and never the PHASE being proven.
# scripts/phase_stamp_check.py holds every probe to it.
stamp("epoll_rearm_probe: FAIL", fail="epoll_rearm_probe: {phase}: FAIL: {msg}",
      stream=sys.stderr)


def count(trace: str) -> tuple[int, int, int, int]:
    """`epoll_ctl` calls in the trace so far, how many were refused EEXIST,
    `recvfrom` calls, and how many of those filled the buffer they were
    given. strace flushes a line as each call returns."""
    calls = eexist = reads = full = 0
    with open(trace) as f:
        for line in f:
            if re.search(r"\bepoll_ctl\(", line):
                calls += 1
                if "EEXIST" in line:
                    eexist += 1
            elif re.search(r"\brecvfrom\(", line):
                reads += 1
                # `recvfrom(7, ""..., 4096, 0, NULL, NULL) = 4096`
                m = re.search(r", (\d+), [^,]+, NULL, NULL\) += (\d+)", line)
                if m and m.group(1) == m.group(2):
                    full += 1
    return calls, eexist, reads, full


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
    # `-s 0`: a read's bytes are not the point, and 3 MB of upload would
    # otherwise be copied into the trace.
    tracer = subprocess.Popen(
        [strace, "-f", "-qq", "-s", "0", "-e", "trace=epoll_ctl,recvfrom",
         "-o", trace, binary],
        env=env, stdout=log, stderr=subprocess.STDOUT,
    )
    child = -1
    try:
        # strace is the process watched: it exits with the server it traces.
        try:
            wait_healthy("http://127.0.0.1:%d/health" % port, tracer, timeout=60, log=log)
        except NotServing as exc:
            fail(str(exc))
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

        phase("dribble: a body sent a piece at a time")
        up = socket.create_connection(("127.0.0.1", port), timeout=UPLOAD_WAIT_S)
        up.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        up.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                   % (DRIBBLE * DRIBBLE_PIECE))
        time.sleep(0.2)
        for _ in range(DRIBBLE):
            up.sendall(b"d" * DRIBBLE_PIECE)
            time.sleep(DRIBBLE_GAP_S)
        answer = http.client.HTTPResponse(up)
        answer.begin()
        body = answer.read()
        if answer.status != 200 or body != b"hello from m0":
            fail("the dribbled upload answered %d %r" % (answer.status, body))
        dribble = settled(trace)
        dribble_calls = dribble[0] - control[0]
        dribble_reads = dribble[2] - control[2]
        # The bound divides by the reads the trace shows, so two pieces read
        # together cannot flatter it; this asks only that reads are seen.
        if dribble_reads < DRIBBLE // 2:
            fail("%d reads for a body sent in %d pieces %.0f ms apart: the "
                 "trace is not seeing the loop's reads" % (
                     dribble_reads, DRIBBLE, DRIBBLE_GAP_S * 1000))
        dribble_per_read = dribble_calls / dribble_reads

        phase("upload: bodies many reads long, in one write each")
        loader = http.client.HTTPConnection("127.0.0.1", port, timeout=UPLOAD_WAIT_S)
        payload = b"u" * UPLOAD_BYTES
        for i in range(UPLOADS):
            try:
                loader.request("POST", "/", body=payload)
                answer = loader.getresponse()
                body = answer.read()
            except TimeoutError:
                fail("upload %d of %d bytes was not answered within %d s: a "
                     "body read that filled the buffer did not re-register, and "
                     "the rest of the body sat in the socket with no edge left "
                     "to announce it (SPEC A13)" % (i, UPLOAD_BYTES, UPLOAD_WAIT_S))
            if answer.status != 200 or body != b"hello from m0":
                fail("upload %d answered %d %r" % (i, answer.status, body))
        upload = settled(trace)
        upload_calls = upload[0] - dribble[0]
        upload_full = upload[3] - dribble[3]

        phase("half-close: a body cut short by the client's FIN")
        cut = socket.create_connection(("127.0.0.1", port), timeout=HALF_CLOSE_WAIT_S)
        cut.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                    % HALF_CLOSE_DECLARED)
        time.sleep(0.2)
        # Corked, the FIN rides the last data segment: one edge for both, so
        # the read that takes the data is the one that spends the EOF's edge.
        cut.setsockopt(socket.IPPROTO_TCP, socket.TCP_CORK, 1)
        cut.sendall(b"h" * HALF_CLOSE_SENT)
        cut.shutdown(socket.SHUT_WR)
        started = time.time()
        try:
            while cut.recv(65536):
                pass
        except TimeoutError:
            fail("a body cut short by a half-close was still open after %d s: "
                 "the read that took its last bytes did not re-register, so "
                 "the EOF behind them was never reported again, and the "
                 "connection is held until the body timeout" % HALF_CLOSE_WAIT_S)
        except ConnectionResetError:
            pass
        released_s = time.time() - started

        phase("stop the server")
        for c in conns + [big, loader, up, cut]:
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
    print("dribble: %d epoll_ctl over %d reads of a body sent in %d pieces"
          % (dribble_calls, dribble_reads, DRIBBLE))
    print("upload: %d epoll_ctl over %d uploads of %d bytes, %d reads filling the buffer"
          % (upload_calls, UPLOADS, UPLOAD_BYTES, upload_full))
    print("half-close: a body cut short was closed after %.2f s" % released_s)
    print("epoll_ctl_per_request %.4f" % per_request)
    print("eexist_per_request %.4f" % (eexist / REQUESTS))
    print("control_per_request %.4f" % control_per_request)
    print("epoll_ctl_per_body_read %.4f" % dribble_per_read)

    phase("verdict")
    if control_calls < LARGE:
        fail("%d epoll_ctl over %d requests larger than the staging buffer: each "
             "read that fills it must re-register, so the meter is not reading "
             "the loop and its count of the keep-alive phase means nothing"
             % (control_calls, LARGE))
    if upload_full == 0 or upload_calls < upload_full:
        fail("%d epoll_ctl over %d body reads that filled the buffer: each must "
             "re-register, so the meter is not reading the body's reads and its "
             "count of the dribble means nothing" % (upload_calls, upload_full))
    if per_request > BOUND:
        fail("%.3f epoll_ctl per keep-alive request (bound %.1f): %d calls, %d of "
             "them refused EEXIST -- the loop is re-registering read interest a "
             "connection already holds (review record R2)"
             % (per_request, BOUND, calls, eexist))
    if dribble_per_read > BOUND:
        fail("%.3f epoll_ctl per read of a dribbled body (bound %.1f): %d calls "
             "over %d reads -- the loop re-registers read interest after a body "
             "read that took everything the socket held (review record R2)"
             % (dribble_per_read, BOUND, dribble_calls, dribble_reads))
    shutil.rmtree(work, ignore_errors=True)
    print("epoll_rearm_probe: OK")


if __name__ == "__main__":
    main()
