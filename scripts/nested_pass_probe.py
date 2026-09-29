#!/usr/bin/env python3
"""An event in the same batch as an eager stream is not lost (SPEC L31).

    python3 scripts/nested_pass_probe.py --port 8088 [--case accept|read]

Against apps/asgi_bare served under the loop inversion (`M0_INVERTED=1`),
with its eager task factory installed (`M0_ASGI_EAGER_TASKS=1`), so a
request's first step runs INSIDE the pass that read it.

Each case puts two events in one batch, a stream's request first:

- `/block?ms=N` holds the serving thread (a synchronous sleep in its first
  step), so what arrives meanwhile is read by the next pass together;
- meanwhile a keep-alive connection sends `/stream?size=N&piece=1`, whose
  first step sends N one-byte frames with no await -- many times what the
  executor's chunk channel holds, since the kernel charges each datagram's
  overhead as well as its byte;
- then the case's own event: a NEW connection (the accept case), or the
  next request on another keep-alive connection (the read case).

After the block, one pass reads both, the stream's request first. The
executor used to place a frame the full channel refused by running a pass
of its own -- INSIDE that pass -- and the wait in it overwrote the event
buffer the outer pass was still walking. The second event was never acted
on: the new connection was not accepted until another one arrived (both
platforms), and on epoll, which reports a keep-alive request once, the
request was never read at all. kqueue reports a readable socket again, so
the read case can fail on Linux only; the accept case fails on both.

Each case checks its own premise -- the case's event was sent while the
blocker still held the thread -- and a round that missed it on a slow
runner is run again, so the probe cannot pass without having built the
batch it is about.

Stdlib only; exits 0 when every case holds.
"""

import argparse
import socket
import time

from probelib import fail, phase, stamp

stamp("nested_pass_probe FAIL", fail="nested_pass_probe FAIL: {phase}: {msg}")

PORT = 8088
BLOCK_MS = 800
# When the stream's request and the case's event are sent, after the blocker.
STREAM_AT = 0.2
EVENT_AT = 0.3
# The case's event must have gone out this long before the block could end.
MARGIN = 0.25
BURST = 32768
ROUNDS = 3
HELLO = b"hello from asgi_bare"


def request(path):
    return ("GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n" % path).encode()


def _fill(sock, deadline):
    """More bytes, or None at the deadline; b"" at EOF."""
    left = deadline - time.monotonic()
    if left <= 0:
        return None
    sock.settimeout(left)
    try:
        return sock.recv(65536)
    except socket.timeout:
        return None


def read_response(sock, deadline):
    """(status, body) of one HTTP/1.1 response, or None at the deadline.

    A body is framed by Content-Length or chunked coding; an EOF before it
    ends is returned as status "EOF" with what arrived."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        more = _fill(sock, deadline)
        if more is None:
            return None
        if not more:
            return ("EOF", buf)
        buf += more
    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        headers[name.strip().lower()] = value.strip()
    if b"content-length" in headers:
        n = int(headers[b"content-length"])
        while len(rest) < n:
            more = _fill(sock, deadline)
            if more is None:
                return None
            if not more:
                return ("EOF", rest)
            rest += more
        return (status, rest[:n])
    if headers.get(b"transfer-encoding", b"").lower() != b"chunked":
        return (status, rest)
    body = b""
    while True:
        while b"\r\n" not in rest:
            more = _fill(sock, deadline)
            if more is None:
                return None
            if not more:
                return ("EOF", body)
            rest += more
        line, rest = rest.split(b"\r\n", 1)
        size = int(line.split(b";")[0], 16)
        while len(rest) < size + 2:
            more = _fill(sock, deadline)
            if more is None:
                return None
            if not more:
                return ("EOF", body)
            rest += more
        if size == 0:
            return (status, body)
        body += rest[:size]
        rest = rest[size + 2:]


def connect():
    return socket.create_connection(("127.0.0.1", PORT), timeout=10)


def answered_once(sock):
    """Make `sock` a connection the loop already holds: one request answered."""
    sock.sendall(request("/"))
    got = read_response(sock, time.monotonic() + 10)
    if got != (200, HELLO):
        fail("a warm-up request was answered %r" % (got,))


def one_round(case):
    """Build the batch once. Returns whether the premise held; fails on a
    wrong answer whether it held or not (a correct server answers every
    request, however the batch fell)."""
    blocker, streamer, other = connect(), connect(), connect()
    newcomer = None
    try:
        for sock in (blocker, streamer, other):
            answered_once(sock)
        t0 = time.monotonic()
        blocker.sendall(request("/block?ms=%d" % BLOCK_MS))
        time.sleep(STREAM_AT)
        streamer.sendall(request("/stream?size=%d&piece=1" % BURST))
        time.sleep(EVENT_AT - STREAM_AT)
        if case == "accept":
            # connect() completes in the listener's backlog: the event is the
            # listener's, and the request is already there when it is taken.
            newcomer = connect()
            newcomer.sendall(request("/"))
            victim = newcomer
        else:
            other.sendall(request("/"))
            victim = other
        sent_at = time.monotonic() - t0
        premise = sent_at < BLOCK_MS / 1000.0 - MARGIN

        got = read_response(blocker, time.monotonic() + BLOCK_MS / 1000.0 + 10)
        if got != (200, b"blocked %d" % BLOCK_MS):
            fail("the blocker was answered %r" % (got,))
        got = read_response(streamer, time.monotonic() + 10)
        if got is None or got[0] != 200 or got[1] != b"\x00" * BURST:
            fail("the stream begun inside the pass was answered %s, want %d zero bytes"
                 % ("nothing" if got is None else "%r with %d bytes" % (got[0], len(got[1])), BURST))
        got = read_response(victim, time.monotonic() + 5)
        if got != (200, HELLO):
            what = "never answered" if got is None else "answered %r" % (got,)
            if got is None and case == "accept":
                # Taken once another connection arrives: the listener's edge
                # was spent by the wait whose event was lost.
                rescue = connect()
                try:
                    rescue.sendall(request("/"))
                    read_response(rescue, time.monotonic() + 3)
                    late = read_response(victim, time.monotonic() + 3)
                finally:
                    rescue.close()
                if late == (200, HELLO):
                    what += ", then answered once another connection arrived"
            fail("the %s in the stream's batch was %s: a pass ran inside the "
                 "pass that read it and overwrote its events"
                 % ("new connection" if case == "accept" else "keep-alive request", what))
        return premise
    finally:
        for sock in (blocker, streamer, other, newcomer):
            if sock is not None:
                sock.close()


def main():
    global PORT
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--case", choices=("accept", "read", "both"), default="both")
    args = parser.parse_args()
    PORT = args.port
    cases = ("accept", "read") if args.case == "both" else (args.case,)

    phase("the server installs the eager task factory")
    probe = connect()
    try:
        probe.sendall(request("/task-factory"))
        got = read_response(probe, time.monotonic() + 10)
    finally:
        probe.close()
    if got != (200, b"eager"):
        fail("/task-factory answered %r: without the eager factory no request "
             "runs inside a pass, and this probe proves nothing" % (got,))

    for case in cases:
        phase("the %s case" % case)
        for n in range(1, ROUNDS + 1):
            if one_round(case):
                print("nested_pass_probe: %s case OK (round %d)" % (case, n))
                break
            print("nested_pass_probe: %s case round %d sent its event too late "
                  "to share the batch; again" % (case, n))
        else:
            fail("in %d rounds the event was never sent while the blocker "
                 "held the thread" % ROUNDS)
    print("nested_pass_probe OK")


if __name__ == "__main__":
    main()
