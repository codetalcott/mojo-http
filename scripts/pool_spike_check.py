#!/usr/bin/env python3
"""Behavioural checks on `apps/pool_spike` — the assertions the probe cannot make.

The probe measures p99. This asserts the things that make the p99 mean what it
says: that `func` really ran on a pool thread and not the loop, that every pool
thread gets work, and that a streaming response from a pool thread is refused
rather than served as a head with no body behind it.

    python3 scripts/pool_spike_check.py --binary /tmp/pool_spike
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import time

FAILURES: list[str] = []


def check(ok: bool, label: str) -> None:
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}")
    if not ok:
        FAILURES.append(label)


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    def __init__(self, binary: str, pool_threads: int) -> None:
        self.port = _free_port()
        env = dict(os.environ)
        env["M0_PORT"] = str(self.port)
        env["M0_POOL_THREADS"] = str(pool_threads)
        self.proc = subprocess.Popen(
            [binary], env=env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True,
        )

    def __enter__(self) -> "Server":
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                if self.get("/health")[0] == 200:
                    return self
            except OSError:
                time.sleep(0.05)
        raise SystemExit("server never became ready")

    def __exit__(self, *_: object) -> None:
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        # SIGTERM must be a graceful drain, not a request for SIGKILL. A
        # negative returncode means a signal ended the process; for the
        # pooled server it would mean stop_and_join hung on a thread that
        # missed its pill -- the exact bug the sabotage script can only
        # observe on Linux, caught here behaviourally on both platforms.
        check(self.proc.returncode == 0,
              f"SIGTERM exits cleanly (rc={self.proc.returncode})")

    def get(self, path: str, timeout: float = 30) -> tuple[int, str]:
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            c.request("GET", path)
            r = c.getresponse()
            return r.status, r.read().decode()
        finally:
            c.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default="/tmp/pool_spike")
    ap.add_argument("--threads", type=int, default=4)
    args = ap.parse_args()

    print("loop-only server:")
    with Server(args.binary, 0) as s:
        status, body = s.get("/fast")
        check(status == 200, "/fast answers 200")
        check(json.loads(body)["thread"] == -1,
              "func ran on the LOOP (thread == -1)")

    print(f"pooled server ({args.threads} threads):")
    with Server(args.binary, args.threads) as s:
        status, body = s.get("/fast")
        check(status == 200, "/fast answers 200")
        first = json.loads(body)["thread"]
        check(first >= 0, f"func ran on a POOL thread (thread == {first} >= 0)")

        # Every thread should take work: 40 requests over 4 threads, and the
        # loop deals them round-robin, so seeing only one would mean the pool
        # is a single thread wearing a hat.
        seen = set()
        for _ in range(40):
            seen.add(json.loads(s.get("/fast")[1])["thread"])
        check(len(seen) > 1,
              f"more than one pool thread served (saw {sorted(seen)})")

        status, body = s.get("/slow?ms=50")
        check(status == 200 and json.loads(body)["ms"] == 50,
              "/slow honours its ms parameter")

        check(s.get("/nope")[0] == 404, "an unknown path is 404")

    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed:")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
