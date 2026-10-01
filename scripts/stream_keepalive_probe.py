#!/usr/bin/env python3
"""A stream's socket has TCP keepalive on, for `poe smoke-stream-keepalive`
(SPEC I32).

    stream_keepalive_probe.py options PORT SERVER_PID IDLE_S
        open an SSE stream the application writes (`/stream-quiet`), a
        WebSocket (`/ws`) and one plain keep-alive connection, and read each
        one's SERVER-side socket out of the kernel: `ss` on Linux, `lsof`
        on macOS. With IDLE_S > 0 both streams must show keepalive with
        that idle time and the plain connection none; with 0, none of the
        three may.
    stream_keepalive_probe.py idle PORT SECONDS
        open `/stream-quiet` and do nothing for SECONDS, several probe
        rounds: a live client's kernel answers every probe, so the
        application must still count the stream open at the end. Prints
        `kept_ms=N`. The arm that shows keepalive reaps the dead and not
        the quiet.
    stream_keepalive_probe.py vanish PORT LIMIT_S reaped|held
        Linux only, and it needs iptables (as root, or through `sudo -n`).
        Open `/stream-quiet`, then drop every packet the client's port
        sends, so the client vanishes without a FIN. `reaped`: the
        application must be told its client is gone within LIMIT_S.
        `held`: it must NOT be, for the whole of LIMIT_S -- the arm that
        shows the first one can fail. Prints `reaped_ms=N` or `held_ms=N`.

Why the kernel is asked, and not the server: the option is set on a socket
only the server holds, and a getsockopt from inside the server would be the
code under test reporting on itself. `ss` prints a socket's armed timer
(`timer:(keepalive,14sec,0)`) and `lsof -Tf` its options
(`SO=KEEPALIVE=15000`), from outside.

Why the stream is quiet: a stream with bytes in flight is reaped by their
retransmission, with or without keepalive (docs/notes/a-stream-has-no-deadline.md).
The stream an application writes gets no heartbeat from the loop, so once
the application stops writing nothing is in flight, and keepalive is the
one thing left that notices a client that is gone.

Each prints one summary line and exits 0, or exits 1 naming the phase.
Stdlib only.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import socket
import subprocess
import sys
import time

from probelib import WebSocket, fail, phase, stamp

stamp("stream_keepalive_probe: FAIL", fail="stream_keepalive_probe: FAIL: {phase}: {msg}",
      stream=sys.stderr)

HOST = "127.0.0.1"
LINUX = sys.platform.startswith("linux")


def open_quiet(port: int) -> socket.socket:
    """An SSE stream the application writes, read up to its one event."""
    s = socket.create_connection((HOST, port), timeout=10)
    s.sendall(b"GET /stream-quiet HTTP/1.1\r\nHost: probe\r\nAccept: text/event-stream\r\n\r\n")
    buf = b""
    while b"data: quiet" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            fail("/stream-quiet closed before its event: %r" % buf[:200])
        buf += chunk
    return s


def quiet_streams(port: int) -> dict:
    c = http.client.HTTPConnection(HOST, port, timeout=10)
    try:
        c.request("GET", "/quiet-streams")
        r = c.getresponse()
        body = r.read()
    finally:
        c.close()
    if r.status != 200:
        fail("/quiet-streams answered HTTP %d" % r.status)
    return json.loads(body)


def server_socket(port: int, cport: int, pid: int) -> str:
    """The kernel's line for the server's end of `cport`'s connection."""
    if LINUX:
        out = subprocess.run(
            ["ss", "-tnoi", "state", "established",
             "( sport = :%d and dport = :%d )" % (port, cport)],
            capture_output=True, text=True).stdout
        lines = [l.strip() for l in out.splitlines()[1:] if l.strip()]
        return " ".join(lines)
    out = subprocess.run(
        ["lsof", "-a", "-p", str(pid), "-i", "TCP@%s:%d" % (HOST, port), "-Tf", "-nP"],
        capture_output=True, text=True).stdout
    want = "->%s:%d " % (HOST, cport)
    for line in out.splitlines():
        if want in line:
            return line.strip()
    return ""


def keepalive_of(line: str):
    """Seconds on the keepalive timer the kernel shows for a socket, or
    None for a socket with none."""
    if LINUX:
        m = re.search(r"timer:\(keepalive,([0-9.]+)(ms|sec|min)", line)
        if not m:
            return None
        scale = {"ms": 0.001, "sec": 1.0, "min": 60.0}[m.group(2)]
        return float(m.group(1)) * scale
    m = re.search(r"KEEPALIVE=(\d+)", line)
    return int(m.group(1)) / 1000.0 if m else None


