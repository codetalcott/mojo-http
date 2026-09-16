#!/usr/bin/env python3
"""Break each rule `smoke-blobs` guards, and insist the smoke fails every time.

Same idea as `pool_sabotage.py`: a gate nobody has broken on purpose is a
gate nobody knows works. Each entry replaces one EXACT source line (or
block) in `apps/blobs/`, runs the whole smoke, and restores the file; the
smoke builds the app itself, so nothing else needs rebuilding. An anchor
that no longer matches is a failure — re-point it with the line.

Not here, and why: the G14 fix in `m0_core.json_parse` needs the `.mojoc`
chain rebuilt and is sabotaged by its own unit test; `send_latest`'s rules
live in m0-datastar and are sabotaged against `test_stream.mojo`. Both are
reached here through the app's use of them (the `send_latest=True`
argument and the non-UTF-8 drop).

    uv run poe sabotage-blobs
    uv run poe sabotage-blobs --only "keep-out"    one rule, by label substring
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# The venv's own poe, never `uv run poe`: a child `uv run` re-syncs the venv
# (pool_sabotage.py records why that matters under the nightly canary).
_SIBLING = Path(sys.executable).with_name("poe")
POE = str(_SIBLING) if _SIBLING.exists() else (shutil.which("poe") or "poe")

SERVER = Path("apps/blobs/server.mojo")
WORLD = Path("apps/blobs/world.mojo")
KERNEL = Path("apps/blobs/kernel.mojo")
WIRE = Path("apps/blobs/wire.mojo")

# (label, file, old, new)
SABOTAGES = [
    (
        "the producer never publishes (cadence)",
        SERVER,
        "        var sent = publish_to_channels(fds, -1, EVENTS, step, frame.as_bytes())\n",
        "        var sent = len(fds)\n",
    ),
    (
        "publishes with skip_worker = 0, reaching nobody (cadence)",
        SERVER,
        "publish_to_channels(fds, -1, EVENTS,",
        "publish_to_channels(fds, 0, EVENTS,",
    ),
    (
        "a frame too big for the bus (refused, and no frames)",
        SERVER,
        "        # skip_worker = -1: every channel, this worker's included",
        "        while frame.byte_length() <= 65536:\n"
        "            frame += \"xxxxxxxxxxxxxxxx\"\n"
        "        # skip_worker = -1: every channel, this worker's included",
    ),
    (
        "no current state at open (the live feed only)",
        SERVER,
        "DatastarStream(capacity, journal_entries=0, send_latest=True)",
        "DatastarStream(capacity, journal_entries=0)",
    ),
    (
        "a replay journal instead of the current state",
        SERVER,
        "DatastarStream(capacity, journal_entries=0, send_latest=True)",
        "DatastarStream(capacity, journal_entries=64)",
    ),
    (
        "the producer never pauses",
        SERVER,
        "        if viewers == 0:\n            # Nobody to draw for",
        "        if False:\n            # Nobody to draw for",
    ),
    (
        "a closed stream is not subtracted from the viewers",
        SERVER,
        "        self.state.stream.closed(slot)\n        self.state.publish_viewers()\n",
        "        self.state.stream.closed(slot)\n",
    ),
    # The band blobs are kept inside, collapsed to nothing. Not the drop's
    # clamp alone: that one is a layer the smoke cannot see, because the
    # producer advances the world before it traces and `advance` bounces an
    # out-of-band centre back inside (measured: MISSED). The kernel test
    # traces without advancing and catches it there.
    (
        "the keep-out band is gone, so contours reach the stage edge",
        WORLD,
        "    return contour_radius(MAX_STRENGTH) + EDGE_GAP\n",
        "    return 0.0\n",
    ),
    (
        "no per-connection drop cap",
        SERVER,
        "        if self._window_drops[slot] >= DROPS_PER_SECOND:\n            return False\n",
        "",
    ),
    (
        "a body without numeric x and y is accepted",
        SERVER,
        "    if not x or not y:\n",
        "    if False:\n",
    ),
    (
        "an idle stage never slows down",
        SERVER,
        "            period_ns = idle_ns\n",
        "            period_ns = active_ns\n",
    ),
    (
        "M0_WORKERS=2 is served instead of refused",
        SERVER,
        "    if config.workers != WORKERS:\n",
        "    if False:\n",
    ),
    (
        "the producer is never told to stop (abandoned at the join)",
        SERVER,
        "    threads.block(0).set(BLK_STOP, 1)\n",
        "",
    ),
    (
        "a frame carries only the filled slots (a delta, not full state)",
        WIRE,
        "        s += '\"_b'\n        s += String(k)\n        s += '\":\"'\n        if shapes.filled[k]:\n            s += polygon(shapes, k)\n        s += '\",'\n",
        "        if shapes.filled[k]:\n            s += '\"_b'\n            s += String(k)\n            s += '\":\"'\n            s += polygon(shapes, k)\n            s += '\",'\n",
    ),
    (
        "loops wind the other way",
        KERNEL,
        "Float32(cx - r * sin(a))",
        "Float32(cx + r * sin(a))",
    ),
    (
        "vertex 0 is not the topmost vertex",
        KERNEL,
        "var a = TWO_PI * Float64(v) / Float64(NVERT)",
        "var a = TWO_PI * (Float64(v) + 3.0) / Float64(NVERT)",
    ),
]


def run_smoke() -> tuple[bool, str]:
    p = subprocess.run(
        [POE, "smoke-blobs"], capture_output=True, text=True, timeout=600
    )
    out = p.stdout + p.stderr
    return (p.returncode == 0 and "smoke-blobs OK" in out), out


def why(out: str) -> str:
    """The line the smoke failed on, for the report."""
    for line in out.splitlines():
        if line.startswith(("blobs_probe: FAIL", "serve:", "idle:", "M0_WORKERS", "the drain", "SIGTERM")) and (
            "FAIL" in line or "not" in line or "abandoned" in line or "exited" in line
        ):
            return line.strip()[:140]
    return out.strip().splitlines()[-1][:140] if out.strip() else "(no output)"


def main() -> int:
    sys.stdout.reconfigure(line_buffering=True)
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
    chosen = [s for s in SABOTAGES if only in s[0]]
    if not chosen:
        print(f"no sabotage label contains {only!r}")
        return 1
    files = sorted({f for _, f, _, _ in SABOTAGES})
    backup_dir = Path(tempfile.mkdtemp())
    originals = {}
    for f in files:
        originals[f] = f.read_text()
        shutil.copy(f, backup_dir / f.name)

    print("baseline (unsabotaged) must PASS:")
    ok, out = run_smoke()
    print(f"  {'ok' if ok else 'FAIL'}  baseline")
    if not ok:
        print(out[-2000:])
        return 1

    missed = []
    try:
        for label, path, old, new in chosen:
            original = originals[path]
            if original.count(old) != 1:
                print(f"  FAIL  anchor missing or ambiguous: {label}")
                missed.append(label)
                continue
            path.write_text(original.replace(old, new, 1))
            try:
                ok, out = run_smoke()
            except subprocess.TimeoutExpired:
                ok, out = False, "(timed out -- itself a failure)"
            finally:
                path.write_text(original)
            if ok:
                print(f"  MISSED  {label}")
                missed.append(label)
            else:
                print(f"  CAUGHT  {label}\n          {why(out)}")
    finally:
        for f in files:
            shutil.copy(backup_dir / f.name, f)

    print()
    if missed:
        print(f"{len(missed)} rule(s) the smoke does not guard:")
        for m in missed:
            print(f"  - {m}")
        return 1
    print(f"all {len(chosen)} rules are guarded by smoke-blobs"
          + ("" if len(chosen) == len(SABOTAGES) else f" (of {len(SABOTAGES)}; --only {only!r})"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
