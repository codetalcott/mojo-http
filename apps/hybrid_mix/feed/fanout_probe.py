"""The cross-worker fan-out probe: spread, then delivery, then ids.

Six streams against M0_WORKERS=2 -- the accept race spreads them (the
same technique smoke-counter trusts) -- then one publish must reach every
stream on BOTH workers. Ids must be distinct across publishes even when
they come from different workers (the shared atomic), unless the C ABI
library is absent, in which case both are -1 and the id assertion is
skipped rather than failed (delivery is the contract; suppression is the
upgrade -- m0pub's own degradation posture).

Exits 1 with the evidence on failure, so the smoke can just run it.
"""

import os
import sys
import threading
import time
import urllib.request

BASE = "http://127.0.0.1:" + os.environ.get("M0_PORT", "8150")
WANT_WORKERS = int(os.environ.get("FANOUT_WORKERS", "2"))
streams = {}


def read_stream(i):
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


def main():
    count = 6 if WANT_WORKERS > 1 else 2
    threads = [
        threading.Thread(target=read_stream, args=(i,)) for i in range(count)
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

    print(
        "fanout: %d/%d streams delivered across %d worker(s); %s | %s"
        % (delivered, count, len(pids), first, second)
    )
    if delivered != count:
        print("FAIL: a stream missed the broadcast")
        sys.exit(1)
    if len(pids) < WANT_WORKERS:
        print("FAIL: streams did not span %d workers" % WANT_WORKERS)
        sys.exit(1)
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
