"""Drive `apps/blobs` on the wire for `poe smoke-blobs` (SPEC N16).

    blobs_probe.py serve PORT     the main run: cadence, frames, drops, the
                                  newest state at open, the pause, the cap
    blobs_probe.py idle PORT      the slow-down after an idle stretch (the
                                  server runs with M0_BLOBS_IDLE_MS=1500)
    blobs_probe.py hold PORT FLAG hold one stream; touch FLAG once a frame
                                  has arrived; exit 0 when the server ends it

Each prints one summary line and exits 0, or exits 1 naming the first
assertion that failed. Stdlib only.

What a frame must be, every time: a `datastar-patch-signals` event whose
signals carry EVERY slot `_b0`..`_b15` (full state, never a delta), each
either empty or `polygon(...)` with exactly 48 vertices, every coordinate
inside 1–99 % (a contour that touches the stage edge is an open path the
page cannot draw), vertex 0 at the smallest y, and a negative shoelace
area in page coordinates — one winding for every loop. The frame is under
the bus's 64 KB, and the ids of one stream are contiguous.

Vertex 0 is checked as "no vertex above it", not as the kernel's exact
rule (smallest y, ties by smallest x): coordinates are rounded to 0.1 %
on the wire, which makes near-ties exact ties whose x order is rounding's.
The kernel's own test holds the exact rule.

The newest-state check is deterministic, which is why it waits for the
producer to PAUSE: with nobody watching, no step runs, so the last id the
producer published is L and stays L. A stream opened then must be sent
frame L before anything else — a server that sends only the live feed
sends L+1 first, and one that replays sends frames older than L.
"""

from __future__ import annotations

import http.client
import json
import random
import re
import socket
import sys
import threading
import time
import traceback

SLOTS = 16
NVERT = 48
BUS_MAX_FRAME = 65536
DROPS_PER_SECOND = 4

POLY = re.compile(r"^polygon\((.*)\)$")


