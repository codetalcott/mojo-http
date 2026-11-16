"""fasthtml/examples/adv_app.py: sessions, Beforeware, fastlite, htmx posts."""
import os
import httpx
from compare import obs, upstream

OWN = False
APP_DIR = upstream("fasthtml", "examples")
SPEC = "adv_app:app"
EXTRA = {}


def SETUP(d):
    os.makedirs(os.path.join(d, "data"), exist_ok=True)
    for f in (".sesskey",):
        p = os.path.join(d, f)
        if os.path.exists(p): os.remove(p)


HX = {"HX-Request": "true", "HX-Current-URL": "http://x/"}


def scenario(srv, steps):
    c = httpx.Client(base_url=srv.base, follow_redirects=False, timeout=10)
    add = lambda label, r, **kw: steps.append((label, obs(r, **kw)))
    add("GET / unauthenticated", c.get("/"))
    add("GET /login", c.get("/login"))
    add("POST /send_login", c.post("/send_login", data={"name": "alice", "pwd": "s3cret"}))
    add("GET / authed", c.get("/"))
    add("POST /create", c.post("/create", data={"title": "Buy milk"}, headers=HX))
    add("POST /create unicode", c.post("/create", data={"title": 'Ünïcode ✓ "q" <b>&amp;'}, headers=HX))
    add("GET /show?id=1", c.get("/show", params={"id": 1}, headers=HX))
    add("GET /edit?id=1", c.get("/edit", params={"id": 1}, headers=HX))
    add("POST /update", c.post("/update", data={"id": "1", "title": "Buy oat milk", "done": "1",
                                               "details": "**bold** é", "priority": "0", "name": "alice"}, headers=HX))
    add("POST /reorder", c.post("/reorder", content="id=2&id=1",
                                headers={**HX, "Content-Type": "application/x-www-form-urlencoded"}))
    add("GET /nonexistent", c.get("/nonexistent/page"))
    add("GET /favicon.ico", c.get("/favicon.ico"))
    add("GET /picovars.css", c.get("/picovars.css"))
    add("HEAD /", c.head("/"))
    add("POST /rm?id=2", c.post("/rm", params={"id": 2}, headers=HX))
    add("GET / after rm", c.get("/"))
    add("GET /logout", c.get("/logout"))
    add("GET / after logout", c.get("/"))
    # a bad login: wrong password for an existing user
    add("POST /send_login wrong pwd", c.post("/send_login", data={"name": "alice", "pwd": "nope"}))
    add("GET / after wrong pwd", c.get("/"))
