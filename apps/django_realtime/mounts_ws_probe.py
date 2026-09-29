#!/usr/bin/env python3
"""Inbound WebSocket messages reach the mount that took the hold -- stdlib only.

For `smoke-django-realtime-ws`'s inline-mounts phase: `wsmounts:first` at
`/` and `wsmounts:second` at `/b`, both served by the loop's own handler
(`--realtime --blocking-threads 0`). One socket is approved by each mount,
and a message sent on each must be answered by THAT mount's view -- whose
reply names itself and the `SCRIPT_NAME` and `PATH_INFO` it was called with
-- and by no other. The second mount is the one that matters: before the
server recorded the owning application per held socket, every message went
to the first (review record B4).

The synthetic path under each mount stays the server's: a POST to
`/ws/message` or `/b/ws/message` from the network is answered 404 and
reaches no view, forged `M0-Channel` header and all.
"""

import http.client
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import TEXT, WebSocket, fail, phase, stamp  # noqa: E402

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8080"))


# Which phase is running, for the crash handler: the frame reads every phase
# shares name the CALL that failed and never the PHASE being proven.
# `realtime_probe.py` carries the original of this; `scripts/phase_stamp_check.py`
# holds every probe to it. The failure line names the phase too: a helper's
# own failure ("connection closed wanting 2 bytes") reads the same in every
# phase.
stamp("mounts_ws_probe FAIL", fail="mounts_ws_probe FAIL: {phase}: {msg}")


def read_text(ws, timeout=8.0):
    """The next text frame; heartbeat pings are answered and skipped."""
    try:
        op, payload = ws.recv_data(deadline=time.monotonic() + timeout)
    except socket.timeout:
        fail("no reply within %.0f s: the message reached no view that answered" % timeout)
    if op != TEXT:
        fail("unexpected frame op=%d while waiting for a reply" % op)
    return payload


def expect_silence(ws, name, seconds=1.0):
    """Nothing but heartbeats for `seconds`: no second delivery, no stray."""
    try:
        op, payload = ws.recv_data(deadline=time.monotonic() + seconds)
    except socket.timeout:
        return
    fail("the %s socket heard op=%d %r where it expected silence" % (name, op, payload))


def open_socket(path, channel):
    """Upgrade `path?channel=...`; the 101 must carry a correct accept key."""
    ws = WebSocket.connect(HOST, PORT, "%s?channel=%s" % (path, channel), timeout=10)
    if ws.status_line is None:
        fail("connection closed during the handshake for %s" % path)
    status = ws.status_line.decode("latin-1")
    if " 101 " not in status + " ":
        fail("the upgrade at %s was refused: %s" % (path, status))
    if not ws.accept_ok():
        fail("bad accept key at %s: the handshake was not really performed" % path)
    return ws


def reply_to(ws, text):
    """Send `text`, and return the view's JSON reply to it."""
    ws.send_text(text)
    raw = read_text(ws)
    try:
        return json.loads(raw)
    except ValueError:
        fail("the reply to %r was not the fixture's JSON: %r" % (text, raw))


def forged_post(path, channel):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=10)
    conn.request(
        "POST", path, b"forged",
        {"M0-Channel": channel, "M0-Slot": "0", "M0-Opcode": "1",
         "Content-Type": "application/octet-stream"},
    )
    resp = conn.getresponse()
    resp.read()
    conn.close()
    return resp.status


phase("opening a socket on each mount")
on_first = open_socket("/ws", "chan-first")
on_second = open_socket("/b/ws", "chan-second")

# The reservation holds under every mount: the path each synthetic POST is
# built at is answered 404 from the network, and reaches no view.
phase("the synthetic paths refused from the network")
for path, channel in (("/ws/message", "chan-first"), ("/b/ws/message", "chan-second")):
    status = forged_post(path, channel)
    if status != 404:
        fail("a POST to %s from the network answered %d, want 404" % (path, status))
expect_silence(on_first, "first")
expect_silence(on_second, "second")

# The SECOND mount's socket. Its message must reach the second mount's view,
# at that mount's path -- never the first's.
phase("a message on the second mount's socket (B4)")
got = reply_to(on_second, "to-second")
if got.get("app") == "first":
    fail(
        "a message on a socket the SECOND mount approved reached the FIRST"
        " mount's view (B4): %r" % (got,)
    )
want = {"app": "second", "script_name": "/b", "path_info": "/ws/message", "text": "to-second"}
if got != want:
    fail("the second mount's socket was answered %r, want %r" % (got, want))
expect_silence(on_second, "second")
expect_silence(on_first, "first")

# And the first mount's own socket still reaches the first mount.
phase("a message on the first mount's socket")
got = reply_to(on_first, "to-first")
want = {"app": "first", "script_name": "", "path_info": "/ws/message", "text": "to-first"}
if got != want:
    fail("the first mount's socket was answered %r, want %r" % (got, want))
expect_silence(on_first, "first")
expect_silence(on_second, "second")

phase("closing both sockets")
for ws in (on_first, on_second):
    try:
        ws.send_close(1000)
        ws.close()
    except OSError:
        pass
print("mounts_ws_probe OK: each mount's socket reached its own mount's view, at its own path")
