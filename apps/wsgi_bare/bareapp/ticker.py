"""An application with a thread of its own, for `poe smoke-app-threads` (SPEC E20).

A Django app that runs background work on a `threading.Thread` -- an agent
turn publishing its progress with `m0pub.publish`, say -- needs that thread
to run while the server is idle. Served with no handler pool, it did not
(#310): the event loop's thread has held the GIL since `Py_Initialize`, and
it blocked in `kevent`/`epoll` without releasing it, so a thread that asked
for the lock waited for the next request to run some Python and hand it
over. Measured 0 ticks in 3 s idle under `--realtime`, `--blocking-threads
0` and `--workers 2` alike.

The thread starts at import, which happens in each worker after the fork,
so every worker has one. It sleeps 10 ms per tick; sleeping releases the
GIL and waking needs it back, so the count is a direct reading of how often
the lock came free. `/ticks` answers the count and the pid, the pid because
two readings only compare when the same worker's thread took both.

Its own module, never a route in `wsgi.py`: a thread ticking every 10 ms
inside `bareapp.wsgi` would sit under every smoke that serves it, the
pool-parallelism ratio among them.
"""

import json
import os
import threading
import time

TICK_SECONDS = 0.01

_ticks = 0


def _tick():
    global _ticks
    while True:
        time.sleep(TICK_SECONDS)
        _ticks += 1


threading.Thread(target=_tick, name="ticker", daemon=True).start()


def application(environ, start_response):
    if environ.get("PATH_INFO") == "/ticks":
        body = json.dumps({"pid": os.getpid(), "ticks": _ticks}).encode()
        start_response("200 OK", [("Content-Type", "application/json")])
        return [body]
    start_response("404 Not Found", [("Content-Type", "text/plain")])
    return [b"not found\n"]
