#!/usr/bin/env python3
"""Phase 2 pressure test: table_notes with the witness-checked page.

The question and its pass were written down before the first run;
README.md beside this file restates them. Runs a built table_notes (arm C,
or a sabotage) at M0_THREADS=2 and
M0_BLOCKING_THREADS=2 over one WAL database, with SSE clients and pollers
applying what the server sends as htmx and a client would, a background
thread of stamped writes, and a main thread of bypasses, checkpoints and
client churn. Every 50 steps the writers pause and every client is compared
with the table.

    pressure.py BINARY WORKDIR workload [--seeds N] [--steps N] [--tag T]
      workload: stamped | bypass | restart
"""
import argparse
import html
import http.client
import json
import os
import random
import re
import select
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from urllib.parse import urlencode

TITLES = ["t-aaaa", "t-bbbb", "t-cccc"]
LIST_PAGE = 50
WINDOW = 100
SEED_ROWS = 120
FORM = {"Content-Type": "application/x-www-form-urlencoded"}


# --- the server ------------------------------------------------------------------

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Server:
    def __init__(self, binary, db, log_path):
        self.binary, self.db, self.log_path = binary, db, log_path
        self.proc = None
        self.port = None

    def start(self):
        self.port = free_port()
        env = dict(os.environ, M0_PORT=str(self.port), M0_THREADS="2",
                   M0_BLOCKING_THREADS="2", M0_DB=self.db, OS_ACTIVITY_MODE="disable")
        self.log = open(self.log_path, "a")
        self.proc = subprocess.Popen([self.binary], env=env, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
                c.request("GET", "/health")
                if c.getresponse().status == 200:
                    c.close()
                    return
            except OSError:
                time.sleep(0.05)
        raise SystemExit("server did not come up")

    def stop(self):
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()


def raises_in(log_path):
    out = {"startup": 0, "mismatch": 0, "unverifiable": 0}
    with open(log_path) as f:
        for line in f:
            m = re.search(r"raised the floor to \d+: (\w+)", line)
            if m:
                out[m.group(1)] = out.get(m.group(1), 0) + 1
    return out


# --- what the server sends, read as a client reads it ---------------------------

def parse_page(body):
    """The `notes` fragment: {id: title} in page order, and the stamp its
    script opens the feed from."""
    rows = {}
    ul = re.search(r'<ul id="notes-list">(.*?)</ul>', body, re.S)
    if ul:
        for m in re.finditer(r'<li id="n(\d+)">(.*?)</li>', ul.group(1), re.S):
            a = re.search(r"<a [^>]*>(.*?)</a>", m.group(2), re.S)
            rows[int(m.group(1))] = html.unescape(a.group(1))
    head = re.search(r"/notes/events\?since=(\d+)'", body)
    return rows, (int(head.group(1)) if head else None)


def parse_event(data):
    """[(id, what, title)]: `true` replaces, `delete` removes, `append`."""
    out = []
    ul = re.search(r'<ul id="notes-list" hx-swap-oob="beforeend">(.*?)</ul>', data, re.S)
    rest = data[:ul.start()] + data[ul.end():] if ul else data
    for m in re.finditer(r'<li id="n(\d+)" hx-swap-oob="(\w+)">(.*?)</li>', rest, re.S):
        a = re.search(r"<a [^>]*>(.*?)</a>", m.group(3), re.S)
        out.append((int(m.group(1)), m.group(2), html.unescape(a.group(1)) if a else None))
    if ul:
        for m in re.finditer(r'<li id="n(\d+)">(.*?)</li>', ul.group(1), re.S):
            a = re.search(r"<a [^>]*>(.*?)</a>", m.group(2), re.S)
            out.append((int(m.group(1)), "append", html.unescape(a.group(1))))
    return out


class Http:
    def __init__(self, port):
        self.port = port
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)

    def ask(self, method, path, body=None, headers=None):
        for attempt in range(2):
            try:
                self.conn.request(method, path, body=body, headers=headers or {})
                resp = self.conn.getresponse()
                return resp.status, resp.read().decode("utf-8")
            except (http.client.HTTPException, OSError):
                self.conn.close()
                self.conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
                if attempt:
                    raise

    def close(self):
        self.conn.close()


