#!/usr/bin/env python3
"""A half-closed client must still get its response.

`shutdown(SHUT_WR)` after sending is how a client says "that is the whole
request" while still waiting to read the answer. The server sees EOF on the
read side with the response still owed, and the mistake it must not make is
treating that as the end of the connection: closing there discards a
response already written, which the client sees as an RST and a lost answer.

This is a socket-level property, so it lives in a probe rather than a unit
test. It is also PLATFORM-SENSITIVE, which is why it earns a smoke: kqueue
reports the half-close as `EV_EOF` on the read filter, and epoll matches it
because `add_read` registers `EPOLLRDHUP`. The bug this pins lost 24-30 of
every 30 requests on macOS and none on Linux — a CI that only ran Linux
would never have seen it.

What the probe pins is the BEHAVIOUR, not one mechanism: the guard is
layered, and a recv that returns 0 marks `peer_eof` even where the flag is
absent, so removing EPOLLRDHUP alone does not fail this probe — removing
both layers does (verified by sabotage). The flag's own value is parity
(the EV_EOF path runs on both platforms, so macOS-only code paths stop
existing) and seeing the half-close in the same event as the final data.

A half-closed client has also sent its LAST request, so the connection ends
behind its answer, which says `Connection: close` (review record LF11). The
EOF set the close and the request's own `Connection` replaced it: the answer
read `keep-alive`, and on epoll, whose edge for the FIN was spent, the slot
waited for a request no event would announce until the idle sweep (60 s in
`apps/hello`). That needs the FIN to land in the event that brings the
request, which a client cannot arrange, so the single request's prompt EOF
is a race this probe runs many times. The pipelined burst's last answer is
the deterministic half: the server takes the burst in several reads, and
the FIN is in before the last of them.

usage: half_close_probe.py PORT
"""
import socket
import sys
import time

from probelib import phase, stamp

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ROUNDS = 15

GET = b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
BODY = b"half-closed body"
CL = (b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n"
      b"Connection: close\r\n\r\n" % len(BODY)) + BODY
CHUNKED = (b"POST /health HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
           b"Connection: close\r\n\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(BODY), BODY))


# Which phase is running, for the crash handler. A traceback names the CALL
# that raised -- here `attempt`, which every shape below shares -- and never
# the PHASE being proven. The 2026-08-30 CI failure cost two investigations
# to exactly that distinction; apps/asgi_bare/ws_probe.py carries the
# original of this comment. The distinction matters most here: `attempt`
# runs half-closed AND as its own control, so "a reset in attempt" reads
# identically whether the fix regressed or the server is simply down.
stamp("half_close_probe: FAIL")


def attempt(payload, half):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    try:
        s.sendall(payload)
        if half:
            s.shutdown(socket.SHUT_WR)
        s.settimeout(10)
        got = b""
        while True:
            c = s.recv(65536)
            if not c:
                break
            got += c
        return "ok" if got.startswith(b"HTTP/1.1") else "no-response"
    except ConnectionResetError:
        return "RESET"
    except socket.timeout:
        return "timeout"
    finally:
        try:
            s.close()
        except OSError:
            pass


failures = []

for label, payload in (("GET", GET), ("Content-Length", CL), ("chunked", CHUNKED)):
    phase("a half-closed %s request" % label)
    bad = [attempt(payload, True) for _ in range(ROUNDS)]
    bad = [r for r in bad if r != "ok"]
    if bad:
        failures.append("%s + half-close: %d/%d did not answer (%s)"
                        % (label, len(bad), ROUNDS, ", ".join(sorted(set(bad)))))
    # The control: the same request without the half-close must be unaffected,
    # so a total failure of the server cannot look like a pass above.
    phase("the control: %s WITHOUT a half-close" % label)
    if attempt(payload, False) != "ok":
        failures.append("%s WITHOUT half-close did not answer — the server is "
                        "broken for ordinary requests, not just this case" % label)

# A request that is still INCOMPLETE when the peer half-closes can never be
# completed: the kernel has already said no more bytes are coming, so the
# connection must end PROMPTLY — on both backends, now that epoll registers
# EPOLLRDHUP. It used not to, which made this case diverge: Linux saw only
# an ordinary readable event, indistinguishable from a client gone quiet,
# and held the slot until the header timeout answered 408 — bounded, but
# ten seconds of a connection the kernel knew was dead. The bound here is
# deliberately far inside that timeout: ending AT the timeout is exactly
# the behaviour this pins out, and an earlier version of this probe had to
# tolerate it as a platform difference.
TRUNCATED_DEADLINE = 5
phase("a truncated request followed by a half-close")
s = socket.create_connection(("127.0.0.1", PORT), timeout=TRUNCATED_DEADLINE)
try:
    s.sendall(b"GET /health HTT")           # truncated request line
    s.shutdown(socket.SHUT_WR)
    s.settimeout(TRUNCATED_DEADLINE)
    got = b""
    while True:
        c = s.recv(65536)
        if not c:
            break
        got += c
    if got.startswith(b"HTTP/1.1 2"):
        failures.append("a truncated request was answered 2xx")
except ConnectionResetError:
    pass                                     # an abrupt close is acceptable here
except socket.timeout:
    failures.append("a truncated request + half-close was still open after %ds "
                    "— the half-close went unseen, so the slot is being held "
                    "for a request that can never complete"
                    % TRUNCATED_DEADLINE)
finally:
    s.close()

# A half-closed request that does NOT ask for a close: answered, and the
# connection ends promptly behind it (LF11). The deadline is far inside the
# server's idle timeout, which is what used to end it on Linux.
KEEPALIVE = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
EOF_DEADLINE = 5


def read_to_eof(payload):
    """`payload`, a half-close, then everything until the server's EOF:
    (bytes, True), or (bytes, False) once EOF_DEADLINE has passed."""
    s = socket.create_connection(("127.0.0.1", PORT), timeout=EOF_DEADLINE)
    try:
        s.sendall(payload)
        s.shutdown(socket.SHUT_WR)
        got = b""
        deadline = time.monotonic() + EOF_DEADLINE
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return got, False
            s.settimeout(left)
            try:
                c = s.recv(65536)
            except socket.timeout:
                return got, False
            if not c:
                return got, True
            got += c
    finally:
        s.close()


phase("a half-closed keep-alive request")
held = 0
for _ in range(ROUNDS):
    got, eof = read_to_eof(KEEPALIVE)
    if not got.startswith(b"HTTP/1.1 200"):
        failures.append("a half-closed keep-alive request was not answered: %r"
                        % got[:80])
        break
    held += not eof
if held:
    failures.append("%d/%d half-closed keep-alive requests left their connection "
                    "open %ds after the answer, held for a request the client "
                    "can no longer send" % (held, ROUNDS, EOF_DEADLINE))

phase("a half-closed pipelined burst")
BURST = 200
got, eof = read_to_eof(KEEPALIVE * BURST)
answers = got.split(b"HTTP/1.1 200")[1:]
if len(answers) != BURST:
    failures.append("a half-closed burst of %d pipelined requests got %d answers"
                    % (BURST, len(answers)))
elif b"\r\nconnection: close\r\n" not in answers[-1].lower():
    failures.append("the last request of a half-closed burst was answered "
                    "without Connection: close: %r" % answers[-1][:200])
if not eof:
    failures.append("a half-closed burst left its connection open %ds after its "
                    "last answer" % EOF_DEADLINE)

if failures:
    for f in failures:
        print("half_close_probe: FAIL:", f)
    sys.exit(1)

print("half_close_probe: a half-closed client is answered on every request shape")
