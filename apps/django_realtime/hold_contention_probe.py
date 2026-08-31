#!/usr/bin/env python3
"""How many `--realtime` holds can be taken AT ONCE, and what does it cost?

`realtime_probe.py` proves the mechanism; this measures its threshold. The
distinction matters because no gate anywhere took more than one hold at a
time: that probe handshakes SEQUENTIALLY -- every subscribe completes before
the next begins -- so with four pool threads configured the number of holds
in flight was one, whatever the smoke's name suggested.

**What contention exercises.** A hold taken on a pool thread travels to the
loop as a reserved `h` frame on ONE `SOCK_DGRAM` bus channel per loop, and N
pool threads are N producers on it. That is the same "one shared socket pair,
N producers" shape whose per-stream windows over-committed the ASGI chunk
channel -- twelve concurrent Django `FileResponse`s were enough there -- and
this channel has no budget at all. Both degradations are documented and
deliberate: a publish meeting a full buffer is DROPPED on EAGAIN
(`broadcast.mojo`), and a hold frame meeting one becomes a 503
(`handler.mojo`, "a client holding a dead stream").

So the honest claim was never "there is a race" -- it is that **the threshold
is unmeasured**. Nobody knew how many concurrent holds, or how heavy a publish
rate beside them, turns a working server into one issuing 503s and silently
losing broadcasts. This puts a number on it, and the number is the deliverable
whether or not it also finds a defect.

**Two things it measures, because they fail differently.** A refused hold is
LOUD -- the client gets a 503 and knows. A dropped publish is SILENT: every
subscriber stays connected and simply never sees the message. The second is
the one worth a gate.

    python3 apps/django_realtime/hold_contention_probe.py PORT [--sweep|--selftest]

Without `--sweep` it runs one width and asserts a floor well inside what
works. With it, it walks the widths and reports where each degradation starts
-- which is how the floor below was chosen rather than guessed.
"""

import json
import os
import socket
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
SWEEP = "--sweep" in sys.argv
SELFTEST = "--selftest" in sys.argv
TOKEN = "letmein"

# The widths the sweep walks. 4 is the pool the smoke configures; the rest
# ask what happens past it. Overridable so the sweep can be pushed further
# than the default without editing the file -- finding the ceiling is the
# point, and it moves with the pool size and the box.
WIDTHS = tuple(
    int(w) for w in os.environ.get("M0_HOLD_WIDTHS", "4,16,32,64,128").split(",")
)

# The asserted width and floors for the non-sweep run. Deliberately inside
# what the sweep measured as clean, so this is a regression gate and not a
# capacity test that goes red on a slow runner.
GATE_WIDTH = 32
GATE_MIN_HOLDS = 32          # every hold at this width must be granted
GATE_MIN_DELIVERY = 1.0      # and every subscriber must see every message

MESSAGES = int(os.environ.get("M0_HOLD_MESSAGES", "5"))
# Seconds between publishes. 0 is the burst: the fan-out has to reach every
# subscriber before the next one arrives, which is what pressures each
# connection's outbox rather than the bus channel.
PUBLISH_GAP = float(os.environ.get("M0_HOLD_PUBLISH_GAP", "0.15"))


# Which phase is running, for the crash handler below. A traceback names the
# CALL that failed -- here that is a shared `recv` or `urlopen` inside a
# worker thread -- and never the PHASE being proven.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("hold_contention FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("hold_contention FAIL:", msg)
    sys.exit(1)


class Holder(threading.Thread):
    """One SSE subscriber, holding its connection open and counting events.

    Raw sockets rather than urllib: the point is to have N of these in
    flight AT THE SAME INSTANT, and a barrier plus a blocking read is the
    honest way to do that. `status` is the hold's outcome -- 200 means the
    server took it, 503 means it refused.
    """

    def __init__(self, index, channel, barrier):
        super().__init__(daemon=True)
        self.index = index
        self.channel = channel
        self.barrier = barrier
        self.status = None
        self.events = []
        self.error = None
        self.sock = None

    def run(self):
        try:
            s = socket.create_connection((HOST, PORT), timeout=20)
            self.sock = s
            req = (
                "GET /events?token=%s&channel=%s HTTP/1.1\r\n"
                "Host: %s\r\nAccept: text/event-stream\r\n\r\n"
                % (TOKEN, self.channel, HOST)
            )
            # Every holder waits here, so the writes go out together and the
            # loop sees N hold frames in one window rather than N in a row.
            self.barrier.wait(timeout=30)
            s.sendall(req.encode())
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = s.recv(4096)
                if not chunk:
                    self.error = "closed before the response head"
                    return
                buf += chunk
            head, _, rest = buf.partition(b"\r\n\r\n")
            self.status = int(head.split(b"\r\n", 1)[0].split()[1])
            if self.status != 200:
                return
            s.settimeout(12)
            body = rest
            deadline = time.time() + 12
            while time.time() < deadline:
                try:
                    chunk = s.recv(4096)
                except socket.timeout:
                    break
                if not chunk:
                    break
                body += chunk
                for line in body.split(b"\n"):
                    if line.startswith(b"data: "):
                        v = line[6:].decode("utf-8", "replace").strip()
                        if v and v not in self.events:
                            self.events.append(v)
                if len(self.events) >= MESSAGES:
                    break
        except Exception as exc:            # noqa: BLE001 -- reported, not raised
            self.error = "%r" % (exc,)

    def close(self):
        try:
            if self.sock:
                self.sock.close()
        except OSError:
            pass


