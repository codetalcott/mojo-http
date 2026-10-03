#!/usr/bin/env python3
"""The wire gate of apps/table_notes: a resource over a SQLite table, its
list rendered when the change clock moves and answered 304 when the bytes
a client holds are still the bytes.

    table_notes_probe.py one PORT DB       one loop: every claim that counts
                                           renderings, where one cache makes
                                           the count exact
    table_notes_probe.py loops PORT DB     M0_THREADS=2: a write through one
                                           loop is what the other serves next,
                                           and what its delta holds

"Another program" below is this process, writing the file through CPython's
own sqlite3: a different process and a different copy of SQLite from the
server's, which is the claim.
"""

import http.client
import json
import re
import select
import socket
import sqlite3
import sys
import time
import traceback
from urllib.parse import urlencode

FORM = {"Content-Type": "application/x-www-form-urlencoded"}
PARTIAL = {"HX-Request-Type": "partial"}
LIST_PAGE = 50


PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("table_notes_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print(f"table_notes_probe FAIL: {PHASE}: {msg}")
    sys.exit(1)


def check(ok, msg):
    if not ok:
        fail(msg)


class Client:
    """One kept-alive connection, so one loop under M0_THREADS."""

    def __init__(self, port):
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)

    def ask(self, method, path, body=None, headers=None):
        self.conn.request(method, path, body=body, headers=headers or {})
        resp = self.conn.getresponse()
        data = resp.read()
        return resp, data.decode("utf-8")

    def get(self, path, headers=None):
        return self.ask("GET", path, headers=headers)

    def post(self, path, fields):
        return self.ask("POST", path, body=urlencode(fields), headers=FORM)

    def changes(self, since):
        resp, body = self.get(f"/notes/changes?since={since}")
        check(resp.status == 200, f"/notes/changes?since={since} answered {resp.status}")
        check(resp.getheader("ETag") is None, "a delta carried a validator")
        return json.loads(body)

    def stats(self):
        resp, body = self.get("/stats")
        check(resp.status == 200, f"/stats answered {resp.status}")
        return json.loads(body)

    def close(self):
        self.conn.close()


class Feed:
    """One subscriber of `/notes/events` on a raw socket, so one loop under
    M0_THREADS, and the wire read as the browser's EventSource reads it."""

    def __init__(self, port, since=None, last_event_id=None, rcvbuf=None):
        self.sock = socket.socket()
        if rcvbuf:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        self.sock.connect(("127.0.0.1", port))
        path = "/notes/events" if since is None else f"/notes/events?since={since}"
        req = f"GET {path} HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n"
        if last_event_id is not None:
            req += f"Last-Event-ID: {last_event_id}\r\n"
        self.sock.sendall((req + "\r\n").encode())
        self.raw = b""
        self.buf = b""
        self.status = None
        self.chunked = False
        self.events = []
        self.bytes = 0
        deadline = time.time() + 5
        while self.status is None and time.time() < deadline:
            self.pump(0.05)
        check(self.status == 200, f"the feed opened with {self.status}")

    def _dechunk(self):
        """Move whole chunks from `raw` to `buf`: a stream is sent chunked,
        and a chunk may end anywhere, mid-line included."""
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
            return
        data = self.sock.recv(65536)
        if not data:
            return
        self.raw += data
        if self.status is None:
            if b"\r\n\r\n" not in self.raw:
                return
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
            self.bytes += len(raw) + 2
            ev = {"id": None, "event": "message", "data": []}
            for line in text.split("\n"):
                key, _, val = line.partition(": ")
                if key == "id":
                    ev["id"] = int(val)
                elif key == "event":
                    ev["event"] = val
                elif key == "data":
                    ev["data"].append(val)
            ev["data"] = "\n".join(ev["data"])
            self.events.append(ev)

    def wait(self, n=1, timeout=3.0, what="an event"):
        deadline = time.time() + timeout
        while len(self.events) < n and time.time() < deadline:
            self.pump(0.01)
        check(len(self.events) >= n, f"waited for {what}, have {len(self.events)} event(s)")
        ev, self.events = self.events[:n], self.events[n:]
        return ev if n > 1 else ev[0]

    def quiet(self, seconds=0.3):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.pump(0.02)
        check(not self.events, f"an event arrived when none was due: {self.events[:1]}")

    def close(self):
        self.sock.close()


