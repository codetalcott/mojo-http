#!/usr/bin/env python3
"""Stdlib WS client for smoke-fasthtml: FastHTML's `app.ws` handler takes
its arguments from a JSON message, so this sends `{"msg": "hello"}` and
expects the handler's `ws-echo:hello` frame back."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import TEXT, WebSocket, fail, phase, stamp  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8097"))


# Which phase is running, for the crash handler. A traceback names the CALL
# that raised -- the frame read, which both phases share -- and never the
# PHASE being proven. apps/asgi_bare/ws_probe.py carries the original of
# this comment and the 2026-08-30 failure that motivated it.
stamp("fasthtml ws_probe FAIL")


def main():
    phase("the opening handshake")
    ws = WebSocket.connect("127.0.0.1", PORT, "/ws", timeout=10)
    if ws.status_line is None:
        fail("no handshake")
    if b" 101 " not in ws.status_line:
        fail("expected 101, got %r" % ws.head[:40])
    phase("the echo round trip")
    ws.send(TEXT, b'{"msg":"hello"}')
    op, payload = ws.recv_data()  # a heartbeat ping is answered on the way
    if op != TEXT or b"ws-echo:hello" not in payload:
        fail("op=%d payload=%r" % (op, payload))
    ws.close()
    print("fasthtml ws_probe OK")


if __name__ == "__main__":
    main()
