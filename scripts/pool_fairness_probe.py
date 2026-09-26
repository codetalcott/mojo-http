#!/usr/bin/env python3
"""Pool threads must take the GIL in job order, or a CPU-bound view convoys.

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

Twenty keep-alive connections hammer `/busy?ms=0.65` -- a view that spins
with the GIL held -- against five pool threads (the task starts the server)
for a few seconds, and the verdict is ORDER. A request is PASSED OVER when a
request sent after it is answered first: the pool served someone else while
it waited. The ring hands jobs out in the order they were queued, so in a
fair pool a request is passed over only while its thread waits its turn for
the GIL, by a few dozen later answers and rarely a hundred. A starved or
convoyed waiter is passed over by hundreds. A fair run lets at most
LONG_WAITS_ALLOWED requests be passed over by more than LONG_WAIT later
answers, and none by more than MOST_PASSED_OVER.

The probe judged latency first -- a p99 under 25 ms and a max under a
quarter second -- and that is too close to the machine for a gate on every
pull request. Measured on a 4-vCPU KVM guest at the first load (four
threads, sixteen connections, a 0.3 ms view): a fair run's max reached
247 ms once in 68 runs, where 21-97 ms is usual, and the old shapes' figures
sat near the same bounds from the other side (the keep rule off: p99
26-34 ms, max 120-609; the turn off: max 554-2237). A pause of the whole
process delays every connection at once, which is what a max cannot tell
from a starved waiter, and it passes nobody over: with the server stopped
for 300 ms twice inside the window, five runs of five were in order (at
most one long wait) where the old verdict failed all five on a 315-320 ms
max.

Negative arms, because a probe that cannot see the failure proves nothing:
the default run must be in order, and the same run must not be with
`M0_POOL_TURN=0` on the server (`--expect-convoy`), the barrier's arm, or
with `M0_POOL_TURN_KEEP=0` (`--expect-starvation`), the keep rule's: inside
its slice a thread takes the jobs already queued without dropping the GIL,
and with the rule off it drops it between every job again, each drop waking
the longest waiter, which finds the GIL re-taken and queues again behind the
others (docs/notes/a-slice-keeps-the-gil.md). Whether that starves anyone
depends on how many jobs a 1 ms slice holds against how many threads wait,
and the load is chosen for it (docs/notes/fairness-judged-by-order.md): a
request's share of the GIL is 0.67-0.70 ms on GitHub's runners and 0.8 ms
on the KVM guest, two jobs a slice on every machine measured, and with four
threads waiting two of them starve. The first load's 0.3 ms view sat on
the boundary between three jobs a slice and four, and starved only the
machines whose overhead put it at three.

Latency is still printed, and recorded in CI; it is not the verdict.

usage: pool_fairness_probe.py PORT [--expect-convoy | --expect-starvation]
                              [--seconds N] [--conns N] [--busy-ms MS]

The defaults are the gate's load; the sweep that chose it passes the rest
(scripts/probes/fairness_sweep.py).
"""
import http.client
import sys
import threading
import time
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else 8080
EXPECT_CONVOY = "--expect-convoy" in sys.argv
EXPECT_STARVATION = "--expect-starvation" in sys.argv
SECONDS = 8.0
CONNS = 20
BUSY_MS = "0.65"
for i, a in enumerate(sys.argv):
    if a == "--seconds":
        SECONDS = float(sys.argv[i + 1])
    if a == "--conns":
        CONNS = int(sys.argv[i + 1])
    if a == "--busy-ms":
        BUSY_MS = sys.argv[i + 1]

# The verdict, in later answers rather than milliseconds. At this load the
# pool answers about 1,450 requests a second on GitHub's runner and 1,250 on
# a 4-vCPU KVM guest, so LONG_WAIT is 70-80 ms of the pool serving others
# while one request waits, and MOST_PASSED_OVER 0.7-0.8 s. Measured on ten
# runners of five CPU types, 20 runs an arm: fair, no request over LONG_WAIT
# and the most passed over by 10-22; the keep rule off, 29-81 requests a run
# over it, the most by 1232-6105; the turn off, 12-116, the most by
# 2596-17892. On the KVM guest: fair 0, the most 46-68; the keep rule off
# 73-100; the turn off 17-32. The allowance is for what the keep rule does
# not prevent: a waiter can still lose its place to its own 5 ms timeout.
# MOST_PASSED_OVER is for a regime with few starvations and long ones, which
# the 2026-09-26 finding showed first (a max of 575-735 ms at a p99 of
# 8.6-16.6) and the turn off shows on the runner: 12 long waits in its
# quietest run, the most passed over by thousands.
LONG_WAIT = 100
LONG_WAITS_ALLOWED = 5
MOST_PASSED_OVER = 1000

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
    """(latencies in ms, sorted; (sent, answered) per request; errors)."""
    stop = time.time() + seconds
    spans = [[] for _ in range(conns)]
    errors = [0] * conns

    def worker(i):
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
        while time.time() < stop:
            t0 = time.perf_counter()
            try:
                conn.request("GET", "/busy?ms=" + BUSY_MS)
                body = conn.getresponse().read()
                if not body.startswith(b"busy"):
                    errors[i] += 1
            except OSError:
                errors[i] += 1
                conn.close()
                conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
                continue
            spans[i].append((t0, time.perf_counter()))
        conn.close()

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    flat = [s for per in spans for s in per]
    return sorted((b - a) * 1000.0 for a, b in flat), flat, sum(errors)


