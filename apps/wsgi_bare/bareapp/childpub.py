"""A view that publishes from a child process, for `poe smoke-child-publish` (#322).

The pattern #310 pushed people to: work that must outlive the request runs
in a child process, and the child publishes its progress onto the bus it was
handed with `pass_fds`, the only way the bus reaches a child: every
descriptor the server creates is close-on-exec (SPEC G16). The shared
event-id page is a mapping, and a mapping dies at exec: `M0_SHARED_ID_ADDR`
is a number in the PARENT's address space. A child that
inherited the environment wholesale called `m0pub.next_event_id()` on that
number and died with SIGSEGV, or, where the new image had something mapped
there, incremented eight bytes of it.

`/spawn?mode=M&channel=C` takes an id in the parent, runs one child that
publishes `from-child` on C and prints what it got, takes another id, and
answers all of it as JSON. The modes:

- `inherit`: the whole environment and the bus fds -- what #322 reported.
- `scrub`: the same without `M0_SHARED_ID_ADDR`, the workaround it named.
- `handoff`: `m0pub.child_fds()` in `pass_fds`, the supported way: the page
  travels as a descriptor, so the child's ids come from the same counter.
- `stale_fd`: `M0_SHARED_ID_FD` inherited but the page NOT passed, and an
  unrelated file sitting on that descriptor number in the child -- a fd
  number is as stale after exec as an address is, and must be refused.
- `stale_bus`: the same for the bus. Nothing is passed, and an unrelated
  file sits on the first `M0_BUS_WRITE_FDS` number in the child. The bus
  is close-on-exec (SPEC G16), so a child handed nothing has no bus, and
  it must write nothing into whatever file now has that number.
- `stale_bus_socket`: the same, with the child's OWN Unix datagram socket
  on that number (a syslog-shaped socket, connected to a path) and a
  default socket timeout set. A check by kind passed it and wrote the bus
  datagram into it, and building a socket object over it under that
  timeout turned it non-blocking; nothing may reach it, and it must still
  block.
- `malformed_bus`: `M0_BUS_WRITE_FDS` names a negative and an overflowing
  number. Publishing degrades to nothing written; it never raises.

`/events?channel=C` holds an SSE stream, so a probe can see the child's frame
arrive and whether it carried an `id:` line.

Its own module, never a route in `wsgi.py`, like `bareapp.ticker`.
"""

import json
import os
import subprocess
import sys
import tempfile
from urllib.parse import parse_qs

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
M0PUB_SRC = os.path.join(REPO, "packaging", "m0serve", "src")
if M0PUB_SRC not in sys.path:
    sys.path.insert(0, M0PUB_SRC)

from m0serve import m0pub  # noqa: E402

# The child's whole program. It imports the same m0pub the parent does.
CHILD = r"""
import json, os, sys
if os.environ.get("CHILDPUB_OCCUPY_FD"):
    # Put an unrelated file on the descriptor number the parent's page had.
    n = int(os.environ["CHILDPUB_OCCUPY_FD"])
    f = open(os.environ["CHILDPUB_OCCUPY_PATH"], "r+b")
    os.dup2(f.fileno(), n)
srv = None
if os.environ.get("CHILDPUB_OCCUPY_SOCKET"):
    # The child's own datagram socket, connected to a path, on a bus fd's
    # number -- and a default timeout, under which a socket object built
    # over a descriptor switches it to non-blocking.
    import socket, tempfile
    n = int(os.environ["CHILDPUB_OCCUPY_SOCKET"])
    path = os.path.join(tempfile.mkdtemp(), "s")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    srv.bind(path)
    cli = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    cli.connect(path)
    os.dup2(cli.fileno(), n)
    socket.setdefaulttimeout(5)
from m0serve import m0pub
written, event_id = m0pub.publish_with_id(sys.argv[1], "from-child")
out = {"id": event_id, "written": written}
if srv is not None:
    srv.setblocking(False)
    try:
        out["received"] = len(srv.recv(65536))
    except BlockingIOError:
        out["received"] = 0
    out["still_blocking"] = os.get_blocking(n)
print(json.dumps(out))
"""


