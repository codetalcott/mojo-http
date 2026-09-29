#!/usr/bin/env python3
"""Raw RFC 6455 client for smoke-django-realtime-ws — stdlib only.

What it proves, in one process because the assertions are about one
connection's lifetime:

  * Django refuses an unauthorised upgrade. The reply is Django's own 403 on
    the wire — no 101, no hold, nothing registered.
  * An authorised upgrade produces a real handshake: 101 with a correct
    `Sec-WebSocket-Accept`, which Django could not have computed.
  * A message sent on a socket reaches a synchronous view, which
    republishes it — so every subscriber of the channel hears it, the sender
    included.
  * Channels isolate: a socket on another channel hears nothing.

`REALTIME_EXPECT_WORKERS=2` switches to the cross-worker shape: one socket on
EACH worker (the X-Worker header on each 101 says who owns it), then ONE
`POST /publish` handled by a sync view must reach both — the far one over the
BroadcastBus.

Modelled on `apps/ws_chat/chat_probe.py`, which pins the same accept-race
problem the same way; see its comments for why SIGSTOP rather than retries.
"""

import http.client
import json
import os
import signal
import socket
import struct
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import BINARY, CLOSE, PING, TEXT, WebSocket, fail, phase, stamp  # noqa: E402

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))
TOKEN = "letmein"
EXPECT_WORKERS = int(os.environ.get("REALTIME_EXPECT_WORKERS", "1"))
# The quickstart's views take no token, by design (its auth is the reader's
# own); smoke-flask-realtime drives THOSE views and skips the gate phase.
GATED = os.environ.get("REALTIME_GATED", "1") == "1"


# Which phase is running, for the crash handler. The phases are already
# named in the comments; this puts the name in the FAILURE, which is where
# it is needed. Every one of them reaches the socket through the same frame
# reads, so a traceback out of those says which CALL raised and never which
# PHASE was being proven -- two investigations of the 2026-08-30 CI failure
# were lost to that distinction, and apps/asgi_bare/ws_probe.py carries the
# original of this comment.
stamp("realtime_probe FAIL")


def read_text(ws, timeout=8.0):
    """Next text frame's payload; heartbeat pings get pongs and are skipped.

    One deadline for the whole read: a per-read timeout is reset by every
    heartbeat, which is why this used to give up after twenty pings."""
    op, payload = ws.recv_data(deadline=time.monotonic() + timeout)
    if op != TEXT:
        fail("unexpected frame op=%d while waiting for text" % op)
    return payload


def expect_silence(ws, seconds=2.0):
    """Assert nothing but heartbeats arrives — the channel-isolation check.

    Bounded by a deadline rather than by the socket timeout alone: heartbeat
    pings arrive faster than any timeout worth waiting, so a loop that only
    resets on recv would answer pings forever.
    """
    try:
        op, payload = ws.recv_data(deadline=time.monotonic() + seconds)
    except socket.timeout:
        return
    fail("socket heard op=%d %r on a channel it never joined" % (op, payload))


def handshake(channel, token=TOKEN):
    """Open one socket and return (WebSocket, worker) — or (None, status, body).

    Nothing here is Mojo-aware: it is the opening handshake exactly as a
    browser sends it, which is the point. The framework sees a normal GET.
    """
    query = {"channel": channel}
    if token is not None:
        query["token"] = token
    ws = WebSocket.connect(HOST, PORT, "/ws?" + urllib.parse.urlencode(query), timeout=10)
    if ws.status_line is None:
        fail("connection closed during handshake")
    status = ws.status_line.decode("latin-1")
    if " 101 " not in status + " ":
        ws.close()
        return None, status, bytes(ws.buf)

    for line in ws.head.decode("latin-1").split("\r\n")[1:]:
        low = line.lower()
        if low.startswith("m0-hold:") or low.startswith("m0-channel:"):
            fail("instruction header leaked to the client: " + line)
    if not ws.accept_ok():
        fail("bad accept key — the handshake was not really performed")
    worker = ws.header("X-Worker")
    if worker is None:
        fail("no X-Worker header on the upgrade response")
    return ws, worker


def expect_end(ws, within=5.0, skip_close=False):
    """EOF from the server, with nothing before it but heartbeat pings (and,
    when `skip_close`, the server's own Close, which this client leaves
    unanswered). A reset at a frame's boundary is an end too; the connection
    ending INSIDE a frame is not."""
    deadline = time.monotonic() + within
    while True:
        try:
            op, payload = ws.recv_frame(deadline=deadline, eof_ok=True)
        except socket.timeout:
            break
        except EOFError as exc:
            if ws.buf:
                fail(str(exc))
            ws.close()
            return
        except ConnectionResetError:
            if ws.buf:
                raise
            ws.close()
            return
        if op == PING or op == TEXT or (op == CLOSE and skip_close):
            skip_close = False if op == CLOSE else skip_close
            continue
        fail("after the closing handshake the server sent op=%d" % op)
    fail("the connection was still open %.0f s after the closing handshake" % within)


def open_socket(channel):
    """`handshake` for a phase that expects the 101; a refusal names itself.

    Unpacking `handshake`'s three-tuple refusal into two names raised
    `ValueError('too many values to unpack')`, which said nothing about the
    status the server actually answered.
    """
    opened = handshake(channel)
    if opened[0] is None:
        fail("upgrade refused: %s %r" % (opened[1], opened[2][:120]))
    return opened[0], opened[1]