def passed_over(spans):
    """For each request, how many requests SENT after it were ANSWERED first.

    A Fenwick tree over answer order, visited from the last request sent to
    the first: at each step the tree holds exactly the requests sent later,
    so the prefix below this request's answer rank counts the ones answered
    before it. n log n, where comparing every pair is 10^9 at this load.
    """
    n = len(spans)
    rank = [0] * n
    for r, k in enumerate(sorted(range(n), key=lambda k: spans[k][1])):
        rank[k] = r + 1
    tree = [0] * (n + 1)
    out = []
    for k in sorted(range(n), key=lambda k: spans[k][0], reverse=True):
        r, c = rank[k] - 1, 0
        while r > 0:
            c += tree[r]
            r -= r & -r
        out.append(c)
        r = rank[k]
        while r <= n:
            tree[r] += 1
            r += r & -r
    return out


def pct(sorted_ms, p):
    if not sorted_ms:
        return float("nan")
    return sorted_ms[min(len(sorted_ms) - 1, int(len(sorted_ms) * p))]


def main():
    phase("health")
    wait_healthy()
    phase("warm-up")
    hammer(1.0, CONNS)
    if EXPECT_CONVOY:
        arm = "turn OFF (expect convoy)"
    elif EXPECT_STARVATION:
        arm = "keep OFF (expect starvation)"
    else:
        arm = "turn on"
    phase(arm + " hammer")
    lat, spans, errors = hammer(SECONDS, CONNS)
    phase(arm + " verdict")
    n = len(lat)
    p50, p99, mx = pct(lat, 0.50), pct(lat, 0.99), (lat[-1] if lat else float("nan"))
    over = passed_over(spans)
    long_waits = sum(1 for x in over if x > LONG_WAIT)
    most = max(over) if over else 0
    in_order = long_waits <= LONG_WAITS_ALLOWED and most <= MOST_PASSED_OVER
    print("pool_fairness_probe: %s: n=%d errors=%d p50=%.2fms p99=%.2fms max=%.2fms; "
          "passed over by more than %d later answers: %d requests (a fair run: at most %d), "
          "the most: %d (at most %d)"
          % (arm, n, errors, p50, p99, mx, LONG_WAIT, long_waits, LONG_WAITS_ALLOWED,
             most, MOST_PASSED_OVER))
    # One figure a line, for the task's recorder (scripts/emit.py).
    # ms_per_request is a request's share of the GIL -- the pool runs one view
    # at a time -- and what the keep arm rests on: under 1 ms, a 1 ms slice
    # holds two of them (the view's own spin keeps it over 0.5 on any machine).
    print("ms_per_request %.3f" % (SECONDS * 1000.0 / n if n else float("nan")))
    print("p99_ms %.2f" % p99)
    print("max_ms %.2f" % mx)
    print("long_waits %d" % long_waits)
    print("long_waits_bound %d" % LONG_WAITS_ALLOWED)
    print("most_passed_over %d" % most)
    print("most_passed_over_bound %d" % MOST_PASSED_OVER)
    if n < CONNS * 10:
        print("pool_fairness_probe: FAIL: too few samples (%d) to judge an order" % n)
        return 1
    if errors:
        print("pool_fairness_probe: FAIL: %d errors" % errors)
        return 1
    if EXPECT_CONVOY or EXPECT_STARVATION:
        what = "the convoy it exists to catch" if EXPECT_CONVOY else "the starvation the keep rule prevents"
        if in_order:
            print("pool_fairness_probe: FAIL: with %s disabled the pool still answered in order "
                  "(%d requests passed over by more than %d, the most by %d) -- the probe cannot "
                  "see %s" % ("the turn" if EXPECT_CONVOY else "the keep rule", long_waits,
                               LONG_WAIT, most, what))
            return 1
        print("pool_fairness_probe: PASS: %s is visible" % ("the convoy" if EXPECT_CONVOY else "the starvation"))
        return 0
    if not in_order:
        print("pool_fairness_probe: FAIL: %d requests passed over by more than %d later answers "
              "(at most %d), the most by %d (at most %d) -- pool threads are not taking the GIL "
              "in job order" % (long_waits, LONG_WAIT, LONG_WAITS_ALLOWED, most, MOST_PASSED_OVER))
        return 1
    print("pool_fairness_probe: PASS: in job order under a CPU-bound view")
    return 0


if __name__ == "__main__":
    sys.exit(main())