class Client:
    """What every client keeps: the rows it holds, the stamp it stands at,
    and the page it last rendered (rows and stamp), which says what it
    should hold."""

    def __init__(self, name):
        self.name = name
        self.rows = {}
        self.head = 0
        self.render_rows = set()
        self.render_head = 0
        self.duplicates = 0

    def render(self, rows, head):
        self.rows = dict(rows)
        self.head = head
        self.render_rows = set(rows)
        self.render_head = head


class Poller(Client):
    def __init__(self, name, port):
        super().__init__(name)
        self.http = Http(port)
        self.load()

    def load(self):
        status, body = self.http.ask("GET", "/notes", headers={"HX-Request": "true"})
        assert status == 200, status
        rows, head = parse_page(body)
        self.render(rows, head)

    def poll(self):
        status, body = self.http.ask("GET", f"/notes/changes?since={self.head}")
        assert status == 200, (status, body)
        d = json.loads(body)
        if d["reset"]:
            self.load()
            return True
        for r in d["rows"]:
            if r.get("gone"):
                self.rows.pop(r["id"], None)
            elif r["born"]:
                if r["id"] in self.rows:
                    self.duplicates += 1
                self.rows[r["id"]] = r["title"]
            elif r["id"] in self.rows:
                self.rows[r["id"]] = r["title"]
        self.head = d["head"]
        return False

    def close(self):
        self.http.close()


class SSE(Client):
    def __init__(self, name, port):
        super().__init__(name)
        self.port = port
        self.http = Http(port)
        status, body = self.http.ask("GET", "/notes", headers={"HX-Request": "true"})
        assert status == 200, status
        rows, head = parse_page(body)
        self.render(rows, head)
        self.sock = None
        self.open(since=head)

    def open(self, since=None, last_event_id=None):
        self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        path = "/notes/events" if since is None else f"/notes/events?since={since}"
        req = f"GET {path} HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n"
        if last_event_id is not None:
            req += f"Last-Event-ID: {last_event_id}\r\n"
        self.sock.sendall((req + "\r\n").encode())
        self.raw = b""
        self.buf = b""
        self.status = None
        self.chunked = False
        deadline = time.time() + 5
        while self.status is None and time.time() < deadline:
            self.pump(0.05)
        assert self.status == 200, f"feed opened with {self.status}"

    def reconnect(self):
        self.sock.close()
        self.open(last_event_id=self.head)

    def _dechunk(self):
        while True:
            nl = self.raw.find(b"\r\n")
            if nl < 0:
                return
            size = int(self.raw[:nl].split(b";")[0], 16)
            if len(self.raw) < nl + 2 + size + 2:
                return
            self.buf += self.raw[nl + 2:nl + 2 + size]
            self.raw = self.raw[nl + 2 + size + 2:]

    def pump(self, wait=0.0):
        r, _, _ = select.select([self.sock], [], [], wait)
        if not r:
            return False
        data = self.sock.recv(1 << 20)
        if not data:
            return False
        self.raw += data
        if self.status is None:
            if b"\r\n\r\n" not in self.raw:
                return True
            head, self.raw = self.raw.split(b"\r\n\r\n", 1)
            self.status = int(head.split(b" ")[1])
            self.chunked = b"transfer-encoding: chunked" in head.lower()
        if self.chunked:
            self._dechunk()
        else:
            self.buf += self.raw
            self.raw = b""
        while b"\n\n" in self.buf:
            raw, self.buf = self.buf.split(b"\n\n", 1)
            text = raw.decode("utf-8")
            if text.startswith(":"):
                continue
            ev = {"id": None, "event": "message", "data": []}
            for line in text.split("\n"):
                key, _, val = line.partition(": ")
                if key == "id":
                    ev["id"] = int(val)
                elif key == "event":
                    ev["event"] = val
                elif key == "data":
                    ev["data"].append(val)
            self.apply(ev["event"], ev["id"], "\n".join(ev["data"]))
        return True

    def apply(self, kind, eid, data):
        if kind == "resync":
            rows, _ = parse_page(data)
            self.render(rows, eid)
            return
        for rid, what, title in parse_event(data):
            if what == "delete":
                self.rows.pop(rid, None)
            elif what == "append":
                if rid in self.rows:
                    self.duplicates += 1
                self.rows[rid] = title
            elif rid in self.rows:
                self.rows[rid] = title
        self.head = eid

    def close(self):
        self.sock.close()
        self.http.close()


