"""Measure `apps/sim_loop`: do the steps arrive, and does the loop stay free?

    sim_loop_probe.py PORT SECONDS

Holds an SSE stream on /events for SECONDS while sampling /now SAMPLES
times, and prints one line:

    frames=16 gaps=0 worst_now_ms=0

Exits 1 naming the problem if the stream carried no frames or its step ids
are not contiguous. The caller asserts on the numbers; this only refuses
what is malformed.

Why SAMPLES is 24. The smoke's on-the-loop arm requires the worst sample to
wait at least 100 ms behind a 200 ms step that starts every 250 ms, and a
request waits that long only if it lands in the step's first half. This used
to take three samples 300 ms apart, argued from the chance of missing the
step ENTIRELY (1 in 125 for all three). What actually carried it was a phase
lock: a sample that waits out a step returns 50 ms before the next one
starts, so a fixed 300 ms gap lands the next request at a step's start, and
40 local runs saw 169-200 ms every time. A runner whose sleeps overshoot
breaks the lock, and CI's macOS smoke failed at 98 ms on a change that did not
touch the app. Three samples at RANDOM phases, which is what a broken lock
approximates, failed 19 of 60 local runs: about 0.68 per sample of landing
too late. At 24 samples that is 0.68^24, about 1 in 10,000 runs; 16 would
have been 1 in 460, on a smoke every pull request runs on two runners.

The gap between samples is drawn at random rather than fixed, so the
arithmetic rests on independent draws rather than on a lock that a slow
runner can break in either direction.
"""
import http.client
import random
import sys
import threading
import time
import traceback


# Which phase is running, for the crash handler below. This probe's phases
# fail for opposite reasons -- OPENING the stream failing is a server that
# never came up, while READING it failing is the producer not reaching the
# loop, which is the thing the gate exists to catch -- and both live inside
# an http.client call a traceback names identically.
# scripts/drain_idle_probe.py carries the shape of this stamp.
PHASE = "startup"

SAMPLES = 24


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("sim_loop_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def sample_now(port, out):
    """Worst of SAMPLES /now round trips, in milliseconds."""
    worst = 0.0
    for _ in range(SAMPLES):
        phase("sampling /now")
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        t0 = time.perf_counter()
        try:
            conn.request("GET", "/now")
            conn.getresponse().read()
        finally:
            conn.close()
        worst = max(worst, (time.perf_counter() - t0) * 1000.0)
        time.sleep(random.uniform(0.05, 0.3))
    out.append(worst)


def main():
    port, secs = int(sys.argv[1]), float(sys.argv[2])

    phase("opening the stream")
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=secs + 15)
    conn.request("GET", "/events", headers={"Accept": "text/event-stream"})
    resp = conn.getresponse()
    if resp.status != 200:
        sys.exit("the stream did not open: HTTP %d" % resp.status)

    # Sample while the stream is held, so the two overlap in time.
    worst = []
    sampler = threading.Thread(target=sample_now, args=(port, worst))
    sampler.start()

    phase("reading simulation frames")
    ids, deadline, buf = [], time.perf_counter() + secs, b""
    while time.perf_counter() < deadline:
        try:
            chunk = resp.read(1)
        except (TimeoutError, OSError):
            break
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            text = line.decode("utf-8", "replace").strip()
            if text.startswith("id: "):
                ids.append(int(text[4:]))
    conn.close()
    sampler.join()

    if not ids:
        sys.exit("no simulation frames reached the client in %.0fs" % secs)
    gaps = [(a, b) for a, b in zip(ids, ids[1:]) if b != a + 1]
    if gaps:
        sys.exit(
            "the step sequence has %d gap(s), first %r — the bus dropped a "
            "frame at this cadence" % (len(gaps), gaps[0])
        )
    print(
        "frames=%d gaps=0 worst_now_ms=%d"
        % (len(ids), int(worst[0] if worst else -1))
    )


main()
