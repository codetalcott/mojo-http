#!/usr/bin/env python3
"""An ASGI application hears the client of an unanswered request leave (SPEC L42).

A request in flight belonged to the executor, and the loop told nobody
when its client hung up: a long poll waited on for the life of the
process. uvicorn answers `receive()` with `http.disconnect`.

The notice does not cancel the request or drop its answer. A client that
half-closes after its request and waits for the response still gets it.

    M0_PORT=... python3 scripts/asgi_gone_probe.py
"""

import http.client
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probelib import fail, phase, stamp  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8000"))

stamp("asgi gone_probe FAIL")


def heard():
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    try:
        conn.request("GET", "/heard")
        return json.loads(conn.getresponse().read())
    finally:
        conn.close()


def read_all(s):
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            return buf
        buf += chunk


def main():
    phase("a request waits unanswered, its handler listening")
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(b"GET /await-disconnect HTTP/1.1\r\nHost: probe\r\n\r\n")
    deadline = time.monotonic() + 3
    while heard()["waiting"] != 1:
        if time.monotonic() > deadline:
            fail("the handler never started waiting: %r" % heard())
        time.sleep(0.05)

    phase("its client leaves, and the application hears it")
    s.close()
    deadline = time.monotonic() + 3
    while True:
        counts = heard()
        if counts["heard"] == 1 and counts["waiting"] == 0:
            break
        if time.monotonic() > deadline:
            fail("3 s after its client left, the handler is still waiting: %r" % counts)
        time.sleep(0.05)

    phase("a client that half-closes while its request runs is answered")
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(b"GET /slow?ms=700 HTTP/1.1\r\nHost: probe\r\n\r\n")
    time.sleep(0.3)
    s.shutdown(socket.SHUT_WR)
    got = read_all(s)
    s.close()
    if not got.startswith(b"HTTP/1.1 200") or b"slept 700" not in got:
        fail("half-closed mid-request, the answer was %r" % got[:120])

    phase("a request sent with its FIN is answered")
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(b"GET /slow?ms=300 HTTP/1.1\r\nHost: probe\r\n\r\n")
    s.shutdown(socket.SHUT_WR)
    got = read_all(s)
    s.close()
    if not got.startswith(b"HTTP/1.1 200") or b"slept 300" not in got:
        fail("half-closed with its request, the answer was %r" % got[:120])
    print("asgi gone_probe OK: a departed client is heard, a half-closed one is answered")


if __name__ == "__main__":
    main()
