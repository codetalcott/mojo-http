#!/usr/bin/env python3
"""Does a thread the application starts run while the server is idle? (SPEC E20)

For each shape that serves a WSGI app with NO handler pool -- the event
loop calling the application itself -- start `m0serve` on
`bareapp.ticker`, read `/ticks` over one keep-alive connection, send
nothing for `--idle` seconds, and read it again on the same connection.
The difference is how many times the application's thread woke from a
10 ms sleep and got the GIL back while the loop waited for I/O.

Before #310's fix the loop held the GIL through its wait, and the thread
ran only when a request happened to run Python: 0 to 2 ticks over the
window, in every shape below. After it, the window's nominal 150. The bar
is `--min-ticks` (default 20), a tick per 75 ms, which a loaded shared
runner clears many times over and the broken server cannot reach at all
-- a count, never a latency.

Each shape's banner must NOT name a handler pool. A pool detaches the loop
by a different route (`_serve_offloaded`), so a default that grew one --
`--realtime` getting a zero-config pool, say -- would pass this probe while
the path it exists for went untested.

    python3 scripts/app_thread_probe.py                 # the gate
    python3 scripts/app_thread_probe.py --bin ./bin/m0serve --port 8641

Prints one `TICKS shape=... idle=N` line per shape for the recorder.
"""
import argparse
import http.client
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (name, flags). Each is a shape `main` serves inline on the loop thread.
SHAPES = [
    # The report's shape: an unmounted `--realtime` keeps the single loop
    # by default (`resolve_blocking_threads`).
    ("realtime", ["--realtime"]),
    # No `--realtime` at all: an explicit zero pool.
    ("no-pool", ["--blocking-threads", "0"]),
    # A forked worker: explicit topology disables the zero-config pool, and
    # the thread here is the worker's own, started after the fork.
    ("workers-2", ["--workers", "2"]),
]


def start(bin_path, app_dir, port, flags, log):
    cmd = [bin_path, "bareapp.ticker:application", "--app-dir", app_dir,
           "--host", "127.0.0.1", "--port", str(port)] + flags
    p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    deadline = time.time() + 60
    while time.time() < deadline:
        if p.poll() is not None:
            raise RuntimeError("m0serve exited %d before it answered" % p.returncode)
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("GET", "/ticks")
            conn.getresponse().read()
            conn.close()
            return p
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("m0serve did not answer on %d within 60 s" % port)


def stop(p):
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()


def read_ticks(conn):
    conn.request("GET", "/ticks")
    resp = conn.getresponse()
    body = resp.read()
    if resp.status != 200:
        raise RuntimeError("/ticks answered %d: %r" % (resp.status, body))
    doc = json.loads(body)
    return doc["pid"], doc["ticks"]


def probe(bin_path, app_dir, port, name, flags, idle, min_ticks):
    """One shape. Returns (idle ticks, failure message or None)."""
    with tempfile.TemporaryFile(mode="w+") as log:
        p = start(bin_path, app_dir, port, flags, log)
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            pid0, before = read_ticks(conn)
            time.sleep(idle)
            pid1, after = read_ticks(conn)
            conn.close()
        finally:
            stop(p)
        log.seek(0)
        output = log.read()
    banner = next((line for line in output.splitlines() if "m0serve:" in line), "")
    if not banner:
        return None, "%s: no startup banner\n%s" % (name, output)
    if "blocking-threads=" in banner or "asgi-loop" in banner:
        return None, ("%s: the banner names a pool or an executor, so this shape "
                      "no longer serves on the loop thread and proves nothing: %s"
                      % (name, banner))
    if pid0 != pid1:
        return None, ("%s: the two readings came from different workers (%d, %d) "
                      "over one keep-alive connection" % (name, pid0, pid1))
    ticks = after - before
    if ticks < min_ticks:
        return ticks, ("%s: the application's thread ticked %d times in %.1f s idle "
                       "(bar %d, nominal %d) -- the loop is holding the GIL while "
                       "it waits\n%s" % (name, ticks, idle, min_ticks,
                                         int(idle / 0.01), output))
    return ticks, None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bin", default=os.path.join(REPO, "bin", "m0serve"))
    ap.add_argument("--app-dir", default=os.path.join(REPO, "apps", "wsgi_bare"))
    ap.add_argument("--port", type=int, default=8641)
    ap.add_argument("--idle", type=float, default=1.5)
    ap.add_argument("--min-ticks", type=int, default=20)
    args = ap.parse_args()

    failures = []
    for i, (name, flags) in enumerate(SHAPES):
        try:
            ticks, failure = probe(args.bin, args.app_dir, args.port + i, name,
                                   flags, args.idle, args.min_ticks)
        except RuntimeError as e:
            ticks, failure = None, "%s: %s" % (name, e)
        if ticks is not None:
            print("TICKS shape=%s idle=%d" % (name, ticks), flush=True)
        if failure:
            failures.append(failure)
    for failure in failures:
        print("FAIL " + failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
