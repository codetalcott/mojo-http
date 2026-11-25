"""Run tailite against phase 1's events (prior-art-wal-witness-2026-11-25.md, "Running tailite").

    python3 -I tailite_check.py <tailite-binary> <work-dir>

Builds bypass_matrix's database, follows it with `tailite watch --json
--interval 20`, runs each event, then inserts a marker row into `other` and
waits for tailite to report it. tailite's `notes` rows reported between two
markers are that event's answer; the truth is the `notes` rowids whose whole row
appeared, vanished or changed. Then 200 single-row commits for latency.
"""

import json
import os
import queue
import sqlite3
import statistics
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bypass_matrix import build, connect, first_ids, watch_sql  # noqa: E402


def main():
    tailite, work = sys.argv[1], sys.argv[2]
    os.makedirs(work, exist_ok=True)
    path = os.path.join(work, "tl.db")
    bk_path = os.path.join(work, "tl-backup.db")
    w = build(path)
    extra = os.environ.get("TAILITE_EXTRA", "").split()   # sabotage: TAILITE_EXTRA="--table other"
    proc = subprocess.Popen([tailite, "watch", path, "--json", "--interval", "20"] + extra,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    errs = []

    def pump():
        for line in proc.stdout:
            lines.put((time.perf_counter(), line))

    def pump_err():
        for line in proc.stderr:
            errs.append(line.rstrip())

    threading.Thread(target=pump, daemon=True).start()
    threading.Thread(target=pump_err, daemon=True).start()

    def rows():
        return {r[0]: r[1:] for r in w.execute("SELECT id, title, body, slug, folder FROM notes")}

    marker = [1000]

    def collect():
        """Insert a marker into `other`; answer tailite's notes rowids (and other tables seen) until it arrives."""
        marker[0] += 1
        m = marker[0]
        w.execute("INSERT INTO other VALUES (?)", (m,))
        got, other_tables = set(), set()
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                _, line = lines.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                c = json.loads(line)
            except ValueError:
                continue
            if c.get("table") == "other" and (c.get("after") or {}).get("x") == m:
                return got, other_tables, True
            if c.get("table") == "notes":
                got.add(c.get("rowid"))
            elif c.get("table") != "other":
                other_tables.add("%s:%s" % (c.get("table"), c.get("op")))
        return got, other_tables, False

    results = []

    def event(label, fn):
        before = rows()
        fn()
        after = rows()
        truth = {k for k in set(before) | set(after) if before.get(k) != after.get(k)}
        got, others, arrived = collect()
        missed = sorted(truth - got)
        extra = sorted(got - truth)
        results.append(dict(event=label, truth=sorted(truth), reported=sorted(got), missed=missed,
                            extra=extra, marker_arrived=arrived, other_tables=sorted(others)))

    _ = collect()   # tailite attached and following
    ids = first_ids(w)

    def upd(c, rid, title):
        c.execute("UPDATE notes SET title = ? WHERE id = ?", (title, rid))

    event("1 update (control)", lambda: upd(w, ids[0], "updated 1"))
    event("2 insert into another table", lambda: w.execute("INSERT INTO other VALUES (1)"))
    event("3 update storing the same title", lambda: w.execute("UPDATE notes SET title = title WHERE id = ?", (ids[1],)))

    def drop():
        for t in ("ai", "au", "am", "ad"):
            w.execute('DROP TRIGGER "m0_notes_%s"' % t)
    event("4 triggers dropped", drop)
    event("5 update after the drop", lambda: upd(w, ids[2], "updated after the drop"))
    event("5b watch restored", lambda: w.executescript(watch_sql("notes", "id")))

    def rebuild():
        w.executescript(
            "BEGIN;"
            "CREATE TABLE notes_new (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,"
            " body TEXT NOT NULL DEFAULT '', slug TEXT UNIQUE,"
            " folder INTEGER REFERENCES folders(id) ON DELETE CASCADE);"
            "INSERT INTO notes_new SELECT * FROM notes;"
            "DROP TABLE notes;"
            "ALTER TABLE notes_new RENAME TO notes;"
            "COMMIT;")
        upd(w, ids[3], "updated after the rebuild")
    event("6 migration rebuild, then an update", rebuild)
    event("6b watch restored", lambda: w.executescript(watch_sql("notes", "id")))

    def replace():
        nr = connect(path, recursive=False)
        slug = w.execute("SELECT slug FROM notes WHERE id = ?", (ids[4],)).fetchone()[0]
        nr.execute("INSERT OR REPLACE INTO notes (title, slug, folder) VALUES ('replaced', ?, 1)", (slug,))
        nr.close()
    event("7 REPLACE through slug, no recursive_triggers", replace)

    def dbconfig():
        dc = connect(path)
        dc.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_TRIGGER, False)
        upd(dc, ids[5], "updated, triggers disabled")
        dc.close()
    event("8 update with triggers disabled (DBCONFIG)", dbconfig)

    def blob():
        bc = connect(path)
        old = bc.execute("SELECT title FROM notes WHERE id = ?", (ids[6],)).fetchone()[0]
        with bc.blobopen("notes", "title", ids[6]) as b:
            b.write(("BLOB" + old)[: len(old)].encode())
        bc.close()
    event("9 title rewritten by blob I/O", blob)

    if os.path.exists(bk_path):
        os.remove(bk_path)
    bk = sqlite3.connect(bk_path)

    def before_restore():
        w.backup(bk)
        for k in range(3):
            upd(w, ids[7 + k], "before restore %d" % k)
    event("10a backup at h, then three updates", before_restore)

    def restore():
        bk.backup(w)
        for k in range(3):
            upd(w, ids[10 + k], "after restore %d" % k)
    event("10 backup restored, three other updates", restore)
    bk.close()

    event("11 VACUUM", lambda: w.execute("VACUUM"))

    def cascade():
        folder = w.execute("SELECT folder FROM notes WHERE id = ?", (ids[14],)).fetchone()[0]
        w.execute("DELETE FROM folders WHERE id = ?", (folder,))
    event("12 folder deleted, cascading to notes", cascade)

    def ckpt():
        w.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
        upd(w, ids[15], "after checkpoint")
    event("13 checkpoint TRUNCATE, then an update", ckpt)

    def grow():
        w.execute("BEGIN")
        for i in range(300):
            w.execute("INSERT INTO notes (title, slug, folder) VALUES (?, ?, 1)", ("grown %d" % i, "g-%d" % i))
        w.execute("COMMIT")
    event("14 300 inserts", grow)
    event("15 stamp counter bumped by hand", lambda: w.execute("UPDATE m0_stamp SET seq = seq + 1"))
    event("16 update (control)", lambda: upd(w, ids[16], "a plain update at the end"))

    # Q3: latency from a single-row commit to tailite's line
    lat = []
    target = ids[20]
    for i in range(0 if os.environ.get("SKIP_LATENCY") else 200):
        title = "lat-%d" % i
        t0 = time.perf_counter()
        upd(w, target, title)
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                t1, line = lines.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                c = json.loads(line)
            except ValueError:
                continue
            if c.get("table") == "notes" and (c.get("after") or {}).get("title") == title:
                lat.append((t1 - t0) * 1e3)
                break
    cpu = subprocess.run(["ps", "-o", "time=", "-p", str(proc.pid)], capture_output=True, text=True).stdout.strip()
    proc.terminate()
    proc.wait(timeout=5)

    print("sqlite (writer)", sqlite3.sqlite_version, "python", sys.version.split()[0], "tailite extra args:", extra)
    print("tailite stderr:", errs[:3])
    print("%-48s %-22s %-22s %-10s %s" % ("event", "truth", "tailite", "missed", "extra / other tables"))
    for r in results:
        print("%-48s %-22s %-22s %-10s %s %s%s" % (r["event"][:48], str(r["truth"])[:22], str(r["reported"])[:22],
                                                str(r["missed"]), str(r["extra"])[:40], r["other_tables"][:4],
                                                "" if r["marker_arrived"] else "  MARKER NOT SEEN"))
    misses = [r["event"].split()[0] for r in results if r["missed"] or not r["marker_arrived"]]
    print("events with a missed row (or no marker):", misses)
    if lat:
        lat.sort()
        print("latency ms over %d commits: median=%.1f p90=%.1f max=%.1f (interval 20 ms)" % (
            len(lat), statistics.median(lat), lat[int(0.9 * len(lat))], lat[-1]))
    print("tailite CPU time over the run:", cpu)
    print("verdict:", "A (no event missed a row)" if not misses else "C")
    with open(os.path.join(work, "tailite.json"), "w") as f:
        json.dump(results, f, indent=1)
    return 0 if not misses else 1


if __name__ == "__main__":
    sys.exit(main())
