#!/usr/bin/env python3
"""Raw RFC 6455 client for smoke-django-realtime-ws — stdlib only.

What it proves, in one process because the assertions are about one
connection's lifetime:

  * Django refuses an unauthorised upgrade. The reply is Django's own 403 on
    the wire — no 101, no hold, nothing registered.
  * An authorised upgrade produces a real handshake: 101 with a correct
    `Sec-WebSocket-Accept`, which Django could not have computed.
  * A message sent on a socket reaches a synchronous Django view, which
    republishes it — so every subscriber of the channel hears it, the sender
    included.
  * Channels isolate: a socket on another channel hears nothing.

`REALTIME_EXPECT_WORKERS=2` switches to the cross-worker shape: one socket on
EACH worker (the X-Worker header on each 101 says who owns it), then ONE
`POST /publish` handled by sync Django must reach both — the far one over the
BroadcastBus.

Modelled on `apps/ws_chat/chat_probe.py`, which pins the same accept-race
problem the same way; see its comments for why SIGSTOP rather than retries.
"""

import base64
import hashlib
import http.client
import os
import signal
import socket
import struct
import sys
import time
import urllib.parse

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TOKEN = "letmein"
EXPECT_WORKERS = int(os.environ.get("REALTIME_EXPECT_WORKERS", "1"))


def fail(msg):
    print("realtime_probe FAIL:", msg)
    sys.exit(1)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            fail("connection closed wanting %d bytes" % n)
        buf += chunk
    return buf


def read_frame(sock):
    hdr = recv_exact(sock, 2)
    b0, b1 = hdr[0], hdr[1]
    if b1 & 0x80:
        fail("server frame is masked")
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(sock, 8))[0]
    return b0 & 0x0F, recv_exact(sock, ln)


def send_frame(sock, opcode, payload, fin=True):
    b0 = (0x80 if fin else 0) | opcode
    mask = os.urandom(4)
    n = len(payload)
    header = bytes([b0])
    if n <= 125:
        header += bytes([0x80 | n])
    elif n <= 0xFFFF:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    sock.sendall(header + mask + masked)


def read_text(sock, timeout=8.0):
    """Next text frame's payload; heartbeat pings get pongs and are skipped."""
    sock.settimeout(timeout)
    for _ in range(20):
        op, payload = read_frame(sock)
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        if op == 0x1:
            return payload
        fail("unexpected frame op=%d while waiting for text" % op)
    fail("only pings arriving; the message never came")


def expect_silence(sock, seconds=2.0):
    """Assert nothing but heartbeats arrives — the channel-isolation check.

    Bounded by a deadline rather than by the socket timeout alone: heartbeat
    pings arrive faster than any timeout worth waiting, so a loop that only
    resets on recv would answer pings forever.
    """
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        sock.settimeout(remaining)
        try:
            op, payload = read_frame(sock)
        except (socket.timeout, TimeoutError):
            return
        if op == 0x9:
            send_frame(sock, 0xA, payload)
            continue
        fail("socket heard op=%d %r on a channel it never joined" % (op, payload))


def handshake(channel, token=TOKEN):
    """Open one socket and return (socket, worker) — or (None, status, body).

    Nothing here is Mojo-aware: it is the opening handshake exactly as a
    browser sends it, which is the point. Django sees a normal GET.
    """
    query = {"channel": channel}
    if token is not None:
        query["token"] = token
    target = "/ws?" + urllib.parse.urlencode(query)
    sock = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET %s HTTP/1.1\r\nHost: %s:%d\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
            % (target, HOST, PORT, key)
        ).encode()
    )
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            fail("connection closed during handshake")
        resp += chunk
    head, _, rest = resp.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    status = lines[0]
    if " 101 " not in status + " ":
        sock.close()
        return None, status, rest

    accept = worker = None
    for line in lines[1:]:
        low = line.lower()
        if low.startswith("sec-websocket-accept:"):
            accept = line.split(":", 1)[1].strip()
        if low.startswith("x-worker:"):
            worker = line.split(":", 1)[1].strip()
        if low.startswith("m0-hold:") or low.startswith("m0-channel:"):
            fail("instruction header leaked to the client: " + line)
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if accept != expected:
        fail("bad accept key — the handshake was not really performed")
    if worker is None:
        fail("no X-Worker header on the upgrade response")
    return sock, worker


