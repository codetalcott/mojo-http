#!/usr/bin/env python3
"""A connection that is not being read costs the loop nothing (SPEC C10).

kqueue's connection read filter is LEVEL triggered, and it used to stay
registered on a slot that was not reading: one waiting to write
(RESPONDING, on a one-shot write filter), or one whose request was out on a
pool thread or an executor. A client that had half-closed, or had sent its
next request, was then reported readable by every wait, and the loop
consumed the event without acting on it -- a full core for as long as the
response waited or the view ran (3.99 CPU seconds in 4, measured on macOS;
review record R4). epoll is edge triggered and its write one-shot replaces
the read interest, so Linux never spun: this fails without the fix on macOS
only and passes either way on Linux.

Four shapes -- a slot waiting to write and a slot whose request is out,
each with an EOF and with unread bytes -- built so the loop has armed its
read interest BEFORE the request arrives (a request that lands with the
accept is read eagerly and never arms one, which hides the spin), and each
measured while the client reads nothing:

  - a response in memory (POST /echo, 16 MiB) stalled on its client, which
    then half-closes
  - a file response (`--static`, sendfile) with the next request pipelined
    behind it, unread
  - a request out on the executor (/slow) whose client half-closed
  - the same with the next request pipelined behind it, unread

Controls measured on the broken build: a request out on the executor with
nothing pending costs 0.00 s, and each shape above a full core -- so the
bound is absolute. After each window the client reads, and everything it
asked for must arrive whole, so a fix that stopped the slot reading for good
fails here rather than passing quietly.

The meter is checked before it is trusted: a busy child must read as busy.
A probe whose CPU counter read zero whatever happened would pass on a
spinning loop.

usage: slot_lifecycle_probe.py PORT
  starts ./bin/m0serve itself (it needs the PID to meter), on apps/asgi_bare
  with `--static`; see `poe smoke-slot-lifecycle`
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import traceback

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8142
BIN = "./bin/m0serve"

BIG = 16 * 1024 * 1024  # past both socket buffers on either kernel
# How long the loop's CPU is metered per shape, and the most it may use. A
# spinning loop takes the whole window (measured 2.99 s of 3); an idle one
# takes nothing (0.00 s). A quarter of the window leaves a loaded runner its
# scheduling noise and still catches a spin by four times over.
WINDOW = 2.0
LIMIT = 0.5
# Settling time before the window: the server fills both socket buffers and
# parks on its write, or hands the job over, before it is metered.
SETTLE = 0.7
# The executor view's length: past settling, the window and slack, so the
# job is still out for the whole window.
SLOW_MS = 4000

# Which phase is running, for the crash handler below. Every shape ends in
# the same `recv` helpers, so a traceback names the same lines whichever
# shape was being proven.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("slot_lifecycle_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped

failures = []
worst = [0.0]


def fail(msg):
    failures.append("%s: %s" % (PHASE, msg))


def cpu_seconds(pid):
    """User plus system CPU of the whole process, every thread included."""
    try:
        with open("/proc/%d/stat" % pid) as fh:
            fields = fh.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    except FileNotFoundError:
        pass
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    total = 0.0
    for part in out.replace("-", ":").split(":"):
        total = total * 60 + float(part)
    return total


def metered(pid, window):
    """CPU seconds `pid` used over `window` wall seconds."""
    c0 = cpu_seconds(pid)
    time.sleep(window)
    return cpu_seconds(pid) - c0


def meter_self_test():
    """A process that spins must read as spinning, or nothing below means
    anything."""
    busy = subprocess.Popen([sys.executable, "-c", "while True: pass"])
    try:
        time.sleep(0.3)
        used = metered(busy.pid, 1.0)
    finally:
        busy.kill()
        busy.wait()
    if used < 0.5:
        print("slot_lifecycle_probe: FAIL: the meter read %.2f s for a process "
              "that spun for 1 s -- it cannot see a spinning loop, so the CPU "
              "half of this probe would prove nothing" % used)
        sys.exit(1)
    print("  the meter: a spinning child read %.2f s of 1.0" % used)


def read_head(sock, buf):
    while b"\r\n\r\n" not in buf:
        part = sock.recv(65536)
        if not part:
            raise RuntimeError("closed before a response head (%d bytes)" % len(buf))
        buf += part
    head, rest = buf.split(b"\r\n\r\n", 1)
    return head, rest


def read_response(sock, buf=b""):
    """(status line, body, leftover) for one Content-Length response."""
    head, rest = read_head(sock, buf)
    lines = head.split(b"\r\n")
    length = 0
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    while len(rest) < length:
        part = sock.recv(1 << 20)
        if not part:
            raise RuntimeError("closed after %d of %d body bytes" % (len(rest), length))
        rest += part
    return lines[0], rest[:length], rest[length:]


def connect_armed():
    """A connection whose read interest the loop has armed: the eager read
    at accept found nothing, so the request below arrives on a registered
    read filter -- the one a slot that stops reading must give up."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # A small window, so a response stalls early rather than landing in a
    # receive buffer that grows to hold it.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
    sock.settimeout(30)
    sock.connect((HOST, PORT))
    time.sleep(0.3)
    return sock


