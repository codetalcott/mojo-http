"""probe with debug=True: does the developer see Starlette's traceback page?"""
import httpx
from probe import APP_DIR, SPEC, SETUP  # noqa: F401 (the scenario's application)
OWN = True
EXTRA = {}
ENV = {"PROBE_DEBUG": "1"}
def scenario(srv, steps):
    c = httpx.Client(base_url=srv.base, timeout=10)
    for path, hdrs in (("/boom", {"Accept": "text/html"}), ("/boom", {}), ("/boom-async", {"Accept": "text/html"})):
        r = c.get(path, headers=hdrs)
        steps.append((f"GET {path} {hdrs}", {"status": r.status_code, "ct": r.headers.get("content-type"),
                      "has_traceback": "kaboom" in r.text, "head": r.text[:80]}))
