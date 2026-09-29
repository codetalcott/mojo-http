#!/usr/bin/env python3
"""Does a child process the application starts inherit the server's descriptors? (SPEC G16)

Serves `bareapp.inherit` in each shape below and has a view start one child
with `close_fds=False` -- what `os.system`, `pty.fork` and a `subprocess`
that keeps its descriptors all do -- that lists every descriptor above 2 it
holds. The server is started here with nothing above 2, so ANY descriptor
above 2 in the child is the server's: a client connection (the view's own,
and an idle keep-alive one this probe holds open), the listener, the
channels between the loop and its pools, the bus, the shutdown pipe, the
shared page. A connection the server closes then stays open in the child;
FastHTML's terminal example took 10 s to close a WebSocket that way.

The shapes are where the server's descriptors come from: the zero-config
pool, the loop's own thread, forked workers (the page, the bus and the
accept-share channels), spawned workers (which adopt those by number), the
realtime bus, and the ASGI executor's channels.

    python3 scripts/exec_inherit_probe.py --port 8681

Prints one line per shape.
"""
import argparse
import http.client
import json
import os
import sys
import tempfile

from probelib import phase, server, stamp

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
stamp("exec_inherit_probe FAIL")

WSGI = "bareapp.inherit:application"
SHAPES = [
    ("wsgi", WSGI, []),
    ("inline", WSGI, ["--blocking-threads", "0"]),
    ("workers", WSGI, ["--workers", "2"]),
    ("spawned", WSGI, ["--workers", "2", "--spawn-workers"]),
    ("realtime", WSGI, ["--realtime"]),
    ("asgi", "bareapp.inherit:asgi", []),
]


def run_shape(port, shape, problems):
    phase("%s: an idle keep-alive connection" % shape)
    idle = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    idle.request("GET", "/idle")
    idle.getresponse().read()
    try:
        phase("%s: a child lists what it holds" % shape)
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        conn.request("GET", "/children")
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        if resp.status != 200:
            problems.append("%s: /children answered %d: %r" % (shape, resp.status, body[:200]))
            return
        answer = json.loads(body)
        if "error" in answer:
            problems.append("%s: the child failed: %s" % (shape, answer["error"]))
            return
        fds = answer["fds"]
        print("CHILD shape=%s holds=%s" % (shape, fds))
        if fds:
            # Every one is the server's: it was started with nothing above 2.
            problems.append(
                "%s: a child started with close_fds=False holds %d of the "
                "server's descriptors %s -- sockets are its connections, "
                "listener and channels, pipes its shutdown pipe, `other` its "
                "shared page; each must be close-on-exec" % (shape, len(fds), fds))
    finally:
        idle.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(REPO, "bin", "m0serve"))
    ap.add_argument("--port", type=int, default=8681)
    ap.add_argument("--shapes", default=",".join(s[0] for s in SHAPES))
    args = ap.parse_args()
    wanted = args.shapes.split(",")

    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, (shape, spec, flags) in enumerate(SHAPES):
            if shape not in wanted:
                continue
            port = args.port + i
            phase("%s: starting" % shape)
            # Any answer is ready, a 404 included; a server that exits first
            # is reported then, not after the 120 s a slow runner is given.
            argv = [args.bin, spec, "--app-dir", os.path.join(REPO, "apps", "wsgi_bare"),
                    "--port", str(port)] + flags
            with server(argv, "http://127.0.0.1:%d/nope" % port, timeout=120, status=None,
                        log=os.path.join(tmp, shape + ".log"), cwd=REPO):
                run_shape(port, shape, problems)
    if problems:
        print("exec_inherit_probe FAIL:")
        for p in problems:
            print("  - " + p)
        return 1
    print("exec_inherit_probe OK: %d shapes, no child holds a descriptor of the server's"
          % len(wanted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