def meter_shape(pid, what):
    time.sleep(SETTLE)
    used = metered(pid, WINDOW)
    worst[0] = max(worst[0], used)
    if used > LIMIT:
        fail("the server used %.2f CPU seconds in %.1f while %s -- a slot that "
             "is not reading still has read interest, and the loop is woken "
             "by every wait for an event it does not consume (R4)"
             % (used, WINDOW, what))
    else:
        print("  %s: %.2f CPU seconds in %.1f" % (what, used, WINDOW))


def shape_memory(pid):
    sock = connect_armed()
    body = b"m0" * (BIG // 2)
    sock.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                 % len(body) + body)
    # The half-close lands once the echo is back from the executor and
    # stalled on the unread socket: a RESPONDING slot's EOF, not an
    # offloaded one's (the /slow shapes are those).
    time.sleep(1.0)
    sock.shutdown(socket.SHUT_WR)
    meter_shape(pid, "a response in memory waits for a half-closed client")
    status, got, _ = read_response(sock)
    if b" 200 " not in status or len(got) != len(body):
        fail("the echo arrived as %r with %d of %d bytes" % (status, len(got), len(body)))
    sock.close()


def shape_file_pipelined(pid):
    sock = connect_armed()
    sock.sendall(b"GET /files/big.bin HTTP/1.1\r\nHost: x\r\n\r\n")
    time.sleep(0.3)
    sock.sendall(b"GET /sized HTTP/1.1\r\nHost: x\r\n\r\n")
    meter_shape(pid, "a file response waits with the next request unread behind it")
    status, got, rest = read_response(sock)
    if b" 200 " not in status or len(got) != BIG:
        fail("the file arrived as %r with %d of %d bytes" % (status, len(got), BIG))
    status2, _, _ = read_response(sock, rest)
    if b" 200 " not in status2:
        fail("the pipelined request behind the file was answered %r" % status2)
    sock.close()


def shape_slow(pid, pipelined):
    sock = connect_armed()
    sock.sendall(b"GET /slow?ms=%d HTTP/1.1\r\nHost: x\r\n\r\n" % SLOW_MS)
    time.sleep(0.3)
    if pipelined:
        sock.sendall(b"GET /sized HTTP/1.1\r\nHost: x\r\n\r\n")
        what = "a request is out on the executor with the next one unread behind it"
    else:
        sock.shutdown(socket.SHUT_WR)
        what = "a request is out on the executor and its client half-closed"
    meter_shape(pid, what)
    status, got, rest = read_response(sock)
    if b" 200 " not in status or got != b"slept %d" % SLOW_MS:
        fail("the executor's answer arrived as %r %r" % (status, got[:40]))
    if pipelined:
        status2, _, _ = read_response(sock, rest)
        if b" 200 " not in status2:
            fail("the pipelined request behind the view was answered %r" % status2)
    sock.close()


def main():
    phase("the meter's self-test")
    meter_self_test()

    tmp = tempfile.mkdtemp()
    with open(os.path.join(tmp, "big.bin"), "wb") as fh:
        fh.write(b"m0" * (BIG // 2))
    log_path = os.path.join(tmp, "server.log")
    log = open(log_path, "w")
    srv = subprocess.Popen(
        [BIN, "bareapp.asgi:application", "--app-dir", "apps/asgi_bare",
         "--port", str(PORT), "--idle-timeout", "30", "--max-body", "32m",
         "--static", "/files=" + tmp],
        stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        phase("waiting for the server")
        for _ in range(300):
            try:
                socket.create_connection((HOST, PORT), timeout=0.5).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("the server never accepted a connection")
        time.sleep(1.0)

        phase("the idle server's baseline")
        base = metered(srv.pid, WINDOW)
        if base > LIMIT:
            fail("the server used %.2f CPU seconds in %.1f with no connection "
                 "at all -- nothing below can be told apart from that" % (base, WINDOW))
        print("  idle: %.2f CPU seconds in %.1f" % (base, WINDOW))

        phase("a response in memory, its client half-closed")
        shape_memory(srv.pid)
        phase("a file response, the next request pipelined behind it")
        shape_file_pipelined(srv.pid)
        phase("a request on the executor, its client half-closed")
        shape_slow(srv.pid, pipelined=False)
        phase("a request on the executor, the next request pipelined behind it")
        shape_slow(srv.pid, pipelined=True)
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=10)
        except subprocess.TimeoutExpired:
            srv.kill()
        log.close()
        if failures:
            with open(log_path) as fh:
                tail = fh.readlines()[-20:]
            print("=== server.log (last 20 lines) ===")
            sys.stdout.write("".join(tail))
        shutil.rmtree(tmp, ignore_errors=True)

    subprocess.run([sys.executable, "scripts/emit.py", "loop_cpu_worst_shape",
                    "%d" % int(worst[0] * 1000), "--unit", "ms",
                    "--limit", "%d" % int(LIMIT * 1000),
                    "--task", "smoke-slot-lifecycle"])
    if failures:
        for f in failures:
            print("slot_lifecycle_probe: FAIL:", f)
        sys.exit(1)
    print("slot_lifecycle_probe: a connection that is not being read costs "
          "the loop nothing")


if __name__ == "__main__":
    main()