def oob(ev):
    """`(id, what)` for each row an event carries: `true`, `delete`, or
    `append` for a row inside the `<ul hx-swap-oob="beforeend">`."""
    out = []
    ul = re.search(r'<ul id="notes-list" hx-swap-oob="beforeend">(.*?)</ul>', ev["data"])
    for m in re.finditer(r'<li id="n(\d+)" hx-swap-oob="(\w+)"', ev["data"]):
        out.append((int(m.group(1)), m.group(2)))
    if ul:
        for m in re.finditer(r'<li id="n(\d+)">', ul.group(1)):
            out.append((int(m.group(1)), "append"))
    return out


def write(db, sql, args=()):
    """A commit from another program."""
    con = sqlite3.connect(db, timeout=10)
    try:
        con.execute(sql, args)
        con.commit()
    finally:
        con.close()


def tag_of(resp):
    tag = resp.getheader("ETag")
    check(tag is not None, "a 200 carried no ETag")
    check(re.fullmatch(r'W/"[0-9a-f]{16}"', tag) is not None, f"an ETag of another shape: {tag}")
    return tag


def one(port, db):
    c = Client(port)

    phase("the list and its 304")
    # --- the list, its tag, and the 304 ---------------------------------------
    resp, body = c.get("/notes")
    check(resp.status == 200, f"GET /notes: {resp.status}")
    check("none yet" in body and "<!doctype html>" in body, "the empty list is not a page saying so")
    check(resp.getheader("Cache-Control") == "no-cache", f"Cache-Control: {resp.getheader('Cache-Control')}")
    check("HX-Request-Type" in (resp.getheader("Vary") or ""), "the list's Vary does not name HX-Request-Type")
    page_tag = tag_of(resp)
    fills = c.stats()["fills"]
    check(fills == 1, f"one GET of the list rendered it {fills} times")

    resp, body = c.get("/notes", {"If-None-Match": page_tag})
    check(resp.status == 304, f"a GET naming the tag: {resp.status}, want 304")
    check(body == "", "the 304 carried content")
    check(resp.getheader("ETag") == page_tag, "the 304's ETag is not the tag it confirms")
    check(resp.getheader("Cache-Control") == "no-cache", "the 304 lost Cache-Control")
    check("HX-Request-Type" in (resp.getheader("Vary") or ""), "the 304 lost Vary")
    check(c.stats()["fills"] == 1, "a 304 rendered the list")
    resp, body = c.ask("HEAD", "/notes", headers={"If-None-Match": page_tag})
    check(resp.status == 304, f"a HEAD naming the tag: {resp.status}")

    # One URL, two representations, two tags.
    resp, body = c.get("/notes", PARTIAL)
    check(resp.status == 200 and body.startswith('<section id="notes">'), "a partial request did not get the bare fragment")
    frag_tag = tag_of(resp)
    check(frag_tag != page_tag, "the fragment and the page share a tag")
    resp, body = c.get("/notes", dict(PARTIAL, **{"If-None-Match": page_tag}))
    check(resp.status == 200, "the page's tag validated the fragment")
    resp, body = c.get("/notes", dict(PARTIAL, **{"If-None-Match": frag_tag}))
    check(resp.status == 304, "the fragment's own tag did not validate it")
    check(c.stats()["fills"] == 1, "the fragment was rendered again for the second representation")

    phase("create")
    # --- create: a plain form, a 303, and a list that noticed -----------------
    resp, body = c.get("/notes/new")
    check(resp.status == 200 and 'method="post"' in body and 'action="/notes"' in body, "the new form is not a plain form posting to /notes")
    check("hx-post" not in body, "the new form is a swap")
    resp, body = c.post("/notes", {"title": "héllo <b>", "body": "first"})
    check(resp.status == 303, f"POST /notes: {resp.status}, want 303")
    check(resp.getheader("Location") == "/notes/1", f"created at {resp.getheader('Location')}")
    resp, body = c.post("/notes", {"title": "", "body": "kept"})
    check(resp.status == 422 and 'role="alert"' in body and "kept" in body, "an empty title is not a 422 with the form back")
    resp, body = c.ask("POST", "/notes", body='{"title":"x"}', headers={"Content-Type": "application/json"})
    check(resp.status == 400, f"a JSON body: {resp.status}, want 400")

    resp, body = c.get("/notes", {"If-None-Match": page_tag})
    check(resp.status == 200, "the list answered 304 after this server's own write")
    check("héllo &lt;b&gt;" in body, "the list does not show the new note, escaped")
    page_tag = tag_of(resp)
    check(c.stats()["fills"] == 2, "the server's own commit did not move the reader's clock exactly once")

    phase("one row, one name")
    # --- one row, one name ------------------------------------------------------
    resp, body = c.get("/notes/1")
    check(resp.status == 200 and "first" in body, "GET /notes/1")
    note_tag = tag_of(resp)
    resp, body = c.get("/notes/1", {"If-None-Match": note_tag})
    check(resp.status == 304, "the note did not answer 304 to its own tag")
    for other in ("/notes/01", "/notes/0", "/notes/+1", "/notes/abc", "/notes/2"):
        resp, body = c.get(other)
        check(resp.status == 404, f"GET {other}: {resp.status}, want 404")

    phase("update")
    # --- update: the form posts to itself, and PUT reaches the same view -------
    resp, body = c.get("/notes/1/edit")
    check(resp.status == 200 and 'action="/notes/1/edit"' in body and 'method="post"' in body, "the edit form does not post to its own URL")
    check('value="héllo &lt;b&gt;"' in body, "the edit form does not carry the title, escaped")
    resp, body = c.post("/notes/1/edit", {"title": "second", "body": "edited"})
    check(resp.status == 303 and resp.getheader("Location") == "/notes/1", f"POST /notes/1/edit: {resp.status} {resp.getheader('Location')}")
    resp, body = c.get("/notes/1", {"If-None-Match": note_tag})
    check(resp.status == 200 and "edited" in body, "the note answered 304 after its update")
    resp, body = c.ask("PUT", "/notes/1", body=urlencode({"title": "third", "body": "put"}), headers=FORM)
    check(resp.status == 303, f"PUT /notes/1: {resp.status}")
    resp, body = c.get("/notes/1")
    check("third" in body and "put" in body, "the PUT did not update the note")
    resp, body = c.ask("PUT", "/notes/9", body=urlencode({"title": "x"}), headers=FORM)
    check(resp.status == 404, f"PUT of a row that is not there: {resp.status}")
    resp, body = c.post("/notes/9/edit", {"title": ""})
    check(resp.status == 404, f"a bad form for a row that is not there: {resp.status}, want 404")
    resp, body = c.post("/notes/1/edit", {"title": ""})
    check(resp.status == 422, f"an update with no title: {resp.status}")
    resp, body = c.ask("OPTIONS", "/notes/1")
    check(resp.getheader("Allow") == "GET, HEAD, PUT, DELETE, OPTIONS", f"Allow for a note: {resp.getheader('Allow')}")
    resp, body = c.post("/notes/1", {"title": "x"})
    check(resp.status == 405, f"POST /notes/1: {resp.status}, want 405")

    phase("another program writes")
    # --- another program writes the file ----------------------------------------
    resp, body = c.get("/notes")
    page_tag = tag_of(resp)
    fills = c.stats()["fills"]
    write(db, "INSERT INTO notes (title, body) VALUES (?, ?)", ("from outside", ""))
    resp, body = c.get("/notes", {"If-None-Match": page_tag})
    check(resp.status == 200 and "from outside" in body, "another program's commit did not reach the list")
    page_tag = tag_of(resp)
    check(c.stats()["fills"] == fills + 1, "another program's commit did not cost exactly one rendering")

    # A commit to another table moves the clock and not the tag.
    before = c.stats()
    write(db, "CREATE TABLE IF NOT EXISTS elsewhere (x INTEGER)")
    write(db, "INSERT INTO elsewhere VALUES (1)")
    check(c.stats()["clock"] != before["clock"], "a commit to another table did not move the clock: the next check is vacuous")
    resp, body = c.get("/notes", {"If-None-Match": page_tag})
    check(resp.status == 304, "a commit to ANOTHER table changed the list's tag")
    check(c.stats()["fills"] == before["fills"] + 1, "the clock moved and the list was not rendered again to find out")

    # An edit that keeps every length: a size-and-time validator's stale 304.
    write(db, "UPDATE notes SET title = 'from 0utside' WHERE title = 'from outside'")
    resp, body = c.get("/notes", {"If-None-Match": page_tag})
    check(resp.status == 200 and "from 0utside" in body, "a same-length edit was answered 304")
    page_tag = tag_of(resp)

    phase("delete")
    # --- delete: the one swap ----------------------------------------------------
    resp, body = c.ask("DELETE", "/notes/1", headers=PARTIAL)
    check(resp.status == 200 and body.startswith('<section id="notes">'), f"DELETE /notes/1: {resp.status}")
    check("third" not in body and "from 0utside" in body, "the list a DELETE answered still has the note")
    resp, body = c.ask("DELETE", "/notes/1", headers=PARTIAL)
    check(resp.status == 404, f"a second DELETE: {resp.status}, want 404")
    resp, body = c.get("/notes/1")
    check(resp.status == 404, "the deleted note is still served")

    phase("paging")
    # --- a page is what is rendered ----------------------------------------------
    con = sqlite3.connect(db, timeout=10)
    con.executemany("INSERT INTO notes (title) VALUES (?)", [(f"row {i}",) for i in range(LIST_PAGE + 9)])
    con.commit()
    con.close()
    resp, body = c.get("/notes")
    check(body.count("<li id=") == LIST_PAGE, f"the first page has {body.count('<li>')} rows, want {LIST_PAGE}")
    more = re.search(r'href="(/notes\?after=(\d+))"', body)
    check(more is not None, "a list with rows left has no link to them")
    resp, body = c.get(more.group(1))
    check(resp.status == 200 and body.count("<li id=") == 10, f"the second page has {body.count('<li>')} rows, want 10")
    check("?after=" not in body, "the last page links to another")
    tag_of(resp)
    resp, body = c.get("/notes?after=0" + more.group(2))
    check(resp.status == 404, "a continuation with a leading zero is a second name for a page")

    phase("what changed since")
    # --- the database remembers what changed -------------------------------------
    check(c.stats()["watched"], "the table is not watched")
    all_ = c.changes(0)
    check(not all_["reset"] and all_["head"] == c.stats()["head"], f"a delta from 0: head {all_['head']}")
    living = [r for r in all_["rows"] if not r.get("gone")]
    check(len(living) > LIST_PAGE and all(r["born"] for r in living), "from 0, on a table watched from its first row, a row that lives was not born")
    con = sqlite3.connect(db, timeout=10)
    held = {i: t for i, t in con.execute("SELECT id, title FROM notes")}
    con.close()
    check({r["id"]: r["title"] for r in living} == held, "the delta from 0 is not the table")
    at = all_["head"]
    again = c.changes(at)
    check(again == {"since": at, "head": at, "reset": False, "rows": []}, f"a client that has everything was sent {again}")

    # One write through the server, one by another program, one delete.
    resp, body = c.post("/notes", {"title": 'quoted "new"', "body": ""})
    made = int(resp.getheader("Location").rsplit("/", 1)[1])
    con = sqlite3.connect(db, timeout=10)
    older = con.execute("SELECT min(id) FROM notes").fetchone()[0]
    doomed = con.execute("SELECT max(id) FROM notes WHERE id < ?", (made,)).fetchone()[0]
    con.close()
    write(db, "UPDATE notes SET title = 'renamed outside' WHERE id = ?", (older,))
    resp, body = c.ask("DELETE", f"/notes/{doomed}", headers=PARTIAL)
    check(resp.status == 200, f"DELETE /notes/{doomed}: {resp.status}")
    delta = c.changes(at)
    check(
        delta["rows"] == [
            {"id": made, "seq": at + 1, "born": True, "title": 'quoted "new"'},
            {"id": older, "seq": at + 2, "born": False, "title": "renamed outside"},
            {"id": doomed, "seq": at + 3, "gone": True},
        ],
        f"three changes, in the order they were committed: {delta['rows']}",
    )
    check(delta["head"] == at + 3, f"the delta's head is {delta['head']}, want {at + 3}")
    # From the middle of it: the row made above the stamp is no longer new.
    tail = c.changes(at + 1)
    check([r["id"] for r in tail["rows"]] == [older, doomed], f"from the middle: {tail['rows']}")
    check(tail["head"] == at + 3, "from the middle, another head")
    # And a row created above a stamp is new from there, not from past it.
    check(c.changes(at)["rows"][0]["born"] is True and all(not r.get("born") for r in tail["rows"]), "born does not follow the stamp asked from")
    # A row written twice has one entry, at its last stamp.
    write(db, "UPDATE notes SET title = 'renamed twice' WHERE id = ?", (older,))
    delta = c.changes(at)
    check(
        [(r["id"], r["seq"]) for r in delta["rows"]] == [(made, at + 1), (doomed, at + 3), (older, at + 4)],
        f"a row written twice: {delta['rows']}",
    )

    # A title is whatever was stored: a byte that is not UTF-8 and a
    # control character still make a delta a strict client can read.
    resp, body = c.ask("POST", "/notes", body="title=a%FFb%01c&body=", headers=FORM)
    check(resp.status == 303, f"a title with a stray byte: {resp.status}")
    odd = int(resp.getheader("Location").rsplit("/", 1)[1])
    row = [r for r in c.changes(at)["rows"] if r["id"] == odd]
    check(row and row[0]["title"] == "a\ufffdb\x01c", f"a stray byte in a title: {row}")
    delta = c.changes(at)

    # What is not a change to the table moves the clock and not the stamp.
    head = delta["head"]
    clock = c.stats()["clock"]
    write(db, "INSERT INTO elsewhere VALUES (2)")
    check(c.stats()["clock"] != clock, "the commit elsewhere did not move the clock: the next check is vacuous")
    check(c.changes(head)["rows"] == [] and c.stats()["head"] == head, "a commit to another table was stamped")

    for bad in ("abc", "-1", "01", "", "1.5"):
        resp, body = c.get(f"/notes/changes?since={bad}")
        check(resp.status == 400, f"since={bad!r}: {resp.status}, want 400")
    resp, body = c.get("/notes/changes")
    check(resp.status == 200 and json.loads(body)["since"] == 0, "no since is not since 0")

    # Below the floor a delta could keep a deleted note alive: start over.
    con = sqlite3.connect(db, timeout=10)
    con.execute("DELETE FROM m0_changes WHERE gone = 1 AND seq <= ?", (head,))
    con.execute("UPDATE m0_stamp SET floor = ?", (head,))
    con.commit()
    con.close()
    stale = c.changes(at)
    check(stale == {"since": at, "head": head, "reset": True, "rows": []}, f"a client behind the floor: {stale}")
    check(c.changes(head)["reset"] is False, "a client at the floor was told to start over")
    # A stamp this database never gave is not a place to wait from.
    ahead = c.changes(head + 50)
    check(ahead == {"since": head + 50, "head": head, "reset": True, "rows": []}, f"a client ahead of the head: {ahead}")

    phase("the list is live")
    # --- the feed: the same rows, as they change -----------------------------
    resp, body = c.get("/notes")
    since = int(re.search(r"/notes/events\?since=(\d+)", body).group(1))
    check('id="notes-list"' in body and "new EventSource(" in body, "the first page carries no feed")
    check("notesFeed.close()" in body, "a fragment rendered again does not reopen the feed from its own stamp")
    resp, body = c.get("/notes?after=1")
    check("new EventSource(" not in body, "a later page carries the feed")
    check(since == c.stats()["head"], "the page's stamp is not the head it was rendered at")
    feed = Feed(c_port := int(sys.argv[2]), since=since)
    feed.quiet()
    check(c.stats()["subscribers"] == 1, "the subscriber is not counted")

    # An outside write, a write through the server, a delete: each one event.
    write(db, "INSERT INTO notes (title, body) VALUES ('live from outside', '')")
    ev = feed.wait(what="the outside insert")
    born = int(re.search(r'<li id="n(\d+)">', ev["data"]).group(1))
    check(ev["event"] == "notes" and oob(ev) == [(born, "append")] and "live from outside" in ev["data"], f"the outside insert: {ev}")
    check(ev["id"] == c.stats()["head"], "the event's id is not the stamp")
    check("hx-get=" in ev["data"] and "hx-delete=" in ev["data"], "an appended row lost its htmx attributes")
    resp, body = c.post("/notes", {"title": "live from the server", "body": ""})
    made2 = int(resp.getheader("Location").rsplit("/", 1)[1])
    ev = feed.wait(what="the server's insert")
    check(oob(ev) == [(made2, "append")], f"the server's own insert: {oob(ev)}")
    write(db, "UPDATE notes SET title = 'renamed live' WHERE id = ?", (born,))
    ev = feed.wait(what="the outside update")
    check(oob(ev) == [(born, "true")] and "renamed live" in ev["data"], f"the update: {oob(ev)}")
    resp, body = c.ask("DELETE", f"/notes/{made2}", headers=PARTIAL)
    ev = feed.wait(what="the delete")
    check(oob(ev) == [(made2, "delete")], f"the delete: {oob(ev)}")
    at = ev["id"]
    # Nothing for what is not a change to the table.
    write(db, "INSERT INTO elsewhere VALUES (3)")
    feed.quiet()
    check(c.stats()["feed_refused"] == 0, "a delta was refused on an idle subscriber")

    # A reconnect is a query from where the client stood, not a replay.
    feed.close()
    write(db, "UPDATE notes SET title = 'while away' WHERE id = ?", (born,))
    write(db, "INSERT INTO notes (title, body) VALUES ('also while away', '')")
    back = Feed(c_port, last_event_id=at)
    ev = back.wait(what="the reconnect's delta")
    check([w for _, w in oob(ev)] == ["true", "append"] and oob(ev)[0][0] == born, f"the reconnect's delta: {oob(ev)}")
    check(ev["id"] == c.stats()["head"], "the reconnect's event does not carry the head")
    back.quiet()
    back.close()
    current = Feed(c_port, last_event_id=c.stats()["head"])
    current.quiet()
    current.close()

    # Below the floor, and above the head: the page whole, as a resync.
    head = c.stats()["head"]
    con = sqlite3.connect(db, timeout=10)
    con.execute("DELETE FROM m0_changes WHERE gone = 1 AND seq <= ?", (head,))
    con.execute("UPDATE m0_stamp SET floor = ?", (head,))
    con.commit()
    con.close()
    for stale in (at, head + 100):
        f2 = Feed(c_port, last_event_id=stale)
        ev = f2.wait(what=f"a resync for {stale} (head {head})")
        check(ev["event"] == "resync" and ev["data"].startswith('<section id="notes">') and f"since={head}" in ev["data"], f"a client at {stale}: {ev['event']} {ev['data'][:60]}")
        check(ev["id"] == head, "the resync does not carry the head")
        f2.close()
    resp, body = c.get("/notes/events?since=x")
    check(resp.status == 400, f"since=x: {resp.status}")

    # A subscriber that stops reading is sent merged deltas, never a gap.
    # Each commit touches every row, so each event is the whole list over
    # again: the socket's buffers fill, then the slot's, then deltas are
    # refused and merged.
    # The sender's own socket buffer absorbs megabytes before the loop
    # feels it, so the table is made large enough that one event does not
    # fit the slot's budget beside another.
    con = sqlite3.connect(db, timeout=10)
    con.executemany("INSERT INTO notes (title) VALUES (?)", [(f"bulk {i}",) for i in range(400)])
    con.commit()
    slow = Feed(c_port, since=c.stats()["head"], rcvbuf=4096)
    for i in range(60):
        con.execute("UPDATE notes SET title = ?", (f"slow {i}",))
        con.commit()
        if i % 8 == 0:
            con.execute("INSERT INTO notes (title) VALUES (?)", (f"burst {i}",))
            con.commit()
        time.sleep(0.02)
    con.close()
    final_head = c.stats()["head"]
    deadline = time.time() + 15
    seen = []
    while time.time() < deadline:
        slow.pump(0.02)
        seen += slow.events
        slow.events = []
        if seen and seen[-1]["id"] == final_head:
            break
    check(seen and seen[-1]["id"] == final_head, f"the slow subscriber did not reach the head: {seen[-1]['id'] if seen else None} vs {final_head}")
    check(len(seen) < 60, f"68 commits were {len(seen)} events to a subscriber that read nothing")
    check(seen[-1]["data"].count("slow 59") >= 450, "the last event does not carry every row's final title")
    appended = [i for ev in seen for i, w in oob(ev) if w == "append"]
    check(len(appended) == 8 and len(set(appended)) == 8, f"the bursts' rows: {appended}")
    check(c.stats()["feed_refused"] > 0, "the slow subscriber's buffer never filled; the phase proved nothing")
    slow.close()

    c.close()
    print("table_notes_probe one: OK")


