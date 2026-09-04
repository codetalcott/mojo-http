#!/usr/bin/env python3
"""Pool threads must acquire the GIL in job order, or a CPU-bound view convoys.

The loop thread holds no thread state while it serves (docs/notes/
detached-loop.md), which took the per-pass GIL acquisition that used to
force CPython's 5 ms switch between pool threads out of the picture. Without
something in its place a pool thread that finishes a job re-takes the GIL
before the threads it just signalled are scheduled, and a job one of THEM
has already dequeued waits out the convoy: measured on Django with four
threads at sixteen connections as a fast-route p99 of 240-510 ms and a max
of a second, against 1.4 ms with the loop attached. The hand-off barrier
in `blocking_pool.mojo` (`_yield_turn`) is what stands in its place, and
this is its gate.

Sixteen keep-alive connections hammer `/busy?ms=0.3` -- a view that spins
with the GIL held -- for a few seconds and the latency distribution is
the verdict. Two arms, because a probe that cannot see the failure proves
nothing: the default run must hold a single-digit-millisecond p99, and the
same run with `M0_POOL_TURN=0` on the server (`--expect-convoy`) must show
the convoy. Pre-release rather than CI: a shared 3-core runner puts its own
scheduling into a p99 (docs/RELEASING.md).

usage: pool_fairness_probe.py PORT [--expect-convoy] [--seconds N] [--conns N]
"""
import http.client
import sys
import threading
import time
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else 8080
EXPECT_CONVOY = "--expect-convoy" in sys.argv
SECONDS = 8.0
CONNS = 16
for i, a in enumerate(sys.argv):
    if a == "--seconds":
        SECONDS = float(sys.argv[i + 1])
    if a == "--conns":
        CONNS = int(sys.argv[i + 1])

# What a fair pool holds and what a convoy shows, with an order of magnitude
# between them so the machine's own hiccups land in neither. The convoy's
# signature at this load is the MAX, not the p99: sixteen connections, one
# starved at a time (measured 4.2 s with the turn disabled, 17 ms with it),
# so the negative arm asks for either a p99 or a max the fair arm never
# approaches.
FAIR_P99_MS = 25.0
FAIR_MAX_MS = 250.0
CONVOY_P99_MS = 50.0
CONVOY_MAX_MS = 500.0

# Which phase is running, for the crash handler below: a traceback names the
# CALL that raised (an http.client method every phase shares) and never the
# PHASE being proven. See apps/asgi_bare/ws_probe.py for the original.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("pool_fairness_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def wait_healthy(deadline=30.0):
    t0 = time.time()
    while time.time() - t0 < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=2)
            c.request("GET", "/")
            if c.getresponse().read():
                c.close()
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("server on :%d never became healthy" % PORT)


def hammer(seconds, conns):
    stop = time.time() + seconds
    samples = [[] for _ in range(conns)]
    errors = [0] * conns

    def worker(i):
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
        while time.time() < stop:
            t0 = time.perf_counter()
            try:
                conn.request("GET", "/busy?ms=0.3")
                body = conn.getresponse().read()
                if not body.startswith(b"busy"):
                    errors[i] += 1
            except OSError:
                errors[i] += 1
                conn.close()
                conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
                continue
            samples[i].append((time.perf_counter() - t0) * 1000.0)
        conn.close()

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    flat = sorted(x for s in samples for x in s)
    return flat, sum(errors)


def pct(sorted_ms, p):
    if not sorted_ms:
        return float("nan")
    return sorted_ms[min(len(sorted_ms) - 1, int(len(sorted_ms) * p))]


def main():
    phase("health")
    wait_healthy()
    phase("warm-up")
    hammer(1.0, CONNS)
    phase("convoy-expected hammer" if EXPECT_CONVOY else "fair hammer")
    lat, errors = hammer(SECONDS, CONNS)
    n = len(lat)
    p50, p99, mx = pct(lat, 0.50), pct(lat, 0.99), (lat[-1] if lat else float("nan"))
    print("pool_fairness_probe: %s: n=%d errors=%d p50=%.2fms p99=%.2fms max=%.2fms"
          % ("turn OFF (expect convoy)" if EXPECT_CONVOY else "turn on", n, errors, p50, p99, mx))
    if n < CONNS * 10:
        print("pool_fairness_probe: FAIL: too few samples (%d) to judge a tail" % n)
        return 1
    if errors:
        print("pool_fairness_probe: FAIL: %d errors" % errors)
        return 1
    if EXPECT_CONVOY:
        if p99 < CONVOY_P99_MS and mx < CONVOY_MAX_MS:
            print("pool_fairness_probe: FAIL: with the turn disabled the p99 stayed at %.2f ms and "
                  "the max at %.2f ms (< %.0f / %.0f ms) -- the probe cannot see the convoy it exists to catch"
                  % (p99, mx, CONVOY_P99_MS, CONVOY_MAX_MS))
            return 1
        print("pool_fairness_probe: PASS: the convoy is visible without the turn")
        return 0
    if p99 > FAIR_P99_MS or mx > FAIR_MAX_MS:
        print("pool_fairness_probe: FAIL: p99 %.2f ms / max %.2f ms exceeds %.0f / %.0f ms -- "
              "pool threads are not acquiring the GIL in job order" % (p99, mx, FAIR_P99_MS, FAIR_MAX_MS))
        return 1
    print("pool_fairness_probe: PASS: fair under a CPU-bound view")
    return 0


if __name__ == "__main__":
    sys.exit(main())
