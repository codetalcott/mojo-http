#!/usr/bin/env python3
"""A socket the SERVER ends must still tell its application (SPEC L21).

    M0_PORT=8110 python3 apps/hybrid_mix/feed/ws_end_probe.py /live

Opens a WebSocket on the mount, whose application sends one message over
the loop's 64 KB per-socket outbox, so the loop ends the connection itself.
The application then waits in receive(); it records the websocket.disconnect
it must hear, and `<mount>/told` reports it. On the second of two executors
that disconnect arrives only if the loop routes it by the lane the socket's
begin frame recorded -- the end erased the channel name. Stdlib only.

Which phase a failure broke is what its message says; a traceback names the
call that raised and never the phase, which is why `PHASE` exists
(apps/asgi_bare/ws_probe.py has the history).
"""

import base64
import os
import socket
import sys
import time
import traceback
import urllib.request

PORT = int(os.environ.get("M0_PORT", "8110"))
MOUNT = sys.argv[1] if len(sys.argv) > 1 else "/live"
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("ws_end_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("ws_end_probe FAIL: %s: %s" % (PHASE, msg))
    sys.exit(1)


def main():
    phase("the handshake on %s" % MOUNT)
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
        (
            "GET %s/ws HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (MOUNT, PORT, key)
        ).encode()
    )

    phase("the server ends the socket")
    s.settimeout(5)
    first = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            first += chunk
    except socket.timeout:
        fail("the server did not end the socket within 5 s")
    if b" 101 " not in first.split(b"\r\n", 1)[0]:
        fail("expected 101, got %r" % first[:40])

    phase("the application heard")
    told = "0"
    for _ in range(30):
        with urllib.request.urlopen(
            "http://127.0.0.1:%d%s/told" % (PORT, MOUNT), timeout=5
        ) as r:
            told = r.read().decode()
        if told != "0":
            break
        time.sleep(0.1)
    if told == "0":
        fail(
            "the server ended a socket on %s and its application never heard "
            "(a disconnect tag misrouted, or not sent)" % MOUNT
        )
    print("ws_end_probe OK: %s heard the server end its socket" % MOUNT)


if __name__ == "__main__":
    main()
