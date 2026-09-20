#!/usr/bin/env python3
"""The notes app's login and its CSRF token, driven by a real browser (SPEC N13).

`smoke-fragment-notes` proves the server's half with curl: the cookie, the
forgeries, and a write refused unless it carries this session's token in the
body or the `X-CSRF-Token` header. It cannot prove the half that fails
silently — what htmx actually SENDS — and under htmx 4 that half is most of
the contract (SPEC N22):

- **A `DELETE`'s token is a header.** htmx 4.0.0 sends a DELETE's parameters
  in the QUERY STRING, hard-coded (`/GET|DELETE/.test(method)`; the
  `methodsThatUseUrlParams` setting the 2.0.4 shell narrowed is gone), where a
  CSRF token becomes an access-log entry, a `Referer` and a history entry. So
  the delete form holds no field and carries `hx-headers`. Nothing on the wire
  can tell whether the bundle honoured that attribute: a bundle that ignored
  it would leave the delete button quietly broken, 403 on every click, with a
  green suite.
- **Every request says `HX-Request-Type`.** `page_or_fragment` takes htmx 4 at
  its word, so the word has to be there: `partial` on a swap into `#notes`.
- **A 4xx is swapped.** A session that ends mid-interaction is answered 401
  with the login fragment, and htmx 4 puts it where the list was (2.0.4 showed
  nothing). Checked by dropping the cookie and clicking.

This opens the app in Chromium, signs in, adds a note, deletes it, and records
the request the bundle made for each — the URL, the headers and the body.
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
        context = browser.new_context()
        page = context.new_page()

        def record(request):
            parts = urllib.parse.urlparse(request.url)
            seen.append({
                "method": request.method,
                "path": parts.path,
                "query": parts.query,
                "content_type": request.headers.get("content-type", ""),
                "request_type": request.headers.get("hx-request-type", ""),
                "csrf_header": request.headers.get("x-csrf-token", ""),
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
        # STATUS is what is read, not the list: htmx 4 swaps a 4xx, so a
        # refused delete replaces the list with the refusal and the note
        # "goes away" either way.
        seen.clear()
        status = 0
        try:
            with page.expect_response(
                lambda r: r.request.method == "DELETE", timeout=5000
            ) as answered:
                page.click("form.delete button")
            status = answered.value.status
        except Exception:
            failures.append("clicking the delete button made no DELETE request")
        if status == 200:
            try:
                page.wait_for_selector("li a", state="detached", timeout=5000)
            except Exception:
                failures.append("the note was still in the list after a DELETE answered 200")
        elif status:
            failures.append(f"the DELETE was answered {status} — the write was refused")
            page.goto(url + "/notes")
            page.wait_for_selector('input[name="title"]', timeout=5000)
        delete = next((r for r in seen if r["method"] == "DELETE"), None)

        # A session that ends mid-interaction: drop the cookie, add a note.
        # The 401 carries the login fragment under the list's id, and htmx 4
        # swaps a 4xx -- so the form appears in place, the address unmoved.
        jar = context.cookies()
        context.clear_cookies()
        page.fill('input[name="title"]', "after the session ended")
        page.click('form[hx-post] button')
        try:
            page.wait_for_selector('#notes input[name="password"]', timeout=5000)
        except Exception:
            failures.append("a 401 answered to a swap did not put the login "
                            "form where the list was")
        if not page.url.endswith("/notes"):
            failures.append(f"the swapped-in login moved the address bar (it is {page.url})")
        context.add_cookies(jar)
        page.goto(url + "/notes")
        page.wait_for_selector('input[name="title"]', timeout=5000)

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
        if create["request_type"] != "partial":
            failures.append("the create form's swap did not say HX-Request-Type: partial "
                            f"(it said {create['request_type']!r}) — the header "
                            "page_or_fragment decides by")
    if not delete:
        failures.append("no DELETE was made by the delete button")
    else:
        if "csrf" in urllib.parse.parse_qs(delete["query"]):
            failures.append(
                "the DELETE put a CSRF token in the query string "
                f"({delete['query']!r}) — the delete form holds a field, and "
                "htmx 4 sends a DELETE's fields in the URL"
            )
        if not delete["csrf_header"]:
            failures.append("the DELETE carried no X-CSRF-Token header — "
                            "hx-headers on the form was not honoured")
        if delete["request_type"] != "partial":
            failures.append("the DELETE did not say HX-Request-Type: partial "
                            f"(it said {delete['request_type']!r})")

    print("what the bundle sent:")
    for label, req in (("create (POST)", create), ("delete (DELETE)", delete)):
        if req:
            print(f"  {label}: {req['method']} {req['path']}"
                  f"{'?' + req['query'] if req['query'] else ''}"
                  f"  content-type {req['content_type']!r}")
            print(f"    body {req['body']!r}")
            print(f"    hx-request-type {req['request_type']!r}  "
                  f"x-csrf-token {'present' if req['csrf_header'] else 'absent'}")
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
    print("ok    the login navigates, a POST carries its token in the body and a "
          "DELETE in a header, and a 401 is swapped in")
    return 0


if __name__ == "__main__":
    sys.exit(main())
