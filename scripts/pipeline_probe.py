#!/usr/bin/env python3
"""Pipelined requests must ALL be answered, in order.

RFC 9112 §9.3: a server MUST be able to receive pipelined requests. The
bytes of request N+1 arrive in the same read that completes request N, so
they get no readiness event of their own — a server that waits for one
answers the first request and leaves the client hanging forever on the
rest. That was this server, on both backends, in every release up to and
including v0.12.0.

Shapes covered: bursts of bodyless requests in one write; a request
pipelined behind a Content-Length body; behind a chunked body (whose
decoder must PRESERVE the bytes after the terminator, not discard them);
a second request sent while the first response is in flight; and a
pipelined burst followed by half-close (the tail must still be answered,
then the connection closed).

usage: pipeline_probe.py PORT
"""
import socket
import sys
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ROUNDS = 10

GET = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
BODY = b"pipelined body bytes"
CL = (b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
      % len(BODY)) + BODY
CHUNKED = (b"POST /health HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
           b"\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(BODY), BODY))


# Which phase is running, for the crash handler below. A traceback names the
# CALL that raised -- here `count_responses`, which every `check` below shares
# -- and never the PHASE being proven. The 2026-08-30 CI failure cost two
# investigations to exactly that distinction; apps/asgi_bare/ws_probe.py
# carries the original of this comment. Eight shapes share one helper here,
# so an unhandled reset in it names none of them without this.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("pipeline_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def count_responses(payload, want, half_close=False, timeout=6.0):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    try:
        s.sendall(payload)
        if half_close:
            s.shutdown(socket.SHUT_WR)
        s.settimeout(timeout)
        buf = b""
        while buf.count(b"HTTP/1.1 ") < want:
            try:
                c = s.recv(65536)
            except socket.timeout:
                break
            except ConnectionResetError:
                return -1, buf
            if not c:
                break
            buf += c
        return buf.count(b"HTTP/1.1 "), buf
    finally:
        try:
            s.close()
        except OSError:
            pass


failures = []


def check(label, payload, want, half_close=False):
    phase(label)
    seen = {}
    for _ in range(ROUNDS):
        n, buf = count_responses(payload, want, half_close)
        seen[n] = seen.get(n, 0) + 1
    bad = {k: v for k, v in seen.items() if k != want}
    if bad:
        failures.append("%s: wanted %d responses, saw %s over %d rounds"
                        % (label, want, dict(sorted(seen.items())), ROUNDS))


check("2 GETs in one write", GET * 2, 2)
check("8 GETs in one write", GET * 8, 8)
check("GET behind Content-Length POST", CL + GET, 2)
check("GET behind chunked POST", CHUNKED + GET, 2)
check("chunked POST behind GET behind chunked POST", CHUNKED + GET + CHUNKED, 3)
check("pipelined burst then half-close", GET * 4, 4, half_close=True)

# A second request sent only after the first is in flight — no pipelining
# in the same packet, but the bytes can arrive while the loop is still
# sending response 1, which consumes their edge on an edge-triggered
# backend. The re-arm after the response is what answers it.
import time  # noqa: E402
phase("a second request sent while the first response is in flight")
for _ in range(ROUNDS):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=6.0)
    try:
        s.sendall(GET)
        time.sleep(0.002)
        s.sendall(GET)
        s.settimeout(6.0)
        buf = b""
        while buf.count(b"HTTP/1.1 ") < 2:
            try:
                c = s.recv(65536)
            except (socket.timeout, ConnectionResetError):
                break
            if not c:
                break
            buf += c
        if buf.count(b"HTTP/1.1 ") != 2:
            failures.append("second request during response: %d/2 answered"
                            % buf.count(b"HTTP/1.1 "))
            break
    finally:
        s.close()

# Ordering: pipelined responses must come back in request order. The hello
# app answers every path 200 and only the bodies differ, so order is read
# from the bodies: /health carries "status":"ok", everything else carries
# "hello from m0".
phase("pipelined responses coming back in request order")
REQ_A = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
REQ_B = b"GET /other HTTP/1.1\r\nHost: x\r\n\r\n"
n, buf = count_responses(REQ_A + REQ_B, 2)
if n == 2:
    a = buf.find(b'"status":"ok"')
    b_ = buf.find(b"hello from m0")
    if a < 0 or b_ < 0 or not a < b_:
        failures.append("responses out of order: /health body at %d, "
                        "/other body at %d" % (a, b_))
else:
    failures.append("ordering check: %d/2 answered" % n)

if failures:
    for f in failures:
        print("pipeline_probe: FAIL:", f)
    sys.exit(1)

print("pipeline_probe: every pipelined request is answered, in order")
