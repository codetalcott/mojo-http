"""live=True under each server's --reload: edit main.py, watch the page update."""
import os, time
import httpx
import websockets.sync.client as wsc
from compare import HERE
OWN = True
APP_DIR = os.path.join(HERE, "apps", "live"); SPEC = "main:app"
EXTRA = {"m0": ["--reload"], "uv": ["--reload"]}
def scenario(srv, steps):
    r = httpx.get(srv.base + "/")
    steps.append(("page has live-reload script", {"v1": "version v1" in r.text, "script": "live-reload" in r.text}))
    ws = wsc.connect(f"ws://127.0.0.1:{srv.port}/live-reload")
    time.sleep(1.0)
    p = os.path.join(srv.dir, "main.py")
    new = open(p).read().replace('"v1"', '"v2"')
    open(p + ".tmp", "w").write(new); os.replace(p + ".tmp", p)
    t0 = time.time(); closed = None
    try:
        while time.time() - t0 < 15: ws.recv(timeout=15 - (time.time() - t0))
    except Exception: closed = round(time.time() - t0)
    steps.append(("live-reload socket drops after edit", {"dropped": closed is not None and closed < 10}))
    t0 = time.time(); got = None
    while time.time() - t0 < 20:
        try:
            r = httpx.get(srv.base + "/", timeout=2)
            if "version v2" in r.text: got = round(time.time() - t0); break
        except Exception: pass
        time.sleep(0.2)
    steps.append(("edited page served within 10s", {"ok": got is not None and got < 10}))
