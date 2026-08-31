"""Prove a request in flight at SIGTERM is answered AND its keep-alive
connection does not then hold the drain to its deadline.

`scripts/drain_idle_probe.py` pins the connections that were already idle
when the signal landed. This is the other shape: a request still running
when SIGTERM arrives — on a pool thread, so the loop is free to see the
signal — whose response completes DURING the drain. That response goes out
in one `send`, so no write interest is ever registered and the drain's
EVFILT_WRITE dispatch never sees it; it took `_finish_response`'s keep-alive
branch and re-armed the slot for a next request the drain never reads.
Measured with a 1.5 s request: the response arrived at 1.5 s either way,
but the process exited at 1.55 s with `Connection: close` and 5.35 s with
keep-alive — the whole DRAIN_TIMEOUT_NS budget, most of `docker stop`'s
10 s, for a connection that had already been answered.

The drain now re-runs the between-requests sweep after every completion
pass. This sends `GET /slow?ms=1500` on a keep-alive connection, signals
the server 300 ms later, asserts the 200 arrives, then asserts the process
exits well inside the budget. The limit is deliberately far above the
~1.6 s a pass measures and far below the ~5.3 s a regression measures.

Run as: `python3 scripts/drain_inflight_probe.py PORT PID [SLOW_MS]`
"""
import os
import signal
import socket
import sys
import time
import traceback

HOST = "127.0.0.1"
PORT = int(sys.argv[1])
PID = int(sys.argv[2])
SLOW_MS = int(sys.argv[3]) if len(sys.argv) > 3 else 1500
# The drain budget is 5 s. A pass exits ~0.05 s after the response; a
# regression exits at the deadline. Response time + 1.5 s separates them
# with room for a badly loaded runner.
LIMIT = SLOW_MS / 1000.0 + 1.5


# Which phase is running, for the crash handler below. The two assertions
# here fail in the same recv/kill calls but mean opposite things: an
# in-flight request DROPPED by the drain, versus one answered whose
# keep-alive connection then held the drain to its deadline. A traceback
# names the call and not the claim. apps/asgi_bare/ws_probe.py carries the
# original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("drain_inflight_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def main() -> int:
    phase("the in-flight request, which the drain must still answer")
    s = socket.create_connection((HOST, PORT), timeout=LIMIT + 5.0)
    request = (
        f"GET /slow?ms={SLOW_MS} HTTP/1.1\r\nHost: x\r\n"
        "Connection: keep-alive\r\n\r\n"
    ).encode()
    start = time.time()
    s.sendall(request)
    time.sleep(0.3)
    os.kill(PID, signal.SIGTERM)
    signalled = time.time()

    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(65536)
        if not chunk:
            print("connection closed before the response arrived", file=sys.stderr)
            return 1
        data += chunk
    answered = time.time()
    head = data.split(b"\r\n", 1)[0]
    if not head.startswith(b"HTTP/1.1 200"):
        print(f"in-flight request answered with {head!r}, want 200", file=sys.stderr)
        return 1
    print(
        f"in-flight request answered {answered - start:.2f}s after it was sent"
        f" ({answered - signalled:.2f}s after SIGTERM)"
    )

    phase("the exit, which the answered keep-alive must not hold open")
    # Wait for the process to actually go, not just for the signal to land.
    while time.time() - start < LIMIT + 4.0:
        try:
            os.kill(PID, 0)
        except OSError:
            break
        time.sleep(0.01)
    exited = time.time() - start
    s.close()

    try:
        os.kill(PID, 0)
    except OSError:
        pass
    else:
        print(f"server still alive {exited:.2f}s after the request was sent", file=sys.stderr)
        return 1
    if exited > LIMIT:
        print(
            f"server exited {exited:.2f}s after the request was sent, limit {LIMIT:.2f}s"
            " -- the answered keep-alive connection is holding the drain open",
            file=sys.stderr,
        )
        return 1
    print(f"server exited {exited:.2f}s after the request was sent ({exited - (answered - start):.2f}s after answering)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
