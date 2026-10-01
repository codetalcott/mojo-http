"""A WSGI application on psycopg's BINARY wheel, for `smoke-pg-notify`.

The wheel bundles a libpq of its own. Under `m0serve --pg-listen` the
server has already opened the system's libpq when this module is imported,
and the gate asks which library psycopg then runs on (SPEC O24): `/v`
answers what psycopg says of itself and which libpq files the process has
mapped, `/q` runs one query through it.

One `key=value` per line, so the gate reads it with grep.
"""

import os

import psycopg


def _mapped():
    """The libpq files mapped in this process; empty where /proc is not."""
    try:
        with open("/proc/self/maps") as f:
            return sorted({ln.split()[-1] for ln in f if "libpq" in ln})
    except OSError:
        return []


def application(environ, start_response):
    path = environ.get("PATH_INFO", "")
    if path == "/v":
        lines = [
            "impl=%s" % psycopg.pq.__impl__,
            "version=%d" % psycopg.pq.version(),
            "build_version=%d" % psycopg.pq.__build_version__,
            "pid=%d" % os.getpid(),
        ] + ["mapped=%s" % p for p in _mapped()]
    elif path == "/q":
        with psycopg.connect(os.environ["LIBPQ_APP_URL"]) as conn:
            lines = ["answer=%s" % conn.execute("select 40 + 2").fetchone()[0]]
    else:
        start_response("404 Not Found", [("Content-Type", "text/plain")])
        return [b"not found\n"]
    body = ("\n".join(lines) + "\n").encode()
    start_response("200 OK", [("Content-Type", "text/plain"),
                              ("Content-Length", str(len(body)))])
    return [body]
