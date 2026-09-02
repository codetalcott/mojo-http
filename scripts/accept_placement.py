#!/usr/bin/env python3
"""Which prefork worker wins the accept, and why: a placement experiment.

`M0_WORKERS` forks after `listen`, so both workers share ONE listen socket,
each registers it `EPOLLIN|EPOLLET` in its own epoll, and on a connection
both wake and the first to reach `accept()` drains the backlog until EAGAIN.
The 2026-08-29 CI sighting (docs/ROADMAP.md, "Scheduling stickiness") was
`smoke-reload`'s 10 x 8 sequential connections ALL answered by one of two
live workers. This script reproduces it deterministically, and it is CPU
placement that decides it, not load:

    # the real server: pin worker A to CPU 0, worker B to CPU 1, and run the
    # smoke's probe on CPU 1 -- the worker sharing the client's CPU loses
    # every accept (measured 80/80, 0 of 10 rounds with both pids)
    python3 scripts/accept_placement.py serve --cpus 0,1 --client-cpu 1
    python3 scripts/accept_placement.py serve --cpus 0,1 --client-cpu 2   # ~75/80

    # the accept path modelled in pure Python, so the alternatives can be
    # tried without touching the server: EPOLLEXCLUSIVE sends 80/80 to one
    # worker in EVERY placement; per-worker SO_REUSEPORT listeners balance
    python3 scripts/accept_placement.py model --mode shared
    python3 scripts/accept_placement.py model --mode exclusive
    python3 scripts/accept_placement.py model --mode reuseport

Linux only (epoll, sched_setaffinity, taskset). `serve` needs `m0serve` on
PATH or `--bin`. Measured 2026-09-02 in colima (4 vCPU, the 0.16.0 aarch64
wheel); the numbers are in the ROADMAP entry.
"""
import argparse
import http.client
import os
import select
import signal
import socket
import subprocess
import sys
import textwrap
import threading
import time

EPOLLEXCLUSIVE = 1 << 28
ROUNDS, PER = 10, 8

APP = textwrap.dedent('''\
    import os
    def application(environ, start_response):
        body = ("four pid=%d" % os.getpid()).encode()
        start_response("200 OK", [("Content-Type", "text/plain"),
                                  ("Content-Length", str(len(body)))])
        return [body]
''')


def probe(port, concurrent=False):
    """The smoke's phase-2 probe: ROUNDS x PER fresh connections, 0.5 s apart.

    Returns (counts by pid, rounds that saw two pids, first such round)."""
    counts, both, first = {}, 0, None

    def one(out):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        c.request("GET", "/")
        out.append(c.getresponse().read().decode().split("pid=")[1])
        c.close()

    for r in range(ROUNDS):
        time.sleep(0.5)
        seen = []
        if concurrent:
            ts = [threading.Thread(target=one, args=(seen,)) for _ in range(PER)]
            for t in ts:
                t.start()
            for t in ts:
                t.join()
        else:
            for _ in range(PER):
                one(seen)
                time.sleep(0.005)  # a curl start, roughly
        for p in seen:
            counts[p] = counts.get(p, 0) + 1
        if len(set(seen)) >= 2:
            both += 1
            first = first or r + 1
    return counts, both, first


def report(label, counts, both, first):
    split = sorted(counts.values(), reverse=True)
    print("%s: split=%s rounds-with-2-pids=%d/%d first=%s"
          % (label, split, both, ROUNDS, first))


# --- model -----------------------------------------------------------------

def model_worker(mode, port, lsock):
    if mode == "reuseport":
        lsock = socket.socket()
        lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        lsock.bind(("127.0.0.1", port))
        lsock.listen(128)
    lsock.setblocking(False)
    ep = select.epoll()
    flags = select.EPOLLIN | select.EPOLLET
    if mode == "exclusive":
        flags |= EPOLLEXCLUSIVE
    ep.register(lsock.fileno(), flags)
    body = str(os.getpid()).encode()
    resp = (b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\npid=%s"
            % (len(body) + 4, body))
    while True:
        ep.poll()
        while True:  # drain until EAGAIN, as the loop does
            try:
                c, _ = lsock.accept()
            except BlockingIOError:
                break
            c.settimeout(5)
            try:
                c.recv(4096)
                c.sendall(resp)
            except OSError:
                pass
            c.close()


