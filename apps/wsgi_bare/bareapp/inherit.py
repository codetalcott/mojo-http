"""What a child process the application starts inherits, for `poe smoke-exec-inherit` (SPEC G16).

A child that execs keeps every descriptor not marked close-on-exec:
`subprocess` with `close_fds=False`, `os.system`, `pty.fork` and exec. The
server's own descriptors -- the client connections open at that moment, the
listener, the channels between the loop and its pools, the bus -- must not
be among them. A connection the server closes stays open in a child that
holds it: FastHTML's terminal example took 10 s to close a WebSocket
(2026-09-22).

`/children` runs one child with `close_fds=False` that lists every
descriptor above 2 it holds, by kind, and answers the list as JSON. Served
as WSGI (`application`) and as ASGI (`asgi`), so one module covers the
pool, the loop and the executor.

Its own module, never a route in `wsgi.py`, like `bareapp.ticker`.
"""

import json
import subprocess
import sys

LISTER = r"""
import json, os, stat
out = []
for name in os.listdir("/dev/fd"):
    fd = int(name)
    if fd <= 2:
        continue
    try:
        mode = os.fstat(fd).st_mode
    except OSError:
        continue  # the directory listdir opened, closed again by now
    if stat.S_ISSOCK(mode):
        kind = "socket"
    elif stat.S_ISFIFO(mode):
        kind = "pipe"
    elif stat.S_ISREG(mode):
        kind = "file"
    elif stat.S_ISDIR(mode):
        kind = "dir"
    else:
        kind = "other"
    out.append([fd, kind])
print(json.dumps(out))
"""


def children():
    proc = subprocess.run(
        [sys.executable, "-c", LISTER],
        close_fds=False, capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        return {"error": proc.stderr[-2000:]}
    return {"fds": json.loads(proc.stdout)}


def application(environ, start_response):
    if environ.get("PATH_INFO", "") != "/children":
        start_response("404 Not Found", [("Content-Type", "text/plain")])
        return [b"not found"]
    body = json.dumps(children()).encode()
    start_response("200 OK", [("Content-Type", "application/json")])
    return [body]


async def asgi(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    if scope["type"] != "http":
        return
    if scope["path"] != "/children":
        status, body = 404, b"not found"
    else:
        # Blocks the executor for the child's life: a probe, not an app.
        status, body = 200, json.dumps(children()).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": body})
