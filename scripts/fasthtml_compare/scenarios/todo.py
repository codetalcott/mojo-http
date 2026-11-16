"""fasthtml-example/01_todo_app: fast_app(db), PUT/DELETE, path params."""
import os
import httpx
from compare import obs, upstream

OWN = False
APP_DIR = upstream("fasthtml-example", "01_todo_app")
SPEC = "main:app"
EXTRA = {}
def SETUP(d): os.makedirs(os.path.join(d, "data"), exist_ok=True)
HX = {"HX-Request": "true"}

def scenario(srv, steps):
    c = httpx.Client(base_url=srv.base, follow_redirects=False, timeout=10)
    add = lambda label, r: steps.append((label, obs(r)))
    add("GET /", c.get("/"))
    for t in ("one", "två ✓", "three & <four>"):
        add(f"POST / {t}", c.post("/", data={"task": t}, headers=HX))
    add("GET /todos/2", c.get("/todos/2", headers=HX))
    add("GET /edit/2", c.get("/edit/2", headers=HX))
    add("PUT /", c.put("/", data={"id": "2", "task": "två edited", "done": "1"}, headers=HX))
    add("DELETE /todos/1", c.delete("/todos/1", headers=HX))
    add("GET / final", c.get("/"))
    add("GET /favicon.ico", c.get("/favicon.ico"))
    add("GET /picovars.css", c.get("/picovars.css"))
    add("GET /todos/99 (missing)", c.get("/todos/99", headers=HX))
    add("OPTIONS /", c.options("/"))
