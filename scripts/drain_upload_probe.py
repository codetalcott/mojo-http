#!/usr/bin/env python3
"""Prove a request whose BODY is still arriving at SIGTERM is finished by the
drain, not left to the deadline.

    python3 scripts/drain_upload_probe.py --port 8450 --pid PID

`scripts/drain_inflight_probe.py` pins the response side: a request already
running at SIGTERM is answered, and its keep-alive connection does not then
hold the drain to its deadline. This is the request side, found by the soak
driver's uploads population on color-separation (2026-09-02): with 9.7 MB
uploads in flight every SIGTERM drain took exactly its 5 s budget, and the
bisection put it on uploads alone. Measured directly: a 10 MB POST with 5 MB
delivered when SIGTERM lands, the rest sent 1 s later — the server never
reads it, the client is reset at 5.03 s, and the process exits at 5.09 s.
Half of `docker stop`'s patience for nothing, on a request that would have
completed in milliseconds. gunicorn's graceful timeout keeps reading.

The assertion is two-sided, like its sibling: the request must be ANSWERED
(the echo comes back whole), and the process must exit well inside the
drain budget once it has been.
"""

import argparse
import os
import signal
import socket
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--path", default="/echo")
    ap.add_argument("--size", type=int, default=10 * 1024 * 1024)
    ap.add_argument("--budget", type=float, default=3.0,
                    help="seconds after SIGTERM by which the answered "
                         "process must have exited (the drain budget is 5)")
    args = ap.parse_args()

    half = args.size // 2
    sock = socket.create_connection((args.host, args.port))
    sock.settimeout(20)
    sock.sendall(("POST %s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\n"
                  "Content-Type: application/octet-stream\r\n\r\n"
                  % (args.path, args.host, args.size)).encode())
    sock.sendall(b"a" * half)
    time.sleep(0.5)
    t0 = time.time()
    os.kill(args.pid, signal.SIGTERM)
    time.sleep(1.0)
    answered = False
    try:
        sock.sendall(b"b" * (args.size - half))
        head = sock.recv(4096)
        got = len(head)
        body_start = head.find(b"\r\n\r\n")
        while True:
            try:
                chunk = sock.recv(1 << 20)
            except socket.timeout:
                break
            if not chunk:
                break
            got += len(chunk)
        answered = head.startswith(b"HTTP/1.1 200") and \
            got - (body_start + 4) >= args.size
        print("drain-upload: %s (%d bytes back, %.2fs after SIGTERM)"
              % ("answered" if answered else "NOT answered", got,
                 time.time() - t0))
    except OSError as exc:
        print("drain-upload: NOT answered: %r at %.2fs after SIGTERM"
              % (exc, time.time() - t0))
    while True:
        try:
            os.kill(args.pid, 0)
            time.sleep(0.02)
        except ProcessLookupError:
            break
        if time.time() - t0 > 30:
            print("drain-upload FAIL: still alive 30 s after SIGTERM")
            return 1
    exited = time.time() - t0
    print("drain-upload: process exited %.2fs after SIGTERM" % exited)
    if not answered:
        print("drain-upload FAIL: the body that arrived during the drain was "
              "never read; the request was reset instead of answered")
        return 1
    if exited > args.budget:
        print("drain-upload FAIL: answered, but the drain still ran %.2fs "
              "(budget %.1fs)" % (exited, args.budget))
        return 1
    print("drain-upload ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
