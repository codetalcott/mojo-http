"""Drive `apps/host_check` on the wire for `poe smoke-host` (SPEC E21, E23).

    host_probe.py streams PORT N SECONDS WORKERS
        open N streams, retrying until they span WORKERS workers, hold them
        SECONDS, and require every one to carry every beat: ids contiguous
        from its first, no repeats, and at least half the beats the period
        allows
    host_probe.py hold PORT FLAG N WORKERS
        hold N streams spanning WORKERS workers; touch FLAG once each has a
        beat; exit 0 once the server has ended every one (the drain)

Each prints one summary line and exits 0, or exits 1 naming the phase and
the first assertion that failed. Stdlib only.

Every beat names the pid that produced it, and one run must see exactly
one: the loop's redelivery filter keeps the newer of two racing ids, so a
producer in every worker repeats no id a stream can see.

"Spanning" is the point of both. A producer that publishes to worker 0's
channel alone passes every frame count while every stream happens to sit
on worker 0, so a run that could not put a stream on each worker fails as
vacuous rather than passing.
"""

from __future__ import annotations

import http.client
import json
import socket
import sys
import threading
import time
import traceback

PERIOD_S = 0.1

PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("host_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("host_probe: FAIL: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


class Stream:
    """One held `/events` stream; a reader thread collects the beat ids."""

    def __init__(self, port: int):
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        self.conn.request("GET", "/events", headers={"Accept": "text/event-stream"})
        self.sock = self.conn.sock
        self.resp = self.conn.getresponse()
        if self.resp.status != 200:
            fail(f"the stream did not open: HTTP {self.resp.status}")
        self.worker = self.resp.getheader("x-worker")
        self.ids: list[int] = []
        self.pids: set[int] = set()
        self.ended = False
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self) -> None:
        buf = b""
        while True:
            try:
                chunk = self.resp.read1(65536)
            except (OSError, ValueError, http.client.HTTPException):
                break
            if not chunk:
                self.ended = True
                break
            buf += chunk
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                ident = None
                event = None
                pid = None
                for line in block.decode("utf-8").split("\n"):
                    if line.startswith("id: "):
                        ident = int(line[4:])
                    elif line.startswith("event: "):
                        event = line[7:]
                    elif line.startswith("data: "):
                        pid = json.loads(line[6:]).get("pid")
                if event == "beat" and ident is not None:
                    with self.lock:
                        self.ids.append(ident)
                        self.pids.add(pid)

    def snapshot(self) -> list[int]:
        with self.lock:
            return list(self.ids)

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.thread.join(timeout=5)
        self.conn.close()


def spread(port: int, n: int, workers: int) -> list[Stream]:
    streams: list[Stream] = []
    for _ in range(4 * n):
        streams.append(Stream(port))
        if len(streams) >= n and len({s.worker for s in streams}) >= workers:
            break
    got = sorted({s.worker for s in streams})
    if len(got) < workers:
        fail(
            f"{len(streams)} streams landed on workers {got}, not {workers} of them"
            " -- accept sharing did not spread them, so nothing here would be proven"
        )
    return streams


def check_beats(s: Stream, ids: list[int], seconds: float) -> None:
    if not ids:
        fail(f"a stream on worker {s.worker} carried no beats in {seconds} s")
    repeats = len(ids) - len(set(ids))
    if repeats:
        fail(
            f"a stream on worker {s.worker} carried {repeats} repeated beat ids"
            " -- more than one producer is publishing"
        )
    gaps = [(a, b) for a, b in zip(ids, ids[1:]) if b != a + 1]
    if gaps:
        fail(f"a stream on worker {s.worker} skipped beats, first gap {gaps[0]}")
    if len(ids) < 0.5 * seconds / PERIOD_S:
        fail(
            f"a stream on worker {s.worker} carried {len(ids)} beats in {seconds} s"
            f" at {1 / PERIOD_S:.0f} Hz -- the producer does not reach this worker's channel"
        )


def streams(port: int, n: int, seconds: float, workers: int) -> None:
    phase("streams spanning the workers")
    held = spread(port, n, workers)
    phase("every stream gets every beat")
    time.sleep(seconds)
    snaps = [(s, s.snapshot()) for s in held]
    for s, ids in snaps:
        check_beats(s, ids, seconds)
    tops = [ids[-1] for _, ids in snaps]
    if max(tops) - min(tops) > 3:
        fail(f"the streams are at different beats: {tops}")
    for s in held:
        s.close()
    # The loop keeps the newer of two racing ids, so a second producer in
    # lockstep with the first repeats no id on the wire. Its pid gives it
    # away: every beat names the process that produced it. Read after the
    # close, which joined the readers that write it.
    producers = set().union(*(s.pids for s in held))
    if len(producers) != 1:
        fail(
            f"beats came from {len(producers)} processes {sorted(producers)}"
            " -- a producer runs in more than one worker"
        )
    print(
        "workers=%d streams=%d min_beats=%d"
        % (len({s.worker for s in held}), len(held), min(len(ids) for _, ids in snaps))
    )


def hold(port: int, flag: str, n: int, workers: int) -> None:
    phase("holding streams for the drain")
    held = spread(port, n, workers)
    end = time.perf_counter() + 5
    while time.perf_counter() < end and not all(s.snapshot() for s in held):
        time.sleep(0.02)
    if not all(s.snapshot() for s in held):
        fail("a held stream got no beat within 5 s")
    with open(flag, "w") as fh:
        fh.write("holding\n")
    phase("waiting for the drain to end every stream")
    for s in held:
        s.thread.join(timeout=15)
    ended = sum(1 for s in held if s.ended)
    if ended != len(held):
        fail(f"the drain ended {ended} of {len(held)} held streams within 15 s")
    print("ended=%d workers=%d" % (ended, len({s.worker for s in held})))


def main() -> None:
    a = sys.argv
    if len(a) == 6 and a[1] == "streams":
        streams(int(a[2]), int(a[3]), float(a[4]), int(a[5]))
    elif len(a) == 6 and a[1] == "hold":
        hold(int(a[2]), a[3], int(a[4]), int(a[5]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