# --- the writers -------------------------------------------------------------------

def connect(db):
    con = sqlite3.connect(db, timeout=30, isolation_level=None)
    return con


def ids_now(con):
    return [r[0] for r in con.execute("SELECT id FROM notes ORDER BY id")]


class StampedWriter(threading.Thread):
    """Updates, inserts and deletes that the triggers stamp, through the
    server's routes and through CPython's sqlite3, 0-5 ms apart."""

    def __init__(self, db, port, seed):
        super().__init__(daemon=True)
        self.db, self.port = db, port
        self.rng = random.Random(seed * 7919)
        self.go = threading.Event()
        self.stopped = False
        self.busy = threading.Lock()
        self.writes = 0
        self.bulk = 0
        self.errors = []

    def run(self):
        con = connect(self.db)
        h = Http(self.port)
        while not self.stopped:
            if not self.go.wait(0.05):
                continue
            with self.busy:
                if not self.go.is_set():
                    continue
                try:
                    self.one(con, h)
                except Exception as e:  # recorded, not swallowed
                    self.errors.append(repr(e))
            time.sleep(self.rng.random() * 0.005)
        con.close()
        h.close()

    def target(self, ids):
        if not ids:
            return None
        if self.rng.random() < 0.6:
            return self.rng.choice(ids[:WINDOW])
        return self.rng.choice(ids)

    def one(self, con, h):
        ids = ids_now(con)
        n = len(ids)
        if n >= 110 and self.rng.random() < 0.01:
            # A stamped bulk delete of 60 rows of the window, which the
            # kept-window design could not verify and raised the floor for.
            gone = self.rng.sample(ids[:WINDOW], 60)
            con.execute("DELETE FROM notes WHERE id IN (%s)" % ",".join(str(i) for i in gone))
            self.writes += 1
            self.bulk += 1
            return
        r = self.rng.random()
        op = "update" if r < 0.6 else ("insert" if r < 0.8 else "delete")
        if n < SEED_ROWS - 10 and op == "delete":
            op = "insert"
        if n > SEED_ROWS + 10 and op == "insert":
            op = "delete"
        title = self.rng.choice(TITLES)
        via_http = self.rng.random() < 0.5
        if op == "insert":
            if via_http:
                h.ask("POST", "/notes", urlencode({"title": title, "body": ""}), FORM)
            else:
                con.execute("INSERT INTO notes (title, body) VALUES (?, '')", (title,))
        elif op == "update":
            t = self.target(ids)
            if via_http:
                h.ask("POST", f"/notes/{t}/edit", urlencode({"title": title, "body": ""}), FORM)
            else:
                con.execute("UPDATE notes SET title = ? WHERE id = ?", (title, t))
        else:
            t = self.target(ids)
            if via_http:
                h.ask("DELETE", f"/notes/{t}")
            else:
                con.execute("DELETE FROM notes WHERE id = ?", (t,))
        self.writes += 1

    def pause(self):
        self.go.clear()
        with self.busy:
            pass

    def resume(self):
        self.go.set()


