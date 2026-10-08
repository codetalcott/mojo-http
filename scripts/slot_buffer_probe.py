#!/usr/bin/env python3
"""A connection that closes hands the buffers a large request grew back to
the allocator, for connections on any slot to reuse (SPEC C17).

A slot's receive buffer grows to the largest request it has held, and a
slot is never rebuilt: closing a connection used to CLEAR the buffer, which
keeps its capacity, so every slot that ever took a large upload kept that
memory, of no use to any other slot (review record LF25). 64 concurrent
4 MiB uploads left apps/hello at 431-448 MB resident, against 14 MB after
64 small requests, and each further 64 uploads on other slots added another
386-400 MB.

The memory after one burst cannot be the gate. The allocator keeps what is
freed for reuse rather than handing it back to the system -- with the fix,
283-309 MB stayed resident after the same burst -- so the probe asks the
question that tells the two apart: can connections on OTHER slots reuse
what the first ones grew?

  1. 64 keep-alive connections each upload 4 MiB and stay open. The
     server's footprint must rise by at least `GREW`: the control that the
     buffers really grew, so a server that refused the bodies cannot pass
     with nothing to keep. What it rose by is what one round of uploads
     costs this server, on this allocator.
  2. They close, and the server closes their slots.
  3. `ROUNDS` times: 64 idle connections take every slot used so far (the
     pool hands out the lowest free slot), each after one small keep-alive
     request, so the idle timeout holds them rather than the header
     timeout; and 64 more 4 MiB uploads land on slots never used, then
     close.
  4. The footprint above the start may never exceed `LIMIT` times what the
     first round cost.

usage: slot_buffer_probe.py SERVER_BINARY PORT [LOG]
  starts SERVER_BINARY (apps/hello) itself, since it reads that process's
  footprint; see `poe smoke-slot-buffers`
"""

import ctypes
import ctypes.util
import os
import resource
import socket
import sys
import threading
import time

from probelib import fail, phase, server, stamp

stamp("slot_buffer_probe: FAIL")

BIN = sys.argv[1]
PORT = int(sys.argv[2])
LOG = sys.argv[3] if len(sys.argv) > 3 else None
HOST = "127.0.0.1"

CONNS = 64
BODY = 4 * 1024 * 1024  # the default body cap, which the server accepts
ROUNDS = 3
# The first round's buffers must show: 64 x 4 MiB held is 256 MiB of
# receive buffers alone, measured at 380-450 MB in all; half of the buffers
# is a control no real growth misses.
GREW = 128 * 1024
# Measured on macOS, in the footprint, as multiples of one round's cost:
# 1.12-1.40 with the buffers handed back (1.40 is where an eight-round run
# levelled off), 3.62-3.88 after three rounds with them kept. 2.5 leaves
# either side room for an allocator that behaves otherwise.
LIMIT = 2.5
# Time for the loop to close the slots whose clients closed, and to settle.
SETTLE = 1.5


class _RusageInfoV0(ctypes.Structure):
    """`struct rusage_info_v0` from <sys/resource.h>, for proc_pid_rusage."""
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
        "wired_size", "resident_size", "phys_footprint", "proc_start_abstime",
        "proc_exit_abstime")]


def footprint_kb(pid):
    """What the server holds in memory, in KB, counting pages the system
    compressed or swapped out: those leave RSS without being given back, and
    a busy machine does it in the middle of a run (plain RSS read 2.36 on the
    unfixed server once, against 3.62-3.88 here). macOS reports it as the
    physical footprint, to the byte through `proc_pid_rusage` (vmmap prints
    it rounded to a tenth of a gigabyte past one), Linux as VmRSS plus
    VmSwap."""
    if sys.platform == "darwin":
        libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib",
                              use_errno=True)
        info = _RusageInfoV0()
        if libproc.proc_pid_rusage(pid, 0, ctypes.byref(info)) != 0:  # RUSAGE_INFO_V0
            raise OSError(ctypes.get_errno(), "proc_pid_rusage(%d)" % pid)
        return info.phys_footprint // 1024
    with open("/proc/%d/status" % pid) as fh:
        fields = dict(line.split(":", 1) for line in fh if ":" in line)
    return sum(int(fields[k].split()[0]) for k in ("VmRSS", "VmSwap") if k in fields)


