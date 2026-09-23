#!/usr/bin/env python3
"""A socket the SERVER ends must still tell its application (SPEC L21).

    M0_PORT=8110 python3 apps/hybrid_mix/feed/ws_end_probe.py /live

Opens a WebSocket on the mount, whose application sends one message over
the loop's 64 KB per-socket outbox, so the loop ends the connection itself.
The application then waits in receive(); it records the websocket.disconnect
it must hear, and `<mount>/told` reports it. Stdlib only.
"""

import base64
import os
import socket
import sys
import time
import urllib.request

PORT = int(os.environ.get("M0_PORT", "8110"))
MOUNT = sys.argv[1] if len(sys.argv) > 1 else "/live"

s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(
    (
        "GET %s/ws HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n" % (MOUNT, PORT, key)
    ).encode()
)
s.settimeout(5)
first = b""
try:
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        first += chunk
except socket.timeout:
    print("ws_end_probe FAIL: the server did not end the socket within 5 s")
    sys.exit(1)
if b" 101 " not in first.split(b"\r\n", 1)[0]:
    print("ws_end_probe FAIL: expected 101, got %r" % first[:40])
    sys.exit(1)
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
    print(
        "ws_end_probe FAIL: the server ended a socket on %s and its "
        "application never heard (a disconnect tag misrouted, or not sent)"
        % MOUNT
    )
    sys.exit(1)
print("ws_end_probe OK: %s heard the server end its socket" % MOUNT)
