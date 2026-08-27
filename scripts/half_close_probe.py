#!/usr/bin/env python3
"""A half-closed client must still get its response.

`shutdown(SHUT_WR)` after sending is how a client says "that is the whole
request" while still waiting to read the answer. The server sees EOF on the
read side with the response still owed, and the mistake it must not make is
treating that as the end of the connection: closing there discards a
response already written, which the client sees as an RST and a lost answer.

This is a socket-level property, so it lives in a probe rather than a unit
test. It is also PLATFORM-SENSITIVE, which is why it earns a smoke: kqueue
reports the half-close as `EV_EOF` on the read filter, while the epoll
backend never registers `EPOLLRDHUP` and so sees an ordinary readable event.
The bug this pins lost 24-30 of every 30 requests on macOS and none on
Linux — a CI that only ran Linux would never have seen it.

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
# completed, so the connection must end — but HOW it ends is platform
# dependent, and asserting the faster answer here would be asserting a macOS
# detail as though it were the contract.
#
# kqueue reports the half-close as EV_EOF, so the loop knows at once that no
# more bytes can arrive and releases the slot immediately. The epoll backend
# does not register EPOLLRDHUP, so on Linux this is an ordinary readable
# event and the request simply stops arriving — indistinguishable from a
# client that went quiet, which the header timeout answers with 408. Both
# are correct. What must NOT happen is the connection outliving that
# timeout, or the truncated request being answered as though complete.
#
# So the wait is the header timeout plus slack, not a snap judgement. An
# earlier version of this probe waited 10s and failed on Linux for doing
# exactly what Linux is supposed to do.
HEADER_TIMEOUT_SLACK = 20
s = socket.create_connection(("127.0.0.1", PORT), timeout=HEADER_TIMEOUT_SLACK)
try:
    s.sendall(b"GET /health HTT")           # truncated request line
    s.shutdown(socket.SHUT_WR)
    s.settimeout(HEADER_TIMEOUT_SLACK)
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
                    "— past the header timeout, so nothing is going to end it"
                    % HEADER_TIMEOUT_SLACK)
finally:
    s.close()

if failures:
    for f in failures:
        print("half_close_probe: FAIL:", f)
    sys.exit(1)

print("half_close_probe: a half-closed client is answered on every request shape")
