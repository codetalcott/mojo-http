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
import sqlite3
import sys
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
    check(body.count("<li>") == LIST_PAGE, f"the first page has {body.count('<li>')} rows, want {LIST_PAGE}")
    more = re.search(r'href="(/notes\?after=(\d+))"', body)
    check(more is not None, "a list with rows left has no link to them")
    resp, body = c.get(more.group(1))
    check(resp.status == 200 and body.count("<li>") == 10, f"the second page has {body.count('<li>')} rows, want 10")
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
