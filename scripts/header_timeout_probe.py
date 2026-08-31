"""Prove the header read timeout still fires.

Opens a connection, sends nothing, and waits. The server must answer 408 and
close. This is the one path with no read event to hang the check on — a
client that connects and stays silent generates no traffic at all — so it is
the case a deadline sweep has to catch on its own.

Also asserts the opposite: a connection that sends a complete request is NOT
closed by the header deadline, which is what separates "the timeout works"
from "the server hangs up on everyone".
"""
import socket
import sys
import time
import traceback

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
# Default header_read_timeout is 10s; the sweep adds up to 1s of slack.
LIMIT = 14.0


# Which phase is running, for the crash handler below. This probe's two
# halves are opposites -- a silent connection MUST be closed, a keep-alive
# one MUST NOT be -- and both spend most of their time inside a bare `recv`.
# A traceback naming that recv says which CALL raised and never which PHASE
# was being proven, which is the distinction two investigations of the
# 2026-08-30 CI failure lost; apps/asgi_bare/ws_probe.py carries the
# original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("header_timeout_probe: FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def silent_connection_is_closed() -> None:
    s = socket.create_connection((HOST, PORT), timeout=LIMIT + 5)
    s.settimeout(LIMIT + 5)
    start = time.monotonic()
    try:
        data = s.recv(4096)
    except socket.timeout:
        raise SystemExit(
            f"FAIL: silent connection still open after {LIMIT + 5:.0f}s "
            "— the header timeout never fired"
        )
    finally:
        s.close()
    elapsed = time.monotonic() - start

    if elapsed > LIMIT:
        raise SystemExit(f"FAIL: header timeout took {elapsed:.1f}s (limit {LIMIT}s)")
    if data and b"408" not in data.split(b"\r\n", 1)[0]:
        raise SystemExit(f"FAIL: expected 408, got {data.split(b'~n')[0][:80]!r}")
    if not data:
        raise SystemExit("FAIL: connection closed with no 408 response")
    print(f"  silent connection answered 408 and closed after {elapsed:.1f}s")


def normal_request_is_not_closed() -> None:
    """A connection that completes its headers must survive the deadline."""
    s = socket.create_connection((HOST, PORT), timeout=10)
    s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
    first = s.recv(4096)
    if b"200" not in first.split(b"\r\n", 1)[0]:
        raise SystemExit(f"FAIL: expected 200, got {first[:80]!r}")
    # Hold the keep-alive connection past the header timeout, then reuse it.
    time.sleep(12)
    try:
        s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
        second = s.recv(4096)
    except OSError as exc:
        raise SystemExit(
            f"FAIL: keep-alive connection was closed by the header deadline ({exc}) "
            "— the deadline must only govern the first request"
        )
    if b"200" not in second.split(b"\r\n", 1)[0]:
        raise SystemExit(
            f"FAIL: keep-alive request after 12s idle got {second[:80]!r}; the header "
            "deadline must not apply once a request has completed"
        )
    s.close()
    print("  keep-alive connection survived 12s idle and served a second request")


if __name__ == "__main__":
    phase("a silent connection, which must be answered 408 and closed")
    silent_connection_is_closed()
    phase("a keep-alive connection, which the deadline must NOT close")
    normal_request_is_not_closed()
    print("header_timeout_probe OK")
