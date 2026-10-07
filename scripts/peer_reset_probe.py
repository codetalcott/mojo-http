#!/usr/bin/env python3
"""A peer that resets its connection gives its slot back at once (SPEC C9).

The epoll backend reported EPOLLERR as `EV_ERROR`, and the loop skips any
event carrying `EV_ERROR` -- a skip written for kqueue's meaning of the flag,
a registration that failed, which no wait of this loop ever returns. A
client's RST reaches epoll as ONE event carrying EPOLLERR (beside EPOLLHUP),
the skip swallowed it, and the registration it arrived on was spent with it:
a stalled response's write is one-shot, a keep-alive connection's read is
edge-triggered, and neither reports that socket again. So the slot kept its
descriptor and its provision until the process exited -- `--idle-timeout`
bounded it, where it applied, and every graceful shutdown waited out its
whole drain for it (review record B12). kqueue reports a reset as `EV_EOF`,
with the error beside it, so macOS gave the slot back all along: this probe
fails without the fix on Linux only, and passes either way on macOS.

Three shapes, each reset with `SO_LINGER 0` and each registered its own way
when the RST lands:

  - a response in memory its client stopped reading (POST /echo), waiting on
    a one-shot write registration
  - the same from a file (`--static`, sendfile), the pump's path
  - an idle keep-alive connection, waiting on its read registration

The server runs with `--idle-timeout 0`, so no deadline can give back a slot
the reset left behind and a leak stays visible for as long as it is watched,
and with `--metrics`: `http_active_connections`, read by a fresh scrape,
counts every slot the loop holds, the scrape's own included. Each shape
asserts both directions -- the slot is held before the reset (the shape was
built, so a pass is not vacuous) and released within RELEASE seconds after.

usage: peer_reset_probe.py PORT
  against apps/asgi_bare with `--idle-timeout 0 --metrics --max-body 32m`
  and `--static /files=DIR`, DIR holding `big.bin` (16 MiB); see
  `poe smoke-peer-reset`
"""

import socket
import struct
import sys
import time

from probelib import phase, stamp

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8141

BIG = 16 * 1024 * 1024  # past both socket buffers on either kernel
FILE_PATH = "/files/big.bin"  # the smoke's --static file, BIG bytes
# How long a reset slot may take to be given back. The fix releases it in
# the pass the RST wakes; the budget is for a loaded CI runner.
RELEASE = 3.0
# How long a stalled response is left before the reset, so the server has
# filled both socket buffers and parked on its write registration.
STALL = 1.0

# Which phase is running, for the crash handler. Every shape reads the count
# through the same scrape connection, so a traceback out of `active()` names
# the same line whichever shape was being built or released.
# apps/asgi_bare/ws_probe.py carries the original of this comment.
stamp("peer_reset_probe: FAIL")

failures = []


def fail(where, msg):
    """Record a failure against its shape; the probe reports them all."""
    failures.append("%s: %s" % (where, msg))


# ONE scrape connection, kept alive for the whole probe (a scrape asking
# for no close keeps its connection open), so the count it
# reads always includes exactly one slot of its own -- a scrape per call
# would race its own previous connection's close.
_scrape = None


def active():
    """`http_active_connections`, the scrape's own connection included."""
    global _scrape
    if _scrape is None:
        _scrape = socket.create_connection((HOST, PORT), timeout=10)
    _scrape.sendall(b"GET /__metrics HTTP/1.1\r\nHost: x\r\n\r\n")
    buf = b""
    while b"\r\n\r\n" not in buf:
        part = _scrape.recv(65536)
        if not part:
            raise RuntimeError("the scrape connection closed")
        buf += part
    head, body = buf.split(b"\r\n\r\n", 1)
    length = None
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    if length is None:
        raise RuntimeError("the scrape has no Content-Length: %r" % head[:200])
    while len(body) < length:
        part = _scrape.recv(65536)
        if not part:
            raise RuntimeError("the scrape was cut short")
        body += part
    for line in body[:length].split(b"\n"):
        if line.startswith(b"http_active_connections "):
            return int(line.split()[1])
    raise RuntimeError("no http_active_connections in the scrape: %r" % body[:200])


def settle(want, budget):
    """Poll until the count is `want`; the last count seen, and when."""
    start = time.monotonic()
    n = active()
    while n != want and time.monotonic() - start < budget:
        time.sleep(0.05)
        n = active()
    return n, time.monotonic() - start


def reset(sock):
    """Close with an RST rather than a FIN: SO_LINGER on, zero seconds."""
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    sock.close()


def stalled(kind):
    """A connection whose response the server is parked on, unread."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # A small window, so the stall comes early and cannot be hidden by a
    # receive buffer that grows to hold the whole response.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
    sock.settimeout(15)
    sock.connect((HOST, PORT))
    if kind == "memory":
        body = b"m0" * (BIG // 2)
        sock.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                     % len(body) + body)
    else:
        sock.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % FILE_PATH).encode())
    time.sleep(STALL)
    return sock


def idle():
    """A keep-alive connection answered in full, then left open."""
    sock = socket.create_connection((HOST, PORT), timeout=15)
    sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    buf = b""
    while b"\r\n\r\n" not in buf:
        part = sock.recv(4096)
        if not part:
            raise RuntimeError("the keep-alive request was not answered")
        buf += part
    head, rest = buf.split(b"\r\n\r\n", 1)
    length = 0
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    while len(rest) < length:
        part = sock.recv(4096)
        if not part:
            raise RuntimeError("the keep-alive response was cut short")
        rest += part
    time.sleep(0.2)
    return sock


phase("the baseline: the scrape's own slot and no other")
base, _ = settle(1, 10.0)
if base != 1:
    print("peer_reset_probe: FAIL: the server holds %d slots before the first "
          "shape (expected only the scrape's own)" % base)
    sys.exit(1)

# Each shape is judged against the count at its own start, so a slot an
# earlier shape leaked is reported there and does not blind the next one.
for kind in ("memory", "file", "idle"):
    where = {
        "memory": "a reset while a response in memory waits on its write",
        "file": "a reset while a file response waits on its write (sendfile)",
        "idle": "a reset on an idle keep-alive connection",
    }[kind]
    phase(where + ", the connection held")
    before = active()
    try:
        sock = idle() if kind == "idle" else stalled(kind)
    except Exception as exc:
        fail(where, "the shape could not be built: %r" % (exc,))
        continue
    held = active()
    if held != before + 1:
        fail(where, "%d slots held with the connection open, %d before it -- "
             "the shape was not built, so the release below would prove "
             "nothing" % (held, before))
        reset(sock)
        settle(before, RELEASE)
        continue
    phase(where + ", the release after the RST")
    reset(sock)
    left, took = settle(before, RELEASE)
    if left != before:
        fail(where, "%d slots still held %.1fs after the RST, %d before the "
             "connection -- the reset was never seen, so the slot and its "
             "descriptor are held for the life of the process (B12: epoll's "
             "EPOLLERR reported as EV_ERROR, which the loop skips)"
             % (left, took, before))
    else:
        print("  %s: the slot was given back in %.2fs" % (where, took))

if failures:
    for f in failures:
        print("peer_reset_probe: FAIL:", f)
    sys.exit(1)
print("peer_reset_probe: a reset peer's slot is given back at once, "
      "mid-response and idle")
