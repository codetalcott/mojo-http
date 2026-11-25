"""D63 bypass matrix (plan-d63-witness-2026-11-25.md, phase 1).

    python3 -I bypass_matrix.py <work-dir> [--sabotage-witness]

Builds a WAL database watched with m0's stamp triggers (the SQL copied from
mojo-http 31fb5841 packages/m0-sqlite/src/stamps.mojo), then runs each event
and one check per design. With --sabotage-witness the witness ignores the
pages it reads (says "unchanged" whenever the salts agree), and must go stale.
"""

import json
import os
import sqlite3
import struct
import subprocess
import sys

# --- m0's stamp schema, verbatim from stamps.mojo ---------------------------

STAMP_TABLES = """
CREATE TABLE IF NOT EXISTS m0_changes(
    tbl TEXT NOT NULL, row INTEGER NOT NULL,
    seq INTEGER NOT NULL, born INTEGER NOT NULL, gone INTEGER NOT NULL,
    PRIMARY KEY (tbl, row)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS m0_changes_seq ON m0_changes(tbl, seq);
CREATE TABLE IF NOT EXISTS m0_stamp(
    id INTEGER PRIMARY KEY CHECK (id = 0),
    seq INTEGER NOT NULL, floor INTEGER NOT NULL);
INSERT OR IGNORE INTO m0_stamp VALUES (0, 0, 0);
CREATE TABLE IF NOT EXISTS m0_cursors(name TEXT PRIMARY KEY, seq INTEGER NOT NULL);
"""
_TICK = "UPDATE m0_stamp SET seq = seq + 1;"
_NOW = "(SELECT seq FROM m0_stamp)"


def _quoted(name):
    return '"' + name.replace('"', '""') + '"'


def _entry(t, row):
    return (" INSERT INTO m0_changes SELECT '" + t + "', " + row
            + ", 0, 0, 0 WHERE NOT EXISTS (SELECT 1 FROM m0_changes WHERE tbl = '"
            + t + "' AND row = " + row + "); UPDATE m0_changes SET ")


def _where(t, row):
    return " WHERE tbl = '" + t + "' AND row = " + row + ";"


def _born(t, row):
    return _TICK + _entry(t, row) + "seq = " + _NOW + ", born = " + _NOW + ", gone = 0" + _where(t, row)


def _touched(t, row):
    return _TICK + _entry(t, row) + "seq = " + _NOW + _where(t, row)


def _gone(t, row):
    return _TICK + _entry(t, row) + "seq = " + _NOW + ", gone = 1" + _where(t, row)


def watch_sql(t, key):
    new = "new." + _quoted(key)
    old = "old." + _quoted(key)
    on = " ON " + _quoted(t)
    return ('CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_ai" AFTER INSERT' + on
            + " BEGIN " + _born(t, new) + " END;"
            + 'CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_au" AFTER UPDATE' + on
            + " WHEN " + old + " = " + new + " BEGIN " + _touched(t, new) + " END;"
            + 'CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_am" AFTER UPDATE' + on
            + " WHEN " + old + " <> " + new + " BEGIN " + _gone(t, old)
            + " " + _born(t, new) + " END;"
            + 'CREATE TRIGGER IF NOT EXISTS "m0_' + t + '_ad" AFTER DELETE' + on
            + " BEGIN " + _gone(t, old) + " END;")


WATCHED_SQL = ("SELECT count(*) FROM sqlite_master WHERE type = 'trigger'"
               " AND tbl_name = 'notes' AND name IN ('m0_notes_ai', 'm0_notes_au', 'm0_notes_am', 'm0_notes_ad')")

# --- the witness ---------------------------------------------------------------


