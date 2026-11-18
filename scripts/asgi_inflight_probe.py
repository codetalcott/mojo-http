#!/usr/bin/env python3
"""Many ASGI requests in flight at once (SPEC L39, L43).

A loop's asyncio executor took 256 requests at a time. The 257th used to
be run on the loop's own thread, `run_until_complete` and all: a handler
that awaited stopped every connection, and the stop signal, until it
returned (L39). It then waited for one of the 256, so 300 requests to a
3 s handler took 6 s where uvicorn takes 3. The executor now takes as
many as the loop has connections (L43). This holds HELD requests to a
handler that sleeps and asks what the loop does meanwhile.

    M0_PORT=... python3 scripts/asgi_inflight_probe.py            # answered
    M0_PORT=... python3 scripts/asgi_inflight_probe.py waits
    M0_PORT=... M0_PID=... python3 scripts/asgi_inflight_probe.py stop
    M0_PORT=... M0_PID=... M0_BLOCKED_CONNS=N python3 scripts/asgi_inflight_probe.py blocked

`answered`: the health path answers while every request is held, every
held request is answered within one sleep of the first, and the
application answers afterwards. `waits` is the same against a server
started with `M0_EXECUTOR_INFLIGHT=256`: the requests past the bound must
wait for a second sleep, which is what says the waiting path still runs. `stop`: the same hold on a handler that sleeps an hour,
then SIGTERM to M0_PID; the probe keeps its sockets until the server has
gone, and the caller bounds the exit.

`blocked` (L44): the application blocks its own asyncio loop for 5 s
(`/block`, a `time.sleep` in an `async def`), so the executor stops reading
its submit channel, and a request arrives on each of N-1 open connections
half a millisecond apart, so each loop pass submits one or two and the
channel fills with one-job datagrams. Where N is more than the channel holds
the loop's submits are refused. Over the block the server's own CPU time
(M0_PID) must stay under `BLOCKED_CPU_LIMIT` of one core, and the health
path must answer; afterwards every request is answered. The caller checks
the log for the refusal's line, which is what says the run reached the
path at all.
"""

import http.client
import os
import signal
import socket
import subprocess
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


BLOCK_MS = 5000
BLOCKED_CPU_LIMIT = 25.0
"""Percent of one core. A refused batch was offered again every
millisecond, its queue rebuilt once per request it put back: this phase
measured 64.2% on Linux (1000 connections, a colima VM on an M4) and 70.7%
on macOS (2600, bound 3000), and since L44 0.8-1.3% and 1.1%, on
2026-11-17 (docs/notes/a-refused-batch-backs-off.md)."""


def cpu_seconds(pid):
    """User and system CPU seconds `pid` has used, every thread."""
    if sys.platform.startswith("linux"):
        with open("/proc/%d/stat" % pid) as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        fail("ps reported no CPU time for pid %d: the server is gone" % pid)
    secs = 0.0
    for part in out.replace("-", ":").split(":"):
        secs = secs * 60 + float(part)
    return secs


