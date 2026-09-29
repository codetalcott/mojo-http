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
per-PR path. A sabotage that does not build is a miss, never a catch, and a
catch is the probe failing in its own words (`sabotage_lib.py` owns
everything around the table). Binds a fixed port: run it alone.

    python3 scripts/outbox_cap_sabotage.py
    python3 scripts/outbox_cap_sabotage.py --only "under-cap"
"""

from __future__ import annotations

import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from sabotage_lib import (DIAGNOSTIC, POE, Gate, Outcome, end_group, last_line,
                          rule, run, run_command)

HANDLER = Path("packages/m0-wsgi/src/handler.mojo")
REGISTRY = Path("packages/m0-http/src/sse/registry.mojo")
PROBE = Path("scripts/outbox_cap_probe.py")
PORT = "8156"

# (label, path, old, new[, the probe must say])
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
        # The claim alone: the frame is still offered to the queue, which
        # still refuses it, and only the `w` case's claim is gone -- the `x`
        # case's names "websocket close frame". Replacing the queue call's
        # `if` instead queued no frame at all, the under-cap one included,
        # so the probe failed on the under-cap half and never reached this.
        """                        if self._claim_lost(slot, String("websocket frame")):""",
        """                        if False:""",
        # What the claim is for: without it nothing ends the socket, and it
        # sits open with the message neither delivered nor refused.
        "neither delivered the message nor ended",
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


RULES = [rule(label, path, old, new, expect=said[0] if said else "")
         for label, path, old, new, *said in SABOTAGES]

SERVER_LOG = Path("/tmp/outbox_cap_sabotage_server.log")


def build() -> Outcome | None:
    """Rebuild the .mojoc artifacts THEN the binary; None once all three built.

    `build-serve` has no deps and compiles `m0serve.mojo` against the
    packages' `.mojoc` files, so editing `m0-http/src` or `m0-wsgi/src` and
    running it alone produces a binary from stale artifacts -- the sabotage
    is not in it, the probe passes, and the rule looks guarded when nothing
    was tested. `registry.mojo` is m0-http and `handler.mojo` is m0-wsgi,
    which depends on it, so both packages are rebuilt in dependency order.
    """
    for task in ("build-http", "build-wsgi", "build-serve"):
        p = run_command([POE, task], timeout=1800)
        if p.timed_out:
            return Outcome.unbuilt(f"`poe {task}` timed out", p.output)
        if p.returncode != 0:
            said = DIAGNOSTIC.search(p.output)
            return Outcome.unbuilt(
                f"`poe {task}`: " + (said.group(0).strip() if said else last_line(p.output)),
                p.output)
    return None


def run_probe() -> Outcome:
    """Start the server, run the probe, stop.

    A catch is the probe failing in its own words: `fail()`'s `outbox-cap:`
    line, or its excepthook's `outbox_cap_probe: FAIL:` (a read that timed
    out waiting for a frame). A server that does not come up has not been
    asked anything about the cap, so that is not a catch."""
    with open(SERVER_LOG, "w") as log:
        srv = subprocess.Popen(
            ["bin/m0serve", "bareapp.asgi:application",
             "--app-dir", "apps/asgi_bare", "--port", PORT],
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            for _ in range(40):
                try:
                    urllib.request.urlopen("http://127.0.0.1:%s/" % PORT, timeout=1).read()
                    break
                except Exception:
                    if srv.poll() is not None:
                        return Outcome.unclear("the server exited during startup: "
                                               + last_line(SERVER_LOG.read_text(errors="replace")))
                    time.sleep(0.5)
            else:
                return Outcome.unclear("the server never became healthy: "
                                       + last_line(SERVER_LOG.read_text(errors="replace")))
            p = run_command([sys.executable, str(PROBE), PORT], timeout=180)
        finally:
            if srv.poll() is None:
                srv.send_signal(signal.SIGTERM)
                try:
                    srv.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    pass
            end_group(srv, grace=0)
    if p.timed_out:
        return Outcome.failed("the probe hung: no answer in 180 s", p.output)
    if p.returncode == 0:
        return Outcome.passed(p.output)
    said = [ln for ln in p.output.splitlines()
            if ln.startswith(("outbox-cap: ", "outbox_cap_probe: FAIL"))]
    if said:
        return Outcome.failed(said[0][:140], p.output)
    return Outcome.unclear(f"the probe exited {p.returncode} without its own "
                           f"failure line: {last_line(p.output)}", p.output)


class Probe(Gate):
    def run(self, texts) -> Outcome:
        return build() or run_probe()


def finish(interrupted: bool) -> bool:
    """Leave the artifacts built from the restored tree, not the last
    sabotage: `bin/m0serve` and `m0_http.mojoc`/`m0_wsgi.mojoc` hold it."""
    if interrupted:
        print("the .mojoc artifacts and bin/m0serve may still hold a sabotage: "
              "run `uv run poe build-http`, `build-wsgi`, then `build-serve`", flush=True)
        return False
    failed = build()
    if failed is not None:
        print(f"rebuilding from the restored tree FAILED: {failed.detail}", flush=True)
        return False
    return True


def main(argv: list[str]) -> int:
    return run("sabotage-outbox-cap", RULES, Probe(), argv, finish=finish)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