def publish(channel, msg):
    """POST /publish, handled by a synchronous view. Returns the parsed JSON.

    Parsed rather than grepped: Django's JsonResponse spaces after the colon
    and Flask's jsonify does not, and a byte pattern that fits one framework
    silently fails the other.
    """
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
    try:
        return json.loads(text)
    except ValueError:
        fail("publish did not answer JSON: %r" % text)


def close_all(sockets):
    for ws in sockets:
        try:
            ws.send_close(1000)
            ws.close()
        except OSError:
            pass


# --- Phase 1: Django gates the upgrade ---------------------------------------
# The refusal is the load-bearing assertion. Django ran, decided no, and its
# ordinary 403 reached the wire — the Mojo layer performs an upgrade only for
# a response that asked for one.

if GATED:
    phase("phase 1: Django gating the upgrade")
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
    phase("phase 2: an authorised upgrade, and a message reaching a sync view")
    sock_a, worker_a = open_socket("news")
    sock_b, _ = open_socket("news")
    sock_other, _ = open_socket("other")

    msg = b"hello from a websocket"
    sock_a.send(TEXT, msg)

    # The trip: ws_message -> ws_message_request -> POST /ws/message -> a plain
    # synchronous view -> m0pub.publish -> the bus -> both sockets. Nothing
    # but the application decided what to do with the message.
    for name, sock in (("sender", sock_a), ("second", sock_b)):
        got = read_text(sock)
        if got != msg:
            fail("%s socket heard %r, wanted %r" % (name, got, msg))

    # A different channel must hear none of it.
    expect_silence(sock_other)

    # --- Phase 3: a Django publish reaches sockets too -----------------------
    phase("phase 3: a publish from a view reaching sockets")
    publish("news", "hello from publish")
    got = read_text(sock_a)
    if got != b"hello from publish":
        fail("socket heard %r, wanted the published message" % got)
    expect_silence(sock_other)

    # --- Phase 4: a message the pool's channel cannot carry -------------------
    # Inbound messages reach a pool thread as datagrams of at most 65,546
    # bytes. A larger one used to be parked and retried for ever: no reply,
    # no close, no log. It is refused with a Close carrying 1009 (SPEC I26).
    phase("phase 4: an inbound message the channel cannot carry")
    sock_listen, _ = open_socket("news")
    sock_big, _ = open_socket("news")
    # A message right behind the oversized one: RFC 6455 §7.1.7, nothing
    # is processed after the connection is failed, so the channel's other
    # socket must hear none of it.
    sock_big.send(BINARY, b"o" * 70000)
    sock_big.send(TEXT, b"after-the-refused-one")
    # Heartbeat pings are answered and the channel's own text skipped, for
    # up to five seconds; anything else is the answer.
    deadline = time.monotonic() + 5.0
    while True:
        try:
            op, payload = sock_big.recv_data(deadline=deadline)
        except socket.timeout:
            op = None
            break
        if op != TEXT:
            break
    if op is None:
        fail("no answer but heartbeats to a 70,000-byte message in 5 s: parked, not refused")
    if op != CLOSE:
        fail("a 70,000-byte message was answered with op=%d, not a Close" % op)
    code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
    if code != 1009:
        fail("the Close carried %r, want 1009" % code)
    # The client answers the Close, as a browser does: the server must end
    # the connection, with no second Close -- which Chromium reports as a
    # failed connection (1006), not the 1009 it was sent.
    sock_big.send_close(1009)
    expect_end(sock_big)
    expect_silence(sock_listen)
    # And a client that never answers is let go when the linger runs out.
    sock_quiet, _ = open_socket("news")
    sock_quiet.send(BINARY, b"o" * 70000)
    expect_end(sock_quiet, within=8.0, skip_close=True)
    close_all([sock_listen])

    close_all([sock_a, sock_b, sock_other])
    print("realtime_probe OK (single worker, worker %s)" % worker_a)
    sys.exit(0)

# --- Multi-worker: one socket per worker, then one publish reaches both -------
# Which worker wins an accept is the kernel's choice and it is not a fair one;
# see chat_probe.py. Open one socket, SIGSTOP the worker that got it (X-Worker
# is that worker's pid), open the second, resume immediately.
phase("landing one socket on each worker (the second under SIGSTOP)")
sock_a, w_a = open_socket("news")
os.kill(int(w_a), signal.SIGSTOP)
try:
    sock_b, w_b = open_socket("news")
finally:
    os.kill(int(w_a), signal.SIGCONT)

conns = [(sock_a, w_a), (sock_b, w_b)]
if w_a == w_b:
    close_all([s for s, _ in conns])
    fail("both sockets landed on worker %s even though it was SIGSTOPped" % w_a)

# ONE publish, handled by a sync view on whichever worker took the POST.
phase("one publish reaching both workers")
body = publish("news", "cross-worker-ws")
if body.get("workers") != 2:
    fail("publish did not reach both worker channels: %r" % (body,))

for sock, worker in conns:
    got = read_text(sock)
    if got != b"cross-worker-ws":
        fail("socket on worker %s heard %r" % (worker, got))

# And a message SENT on one worker's socket reaches the other worker's too:
# ws_message -> the view -> m0pub -> every channel -> every worker's registry.
phase("a message sent on one worker reaching the other")
sock_a.send(TEXT, b"cross-worker-msg")
for sock, worker in conns:
    got = read_text(sock)
    if got != b"cross-worker-msg":
        fail("socket on worker %s heard %r, wanted the relayed message" % (worker, got))

close_all([s for s, _ in conns])
print("realtime_probe OK (2 sockets across workers %s and %s)" % (w_a, w_b))
