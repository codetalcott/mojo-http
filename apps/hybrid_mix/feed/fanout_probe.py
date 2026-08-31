"""The cross-worker fan-out probe: spread, then delivery, then ids.

Six streams against M0_WORKERS=2 -- the accept race spreads them (the
same technique smoke-counter trusts) -- then one publish must reach every
stream on BOTH workers. Ids must be distinct across publishes even when
they come from different workers (the shared atomic), unless the C ABI
library is absent, in which case both are -1 and the id assertion is
skipped rather than failed (delivery is the contract; suppression is the
upgrade -- m0pub's own degradation posture).

**Spread is a precondition, not the contract, and it is a race.** Nothing
makes the kernel hand six near-simultaneous connections to both workers;
with a shared listener the accept race can legitimately put all six on
one, and then there is no cross-worker delivery left to verify. Measured
on an idle laptop that happens roughly 5-8% of the time, on unmodified
main as readily as anywhere else, which on CI reads as a mystery failure
in whatever PR drew the short straw.

So the two outcomes are separated. A stream that misses the broadcast is
a REAL failure and exits immediately -- retrying would only hide it.
Streams that failed to spread are a failed setup: the attempt is thrown
away and retried, and only a run that cannot achieve spread in
`FANOUT_ATTEMPTS` tries fails, because that is no longer luck.

Exits 1 with the evidence on failure, so the smoke can just run it.
"""

import os
import sys
import threading
import time
import traceback
import urllib.request

BASE = "http://127.0.0.1:" + os.environ.get("M0_PORT", "8150")
WANT_WORKERS = int(os.environ.get("FANOUT_WORKERS", "2"))
ATTEMPTS = int(os.environ.get("FANOUT_ATTEMPTS", "4"))


# Which phase is running, for the crash handler below. A traceback names the
# CALL that raised -- here `read_stream`, shared by every attempt -- and never the PHASE being proven.
# apps/asgi_bare/ws_probe.py carries the original of this comment and the
# 2026-08-30 failure that motivated it.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("fanout FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def read_stream(streams, i):
    got = []
    try:
        with urllib.request.urlopen(BASE + "/events", timeout=25) as r:
            while True:
                line = r.readline()
                if not line:
                    break
                if line.startswith(b"data: "):
                    got.append(line[6:].strip().decode())
                    if got[-1] == "stop":
                        break
    except Exception as exc:  # noqa: BLE001 - the evidence IS the point
        got.append("ERR:" + str(exc))
    streams[i] = got


def attempt(count):
    """One full round: open the streams, publish twice, collect."""
    streams = {}
    threads = [
        threading.Thread(target=read_stream, args=(streams, i))
        for i in range(count)
    ]
    for t in threads:
        t.start()
    time.sleep(1.5)

    first = urllib.request.urlopen(
        BASE + "/publish?msg=hello-everyone", timeout=10
    ).read().decode()
    time.sleep(1.0)
    second = urllib.request.urlopen(
        BASE + "/publish?msg=stop", timeout=10
    ).read().decode()
    for t in threads:
        t.join(timeout=20)

    pids = set()
    delivered = 0
    for i in sorted(streams):
        got = streams[i]
        pids.add(next((g for g in got if g.startswith("pid-")), "?"))
        if "hello-everyone" in got and "stop" in got:
            delivered += 1
        else:
            print("stream %d incomplete: %r" % (i, got))
    return delivered, pids, first, second


def main():
    count = 6 if WANT_WORKERS > 1 else 2
    for attempt_no in range(1, ATTEMPTS + 1):
        phase("attempt %d: %d streams, one broadcast" % (attempt_no, count))
        delivered, pids, first, second = attempt(count)
        print(
            "fanout: %d/%d streams delivered across %d worker(s); %s | %s"
            % (delivered, count, len(pids), first, second)
        )

        # A missed broadcast is the real failure this probe exists to
        # catch. Never retry it: a retry that passes would turn a genuine
        # delivery bug into an intermittent one.
        if delivered != count:
            print("FAIL: a stream missed the broadcast")
            sys.exit(1)

        if len(pids) >= WANT_WORKERS:
            break

        # Spread is the accept race, not the product. Throw the attempt
        # away and race again.
        if attempt_no < ATTEMPTS:
            print(
                "  streams landed on %d worker(s), need %d - the accept race"
                " went one way; retrying (%d/%d)"
                % (len(pids), WANT_WORKERS, attempt_no, ATTEMPTS)
            )
            time.sleep(1.0)
    else:
        print(
            "FAIL: streams never spanned %d workers in %d attempts"
            % (WANT_WORKERS, ATTEMPTS)
        )
        sys.exit(1)

    phase("the publish ids, which must be distinct")
    ids = []
    for text in (first, second):
        for part in text.split():
            if part.startswith("id="):
                ids.append(int(part[3:]))
    if -1 not in ids and len(set(ids)) != len(ids):
        print("FAIL: publish ids were not distinct: %r" % ids)
        sys.exit(1)


if __name__ == "__main__":
    main()
