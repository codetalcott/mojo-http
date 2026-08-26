#!/usr/bin/env python3
"""The claim stage 2 exists to make: a slow SYNC mount must not stall the
ASYNC one.

Four blocking Django views hold every handler-pool thread for two seconds
each while requests hit the FastHTML mount. If the two mounts shared an
execution mode, those requests would queue behind the sync work and the p99
here would be seconds; with a submit lane each, the executor never sees
them. `--blocking-threads 4` is passed by the smoke so "every pool thread"
is a number this script can saturate deliberately rather than by luck.

Exits 1 with the measurement on failure, so the smoke can just run it.
"""

import os
import sys
import threading
import time
import urllib.request

BASE = "http://127.0.0.1:" + os.environ.get("M0_PORT", "8110")

HOLD_MS = 2000.0
"""How long each blocking sync view holds a pool thread. The failure this
script exists to catch parks the async mount behind one, so a broken run
lands near this number rather than a little above the budget."""

BUDGET_MS = float(os.environ.get("ISOLATION_BUDGET_MS", "50"))
"""Ceiling for the async mount's p99 while every pool thread is held.

Chosen from what CI actually measures, not from the gap to HOLD_MS. Across
17 recorded runs on both runners the p99 ranged **1.4-4.1 ms** (Ubuntu
1.4-2.0, macOS 2.6-4.1), so 50 ms is ~12x the worst observed and ~40x
below the failure signal.

It was 400 ms, which discriminated "isolated" from "sharing an execution
mode" and nothing else: a regression that parked the async mount for 300 ms
-- a hundredfold degradation, and plainly visible to a user -- passed. A
control that only catches the total failure has stopped measuring the thing
that can actually drift.

One limit of that evidence, stated rather than assumed: every one of those
17 runs is the prefork phase. `smoke-hybrid`'s `--threads` phase calls this
script with the same budget but is skipped wherever there is no
free-threaded interpreter with fasthtml, which is both this repository's CI
and the usual development machine -- so 50 ms is unvalidated there. If it
proves tight under `--threads`, that invocation should carry its own
`ISOLATION_BUDGET_MS` rather than loosening this default for both.

Raise it via the environment if a loaded runner ever makes this flaky, and
say so here with the measurement that justified it; a gate that goes red
for reasons nobody believes trains people to ignore red, which is the
failure mode on the other side.
"""


def get(path, timeout=30):
    start = time.time()
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        r.read()
    return (time.time() - start) * 1000


def timed(path, timeout, what):
    """`get`, but a transport failure is reported as the isolation failure.

    Losing isolation completely does not present as a slow request: with
    `--blocking-threads 0` the sync mount's warm-up never returns at all,
    and an unguarded `get` exits with a urllib traceback instead of saying
    what broke. The smoke still fails, but whoever reads the log has to
    work out why from a stack trace.
    """
    try:
        return get(path, timeout=timeout)
    except Exception as exc:  # timeout, refused, reset -- all mean the same
        print(
            "hybrid isolation FAIL: %s did not complete within %.0fs (%s: %s)."
            "\n  A request that never returns is isolation lost entirely,"
            " not a slow one -- check that the sync mount has a handler pool"
            " (--blocking-threads N) and that the banner names an executor"
            " per ASGI mount." % (what, timeout, type(exc).__name__, exc)
        )
        sys.exit(1)


def main():
    # Warm both mounts: first-touch import and lifespan cost is not latency.
    timed("/", 30, "the sync mount's warm-up")
    timed("/app/", 30, "the async mount's warm-up")

    blockers = [
        threading.Thread(target=lambda: get("/slow?ms=%d" % HOLD_MS))
        for _ in range(4)
    ]
    for t in blockers:
        t.start()
    # Let them all take a pool thread before measuring.
    time.sleep(0.4)

    # Bounded well above HOLD_MS: a request genuinely queued behind the sync
    # work still returns (~HOLD_MS) and is measured, so the ordinary failure
    # reports a number rather than an error. Only a total hang trips `timed`.
    samples = sorted(
        timed("/app/", 15, "an async-mount sample") for _ in range(12)
    )
    p50 = samples[len(samples) // 2]
    p99 = samples[-1]
    for t in blockers:
        t.join()

    # The headroom is printed on every run, pass or fail, because it is what
    # the budget above was tuned from and what re-tuning it will need. A
    # number that quietly drifts from 12x to 2x is the warning that comes
    # before the failure.
    print(
        "hybrid isolation: asgi p50=%.1fms p99=%.1fms under 4 blocking sync"
        " views (budget %.0fms, %.1fx headroom; a shared execution mode"
        " would land near %.0fms)"
        % (p50, p99, BUDGET_MS, BUDGET_MS / max(p99, 0.001), HOLD_MS)
    )
    if p99 > BUDGET_MS:
        shared = p99 > HOLD_MS / 2
        print(
            "hybrid isolation FAIL: the async mount waited %.1fms behind the"
            " sync mount, over the %.0fms budget. %s"
            % (
                p99,
                BUDGET_MS,
                "That is most of the %.0fms hold, so the mounts are sharing an"
                " execution mode." % HOLD_MS
                if shared
                else "That is well short of the %.0fms hold, so the mounts are"
                " still isolated -- this is a partial regression, or a runner"
                " slow enough to need a higher ISOLATION_BUDGET_MS."
                % HOLD_MS,
            )
        )
        print("  samples (ms): " + ", ".join("%.1f" % s for s in samples))
        sys.exit(1)


if __name__ == "__main__":
    main()