class Witness:
    """Which pages the WAL's frames wrote since a position (salt, mxFrame)."""

    def __init__(self, path, sabotage=False):
        self.path = path
        self.shm = path + "-shm"
        self.wal = path + "-wal"
        self.sabotage = sabotage

    def position(self):
        """The wal-index header's (salt bytes, mxFrame, page size), read
        until its two copies agree, as SQLite's readers do."""
        for _ in range(1000):
            try:
                with open(self.shm, "rb") as f:
                    b = f.read(96)
            except FileNotFoundError:
                return None
            if len(b) < 96:
                return None
            if b[:48] == b[48:96]:
                # Native order, except aSalt: the WAL header's bytes, copied as they are.
                (_ver, _u, _chg, is_init, _be, sz, mx, _np) = struct.unpack("<IIIBBHII", b[:24])
                if not is_init:
                    return None
                return (b[32:40], mx, 65536 if sz == 1 else sz)
        raise RuntimeError("the wal-index header's two copies never agreed")

    def frames(self, since, now):
        """Page numbers written by frames since `since` up to `now`, or a
        reason this can't be told."""
        if since is None or now is None:
            return None, "no position"
        if since[0] != now[0]:
            return None, "WAL reset (salts changed)"
        if now[1] < since[1]:
            return None, "mxFrame went back"
        page = now[2]
        pages = []
        with open(self.wal, "rb") as f:
            for i in range(since[1] + 1, now[1] + 1):
                f.seek(32 + (i - 1) * (24 + page))
                h = f.read(16)
                if h[8:16] != now[0]:
                    return None, "a frame's salts differ"
                pages.append(struct.unpack(">I", h[:4])[0])
        return pages, ""

    def table_pages(self):
        out = subprocess.run(["/usr/bin/sqlite3", "-readonly", self.path,
                              "SELECT pageno FROM dbstat WHERE name = 'notes'"],
                             capture_output=True, text=True, check=True).stdout
        return {int(x) for x in out.split()}


# --- one check's observations ----------------------------------------------------


def observe(reader, witness, prev_head):
    pos = witness.position()          # BEFORE the read transaction: the snapshot holds at least this
    dv = reader.execute("PRAGMA data_version").fetchone()[0]
    reader.execute("BEGIN")
    head = reader.execute("SELECT seq FROM m0_stamp").fetchone()[0]
    sv = reader.execute("PRAGMA schema_version").fetchone()[0]
    watched = reader.execute(WATCHED_SQL).fetchone()[0] == 4
    page = reader.execute("SELECT id, title FROM notes ORDER BY id LIMIT 50").fetchall()
    table = dict(reader.execute("SELECT id, title FROM notes").fetchall())
    stamped = {r for (r,) in reader.execute(
        "SELECT row FROM m0_changes WHERE tbl = 'notes' AND seq > ?", (prev_head,)).fetchall()}
    reader.execute("COMMIT")
    return dict(pos=pos, dv=dv, head=head, sv=sv, watched=watched, page=page, table=table, stamped=stamped)


class Design:
    def __init__(self, name):
        self.name = name
        self.page = None
        self.dv = None
        self.head = None
        self.sv = None
        self.trusted_sv = None   # D2w
        self.pos = None          # D3
        self.pages = set()       # D3
        self.refreshes = 0
        self.remaps = 0

    def check(self, o, witness):
        """Decide keep or refresh; answer (decision, reason)."""
        if self.page is None:
            return self._refresh(o, witness, "first check", remap=True)
        if o["dv"] == self.dv:
            return "keep", "clock unchanged"
        n = self.name
        if n == "D0":
            return self._refresh(o, witness, "clock moved")
        if n == "D1":
            return self._refresh(o, witness, "clock moved; rows compared")
        if n == "Dr":
            if o["head"] == self.head:
                return self._keep(o, "stamp head unchanged")
            return self._refresh(o, witness, "stamp head moved")
        if n == "D2":
            if o["head"] == self.head and o["sv"] == self.sv:
                return self._keep(o, "head and schema unchanged")
            return self._refresh(o, witness, "head or schema moved")
        if n == "D2w":
            if o["sv"] != self.sv:
                # The schema moved: verify the watch again, and refresh once.
                self.trusted_sv = o["sv"] if o["watched"] else None
                return self._refresh(o, witness, "schema moved; watched=%s" % o["watched"])
            if self.trusted_sv is None:
                return self._refresh(o, witness, "not watched: on the clock")
            if o["head"] == self.head:
                return self._keep(o, "watched, head unchanged")
            return self._refresh(o, witness, "head moved")
        if n == "D3":
            pages, why = witness.frames(self.pos, o["pos"])
            if pages is None:
                return self._refresh(o, witness, "can't tell: " + why, remap=True)
            if 1 in pages:
                return self._refresh(o, witness, "page 1 written", remap=True)
            hit = sorted(set(pages) & self.pages)
            if hit and not witness.sabotage:
                return self._refresh(o, witness, "table pages written: %d" % len(hit))
            return self._keep(o, "no table page in %d frames" % len(pages))
        raise ValueError(n)

    def _keep(self, o, why):
        self.dv = o["dv"]
        self.pos = o["pos"]
        self.sv = o["sv"]
        return "keep", why

    def _refresh(self, o, witness, why, remap=False):
        self.page = o["page"]
        self.dv = o["dv"]
        self.head = o["head"]
        self.sv = o["sv"]
        self.pos = o["pos"]
        if self.name == "D2w" and why == "first check":
            self.trusted_sv = o["sv"] if o["watched"] else None
        if self.name == "D3" and remap:
            self.pages = witness.table_pages()
            self.remaps += 1
        self.refreshes += 1
        return "refresh", why


