#!/usr/bin/env python3
"""Stdlib WS client for smoke-fastapi.

FastAPI's `@app.websocket` handler takes plain text (FastHTML's `app.ws`
takes a JSON message, which is why that app has a probe of its own), so
this sends `hello` and expects `ws-echo:hello` back, then drives the
app-initiated close through FastAPI's `websocket.close(1000)`.

The bare ASGI probe proves the close ORDER against a hand-written app
(SPEC L15/L16, and its close phase runs 64 at once, which is what caught
the missing linger). This one asks the narrower question the row is for:
that a framework's own close API reaches the same seam.

It is also scripts/phase_stamp_check.py's representative of a probe on
scripts/probelib.py: driven against a listener that hangs, it must name
two different phases.
"""

import os
import socket
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import CLOSE, TEXT, WebSocket, fail, phase, stamp  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8099"))

# Which phase is running, for the crash handler. A traceback names the CALL
# that raised -- the frame read, which every phase shares -- and never the
# PHASE being proven. apps/asgi_bare/ws_probe.py carries the original of
# this comment and the 2026-08-30 failure that motivated it.
stamp("fastapi ws_probe FAIL")


def main():
    phase("the opening handshake")
    ws = WebSocket.connect("127.0.0.1", PORT, "/ws", timeout=10)
    if ws.status_line is None:
        fail("no handshake response")
    if b" 101 " not in ws.status_line:
        fail("expected 101, got %r" % ws.head[:40])

    phase("the echo round trip")
    ws.send(TEXT, b"hello")
    op, payload = ws.recv_data()
    if op != TEXT or b"ws-echo:hello" not in payload:
        fail("echo wrong: op=%d payload=%r" % (op, payload))

    phase("the app-initiated close handshake")
    ws.send(TEXT, b"bye")
    op, payload = ws.recv_data()
    if op != CLOSE:
        fail("expected a close frame after bye, got op=%d %r" % (op, payload))
    if len(payload) >= 2 and struct.unpack(">H", payload[:2])[0] != 1000:
        fail("close code != 1000: %r" % payload[:2])
    # Reply, then the server must FIN rather than reset: it closed first, so
    # RFC 6455 5.5.1 has it wait for this frame before closing the socket.
    ws.send(CLOSE, payload[:2])
    ws.settimeout(5)
    try:
        rest = ws.recv_raw(1024)
    except socket.timeout:
        fail("no FIN after the close handshake")
    except ConnectionResetError:
        fail("RST after the close handshake: the server closed with bytes queued")
    if rest != b"":
        fail("unexpected bytes after close: %r" % rest)
    ws.close()
    print("fastapi ws_probe OK")


if __name__ == "__main__":
    main()
