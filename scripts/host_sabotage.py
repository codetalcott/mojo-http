#!/usr/bin/env python3
"""Break each rule the Mojo host keeps, and insist its gate fails every time.

`blobs_sabotage.py`'s shape: each entry replaces one EXACT source block in
`packages/m0-http/lightbug_http/host.mojo`, runs its gate, and restores the
file. The gate is `smoke-host` for what the wire shows,
`smoke-fragment-notes` for `ViewsApp` (the host's own app does not use
it), or `test_host.mojo` for what only a thread-level test can see
precisely (a producer that catches up still publishes). The fork is resolved from source by both, so
nothing else needs rebuilding. An anchor that no longer matches is a
failure -- re-point it with the line.

Not here, and why: the handler built BEFORE the fork, and the pages and the
bus created AFTER it, are not one-line edits in `serve` -- each needs the
order of several statements changed, and a harness that moves blocks
around would be testing itself. The smoke's two-worker phases are what
would fail (a single shared handler cannot hold a stream in two
processes; a post-fork bus reaches no sibling).

Nor the `_exit` after an abandoned producer. Removed, the smoke still
passes: a forked worker leaves through `exit_worker` anyway, and a single
process returning from `main` with the producer asleep inside its step
exits 0 in the same time (measured). The `_exit` stays so that teardown
never runs under a thread that is mid-step, but nothing on the wire can
tell, so it is not claimed as a guarded rule.

    uv run poe sabotage-host
    uv run poe sabotage-host --only "tick-owner"   one rule, by label substring
    uv run poe sabotage-host --only unit           the thread rules alone
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# The venv's own poe and mojo, never `uv run`: a child `uv run` re-syncs the
# venv (pool_sabotage.py records why that matters under the nightly canary).
_SIBLING = Path(sys.executable).with_name("poe")
POE = str(_SIBLING) if _SIBLING.exists() else (shutil.which("poe") or "poe")
_MOJO = Path(sys.executable).with_name("mojo")
MOJO = str(_MOJO) if _MOJO.exists() else (shutil.which("mojo") or "mojo")

SMOKE = "smoke"
NOTES = "notes"
UNIT = "unit"

HOST = Path("packages/m0-http/lightbug_http/host.mojo")

# (label, gate, old, new); `old` and `new` may be tuples of the same
# length for a rule that takes more than one edit to break.
SABOTAGES = [
    (
        "the publisher skips worker 0's channel",
        SMOKE,
        "publish_to_channels(self._fds, -1, url, event_id, frame)",
        "publish_to_channels(self._fds, 0, url, event_id, frame)",
    ),
    (
        "the producer is handed worker 0's channel alone",
        SMOKE,
        "    var out = Publisher(ctx.bus.write_fds.copy())\n",
        "    var out = Publisher([ctx.bus.write_fds[0]])\n",
    ),
    (
        "the bus is drained only above one worker",
        SMOKE,
        "        bus_read_fd=bus.read_fd(worker),\n",
        "        bus_read_fd=bus.read_fd(worker) if forked else -1,\n",
    ),
    (
        "a producer in every worker (the tick-owner rule)",
        SMOKE,
        "    if ctx.tick_owner() and P.wanted(ctx):\n",
        "    if P.wanted(ctx):\n",
    ),
    (
        "accept sharing is never bound",
        SMOKE,
        "    share.bind(worker, host_page.addr(0))\n",
        "",
    ),
    (
        "signals armed before the fork",
        SMOKE,
        (
            "    var worker = 0\n    var forked = workers > 1\n    if forked:\n",
            "    share.bind(worker, host_page.addr(0))\n"
            "    var shutdown_fd = install_shutdown_signals()\n",
        ),
        (
            "    var shutdown_fd = install_shutdown_signals()\n"
            "    var worker = 0\n    var forked = workers > 1\n    if forked:\n",
            "    share.bind(worker, host_page.addr(0))\n",
        ),
    ),
    (
        "a forked worker returns from main",
        SMOKE,
        "    if forked:\n        exit_worker()\n",
        "",
    ),
    (
        "the producer is never told to stop",
        SMOKE,
        "        self._set.block(0).set(BLK_STOP, 1)\n",
        "",
    ),
    (
        "the join has no bound",
        SMOKE,
        "        self.stragglers = self._set.join_within(timeout_ns)\n",
        "        self._set.join_all()\n        self.stragglers = 0\n",
    ),
    (
        "a producer's sleep is not sliced",
        SMOKE,
        "            if left > SLEEP_SLICE_NS:\n                left = SLEEP_SLICE_NS\n",
        "",
    ),
    (
        "the status slot is written first",
        SMOKE,
        "    var status = STATUS_RAISED\n    try:\n        _producer_run[P](block)\n",
        "    block.set(BLK_STATUS, STATUS_OK)\n    var status = STATUS_RAISED\n    try:\n        _producer_run[P](block)\n",
    ),
    (
        "a configuration the host does not serve is served",
        SMOKE,
        "    if refusal:\n",
        "    if False:\n",
    ),
    (
        "the host never asks how many workers the app serves",
        SMOKE,
        "    var refusal = host_refusal(config, H.max_workers())\n",
        "    var refusal = host_refusal(config)\n",
    ),
    (
        "ViewsApp drops its state's worker limit",
        NOTES,
        "        return Self.S.max_workers()\n",
        "        return 0\n",
    ),
    (
        "the refusal comes after the bind",
        SMOKE,
        "    var refusal = host_refusal(config, H.max_workers())\n",
        "    var early_listener = ListenConfig().listen(config.address())\n"
        "    var refusal = host_refusal(config, H.max_workers())\n",
    ),
    # --- the thread's own rules, against test_host.mojo -----------------------
    (
        "an overrun is caught up",
        UNIT,
        "            next_ns = now\n            continue\n",
        "            continue\n",
    ),
    (
        "a raising step reports success",
        UNIT,
        "    except e:\n        print(\"host: the producer raised",
        "    except e:\n        status = STATUS_OK\n        print(\"host: the producer raised",
    ),
    (
        "more workers than the app serves are not refused",
        UNIT,
        "    if max_workers > 0 and config.workers > max_workers:\n",
        "    if False:\n",
    ),
    (
        "the publisher does not count a refusal",
        UNIT,
        "            self.refused += 1\n",
        "",
    ),
]


def run_smoke() -> tuple[bool, str]:
    p = subprocess.run(
        [POE, "smoke-host"], capture_output=True, text=True, timeout=600
    )
    out = p.stdout + p.stderr
    return (p.returncode == 0 and "smoke-host OK" in out), out


def run_notes() -> tuple[bool, str]:
    p = subprocess.run(
        [POE, "smoke-fragment-notes"], capture_output=True, text=True, timeout=600
    )
    out = p.stdout + p.stderr
    return (p.returncode == 0 and "smoke-fragment-notes OK" in out), out


def run_unit() -> tuple[bool, str]:
    p = subprocess.run(
        [MOJO, "run", "-I", "packages/m0-http", "-I", "packages/m0-core",
         "packages/m0-http/test/test_host.mojo"],
        capture_output=True, text=True, timeout=600,
    )
    out = p.stdout + p.stderr
    return (p.returncode == 0 and " 0 failed" in out), out


GATES = {SMOKE: run_smoke, NOTES: run_notes, UNIT: run_unit}


def why(out: str) -> str:
    """The line the gate failed on, for the report.

    The smoke's `fail` prints its message and then each log under a
    `=== name ===` header, so the message is the line before the first
    header; a unit run names its failing tests.
    """
    # A sabotage that does not compile is caught for the wrong reason. A
    # compiler diagnostic names its file, line and column; `mojo run`'s own
    # "error: execution exited with a non-zero result" is a failing test.
    errors = [
        ln.strip() for ln in out.splitlines()
        if re.search(r"\.mojo:\d+:\d+: error:", ln)
    ]
    if errors:
        return "COMPILE ERROR (wrong reason): " + errors[0][-120:]
    fails = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("FAIL [")]
    if fails:
        return ", ".join(f.split("] ", 1)[-1] for f in fails)[:140]
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("=== ") and i > 0:
            return lines[i - 1].strip()[:140]
    return out.strip().splitlines()[-1][:140] if out.strip() else "(no output)"


def main() -> int:
    sys.stdout.reconfigure(line_buffering=True)
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
    chosen = [e for e in SABOTAGES if only in e[0] or only == e[1]]
    if not chosen:
        print(f"no sabotage label contains {only!r}")
        return 1
    backup_dir = Path(tempfile.mkdtemp())
    original = HOST.read_text()
    shutil.copy(HOST, backup_dir / HOST.name)

    print("baseline (unsabotaged) must PASS:")
    for gate in sorted({g for _, g, _, _ in chosen}):
        ok, out = GATES[gate]()
        print(f"  {'ok' if ok else 'FAIL'}  baseline ({gate})")
        if not ok:
            print(out[-2000:])
            return 1

    missed = []
    try:
        for label, gate, old, new in chosen:
            olds = old if isinstance(old, tuple) else (old,)
            news = new if isinstance(new, tuple) else (new,)
            if any(original.count(o) != 1 for o in olds):
                print(f"  FAIL  anchor missing or ambiguous: {label}")
                missed.append(label)
                continue
            broken = original
            for o, n in zip(olds, news):
                broken = broken.replace(o, n, 1)
            HOST.write_text(broken)
            try:
                ok, out = GATES[gate]()
            except subprocess.TimeoutExpired:
                ok, out = False, "(timed out -- itself a failure)"
            finally:
                HOST.write_text(original)
            reason = why(out)
            if ok:
                print(f"  MISSED  [{gate}] {label}")
                missed.append(label)
            elif reason.startswith("COMPILE ERROR"):
                print(f"  BROKEN  [{gate}] {label}\n          {reason}")
                missed.append(label + " (the sabotage does not compile)")
            else:
                print(f"  CAUGHT  [{gate}] {label}\n          {reason}")
    finally:
        shutil.copy(backup_dir / HOST.name, HOST)

    print()
    if missed:
        print(f"{len(missed)} rule(s) no gate guards:")
        for m in missed:
            print(f"  - {m}")
        return 1
    print(f"all {len(chosen)} rules are guarded"
          + ("" if len(chosen) == len(SABOTAGES) else f" (of {len(SABOTAGES)}; --only {only!r})"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
