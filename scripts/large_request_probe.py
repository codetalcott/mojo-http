#!/usr/bin/env python3
"""A request larger than one read must still be answered.

The loop performs exactly one `recv` of `recv_staging.capacity()` (4096)
per readiness event. On epoll, which is edge triggered, bytes already
sitting in the socket buffer when the edge fired produce no further edge —
so a request whose headers did not fit in what the eager read at accept
plus one edge could take was left half-read, and stalled until the header
timeout answered 408. The limit was exactly 8192 bytes, and 8 KB of request
headers is a large cookie jar or a JWT, not an attack.

macOS never showed it: `add_read` there is `EV_ADD` without `EV_CLEAR`, so
connection reads are LEVEL triggered and the next `kevent` simply reported
the socket readable again. That asymmetry is the point of this probe — the
platform that forgives the mistake is the one most people develop on.

usage: large_request_probe.py PORT
"""
import socket
import sys
import time
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

# Comfortably inside the 32 KB max_total_header_size, and comfortably past
# the 8192 the bug stopped at.
SIZES = (4000, 8192, 8200, 12000, 20000, 31000)
OVERSIZED = 40000


# Which phase is running, for the crash handler below. All three phases
# funnel through `send`, so a traceback naming its recv or sendall says
# which CALL raised and never which PHASE was being proven -- and the
# phases here mean opposite things (a size that must be ANSWERED versus one
# that must be REFUSED). Two investigations of the 2026-08-30 CI failure
# were lost to that distinction; apps/asgi_bare/ws_probe.py carries the
# original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("large_request_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def request_of(total):
    base = (b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
            b"X-Pad: ")
    tail = b"\r\n\r\n"
    return base + b"p" * (total - len(base) - len(tail)) + tail


def send(total, segment=None, timeout=8.0):
    """Returns the status line, or a word describing how it failed."""
    req = request_of(total)
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    s.settimeout(timeout)
    try:
        if segment:
            for i in range(0, len(req), segment):
                s.sendall(req[i:i + segment])
        else:
            s.sendall(req)                    # ONE write: the failing shape
        buf = b""
        while True:
            try:
                c = s.recv(65536)
            except socket.timeout:
                return "STALLED"
            if not c:
                return "closed-without-answering"
            buf += c
            if b"\r\n\r\n" in buf:
                return buf.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    except ConnectionResetError:
        return "RESET"
    finally:
        s.close()


failures = []

for size in SIZES:
    phase("a %d-byte request in ONE write" % size)
    t0 = time.time()
    got = send(size)
    dt = time.time() - t0
    if not got.startswith("HTTP/1.1 200"):
        failures.append("a %d-byte request in one write: %s" % (size, got))
    elif dt > 2.0:
        # Answered, but only after the header timeout had a say.
        failures.append("a %d-byte request in one write took %.1fs" % (size, dt))

# The same bytes segmented must keep working — that path was never broken,
# and a fix that traded one for the other would be no fix.
for size in (20000, 31000):
    phase("a %d-byte request in 1400-byte writes" % size)
    got = send(size, segment=1400)
    if not got.startswith("HTTP/1.1 200"):
        failures.append("a %d-byte request in 1400-byte writes: %s" % (size, got))

# Past max_total_header_size the server must REFUSE, promptly. A stall is
# not a refusal, and this is what stops the fix from becoming a way to feed
# the server unbounded headers.
phase("a %d-byte request, which must be refused 431" % OVERSIZED)
got = send(OVERSIZED)
if "431" not in got:
    failures.append("a %d-byte request should be refused 431, got: %s"
                    % (OVERSIZED, got))

if failures:
    for f in failures:
        print("large_request_probe: FAIL:", f)
    sys.exit(1)

print("large_request_probe: requests up to the header cap are answered in one "
      "write, and oversized ones are refused")
