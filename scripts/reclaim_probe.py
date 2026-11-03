#!/usr/bin/env python3
"""A full loop takes a slot back for a new connection (SPEC C23).

When every one of a loop's slots is in use, a new connection gets one from
a connection a deadline is already counting down: the one between requests
idle longest, once that is a second, else the one whose head has been
arriving longest, once that is a second. Before, the new connection was
closed unread and its client read a reset. Measured on 1.17.0's tree: 1008 streams beside 16 idle
keep-alive connections -- the page loads of the tabs holding them -- reset
the health check, and 1024 idle keep-alive connections from one client
reset every connection for the 60 s of their idle timeout.

Against `m0serve scripts/smoke/hold_app.py --realtime --max-connections N
--health-path /health --metrics`, `reserve = min(16, N // 16)`:

- the browser shape: `N - reserve` held streams and `reserve` idle
  keep-alive connections fill the loop; the health path is refused while
  the idle connections have been idle under a second, then answered, the
  idle connections taken back oldest first, one per connection that finds
  the loop full, and every stream still held;
- `N` connections that say nothing fill it: a new one is refused while they
  are younger than a second, and served once they are older, the oldest of
  them answered 408 and closed;
- `N` busy keep-alive clients, each asking again as soon as it is answered,
  fill it while new connections keep arriving: every newcomer is refused
  and no busy client loses a request (the review finding of 2026-11-02:
  with no idle floor each newcomer closed the busy connection answered
  longest ago, over the next request already in its socket);
- `/__metrics` counting all three.

With `--off` (the server under `M0_RECLAIM=0`) the browser shape, its idle
connections past a second, resets the health path, as before: the probe
sees the mechanism, not luck. With `--no-idle-timeout` (the server under
`--idle-timeout 0`) it does too, every idle connection kept: no deadline
counts them down.

usage: reclaim_probe.py PORT N [--off | --no-idle-timeout]
"""
import threading
import socket
import sys
import time

from probelib import fail, phase, stamp

stamp("reclaim_probe: FAIL")

PORT = int(sys.argv[1])
N = int(sys.argv[2])
OFF = "--off" in sys.argv[3:]
NO_IDLE_TIMEOUT = "--no-idle-timeout" in sys.argv[3:]
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
    try:
        s.sendall(b"GET " + path.encode() + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    except OSError:
        # Refused before the request was out: the reset arrived first.
        s.close()
        return None, b"<reset>", b""
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
        chunk = s.recv(4096)
        if not chunk:
            fail("a keep-alive connection under the limit was closed before its body: %r" % head[:120])
        head += chunk
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
if OFF or NO_IDLE_TIMEOUT:
    # Past the floor, so a refusal is the switch's and not the floor's.
    time.sleep(FLOOR_S + 0.3)
    code, head, _ = get("/health")
    why = "M0_RECLAIM=0" if OFF else "--idle-timeout 0"
    if code == 200:
        fail("with %s the health path was answered on a full loop: the probe cannot see the mechanism" % why)
    for s in idle:
        if not still_open(s):
            fail("with %s an idle connection was closed" % why)
    print("%s: the health path on a full loop read %r; every idle connection kept" % (why, head[-20:]))
    print("reclaim_probe OK (%s)" % ("off" if OFF else "no idle timeout"))
    sys.exit(0)
code, head, _ = get("/health")
if code == 200:
    fail("a connection was admitted by taking back one idle for under a second")
for s in idle:
    if not still_open(s):
        fail("an idle connection answered under a second ago was closed")
time.sleep(FLOOR_S + 0.3)
code, head, _ = get("/health")
if code != 200:
    fail("the health path read %r on a loop full of streams and connections idle past a second" % head[:120])
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
if taken != 2 or refused != 1:
    fail("/__metrics counts %d taken back and %d refused, wanted 2 and 1" % (taken, refused))
print("health refused while the idle connections were under a second, then 200, and plain 200, on a full loop;"
      " two idle connections taken, oldest first; %d streams held" % held)
for s in holds + idle:
    s.close()


def drained():
    """Every slot free again before the next phase counts: the server has
    seen each close when the only connection it holds is the one asking."""
    deadline = time.monotonic() + 10
    while True:
        code, head, body = get("/__metrics")
        if metric(body.decode("latin-1"), "http_active_connections") == 1:
            return
        if time.monotonic() > deadline:
            fail("the server still held connections 10 s after the clients closed them")
        time.sleep(0.1)


drained()

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
if taken != 3 or refused != 2:
    fail("/__metrics counts %d taken back and %d refused, wanted 3 and 2" % (taken, refused))
print("refused while every head was under a second; then the oldest answered 408 and the health path 200")
for s in silent:
    s.close()
drained()

phase("%d busy keep-alive clients while new connections arrive" % N)
BUSY_S = 1.5
# Each client asks again PACE_S after its answer: never idle near the
# second a connection must be idle to be taken, and about 300 requests in
# BUSY_S, well under the keep-alive cap (1000), whose close is not a loss.
PACE_S = 0.005


def response(s):
    """One whole response on `s`: its status, or None at an EOF or a reset."""
    got = b""
    try:
        while b"\r\n\r\n" not in got:
            chunk = s.recv(4096)
            if not chunk:
                return None
            got += chunk
        head, body = got.split(b"\r\n\r\n", 1)
        length = 0
        for line in head.split(b"\r\n")[1:]:
            name, _, value = line.partition(b":")
            if name.strip().lower() == b"content-length":
                length = int(value.strip())
        while len(body) < length:
            chunk = s.recv(4096)
            if not chunk:
                return None
            body += chunk
    except (ConnectionResetError, socket.timeout, OSError):
        return None
    return status_of(head)


busy = []
for _ in range(N):
    s = connect()
    s.sendall(PLAIN)
    if response(s) != 200:
        fail("a busy client's first request under the limit was not answered")
    busy.append(s)
stop = threading.Event()
lost = []
asked = [0] * N


def keep_asking(i):
    s = busy[i]
    while not stop.is_set():
        try:
            s.sendall(PLAIN)
        except OSError as e:
            lost.append("client %d could not send: %r" % (i, e))
            return
        if response(s) != 200:
            lost.append("client %d lost a request after %d answered" % (i, asked[i]))
            return
        asked[i] += 1
        time.sleep(PACE_S)


threads = [threading.Thread(target=keep_asking, args=(i,)) for i in range(N)]
for th in threads:
    th.start()
newcomers = 0
admitted = 0
end = time.monotonic() + BUSY_S
while time.monotonic() < end and not lost:
    code, head, _ = get("/health")
    newcomers += 1
    if code == 200:
        admitted += 1
    time.sleep(0.02)
stop.set()
for th in threads:
    th.join(10)
if lost:
    fail("a busy keep-alive client lost a request to a new connection: %s" % lost[0])
if admitted:
    fail("%d of %d new connections were admitted to a loop of busy clients" % (admitted, newcomers))
if min(asked) == 0:
    fail("a busy client was never answered again while the newcomers arrived")
for s in busy:
    s.close()
drained()
code, head, body = get("/__metrics")
text = body.decode("latin-1")
taken = metric(text, "http_connections_reclaimed_total")
refused = metric(text, "http_connections_refused_total")
if taken != 3 or refused != 2 + newcomers:
    fail("/__metrics counts %d taken back and %d refused, wanted 3 and %d" % (taken, refused, 2 + newcomers))
print("%d busy clients asked %d times beside %d newcomers, every newcomer refused and no request lost"
      % (N, sum(asked), newcomers))
print("reclaim_probe OK")