def loops(port, db):
    """Two loops, two caches, one file: neither serves the other's past."""
    phase("reaching both loops")
    by_worker = {}
    for _ in range(200):
        c = Client(port)
        w = c.stats()["worker"]
        if w in by_worker:
            c.close()
        else:
            by_worker[w] = c
        if len(by_worker) == 2:
            break
    check(len(by_worker) == 2, f"200 connections reached loops {sorted(by_worker)} only: the phase would be vacuous")
    a, b = by_worker[0], by_worker[1]

    phase("each loop serves the other's write")
    at = a.changes(0)["head"]
    for i in range(20):
        writer, reader = (a, b) if i % 2 == 0 else (b, a)
        # Warm the reader's cache, so what it must notice is a change.
        resp, body = reader.get("/notes")
        held = tag_of(resp)
        title = f"round {i}"
        resp, body = writer.post("/notes", {"title": title, "body": ""})
        check(resp.status == 303, f"round {i}: POST answered {resp.status}")
        where = resp.getheader("Location")
        resp, body = reader.get("/notes", {"If-None-Match": held})
        check(resp.status == 200 and title in body, f"round {i}: the other loop served the list without the note just written")
        there = tag_of(resp)
        resp, body = reader.get(where)
        check(resp.status == 200 and title in body, f"round {i}: the other loop does not have {where}")
        # The tag is over the bytes, so the two loops agree on it.
        resp, body = writer.get("/notes", {"If-None-Match": there})
        check(resp.status == 304, f"round {i}: one loop's tag did not validate the other's list")
        # Neither loop keeps the client's place, so either answers from it.
        delta = reader.changes(at)
        want = [{"id": int(where.rsplit("/", 1)[1]), "seq": at + 1, "born": True, "title": title}]
        check(delta["rows"] == want and delta["head"] == at + 1, f"round {i}: the other loop's delta from {at}: {delta}")
        check(writer.changes(at) == delta, f"round {i}: the two loops answered one stamp differently")
        at = delta["head"]

    phase("each loop's feed carries the other's write")
    feeds = {}
    for _ in range(200):
        f = Feed(int(sys.argv[2]), since=a.stats()["head"])
        f.quiet(0.1)
        # Which loop took it: the one whose subscriber count rose.
        for w, cl in ((0, a), (1, b)):
            if cl.stats()["subscribers"] == 1 and w not in feeds:
                feeds[w] = f
                break
        else:
            f.close()
        if len(feeds) == 2:
            break
    check(len(feeds) == 2, f"200 feeds reached loops {sorted(feeds)} only: the phase would be vacuous")
    for i in range(6):
        writer = a if i % 2 == 0 else b
        resp, body = writer.post("/notes", {"title": f"live round {i}", "body": ""})
        made = int(resp.getheader("Location").rsplit("/", 1)[1])
        for w, f in feeds.items():
            ev = f.wait(what=f"round {i} on loop {w}")
            check(oob(ev) == [(made, "append")] and f"live round {i}" in ev["data"], f"round {i}: loop {w}'s feed: {oob(ev)}")
    for f in feeds.values():
        f.quiet(0.2)
        f.close()

    sa, sb = a.stats(), b.stats()
    check(sa["worker"] == 0 and sb["worker"] == 1, "a connection changed loops")
    check(sa["fills"] >= 20 and sb["fills"] >= 20, f"a loop rendered {sa['fills']} / {sb['fills']} times for 20 changes it had to notice")
    a.close()
    b.close()
    print("table_notes_probe loops: OK")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("one", "loops"):
        fail("usage: table_notes_probe.py one|loops PORT DB")
    {"one": one, "loops": loops}[sys.argv[1]](int(sys.argv[2]), sys.argv[3])
