#!/usr/bin/env python3
"""The request body timeout, and the timer a body that arrived whole left behind.

`--body-timeout` (SPEC A23; `ServerConfig.body_read_timeout`, 30 s unless set)
bounds how long a request body may take to arrive once its headers have. The
timer is keyed by descriptor and armed where the loop parses the headers --
and until B1 it was armed ABOVE the decode of whatever came with them, so a
body that arrived whole, which is every small POST, completed with the timer
still running, and nothing deleted it. When it fired it closed whatever it
found on that descriptor:

  - a keep-alive connection idle between requests, `body_read_timeout` after
    its POST; and
  - one whose next request was out on a `--blocking-threads` pool thread,
    releasing the slot under the thread -- the next connection took the slot
    and was sent the pool thread's response. Reproduced against 1.7.0:
    connection B, opened after the timer fired, read A's `/slow` answer
    before its own.

Two changes close it: the timer is armed only for a body still owed, and the
timer handler acts only on a slot still reading a body with no request out on
a pool thread. Either one alone passes arms 1 and 2, because each covers the
other's case. Arms 4 and 5 make each one load-bearing on its own, by stopping
the server (SIGSTOP) so that a body's bytes and an expiring timer land in ONE
wait, the read first -- both kernels queue ready events in the order they
became ready:

  4. a body completes, and goes to a pool thread, in the pass that then
     reaches its own expired timer. Only the handler's state check keeps that
     timer from closing the slot under the pool thread.
  5. a keep-alive connection's NEXT upload starts in the pass that reaches the
     timer its PREVIOUS, whole, body left behind. The slot is reading a body,
     so the state check lets that timer act; only the arm that never leaves a
     timer behind a whole body keeps the second upload alive.

The stop is proven rather than assumed: a request sent during it must go
unanswered until the server continues, or arms 4 and 5 prove nothing.

And the timeout still works (3): headers and half a body, then silence, is
answered 408 and closed at the deadline -- the arm that fails when the timer
is never armed at all, which would pass every other arm here.

usage: body_timeout_probe.py PORT BODY_TIMEOUT_SECONDS
  against apps/wsgi_bare served with --blocking-threads 2, --body-timeout N
  and an --idle-timeout well above N (see `poe smoke-body-timeout`)
"""

import os
import signal
import socket
import sys
import threading
import time
import traceback

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8092
TIMEOUT = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0

# apps/wsgi_bare's /slow sleeps this long, on a pool thread.
SLOW = 1.5
# A timer fires on time (these are backend timers, not the 1 s sweep), so
# the slack only absorbs a loaded runner. EARLY separates "at the deadline"
# from "at once"; LATE is how far past it a close may still count as it.
EARLY_SLACK = 0.5
LATE_SLACK = 1.5

# The sums `/input/read` reports for the two halves of a ten-byte body.
HELLO = b"hello"
WORLD = b"world"

PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("body_timeout_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped

failures = []


def fail(msg):
    failures.append("%s: %s" % (PHASE, msg))


def post(path, length, body=b""):
    return (
        "POST %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
        % (path, length)
    ).encode() + body


def get(path):
    return ("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode()


def read_answer(body):
    """What `/input/read` answers for `body`."""
    return b"len=%d sum=%d" % (len(body), sum(body))


def parse(data):
    """Complete responses in `data` as (status, body), and the rest."""
    out = []
    while True:
        end = data.find(b"\r\n\r\n")
        if end < 0:
            break
        lines = data[:end].decode("latin-1").split("\r\n")
        try:
            status = int(lines[0].split(" ")[1])
        except (IndexError, ValueError):
            break
        length = 0
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "content-length":
                length = int(value.strip())
        if len(data) < end + 4 + length:
            break
        out.append((status, data[end + 4:end + 4 + length]))
        data = data[end + 4 + length:]
    return out, data


def sleep_until(t):
    left = t - time.monotonic()
    if left > 0:
        time.sleep(left)


class Conn:
    """A connection whose every byte, and its EOF, a thread records."""

    def __init__(self):
        self.sock = socket.create_connection((HOST, PORT), timeout=10)
        self.sock.settimeout(None)
        self.data = b""
        self.eof_at = None
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                chunk = b""
            with self.lock:
                if not chunk:
                    self.eof_at = time.monotonic()
                    return
                self.data += chunk

    def send(self, data):
        try:
            self.sock.sendall(data)
            return True
        except OSError:
            return False

    def answers(self):
        with self.lock:
            return parse(self.data)

    def closed(self):
        with self.lock:
            return self.eof_at is not None

    def wait(self, count, budget=10.0):
        """The first `count` responses, or fewer at EOF or the budget."""
        deadline = time.monotonic() + budget
        while time.monotonic() < deadline:
            got, _ = self.answers()
            if len(got) >= count or self.closed():
                break
            time.sleep(0.02)
        return self.answers()[0]

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


# --- 1. a body that arrived whole leaves nothing behind ---------------------
phase("a keep-alive connection whose POST body came with its headers, "
      "idle past the body timeout")
c = Conn()
c.send(post("/input/read", len(HELLO), HELLO))
got = c.wait(1)
if got[:1] != [(200, read_answer(HELLO))]:
    fail("the POST was not answered 200 %r: %r" % (read_answer(HELLO), got))
else:
    answered = time.monotonic()
    time.sleep(TIMEOUT + LATE_SLACK)
    if c.closed():
        fail("closed %.2fs after its POST was answered, with the idle timeout "
             "far off -- the body timer of a body that arrived whole was "
             "still running (B1)" % (c.eof_at - answered))
    else:
        c.send(get("/"))
        got = c.wait(2)
        if len(got) < 2 or got[1][0] != 200:
            fail("the next request on it was not answered 200: %r" % got)
        else:
            print("  a POST's connection still serves %.1fs after it "
                  "(body timeout %.0fs)" % (TIMEOUT + LATE_SLACK, TIMEOUT))
c.close()

# --- 2. ...and a request on a pool thread keeps its slot --------------------
# A new connection takes the lowest free slot, so eight of them are opened
# where the leftover timer would have released A's: one of them takes it on
# a server that has the bug. Each asks for its own status and must read that
# and nothing else -- the bug delivered A's /slow answer to whichever did.
phase("a request on a pool thread when a leftover timer would fire, and "
      "new connections behind it")
a = Conn()
t0 = time.monotonic()
a.send(post("/input/read", len(HELLO), HELLO))
got = a.wait(1)
if got[:1] != [(200, read_answer(HELLO))]:
    fail("the POST was not answered 200 %r: %r" % (read_answer(HELLO), got))
else:
    sleep_until(t0 + TIMEOUT - 0.5)
    a.send(get("/slow"))  # on a pool thread from here until SLOW later
    sleep_until(t0 + TIMEOUT + 0.4)
    others = []
    for i in range(8):
        b = Conn()
        b.send(get("/status?code=%d" % (230 + i)))
        others.append(b)
    # Past the /slow answer, wherever it was going to land.
    sleep_until(t0 + TIMEOUT - 0.5 + SLOW + 1.5)
    got, rest = a.answers()
    if a.closed() or got != [(200, read_answer(HELLO)), (200, b"slow done")]:
        fail("A, whose /slow was on a pool thread, read %r%s (want its POST's "
             "answer, then 'slow done', on a connection still open)"
             % (got, ", then EOF" if a.closed() else ""))
    strays = 0
    for i, b in enumerate(others):
        mine = (230 + i, b"status %d" % (230 + i))
        got, rest = b.answers()
        if got != [mine] or rest:
            strays += 1
            fail("new connection %d read %r%s, want only %r -- a pool "
                 "thread's answer reached a connection that never asked "
                 "for it" % (i, got, " + %r" % rest if rest else "", mine))
        b.close()
    if not strays and not a.closed():
        print("  a pool thread's answer reached its own connection; 8 new "
              "connections read only their own")
a.close()

# --- 3. a body that stops arriving is refused at the deadline ---------------
phase("headers and half a body, then silence, which the body timeout must "
      "refuse")
c = Conn()
sent = time.monotonic()
c.send(post("/input/read", len(HELLO + WORLD), HELLO))
deadline = sent + TIMEOUT + LATE_SLACK + 2.0
while not c.closed() and time.monotonic() < deadline:
    time.sleep(0.02)
if not c.closed():
    fail("still open %.1fs after half a body, against a %.0fs body timeout "
         "-- nothing ends an upload that stops" % (deadline - sent, TIMEOUT))
else:
    took = c.eof_at - sent
    got = c.answers()[0]
    if took < TIMEOUT - EARLY_SLACK:
        fail("closed after %.2fs, before the %.0fs body timeout"
             % (took, TIMEOUT))
    elif took > TIMEOUT + LATE_SLACK:
        fail("closed after %.2fs, past the %.0fs body timeout"
             % (took, TIMEOUT))
    elif [s for s, _ in got] != [408]:
        fail("closed without the 408 a connection's first request is owed: "
             "%r" % got)
    else:
        print("  a stalled upload was answered 408 and closed after %.2fs "
              "(body timeout %.0fs)" % (took, TIMEOUT))
c.close()

# --- 4 and 5. a timer that expires in the same wait as a read ---------------
phase("the server's own pid, for the stop")
p = Conn()
p.send(get("/pid"))
got = p.wait(1)
p.close()
pid = int(got[0][1]) if got and got[0][0] == 200 else 0
if pid <= 1 or pid == os.getpid():
    fail("/pid answered %r, not a server process to stop" % got)
else:
    phase("a stop that holds the server while bytes and a timer arrive")
    body = Conn()   # 4: the body completes in the timer's wait
    again = Conn()  # 5: the next upload starts in its stale timer's wait
    probe = Conn()  # the stop's own proof
    t0 = time.monotonic()
    body.send(post("/input/read", len(HELLO + WORLD), HELLO))
    again.send(post("/input/read", len(HELLO), HELLO))
    got = again.wait(1)
    if got[:1] != [(200, read_answer(HELLO))]:
        fail("the first POST was not answered 200 %r: %r"
             % (read_answer(HELLO), got))
    stop_at = t0 + TIMEOUT - 1.0
    now = time.monotonic()
    if now > stop_at:
        fail("the first POST took until %.2fs, past the stop at %.2fs"
             % (now - t0, stop_at - t0))
    sleep_until(stop_at)
    os.kill(pid, signal.SIGSTOP)
    try:
        # Everything below reaches the kernel while no thread of the server
        # runs: reads first, then, a second after the headers above, the
        # timers. The server wakes to all of them in one wait.
        sleep_until(t0 + TIMEOUT - 0.7)
        probe.send(get("/"))
        time.sleep(0.3)
        held = not probe.answers()[0]
        body.send(WORLD)
        again.send(post("/input/read", len(HELLO + WORLD), HELLO))
        sleep_until(t0 + TIMEOUT + 0.8)
    finally:
        os.kill(pid, signal.SIGCONT)
    if not held:
        fail("the server answered while it was stopped, so the timer and the "
             "read did not share a wait and arms 4 and 5 prove nothing")
    if probe.wait(1)[:1] != [(200, b"bare wsgi app")]:
        fail("the server did not answer after it was continued: %r"
             % (probe.answers(),))
    probe.close()

    phase("a body completed in the wait its own timer expired in (4)")
    want = read_answer(HELLO + WORLD)
    got = body.wait(1)
    if body.closed() or got != [(200, want)]:
        fail("read %r%s, want (200, %r) -- the expired timer acted on a "
             "request already handed to a pool thread, releasing its slot"
             % (got, " and EOF" if body.closed() else "", want))
    else:
        body.send(get("/"))
        got = body.wait(2)
        if len(got) < 2 or got[1][0] != 200:
            fail("the connection did not serve its next request: %r" % got)
        else:
            print("  a body completed beside its expiring timer was answered, "
                  "and its connection kept")
    body.close()

    phase("a keep-alive connection's next upload, begun in the wait a stale "
          "timer expired in (5)")
    time.sleep(0.2)
    again.send(WORLD)
    got = again.wait(2)
    if again.closed() or len(got) < 2 or got[1] != (200, want):
        fail("the second upload read %r%s, want its (200, %r) -- a timer the "
             "first, whole body left behind closed the connection while it "
             "read the second" % (got[1:], " and EOF" if again.closed()
                                  else "", want))
    else:
        print("  a second upload outlived the wait in which the first one's "
              "timer would have fired")
    again.close()

if failures:
    for f in failures:
        print("body_timeout_probe: FAIL:", f)
    sys.exit(1)

print("body_timeout_probe: a stalled body is refused at the deadline, and a "
      "timer from a body that arrived whole never outlives it")
