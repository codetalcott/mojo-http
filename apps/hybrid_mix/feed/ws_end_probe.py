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
call that raised and never the phase, which is why the stamp exists
(apps/asgi_bare/ws_probe.py has the history).
"""

import os
import socket
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                                "scripts"))
from probelib import fail, phase, stamp, upgrade_request, ws_key  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8110"))
MOUNT = sys.argv[1] if len(sys.argv) > 1 else "/live"
stamp("ws_end_probe FAIL", fail="ws_end_probe FAIL: {phase}: {msg}")


def main():
    phase("the handshake on %s" % MOUNT)
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(upgrade_request(MOUNT + "/ws", ws_key(), "127.0.0.1:%d" % PORT))

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
