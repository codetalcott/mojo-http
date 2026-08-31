#!/usr/bin/env python3
"""Revert each rule behind SPEC I17 and insist the probe fails for every one.

Same shape as `pool_sabotage.py` and `trailer_sabotage.py`. The rule under
test is small but its failure mode is the quiet kind: a dropped WebSocket
frame is a message the peer cannot know it missed, so a server that drops one
silently looks -- from the client -- exactly like a server that sent
everything. Each sabotage below is one way to reach that, plus the inverse
(refusing frames that should be served), which only the probe's under-cap
half can catch.

Rebuilds `bin/m0serve` per sabotage, so this is minutes rather than seconds
and belongs beside the other pre-release-shaped checks rather than in the
per-PR path.

    python3 scripts/outbox_cap_sabotage.py
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HANDLER = Path("packages/m0-wsgi/src/handler.mojo")
REGISTRY = Path("packages/m0-http/src/sse/registry.mojo")
PROBE = Path("scripts/outbox_cap_probe.py")
PORT = "8156"

# (label, path, old, new)
SABOTAGES = [
    (
        "the refused frame is dropped silently instead of ending the socket",
        HANDLER,
        """                        if self._claim_lost(slot, String("websocket frame")):
                            self._end_socket(slot)""",
        """                        if self._claim_lost(slot, String("websocket frame")):
                            pass""",
    ),
    (
        "the give-up claim never fires, so the socket is never ended",
        HANDLER,
        """                    if not self.sockets.queue_frame(slot, NO_EVENT_ID, frame):""",
        """                    if False:""",
    ),
    (
        "the per-frame cap is raised, so an unqueueable message is queued",
        REGISTRY,
        "comptime MAX_PENDING_BYTES = 65536",
        "comptime MAX_PENDING_BYTES = 1048576",
    ),
    (
        "the outbox refuses every frame (the under-cap half)",
        REGISTRY,
        # Anchored on queue_frame's body, not the bare `if`: `notify_frame`
        # has the same line at deeper indentation, and a 12-space prefix is a
        # substring of a 20-space one -- so the short anchor sabotaged the
        # BROADCAST path while the probe exercised the socket path, and the
        # rule looked unguarded when the sabotage had simply landed elsewhere.
        """            if len(self.pending_bufs[slot]) + len(frame) <= MAX_PENDING_BYTES:
                self.pending_bufs[slot].extend(Span(frame))
                if event_id != NO_EVENT_ID:
                    self.last_event_ids[slot] = event_id
                return True""",
        """            if False:
                self.pending_bufs[slot].extend(Span(frame))
                if event_id != NO_EVENT_ID:
                    self.last_event_ids[slot] = event_id
                return True""",
    ),
]


def build() -> bool:
    """Rebuild the .mojoc artifacts THEN the binary.

    `build-serve` has no deps and compiles `m0serve.mojo` against the
    packages' `.mojoc` files, so editing `m0-http/src` or `m0-wsgi/src` and
    running it alone produces a binary from stale artifacts -- the sabotage
    is not in it, the probe passes, and the rule looks guarded when nothing
    was tested. `registry.mojo` is m0-http and `handler.mojo` is m0-wsgi,
    which depends on it, so both packages are rebuilt in dependency order.
    """
    for task in ("build-http", "build-wsgi", "build-serve"):
        p = subprocess.run(["uv", "run", "poe", task],
                           capture_output=True, text=True, timeout=1800)
        if p.returncode != 0:
            return False
    return True


def run_probe() -> tuple[bool, str]:
    """Start the server, run the probe, stop. True = the probe PASSED."""
    log = open("/tmp/outbox_cap_sabotage_server.log", "w")
    srv = subprocess.Popen(
        ["bin/m0serve", "bareapp.asgi:application",
         "--app-dir", "apps/asgi_bare", "--port", PORT],
        stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        for _ in range(40):
            try:
                urllib.request.urlopen("http://127.0.0.1:%s/" % PORT, timeout=1).read()
                break
            except Exception:
                if srv.poll() is not None:
                    return False, "(server exited during startup)"
                time.sleep(0.5)
        else:
            return False, "(server never became healthy)"
        p = subprocess.run([sys.executable, str(PROBE), PORT],
                           capture_output=True, text=True, timeout=180)
        return p.returncode == 0, p.stdout + p.stderr
    finally:
        try:
            srv.send_signal(signal.SIGTERM)
            srv.wait(timeout=15)
        except Exception:
            srv.kill()
        log.close()


def main() -> int:
    originals = {p: p.read_text() for p in (HANDLER, REGISTRY)}
    tmp = Path(tempfile.mkdtemp())
    for p, text in originals.items():
        (tmp / p.name).write_text(text)

    print("baseline (unsabotaged) must PASS:")
    if not build():
        print("  FAIL  baseline build")
        return 1
    ok, out = run_probe()
    print(f"  {'ok' if ok else 'FAIL'}  baseline")
    if not ok:
        print(out[-1200:])
        return 1

    failures = []
    for label, path, old, new in SABOTAGES:
        original = originals[path]
        if old not in original:
            print(f"  FAIL  anchor missing: {label}")
            failures.append(label)
            continue
        path.write_text(original.replace(old, new, 1))
        try:
            if not build():
                # A sabotage that will not compile is not evidence either way.
                print(f"  SKIP  {label} (does not build)")
                path.write_text(original)
                continue
            ok, out = run_probe()
        except subprocess.TimeoutExpired:
            ok, out = False, "(timed out — itself a failure)"
        path.write_text(original)
        good = not ok
        detail = ""
        for line in out.splitlines():
            if line.startswith("outbox-cap: "):
                detail = "  (" + line[len("outbox-cap: "):][:90] + ")"
                break
        print(f"  {'ok  ' if good else 'BAD '}  {label}{detail}")
        if not good:
            failures.append(label)

    for p, text in originals.items():
        shutil.copy(tmp / p.name, p)
    build()

    print()
    if failures:
        print(f"{len(failures)} rule(s) not covered:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"all {len(SABOTAGES)} outbox-cap rule(s) are guarded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