def bypass(db, rng, kind, where, counts):
    """A write no trigger sees: an update, delete or insert on a connection
    with triggers off, or a title rewritten by blob I/O. Made under the
    write lock, after checking the row is still there: the stamped writer
    may have deleted it since the ids were read, and a bypass that finds it
    gone is counted as `vanished`, not made."""
    con = connect(db)
    try:
        ids = ids_now(con)
        if where == "page":
            pool = ids[:LIST_PAGE]
        elif where == "margin":
            pool = ids[LIST_PAGE:WINDOW]
        else:
            pool = ids[WINDOW:]
        if kind != "insert" and not pool:
            return
        t = rng.choice(pool) if pool else None
        if kind != "blob":
            con.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_TRIGGER, False)
        con.execute("BEGIN IMMEDIATE")
        if kind != "insert":
            row = con.execute("SELECT title FROM notes WHERE id = ?", (t,)).fetchone()
            if row is None:
                con.execute("ROLLBACK")
                counts[("vanished", where)] = counts.get(("vanished", where), 0) + 1
                return
            old = row[0]
        if kind == "blob":
            new = rng.choice([x for x in TITLES if x != old])
            with con.blobopen("notes", "title", t) as b:
                b.write(new.encode())
        elif kind == "update":
            con.execute("UPDATE notes SET title = ? WHERE id = ?",
                        (rng.choice([x for x in TITLES if x != old]), t))
        elif kind == "delete":
            con.execute("DELETE FROM notes WHERE id = ?", (t,))
        else:
            con.execute("INSERT INTO notes (title, body) VALUES (?, '')", (rng.choice(TITLES),))
            where = "beyond"
        con.execute("COMMIT")
        counts[(kind, where)] = counts.get((kind, where), 0) + 1
    finally:
        con.close()


def checkpoint(db, rng):
    con = connect(db)
    try:
        con.execute("PRAGMA wal_checkpoint(%s)" % rng.choice(["PASSIVE", "TRUNCATE"])).fetchone()
    finally:
        con.close()


# --- the quiescent check -------------------------------------------------------------

def stamp(db):
    con = connect(db)
    try:
        return con.execute("SELECT seq, floor FROM m0_stamp").fetchone()
    finally:
        con.close()


def settle(db, sse, pollers, timeout=10.0):
    """Wait until every client stands at the head, and the head has held
    still for 0.4 s (eight ticks)."""
    deadline = time.time() + timeout
    still_since, last = time.time(), None
    while time.time() < deadline:
        head, _ = stamp(db)
        if head != last:
            last, still_since = head, time.time()
        for c in sse:
            c.pump(0.0)
        for p in pollers:
            if p.head != head:
                p.poll()
        if all(c.head == head for c in sse) and all(p.head == head for p in pollers) \
                and time.time() - still_since > 0.4:
            return True
        for c in sse:
            c.pump(0.01)
    return False


def truth(db):
    con = connect(db)
    try:
        rows = dict(con.execute("SELECT id, title FROM notes"))
        born = dict(con.execute("SELECT row, born FROM m0_changes WHERE tbl = 'notes' AND gone = 0"))
    finally:
        con.close()
    return rows, born


def compare(db, clients):
    rows, born = truth(db)
    ids = sorted(rows)
    pmax = ids[LIST_PAGE - 1] if len(ids) >= LIST_PAGE else (ids[-1] if ids else 0)
    err = {}
    detail = []

    def add(kind, rid, c):
        zone = "covered" if rid <= pmax else "beyond"
        err[(kind, zone)] = err.get((kind, zone), 0) + 1
        if zone == "covered" and len(detail) < 8:
            detail.append(f"{c.name}: {kind} row {rid} (held {c.rows.get(rid)!r}, truth {rows.get(rid)!r}, "
                          f"render_head {c.render_head}, head {c.head})")

    for c in clients:
        for rid, t in c.rows.items():
            if rid not in rows:
                add("extra", rid, c)
            elif t != rows[rid]:
                add("stale", rid, c)
        should = {i for i in c.render_rows if i in rows} | {i for i, b in born.items() if b > c.render_head and i in rows}
        for rid in should - set(c.rows):
            add("missing", rid, c)
        if c.duplicates:
            err[("duplicate", "any")] = err.get(("duplicate", "any"), 0) + c.duplicates
            c.duplicates = 0
    unstamped = len([i for i in rows if i not in born])
    return err, detail, unstamped


