#!/usr/bin/env python3
"""Break each rule `apps/blobs` depends on, and insist its gate fails every time.

Same idea as `pool_sabotage.py`: a gate nobody has broken on purpose is a
gate nobody knows works. Each entry replaces one EXACT source line (or
block) in `apps/blobs/`, runs its gate, and restores the file. The gate is
`smoke-blobs` for what the wire shows, or the kernel's unit tests for the
kernel's own rules, which the wire cannot see precisely (a fragmenting
march still draws something). Both build from source, so nothing else
needs rebuilding. An anchor that no longer matches is a failure —
re-point it with the line.

Not here, and why: the G14 fix in `m0_core.json_parse` needs the `.mojoc`
chain rebuilt and is sabotaged by its own unit test; `send_latest`'s rules
live in m0-datastar and are sabotaged against `test_stream.mojo`. Both are
reached here through the app's use of them (the `send_latest=True`
argument and the non-UTF-8 drop).
The Mojo host's own rules -- every worker's channel, the tick owner, the
bounded join -- moved into `m0_host.host` when this app did, and are
`sabotage-host`'s; what stays here is the two-worker half that is the
app's: the viewer sum and a board every worker shares.

    uv run poe sabotage-blobs
    uv run poe sabotage-blobs --only "keep-out"    one rule, by label substring
    uv run poe sabotage-blobs --only unit          the kernel's rules alone
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
UNIT = "unit"

SERVER = Path("apps/blobs/server.mojo")
WORLD = Path("apps/blobs/world.mojo")
KERNEL = Path("apps/blobs/kernel.mojo")
WIRE = Path("apps/blobs/wire.mojo")

# (label, gate, file, old, new); `old` and `new` may be tuples of the same
# length for a rule that takes more than one edit to break.
SABOTAGES = [
    (
        "the producer never publishes (cadence)",
        SMOKE,
        SERVER,
        "        if not out.publish(EVENTS, id, frame.as_bytes()):\n",
        "        if False:\n",
    ),
    (
        "a frame too big for the bus (refused, and no frames)",
        SMOKE,
        SERVER,
        "        # Every worker's channel. A shortfall is counted",
        "        while frame.byte_length() <= 65536:\n"
        "            frame += \"xxxxxxxxxxxxxxxx\"\n"
        "        # Every worker's channel. A shortfall is counted",
    ),
    (
        "no current state at open (the live feed only)",
        SMOKE,
        SERVER,
        "DatastarStream(capacity, journal_entries=0, send_latest=True)",
        "DatastarStream(capacity, journal_entries=0)",
    ),
    (
        "a replay journal instead of the current state",
        SMOKE,
        SERVER,
        "DatastarStream(capacity, journal_entries=0, send_latest=True)",
        "DatastarStream(capacity, journal_entries=64)",
    ),
    (
        "the producer never pauses",
        SMOKE,
        SERVER,
        "        if viewers == 0:\n            # Nobody to draw for",
        "        if False:\n            # Nobody to draw for",
    ),
    (
        "a closed stream is not subtracted from the viewers",
        SMOKE,
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
        "the keep-out band is gone, so a lone corner blob reaches the wall",
        SMOKE,
        WORLD,
        "    return contour_radius(MAX_STRENGTH) + EDGE_GAP\n",
        "    return 0.0\n",
    ),
    (
        "no per-connection drop cap",
        SMOKE,
        SERVER,
        "        if self._window_drops[slot] >= DROPS_PER_SECOND:\n            return False\n",
        "",
    ),
    (
        "a body without numeric x and y is accepted",
        SMOKE,
        SERVER,
        "    if not x or not y:\n",
        "    if False:\n",
    ),
    (
        "an idle stage never slows down",
        SMOKE,
        SERVER,
        "            period_ns = self.idle_ns\n",
        "            period_ns = self.active_ns\n",
    ),
    # The two-worker half. The host's own rules (every channel, the tick
    # owner, the bounded join) are `sabotage-host`'s; these are the app's.
    (
        "the pause counts worker 0's viewers alone",
        SMOKE,
        SERVER,
        "        var viewers = self.board.viewers(self.workers)\n",
        "        var viewers = self.board.viewers(1)\n",
    ),
    (
        "worker 1's board is its own memory, so its clicks never cross",
        SMOKE,
        SERVER,
        (
            "from m0_http import AppConfig, Views, reply\n",
            "                ctx.capacity, Board(ctx.page), ctx.worker, ctx.workers,\n",
        ),
        (
            "from m0_http import AppConfig, Views, reply\n"
            "from m0_http.multiworker import SharedAtomics\n",
            "                ctx.capacity,\n"
            "                Board(\n"
            "                    ctx.page if ctx.worker == 0\n"
            "                    else SharedAtomics(board_slots(ctx.workers)).addr(0)\n"
            "                ),\n"
            "                ctx.worker,\n"
            "                ctx.workers,\n",
        ),
    ),
    (
        "a frame carries only the filled slots (a delta, not full state)",
        SMOKE,
        WIRE,
        "        s += '\"_b'\n        s += String(k)\n        s += '\":\"'\n        if shapes.filled[k]:\n            s += polygon(shapes, k)\n        s += '\",'\n",
        "        if shapes.filled[k]:\n            s += '\"_b'\n            s += String(k)\n            s += '\":\"'\n            s += polygon(shapes, k)\n            s += '\",'\n",
    ),
    (
        "shapes wind the other way (vertex order reversed)",
        SMOKE,
        KERNEL,
        "                shapes.px[k * NVERT + v] = self.cand_x[c * NVERT + v]\n"
        "                shapes.py[k * NVERT + v] = self.cand_y[c * NVERT + v]\n",
        "                shapes.px[k * NVERT + v] = self.cand_x[c * NVERT + NVERT - 1 - v]\n"
        "                shapes.py[k * NVERT + v] = self.cand_y[c * NVERT + NVERT - 1 - v]\n",
    ),
    (
        "vertex 0 is not the topmost vertex (start rotated past it)",
        SMOKE,
        KERNEL,
        "        tmp.append(xs[base + (v + by) % NVERT])\n",
        "        tmp.append(xs[base + (v + by + 3) % NVERT])\n",
    ),
    # --- the kernel's own rules, against test_kernel.mojo ---------------------
    (
        "complementary cases wound the same way (case 14 as case 1)",
        UNIT,
        KERNEL,
        "self._emit(tx, fy, fx, ly, e_t, e_l)",
        "self._emit(fx, ly, tx, fy, e_l, e_t)",
    ),
    (
        "segments chained on rounded coordinates, not edge identity",
        UNIT,
        KERNEL,
        "        self.seg_from.append(from_edge)\n        self.seg_to.append(to_edge)\n",
        "        self.seg_from.append(Int(x0 + 0.5) * W + Int(y0 + 0.5))\n"
        "        self.seg_to.append(Int(x1 + 0.5) * W + Int(y1 + 0.5))\n",
    ),
    (
        "no zero border, so a shape at a wall is an open path",
        UNIT,
        KERNEL,
        "        self._close_border()\n",
        "",
    ),
    (
        "holes are kept as shapes",
        UNIT,
        KERNEL,
        "            if not (area < 0):\n                self.holes += 1\n                continue\n",
        "",
    ),
    (
        "vertex 0 is not re-chosen after resampling",
        UNIT,
        KERNEL,
        "            if best > 0:\n                _rotate(self.cand_x, base, best)\n",
        "            if False:\n                _rotate(self.cand_x, base, best)\n",
    ),
    (
        "a shape ignores the slot it held (no matching)",
        UNIT,
        KERNEL,
        "            if best >= 0:\n                taken[best] = True\n",
        "            if False:\n                taken[best] = True\n",
    ),
    (
        "a new shape may take a slot that just emptied",
        UNIT,
        KERNEL,
        "                if not taken[k] and not was[k]:\n",
        "                if not taken[k]:\n",
    ),
    (
        "a drop is not clamped (a lone blob against the wall)",
        UNIT,
        WORLD,
        "        self.x[i] = clamp_centre(gx)\n        self.y[i] = clamp_centre(gy)\n",
        "        self.x[i] = gx\n        self.y[i] = gy\n",
    ),
]


def run_smoke() -> tuple[bool, str]:
    p = subprocess.run(
        [POE, "smoke-blobs"], capture_output=True, text=True, timeout=600
    )
    out = p.stdout + p.stderr
    return (p.returncode == 0 and "smoke-blobs OK" in out), out


def run_unit() -> tuple[bool, str]:
    p = subprocess.run(
        [MOJO, "run", "-I", "packages/m0-core", "-I", "packages/m0-http",
         "-I", "packages/m0-datastar", "-I", "apps/",
         "apps/blobs/test/test_kernel.mojo"],
        capture_output=True, text=True, timeout=600,
    )
    out = p.stdout + p.stderr
    return (p.returncode == 0 and " 0 failed" in out), out


GATES = {SMOKE: run_smoke, UNIT: run_unit}


def why(out: str) -> str:
    """The line the gate failed on, for the report."""
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
    for line in out.splitlines():
        if line.startswith(("blobs_probe: FAIL", "serve:", "idle:", "two workers", "the drain", "SIGTERM")) and (
            "FAIL" in line or "not" in line or "abandoned" in line or "exited" in line
        ):
            return line.strip()[:140]
    return out.strip().splitlines()[-1][:140] if out.strip() else "(no output)"


def main() -> int:
    sys.stdout.reconfigure(line_buffering=True)
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
    chosen = [e for e in SABOTAGES if only in e[0] or only == e[1]]
    if not chosen:
        print(f"no sabotage label contains {only!r}")
        return 1
    files = sorted({f for _, _, f, _, _ in SABOTAGES})
    backup_dir = Path(tempfile.mkdtemp())
    originals = {}
    for f in files:
        originals[f] = f.read_text()
        shutil.copy(f, backup_dir / f.name)

    print("baseline (unsabotaged) must PASS:")
    for gate in sorted({g for _, g, _, _, _ in chosen}):
        ok, out = GATES[gate]()
        print(f"  {'ok' if ok else 'FAIL'}  baseline ({gate})")
        if not ok:
            print(out[-2000:])
            return 1

    missed = []
    try:
        for label, gate, path, old, new in chosen:
            original = originals[path]
            olds = old if isinstance(old, tuple) else (old,)
            news = new if isinstance(new, tuple) else (new,)
            if any(original.count(o) != 1 for o in olds):
                print(f"  FAIL  anchor missing or ambiguous: {label}")
                missed.append(label)
                continue
            broken = original
            for o, n in zip(olds, news):
                broken = broken.replace(o, n, 1)
            path.write_text(broken)
            try:
                ok, out = GATES[gate]()
            except subprocess.TimeoutExpired:
                ok, out = False, "(timed out -- itself a failure)"
            finally:
                path.write_text(original)
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
        for f in files:
            shutil.copy(backup_dir / f.name, f)

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
