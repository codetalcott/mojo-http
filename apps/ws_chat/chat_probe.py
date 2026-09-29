#!/usr/bin/env python3
"""Raw RFC 6455 chat client for smoke-chat — stdlib only.

Single-worker mode (default): two sockets, one speaks, both must hear it —
the sender included (its own message coming back is the delivery
confirmation).

Multi-worker mode (CHAT_EXPECT_WORKERS=2): one socket is placed on EACH
worker by freezing the worker that wins the first one (the X-Worker
header on each 101 says who owns each socket — sequential opens can all be
won by whichever worker is hottest, the same accept-race bias the counter
smoke hit on 2-core CI runners), then ONE message sent on a worker-A
socket must arrive on every socket, including worker B's — those cross the
BroadcastBus.
"""

import os
import signal
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import TEXT, WebSocket, fail, phase, stamp  # noqa: E402

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
EXPECT_WORKERS = int(os.environ.get("CHAT_EXPECT_WORKERS", "1"))


# Which phase is running, for the crash handler. Every phase here reaches
# the socket through the same frame reads, so a traceback out of one says
# which CALL raised and never which PHASE was being proven -- and this
# probe's phases mean different things (a handshake that never completed,
# versus a message that never crossed the bus). Two investigations of the
# 2026-08-30 CI failure were lost to that distinction;
# apps/asgi_bare/ws_probe.py carries the original of this comment.
stamp("chat_probe FAIL")


def read_text(ws, timeout=6.0):
    """Next text frame's payload; heartbeat pings get pongs and are skipped.

    One deadline for the whole read: a per-read timeout is reset by every
    heartbeat, which is why this used to give up after twenty pings."""
    op, payload = ws.recv_data(deadline=time.monotonic() + timeout)
    if op != TEXT:
        fail("unexpected frame op=%d while waiting for text" % op)
    return payload


def connect_ws():
    """Open one chat socket; returns (WebSocket, owning worker id)."""
    ws = WebSocket.connect(HOST, PORT, "/ws", timeout=10)
    if ws.status_line is None:
        fail("connection closed during handshake")
    status = ws.status_line.decode("latin-1")
    if " 101 " not in status + " ":
        fail("expected 101, got: " + status)
    if not ws.accept_ok():
        fail("bad accept key")
    worker = ws.header("X-Worker")
    if worker is None:
        fail("no X-Worker header on the upgrade response")
    return ws, worker


def close_all(sockets):
    for ws in sockets:
        try:
            ws.send_close(1000)
            ws.close()
        except OSError:
            pass


if EXPECT_WORKERS <= 1:
    phase("two sockets on one worker, and a message reaching both")
    a = connect_ws()
    b = connect_ws()
    a[0].send_text("hello room")
    for name, (sock, _) in (("sender", a), ("other", b)):
        got = read_text(sock)
        if got != b"hello room":
            fail("%s socket heard %r, wanted b'hello room'" % (name, got))
    close_all([a[0], b[0]])
    print("chat_probe OK (single worker)")
    sys.exit(0)

# --- Multi-worker: one socket per worker, then one message reaches both ------
# Which worker wins an accept is the kernel's choice and it is not a fair
# one: a macOS runner once handed a single worker every one of 24 opens,
# failing this precondition with nothing wrong in the server. Opening in
# bursts made it worse, not better — the accept path drains the backlog
# until EAGAIN, so the first worker to wake takes the whole burst.
#
# So stop racing. Open one socket, SIGSTOP the worker that got it (X-Worker
# is that worker's pid), and open the second: a stopped process cannot
# accept, so it provably lands on the other worker. Resume immediately —
# the frozen worker's own socket is idle meanwhile, and the assertions
# below are unchanged.
phase("landing one socket on each worker (the second under SIGSTOP)")
sock_a, w_a = connect_ws()
os.kill(int(w_a), signal.SIGSTOP)
try:
    sock_b, w_b = connect_ws()
finally:
    os.kill(int(w_a), signal.SIGCONT)

conns = [(sock_a, w_a), (sock_b, w_b)]
workers = set(w for _, w in conns)
if len(workers) < 2:
    close_all([s for s, _ in conns])
    fail("both sockets landed on worker %s even though it was SIGSTOPped" % w_a)

phase("one message reaching both workers over the bus")
sender_sock, sender_worker = conns[0]
msg = b"hello from " + sender_worker.encode()
sender_sock.send(TEXT, msg)

cross_checked = 0
for sock, worker in conns:
    got = read_text(sock)
    if got != msg:
        fail(
            "socket on worker %s heard %r, wanted %r"
            % (worker, got, msg)
        )
    if worker != sender_worker:
        cross_checked += 1

close_all([s for s, _ in conns])
print(
    "chat_probe OK (%d sockets across %d workers, %d heard it over the bus)"
    % (len(conns), len(workers), cross_checked)
)
