#!/usr/bin/env python3
"""Client for smoke-fasthtml's two-worker phase (SPEC L38).

Opens CLIENTS sockets on `/live`, requires them to sit on more than one
worker, then publishes FRAMES texts through `/announce`, each on a new
connection, and requires every socket to receive every one, once.
"""

import http.client
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import TEXT, WebSocket, fail, phase, stamp  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8097"))
CLIENTS = 6
FRAMES = 30

stamp("fasthtml bus_probe FAIL")


def get(path):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    try:
        conn.request("GET", path)
        r = conn.getresponse()
        return r.status, r.read().decode()
    finally:
        conn.close()


def main():
    phase("the sockets open")
    clients = []
    for _ in range(CLIENTS):
        ws = WebSocket.connect("127.0.0.1", PORT, "/live", timeout=10)
        if ws.status_line is None or b" 101 " not in ws.status_line:
            fail("/live did not upgrade: %r" % (ws.head[:60],))
        clients.append(ws)

    # A worker that answers a count other than 0 or CLIENTS holds some of
    # the sockets and not all of them. Each request is a new connection,
    # so which worker answers is the server's choice: ask until one does.
    phase("the sockets sit on more than one worker")
    seen = set()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        status, body = get("/live-here")
        if status != 200 or not body.isdigit():
            fail("/live-here answered %d %r" % (status, body))
        seen.add(int(body))
        if seen - {0, CLIENTS}:
            break
        time.sleep(0.05)
    else:
        fail("every worker asked holds all %d sockets or none (answers %s): "
             "the phase would prove nothing about a second worker" % (CLIENTS, sorted(seen)))

    phase("every socket receives every announcement")
    for n in range(FRAMES):
        status, body = get("/announce?text=frame-%d" % n)
        if status != 200 or body != "ok":
            fail("/announce answered %d %r" % (status, body))
    want = ["frame-%d" % n for n in range(FRAMES)]
    for i, ws in enumerate(clients):
        got = []
        deadline = time.monotonic() + 10
        while len(got) < FRAMES:
            try:
                op, payload = ws.recv_data(deadline=deadline)
            except Exception as exc:  # the deadline, or the socket ending
                fail("socket %d received %d of %d announcements (%s: %s); "
                     "the first missing is %r" % (
                         i, len(got), FRAMES, type(exc).__name__, exc,
                         next((w for w in want if w not in got), None)))
            if op == TEXT:
                got.append(payload.decode())
        if sorted(got) != sorted(want):
            fail("socket %d received %r" % (i, got))

    for ws in clients:
        ws.close()
    print("fasthtml bus_probe OK: %d sockets on more than one worker, %d of %d each" % (
        CLIENTS, FRAMES, FRAMES))


if __name__ == "__main__":
    main()
