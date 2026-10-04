#!/usr/bin/env python3
"""An SVG a static mount serves cannot run as this origin, in real browsers (SPEC J14).

`smoke-serve` proves the server's half with curl: an SVG's response carries
`SVG_SANDBOX_POLICY` and a stylesheet's does not. What only a browser can
prove is the effect. An SVG's `<script>` never runs in an `<img>`, but opened
directly, or framed, it runs as a page of the serving origin, with its
cookies and storage; the policy must stop that and must not stop an SVG
doing its ordinary work: an `<img>`, a CSS background, a `<use>` sprite.

Two arms, both through the real `bin/m0serve` with a `--static` mount:

1. As shipped: the three ordinary uses render, and a scripted SVG's script
   leaves no mark in this origin's storage, framed or opened directly.
2. Its own negative: the same mount with a `--static-header` policy that
   allows inline script (it replaces the sandbox). The script MUST leave its
   mark both ways, or arm 1's "it did not run" proves nothing about this
   probe's ability to see a run.

Pre-release, not CI: it needs browsers. Run as

    uv run poe browser-svg-sandbox

which builds `bin/m0serve` and calls this with `uv run --no-project --with
playwright`. Chromium, Firefox and WebKit by default (`--browsers`); the
first run may need `uv run --no-project --with playwright playwright install
chromium firefox webkit`. Exit 0 with each arm's findings printed, 1 with
what differed.
"""

from __future__ import annotations

import argparse
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from probelib import free_port

W = 'xmlns="http://www.w3.org/2000/svg"'
ASSETS = {
    "icon.svg": f'<svg {W} width="10" height="10"><rect width="10" height="10" fill="red"/></svg>',
    # The background's own file: a URL the <img> already fetched would come
    # from the image cache and prove nothing about the background.
    "bg.svg": f'<svg {W} width="20" height="20"><rect width="20" height="20" fill="blue"/></svg>',
    "sprite.svg": f'<svg {W}><symbol id="dot" viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></symbol></svg>',
    # The mark is this origin's localStorage, which a sandboxed document
    # (an opaque origin) cannot reach even where its script runs.
    "evil.svg": (
        f'<svg {W} width="10" height="10"><rect width="10" height="10"/><script>'
        'try { localStorage.setItem("ran:" + (window === top ? "top" : "framed"), "1"); }'
        " catch (e) {}</script></svg>"
    ),
    "page.html": (
        "<!doctype html><title>svg</title>"
        '<img id="img" src="icon.svg">'
        '<div id="bg" style="width:20px;height:20px;background:url(bg.svg)"></div>'
        '<svg id="spr" width="20" height="20"><use href="sprite.svg#dot"/></svg>'
        '<div id="blank" style="width:20px;height:20px"></div>'
    ),
}


FRAME = """() => { const f = document.createElement('iframe'); f.src = 'evil.svg';
                   document.body.appendChild(f); }"""

# Allows inline script, and eval for Playwright's own probes of the page.
PERMISSIVE = "Content-Security-Policy: script-src 'unsafe-inline' 'unsafe-eval'"


def start(m0serve: str, root: str, extra: list[str]) -> tuple[subprocess.Popen, str, str]:
    port = free_port()
    log = os.path.join(root, f"m0serve-{port}.log")
    proc = subprocess.Popen(
        [m0serve, "bareapp.wsgi:application", "--app-dir", "apps/wsgi_bare",
         "--host", "127.0.0.1", "--port", str(port),
         "--static", "/s/=" + os.path.join(root, "assets"), *extra],
        stdout=open(log, "w"), stderr=subprocess.STDOUT,
    )
    end = time.monotonic() + 60
    while time.monotonic() < end:
        if proc.poll() is not None:
            raise SystemExit("m0serve exited:\n" + open(log).read())
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            if "on http://" in open(log).read():
                return proc, f"http://127.0.0.1:{port}/s/", log
        except OSError:
            pass
        time.sleep(0.2)
    proc.kill()
    raise SystemExit("m0serve did not come up:\n" + open(log).read())


def observe(browser, base: str) -> dict:
    ctx = browser.new_context()
    page = ctx.new_page()
    page.goto(base + "page.html")
    page.evaluate("localStorage.clear()")
    page.wait_for_timeout(500)
    # Drawn, not merely fetched: each box's pixels against an empty box of
    # the same size.
    blank = page.locator("#blank").screenshot()
    seen = {
        "img": page.evaluate("document.getElementById('img').naturalWidth") > 0,
        "css_background": page.locator("#bg").screenshot() != blank,
        "use_sprite": page.locator("#spr").screenshot() != blank,
    }
    page.evaluate(FRAME)
    page.wait_for_timeout(800)
    seen["ran_framed"] = page.evaluate("localStorage.getItem('ran:framed')") is not None
    page.goto(base + "evil.svg")
    page.wait_for_timeout(400)
    page.goto(base + "page.html")
    seen["ran_opened_directly"] = page.evaluate("localStorage.getItem('ran:top')") is not None
    ctx.close()
    return seen


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bin", default="bin/m0serve", help="the m0serve binary")
    ap.add_argument("--browsers", default="chromium,firefox,webkit")
    args = ap.parse_args()
    from playwright.sync_api import sync_playwright

    root = tempfile.mkdtemp(prefix="svg-sandbox-")
    os.makedirs(os.path.join(root, "assets"))
    for name, text in ASSETS.items():
        with open(os.path.join(root, "assets", name), "w") as f:
            f.write(text)
    failures = []
    arms = [("as shipped", []), ("negative (script allowed)", ["--static-header", PERMISSIVE])]
    try:
        with sync_playwright() as p:
            for name in args.browsers.split(","):
                browser = getattr(p, name).launch()
                for arm, extra in arms:
                    proc, base, _ = start(args.bin, root, extra)
                    try:
                        seen = observe(browser, base)
                    finally:
                        proc.terminate()
                        proc.wait(timeout=10)
                    print(f"{name:9} {arm}: {seen}", flush=True)
                    for use in ("img", "css_background", "use_sprite"):
                        if not seen[use]:
                            failures.append(f"{name}, {arm}: an SVG as {use} did not render")
                    ran = (seen["ran_framed"], seen["ran_opened_directly"])
                    if extra and ran != (True, True):
                        failures.append(
                            f"{name}: with script allowed the probe saw framed={ran[0]}, "
                            f"opened-directly={ran[1]}; it cannot see a script run, so "
                            "the shipped arm proves nothing")
                    if not extra and ran != (False, False):
                        failures.append(
                            f"{name}: a scripted SVG ran as this origin (framed={ran[0]}, "
                            f"opened-directly={ran[1]})")
                browser.close()
    finally:
        shutil.rmtree(root, ignore_errors=True)
    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        return 1
    print("ok    an SVG renders as an image, a background and a sprite, and its "
          "script cannot run as this origin; with script allowed, the probe sees it run")
    return 0


if __name__ == "__main__":
    sys.exit(main())
