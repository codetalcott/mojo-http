#!/usr/bin/env python3
"""Streams take a loop's slots up to its reserve, and the rest still answers.

A held stream keeps its slot until its client leaves, and before SPEC C20 a
loop let streams take every slot: once they had, each new connection was
reset at accept -- the next stream, an ordinary request, and the health
check a load balancer reads, so a server full of streams was marked dead at
the moment it was busiest. Measured on m0serve 1.16.0's quickstart: 1024
holds took the loop's 1024 slots and the 1025th connection, `/health`
among them, read a reset.

Against `m0serve scripts/smoke/hold_app.py --realtime --max-connections N
--health-path /health --metrics`, started under a soft descriptor limit far
below N (SPEC C21, which the server must raise before any of this can
hold), the probe holds N SSE streams at once and expects:

- `N - reserve` held (200) and the rest answered 503 with `Retry-After`
  and closed, where `reserve = min(16, N // 16)`;
- while they are held: the health path answered 200 in the server, an
  ordinary request answered 200 by the application, and a WebSocket the
  application approves answered 503 too;
- `/__metrics` counting the held and the refused;
- ten streams leaving, then ten more held: the count goes back down.

usage: max_connections_probe.py PORT N
"""
import socket
import sys
import time

from probelib import fail, phase, stamp

stamp("max_connections_probe: FAIL")

PORT = int(sys.argv[1])
N = int(sys.argv[2])
RESERVE = min(16, N // 16)
LIMIT = N - RESERVE

HOLD = b"GET /hold HTTP/1.1\r\nHost: x\r\n\r\n"


def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def head_of(s, timeout=5.0):
    """The response head `s` reads, or what it read before EOF/reset."""
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
    line = head.split(b"\r\n", 1)[0]
    parts = line.split(b" ")
    return int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None


def hold_many(count):
    """`count` connections asking for a hold, sent before any is read, as a
    page's tabs reconnecting after a deploy arrive. Answers each one's
    socket and status."""
    socks = [connect() for _ in range(count)]
    for s in socks:
        s.sendall(HOLD)
    out = []
    for s in socks:
        head = head_of(s)
        out.append((s, status_of(head), head))
    return out


def get(path):
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


phase("the stream share fills")
answers = hold_many(N)
held = [a for a in answers if a[1] == 200]
refused = [a for a in answers if a[1] == 503]
other = [a for a in answers if a[1] not in (200, 503)]
if other:
    fail("%d of %d hold requests read neither 200 nor 503; first: %r"
         % (len(other), N, other[0][2][:120]))
if len(held) != LIMIT or len(refused) != RESERVE:
    fail("%d held and %d refused of %d, wanted %d and %d (reserve %d)"
         % (len(held), len(refused), N, LIMIT, RESERVE, RESERVE))
for s, _, head in refused:
    low = head.lower()
    if b"\r\nretry-after: 5\r\n" not in low:
        fail("a refused stream's 503 carries no Retry-After: %r" % head[:200])
    if b"\r\nconnection: close\r\n" not in low:
        fail("a refused stream's 503 does not close: %r" % head[:200])
    s.close()
print("held %d, refused %d with 503 (reserve %d)" % (len(held), len(refused), RESERVE))

phase("the reserve answers while streams are full")
code, head, body = get("/health")
if code != 200:
    fail("the health path read %r while streams were full" % head[:120])
code, head, body = get("/plain")
if code != 200 or body != b"ok\n":
    fail("an ordinary request read %r while streams were full" % head[:120])
ws = connect()
ws.sendall(
    b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
)
head = head_of(ws)
if status_of(head) != 503:
    fail("a WebSocket past the stream share read %r, wanted 503" % head[:120])
ws.close()
print("health 200, plain 200, websocket 503")

phase("the metrics count them")
code, head, body = get("/__metrics")
text = body.decode("latin-1")
if "\nhttp_streams_held %d\n" % LIMIT not in text:
    fail("/__metrics does not say %d streams held:\n%s" % (LIMIT, text))
if "\nhttp_streams_refused_total %d\n" % (RESERVE + 1) not in text:
    fail("/__metrics does not say %d refused:\n%s" % (RESERVE + 1, text))

phase("a stream that leaves gives its place back")
for s, _, _ in held[:10]:
    s.close()
time.sleep(0.5)
again = hold_many(10)
if [a[1] for a in again] != [200] * 10:
    fail("after ten streams left, ten more read %r" % [a[1] for a in again])
one_more = hold_many(1)
if one_more[0][1] != 503:
    fail("the share refilled, and one more read %r" % one_more[0][2][:120])
for s, _, _ in held[10:] + again + one_more:
    s.close()
print("ten left, ten held again, the next refused")
print("max_connections_probe OK")