def _spawn(mode, channel):
    env = dict(os.environ)
    env["PYTHONPATH"] = M0PUB_SRC
    fds = list(m0pub.bus_write_fds())
    occupy = None
    if mode == "scrub":
        env.pop("M0_SHARED_ID_ADDR", None)
    elif mode == "handoff":
        if not hasattr(m0pub, "child_fds"):
            return {"error": "m0pub has no child_fds()"}
        fds = list(m0pub.child_fds())
    elif mode == "stale_fd":
        page_fd = env.get("M0_SHARED_ID_FD", "")
        if not page_fd:
            return {"error": "the server exports no M0_SHARED_ID_FD"}
        # A regular file of a page's size, so a size check alone cannot
        # tell it from the real page: only the magic word can.
        occupy = tempfile.NamedTemporaryFile(delete=False)
        occupy.write(b"\0" * 16384)
        occupy.close()
        env["CHILDPUB_OCCUPY_FD"] = page_fd
        env["CHILDPUB_OCCUPY_PATH"] = occupy.name
    elif mode == "stale_bus":
        bus = m0pub.bus_write_fds()
        if not bus:
            return {"error": "the server exports no M0_BUS_WRITE_FDS"}
        fds = []  # the bus is NOT handed over
        occupy = tempfile.NamedTemporaryFile(delete=False)
        occupy.write(b"\0" * 16384)
        occupy.close()
        env["CHILDPUB_OCCUPY_FD"] = str(bus[0])
        env["CHILDPUB_OCCUPY_PATH"] = occupy.name
    elif mode == "stale_bus_socket":
        bus = m0pub.bus_write_fds()
        if not bus:
            return {"error": "the server exports no M0_BUS_WRITE_FDS"}
        fds = []  # the bus is NOT handed over
        env["CHILDPUB_OCCUPY_SOCKET"] = str(bus[0])
    elif mode == "malformed_bus":
        fds = []
        env["M0_BUS_WRITE_FDS"] = "-1,99999999999999999999"
    elif mode != "inherit":
        return {"error": "unknown mode " + mode}
    try:
        proc = subprocess.run(
            [sys.executable, "-c", CHILD, channel],
            env=env, pass_fds=fds, capture_output=True, text=True, timeout=30,
        )
    finally:
        if occupy is not None:
            with open(occupy.name, "rb") as f:
                untouched = f.read() == b"\0" * 16384
            os.unlink(occupy.name)
    result = {"exit": proc.returncode, "stderr": proc.stderr[-2000:]}
    if occupy is not None:
        result["occupied_file_untouched"] = untouched
    try:
        result.update(json.loads(proc.stdout.strip().splitlines()[-1]))
    except (IndexError, ValueError):
        result["stdout"] = proc.stdout[-2000:]
    return result


def application(environ, start_response):
    path = environ.get("PATH_INFO", "")
    query = {k: v[0] for k, v in parse_qs(environ.get("QUERY_STRING", "")).items()}
    channel = query.get("channel", "childpub")
    if path == "/events":
        start_response("200 OK", [
            ("Content-Type", "text/event-stream"),
            ("M0-Hold", "stream"),
            ("M0-Channel", channel),
        ])
        return [b": connected\n\n"]
    if path == "/spawn":
        before = m0pub.next_event_id()
        child = _spawn(query.get("mode", "inherit"), channel)
        after = m0pub.next_event_id()
        body = json.dumps({
            "pid": os.getpid(), "before": before, "after": after, "child": child,
        }).encode()
        start_response("200 OK", [("Content-Type", "application/json")])
        return [body]
    start_response("404 Not Found", [("Content-Type", "text/plain")])
    return [b"not found\n"]
