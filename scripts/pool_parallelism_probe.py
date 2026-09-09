#!/usr/bin/env python3
"""A view that releases the GIL runs in parallel across `--blocking-threads`.

`--blocking-threads N` puts N handler threads behind one event loop, and C5
proves what that buys for isolation: a slow view no longer holds the
keep-alive connections pinned behind it. It does NOT prove the other half,
which users assume and which is only sometimes true -- that N threads do N
things at once. Whether they do is decided inside the view, by whether its
work lets go of the interpreter lock.

This matters because it is invisible until measured and it silently caps a
whole class of deployment. Core ML's `MLModel.predict` holds the lock for its
duration, so an embedding server on m0serve served the same 1680 req/s on one
handler thread and on two, and LOST 31 % on the zero-config eight
(docs/notes/coreml-embeddings.md). MAX releases it, and the same shape scales
(docs/notes/gil-and-the-handler-pool.md).

The measurement is a comparison, never an absolute. `bareapp`'s `/work` is
one function over two modes, differing only in whether hashlib drops the lock
(64 KB) or keeps it (1 KB -- either side of HASHLIB_GIL_MINSIZE):

    /work?mode=nogil&n=N   N digests of 64 KB -- releases
    /work?mode=gil&n=N     N digests of 1 KB  -- holds

FIXED WORK, not a duration. `/busy?ms=N` beside it spins to a wall-clock
deadline, so two at once finish in 1.0x by construction on any server however
serialised they were -- it cannot be the control here, and an early draft of
this probe using it passed against nothing.

One request, then two at once, on one server in one run. A mode that
parallelises answers two in about the time of one; a mode that does not takes
twice as long. Measured bare, two threads against one: 1.01x and 2.01x. The
assertion is the GAP, which survives a shared runner where an absolute
millisecond figure would not. Two threads and two connections, never more: a
probe that asks four threads to spread four instant jobs is asserting
scheduler fairness, and CI's three-core runners disprove that.

usage: pool_parallelism_probe.py PORT [N_NOGIL] [N_GIL] [ROUNDS]
"""
import statistics
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
# Sized to ~200 ms each on a 2026 laptop: 64 KB is ~22 us a digest and 1 KB
# ~0.5 us. A slower runner makes both rounds longer, which the ratio absorbs;
# what it must not do is make them SHORT, so the floor below is checked.
N_NOGIL = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
N_GIL = int(sys.argv[3]) if len(sys.argv) > 3 else 400000
ROUNDS = int(sys.argv[4]) if len(sys.argv) > 4 else 3
MIN_SERIAL_S = 0.05
BASE = "http://127.0.0.1:%d" % PORT

# Both ratios come out of the same two helpers, so an unhandled reset in
# either names the call and not the route being proven. Same stamp, same
# reason, as scripts/pipeline_probe.py.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("pool_parallelism_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fetch(mode, timeout=300.0):
    url = "%s/work?mode=%s&n=%d" % (BASE, mode, N_NOGIL if mode == "nogil" else N_GIL)
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


def serial(mode):
    t0 = time.perf_counter()
    fetch(mode)
    return time.perf_counter() - t0


def concurrent(mode, n=2):
    errs = []

    def go():
        try:
            fetch(mode)
        except Exception as e:  # a dropped request must fail the round loudly
            errs.append(e)

    threads = [threading.Thread(target=go) for _ in range(n)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    took = time.perf_counter() - t0
    if errs:
        raise errs[0]
    return took


def ratio(mode):
    """Median of per-round (two-at-once / one-alone). Per-round rather than a
    ratio of medians, so a machine that gets busier mid-run moves both halves
    of each round together."""
    rounds, ones = [], []
    for _ in range(ROUNDS):
        one = serial(mode)
        two = concurrent(mode)
        rounds.append(two / one)
        ones.append(one)
    return statistics.median(rounds), statistics.median(ones)


phase("health")
urllib.request.urlopen(BASE + "/", timeout=30).read()

phase("warm")
for mode in ("nogil", "gil"):
    fetch(mode)

phase("nogil (64 KB, GIL released)")
releasing, rel_one = ratio("nogil")

phase("gil (1 KB, GIL held)")
holding, hold_one = ratio("gil")

phase("verdict")
print("pool_parallelism_probe: %d rounds, 2 handler threads, 2 connections"
      % ROUNDS)
print("  mode=nogil (releases): one %.0f ms, two-at-once %.2fx" % (rel_one * 1000, releasing))
print("  mode=gil   (holds):    one %.0f ms, two-at-once %.2fx" % (hold_one * 1000, holding))
print("RATIOS releasing=%.3f holding=%.3f" % (releasing, holding))

failures = []
# A request too short to measure makes every ratio noise, and the gap test
# would then pass or fail at random rather than reporting anything.
for name, one in (("nogil", rel_one), ("gil", hold_one)):
    if one < MIN_SERIAL_S:
        failures.append("mode=%s answered in %.0f ms, under the %.0f ms floor: "
                        "raise its n, the ratios below are noise"
                        % (name, one * 1000, MIN_SERIAL_S * 1000))
# ~1.0 is perfect overlap and ~2.0 is none. The bars sit well inside both so
# a loaded runner does not decide the result; the gap is the real assertion.
if releasing > 1.45:
    failures.append("a GIL-releasing view did not overlap: %.2fx, want < 1.45 "
                    "(two handler threads answered two requests serially)" % releasing)
if holding < 1.55:
    failures.append("a GIL-holding view overlapped: %.2fx, want > 1.55 -- the "
                    "control is broken, so the other arm proves nothing" % holding)
if holding - releasing < 0.35:
    failures.append("the two routes did not differ: %.2fx vs %.2fx, want a gap "
                    "over 0.35" % (holding, releasing))

if failures:
    for f in failures:
        print("pool_parallelism_probe: FAIL:", f)
    sys.exit(1)

print("pool_parallelism_probe: the releasing view parallelises across the pool "
      "and the holding one does not")