# --- the workloads ------------------------------------------------------------------------

def fresh(workdir, tag, seed):
    d = os.path.join(workdir, f"{tag}-{seed}")
    os.makedirs(d, exist_ok=True)
    db = os.path.join(d, "notes.db")
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(db + suffix):
            os.remove(db + suffix)
    return db, os.path.join(d, "server.log")


def seed_rows(db, rng):
    con = connect(db)
    con.execute("BEGIN")
    for _ in range(SEED_ROWS):
        con.execute("INSERT INTO notes (title, body) VALUES (?, '')", (rng.choice(TITLES),))
    con.execute("COMMIT")
    con.close()


def add_total(total, err):
    for k, v in err.items():
        total[k] = total.get(k, 0) + v


def run_seed(binary, workdir, tag, seed, steps, with_bypass, only_where=None):
    rng = random.Random(seed)
    db, log = fresh(workdir, tag, seed)
    srv = Server(binary, db, log)
    srv.start()
    seed_rows(db, rng)
    writer = StampedWriter(db, srv.port, seed)
    writer.start()
    sse, pollers = [], []
    n = 0
    for _ in range(4):
        n += 1
        sse.append(SSE(f"sse{n}", srv.port))
        n += 1
        pollers.append(Poller(f"poll{n}", srv.port))
    total, details, bypasses, checks, unsettled, unstamped = {}, [], {}, 0, 0, 0
    writer.resume()
    for step in range(1, steps + 1):
        r = rng.random()
        if with_bypass and r < 0.10:
            kind = rng.choice(["update", "update", "delete", "insert", "blob", "blob"])
            where = only_where or rng.choice(["page", "page", "page", "margin", "beyond"])
            bypass(db, rng, kind, where, bypasses)
        elif r < 0.15:
            checkpoint(db, rng)
        elif r < 0.19:
            n += 1
            if rng.random() < 0.5:
                sse.append(SSE(f"sse{n}", srv.port))
            else:
                pollers.append(Poller(f"poll{n}", srv.port))
        elif r < 0.21 and len(sse) + len(pollers) > 4:
            group = sse if (rng.random() < 0.5 and len(sse) > 1) else pollers
            if len(group) > 1:
                group.pop(rng.randrange(len(group))).close()
        elif r < 0.25 and sse:
            rng.choice(sse).reconnect()
        elif r < 0.65 and pollers:
            rng.choice(pollers).poll()
        else:
            for c in sse:
                c.pump(0.0)
        time.sleep(rng.random() * 0.003)
        if step % 50 == 0:
            writer.pause()
            ok = settle(db, sse, pollers)
            if not ok:
                unsettled += 1
            err, detail, un = compare(db, sse + pollers)
            unstamped = un
            add_total(total, err)
            details += detail
            checks += 1
            writer.resume()
    writer.pause()
    writer.stopped = True
    writer.join(timeout=5)
    for c in sse + pollers:
        c.close()
    srv.stop()
    return {
        "seed": seed, "errors": total, "detail": details[:8], "bypasses": bypasses,
        "raises": raises_in(log), "checks": checks, "unsettled": unsettled,
        "writes": writer.writes, "bulk_deletes": writer.bulk, "writer_errors": writer.errors[:3],
        "unstamped_rows": unstamped,
        "clients": n,
    }


