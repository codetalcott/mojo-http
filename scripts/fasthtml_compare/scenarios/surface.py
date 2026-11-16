"""apps/surface: the FastHTML API surface a server can get wrong."""
import os, time, socket, json, concurrent.futures as cf
import httpx
from compare import obs, HERE

OWN = True
APP_DIR = os.path.join(HERE, "apps", "surface")
SPEC = "main:app"
EXTRA = {}
ENV = {}
def SETUP(d):
    with open(os.path.join(d, "blob.bin"), "wb") as f: f.write(os.urandom(3 * 1024 * 1024 + 7))
    for f in ("lifespan.log", ".sesskey"):
        if os.path.exists(os.path.join(d, f)): os.remove(os.path.join(d, f))
HX = {"HX-Request": "true"}

def scenario(srv, steps):
    c = httpx.Client(base_url=srv.base, follow_redirects=False, timeout=30)
    add = lambda label, r, **kw: steps.append((label, obs(r, **kw)))
    note = lambda label, d: steps.append((label, d))
    r = c.get("/scope?a=1&a=2&b=%C3%A9", headers={"X-Custom": "v"})
    add("GET /scope", r)
    add("GET /state-keys", c.get("/state-keys"))
    add("POST /scope chunked", c.post("/scope", content=iter([b"abc", b"defg"]), headers={"Content-Type": "text/plain"}))
    add("POST /scope sized", c.post("/scope", content=b"abcdefg", headers={"Content-Type": "text/plain"}))
    add("GET /boom", c.get("/boom"))
    add("GET /boom-async", c.get("/boom-async"))
    # A background task takes 1.5 s; its response must not wait for it.
    t = time.time(); r = c.get("/bg?tag=one"); add("GET /bg", r); note("GET /bg answered before its task", {"ok": time.time() - t < 1.0})
    t = time.time(); r = c.get("/bg-sync?tag=two"); add("GET /bg-sync", r); note("GET /bg-sync answered before its task", {"ok": time.time() - t < 1.0})
    add("GET /log at once", c.get("/log"))
    time.sleep(3.0)
    add("GET /log after 3 s", c.get("/log"))
    add("GET /toast", c.get("/toast"))
    add("GET /after-toast (toast shown)", c.get("/after-toast"))
    add("GET /after-toast (toast gone)", c.get("/after-toast"))
    add("GET /cookies", c.get("/cookies", headers=HX))
    add("GET /redir", c.get("/redir"))
    add("GET /redir htmx", c.get("/redir", headers=HX))
    add("GET /nocontent", c.get("/nocontent"))
    add("GET /notmod", c.get("/notmod"))
    add("POST /json", c.post("/json", json={"k": ["v", 1, None], "u": "é✓"}))
    add("POST /form", c.post("/form", data={"x": ["1", "2"], "y": "é ✓ &="}))
    add("POST /upload sized", c.post("/upload", files={"myFile": ("résumé ✓.bin", b"z" * 200000, "application/octet-stream")}))
    # The same multipart body with no Content-Length.
    req = httpx.Request("POST", srv.base + "/upload", files={"myFile": ("c.bin", b"z" * 200000, "application/octet-stream")})
    raw = req.read()
    add("POST /upload chunked", c.post("/upload", content=(raw[i:i + 8192] for i in range(0, len(raw), 8192)),
                                       headers={"Content-Type": req.headers["content-type"]}))
    r = c.get("/big"); note("GET /big", {"status": r.status_code, "len": len(r.content), "ok": r.content == b"0123456789abcdef" * (5 * 1024 * 1024 // 16)})
    blob = open(os.path.join(srv.dir, "blob.bin"), "rb").read()
    r = c.get("/file"); note("GET /file", {"status": r.status_code, "ok": r.content == blob, "ct": r.headers.get("content-type"), "ar": r.headers.get("accept-ranges")})
    r = c.get("/file", headers={"Range": "bytes=10-109"}); note("GET /file range", {"status": r.status_code, "ok": r.content == blob[10:110], "cr": r.headers.get("content-range")})
    r = c.get("/file", headers={"Range": "bytes=0-9,20-29"}); note("GET /file multirange", {"status": r.status_code, "len": len(r.content), "ct": r.headers.get("content-type", "")[:30]})
    add("HEAD /file", c.head("/file"))
    add("HEAD /big", c.head("/big"))
    r = c.get("/gz/big", headers={"Accept-Encoding": "gzip"}); note("GET /gz/big", {"status": r.status_code, "ce": r.headers.get("content-encoding"), "ok": r.text == "gzip me " * 5000})
    for path in ("/stream-sync", "/stream-async"):
        t0 = time.time(); arrivals = []
        with c.stream("GET", path) as r:
            for line in r.iter_lines():
                arrivals.append((line, time.time() - t0))
        # Five chunks 0.3 s apart: streamed if the last came well after the first.
        note(f"GET {path}", {"status": r.status_code, "te": r.headers.get("transfer-encoding"),
                             "lines": [a[0] for a in arrivals], "streamed": arrivals[-1][1] - arrivals[0][1] > 0.6})
    # disconnect detection: read 3 events then vanish
    s = socket.create_connection(("127.0.0.1", srv.port))
    s.sendall(b"GET /watch HTTP/1.1\r\nHost: x\r\n\r\n")
    buf = b""; t0 = time.time()
    while buf.count(b"data:") < 3 and time.time() - t0 < 5: buf += s.recv(4096)
    s.close()
    time.sleep(1.5)
    add("GET /log after watch disconnect", c.get("/log"))
    # concurrency
    for path in ("/sleep", "/sync-sleep"):
        t0 = time.time()
        with cf.ThreadPoolExecutor(8) as ex:
            codes = list(ex.map(lambda _: httpx.get(srv.base + path, timeout=20).status_code, range(8)))
        # Eight 1 s requests: 8 s in series.
        note(f"8x {path}", {"codes": codes, "overlapped": time.time() - t0 < 4.0})
    add("GET /q", c.get("/q?x=1&x=2&y=&z=%20%2B+"))
    add("GET /p/unicode", c.get("/p/caf%C3%A9%20%E2%9C%93"))
    add("GET /p/slash", c.get("/p/a%2Fb"))
    # websocket
    import websockets.sync.client as wsc
    with wsc.connect(f"ws://127.0.0.1:{srv.port}/ws") as ws:
        ws.send(json.dumps({"msg": "hi é", "HEADERS": {"HX-Request": "true"}}))
        note("WS /ws echo", {"got": ws.recv(timeout=5)})

def after_stop(srv, steps):
    p = os.path.join(srv.dir, "lifespan.log")
    steps.append(("lifespan", {"log": open(p).read() if os.path.exists(p) else None}))