# --- the database and the events -------------------------------------------------


def connect(path, recursive=True):
    c = sqlite3.connect(path, isolation_level=None)
    c.execute("PRAGMA foreign_keys = ON")
    if recursive:
        c.execute("PRAGMA recursive_triggers = ON")
    return c


def build(path):
    for s in ("", "-wal", "-shm"):
        if os.path.exists(path + s):
            os.remove(path + s)
    w = connect(path)
    w.execute("PRAGMA journal_mode = WAL")
    w.executescript(STAMP_TABLES)
    w.executescript(
        "CREATE TABLE folders (id INTEGER PRIMARY KEY, name TEXT);"
        "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,"
        " body TEXT NOT NULL DEFAULT '', slug TEXT UNIQUE,"
        " folder INTEGER REFERENCES folders(id) ON DELETE CASCADE);"
        "CREATE TABLE other (x INTEGER);")
    w.executescript(watch_sql("notes", "id"))
    w.execute("BEGIN")
    for f in range(1, 11):
        w.execute("INSERT INTO folders VALUES (?, ?)", (f, "folder %d" % f))
    for i in range(1, 201):
        w.execute("INSERT INTO notes (title, slug, folder) VALUES (?, ?, ?)",
                  ("note %03d title" % i, "slug-%d" % i, 1 + (i % 10)))
    w.execute("COMMIT")
    return w


def first_ids(w, n=50):
    return [r for (r,) in w.execute("SELECT id FROM notes ORDER BY id LIMIT ?", (n,)).fetchall()]