def run_restart(binary, workdir, tag, reps):
    rng = random.Random(4242)
    db, log = fresh(workdir, tag, 0)
    srv = Server(binary, db, log)
    srv.start()
    seed_rows(db, rng)
    sse = [SSE(f"sse{i}", srv.port) for i in range(5)]
    pollers = [Poller(f"poll{i}", srv.port) for i in range(5)]
    out = []
    for rep in range(reps):
        con = connect(db)
        for _ in range(20):
            ids = ids_now(con)
            con.execute("UPDATE notes SET title = ? WHERE id = ?", (rng.choice(TITLES), rng.choice(ids[:LIST_PAGE])))
        con.close()
        settle(db, sse, pollers)
        before, _, _ = compare(db, sse + pollers)
        srv.stop()
        # While no server runs: a write no trigger sees, to a row every
        # client holds.
        con = connect(db)
        held = set.intersection(*[set(c.rows) for c in sse + pollers])
        con2 = connect(db)
        target = min(held)
        old = con2.execute("SELECT title FROM notes WHERE id = ?", (target,)).fetchone()[0]
        con2.close()
        con.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_TRIGGER, False)
        con.execute("UPDATE notes SET title = ? WHERE id = ?", (rng.choice([t for t in TITLES if t != old]), target))
        con.close()
        srv.start()
        for c in sse:
            c.port = srv.port
            c.http = Http(srv.port)
            c.reconnect()
        for p in pollers:
            p.http = Http(srv.port)
            p.poll()
        ok = settle(db, sse, pollers)
        err, detail, _ = compare(db, sse + pollers)
        out.append({"rep": rep, "before": before, "after": err, "settled": ok, "detail": detail[:4], "target": target})
    for c in sse + pollers:
        c.close()
    srv.stop()
    return {"reps": out, "raises": raises_in(log)}


def run_restore(binary, workdir, tag, reps):
    """A backup restored while no server runs (post-hoc, after the shadow
    table's registered workload 3 could not fail without the startup
    raise). Rows, copies and counter go back together, so nothing differs;
    then stamped writes to other rows carry the head past where the clients
    stand, so a client is neither below the floor nor above the head."""
    rng = random.Random(777)
    db, log = fresh(workdir, tag, 0)
    srv = Server(binary, db, log)
    srv.start()
    seed_rows(db, rng)
    sse = [SSE(f"sse{i}", srv.port) for i in range(5)]
    pollers = [Poller(f"poll{i}", srv.port) for i in range(5)]
    out = []
    backup = db + ".bak"
    for rep in range(reps):
        settle(db, sse, pollers)
        con = connect(db)
        bk = sqlite3.connect(backup)
        con.backup(bk)
        bk.close()
        ids = ids_now(con)
        touched = rng.sample(ids[:LIST_PAGE], 10)
        for t in touched:
            old = con.execute("SELECT title FROM notes WHERE id = ?", (t,)).fetchone()[0]
            con.execute("UPDATE notes SET title = ? WHERE id = ?", (rng.choice([x for x in TITLES if x != old]), t))
        con.close()
        settle(db, sse, pollers)
        held = max(c.head for c in sse + pollers)
        srv.stop()
        src = sqlite3.connect(backup)
        dst = connect(db)
        src.backup(dst)
        src.close()
        dst.close()
        srv.start()
        con = connect(db)
        others = [i for i in ids_now(con)[LIST_PAGE:] if i not in touched]
        k = 0
        while con.execute("SELECT seq FROM m0_stamp").fetchone()[0] <= held + 2 and k < len(others):
            con.execute("UPDATE notes SET title = ? WHERE id = ?", (rng.choice(TITLES), others[k]))
            k += 1
        con.close()
        for c in sse:
            c.port = srv.port
            c.http = Http(srv.port)
            c.reconnect()
        for p in pollers:
            p.http = Http(srv.port)
            p.poll()
        ok = settle(db, sse, pollers)
        err, detail, _ = compare(db, sse + pollers)
        out.append({"rep": rep, "after": err, "settled": ok, "detail": detail[:4], "writes_after_start": k})
    for c in sse + pollers:
        c.close()
    srv.stop()
    return {"reps": out, "raises": raises_in(log)}


