#!/usr/bin/env python3
"""Revert each rule in `mojo_pool.mojo` and insist a guard fails for every one.

Same idea as `shim_ownership.py --sabotage`: a guard nobody has broken on
purpose is a guard nobody knows works. The table is this file's; everything
around it -- anchors that must match exactly once, the restore, and what
counts as caught (a sabotage that does not compile is a miss, never a catch)
-- is `sabotage_lib.py`'s.

    python3 scripts/pool_sabotage.py
    python3 scripts/pool_sabotage.py --only "hold"     rules by label substring
"""

from __future__ import annotations

import sys
from pathlib import Path

from sabotage_lib import MojoRun, rule, run

POOL = Path("packages/m0-http/src/mojo_pool.mojo")
TEST = Path("packages/m0-http/test/test_mojo_pool.mojo")

# (label, old, new, linux_only) — each reverts one load-bearing rule.
#
# `linux_only` marks a rule whose breakage is INVISIBLE on macOS, so the suite
# genuinely cannot catch it here and reporting it as an uncovered gap would be
# noise. There is exactly one, and it is not a weakness in the test: closing
# lane 0's write end wakes a blocked `recv` on macOS and does not on Linux
# (`OffloadPool.stop`'s docstring, which records the 20-minute CI timeout that
# established it). So a missing pill strands a thread only on Linux, where CI
# runs this file too. Since Mojo pool threads register (SPEC M22) a
# registered thread is pilled by name whatever count `stop` is given, so the
# pill count is caught by `test_stop_and_join_ends_every_thread_that_could_not_register`,
# which builds its pool under `M0_POOL_ELASTIC=0` to keep the threads on the
# lane socket where the count is load-bearing.
SABOTAGES = [
    (
        "completion never sent (the loop waits forever)",
        "        pool.put_response(slot, response^, raised)\n        pool.complete(slot)",
        "        pool.put_response(slot, response^, raised)",
        False,
    ),
    (
        "one pill too few (a thread parks forever)",
        "        if zero > 0:\n            pool.stop(zero, 0)",
        "        if zero > 1:\n            pool.stop(zero - 1, 0)",
        True,
    ),
    (
        "handler built once and shared instead of per thread",
        "    var handler = T.make(PoolContext(index, block.get(BLK_USER), lane, prefix))",
        "    var handler = T.make(PoolContext(0, block.get(BLK_USER), lane, prefix))",
        False,
    ),
    (
        "poison pill ignored (join never completes)",
        "        if job.kind == JOB_STOP:\n            break",
        "        if job.kind == JOB_STOP:\n            continue",
        False,
    ),
    # The hold seam (SPEC N11). Two rules, one each way: a stream that is
    # NOT a hold must still be refused (the head would promise a body
    # nothing writes), and a hold's frame must actually be sent (without it
    # the loop never subscribes the slot, and the client holds a stream
    # nothing feeds -- the smoke sees it as a publish that never arrives,
    # the unit test as an empty channel).
    (
        "an unheld streaming response is served instead of refused",
        "        if response.sse_streaming and not held:",
        "        if False and not held:",
        False,
    ),
    (
        "the hold frame is never sent (a stream nothing feeds)",
        "                if send_hold_frame(\n",
        "                if True or send_hold_frame(\n",
        False,
    ),
]


RULES = [rule(label, POOL, old, new, only_on="Linux" if linux_only else "")
         for label, old, new, linux_only in SABOTAGES]

# A hang is a catch only once the compiler says the sabotaged source builds
# (sabotage_lib's timeout rule), so the timeout bounds a genuine hang.
GATE = MojoRun(TEST, timeout=300)


def main(argv: list[str]) -> int:
    return run("sabotage-pool", RULES, GATE, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
