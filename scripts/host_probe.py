"""Drive `apps/host_check` on the wire for `poe smoke-host` (SPEC E21, E23).

    host_probe.py streams PORT N SECONDS WORKERS
        open N streams, retrying until they span WORKERS workers, hold them
        SECONDS, and require every one to carry every beat: ids contiguous
        from its first, no repeats, and at least half the beats the period
        allows
    host_probe.py hold PORT FLAG N WORKERS
        hold N streams spanning WORKERS workers; touch FLAG once each has a
        beat; exit 0 once the server has ended every one (the drain)
    host_probe.py respawn PORT N WORKERS
        hold N streams spanning WORKERS workers for a few seconds, SIGKILL
        the producer's process (the pid its beats name: worker 0, the tick
        owner), and require the streams STILL HELD on the sibling to beat
        again within a bound, from the respawned producer, with an id above
        the last one they saw

Each prints one summary line and exits 0, or exits 1 naming the phase and
the first assertion that failed. Stdlib only.

Every beat names the pid that produced it, and one run must see exactly
one: the loop's redelivery filter keeps the newer of two racing ids, so a
producer in every worker repeats no id a stream can see.

"Spanning" is the point of all three. A producer that publishes to worker
0's channel alone passes every frame count while every stream happens to
sit on worker 0, so a run that could not put a stream on each worker fails
as vacuous rather than passing.

The respawn phase asserts on the ALREADY-HELD sibling stream, never on a
fresh one. The loop drops any frame whose id is not above the slot's
last-seen id, so a respawned producer that numbers from a per-process
counter restarts at 1 and every stream held before the kill goes silent
for exactly the pre-kill uptime (measured: 4.21 s of silence after 41
beats over 4 s), while a stream opened after the respawn beats at once.
The pre-kill hold is longer than the post-kill bound for that reason: the
broken host's silence is the hold plus the respawn, and cannot fit.
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


PRE_KILL_S = 4.0
"""How long the streams are held before the producer's worker is killed.
Longer than `POST_KILL_BOUND_S` on purpose: see the module docstring."""

POST_KILL_BOUND_S = 2.0
"""How long a held sibling stream may go without a beat after the kill:
the supervisor's reap and fork, the worker's startup and one period, with
room for a loaded runner. Twenty periods."""


def respawn(port: int, n: int, workers: int) -> None:
    import os
    import signal

    phase("streams spanning the workers")
    held = spread(port, n, workers)
    end = time.perf_counter() + 5
    while time.perf_counter() < end and not all(s.snapshot() for s in held):
        time.sleep(0.02)
    if not all(s.snapshot() for s in held):
        fail("a held stream got no beat within 5 s")
    phase("holding streams before the kill")
    time.sleep(PRE_KILL_S)
    siblings = [s for s in held if s.worker != "0"]
    if not siblings:
        fail("no held stream sits on a sibling of worker 0, so nothing here would be proven")
    producers = set().union(*(s.pids for s in held))
    if len(producers) != 1:
        fail(f"beats came from {len(producers)} processes {sorted(producers)}")
    producer_pid = producers.pop()
    before = {id(s): s.snapshot() for s in siblings}
    phase("killing the producer's worker")
    os.kill(producer_pid, signal.SIGKILL)
    t_kill = time.perf_counter()
    phase("a beat on the already-held sibling streams after the respawn")
    deadline = t_kill + POST_KILL_BOUND_S
    silence = {}
    while time.perf_counter() < deadline and len(silence) < len(siblings):
        for s in siblings:
            if id(s) in silence:
                continue
            ids = s.snapshot()
            if len(ids) > len(before[id(s)]):
                silence[id(s)] = time.perf_counter() - t_kill
        time.sleep(0.01)
    for s in siblings:
        if id(s) not in silence:
            ids = before[id(s)]
            fail(
                f"a stream held on worker {s.worker} through the kill carried no beat"
                f" in the {POST_KILL_BOUND_S} s after it (last id {ids[-1]}, {len(ids)}"
                f" beats before) -- the respawned producer's ids are below what the"
                f" stream has seen, so the loop drops them"
            )
        ids = s.snapshot()
        last_before = before[id(s)][-1]
        first_after = ids[len(before[id(s)])]
        if first_after <= last_before:
            fail(f"a sibling stream saw id {first_after} after id {last_before}")
        if s.ended:
            fail(f"a stream held on worker {s.worker} was ended by the kill of worker 0")
    with_new = set().union(*(s.pids for s in siblings))
    if with_new == {producer_pid}:
        fail("the beats after the kill still name the killed pid")
    for s in held:
        s.close()
    print(
        "workers=%d held=%d siblings=%d silence_ms=%d pre_kill_beats=%d"
        % (
            len({s.worker for s in held}), len(held), len(siblings),
            int(1000 * max(silence.values())),
            min(len(v) for v in before.values()),
        )
    )


def main() -> None:
    a = sys.argv
    if len(a) == 6 and a[1] == "streams":
        streams(int(a[2]), int(a[3]), float(a[4]), int(a[5]))
    elif len(a) == 6 and a[1] == "hold":
        hold(int(a[2]), a[3], int(a[4]), int(a[5]))
    elif len(a) == 5 and a[1] == "respawn":
        respawn(int(a[2]), int(a[3]), int(a[4]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