def read_answer(s, deadline):
    """The status of one keep-alive response with a `Content-Length`."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        s.settimeout(max(0.01, deadline - time.monotonic()))
        chunk = s.recv(65536)
        if not chunk:
            raise ConnectionError("closed before the head, after %r" % buf[:60])
        buf += chunk
    head, body = buf.split(b"\r\n\r\n", 1)
    length = 0
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    while len(body) < length:
        s.settimeout(max(0.01, deadline - time.monotonic()))
        chunk = s.recv(65536)
        if not chunk:
            raise ConnectionError("closed in the body")
        body += chunk
    return int(head.split()[1])


def blocked():
    pid = int(os.environ["M0_PID"])
    n = int(os.environ.get("M0_BLOCKED_CONNS", "1000"))
    phase("%d keep-alive connections, each answered once" % n)
    socks = []
    for _ in range(n):
        s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        socks.append(s)
    get_root = b"GET / HTTP/1.1\r\nHost: probe\r\n\r\n"
    for s in socks:
        s.sendall(get_root)
    for i, s in enumerate(socks):
        try:
            status = read_answer(s, time.monotonic() + 10)
        except OSError as exc:
            fail("connection %d of %d was not answered before the block: %r" % (i + 1, n, exc))
        if status != 200:
            fail("connection %d of %d was answered %d before the block" % (i + 1, n, status))

    phase("the application blocks its loop for %d ms; %d requests arrive behind it" % (BLOCK_MS, n - 1))
    began = time.monotonic()
    socks[0].sendall(b"GET /block?ms=%d HTTP/1.1\r\nHost: probe\r\n\r\n" % BLOCK_MS)
    time.sleep(0.1)
    # Half a millisecond apart by the clock, spun for rather than slept:
    # `time.sleep(0.0005)` slept about 4 ms on the macOS CI runner, so the
    # 2599 sends took 11.1 s and left nothing of the block to measure.
    due = time.perf_counter()
    for s in socks[1:]:
        s.sendall(get_root)
        due += 0.0005
        while time.perf_counter() < due:
            pass
    sent = time.monotonic()
    w0, w1 = sent + 0.2, began + BLOCK_MS / 1000.0 - 0.3
    if w1 - w0 < 1.0:
        fail("the %d requests took %.1f s to send, leaving under a second of the block to measure" % (n - 1, sent - began))
    while time.monotonic() < w0:
        time.sleep(0.01)

    phase("the loop's CPU and its health path while the application blocks")
    cpu0, t0 = cpu_seconds(pid), time.monotonic()
    slowest = 0.0
    while time.monotonic() < w1:
        asked = time.monotonic()
        loop_is_alive()
        slowest = max(slowest, time.monotonic() - asked)
        time.sleep(0.05)
    cpu1, t1 = cpu_seconds(pid), time.monotonic()
    used = 100.0 * (cpu1 - cpu0) / (t1 - t0)
    print("asgi inflight_probe blocked: the server used %.1f%% of a core over %.1f s "
          "with %d requests behind a blocked application; slowest health answer %.1f ms"
          % (used, t1 - t0, n - 1, slowest * 1000))
    if used > BLOCKED_CPU_LIMIT:
        fail("the server used %.1f%% of a core while its application blocked, more than "
             "%.0f%%: the loop is retrying what the executor's channel refused" % (used, BLOCKED_CPU_LIMIT))

    phase("every request is answered after the block")
    deadline = time.monotonic() + 30
    for i, s in enumerate(socks):
        try:
            status = read_answer(s, deadline)
        except OSError as exc:
            fail("request %d of %d was not answered after the block: %r" % (i + 1, n, exc))
        if status != 200:
            fail("request %d of %d was answered %d after the block" % (i + 1, n, status))
        s.close()
    print("asgi inflight_probe blocked OK: %d answered, %.1f%% of a core" % (n, used))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "answered"
    if mode == "blocked":
        blocked()
        return
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
    if mode == "waits":
        # The bound is 256: what waited for an entry slept after an earlier
        # request had finished, so the last answer is a second sleep away.
        if max(took) < 2 * SLEEP_MS / 1000.0 - 0.5:
            fail("all %d were answered within %.1f s: nothing waited, so this "
                 "run held no more than the executor takes at once" % (HELD, max(took)))
    elif max(took) > 1.5 * SLEEP_MS / 1000.0:
        # Every request overlaps: the last answer is one sleep after the
        # first request, as under uvicorn.
        fail("the last of %d answers came after %.1f s, more than one %d ms "
             "sleep: some request waited for another to finish" % (
                 HELD, max(took), SLEEP_MS))

    phase("the application answers afterwards")
    status, body = get("/", timeout=5)
    if status != 200 or b"hello from asgi_bare" not in body:
        fail("GET / answered %d %r" % (status, body[:60]))
    print("asgi inflight_probe OK: %d held, health answered, last answer at %.1f s" % (HELD, max(took)))


if __name__ == "__main__":
    main()
