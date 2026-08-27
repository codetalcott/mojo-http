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

usage: half_close_probe.py PORT
"""
import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ROUNDS = 15

GET = b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
BODY = b"half-closed body"
CL = (b"POST /health HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n"
      b"Connection: close\r\n\r\n" % len(BODY)) + BODY
CHUNKED = (b"POST /health HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
           b"Connection: close\r\n\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(BODY), BODY))


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
    bad = [attempt(payload, True) for _ in range(ROUNDS)]
    bad = [r for r in bad if r != "ok"]
    if bad:
        failures.append("%s + half-close: %d/%d did not answer (%s)"
                        % (label, len(bad), ROUNDS, ", ".join(sorted(set(bad)))))
    # The control: the same request without the half-close must be unaffected,
    # so a total failure of the server cannot look like a pass above.
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

if failures:
    for f in failures:
        print("half_close_probe: FAIL:", f)
    sys.exit(1)

print("half_close_probe: a half-closed client is answered on every request shape")