def publish(channel, msg):
    data = urllib.parse.urlencode({"channel": channel, "msg": msg}).encode()
    req = urllib.request.Request("http://%s:%d/publish" % (HOST, PORT), data=data)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode())


def run_width(width):
    """Take `width` holds at once, publish, and count what arrived."""
    channel = "load%d" % width
    barrier = threading.Barrier(width + 1)
    holders = [Holder(i, channel, barrier) for i in range(width)]
    for h in holders:
        h.start()
    barrier.wait(timeout=30)                # release them together

    # Let the subscriptions settle before publishing: a publish that beats a
    # subscribe is a miss that says nothing about capacity.
    time.sleep(2.0)

    granted = [h for h in holders if h.status == 200]
    refused = [h for h in holders if h.status is not None and h.status != 200]
    broken = [h for h in holders if h.status is None]

    sent = []
    for i in range(MESSAGES):
        msg = "m%d-%d" % (width, i)
        try:
            publish(channel, msg)
            sent.append(msg)
        except (urllib.error.URLError, OSError) as exc:
            print("    publish %d failed: %r" % (i, exc))
        if PUBLISH_GAP:
            time.sleep(PUBLISH_GAP)

    for h in holders:
        h.join(timeout=20)
    for h in holders:
        h.close()

    expected = len(granted) * len(sent)
    delivered = sum(
        len([e for e in h.events if e in sent]) for h in granted
    )
    return {
        "width": width,
        "granted": len(granted),
        "refused": len(refused),
        "broken": len(broken),
        "refused_codes": sorted({h.status for h in refused}),
        "published": len(sent),
        "expected": expected,
        "delivered": delivered,
        "delivery": (delivered / expected) if expected else 0.0,
    }


def report(r):
    print(
        "  width %4d: holds %3d/%-3d granted%s | delivery %5.1f%% (%d/%d)%s"
        % (
            r["width"], r["granted"], r["width"],
            (" REFUSED %s" % r["refused_codes"]) if r["refused"] else "",
            r["delivery"] * 100, r["delivered"], r["expected"],
            (" BROKEN %d" % r["broken"]) if r["broken"] else "",
        )
    )


def selftest():
    """Prove the two counters can FAIL before believing that they did not.

    This probe's headline result is a negative -- nothing was refused,
    nothing was lost -- and a negative from an instrument that cannot
    register a positive is worth nothing. So each counter is shown its own
    failure: a bad token must read as zero holds granted, and publishing to
    a channel nobody holds must read as zero delivery. Neither uses a
    special code path; they steer the real one.
    """
    global TOKEN, publish
    print("selftest: the counters must be able to report failure")

    saved_token = TOKEN
    TOKEN = "wrong-token"
    r = run_width(8)
    TOKEN = saved_token
    report(r)
    if r["granted"] != 0:
        fail("a refused hold (403) was still counted as granted -- the hold "
             "counter cannot see a refusal, so its zero means nothing")
    print("  ok  the hold counter registers a refusal")

    real_publish = publish
    publish = lambda channel, msg: real_publish("a-channel-nobody-holds", msg)
    try:
        r = run_width(8)
    finally:
        publish = real_publish
    report(r)
    if r["granted"] != 8:
        fail("the control run could not even take 8 holds")
    if r["delivery"] != 0.0:
        fail("a publish that reached NO subscriber was still counted as "
             "delivered -- the delivery counter cannot see loss, which is "
             "the half a subscriber cannot detect for itself")
    print("  ok  the delivery counter registers loss")
    print("selftest OK: both counters bite")


def main():
    if SELFTEST:
        phase("the selftest, proving the counters can fail")
        selftest()
        return
    if SWEEP:
        phase("the sweep, to find where each degradation starts")
        print("concurrent --realtime holds, and the cost of each width:")
        rows = []
        for w in WIDTHS:
            r = run_width(w)
            rows.append(r)
            report(r)
            time.sleep(1.0)
        first_refusal = next((r["width"] for r in rows if r["refused"]), None)
        first_loss = next((r["width"] for r in rows if r["delivery"] < 1.0), None)
        print()
        print("  first width refusing a hold : %s"
              % (first_refusal if first_refusal else "none up to %d" % WIDTHS[-1]))
        print("  first width losing a publish: %s"
              % (first_loss if first_loss else "none up to %d" % WIDTHS[-1]))
        return

    phase("taking %d holds at once" % GATE_WIDTH)
    r = run_width(GATE_WIDTH)
    report(r)

    phase("the assertions")
    if r["broken"]:
        fail("%d of %d holders never got a response head (%s)"
             % (r["broken"], r["width"],
                next((h for h in [r] if True), "")))
    if r["granted"] < GATE_MIN_HOLDS:
        fail(
            "only %d of %d concurrent holds were granted (refused %s) -- the "
            "bus channel is refusing hold frames at a width that used to "
            "work, and a refused hold is a 503 the client sees"
            % (r["granted"], GATE_WIDTH, r["refused_codes"])
        )
    if r["delivery"] < GATE_MIN_DELIVERY:
        fail(
            "delivery was %.1f%% (%d of %d) across %d concurrent holds -- a "
            "dropped publish is SILENT, so this is the half a subscriber "
            "cannot detect for itself"
            % (r["delivery"] * 100, r["delivered"], r["expected"], r["granted"])
        )
    print("hold_contention OK: %d concurrent holds, every publish delivered"
          % r["granted"])


if __name__ == "__main__":
    main()
