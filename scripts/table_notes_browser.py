#!/usr/bin/env python3
"""The table notes list, live in Chromium under htmx 4.0.0 (SPEC N50).

`smoke-table-notes` reads the feed's events as text. This drives the page
the events are for, and counts what htmx made of them in the DOM:

- **A row whose id comes back is one row.** A note is deleted and another
  program inserts a row under the same id (an explicit id, or a REPLACE).
  The row is born again above the stamp the page stands at, so the feed
  appends it, and the page still shows the old `<li id="n…">`. The event
  deletes that one first: afterwards there is exactly one `li#n…`, with the
  new title.
- **An update, an outside insert and a delete** each reach the page once.

Needs a built `apps/table_notes` server (`--bin`) or a running one (`--url`
and `--db`), and `playwright`; see `browser-table-notes` in pyproject.toml.
Exit 0 with no output past the summary when every check holds.
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request

from probelib import free_port


def wait_healthy(url: str, deadline_s: float = 30.0) -> None:
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as r:
                if r.status == 200:
                    return
        except Exception:
            time.sleep(0.25)
    sys.exit(f"the app at {url} never became healthy")


def write(db: str, sql: str, args=()) -> None:
    """A commit from another program, stamped by the table's triggers."""
    con = sqlite3.connect(db, timeout=10)
    try:
        con.execute(sql, args)
        con.commit()
    finally:
        con.close()


def run(url: str, db: str) -> list[str]:
    from playwright.sync_api import sync_playwright

    failures: list[str] = []
    for i in range(5):
        write(db, "INSERT INTO notes (title, body) VALUES (?, '')", (f"seeded {i}",))
    con = sqlite3.connect(db)
    first = con.execute("SELECT min(id) FROM notes").fetchone()[0]
    con.close()

    with sync_playwright() as p:
        # No GPU process: a headless check renders nothing that needs one,
        # and a sandboxed shell (macOS seatbelt) kills it at startup.
        browser = p.chromium.launch(args=["--disable-gpu", "--in-process-gpu"])
        page = browser.new_context().new_page()
        page.goto(url + "/notes")
        page.wait_for_selector(f"li#n{first}", timeout=5000)
        # The feed opens from the stamp the page was rendered at.
        page.wait_for_function("() => window.notesFeed && window.notesFeed.readyState === 1", timeout=5000)

        def settle(predicate: str, what: str) -> None:
            try:
                page.wait_for_function(predicate, timeout=5000)
            except Exception:
                failures.append(what)

        write(db, "UPDATE notes SET title = 'renamed live' WHERE id = ?", (first + 1,))
        settle(f"() => document.querySelector('li#n{first + 1}')?.textContent.includes('renamed live')",
               "an update did not reach the page")

        write(db, "INSERT INTO notes (title, body) VALUES ('from outside', '')")
        settle("() => [...document.querySelectorAll('#notes-list li')].some(li => li.textContent.includes('from outside'))",
               "an outside insert did not reach the page")

        write(db, "DELETE FROM notes WHERE id = ?", (first + 2,))
        settle(f"() => !document.querySelector('li#n{first + 2}')", "a delete did not reach the page")

        # The id comes back, from another program, within one tick: the
        # delete's tombstone and the new row are one entry, born above the
        # page's stamp, and the page still shows the old row.
        con = sqlite3.connect(db, timeout=10)
        con.execute("DELETE FROM notes WHERE id = ?", (first,))
        con.execute("INSERT INTO notes (id, title, body) VALUES (?, 'back again', '')", (first,))
        con.commit()
        con.close()
        settle(f"() => [...document.querySelectorAll('li#n{first}')].some(li => li.textContent.includes('back again'))",
               "a row whose id came back never reached the page")
        time.sleep(0.3)
        count = page.evaluate(f"() => document.querySelectorAll('li#n{first}').length")
        titles = page.evaluate(f"() => [...document.querySelectorAll('li#n{first}')].map(li => li.textContent.trim())")
        if count != 1:
            failures.append(f"a row whose id came back is {count} rows on the page: {titles}")

        # And a REPLACE, which puts the id back in one statement.
        write(db, "INSERT OR REPLACE INTO notes (id, title, body) VALUES (?, 'replaced', '')", (first + 3,))
        settle(f"() => [...document.querySelectorAll('li#n{first + 3}')].some(li => li.textContent.includes('replaced'))",
               "a REPLACE never reached the page")
        time.sleep(0.3)
        count = page.evaluate(f"() => document.querySelectorAll('li#n{first + 3}').length")
        titles = page.evaluate(f"() => [...document.querySelectorAll('li#n{first + 3}')].map(li => li.textContent.trim())")
        if count != 1:
            failures.append(f"a REPLACEd row is {count} rows on the page: {titles}")
        browser.close()
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", help="a built apps/table_notes server, started on a fresh database")
    ap.add_argument("--url", help="a running server (with --db)")
    ap.add_argument("--db", help="the running server's database")
    a = ap.parse_args()
    proc = None
    if a.bin:
        work = tempfile.mkdtemp(prefix="table-notes-browser-")
        db = os.path.join(work, "notes.db")
        port = free_port()
        url = f"http://127.0.0.1:{port}"
        env = dict(os.environ, M0_PORT=str(port), M0_DB=db)
        proc = subprocess.Popen([a.bin], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        wait_healthy(url)
    elif a.url and a.db:
        url, db = a.url, a.db
    else:
        ap.error("give --bin, or --url and --db")
    try:
        failures = run(url, db)
    finally:
        if proc:
            proc.terminate()
            proc.wait(timeout=10)
    for f in failures:
        print("FAIL:", f)
    print(f"table_notes_browser: {'OK' if not failures else str(len(failures)) + ' failure(s)'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