def read_response(sock):
    """The status line of one response, read whole by its Content-Length."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("closed before the response head: %r" % buf[:200])
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    length = 0
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    while len(rest) < length:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("closed inside the response body")
        rest += chunk
    return head.split(b"\r\n", 1)[0].decode("latin-1")


def upload_round(socks):
    """One 4 MiB POST on each socket, all at once, each answered 200."""
    request = (("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Type: application/octet-stream\r\n"
                "Content-Length: %d\r\n\r\n" % BODY).encode() + b"x" * BODY)
    statuses = [None] * len(socks)
    errors = []
    go = threading.Barrier(len(socks))

    def one(i):
        try:
            go.wait()
            socks[i].sendall(request)
            statuses[i] = read_response(socks[i])
        except Exception as e:  # reported below, under the phase that ran it
            errors.append(repr(e))

    threads = [threading.Thread(target=one, args=(i,)) for i in range(len(socks))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        fail("%d of %d uploads failed: %s" % (len(errors), len(socks), errors[0]))
    refused = [s for s in statuses if " 200 " not in (s or "") + " "]
    if refused:
        fail("%d of %d uploads were not answered 200: %r" % (len(refused), len(socks), refused[0]))


def connect_all():
    return [socket.create_connection((HOST, PORT), timeout=60) for _ in range(CONNS)]


def hold_all():
    """64 connections that each complete one small keep-alive request and
    then sit idle. A connection that sent nothing would be closed by the
    header timeout (10 s) and give its slot back mid-run, which a slow
    runner reaches; after a request it waits out the idle timeout (60 s)."""
    socks = connect_all()
    for s in socks:
        s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
        status = read_response(s)
        if " 200 " not in status + " ":
            fail("an idle connection's request was answered %r" % status)
    return socks


def close_all(socks):
    for s in socks:
        s.close()


def main():
    # 64 x (ROUNDS + 1) sockets at the end, on both sides: past macOS's
    # default soft limit of 256. The server inherits the raised one.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = 4096 if hard == resource.RLIM_INFINITY else min(4096, hard)
    if soft != resource.RLIM_INFINITY and soft < want:
        resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))

    env = dict(os.environ, M0_PORT=str(PORT), M0_HOST=HOST)
    phase("the server starting")
    with server([BIN], "http://%s:%d/health" % (HOST, PORT), log=LOG, env=env) as proc:
        time.sleep(0.5)
        start = footprint_kb(proc.pid)

        phase("the first round, held open")
        first = connect_all()
        upload_round(first)
        held = footprint_kb(proc.pid)
        one_round = held - start
        if one_round < GREW:
            fail("64 held 4 MiB uploads grew the footprint by %d KB, under the %d KB control: the "
                 "buffers this probe is about never grew" % (one_round, GREW))

        phase("the first round's connections closing")
        close_all(first)
        time.sleep(SETTLE)
        after = [footprint_kb(proc.pid)]

        holders = []
        for r in range(ROUNDS):
            phase("idle connections taking every slot used before round %d" % (r + 2))
            holders += hold_all()
            phase("round %d, on slots never used" % (r + 2))
            fresh = connect_all()
            upload_round(fresh)
            close_all(fresh)
            time.sleep(SETTLE)
            after.append(footprint_kb(proc.pid))
        close_all(holders)

    worst = max(after) - start
    print("slot buffers: footprint %d KB at start; one round of 64 held 4 MiB uploads cost "
          "%d KB; after it and %d more on fresh slots: %s KB"
          % (start, one_round, ROUNDS, ", ".join(str(a) for a in after)))
    print("footprint_rounds_ratio %.2f" % (worst / one_round))
    if worst > LIMIT * one_round:
        fail("uploads on fresh slots took the footprint %d KB above the start, %.1f times "
             "what one round cost (limit %.1f): the slots that closed kept their buffers"
             % (worst, worst / one_round, LIMIT))
    print("slot_buffer_probe: OK")


main()
