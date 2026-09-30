#!/usr/bin/env python3
"""IPv6 on the wire, for `poe smoke-ipv6` (review R15, SPEC M29).

    ipv6_probe.py M0SERVE HOST_CHECK BASE_PORT

Every listener was IPv4 whatever its address, and `AF_INET6` held
OpenBSD's number, so `--host ::` could not bind at all. What this holds:

  - `--host ::` listens on both families, `IPV6_V6ONLY` set to 0 rather
    than left to a default that is a system setting; `--host [::1]` (the
    bracket form, as in a URL) answers on `::1` and refuses IPv4;
  - the client is reported in its own family -- `REMOTE_ADDR`, ASGI's
    `scope["client"]`, and the access log's `remote_addr` -- and an IPv4
    client of `::` as IPv4 (`127.0.0.1`, not `::ffff:127.0.0.1`: gunicorn
    and uvicorn report the mapped form, and this server reports what a
    `0.0.0.0` listener would);
  - a request with a query string is answered on `::`, whose own address
    `[::]:PORT` the loop puts in front of every such target;
  - `--workers 2` (a connection handed to a sibling carries its peer),
    `--spawn-workers` (the listener crosses an exec by number, and the new
    image adopts it as IPv6) and `--reload` serve `::` too, and the doctor
    reports the host;
  - the Mojo host on `M0_HOST=::` and on `--host ::1`, and its doctor's
    address, `[::]:PORT`.

It fails, naming the phase, when the runner has no IPv6 loopback: an
IPv6 gate that skipped there would pass having tested nothing.

Exits 0 printing one summary line, or 1 naming the first phase that failed.
Stdlib only.
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from probelib import fail, phase, server, stamp

stamp("ipv6_probe: FAIL", fail="ipv6_probe: FAIL: {phase}: {msg}")

WSGI_APP = '''\
import json


def application(environ, start_response):
    body = json.dumps({
        "remote_addr": environ.get("REMOTE_ADDR"),
        "remote_port": environ.get("REMOTE_PORT"),
        "query": environ.get("QUERY_STRING"),
    }).encode()
    start_response("200 OK", [("Content-Type", "application/json")])
    return [body]
'''

ASGI_APP = '''\
import json


async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    body = json.dumps({"client": list(scope.get("client") or [])}).encode()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": body})
'''


def clean_env(extra: dict | None = None) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("M0_")}
    env.update(extra or {})
    return env


def get(host: str, port: int, path: str = "/", conn=None) -> dict:
    """GET `path` from `host` (an IPv4 or IPv6 literal) and the JSON body."""
    own = conn is None
    c = conn or http.client.HTTPConnection(host, port, timeout=10)
    try:
        c.request("GET", path)
        r = c.getresponse()
        raw = r.read()
    finally:
        if own:
            c.close()
    if r.status != 200:
        fail("GET %s from %s answered %d: %r" % (path, host, r.status, raw[:200]))
    return json.loads(raw)


def refused_v4(port: int) -> bool:
    try:
        socket.create_connection(("127.0.0.1", port), timeout=3).close()
    except ConnectionRefusedError:
        return True
    return False


def want(got, expected, what: str) -> None:
    if got != expected:
        fail("%s: got %r, want %r" % (what, got, expected))


def both_families(port: int, conn4=None, conn6=None) -> None:
    """The WSGI app answers IPv4 and IPv6 clients, each reported as itself."""
    body = get("127.0.0.1", port, "/v4?a=1", conn4)
    want(body["remote_addr"], "127.0.0.1", "REMOTE_ADDR of an IPv4 client of ::")
    want(body["query"], "a=1", "the query string of a request to [::]")
    body = get("::1", port, "/v6", conn6)
    want(body["remote_addr"], "::1", "REMOTE_ADDR of an IPv6 client")


def m0serve(binary: str, app_dir: str, spec: str, port: int, *flags: str,
            log: str, ready_host: str = "::1"):
    argv = [binary, spec, "--app-dir", app_dir, "--port", str(port), *flags]
    target = "http://%s:%d/" % ("[%s]" % ready_host if ":" in ready_host else ready_host, port)
    return server(argv, target, timeout=60, log=log, group=True, env=clean_env())


def doctor_report(argv: list, env: dict | None = None) -> tuple:
    p = subprocess.run(argv, env=clean_env(env), capture_output=True, text=True, timeout=60)
    lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
    if not lines:
        fail("the doctor printed nothing (exit %d): %s" % (p.returncode, p.stderr[-300:]))
    try:
        return p.returncode, json.loads(lines[-1])
    except ValueError:
        fail("the doctor's last line is not JSON: %r" % lines[-1][:200])


def main() -> int:
    m0, host_check, base = sys.argv[1], sys.argv[2], int(sys.argv[3])
    ports = iter(range(base, base + 12))
    # Under the smoke, its $SMOKE_DIR: the lib prints every *.log there when
    # the task fails and removes the directory either way.
    smoke_dir = os.environ.get("SMOKE_DIR")
    work = smoke_dir or tempfile.mkdtemp(prefix="ipv6-probe-")
    logs = work
    with open(os.path.join(work, "v6app.py"), "w") as f:
        f.write(WSGI_APP)
    with open(os.path.join(work, "v6asgi.py"), "w") as f:
        f.write(ASGI_APP)

    phase("the runner has an IPv6 loopback")
    try:
        probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        probe.bind(("::1", 0))
        probe.listen(1)
        socket.create_connection(("::1", probe.getsockname()[1]), timeout=3).close()
        probe.close()
    except OSError as e:
        fail("no IPv6 loopback here (%r): this gate cannot run, and must not pass" % e)

    phase("m0serve --host :: answers both families")
    port = next(ports)
    log = os.path.join(logs, "ipv6-dual.log")
    with m0serve(m0, work, "v6app:application", port, "--host", "::", "--access-log", log=log):
        both_families(port)
    with open(log) as f:
        access = [json.loads(ln) for ln in f if '"msg":"access"' in ln]
    peers = sorted({line.get("remote_addr") for line in access})
    if "::1" not in peers or "127.0.0.1" not in peers:
        fail("the access log's remote_addr values were %r, want ::1 and 127.0.0.1" % peers)

    phase("m0serve --host [::1] is IPv6 alone")
    port = next(ports)
    with m0serve(m0, work, "v6app:application", port, "--host", "[::1]",
                 log=os.path.join(logs, "ipv6-loopback.log")):
        want(get("::1", port)["remote_addr"], "::1", "REMOTE_ADDR on [::1]")
        if not refused_v4(port):
            fail("127.0.0.1 reached a --host [::1] listener")

    phase("m0serve --host 127.0.0.1 is IPv4 alone, as before")
    port = next(ports)
    with m0serve(m0, work, "v6app:application", port, "--host", "127.0.0.1",
                 log=os.path.join(logs, "ipv6-v4only.log"), ready_host="127.0.0.1"):
        want(get("127.0.0.1", port, "/?a=1")["remote_addr"], "127.0.0.1", "REMOTE_ADDR on 127.0.0.1")
        try:
            socket.create_connection(("::1", port), timeout=3).close()
            fail("::1 reached a --host 127.0.0.1 listener")
        except ConnectionRefusedError:
            pass

    phase("ASGI's scope client on ::")
    port = next(ports)
    with m0serve(m0, work, "v6asgi:app", port, "--host", "::",
                 log=os.path.join(logs, "ipv6-asgi.log")):
        client = get("::1", port)["client"]
        want(client[0] if client else None, "::1", "scope['client'] host of an IPv6 client")
        client = get("127.0.0.1", port)["client"]
        want(client[0] if client else None, "127.0.0.1", "scope['client'] host of an IPv4 client of ::")

    phase("--workers 2 on ::, connections handed between workers")
    port = next(ports)
    with m0serve(m0, work, "v6app:application", port, "--host", "::", "--workers", "2",
                 log=os.path.join(logs, "ipv6-workers.log")):
        # Held open, so the acceptor is loaded and passes the next ones on.
        conns = []
        for i in range(8):
            fam = "::1" if i % 2 else "127.0.0.1"
            c = http.client.HTTPConnection(fam, port, timeout=10)
            want(get(fam, port, "/?i=%d" % i, c)["remote_addr"], fam, "REMOTE_ADDR, connection %d" % i)
            conns.append((fam, c))
        for i, (fam, c) in enumerate(conns):
            want(get(fam, port, "/again", c)["remote_addr"], fam, "REMOTE_ADDR, again on %d" % i)
            c.close()

    phase("--workers 2 --spawn-workers on ::, the listener adopted across an exec")
    port = next(ports)
    with m0serve(m0, work, "v6app:application", port, "--host", "::", "--workers", "2",
                 "--spawn-workers", log=os.path.join(logs, "ipv6-spawn.log")):
        for _ in range(4):
            both_families(port)

    phase("--reload on ::")
    port = next(ports)
    with m0serve(m0, work, "v6app:application", port, "--host", "::", "--reload",
                 log=os.path.join(logs, "ipv6-reload.log")):
        both_families(port)

    phase("m0serve's doctor on ::")
    port = next(ports)
    code, doc = doctor_report([m0, "v6app:application", "--app-dir", work, "--host", "::",
                               "--port", str(port), "--doctor"])
    want(code, 0, "the doctor's exit for --host ::")
    want(doc.get("server", {}).get("host"), "::", "the doctor's host")
    code, doc = doctor_report([m0, "v6app:application", "--app-dir", work, "--host", "[::1]",
                               "--port", str(port), "--doctor"])
    want(doc.get("server", {}).get("host"), "::1", "the doctor's host for --host [::1]")

    phase("the Mojo host on M0_HOST=::")
    port = next(ports)
    with server([host_check], "http://[::1]:%d/health" % port, timeout=60,
                log=os.path.join(logs, "ipv6-host.log"),
                env=clean_env({"M0_HOST": "::", "M0_PORT": str(port)})):
        for fam in ("127.0.0.1", "::1"):
            c = http.client.HTTPConnection(fam, port, timeout=10)
            c.request("GET", "/health?from=%s" % fam)
            r = c.getresponse()
            r.read()
            c.close()
            want(r.status, 200, "the Mojo host's /health over %s" % fam)

    phase("the Mojo host's --host ::1")
    port = next(ports)
    with server([host_check, "--host", "::1", "--port", str(port)],
                "http://[::1]:%d/health" % port, timeout=60,
                log=os.path.join(logs, "ipv6-host-loopback.log"), env=clean_env()):
        if not refused_v4(port):
            fail("127.0.0.1 reached a Mojo host on --host ::1")

    phase("the Mojo host's doctor on ::")
    port = next(ports)
    code, doc = doctor_report([host_check, "--doctor", "--host", "::", "--port", str(port)])
    want(code, 0, "the host doctor's exit for --host ::")
    want(doc.get("config", {}).get("address"), "[::]:%d" % port, "the host doctor's address")

    print("ipv6_probe: OK -- :: dual-stack and ::1 IPv6-only, through m0serve "
          "(WSGI, ASGI, --workers, --spawn-workers, --reload, the doctor) and the Mojo host")
    if not smoke_dir:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
