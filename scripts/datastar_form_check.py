#!/usr/bin/env python3
"""The Datastar form arm, driven by a real browser (SPEC N12).

`smoke-todo` posts the rename form with curl and greps the frame, which
proves the server's half. It cannot prove the half that fails silently: that
the attribute `Fragment[Datastar]` emits on a `<form>` --
`data-on:submit__prevent="@post('/edit/2', {contentType: 'form'})"` -- makes
the pinned Datastar bundle send the form's FIELDS, urlencoded, when a person
presses Enter in the input. A misspelled modifier or option there sends
nothing, or sends the signal store, and the page looks fine until someone
types. So this opens the demo in Chromium, renames a todo from the keyboard,
records the request the bundle made, and checks that a second tab was
morphed to the new text.

It also records what a bound FIELD's action sends -- the draft input's
`data-on:keydown` posting `@post('/add')` -- because decision D21 rests on
that: the signal store as JSON, never the field alone. If a bundle ever
sends the field alone, this is where it shows.

Pre-release, not CI: it needs Chromium. Run as

    uv run poe browser-datastar-form

which builds the demo and calls this with `uv run --no-project --with
playwright`; or point it at a running demo with `--url`. Exit 0 with the
two request shapes printed, 1 with what differed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


def wait_healthy(url: str, deadline_s: float = 30.0) -> None:
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as r:
                if r.status == 200:
                    return
        except Exception:
            time.sleep(0.25)
    sys.exit(f"the demo at {url} never became healthy")


def run(url: str) -> list[str]:
    from playwright.sync_api import sync_playwright

    failures: list[str] = []
    seen: dict[str, dict] = {}

    with sync_playwright() as p:
        browser = p.chromium.launch()
        context = browser.new_context()
        watcher = context.new_page()
        actor = context.new_page()

        def record(request):
            path = urllib.parse.urlparse(request.url).path
            if request.method == "POST" and path.startswith(("/edit/", "/add")):
                seen[path.split("/")[1]] = {
                    "path": path,
                    "content_type": request.headers.get("content-type", ""),
                    "datastar_request": request.headers.get("datastar-request", ""),
                    "body": request.post_data or "",
                }

        actor.on("request", record)

        watcher.goto(url)
        actor.goto(url)
        watcher.wait_for_selector("#todos")
        actor.wait_for_selector("#todos")

        # Seed a todo through the field's own action, which is D21's shape.
        actor.fill("input[data-bind\\:draft]", "buy milk")
        actor.press("input[data-bind\\:draft]", "Enter")
        actor.wait_for_selector('form.edit input[name="text"]', timeout=5000)
        watcher.wait_for_selector('form.edit input[name="text"]', timeout=5000)

        # Rename it from the keyboard: the form arm.
        actor.fill('form.edit input[name="text"]', "buy oat milk")
        actor.press('form.edit input[name="text"]', "Enter")
        try:
            watcher.wait_for_function(
                "() => Array.from(document.querySelectorAll('form.edit input[name=text]'))"
                ".some(i => i.value === 'buy oat milk')",
                timeout=5000,
            )
        except Exception:
            failures.append("the second tab was not morphed to the renamed todo")

        browser.close()

    add, edit = seen.get("add"), seen.get("edit")
    if not add:
        failures.append("no POST /add was made by the draft field's action")
    else:
        try:
            store = json.loads(add["body"])
        except ValueError:
            store = None
        if not isinstance(store, dict) or "draft" not in store:
            failures.append(f"the field's action did not send the signal store as JSON: {add['body']!r}")
        if "form" in add["content_type"]:
            failures.append(f"the field's action sent a form body: {add['content_type']!r}")
    if not edit:
        failures.append("no POST /edit/<id> was made by the form's submit")
    else:
        fields = urllib.parse.parse_qs(edit["body"])
        if not edit["content_type"].startswith("application/x-www-form-urlencoded"):
            failures.append(f"the form did not post urlencoded: {edit['content_type']!r}")
        if fields.get("text") != ["buy oat milk"]:
            failures.append(f"the form's fields did not travel: {edit['body']!r}")
        if "datastar" in fields or edit["body"].lstrip().startswith("{"):
            failures.append(f"the form sent the signal store instead of its fields: {edit['body']!r}")
        if edit["datastar_request"] != "true":
            failures.append("the form's request lacked Datastar-Request: true")

    print("what the bundle sent:")
    for label, req in (("the field's action (D21)", add), ("the form's submit (N12)", edit)):
        if req:
            print(f"  {label}: POST {req['path']}  content-type {req['content_type']!r}")
            print(f"    body {req['body']!r}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", help="a running demo; otherwise --bin is started on --port")
    ap.add_argument("--bin", help="the built todo binary to start")
    ap.add_argument("--port", type=int, default=8094)
    args = ap.parse_args()
    if not args.url and not args.bin:
        ap.error("--url or --bin")

    proc = None
    url = args.url
    workdir = None
    if not url:
        workdir = tempfile.TemporaryDirectory()
        env = dict(os.environ, M0_DB=os.path.join(workdir.name, "todos.db"), M0_PORT=str(args.port))
        proc = subprocess.Popen([args.bin], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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
        if workdir:
            workdir.cleanup()
    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        return 1
    print("ok    the form posts its fields, the field posts the store, and the other tab morphed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
