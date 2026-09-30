"""An application that answers, then exits: `smoke-doctor`'s control.

`smoke-doctor` reads a configuration the server accepts as "still serving
when the watchdog stopped it". The watchdog polls until the server answers
and then allows it a short grace, so the one thing it could lose is a
server that answers and then dies. This one answers its first request and
exits 3 a fifth of a second later, from a thread, through `os._exit` --
never a crash signal -- and the smoke insists the watchdog reads that as
exit 3, not as a server that served.
"""

import os
import threading

_armed = False


def application(environ, start_response):
    global _armed
    if not _armed:
        _armed = True
        threading.Timer(0.2, os._exit, (3,)).start()
    start_response("200 OK", [("Content-Type", "text/plain; charset=utf-8")])
    return [b"answered; exiting in 0.2 s\n"]
