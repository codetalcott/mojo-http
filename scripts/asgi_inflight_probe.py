#!/usr/bin/env python3
"""More ASGI requests in flight than the executor's tables hold (SPEC L39).

A loop's asyncio executor holds 256 requests in flight
(`OFFLOAD_MAX_INFLIGHT`). The 257th used to be run on the loop's own
thread, `run_until_complete` and all: a handler that awaited stopped every
connection, and the stop signal, until it returned. This holds HELD
requests to a handler that sleeps, more than the bound, and asks what the
loop does meanwhile.

    M0_PORT=... python3 scripts/asgi_inflight_probe.py            # answered
    M0_PORT=... M0_PID=... python3 scripts/asgi_inflight_probe.py stop

`answered`: the health path answers while every request is held, each held
request is answered, the later ones after the earlier, and the application
answers afterwards. `stop`: the same hold on a handler that sleeps an hour,
then SIGTERM to M0_PID; the probe keeps its sockets until the server has
gone, and the caller bounds the exit.
"""

import http.client
import os
import signal
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probelib import fail, phase, stamp  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8000"))
HELD = 300
SLEEP_MS = 3000

stamp("asgi inflight_probe FAIL")


def get(path, timeout):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=timeout)
    try:
        conn.request("GET", path)
        r = conn.getresponse()
        return r.status, r.read()
    finally:
        conn.close()


def hold(ms):
    socks = []
    for _ in range(HELD):
        s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        s.sendall(b"GET /slow?ms=%d HTTP/1.1\r\nHost: probe\r\nConnection: close\r\n\r\n" % ms)
        socks.append(s)
    return socks


def loop_is_alive():
    try:
        status, body = get("/health", timeout=2)
    except OSError as exc:
        fail("the health path did not answer in 2 s with %d requests held: %r" % (HELD, exc))
    if status != 200:
        fail("the health path answered %d with %d requests held" % (status, HELD))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "answered"
    if mode == "stop":
        phase("%d requests held for an hour" % HELD)
        socks = hold(3600 * 1000)
        time.sleep(0.5)
        phase("the health path answers while they are held")
        loop_is_alive()
        phase("SIGTERM while they are held")
        pid = int(os.environ["M0_PID"])
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        for s in socks:
            s.close()
        print("asgi inflight_probe stop: sockets kept until the server went, or 25 s")
        return

    phase("%d requests held" % HELD)
    began = time.monotonic()
    socks = hold(SLEEP_MS)
    phase("the health path answers while they are held")
    loop_is_alive()

    phase("every held request is answered")
    want = b"slept %d" % SLEEP_MS
    took = []
    deadline = began + 30
    for i, s in enumerate(socks):
        buf = b""
        s.settimeout(max(0.1, deadline - time.monotonic()))
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
        except OSError as exc:
            fail("request %d of %d was not answered in 30 s: %r, after %r" % (i + 1, HELD, exc, buf[:60]))
        took.append(time.monotonic() - began)
        s.close()
        if not buf.startswith(b"HTTP/1.1 200") or want not in buf:
            fail("request %d of %d was answered %r" % (i + 1, HELD, buf[:80]))
    # The bound is 256: what waited for an entry slept after an earlier
    # request had finished, so the last answer is a second sleep away.
    if max(took) < 2 * SLEEP_MS / 1000.0 - 0.5:
        fail("all %d were answered within %.1f s: nothing waited, so this "
             "run held no more than the executor takes at once" % (HELD, max(took)))

    phase("the application answers afterwards")
    status, body = get("/", timeout=5)
    if status != 200 or b"hello from asgi_bare" not in body:
        fail("GET / answered %d %r" % (status, body[:60]))
    print("asgi inflight_probe OK: %d held, health answered, last answer at %.1f s" % (HELD, max(took)))


if __name__ == "__main__":
    main()
