#!/usr/bin/env python3
"""The blobs page, driven by a real browser (SPEC N16's pre-release half).

`smoke-blobs` proves what the server sends. Three things only the pinned
Datastar bundle can prove, and each fails silently — the page looks fine
until someone watches it for a while:

1. **An underscored signal drives `clip-path`.** The frames patch `_b0`..
   `_b15`; the slots bind `data-style:clip-path="$_bk"`. If the bundle did
   not apply a patched `_`-signal to a style, every slot would stay empty.
2. **A click posts `x` and `y`, and nothing else.** A fetch action sends
   every signal whose name lacks a leading `_`, and reading an undeclared
   signal creates one. The run clicks the stage and reads the body the
   bundle actually sent: exactly `{"x", "y"}`, at the point clicked. A
   second tab gains the blob.
3. **A tab comes back after the server restarts.** Datastar 1.0.3's
   default retry gives up on a clean close, which is what a draining
   server produces; the page asks for `retry: 'always'`. The run SIGTERMs
   the server, starts a new one on the same port, and requires both tabs
   to open `/events` again and draw the new process's world.

Pre-release, not CI: it needs Chromium. Run as

    uv run poe browser-blobs

which builds the demo and calls this with `uv run --no-project --with
playwright`. Exit 0 with what the bundle sent printed, 1 with what differed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
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
            time.sleep(0.2)
    sys.exit(f"the demo at {url} never became healthy")


def start(binary: str, port: int) -> subprocess.Popen:
    env = dict(os.environ, M0_PORT=str(port))
    return subprocess.Popen(
        [binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT
    )


def stop(proc: subprocess.Popen) -> int:
    proc.terminate()
    try:
        return proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        return proc.wait()


BLOBS = "() => document.querySelectorAll('.meta span')[1].textContent"

VISIBLE = (
    "() => Array.from(document.querySelectorAll('#stage .blob'))"
    ".filter(b => getComputedStyle(b).display !== 'none'"
    " && getComputedStyle(b).clipPath.startsWith('polygon(')).length"
)


def run(binary: str, port: int) -> list[str]:
    from playwright.sync_api import sync_playwright

    url = f"http://127.0.0.1:{port}"
    failures: list[str] = []
    drops: list[dict] = []
    opens = {"watcher": 0, "actor": 0}

    proc = start(binary, port)
    try:
        wait_healthy(url)
        with sync_playwright() as p:
            browser = p.chromium.launch()
            context = browser.new_context(viewport={"width": 700, "height": 900})
            watcher = context.new_page()
            actor = context.new_page()

            def recorder(name):
                def record(request):
                    path = urllib.parse.urlparse(request.url).path
                    if path == "/events":
                        opens[name] += 1
                    elif path == "/drop" and request.method == "POST":
                        drops.append(
                            {
                                "content_type": request.headers.get("content-type", ""),
                                "body": request.post_data or "",
                            }
                        )
                return record

            watcher.on("request", recorder("watcher"))
            actor.on("request", recorder("actor"))
            watcher.goto(url)
            actor.goto(url)

            # 1. The patched underscore signals draw the seeded blobs (as
            # one shape or several: blobs that touch merge).
            try:
                watcher.wait_for_function(f"() => ({VISIBLE})() >= 1", timeout=8000)
            except Exception:
                failures.append(
                    "no slot took a polygon clip-path: a patched `_b` signal "
                    "does not drive data-style:clip-path"
                )
                browser.close()
                return failures
            before = watcher.evaluate("() => getComputedStyle(document.querySelector('#b0')).clipPath")
            time.sleep(0.6)
            after = watcher.evaluate("() => getComputedStyle(document.querySelector('#b0')).clipPath")
            if before == after:
                failures.append("slot 0 did not move in 0.6 s: the stream is not reaching the style")
            step = watcher.evaluate(
                "() => document.querySelector('.meta span').textContent"
            )
            if not step.strip().isdigit():
                failures.append(f"the step readout shows {step!r}, not a number")

            # 2. A click posts x and y alone, where it landed; the other tab
            # counts one more blob. Counted from the readout, not the shapes:
            # a drop beside another blob merges into its shape.
            shown = int(watcher.evaluate(BLOBS))
            box = actor.locator("#stage").bounding_box()
            actor.mouse.click(box["x"] + box["width"] * 0.30, box["y"] + box["height"] * 0.70)
            try:
                watcher.wait_for_function(f"() => Number(({BLOBS})()) === {shown + 1}", timeout=5000)
            except Exception:
                failures.append("the other tab did not count the dropped blob")
            if not drops:
                failures.append("the click made no POST /drop")
            else:
                d = drops[0]
                try:
                    body = json.loads(d["body"])
                except ValueError:
                    body = None
                if not isinstance(body, dict) or sorted(body) != ["x", "y"]:
                    failures.append(f"the click posted {d['body']!r}, not exactly x and y")
                elif abs(body["x"] - 30) > 2 or abs(body["y"] - 70) > 2:
                    failures.append(f"the click at (30%, 70%) posted ({body['x']}, {body['y']})")
                if not d["content_type"].startswith("application/json"):
                    failures.append(f"the click posted {d['content_type']!r}")

            # 3. A restart: both tabs come back and draw the new world.
            opened = dict(opens)
            rc = stop(proc)
            if rc != 0:
                failures.append(f"the drain exited {rc}")
            proc = start(binary, port)
            wait_healthy(url)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and not all(
                opens[k] > opened[k] for k in opens
            ):
                watcher.wait_for_timeout(200)
            for k in opens:
                if opens[k] <= opened[k]:
                    failures.append(
                        f"the {k} tab never reopened /events after the server "
                        "restarted -- retry: 'always' is not in effect"
                    )
            try:
                # A fresh process seeds five blobs; the dropped sixth is gone.
                watcher.wait_for_function(
                    "() => document.querySelectorAll('.meta span')[1].textContent === '5'",
                    timeout=8000,
                )
            except Exception:
                failures.append("the watcher did not draw the restarted server's world")
            browser.close()
    finally:
        stop(proc)

    print("what the bundle sent:")
    for d in drops[:1]:
        print(f"  the click: POST /drop  content-type {d['content_type']!r}  body {d['body']!r}")
    print(f"  /events opened: {opens}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bin", required=True, help="the built blobs binary")
    ap.add_argument("--port", type=int, default=8354)
    args = ap.parse_args()
    failures = run(args.bin, args.port)
    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        return 1
    print("ok    underscored signals draw the slots, a click posts x and y alone, and both tabs survive a restart")
    return 0


if __name__ == "__main__":
    sys.exit(main())
