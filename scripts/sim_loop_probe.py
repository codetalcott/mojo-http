"""Measure `apps/sim_loop`: do the steps arrive, and does the loop stay free?

    sim_loop_probe.py PORT SECONDS
    sim_loop_probe.py PORT SECONDS --streams K

Holds an SSE stream on /events for SECONDS while sampling /now SAMPLES
times, and prints one line:

    frames=16 gaps=0 worst_now_ms=0

Exits 1 naming the problem if the stream carried no frames or its step ids
are not contiguous. The caller asserts on the numbers; this only refuses
what is malformed.

With `--streams K` (the two-worker phase) it holds K streams instead, opened
one after another so accept sharing can place each on the least-loaded
worker, reads every one for SECONDS, samples nothing, and prints:

    streams=4 workers=2 min_frames=16 per_stream=0:16,1:16,0:16,1:16

`workers` is how many distinct `x-worker` values the streams answered with
and `min_frames` the fewest steps any one stream carried; `per_stream` is
worker:frames in opening order, for the failure message. A stream with no
frames is NOT refused here, because that is the result the phase exists to
detect -- the caller says what it means. A missing `x-worker` header, a
non-200, or a gap in any stream's ids is malformed and exits 1.

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
import socket
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


def open_stream(port, secs):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=secs + 15)
    conn.request("GET", "/events", headers={"Accept": "text/event-stream"})
    # Taken before getresponse: a response that will close detaches the
    # socket from the connection, which then reads as None.
    sock = conn.sock
    resp = conn.getresponse()
    if resp.status != 200:
        sys.exit("the stream did not open: HTTP %d" % resp.status)
    return conn, resp, sock


def read_ids(resp, deadline, ids):
    """Append each frame's step id to `ids` until the deadline or EOF."""
    buf = b""
    while time.perf_counter() < deadline:
        try:
            chunk = resp.read(1)
        except (TimeoutError, OSError, ValueError):
            break
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            text = line.decode("utf-8", "replace").strip()
            if text.startswith("id: "):
                ids.append(int(text[4:]))


def refuse_gaps(ids, which):
    gaps = [(a, b) for a, b in zip(ids, ids[1:]) if b != a + 1]
    if gaps:
        sys.exit(
            "%sthe step sequence has %d gap(s), first %r — the bus dropped a "
            "frame at this cadence" % (which, len(gaps), gaps[0])
        )


def one_stream(port, secs):
    phase("opening the stream")
    conn, resp, _ = open_stream(port, secs)

    # Sample while the stream is held, so the two overlap in time.
    worst = []
    sampler = threading.Thread(target=sample_now, args=(port, worst))
    sampler.start()

    phase("reading simulation frames")
    ids = []
    read_ids(resp, time.perf_counter() + secs, ids)
    conn.close()
    sampler.join()

    if not ids:
        sys.exit("no simulation frames reached the client in %.0fs" % secs)
    refuse_gaps(ids, "")
    print(
        "frames=%d gaps=0 worst_now_ms=%d"
        % (len(ids), int(worst[0] if worst else -1))
    )


def many_streams(port, secs, k):
    streams = []
    for i in range(k):
        phase("opening stream %d of %d" % (i + 1, k))
        conn, resp, sock = open_stream(port, secs)
        worker = resp.getheader("x-worker")
        if worker is None:
            sys.exit("stream %d carries no x-worker header" % (i + 1))
        streams.append((conn, resp, worker, [], sock))
        # Long enough for the worker that took it to end a pass and publish
        # its connection count, which is what the next acceptor's pick reads.
        time.sleep(0.2)

    phase("reading simulation frames on %d streams" % k)
    deadline = time.perf_counter() + secs
    readers = [
        threading.Thread(target=read_ids, args=(resp, deadline, ids))
        for _, resp, _, ids, _ in streams
    ]
    for r in readers:
        r.start()
    time.sleep(max(0.0, deadline - time.perf_counter()))
    # A starved stream is blocked inside read(1) with nothing coming; shutting
    # its socket down is what ends that read at the deadline.
    for _, _, _, _, sock in streams:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
    for r in readers:
        r.join()
    for conn, resp, _, _, _ in streams:
        resp.close()
        conn.close()

    for i, (_, _, worker, ids, _) in enumerate(streams):
        refuse_gaps(ids, "stream %d (worker %s): " % (i + 1, worker))
    print(
        "streams=%d workers=%d min_frames=%d per_stream=%s"
        % (
            k,
            len({worker for _, _, worker, _, _ in streams}),
            min(len(ids) for _, _, _, ids, _ in streams),
            ",".join("%s:%d" % (w, len(ids)) for _, _, w, ids, _ in streams),
        )
    )


def main():
    port, secs = int(sys.argv[1]), float(sys.argv[2])
    if len(sys.argv) == 5 and sys.argv[3] == "--streams":
        many_streams(port, secs, int(sys.argv[4]))
    elif len(sys.argv) == 3:
        one_stream(port, secs)
    else:
        sys.exit("usage: sim_loop_probe.py PORT SECONDS [--streams K]")


main()