def run_live_restore(binary, workdir, tag, reps):
    """A backup restored onto the file while the server runs (post-hoc,
    after the second review). Rows, copies and counter go back together,
    and stamped writes to other rows then carry the head past where the
    clients stand before they ask again."""
    rng = random.Random(888)
    db, log = fresh(workdir, tag, 0)
    srv = Server(binary, db, log)
    srv.start()
    seed_rows(db, rng)
    sse = [SSE(f"sse{i}", srv.port) for i in range(5)]
    pollers = [Poller(f"poll{i}", srv.port) for i in range(5)]
    out = []
    backup = db + ".bak"
    for rep in range(reps):
        settle(db, sse, pollers)
        con = connect(db)
        bk = sqlite3.connect(backup)
        con.backup(bk)
        bk.close()
        ids = ids_now(con)
        touched = rng.sample(ids[:LIST_PAGE], 10)
        for t in touched:
            old = con.execute("SELECT title FROM notes WHERE id = ?", (t,)).fetchone()[0]
            con.execute("UPDATE notes SET title = ? WHERE id = ?", (rng.choice([x for x in TITLES if x != old]), t))
        con.close()
        settle(db, sse, pollers)
        held = max(c.head for c in sse + pollers)
        src = sqlite3.connect(backup)
        dst = connect(db)
        src.backup(dst)
        src.close()
        others = [i for i in ids_now(dst)[LIST_PAGE:] if i not in touched]
        k = 0
        while dst.execute("SELECT seq FROM m0_stamp").fetchone()[0] <= held + 2 and k < len(others):
            dst.execute("UPDATE notes SET title = ? WHERE id = ?", (rng.choice(TITLES), others[k]))
            k += 1
        dst.close()
        ok = settle(db, sse, pollers)
        err, detail, _ = compare(db, sse + pollers)
        out.append({"rep": rep, "after": err, "settled": ok, "detail": detail[:4], "writes_after_restore": k})
    for c in sse + pollers:
        c.close()
    srv.stop()
    return {"reps": out, "raises": raises_in(log)}


def key(k):
    return f"{k[0]}/{k[1]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("workdir")
    ap.add_argument("workload", choices=["stamped", "bypass", "restart", "restore", "live-restore"])
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--steps", type=int, default=400)
    ap.add_argument("--tag", default="C")
    ap.add_argument("--where", choices=["page", "margin", "beyond"], default=None,
                    help="post-hoc: every bypass at this target (not in the registered runs)")
    a = ap.parse_args()
    print(f"# {a.tag} {a.workload} sqlite {sqlite3.sqlite_version} python {sys.version.split()[0]}", flush=True)
    if a.workload == "live-restore":
        res = run_live_restore(a.binary, a.workdir, a.tag, 5)
        for r in res["reps"]:
            print(json.dumps({"rep": r["rep"], "settled": r["settled"], "writes_after_restore": r["writes_after_restore"],
                              "after": {key(k): v for k, v in r["after"].items()}, "detail": r["detail"]}), flush=True)
        print(json.dumps({"raises": res["raises"]}), flush=True)
        return
    if a.workload == "restore":
        res = run_restore(a.binary, a.workdir, a.tag, 5)
        for r in res["reps"]:
            print(json.dumps({"rep": r["rep"], "settled": r["settled"], "writes_after_start": r["writes_after_start"],
                              "after": {key(k): v for k, v in r["after"].items()}, "detail": r["detail"]}), flush=True)
        print(json.dumps({"raises": res["raises"]}), flush=True)
        return
    if a.workload == "restart":
        res = run_restart(a.binary, a.workdir, a.tag, 5)
        for r in res["reps"]:
            print(json.dumps({"rep": r["rep"], "target": r["target"], "settled": r["settled"],
                              "before": {key(k): v for k, v in r["before"].items()},
                              "after": {key(k): v for k, v in r["after"].items()},
                              "detail": r["detail"]}), flush=True)
        print(json.dumps({"raises": res["raises"]}), flush=True)
        return
    grand = {}
    for seed in range(a.first_seed, a.first_seed + a.seeds):
        r = run_seed(a.binary, a.workdir, a.tag, seed, a.steps, a.workload == "bypass", a.where)
        add_total(grand, r["errors"])
        r["errors"] = {key(k): v for k, v in r["errors"].items()}
        r["bypasses"] = {key(k): v for k, v in r["bypasses"].items()}
        print(json.dumps(r), flush=True)
    print(json.dumps({"total": {key(k): v for k, v in grand.items()}}), flush=True)


if __name__ == "__main__":
    main()
