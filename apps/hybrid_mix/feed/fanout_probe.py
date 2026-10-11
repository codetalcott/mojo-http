"""The cross-worker fan-out probe: spread, then delivery, then ids.

Six streams against M0_WORKERS=2 -- the accept race spreads them (the
same technique smoke-counter trusts) -- then one publish must reach every
stream on BOTH workers. Ids must be distinct across publishes even when
they come from different workers (the shared atomic), unless the C ABI
library is absent, in which case both are -1 and the id assertion is
skipped rather than failed (delivery is the contract; suppression is the
upgrade -- m0pub's own degradation posture).

**The ids are m0pub's.** Run against a server that has published nothing,
the first publish is id 1, as `m0pub.next_event_id` numbers: the counter
starts at 0, and a first-visit subscriber stands at 0 behind a filter that
is strictly greater-than, so an id of 0 reaches nobody. And an m0pub
publish followed by a `state["m0"]` publish takes two ids from the one
counter: numbered one below m0pub's rule, the shim handed out the id m0pub
had just taken, and a hold that received the first frame dropped the
second (`/publish-m0pub` is the app's m0pub route).

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
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                                "scripts"))
from probelib import fail, phase, sse_events, stamp  # noqa: E402

BASE = "http://127.0.0.1:" + os.environ.get("M0_PORT", "8150")
WANT_WORKERS = int(os.environ.get("FANOUT_WORKERS", "2"))
ATTEMPTS = int(os.environ.get("FANOUT_ATTEMPTS", "4"))


# Which phase is running, for the crash handler. A traceback names the CALL
# that raised -- here `read_stream`, shared by every attempt -- and never the
# PHASE being proven. apps/asgi_bare/ws_probe.py carries the original of this
# comment and the 2026-08-30 failure that motivated it.
stamp("fanout FAIL", fail="FAIL: {msg}")


def read_stream(streams, i):
    got = []
    try:
        # The response, not its socket: its readline decodes a chunked body.
        with urllib.request.urlopen(BASE + "/events", timeout=25) as r:
            for ev in sse_events(r):
                if ev.data is None:
                    continue
                got.append(ev.data.strip())
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


def published_ids(text):
    """The ids in a `published id=N from pid-P` answer."""
    return [int(part[3:]) for part in text.split() if part.startswith("id=")]


def main():
    count = 6 if WANT_WORKERS > 1 else 2
    fresh_first = None
    for attempt_no in range(1, ATTEMPTS + 1):
        phase("attempt %d: %d streams, one broadcast" % (attempt_no, count))
        delivered, pids, first, second = attempt(count)
        if fresh_first is None:
            fresh_first = first
        print(
            "fanout: %d/%d streams delivered across %d worker(s); %s | %s"
            % (delivered, count, len(pids), first, second)
        )

        # A missed broadcast is the real failure this probe exists to
        # catch. Never retry it: a retry that passes would turn a genuine
        # delivery bug into an intermittent one.
        if delivered != count:
            fail("a stream missed the broadcast")

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
        fail("streams never spanned %d workers in %d attempts" % (WANT_WORKERS, ATTEMPTS))

    phase("the publish ids, which must be distinct")
    ids = published_ids(first) + published_ids(second)
    if -1 not in ids and len(set(ids)) != len(ids):
        fail("publish ids were not distinct: %r" % ids)

    phase("the fresh server's first publish, which must be id 1")
    first_id = published_ids(fresh_first)
    if first_id != [-1] and first_id != [1]:
        fail("the first publish was not id 1, m0pub's first: %r" % fresh_first)

    phase("an m0pub publish, then a state['m0'] one: two ids")
    by_m0pub = urllib.request.urlopen(
        BASE + "/publish-m0pub", timeout=10
    ).read().decode()
    by_shim = urllib.request.urlopen(
        BASE + "/publish?msg=after-m0pub", timeout=10
    ).read().decode()
    print("ids: m0pub %s | state['m0'] %s" % (by_m0pub, by_shim))
    pair = published_ids(by_m0pub) + published_ids(by_shim)
    if len(pair) != 2:
        fail("an answer carried no id: %r | %r" % (by_m0pub, by_shim))
    if pair.count(-1) == 1:
        fail("one publisher numbered and the other could not: %r" % pair)
    if -1 not in pair and (pair[0] == pair[1] or min(pair) < 1):
        fail("m0pub and state['m0'] took ids %r from one counter; want two, each >= 1" % pair)


if __name__ == "__main__":
    main()
