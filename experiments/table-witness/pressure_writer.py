"""Phase 3 writer (plan-d63-witness-2026-11-25.md): writes and checkpoints under the witness.

    python3 -I pressure_writer.py <db> <control-dir> <seconds> <seed>

Builds phase 1's database, writes `ready`, then loops: 60% update a
first-page title, 15% update any title, 5% insert, 5% delete, 15% insert into
`other`, and every 1-5 commits a checkpoint in a random mode. When
`pause.req` appears it makes 1-3 commits to `other` only (and half the time a
checkpoint), writes `paused.ack`, and waits for `pause.req` to go.
"""

import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bypass_matrix import build  # noqa: E402


def main():
    db, ctl, secs, seed = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
    protocol_b = len(sys.argv) > 5 and sys.argv[5] == "B"
    os.makedirs(ctl, exist_ok=True)
    for f in ("ready", "pause.req", "paused.ack", "stop", "quiet.req", "quiet.ack"):
        p = os.path.join(ctl, f)
        if os.path.exists(p):
            os.remove(p)
    w = build(db)
    rng = random.Random(seed)
    req, ack, stop = (os.path.join(ctl, f) for f in ("pause.req", "paused.ack", "stop"))
    st = {"commits": 0, "notes_writes": 0, "other_writes": 0, "pauses": 0,
          "checkpoints": {"PASSIVE": 0, "RESTART": 0, "TRUNCATE": 0}, "checkpoint_busy": 0}

    def checkpoint():
        mode = rng.choice(["PASSIVE", "RESTART", "TRUNCATE"])
        busy, _log, _done = w.execute("PRAGMA wal_checkpoint(%s)" % mode).fetchone()
        st["checkpoints"][mode] += 1
        st["checkpoint_busy"] += 1 if busy else 0

    def first_ids():
        return [r for (r,) in w.execute("SELECT id FROM notes ORDER BY id LIMIT 50")]

    w.execute("INSERT INTO other VALUES (0)")   # the row protocol B's quiet commits update
    with open(os.path.join(ctl, "ready"), "w") as f:
        f.write("1")
    ids = first_ids()
    top = w.execute("SELECT max(id) FROM notes").fetchone()[0]
    until_ck = rng.randint(1, 5)
    end = time.time() + secs
    n = 0
    while time.time() < end and not os.path.exists(stop):
        if os.path.exists(req) and protocol_b:
            # protocol B (post-hoc): one update of the `other` row first, which takes any WAL
            # restart a finished checkpoint left pending; then pause; on quiet.req make 1-3
            # updates of the same row (no growth, so no page 1) and no checkpoint, then quiet.ack
            w.execute("UPDATE other SET x = ? WHERE rowid = (SELECT min(rowid) FROM other)", (rng.random(),))
            st["commits"] += 1
            st["other_writes"] += 1
            with open(ack, "w") as f:
                f.write("1")
            qreq, qack = os.path.join(ctl, "quiet.req"), os.path.join(ctl, "quiet.ack")
            while not os.path.exists(qreq) and os.path.exists(req) and time.time() < end + 5:
                time.sleep(0.0002)
            if os.path.exists(qreq):
                for _ in range(rng.randint(1, 3)):
                    w.execute("UPDATE other SET x = ? WHERE rowid = (SELECT min(rowid) FROM other)", (rng.random(),))
                    st["commits"] += 1
                    st["other_writes"] += 1
                with open(qack, "w") as f:
                    f.write("1")
                while os.path.exists(qreq) and time.time() < end + 5:
                    time.sleep(0.0002)
                os.remove(qack)
            while os.path.exists(req) and not os.path.exists(stop) and time.time() < end + 5:
                time.sleep(0.0002)
            os.remove(ack)
            st["pauses"] += 1
            continue
        if os.path.exists(req):
            for _ in range(rng.randint(1, 3)):
                w.execute("INSERT INTO other VALUES (?)", (rng.random(),))
                st["commits"] += 1
                st["other_writes"] += 1
            if rng.random() < 0.5:
                checkpoint()
            with open(ack, "w") as f:
                f.write("1")
            while os.path.exists(req) and not os.path.exists(stop) and time.time() < end + 5:
                time.sleep(0.0002)
            os.remove(ack)
            st["pauses"] += 1
            continue
        r = rng.random()
        if r < 0.60:
            w.execute("UPDATE notes SET title = ? WHERE id = ?", ("hot %d" % n, rng.choice(ids)))
            st["notes_writes"] += 1
        elif r < 0.75:
            w.execute("UPDATE notes SET title = ? WHERE id = (SELECT id FROM notes WHERE id >= ? ORDER BY id LIMIT 1)",
                      ("any %d" % n, rng.randint(1, top)))
            st["notes_writes"] += 1
        elif r < 0.80:
            w.execute("INSERT INTO notes (title, slug, folder) VALUES (?, ?, 1)", ("new %d" % n, "p-%d-%d" % (seed, n)))
            top += 1
            st["notes_writes"] += 1
        elif r < 0.85:
            w.execute("DELETE FROM notes WHERE id = ?", (rng.choice(ids),))
            ids = first_ids()
            st["notes_writes"] += 1
        else:
            w.execute("INSERT INTO other VALUES (?)", (rng.random(),))
            st["other_writes"] += 1
        st["commits"] += 1
        n += 1
        until_ck -= 1
        if until_ck == 0:
            checkpoint()
            until_ck = rng.randint(1, 5)
    print("writer:", json.dumps(st))


if __name__ == "__main__":
    main()
