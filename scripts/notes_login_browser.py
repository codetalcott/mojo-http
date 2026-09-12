#!/usr/bin/env python3
"""The notes app's login and its CSRF token, driven by a real browser (SPEC N13).

`smoke-fragment-notes` proves the server's half with curl: the cookie, the
forgeries, and a write refused unless it carries this session's token in the
body. It cannot prove the half that fails silently — that htmx actually PUTS
the token in the body of a `DELETE`.

htmx 2.0.4 ships `methodsThatUseUrlParams: ["get","delete"]`, so a form with
`hx-delete` sends its fields in the QUERY STRING, where a CSRF token becomes
an access-log entry, a `Referer` and a history entry. The app narrows that to
`get` in one `<meta name="htmx-config">` in its shell. Nothing on the wire can
tell whether the bundle honoured it: the smoke greps the meta out of the page,
which says it was served, and refuses a token in the query, which says the
server would not take one — so a bundle that ignored the meta would leave the
delete button quietly broken, 403 on every click, with a green suite.

This opens the app in Chromium, signs in, adds a note, deletes it, and records
the request the bundle made for each — the URL, the content type and the body.
It also signs out, which is the other form that is a plain navigation rather
than a swap.

Pre-release, not CI: it needs Chromium. Run as

    uv run poe browser-notes-login

which builds the app and calls this with `uv run --no-project --with
playwright`; or point it at a running app with `--url`. Exit 0 with the
request shapes printed, 1 with what differed.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

KEY = "browser-check-key-0123456789abcdef"
PASSWORD = "hunter2-correct-horse"


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


def run(url: str) -> list[str]:
    from playwright.sync_api import sync_playwright

    failures: list[str] = []
    seen: list[dict] = []

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_context().new_page()

        def record(request):
            parts = urllib.parse.urlparse(request.url)
            seen.append({
                "method": request.method,
                "path": parts.path,
                "query": parts.query,
                "content_type": request.headers.get("content-type", ""),
                "body": request.post_data or "",
            })

        page.on("request", record)

        # The root redirects to the notes, which redirect to the login:
        # a browser with no cookie ends up at the form, address bar and all.
        page.goto(url + "/")
        page.wait_for_selector('input[name="password"]', timeout=5000)
        if not page.url.endswith("/login"):
            failures.append(f"an anonymous visit did not land on /login (it was {page.url})")

        page.fill('input[name="user"]', "notes")
        page.fill('input[name="password"]', PASSWORD)
        page.click("button")
        page.wait_for_selector('input[name="title"]', timeout=5000)
        if not page.url.endswith("/notes"):
            failures.append(f"signing in did not navigate to /notes (it was {page.url})")

        # The create form: an htmx POST carrying the token as a field.
        seen.clear()
        page.fill('input[name="title"]', "buy milk")
        page.click('form[hx-post] button')
        page.wait_for_selector("li a", timeout=5000)
        create = next((r for r in seen if r["method"] == "POST" and r["path"] == "/notes"), None)

        # The delete button: the request this whole check exists for. The
        # wait is in a try because the failure it is watching for is a
        # note that never goes away — the server refusing a token that
        # went to the query string — and a raised timeout would print a
        # stack trace where the request shapes below say what happened.
        seen.clear()
        page.click("form.delete button")
        try:
            page.wait_for_selector("li a", state="detached", timeout=5000)
        except Exception:
            failures.append("the note was still in the list after the delete "
                            "was clicked — the write was refused")
        delete = next((r for r in seen if r["method"] == "DELETE"), None)

        # Signing out is a navigation too, back to a form with no session.
        page.click("form.session button")
        try:
            page.wait_for_selector('input[name="password"]', timeout=5000)
        except Exception:
            failures.append("signing out did not reach the login form")
        if not page.url.endswith("/login"):
            failures.append(f"signing out did not navigate to /login (it was {page.url})")

        browser.close()

    if not create:
        failures.append("no POST /notes was made by the create form")
    else:
        fields = urllib.parse.parse_qs(create["body"])
        if not create["content_type"].startswith("application/x-www-form-urlencoded"):
            failures.append(f"the create form did not post urlencoded: {create['content_type']!r}")
        if not fields.get("csrf"):
            failures.append(f"the create form carried no CSRF token: {create['body']!r}")
        if fields.get("title") != ["buy milk"]:
            failures.append(f"the create form's fields did not travel: {create['body']!r}")
    if not delete:
        failures.append("no DELETE was made by the delete button")
    else:
        fields = urllib.parse.parse_qs(delete["body"])
        if delete["query"]:
            failures.append(
                "the DELETE put its fields in the query string "
                f"({delete['query']!r}) — the htmx-config meta narrowing "
                "methodsThatUseUrlParams to `get` was not honoured"
            )
        if not fields.get("csrf"):
            failures.append(f"the DELETE carried no CSRF token in its body: {delete['body']!r}")

    print("what the bundle sent:")
    for label, req in (("create (POST)", create), ("delete (DELETE)", delete)):
        if req:
            print(f"  {label}: {req['method']} {req['path']}"
                  f"{'?' + req['query'] if req['query'] else ''}"
                  f"  content-type {req['content_type']!r}")
            print(f"    body {req['body']!r}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", help="a running app; otherwise --bin is started on --port")
    ap.add_argument("--bin", help="the built fragment_notes binary to start")
    ap.add_argument("--port", type=int, default=8096)
    args = ap.parse_args()
    if not args.url and not args.bin:
        ap.error("--url or --bin")

    proc = None
    url = args.url
    if not url:
        env = dict(
            os.environ,
            M0_PORT=str(args.port),
            M0_NOTES_KEY=KEY,
            M0_NOTES_PASSWORD=PASSWORD,
        )
        proc = subprocess.Popen([args.bin], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        url = f"http://127.0.0.1:{args.port}"
    try:
        wait_healthy(url)
        failures = run(url)
    finally:
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        return 1
    print("ok    the login navigates, and every write carries its token in the body")
    return 0


if __name__ == "__main__":
    sys.exit(main())