def cmd_model(a):
    if a.pin >= 0:
        os.sched_setaffinity(0, {a.pin})
    lsock = None
    if a.mode != "reuseport":
        lsock = socket.socket()
        lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        lsock.bind(("127.0.0.1", a.port))
        lsock.listen(128)
    kids = []
    for _ in range(a.workers):
        pid = os.fork()
        if pid == 0:
            model_worker(a.mode, a.port, lsock)
        kids.append(pid)
    for _ in range(a.hogs):
        pid = os.fork()
        if pid == 0:
            while True:
                pass
        kids.append(pid)
    time.sleep(0.5)
    try:
        counts, both, first = probe(a.port, a.concurrent)
    finally:
        for k in kids:
            os.kill(k, signal.SIGKILL)
    report("model mode=%s pin=%d hogs=%d" % (a.mode, a.pin, a.hogs), counts, both, first)


# --- serve -----------------------------------------------------------------

def children_of(pid):
    kids = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d) as f:
                if f.read().rsplit(") ", 1)[1].split()[1] == str(pid):
                    kids.append(int(d))
        except OSError:
            pass
    return sorted(kids)


def wait_healthy(port):
    for _ in range(60):
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            c.request("GET", "/")
            c.getresponse().read()
            return
        except OSError:
            time.sleep(0.5)
    sys.exit("m0serve never became healthy on %d" % port)


def cmd_serve(a):
    appdir = "/tmp/accept_placement_app"
    os.makedirs(appdir, exist_ok=True)
    with open(os.path.join(appdir, "myapp.py"), "w") as f:
        f.write(APP)
    hogs = [subprocess.Popen(["taskset", "-c", str(a.hog_cpu), sys.executable,
                              "-c", "while True: pass"])
            for _ in range(a.hogs)]
    srv = subprocess.Popen([a.bin, "myapp:application", "--app-dir", appdir,
                            "--port", str(a.port), "--workers", "2"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_healthy(a.port)
        cpus = [int(c) for c in a.cpus.split(",")]
        for w, cpu in zip(children_of(srv.pid), cpus):
            subprocess.run(["taskset", "-pc", str(cpu), str(w)],
                           check=True, stdout=subprocess.DEVNULL)
        os.sched_setaffinity(0, {a.client_cpu})
        counts, both, first = probe(a.port, a.concurrent)
        report("m0serve workers on cpus %s, client on cpu %d, %d hogs on cpu %d%s"
               % (a.cpus, a.client_cpu, a.hogs, a.hog_cpu,
                  ", concurrent" if a.concurrent else ""), counts, both, first)
        if a.stop_winner:
            # The fairness-free assertion: stop whichever worker answers, and
            # the other one must answer everything, promptly.
            winner = int(max(counts, key=counts.get))
            os.kill(winner, signal.SIGSTOP)
            t0 = time.monotonic()
            counts2, _, _ = probe(a.port)
            os.kill(winner, signal.SIGCONT)
            report("with pid %d stopped (%.1fs)" % (winner, time.monotonic() - t0),
                   counts2, 0, None)
    finally:
        srv.send_signal(signal.SIGTERM)
        print("m0serve exit=%d" % srv.wait(timeout=30))
        for h in hogs:
            h.kill()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("model")
    m.add_argument("--mode", default="shared", choices=["shared", "exclusive", "reuseport"])
    m.add_argument("--workers", type=int, default=2)
    m.add_argument("--port", type=int, default=8101)
    m.add_argument("--pin", type=int, default=-1, help="sched_setaffinity everything to this CPU")
    m.add_argument("--hogs", type=int, default=0)
    m.add_argument("--concurrent", action="store_true")
    m.set_defaults(fn=cmd_model)
    s = sub.add_parser("serve")
    s.add_argument("--bin", default="m0serve")
    s.add_argument("--port", type=int, default=8400)
    s.add_argument("--cpus", default="0,1", help="worker A's CPU, worker B's CPU")
    s.add_argument("--client-cpu", type=int, default=1)
    s.add_argument("--hogs", type=int, default=0)
    s.add_argument("--hog-cpu", type=int, default=1)
    s.add_argument("--concurrent", action="store_true")
    s.add_argument("--stop-winner", action="store_true",
                   help="then SIGSTOP the winner and probe again")
    s.set_defaults(fn=cmd_serve)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
