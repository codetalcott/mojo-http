#!/usr/bin/env python3
"""A full loop takes a slot back for a new connection (SPEC C23).

When every one of a loop's slots is in use, a new connection gets one from
a connection a deadline is already counting down: the one between requests
idle longest, else the one whose head has been arriving longest, once that
is a second. Before, the new connection was closed unread and its client
read a reset. Measured on 1.17.0's tree: 1008 streams beside 16 idle
keep-alive connections -- the page loads of the tabs holding them -- reset
the health check, and 1024 idle keep-alive connections from one client
reset every connection for the 60 s of their idle timeout.

Against `m0serve scripts/smoke/hold_app.py --realtime --max-connections N
--health-path /health --metrics`, `reserve = min(16, N // 16)`:

- the browser shape: `N - reserve` held streams and `reserve` idle
  keep-alive connections fill the loop; the health path is answered, the
  idle connections are taken back oldest first, one per connection that
  finds the loop full, and every stream is still held;
- `N` connections that say nothing fill it: a new one is refused while they
  are younger than a second, and served once they are older, the oldest of
  them answered 408 and closed;
- `/__metrics` counting both.

With `--off` (the server under `M0_RECLAIM=0`) the browser shape resets the
health path, as before: the probe sees the mechanism, not luck.

usage: reclaim_probe.py PORT N [--off]
"""
import socket
import sys
import time

from probelib import fail, phase, stamp

stamp("reclaim_probe: FAIL")

PORT = int(sys.argv[1])
N = int(sys.argv[2])
OFF = "--off" in sys.argv[3:]
RESERVE = min(16, N // 16)
STREAMS = N - RESERVE
FLOOR_S = 1.0

HOLD = b"GET /hold HTTP/1.1\r\nHost: x\r\n\r\n"
PLAIN = b"GET /plain HTTP/1.1\r\nHost: x\r\n\r\n"


def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def head_of(s, timeout=5.0):
    """The response head `s` reads, or what it read before EOF or a reset."""
    s.settimeout(timeout)
    got = b""
    deadline = time.monotonic() + timeout
    while b"\r\n\r\n" not in got and time.monotonic() < deadline:
        try:
            chunk = s.recv(4096)
        except ConnectionResetError:
            return got + b"<reset>"
        except socket.timeout:
            break
        if not chunk:
            return got + b"<eof>"
        got += chunk
    return got


def status_of(head):
    parts = head.split(b"\r\n", 1)[0].split(b" ")
    return int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None


def ended(s, timeout=1.0):
    """What `s` reads until the server closes it, and whether it did within
    `timeout`: an idle connection taken back reads nothing and an EOF."""
    s.settimeout(timeout)
    got = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            chunk = s.recv(4096)
        except ConnectionResetError:
            return got, True
        except socket.timeout:
            return got, False
        if not chunk:
            return got, True
        got += chunk
    return got, False


def still_open(s):
    return not ended(s, timeout=0.05)[1]


def get(path):
    """One request on a new connection: its status, or what ended it."""
    s = connect()
    s.sendall(b"GET " + path.encode() + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    head = head_of(s)
    body = b""
    s.settimeout(5)
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            body += chunk
    except (socket.timeout, ConnectionResetError):
        pass
    s.close()
    return status_of(head), head, head.split(b"\r\n\r\n", 1)[-1] + body


def idle_keepalive():
    """A connection that has answered one request and stays open."""
    s = connect()
    s.sendall(PLAIN)
    head = head_of(s)
    if status_of(head) != 200:
        fail("a keep-alive request under the limit read %r" % head[:120])
    s.settimeout(5)
    while not head.endswith(b"ok\n"):
        head += s.recv(4096)
    return s


def metric(text, name):
    for line in text.splitlines():
        if line.startswith(name + " "):
            return int(line.split()[1])
    fail("/__metrics has no %s:\n%s" % (name, text))


def fill_browser_shape():
    holds = []
    for _ in range(STREAMS):
        s = connect()
        s.sendall(HOLD)
        holds.append(s)
    for s in holds:
        head = head_of(s)
        if status_of(head) != 200:
            fail("a stream under the stream limit read %r" % head[:120])
    idle = [idle_keepalive() for _ in range(RESERVE)]
    return holds, idle


phase("the browser shape: %d streams and %d idle keep-alive connections" % (STREAMS, RESERVE))
holds, idle = fill_browser_shape()
code, head, _ = get("/health")
if OFF:
    if code == 200:
        fail("with M0_RECLAIM=0 the health path was answered on a full loop: the probe cannot see the mechanism")
    print("M0_RECLAIM=0: the health path on a full loop read %r" % head[-20:])
    print("reclaim_probe OK (off)")
    sys.exit(0)
if code != 200:
    fail("the health path read %r on a loop full of streams and idle connections" % head[:120])
got, closed = ended(idle[0])
if not closed:
    fail("the longest idle connection was not taken back for the health check")
if got:
    fail("an idle connection taken back was sent %r" % got[:120])
for s in idle[1:]:
    if not still_open(s):
        fail("an idle connection that was not the longest idle was closed")
# The health check's slot is free again; fill it, and the next connection
# takes the next longest idle.
idle.append(idle_keepalive())
code, head, body = get("/plain")
if code != 200 or body != b"ok\n":
    fail("an ordinary request read %r on a full loop" % head[:120])
if not ended(idle[1])[1]:
    fail("the next longest idle connection was not the next taken")
for s in idle[2:]:
    if not still_open(s):
        fail("a connection idle for less time was taken first")
code, head, body = get("/__metrics")
text = body.decode("latin-1")
held = metric(text, "http_streams_held")
taken = metric(text, "http_connections_reclaimed_total")
refused = metric(text, "http_connections_refused_total")
if held != STREAMS:
    fail("%d streams held after the reclaims, wanted %d: a stream was taken" % (held, STREAMS))
if taken != 2 or refused != 0:
    fail("/__metrics counts %d taken back and %d refused, wanted 2 and 0" % (taken, refused))
print("health 200 and plain 200 on a full loop; two idle connections taken, oldest first; %d streams held" % held)
for s in holds + idle:
    s.close()
# Every slot free again before the next phase counts: the server has seen
# each close when the only connection it holds is the one asking.
deadline = time.monotonic() + 10
while True:
    code, head, body = get("/__metrics")
    if metric(body.decode("latin-1"), "http_active_connections") == 1:
        break
    if time.monotonic() > deadline:
        fail("the server still held connections 10 s after the clients closed them")
    time.sleep(0.1)

phase("%d connections that say nothing" % N)
silent = [connect() for _ in range(N)]
code, head, _ = get("/health")
if code == 200:
    fail("a connection was admitted by taking back one that had been silent for under a second")
time.sleep(FLOOR_S + 0.3)
code, head, _ = get("/health")
if code != 200:
    fail("the health path read %r once the silent connections were past a second" % head[:120])
got, closed = ended(silent[0])
if not closed or not got.startswith(b"HTTP/1.1 408 "):
    fail("the oldest silent connection was not answered 408 and closed: %r, closed=%s" % (got[:120], closed))
for s in silent[1:]:
    if not still_open(s):
        fail("a silent connection newer than the oldest was closed")
code, head, body = get("/__metrics")
text = body.decode("latin-1")
taken = metric(text, "http_connections_reclaimed_total")
refused = metric(text, "http_connections_refused_total")
if taken != 3 or refused != 1:
    fail("/__metrics counts %d taken back and %d refused, wanted 3 and 1" % (taken, refused))
print("refused while every head was under a second; then the oldest answered 408 and the health path 200")
for s in silent:
    s.close()
print("reclaim_probe OK")