# Which phase is running, for failures and for the crash handler: the
# phases share every helper here, and a traceback names the helper, never
# what was being proven (scripts/phase_stamp_check.py).
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("blobs_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("blobs_probe: FAIL: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


# --- HTTP helpers --------------------------------------------------------------


def get_json(port: int, path: str) -> dict:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        if resp.status != 200:
            fail(f"GET {path} answered {resp.status}")
        return json.loads(body)
    finally:
        conn.close()


def post_drop(conn: http.client.HTTPConnection, body: bytes) -> tuple[int, str]:
    conn.request(
        "POST",
        "/drop",
        body=body,
        headers={"Content-Type": "application/json", "Datastar-Request": "true"},
    )
    resp = conn.getresponse()
    resp.read()
    return resp.status, resp.getheader("retry-after") or ""


def drop_json(x: float, y: float) -> bytes:
    return json.dumps({"x": x, "y": y}).encode()


class Stream:
    """One held `/events` stream, parsed into frames by a reader thread."""

    def __init__(self, port: int, headers: dict | None = None):
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        h = {"Accept": "text/event-stream"}
        h.update(headers or {})
        self.conn.request("GET", "/events", headers=h)
        self.sock = self.conn.sock
        self.opened = time.perf_counter()
        self.resp = self.conn.getresponse()
        if self.resp.status != 200:
            fail(f"the stream did not open: HTTP {self.resp.status}")
        self.frames: list[dict] = []
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
                frame = parse_block(block)
                if frame is not None:
                    frame["t"] = time.perf_counter() - self.opened
                    with self.lock:
                        self.frames.append(frame)

    def snapshot(self) -> list[dict]:
        with self.lock:
            return list(self.frames)

    def wait_frames(self, n: int, timeout: float) -> list[dict]:
        end = time.perf_counter() + timeout
        while time.perf_counter() < end:
            got = self.snapshot()
            if len(got) >= n:
                return got
            time.sleep(0.01)
        return self.snapshot()

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.thread.join(timeout=5)
        self.conn.close()


def parse_block(block: bytes) -> dict | None:
    """One SSE event block to {id, event, signals, size}; None for comments."""
    event = None
    ident = None
    data = []
    for raw in block.split(b"\n"):
        line = raw.decode("utf-8")
        if line.startswith(":") or not line:
            continue
        name, _, value = line.partition(": ")
        if name == "event":
            event = value
        elif name == "id":
            ident = int(value)
        elif name == "data":
            data.append(value)
    if event is None:
        return None
    if event != "datastar-patch-signals":
        fail(f"unexpected event type {event!r}")
    if ident is None:
        fail("a frame carries no id")
    signals = None
    for d in data:
        if d.startswith("signals "):
            signals = json.loads(d[len("signals "):])
    if signals is None:
        fail(f"frame {ident} carries no signals line")
    return {"id": ident, "signals": signals, "size": len(block) + 2}


# --- What every frame must be ---------------------------------------------------


def check_polygon(value: str, where: str) -> tuple[float, float]:
    """Assert the polygon contract; return its (min x, min y)."""
    m = POLY.match(value)
    if not m:
        fail(f"{where}: not a polygon(): {value[:60]!r}")
    pts = []
    for pair in m.group(1).split(","):
        xs, ys = pair.split(" ")
        if not (xs.endswith("%") and ys.endswith("%")):
            fail(f"{where}: a vertex is not in percent: {pair!r}")
        pts.append((float(xs[:-1]), float(ys[:-1])))
    if len(pts) != NVERT:
        fail(f"{where}: {len(pts)} vertices, not {NVERT}")
    for x, y in pts:
        if not (1.0 <= x <= 99.0 and 1.0 <= y <= 99.0):
            fail(
                f"{where}: vertex ({x}, {y}) touches the stage edge -- a "
                "contour there is an open path, and the drop clamp exists "
                "to keep blobs clear of it"
            )
    y0 = pts[0][1]
    if min(y for _, y in pts) < y0:
        fail(f"{where}: vertex 0 (y={y0}) is not the topmost vertex")
    area = sum(
        pts[i][0] * pts[(i + 1) % NVERT][1] - pts[(i + 1) % NVERT][0] * pts[i][1]
        for i in range(NVERT)
    )
    if not area < 0:
        fail(f"{where}: winding is {'positive' if area > 0 else 'degenerate'}, not negative")
    return min(x for x, _ in pts), min(y for _, y in pts)


def check_frame(frame: dict, where: str) -> None:
    sig = frame["signals"]
    if frame["size"] >= BUS_MAX_FRAME:
        fail(f"{where}: frame {frame['id']} is {frame['size']} bytes")
    for k in range(SLOTS):
        key = f"_b{k}"
        if key not in sig:
            fail(f"{where}: frame {frame['id']} lacks {key} -- every frame is full state")
        if sig[key]:
            check_polygon(sig[key], f"{where} frame {frame['id']} {key}")
    for key in ("_step_us", "_viewers", "_blobs", "_period_ms"):
        if not isinstance(sig.get(key), int):
            fail(f"{where}: frame {frame['id']} lacks the integer {key}")
    extra = [k for k in sig if not k.startswith("_")]
    if extra:
        fail(f"{where}: frame {frame['id']} patches non-underscore signals {extra} -- they would ride every click")


def check_contiguous(frames: list[dict], where: str) -> None:
    ids = [f["id"] for f in frames]
    gaps = [(a, b) for a, b in zip(ids, ids[1:]) if b != a + 1]
    if gaps:
        fail(f"{where}: ids not contiguous, first gap {gaps[0]} of {len(gaps)}")


def filled(frame: dict) -> int:
    return sum(1 for k in range(SLOTS) if frame["signals"][f"_b{k}"])


# --- serve ------------------------------------------------------------------


def sample_now(port: int, out: list) -> None:
    worst = 0.0
    for _ in range(24):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        t0 = time.perf_counter()
        try:
            conn.request("GET", "/now")
            conn.getresponse().read()
        finally:
            conn.close()
        worst = max(worst, (time.perf_counter() - t0) * 1000.0)
        time.sleep(random.uniform(0.05, 0.15))
    out.append(worst)


def wait_paused(port: int, timeout: float = 5.0) -> dict:
    """Stats once the producer has been paused, with a stable last id."""
    end = time.perf_counter() + timeout
    prev = None
    while time.perf_counter() < end:
        st = get_json(port, "/stats")
        if st["paused"] == 1 and st["viewers"] == 0:
            if prev is not None and prev["last_id"] == st["last_id"]:
                return st
            prev = st
        else:
            prev = None
        time.sleep(0.15)
    fail(f"the producer never paused with nobody watching: {get_json(port, '/stats')}")
    return {}


def serve(port: int) -> None:
    hz = 10
    phase("a paused producer before anyone watches")
    st = get_json(port, "/stats")
    if st["paused"] != 1 or st["steps"] != 0:
        fail(f"with nobody watching yet the producer should be paused at 0 steps: {st}")

    phase("opening two streams")
    s1 = Stream(port)
    s2 = Stream(port)
    if s1.resp.getheader("content-type", "").split(";")[0] != "text/event-stream":
        fail("the stream is not text/event-stream")
    worst: list = []
    sampler = threading.Thread(target=sample_now, args=(port, worst))
    sampler.start()

    # Let a few frames arrive with the five seeded blobs, then drop.
    phase("the first frames")
    first = s1.wait_frames(3, 5.0)
    if len(first) < 3:
        fail(f"only {len(first)} frames in 5 s at {hz} Hz -- the producer is not reaching the stream")
    before = first[-1]
    if filled(before) != 5 or before["signals"]["_b5"] != "":
        fail(f"expected five seeded blobs in slots 0-4, got {filled(before)} filled")

    # One drop at the very corner: it must land clamped, in slot 5, on
    # BOTH streams. Then two more connections fill the world past its cap.
    phase("a corner drop reaching both streams")
    a = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    status, _ = post_drop(a, drop_json(0, 0))
    if status != 204:
        fail(f"a valid drop answered {status}")
    t_drop = time.perf_counter()
    seen = {}
    while time.perf_counter() - t_drop < 3.0 and len(seen) < 2:
        for name, s in (("s1", s1), ("s2", s2)):
            for f in s.snapshot():
                if name not in seen and f["signals"]["_b5"]:
                    seen[name] = f
        time.sleep(0.02)
    if len(seen) < 2:
        fail(f"a drop reached {sorted(seen)} of the two open streams within 3 s")
    minx, miny = check_polygon(seen["s1"]["signals"]["_b5"], "the corner drop")
    if minx > 20 or miny > 20:
        fail(f"a drop at (0, 0) landed with its top-left at ({minx}, {miny}), not near the corner")

    phase("filling the world past its cap")
    extra = [a] + [http.client.HTTPConnection("127.0.0.1", port, timeout=10) for _ in range(2)]
    results: list[int] = []
    lock = threading.Lock()

    def burst(conn, n):
        for _ in range(n):
            code, _ = post_drop(conn, drop_json(random.uniform(0, 100), random.uniform(0, 100)))
            with lock:
                results.append(code)

    # Connection `a` has one drop in its second already.
    workers = [
        threading.Thread(target=burst, args=(extra[0], DROPS_PER_SECOND - 1)),
        threading.Thread(target=burst, args=(extra[1], DROPS_PER_SECOND)),
        threading.Thread(target=burst, args=(extra[2], DROPS_PER_SECOND)),
    ]
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    for c in extra:
        c.close()
    if results.count(204) != 3 * DROPS_PER_SECOND - 1:
        fail(f"the fill burst answered {results}")
    full = None
    end = time.perf_counter() + 3.0
    while time.perf_counter() < end:
        got = [f for f in s1.snapshot() if f["signals"]["_blobs"] == 16]
        if got:
            full = got[-1]
            break
        time.sleep(0.02)
    if full is None or filled(full) != 16:
        fail("the world never reached 16 blobs after 17 drops and seeds -- eviction or the cap is off")

    time.sleep(0.8)
    sampler.join()
    f1 = s1.snapshot()
    f2 = s2.snapshot()
    held_for = time.perf_counter() - s1.opened
    s1.close()
    s2.close()

    phase("checking every frame held")
    for name, frames in (("s1", f1), ("s2", f2)):
        for f in frames:
            check_frame(f, name)
        check_contiguous(frames, name)
    expected = held_for * hz
    if not (0.5 * expected <= len(f1) <= 1.3 * expected + 2):
        fail(f"{len(f1)} frames in {held_for:.1f} s at {hz} Hz: outside {0.5 * expected:.0f}-{1.3 * expected + 2:.0f}")
    worst_now = int(worst[0]) if worst else -1
    if not (0 <= worst_now < 100):
        fail(f"a trivial request waited {worst_now} ms while steps ran")

    # The newest state at open, and only it.
    phase("the newest state at open")
    st = wait_paused(port)
    last = st["last_id"]
    s4 = Stream(port, {"Last-Event-ID": str(max(0, last - 5))})
    got = s4.wait_frames(2, 3.0)
    s4.close()
    if not got:
        fail("a stream opened on a paused producer was sent nothing -- no current state at open")
    if got[0]["id"] != last:
        fail(
            f"the first frame a new stream got was id {got[0]['id']}, not the newest state {last}"
            + (" -- that is a replay" if got[0]["id"] < last else " -- that is the live feed, with no current state at open")
        )
    if sum(1 for f in got if f["id"] <= last) != 1:
        fail(f"frames up to {last} were sent more than once: {[f['id'] for f in got]}")
    if got[0]["signals"]["_blobs"] != 16:
        fail("the state sent at open is not the world the drops built")
    if len(got) < 2 or got[1]["id"] != last + 1:
        fail(f"the producer did not resume for the new viewer: {[f['id'] for f in got]}")
    check_frame(got[0], "open")

    # Nobody watching again: no steps at all.
    phase("no steps with nobody watching")
    st = wait_paused(port)
    time.sleep(0.6)
    st2 = get_json(port, "/stats")
    if st2["steps"] != st["steps"]:
        fail(f"steps went from {st['steps']} to {st2['steps']} with nobody watching")

    # Bad bodies are refused and do not count; a non-UTF-8 byte after a
    # number is read, not trapped (G14); the fifth drop in a second is 429.
    phase("bad bodies and the drop cap")
    time.sleep(1.1)
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    codes = []
    retry = ""
    for body in (b'{"x":"a","y":1}', b'{"y":5}', b'{"y":2,"x":1\x80}') + tuple(
        drop_json(50, 50) for _ in range(5)
    ):
        code, ra = post_drop(c, body)
        codes.append(code)
        if code == 429:
            retry = ra
    c.close()
    want = [400, 400] + [204] * DROPS_PER_SECOND + [429, 429]
    if codes != want:
        fail(f"drop answers {codes}, want {want}")
    if retry != "1":
        fail(f"a 429 carried Retry-After {retry!r}, not '1'")
    if get_json(port, "/health").get("status") != "ok":
        fail("the server is not healthy after the bad bodies")

    phase("the producer's counters")
    st = get_json(port, "/stats")
    if st["refused"] != 0:
        fail(f"the bus refused {st['refused']} frames")
    if st["lost"] != 0:
        fail(f"{st['lost']} drops were lost")
    if not (9000 <= st["frame_max"] < BUS_MAX_FRAME):
        fail(f"the largest frame was {st['frame_max']} bytes; a full stage should be ~9.7 KB")
    print(
        "frames=%d held_s=%.1f worst_now_ms=%d frame_max=%d per_viewer_bps=%d step_us_max=%d drops=%d"
        % (
            len(f1), held_for, worst_now, st["frame_max"], st["frame_max"] * hz,
            st["step_us_max"], st["drops"],
        )
    )


# --- idle ----------------------------------------------------------------------


def idle(port: int) -> None:
    phase("the idle stream")
    s = Stream(port)
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    t0 = time.perf_counter()
    if post_drop(conn, drop_json(40, 40))[0] != 204:
        fail("the idle phase's first drop was refused")
    time.sleep(3.5 - (time.perf_counter() - t0))
    if post_drop(conn, drop_json(60, 60))[0] != 204:
        fail("the idle phase's second drop was refused")
    conn.close()
    # The second drop restarts the 1.5 s idle clock, so the stream is read
    # to just before it would run out again, at 5.0 s.
    time.sleep(4.9 - (time.perf_counter() - t0))
    frames = s.snapshot()
    s.close()
    base = t0 - s.opened

    def window(a, b):
        return [f for f in frames if a <= f["t"] - base < b]

    busy = window(0.3, 1.3)
    quiet = window(2.2, 3.5)
    back = window(4.2, 4.9)
    periods = lambda fs: sorted({f["signals"]["_period_ms"] for f in fs})
    if len(busy) < 5 or periods(busy) != [100]:
        fail(f"after a drop: {len(busy)} frames at periods {periods(busy)}, want >=5 at [100]")
    if len(quiet) > 5 or periods(quiet) != [500]:
        fail(f"after 1.5 s without a drop: {len(quiet)} frames at periods {periods(quiet)}, want <=5 at [500]")
    if len(back) < 4 or periods(back) != [100]:
        fail(f"after a new drop: {len(back)} frames at periods {periods(back)}, want >=4 at [100]")
    print("busy=%d quiet=%d back=%d" % (len(busy), len(quiet), len(back)))


# --- hold -----------------------------------------------------------------------


def hold(port: int, flag: str) -> None:
    phase("holding a stream for the drain")
    s = Stream(port)
    if not s.wait_frames(1, 5.0):
        fail("the held stream got no frame")
    with open(flag, "w") as fh:
        fh.write("holding\n")
    phase("waiting for the drain to end the stream")
    s.thread.join(timeout=15)
    if not s.ended:
        fail("the server did not end the held stream within 15 s of the drain")
    print("held stream ended by the server after %d frames" % len(s.snapshot()))


def main() -> None:
    if len(sys.argv) >= 3 and sys.argv[1] == "serve":
        serve(int(sys.argv[2]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "idle":
        idle(int(sys.argv[2]))
    elif len(sys.argv) == 4 and sys.argv[1] == "hold":
        hold(int(sys.argv[2]), sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
