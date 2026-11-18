#!/usr/bin/env python3
"""A streamed ASGI response's head leaves when it is sent (SPEC L40).

The executor answered a response at its first body, so the head of a
stream that had sent nothing was withheld for as long as it was quiet: an
`EventSource` did not open, and the client's leaving was not noticed,
since nothing tells an application about a request not yet answered.

    M0_PORT=... python3 scripts/asgi_stream_head_probe.py            # at once
    M0_PORT=... python3 scripts/asgi_stream_head_probe.py withheld   # the switch

`withheld` is the arm run with `M0_ASGI_HEAD_AT_START=0`: the head of a
silent stream must NOT arrive, which is what says the switch still works
and that the first arm would fail without the change.
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

stamp("asgi stream_head_probe FAIL")


def head_of(path, within):
    """(socket, head bytes or None, seconds) for a GET on a new connection."""
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.sendall(b"GET %s HTTP/1.1\r\nHost: probe\r\n\r\n" % path.encode())
    began = time.monotonic()
    buf = b""
    s.settimeout(within)
    try:
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            s.settimeout(max(0.01, within - (time.monotonic() - began)))
    except socket.timeout:
        return s, None, time.monotonic() - began
    return s, buf, time.monotonic() - began


def silent():
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    try:
        conn.request("GET", "/silent-streams")
        return json.loads(conn.getresponse().read())
    finally:
        conn.close()


def main():
    withheld = len(sys.argv) > 1 and sys.argv[1] == "withheld"

    phase("the head of a stream that has sent nothing")
    s, head, took = head_of("/stream-silent", within=1.0)
    if withheld:
        if head is not None:
            fail("M0_ASGI_HEAD_AT_START=0 did not withhold the head: %r" % head[:60])
        s.close()
        print("asgi stream_head_probe OK: the switch withholds the head")
        return
    if head is None:
        fail("no head in 1 s from a stream that has sent no body")
    if not head.startswith(b"HTTP/1.1 200") or b"text/event-stream" not in head.lower():
        fail("the silent stream's head was %r" % head[:120])

    phase("the application hears the client leave it")
    if silent()["open"] != 1:
        fail("the silent stream is not open in the application: %r" % silent())
    s.close()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        counts = silent()
        if counts["open"] == 0 and counts["closed"] >= 1:
            break
        time.sleep(0.05)
    else:
        fail("3 s after its client left, the application still holds the stream: %r" % counts)

    phase("the head of a response that waits before its body")
    s, head, took = head_of("/late-body", within=1.0)
    if head is None:
        fail("no head in 1 s from a response whose body comes 1.5 s after it")
    s.close()

    phase("a response that declared its length is answered whole, with it")
    s, head, took = head_of("/late-body?sized", within=3.0)
    if head is None or b"content-length: 4" not in head.lower():
        fail("the sized late body's head was %r" % (head and head[:160],))
    if b"transfer-encoding" in head.lower() or took < 1.0:
        fail("a response that declared a Content-Length was streamed: "
             "head after %.2f s, %r" % (took, head[:160]))
    s.close()

    phase("that response is whole, and its connection is kept")
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    conn.request("GET", "/late-body")
    r = conn.getresponse()
    body = r.read()
    if r.status != 200 or body != b"late":
        fail("/late-body answered %d %r" % (r.status, body))
    conn.request("GET", "/")
    r = conn.getresponse()
    if r.status != 200 or b"hello from asgi_bare" not in r.read():
        fail("the request after /late-body on its connection was not answered")
    conn.close()

    phase("a head the server cannot read fails its own request alone")
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    try:
        conn.request("GET", "/bad-head")
        r = conn.getresponse()
        status = r.status
        r.read()
    except OSError as exc:
        fail("a request whose head has a malformed header was not answered in 5 s: %r" % (exc,))
    conn.close()
    if status != 500:
        fail("a head with a malformed header was answered %d, want 500" % status)
    for n in range(3):
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=2)
        try:
            conn.request("GET", "/")
            r = conn.getresponse()
            ok = r.status == 200 and b"hello from asgi_bare" in r.read()
        except OSError as exc:
            fail("request %d after a malformed head was not answered in 2 s: %r" % (n + 1, exc))
        conn.close()
        if not ok:
            fail("request %d after a malformed head answered %d" % (n + 1, r.status))
    print("asgi stream_head_probe OK: a silent stream has its head, its client is heard leaving, a late body is whole, a malformed head fails alone")


if __name__ == "__main__":
    main()