def main():
    work = sys.argv[1]
    sabotage = "--sabotage-witness" in sys.argv
    os.makedirs(work, exist_ok=True)
    path = os.path.join(work, "matrix.db")
    bk_path = os.path.join(work, "backup.db")
    w = build(path)
    reader = sqlite3.connect("file:" + path + "?mode=ro", uri=True, isolation_level=None)
    witness = Witness(path, sabotage=sabotage)
    designs = [Design(n) for n in ("D0", "Dr", "D2", "D2w", "D3", "D1")]
    rows = []
    state = {"head": 0, "table": None, "pos": None}

    def check(label, note=""):
        o = observe(reader, witness, state["head"])
        prev_table = state["table"]
        # what the frames since the last check wrote (for the record)
        pages, why = witness.frames(state["pos"], o["pos"])
        tpages = witness.table_pages()
        rec = dict(event=label, note=note,
                   dv_moved=state.get("dv") is not None and o["dv"] != state["dv"],
                   head_moved=o["head"] != state["head"], head=o["head"],
                   sv_moved=state.get("sv") is not None and o["sv"] != state["sv"],
                   watched=o["watched"],
                   page1=(None if pages is None else (1 in pages)),
                   table_page=(None if pages is None else bool(set(pages) & tpages)),
                   frames=(None if pages is None else len(pages)), frames_why=why)
        if prev_table is not None:
            changed = {k for k in set(prev_table) | set(o["table"]) if prev_table.get(k) != o["table"].get(k)}
            rec["rows_changed"] = len(changed)
            rec["feed_missed"] = sorted(changed - o["stamped"])
        for d in designs:
            dec, reason = d.check(o, witness)
            stale = d.page != o["page"]
            rec[d.name] = dict(decision=dec, reason=reason, stale=stale)
        rec["page_changed"] = prev_table is not None and state["page"] != o["page"]
        rows.append(rec)
        state.update(head=o["head"], table=o["table"], pos=o["pos"], dv=o["dv"], sv=o["sv"], page=o["page"])
        return o

    def upd(c, rid, title):
        c.execute("UPDATE notes SET title = ? WHERE id = ?", (title, rid))

    check("0 initial")
    ids = first_ids(w)

    upd(w, ids[0], "updated 1")
    check("1 update (control)")

    w.execute("INSERT INTO other VALUES (1)")
    check("2 insert into another table (control)")

    w.execute("UPDATE notes SET title = title WHERE id = ?", (ids[1],))
    check("3 update storing the same title")

    for t in ("ai", "au", "am", "ad"):
        w.execute('DROP TRIGGER "m0_notes_%s"' % t)
    check("4 triggers dropped")

    upd(w, ids[2], "updated after the drop")
    check("5 update after the drop")

    w.executescript(watch_sql("notes", "id"))
    check("5b watch restored")

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
    check("6 migration rebuild, then an update")

    w.executescript(watch_sql("notes", "id"))
    check("6b watch restored")

    nr = connect(path, recursive=False)
    slug = w.execute("SELECT slug FROM notes WHERE id = ?", (ids[4],)).fetchone()[0]
    nr.execute("INSERT OR REPLACE INTO notes (title, slug, folder) VALUES ('replaced', ?, 1)", (slug,))
    nr.close()
    check("7 REPLACE through slug, no recursive_triggers")

    dc = connect(path)
    dc.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_TRIGGER, False)
    upd(dc, ids[5], "updated, triggers disabled")
    dc.close()
    check("8 update with triggers disabled (DBCONFIG)")

    bc = connect(path)
    old = bc.execute("SELECT title FROM notes WHERE id = ?", (ids[6],)).fetchone()[0]
    new = ("BLOB" + old)[: len(old)].encode()
    with bc.blobopen("notes", "title", ids[6]) as b:
        b.write(new)
    bc.close()
    check("9 title rewritten by blob I/O")

    if os.path.exists(bk_path):
        os.remove(bk_path)
    bk = sqlite3.connect(bk_path)
    w.backup(bk)
    for k in range(3):
        upd(w, ids[7 + k], "before restore %d" % k)
    check("10a backup at h, then three updates")
    bk.backup(w)
    for k in range(3):
        upd(w, ids[10 + k], "after restore %d" % k)
    bk.close()
    check("10 backup restored (back to h), three other updates (h+3 again)")

    w.execute("VACUUM")
    check("11 VACUUM")

    folder = w.execute("SELECT folder FROM notes WHERE id = ?", (ids[14],)).fetchone()[0]
    w.execute("DELETE FROM folders WHERE id = ?", (folder,))
    check("12 folder deleted, cascading to notes")

    w.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    upd(w, ids[15], "after checkpoint")
    check("13 checkpoint TRUNCATE, then an update")

    w.execute("BEGIN")
    for i in range(300):
        w.execute("INSERT INTO notes (title, slug, folder) VALUES (?, ?, 1)", ("grown %d" % i, "g-%d" % i))
    w.execute("COMMIT")
    check("14 300 inserts")

    w.execute("UPDATE m0_stamp SET seq = seq + 1")
    check("15 stamp counter bumped by hand")

    upd(w, ids[16], "a plain update at the end")
    check("16 update (control)")

    names = [d.name for d in designs]
    print("sqlite", sqlite3.sqlite_version, "python", sys.version.split()[0], "sabotage_witness", sabotage)
    hdr = "%-60s %5s %4s %4s %4s %5s %5s | " % ("event", "page", "dv", "head", "sv", "pg1", "tbl") + " ".join("%-10s" % n for n in names) + " | feed missed"
    print(hdr)
    for r in rows:
        cells = []
        for n in names:
            d = r[n]
            cells.append("%-10s" % ((("STALE " if d["stale"] else "") + ("keep" if d["decision"] == "keep" else "refresh"))[:10]))
        yn = lambda v: "-" if v is None else ("yes" if v else "no")
        print("%-60s %5s %4s %4s %4s %5s %5s | " % (r["event"][:60], yn(r["page_changed"]), yn(r["dv_moved"]), yn(r["head_moved"]),
                                                    yn(r["sv_moved"]), yn(r["page1"]), yn(r["table_page"]))
              + " ".join(cells) + " | " + str(r.get("feed_missed", "")))
    stale = {n: [r["event"].split()[0] for r in rows if r[n]["stale"]] for n in names}
    print("stale after:", json.dumps(stale))
    print("refreshes:", {d.name: d.refreshes for d in designs}, "D3 remaps:", designs[4].remaps)
    with open(os.path.join(work, "matrix.json"), "w") as f:
        json.dump(rows, f, default=str, indent=1)
    by_event = {r["event"].split()[0]: r for r in rows}
    d3_keeps_other = by_event["2"]["D3"]["decision"] == "keep"
    d3_fewer = designs[4].refreshes < designs[0].refreshes
    print("D3 not degenerate: keeps on event 2:", d3_keeps_other, "; refreshes fewer than D0's:", d3_fewer)
    ok = not stale["D0"] and not stale["D3"] and d3_keeps_other and d3_fewer
    print("verdict:", "A (D0 and D3 never stale; D3 keeps where it can)" if ok else "C")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
