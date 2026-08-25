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
BUDGET_MS = float(os.environ.get("ISOLATION_BUDGET_MS", "400"))


def get(path, timeout=30):
    start = time.time()
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        r.read()
    return (time.time() - start) * 1000


def main():
    # Warm both mounts: first-touch import and lifespan cost is not latency.
    get("/")
    get("/app/")

    blockers = [
        threading.Thread(target=lambda: get("/slow?ms=2000")) for _ in range(4)
    ]
    for t in blockers:
        t.start()
    # Let them all take a pool thread before measuring.
    time.sleep(0.4)

    samples = sorted(get("/app/") for _ in range(12))
    p50 = samples[len(samples) // 2]
    p99 = samples[-1]
    for t in blockers:
        t.join()

    print(
        "hybrid isolation: asgi p50=%.1fms p99=%.1fms under 4 blocking sync views"
        % (p50, p99)
    )
    if p99 > BUDGET_MS:
        print(
            "hybrid isolation FAIL: the async mount waited %.1fms behind the"
            " sync mount (budget %.0fms) -- the mounts are sharing an"
            " execution mode" % (p99, BUDGET_MS)
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
