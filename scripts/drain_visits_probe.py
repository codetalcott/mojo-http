#!/usr/bin/env python3
"""A pass drains the streams that have something to send, not every stream it
holds (SPEC C24).

m0serve's handler names its streams with output (`take_ready_streams`), so
the loop asks it for a stream's bytes (`sse_drain_slot`, counted by
`/__metrics` as `http_stream_drain_visits_total`) only for those. Before,
every pass asked for every held stream: 1008 idle streams cost a loop 12%
of its requests a second and 4000 cost 57%, idle all.

Against `m0serve scripts/smoke/hold_app.py --realtime --max-connections N
--health-path /health --metrics`, the probe holds `STREAMS` idle streams on
channel `c` and expects:

- 200 ordinary requests while they are held to cost almost no visits: the
  sweep made one per stream per pass, at least `STREAMS * 200`;
- one publish to `c` to reach every stream, and to cost a visit per stream,
  at most two (a frame that waits on writability is visited again as it
  lands), not one per stream per pass;
- a stream whose client stops reading to be sent, once it reads again,
  what was queued for it while its last frame waited -- with nothing
  published after: fifty 20 KB frames fill its socket, leave one going out
  and three in its outbox, and the rest are refused at the outbox's cap;
  a last `data: end` fits beside the three and finds the slot busy. Only
  the frame's landing names the slot to the drain then (`_stream_idle`),
  and the next heartbeat is 15 s off.

usage: drain_visits_probe.py PORT STREAMS
"""
import socket
import sys
import time

from probelib import fail, phase, stamp

stamp("drain_visits_probe: FAIL")

PORT = int(sys.argv[1])
STREAMS = int(sys.argv[2])
REQUESTS = 200
HOLD = b"GET /hold HTTP/1.1\r\nHost: x\r\n\r\n"


def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def head_of(s, timeout=5.0):
    s.settimeout(timeout)
    got = b""
    deadline = time.monotonic() + timeout
    while b"\r\n\r\n" not in got and time.monotonic() < deadline:
        try:
            chunk = s.recv(4096)
        except (ConnectionResetError, socket.timeout):
            break
        if not chunk:
            break
        got += chunk
    return got


def get(path):
    s = connect()
    s.sendall(b"GET " + path.encode() + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    data = b""
    s.settimeout(5)
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    except (socket.timeout, ConnectionResetError):
        pass
    s.close()
    head, _, body = data.partition(b"\r\n\r\n")
    parts = head.split(b"\r\n", 1)[0].split(b" ")
    code = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
    return code, body


def visits():
    code, body = get("/__metrics")
    for line in body.decode("latin-1").splitlines():
        if line.startswith("http_stream_drain_visits_total "):
            return int(line.split()[1])
    fail("/__metrics has no http_stream_drain_visits_total:\n%s" % body[:400])


phase("%d idle streams" % STREAMS)
holds = []
for _ in range(STREAMS):
    s = connect()
    s.sendall(HOLD)
    holds.append(s)
for s in holds:
    head = head_of(s)
    if not head.startswith(b"HTTP/1.1 200 "):
        fail("a hold read %r" % head[:120])
# What a hold's head carries is drained as it opens; wait for those visits.
time.sleep(0.3)
before = visits()

phase("%d requests beside them" % REQUESTS)
for _ in range(REQUESTS):
    code, body = get("/plain")
    if code != 200 or body != b"ok\n":
        fail("an ordinary request read %r %r" % (code, body[:60]))
quiet = visits() - before
if quiet > STREAMS // 4:
    fail("%d requests beside %d idle streams cost %d drain visits; nothing had output, and the"
         " sweep this replaced costs at least %d" % (REQUESTS, STREAMS, quiet, REQUESTS * STREAMS))
print("%d requests beside %d idle streams: %d drain visits" % (REQUESTS, STREAMS, quiet))

phase("a publish to every stream")
before = visits()
code, body = get("/publish")
if code != 200:
    fail("the publish read %r %r" % (code, body[:120]))
want = b"data: drained\n\n"
for i, s in enumerate(holds):
    s.settimeout(5)
    got = b""
    deadline = time.monotonic() + 5
    while want not in got and time.monotonic() < deadline:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        got += chunk
    if want not in got:
        fail("stream %d of %d never received the publish: %r" % (i, STREAMS, got[-120:]))
time.sleep(0.3)
published = visits() - before
if published < STREAMS or published > 2 * STREAMS + STREAMS // 4:
    fail("a publish to %d streams cost %d drain visits, wanted one or two a stream" % (STREAMS, published))
print("a publish reached all %d streams for %d drain visits" % (STREAMS, published))
for s in holds:
    s.close()
time.sleep(0.5)

phase("a stream that stalls, then reads")
slow = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
slow.connect(("127.0.0.1", PORT))
slow.sendall(HOLD)
head = head_of(slow)
if not head.startswith(b"HTTP/1.1 200 "):
    fail("the stalling hold read %r" % head[:120])
for _ in range(50):
    code, body = get("/publish?fill=20000")
    if code != 200:
        fail("a fill publish read %r %r" % (code, body[:120]))
time.sleep(0.3)
code, body = get("/publish?end=1")
if code != 200:
    fail("the end publish read %r %r" % (code, body[:120]))
time.sleep(0.3)
got = b""
slow.settimeout(1)
deadline = time.monotonic() + 8
while b"data: end\n\n" not in got and time.monotonic() < deadline:
    try:
        chunk = slow.recv(65536)
    except socket.timeout:
        continue
    if not chunk:
        break
    got += chunk
slow.close()
if b"data: end\n\n" not in got:
    fail("a stream that stalled and read again was not sent what was queued while its frame"
         " waited: %d bytes, the last %r" % (len(got), got[-60:]))
print("a stalled stream read again and was sent what waited: %d bytes, ending in data: end" % len(got))
print("drain_visits_probe OK")
