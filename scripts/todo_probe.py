"""Drive `apps/datastar_todo` on two workers for `poe smoke-todo`.

    todo_probe.py two PORT DB [N]

Opens streams until they sit on both workers (`x-worker`), finds one
keep-alive connection held by each worker, and adds N todos from each at
once. Then three assertions:

- **every stream converges**: each stream, on either worker, is sent a
  frame holding all 2N todos;
- **the page agrees**: `GET /` renders all 2N;
- **the log is monotone**: the persisted `events` table (the SQLite file
  at DB) holds every broadcast frame by id, and with only adds happening
  each frame's todos must include every todo of the frame before it. A
  frame that lacks one its predecessor had is a render that took a newer
  id than a later change -- the race the app's write lock exists to close
  (`BEGIN IMMEDIATE` held until the frame is published).

Prints one summary line and exits 0, or exits 1 naming the phase and the
first assertion that failed. Stdlib only.
"""

from __future__ import annotations

import http.client
import re
import socket
import sqlite3
import sys
import threading
import time
import traceback

TOKEN = re.compile(rb"w[01]-t\d{3}")

PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("todo_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("todo_probe: FAIL: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


class Stream:
    """One held `/events` stream; a reader thread keeps each frame's todos."""

    def __init__(self, port: int):
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        self.conn.request("GET", "/events", headers={"Accept": "text/event-stream"})
        self.sock = self.conn.sock
        self.resp = self.conn.getresponse()
        if self.resp.status != 200:
            fail(f"the stream did not open: HTTP {self.resp.status}")
        self.worker = self.resp.getheader("x-worker")
        self.sets: list[set[bytes]] = []
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
                break
            buf += chunk
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                if b"datastar-patch-elements" in block:
                    with self.lock:
                        self.sets.append(set(TOKEN.findall(block)))

    def best(self) -> int:
        with self.lock:
            return max((len(s) for s in self.sets), default=0)

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.thread.join(timeout=5)
        self.conn.close()


def worker_of(conn: http.client.HTTPConnection) -> str:
    conn.request("GET", "/health")
    resp = conn.getresponse()
    resp.read()
    return resp.getheader("x-worker") or ""


def add(conn: http.client.HTTPConnection, text: str) -> int:
    body = ('{"draft":"%s"}' % text).encode()
    conn.request(
        "POST", "/add", body=body,
        headers={"Content-Type": "application/json", "Datastar-Request": "true"},
    )
    resp = conn.getresponse()
    resp.read()
    return resp.status


def two(port: int, db: str, n: int) -> None:
    phase("streams on both workers")
    streams: list[Stream] = []
    for _ in range(8):
        streams.append(Stream(port))
        if len(streams) >= 2 and len({s.worker for s in streams}) == 2:
            break
    if sorted({s.worker for s in streams}) != ["0", "1"]:
        fail(
            f"{len(streams)} streams landed on workers {sorted({s.worker for s in streams})}"
            " -- accept sharing did not spread them, so this phase would prove nothing"
        )

    phase("a connection on each worker")
    by_worker: dict[str, http.client.HTTPConnection] = {}
    spare = []
    for _ in range(16):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        w = worker_of(c)
        if w in ("0", "1") and w not in by_worker:
            by_worker[w] = c
        else:
            spare.append(c)
        if len(by_worker) == 2:
            break
    if len(by_worker) != 2:
        fail(f"sixteen connections reached workers {sorted(by_worker)} only")

    phase("adds from both workers at once")
    codes: list[int] = []
    lock = threading.Lock()

    def burst(w: str) -> None:
        conn = by_worker[w]
        for i in range(n):
            code = add(conn, "w%s-t%03d" % (w, i))
            with lock:
                codes.append(code)

    threads = [threading.Thread(target=burst, args=(w,)) for w in ("0", "1")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for c in list(by_worker.values()) + spare:
        c.close()
    if codes.count(204) != 2 * n:
        fail(f"the adds answered {sorted(set(codes))}, not {2 * n} x 204")

    phase("every stream converges on the whole list")
    end = time.perf_counter() + 10
    while time.perf_counter() < end and any(s.best() < 2 * n for s in streams):
        time.sleep(0.05)
    short = [(s.worker, s.best()) for s in streams if s.best() < 2 * n]
    for s in streams:
        s.close()
    if short:
        fail(f"streams (worker, todos) never saw all {2 * n}: {short}")

    phase("the page agrees")
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("GET", "/")
    page = c.getresponse().read()
    c.close()
    if len(set(TOKEN.findall(page))) != 2 * n:
        fail(f"the page renders {len(set(TOKEN.findall(page)))} of {2 * n} todos")

    phase("the broadcast log is monotone")
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        rows = con.execute("SELECT id, frame FROM events ORDER BY id").fetchall()
    finally:
        con.close()
    if len(rows) != 2 * n:
        fail(f"the log holds {len(rows)} frames for {2 * n} adds")
    prev_id, prev = None, set()
    for ident, frame in rows:
        now = set(TOKEN.findall(bytes(frame)))
        lost = prev - now
        if lost:
            fail(
                f"frame {ident} lacks {sorted(lost)[:3]} that frame {prev_id} had"
                " -- a render took a newer id than a later change"
            )
        prev_id, prev = ident, now
    if len(prev) != 2 * n:
        fail(f"the last frame holds {len(prev)} of {2 * n} todos")
    print(
        "workers=2 streams=%d adds=%d frames=%d monotone=yes"
        % (len(streams), 2 * n, len(rows))
    )


def main() -> None:
    a = sys.argv
    if len(a) in (4, 5) and a[1] == "two":
        two(int(a[2]), a[3], int(a[4]) if len(a) == 5 else 25)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