def check(name: str, line: str, idle: int, is_stream: bool) -> str:
    if not line:
        fail("%s: the kernel shows no server-side socket for it" % name)
    got = keepalive_of(line)
    if idle > 0 and is_stream:
        if got is None:
            fail("%s: no keepalive on its socket: %s" % (name, line))
        # Both print the armed timer, which started at `idle` a moment ago
        # (macOS showed 7001 ms for 7 s), so the reading sits just under or
        # at it. A second either way tells one setting from the next.
        if not (max(0.0, idle - 1.5) < got <= idle + 0.5):
            fail("%s: keepalive timer at %.3f s, wanted about %d: %s" % (name, got, idle, line))
        return "%s=on" % name
    if got is not None:
        fail("%s: keepalive is on (%.3f s) where none was asked for: %s" % (name, got, line))
    return "%s=off" % name


def options(port: int, pid: int, idle: int) -> None:
    phase("an SSE stream the application writes")
    sse = open_quiet(port)
    phase("a WebSocket")
    ws = WebSocket.connect(HOST, port, "/ws")
    if not (ws.status_line or b"").startswith(b"HTTP/1.1 101"):
        fail("/ws answered %r" % ws.status_line)
    phase("a plain keep-alive connection")
    plain = socket.create_connection((HOST, port), timeout=10)
    plain.sendall(b"GET / HTTP/1.1\r\nHost: probe\r\n\r\n")
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = plain.recv(4096)
        if not chunk:
            fail("the plain connection closed before its head")
        buf += chunk
    # The option goes on as the head is written; give the loop its pass.
    time.sleep(0.2)
    phase("reading the three sockets out of the kernel")
    found = [
        check("sse", server_socket(port, sse.getsockname()[1], pid), idle, True),
        check("websocket", server_socket(port, ws.sock.getsockname()[1], pid), idle, True),
        check("plain", server_socket(port, plain.getsockname()[1], pid), idle, False),
    ]
    for s in (sse, ws.sock, plain):
        s.close()
    print("idle_s=%d %s" % (idle, " ".join(found)))


def idle(port: int, seconds: float) -> None:
    phase("opening the stream")
    before = quiet_streams(port)
    s = open_quiet(port)
    end = time.monotonic() + 5
    while quiet_streams(port)["open"] != before["open"] + 1:
        if time.monotonic() > end:
            fail("the application never counted the stream open: %r" % quiet_streams(port))
        time.sleep(0.05)
    phase("idling while the kernel probes")
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        now = quiet_streams(port)
        if now["closed"] > before["closed"] or now["open"] != before["open"] + 1:
            fail("a live, idle client's stream was closed after %.1f s: %r"
                 % (time.monotonic() - t0, now))
        time.sleep(0.2)
    # And it is still a stream: the server has not closed its end.
    s.settimeout(0.2)
    try:
        if s.recv(1) == b"":
            fail("the server closed a live, idle client's stream")
    except socket.timeout:
        pass
    s.close()
    print("kept_ms=%d" % int(seconds * 1000))


def iptables(op: str, cport: int) -> None:
    cmd = ["iptables", "-w", op, "INPUT", "-i", "lo", "-p", "tcp",
           "--sport", str(cport), "-j", "DROP"]
    if os.geteuid() != 0:
        cmd = ["sudo", "-n"] + cmd
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        fail("%s failed (%d): %s" % (" ".join(cmd), r.returncode, r.stderr.strip()))


def vanish(port: int, limit: float, want: str) -> None:
    if not LINUX:
        fail("the vanish arm is Linux's: it drops packets with iptables")
    phase("opening the stream")
    before = quiet_streams(port)
    s = open_quiet(port)
    cport = s.getsockname()[1]
    end = time.monotonic() + 5
    while quiet_streams(port)["open"] != before["open"] + 1:
        if time.monotonic() > end:
            fail("the application never counted the stream open: %r" % quiet_streams(port))
        time.sleep(0.05)
    phase("dropping the client's packets")
    iptables("-I", cport)
    t0 = time.monotonic()
    reaped_at = None
    try:
        phase("waiting for the application to be told")
        while time.monotonic() - t0 < limit:
            if quiet_streams(port)["closed"] > before["closed"]:
                reaped_at = time.monotonic() - t0
                break
            time.sleep(0.1)
    finally:
        iptables("-D", cport)
        s.close()
    if want == "reaped":
        if reaped_at is None:
            fail("a vanished client still held its stream after %.0f s" % limit)
        print("reaped_ms=%d" % int(reaped_at * 1000))
    else:
        if reaped_at is not None:
            fail("the stream was closed %.1f s after its client vanished, with keepalive off: "
                 "something else reaps it, and the other arm proves nothing" % reaped_at)
        print("held_ms=%d" % int(limit * 1000))


def main() -> None:
    if len(sys.argv) >= 5 and sys.argv[1] == "options":
        options(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
    elif len(sys.argv) >= 4 and sys.argv[1] == "idle":
        idle(int(sys.argv[2]), float(sys.argv[3]))
    elif len(sys.argv) >= 5 and sys.argv[1] == "vanish" and sys.argv[4] in ("reaped", "held"):
        vanish(int(sys.argv[2]), float(sys.argv[3]), sys.argv[4])
    else:
        sys.exit(__doc__)


main()