def publish(channel, msg):
    """POST /publish, handled by synchronous Django. Returns the body."""
    conn = http.client.HTTPConnection(HOST, PORT, timeout=10)
    body = urllib.parse.urlencode({"channel": channel, "msg": msg})
    conn.request(
        "POST", "/publish", body,
        {"Content-Type": "application/x-www-form-urlencoded"},
    )
    resp = conn.getresponse()
    text = resp.read().decode()
    conn.close()
    if resp.status != 200:
        fail("publish returned %d: %s" % (resp.status, text))
    return text


def close_all(socks):
    for s in socks:
        try:
            send_frame(s, 0x8, struct.pack(">H", 1000))
            s.close()
        except OSError:
            pass


# --- Phase 1: Django gates the upgrade ---------------------------------------
# The refusal is the load-bearing assertion. Django ran, decided no, and its
# ordinary 403 reached the wire — the Mojo layer performs an upgrade only for
# a response that asked for one.

rejected = handshake("news", token=None)
if rejected[0] is not None:
    close_all([rejected[0]])
    fail("an unauthorised upgrade was accepted")
if " 403 " not in rejected[1] + " ":
    fail("expected Django's 403 for an unauthorised upgrade, got: " + rejected[1])
if b"forbidden" not in rejected[2]:
    fail("403 did not carry Django's body: %r" % rejected[2])

if EXPECT_WORKERS <= 1:
    # --- Phase 2: authorised, and a message reaches a Django view ------------
    sock_a, worker_a = handshake("news")
    sock_b, _ = handshake("news")
    sock_other, _ = handshake("other")

    msg = b"hello from a websocket"
    send_frame(sock_a, 0x1, msg)

    # The trip: ws_message -> ws_message_request -> POST /ws/message -> a plain
    # synchronous Django view -> m0pub.publish -> the bus -> both sockets.
    # Nothing but Django decided what to do with the message.
    for name, sock in (("sender", sock_a), ("second", sock_b)):
        got = read_text(sock)
        if got != msg:
            fail("%s socket heard %r, wanted %r" % (name, got, msg))

    # A different channel must hear none of it.
    expect_silence(sock_other)

    # --- Phase 3: a Django publish reaches sockets too -----------------------
    publish("news", "hello from publish")
    got = read_text(sock_a)
    if got != b"hello from publish":
        fail("socket heard %r, wanted the published message" % got)
    expect_silence(sock_other)

    close_all([sock_a, sock_b, sock_other])
    print("realtime_probe OK (single worker, worker %s)" % worker_a)
    sys.exit(0)

# --- Multi-worker: one socket per worker, then one publish reaches both -------
# Which worker wins an accept is the kernel's choice and it is not a fair one;
# see chat_probe.py. Open one socket, SIGSTOP the worker that got it (X-Worker
# is that worker's pid), open the second, resume immediately.
sock_a, w_a = handshake("news")
os.kill(int(w_a), signal.SIGSTOP)
try:
    sock_b, w_b = handshake("news")
finally:
    os.kill(int(w_a), signal.SIGCONT)

conns = [(sock_a, w_a), (sock_b, w_b)]
if w_a == w_b:
    close_all([s for s, _ in conns])
    fail("both sockets landed on worker %s even though it was SIGSTOPped" % w_a)

# ONE publish, handled by sync Django on whichever worker took the POST.
body = publish("news", "cross-worker-ws")
if '"workers": 2' not in body:
    fail("publish did not reach both worker channels: " + body)

for sock, worker in conns:
    got = read_text(sock)
    if got != b"cross-worker-ws":
        fail("socket on worker %s heard %r" % (worker, got))

# And a message SENT on one worker's socket reaches the other worker's too:
# ws_message -> Django -> m0pub -> every channel -> every worker's registry.
send_frame(sock_a, 0x1, b"cross-worker-msg")
for sock, worker in conns:
    got = read_text(sock)
    if got != b"cross-worker-msg":
        fail("socket on worker %s heard %r, wanted the relayed message" % (worker, got))

close_all([s for s, _ in conns])
print("realtime_probe OK (2 sockets across workers %s and %s)" % (w_a, w_b))
