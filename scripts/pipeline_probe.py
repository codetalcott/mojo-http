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

And the two shapes where the parser and the loop disagreed about where a
head ends (SPEC B12): a bare-LF empty line with a request behind it, which
was answered once for two requests, and a bare LF with a `Content-Length`
behind it, whose body was answered as a request. Each must be refused: one
400, then the connection closed. Two requests that must close the
connection behind their answer, and did not, do the same with a 200: an
HTTP/1.0 request with a chunked body (SPEC B15), `Connection: close`
listed with another option (SPEC B17), and `Connection: close` on the first
of two `Connection` lines (SPEC B22). A head of bare LFs, which no CRLFCRLF
ever frames, is refused with 400 at once, not at the header timeout (SPEC
B23). A request for what this server does not implement is refused with
501, then the connection closed: CONNECT (SPEC B18), and a chunked body in
another transfer coding as well (SPEC B21).

usage: pipeline_probe.py PORT
"""
import re
import socket
import sys

from probelib import phase, stamp

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ROUNDS = 10

GET = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
BODY = b"pipelined body bytes"
CL = (b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
      % len(BODY)) + BODY
CHUNKED = (b"POST /health HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
           b"\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(BODY), BODY))


# Which phase is running, for the crash handler. A traceback names the CALL
# that raised -- here `count_responses`, which every `check` below shares --
# and never the PHASE being proven. The 2026-08-30 CI failure cost two
# investigations to exactly that distinction; apps/asgi_bare/ws_probe.py
# carries the original of this comment. Eight shapes share one helper here,
# so an unhandled reset in it names none of them without this.
stamp("pipeline_probe: FAIL")


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


def read_to_close(payload, timeout=4.0):
    """Send `payload`, read until the server closes; (bytes, closed)."""
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    try:
        s.sendall(payload)
        s.settimeout(timeout)
        buf = b""
        while True:
            try:
                c = s.recv(65536)
            except socket.timeout:
                return buf, False
            except ConnectionResetError:
                return buf, True
            if not c:
                return buf, True
            buf += c
    finally:
        try:
            s.close()
        except OSError:
            pass


def check_closed_after(label, payload, want):
    """Exactly the statuses `want`, then the connection closed: whatever
    was pipelined behind them is never answered."""
    phase(label)
    buf, closed = read_to_close(payload)
    # By pattern, not by line: a pipelined status line follows the body
    # before it with no CRLF between.
    statuses = [int(x) for x in re.findall(rb"HTTP/1\.1 (\d{3})", buf)]
    if statuses != want or not closed:
        failures.append("%s: wanted %s and a close, saw statuses %s, "
                        "closed=%s" % (label, want, statuses, closed))


# SPEC B12. The loop frames a head by its first CRLFCRLF; a parser that
# also ended one at a bare LF stopped short of it, and what lay between
# was lost. Measured on apps/hello before the fix: the first shape got ONE
# 200 for two requests, the second TWO 200s (its body served as a request).
check_closed_after(
    "a bare-LF empty line with a request pipelined behind it",
    b"GET /health HTTP/1.1\r\nHost: x\r\n\n" + GET, [400])
check_closed_after(
    "a bare LF with a Content-Length behind it covering a request",
    b"POST /health HTTP/1.1\r\nHost: x\r\n\nContent-Length: %d\r\n\r\n"
    % len(GET) + GET, [400])

# SPEC B15. RFC 9112 §6.1: an HTTP/1.0 message carrying Transfer-Encoding
# has faulty framing, and the connection closes after it, whatever its
# Connection says. Served here and kept alive, so the request behind it
# was answered too (one more 200).
check_closed_after(
    "an HTTP/1.0 chunked body asking for keep-alive, a request behind it",
    b"POST /health HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n"
    b"Transfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n0\r\n\r\n"
    % (len(BODY), BODY) + GET, [200])

# SPEC B17. Connection is a list of tokens (RFC 9110 §7.6.1): `close`
# among others still closes. The whole value was compared, so the
# request behind `close, TE` was answered too.
check_closed_after(
    "Connection: close among other options, a request behind it",
    b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close, TE\r\n"
    b"TE: trailers\r\n\r\n" + GET, [200])

# SPEC B22. Two Connection lines are one list (RFC 9110 §5.3). The
# store kept the last line, so `close` on the first was lost and the
# request behind it answered too.
check_closed_after(
    "Connection: close on the first of two Connection lines, a request behind",
    b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
    b"Connection: keep-alive\r\n\r\n" + GET, [200])

# SPEC B23. A head of bare LFs holds no CRLFCRLF to frame it, so it was
# never parsed: no answer until the header timeout. No half-close here,
# so the 400 and the close must come from the bytes alone, inside
# `read_to_close`'s four seconds.
check_closed_after(
    "a head of bare LFs, never half-closed",
    b"GET /health HTTP/1.1\nHost: x\n\n", [400])

# SPEC B18. CONNECT asks for a tunnel, which this server does not
# implement: 501 and a close. It reached the application, which answered
# it 200 -- an open tunnel, to a front end forwarding it -- and kept the
# connection, answering the request behind it too.
check_closed_after(
    "CONNECT, a request behind it",
    b"CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\n\r\n" + GET, [501])

# SPEC B21. A coding the loop cannot decode: 501 and a close. `gzip,
# chunked` was de-chunked and served still gzipped, and the connection
# kept, so the request behind it was answered too.
check_closed_after(
    "a gzip, chunked body, a request behind it",
    b"POST /health HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n"
    b"\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(BODY), BODY) + GET, [501])

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
