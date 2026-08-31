"""Prove idle keep-alive connections do not hold the graceful drain open.

`active_count` counts a connection that is merely *open* the same as one with
a request in flight. When it did nothing else, a server holding idle
keep-alive connections waited out the whole 5 s `DRAIN_TIMEOUT_NS` budget at
SIGTERM for clients that had already been answered — 5.02 s to exit against
0.02 s idle, in every execution mode, which is most of what `docker stop`
allows before it escalates to SIGKILL.

The shutdown path now closes slots that are in `READING_HEADERS` with an
empty receive buffer, which is what "between requests" looks like. This opens
N such connections, answers a request on each so they are genuinely idle
keep-alive rather than merely accepted, signals the server, and asserts it
exits well inside the budget.

The threshold is deliberately far below 5 s and far above the 0.03 s
measured: a regression puts this back at 5.02 s, so anything under a few
seconds distinguishes them on the slowest CI box without being flaky.

Run as: `python3 scripts/drain_idle_probe.py PORT PID [N]`
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
N = int(sys.argv[3]) if len(sys.argv) > 3 else 8
# The drain budget is 5 s. A pass measures ~0.03 s; a regression measures
# ~5.02 s. 3 s separates them with room for a badly loaded runner.
LIMIT = 3.0
REQUEST = b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"


# Which phase is running, for the crash handler below. This probe's phases
# have very different meanings -- failing to SET UP the idle connections is
# a broken server, failing to WAIT OUT the drain is the regression it pins
# -- and both live inside a recv/kill that a traceback names identically.
# apps/asgi_bare/ws_probe.py carries the original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("drain_idle_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def main() -> int:
    phase("opening %d idle keep-alive connections" % N)
    held = []
    for i in range(N):
        s = socket.create_connection((HOST, PORT), timeout=10)
        s.sendall(REQUEST)
        # Read the response so the connection is idle *between* requests --
        # the state the fix keys on -- rather than mid-request.
        if not s.recv(65536):
            print(f"connection {i} got no response", file=sys.stderr)
            return 1
        held.append(s)
    print(f"holding {len(held)} idle keep-alive connections")

    phase("the drain after SIGTERM, which idle connections must not hold open")
    start = time.time()
    os.kill(PID, signal.SIGTERM)
    # Wait for the process to actually go, not just for the signal to land.
    while time.time() - start < LIMIT + 4.0:
        try:
            os.kill(PID, 0)
        except OSError:
            break
        time.sleep(0.01)
    elapsed = time.time() - start

    for s in held:
        try:
            s.close()
        except OSError:
            pass

    try:
        os.kill(PID, 0)
    except OSError:
        pass
    else:
        print(f"server still alive {elapsed:.2f}s after SIGTERM", file=sys.stderr)
        return 1

    if elapsed > LIMIT:
        print(
            f"drain took {elapsed:.2f}s with {N} idle keep-alive connections,"
            f" limit {LIMIT}s -- idle connections are holding the drain open",
            file=sys.stderr,
        )
        return 1
    print(f"drained in {elapsed:.2f}s with {N} idle keep-alive connections")
    return 0


if __name__ == "__main__":
    sys.exit(main())
