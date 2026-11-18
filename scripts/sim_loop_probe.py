"""Measure `apps/sim_loop`: do the steps arrive, and does the loop stay free?

    sim_loop_probe.py PORT SECONDS
    sim_loop_probe.py PORT SECONDS --streams K

Holds an SSE stream on /events for SECONDS while sampling /now SAMPLES
times, and prints one line:

    frames=16 gaps=0 worst_now_ms=0 second_now_ms=0 worst_connect_ms=0 worst_request_ms=0

`second_now_ms` is the second-worst sample, the one `smoke-sim-loop`
judges, and the last two say where the worst sample spent its time
(`probelib.placement_summary`, the function `ramp_probe.py` and
`host_probe.py` print through).

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

Why the second-worst, and why SAMPLES is 32. A request waits 100 ms or
more behind a 200 ms step that starts every 250 ms only if it lands in the
step's first half. Off the loop no request should wait at all, but a shared
macOS runner stalls a single sample for 80 to 190 ms about once in a
thousand (`ramp_probe.py` and `host_probe.py` say where), and the worst of
the samples has no margin for one: on 2026-11-16 `Tests` run 43811357500
failed this gate at 113 ms on a change that did not touch the app, where
the worst sample of 37 other macOS runs had been 40 ms or less and every
Ubuntu run's 0. On an M4 the same tail appears with the cores taken,
whether the load is the step or a spinner in another process, and the two
are the same size: it is the machine, not the step. So the off-the-loop
arm reads the second-worst, which one stall does not move.

The on-the-loop arm must reach the bound by the same number, or it proves
nothing about the statistic the gate judges, and there it needs two
samples to land early, not one. The probability that a sample lands too
late is about 0.68, measured: three samples at random phases failed 19
of 60 local runs. Of 24 samples, fewer than two land early in about one
run in 850; of 32, about one in 14,000, where the worst of 24 missed about
one in 10,000. It used to take three samples, and a phase lock with the
probe's fixed gap hid how few that was: a sample that waits out a step
returns 50 ms before the next one starts, so a fixed 300 ms gap landed
each request at a step's start, and a runner whose sleeps overshoot broke
the lock. The gap between samples is drawn at random, so the arithmetic
rests on independent draws rather than on a lock a slow runner can break
in either direction.
"""
import http.client
import random
import socket
import sys
import threading
import time

from probelib import fail, phase, placement_summary, sse_events, stamp

# Which phase is running, for the crash handler. This probe's phases fail
# for opposite reasons -- OPENING the stream failing is a server that never
# came up, while READING it failing is the producer not reaching the loop,
# which is the thing the gate exists to catch -- and both live inside an
# http.client call a traceback names identically.
stamp("sim_loop_probe: FAIL", stream=sys.stderr)

SAMPLES = 32


def sample_now(port, out):
    """SAMPLES /now round trips, each `(total, connect, request)` in
    milliseconds, appended to `out` as they are taken."""
    for _ in range(SAMPLES):
        phase("sampling /now")
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        t0 = time.perf_counter()
        try:
            conn.connect()
            t1 = time.perf_counter()
            conn.request("GET", "/now")
            conn.getresponse().read()
            t2 = time.perf_counter()
        finally:
            conn.close()
        # The total ends after the close, as it always did.
        total = (time.perf_counter() - t0) * 1000.0
        out.append((total, (t1 - t0) * 1000.0, (t2 - t1) * 1000.0))
        time.sleep(random.uniform(0.05, 0.3))


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


def read_ids(resp, sock, deadline, ids):
    """Append each frame's step id to `ids` until the deadline (a
    `time.monotonic()` value) or EOF. The deadline is the socket's: a
    heartbeat cannot reset it."""
    try:
        for ev in sse_events(resp, sock=sock, deadline=deadline):
            if ev.id is not None:
                ids.append(int(ev.id))
    except (OSError, ValueError):
        pass


def refuse_gaps(ids, which):
    gaps = [(a, b) for a, b in zip(ids, ids[1:]) if b != a + 1]
    if gaps:
        sys.exit(
            "%sthe step sequence has %d gap(s), first %r — the bus dropped a "
            "frame at this cadence" % (which, len(gaps), gaps[0])
        )


def one_stream(port, secs):
    phase("opening the stream")
    conn, resp, sock = open_stream(port, secs)

    # Sample while the stream is held, so the two overlap in time.
    samples = []
    sampler = threading.Thread(target=sample_now, args=(port, samples))
    sampler.start()

    phase("reading simulation frames")
    ids = []
    read_ids(resp, sock, time.monotonic() + secs, ids)
    conn.close()
    sampler.join()

    if not ids:
        sys.exit("no simulation frames reached the client in %.0fs" % secs)
    refuse_gaps(ids, "")
    if len(samples) != SAMPLES:
        fail("the sampler took %d of %d /now samples" % (len(samples), SAMPLES))
    got = placement_summary(samples, "now")
    print(" ".join(["frames=%d" % len(ids), "gaps=0"] + ["%s=%d" % kv for kv in got.items()]))


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
    deadline = time.monotonic() + secs
    readers = [
        threading.Thread(target=read_ids, args=(resp, sock, deadline, ids))
        for _, resp, _, ids, sock in streams
    ]
    for r in readers:
        r.start()
    time.sleep(max(0.0, deadline - time.monotonic()))
    # Each reader ends at the deadline by its socket's timeout; the shutdown
    # is the backstop for one caught between two reads of a chunked line.
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
