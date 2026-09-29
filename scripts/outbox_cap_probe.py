#!/usr/bin/env python3
"""A message at or above the outbox cap ends the connection (SPEC I17).

`MAX_PENDING_BYTES` (64 KB, `src/sse/registry.mojo`) bounds ONE frame as well
as the whole queue, so a message at or above it can never be queued however
patient the sender is. The executor's credit gate cannot rescue it and does
not try -- `_ws_spend` clamps a request bigger than the window rather than
waiting for credit that can never exist -- so the frame reaches the outbox,
`queue_frame` refuses it, and the server's answer is to END the connection.

That answer is deliberate, and this is what it is worth: a dropped WebSocket
frame is a message the peer has no protocol-level way to notice it missed. The
broken shape is not a crash, it is a CLEAN conversation with a hole in it --
the marker after the oversized message arriving under a `close(1000)`, exactly
as if the server had sent everything. So the assertion is not "something went
wrong" but "the connection ended INSTEAD of lying", and the marker is what
tells those apart.

The under-cap message is the other half. A server that ended every connection
carrying a large message would pass a test that only looked for the ending.

The drain has ONE deadline, not a timeout per read. The server pings every
heartbeat (15 s by default), and each ping reset the per-read timeout this
used to rely on, so a connection that neither delivered the message nor
ended was never judged here: two of `sabotage-outbox-cap`'s catches came
from its harness killing the probe at 180 s. A read timeout also used to
count as the connection ending, which would have passed a server that went
quiet instead. Now the deadline passing is "not ended", and the verdict is
this probe's own.

Run against `apps/asgi_bare` under `m0serve`.

Usage: outbox_cap_probe.py PORT
"""
import socket
import sys
import time

from probelib import CLOSE, TEXT, WebSocket, fail, phase, stamp

# The phase stamp: both phases share the frame reads, so a raise inside one
# names the call and not the claim. See scripts/phase_stamp_check.py.
stamp("outbox_cap_probe: FAIL", fail="outbox-cap: {msg}")

# Kept in step with apps/asgi_bare/bareapp/asgi.py.
OVERSIZED_UNDER = 32 * 1024
OVERSIZED_OVER = 66 * 1024
OVERSIZED_MARKER = b"after-the-oversized-message"
HOST = "127.0.0.1"
# How long a connection has to deliver what it will and end: the whole
# exchange takes milliseconds, and this was the per-read timeout before.
DRAIN_SECONDS = 20


def connect(port, path):
    """(WebSocket, status line) -- the status None if no head arrived."""
    ws = WebSocket.connect(HOST, port, path, timeout=20, host_header="localhost")
    status = ws.status_line
    return ws, None if status is None else status.decode("latin-1")


def drain_messages(ws, limit=16):
    """Every frame the server sends until it stops. Returns (frames, closed).

    Closed means the server ended the connection: a Close frame, EOF, or a
    reset. The deadline passing is NOT closed -- it is the connection
    staying open, which is the finding.
    """
    frames = []
    deadline = time.monotonic() + DRAIN_SECONDS
    for _ in range(limit):
        try:
            opcode, payload = ws.recv_frame(deadline=deadline, eof_ok=True)
        except (EOFError, ConnectionResetError):
            return frames, True
        except socket.timeout:
            return frames, False
        if opcode == CLOSE:
            return frames, True
        frames.append((opcode, payload))
    return frames, False


def main():
    port = int(sys.argv[1])

    phase("oversized-message-ends-the-connection")
    ws, status = connect(port, "/ws/oversized")
    if status is None or "101" not in status:
        fail("handshake on /ws/oversized: %r" % (status,))
    frames, closed = drain_messages(ws)
    ws.close()

    payloads = [p for _, p in frames]
    under = [p for p in payloads if len(p) == OVERSIZED_UNDER]
    over = [p for p in payloads if len(p) >= OVERSIZED_OVER]
    marker = [p for p in payloads if p == OVERSIZED_MARKER]

    # The under-cap message must arrive whole. Without this the test would
    # pass on a server that ended the connection at the first large frame.
    if not under:
        fail(
            "the under-cap message (%d bytes) never arrived: got %r. The cap "
            "is ending connections it should be serving."
            % (OVERSIZED_UNDER, [len(p) for p in payloads])
        )

    if over:
        fail(
            "a message of %d bytes was delivered, but MAX_PENDING_BYTES caps "
            "ONE frame at 65536 -- either the cap moved or this probe's "
            "constants are stale" % len(over[0])
        )

    # The claim. A silent drop looks exactly like success from here except
    # for this: the conversation continues past the message that vanished.
    if marker:
        fail(
            "the oversized message was dropped SILENTLY: the marker after it "
            "arrived, so the peer sees a complete conversation with a message "
            "missing from the middle. The connection must end instead."
        )
    if not closed:
        fail("the connection neither delivered the message nor ended")
    print("  oversized message: not delivered, no marker, connection ended")
    print("  under-cap message: delivered whole (%d bytes)" % OVERSIZED_UNDER)

    # An ordinary socket on the same server must be unaffected -- the cap is
    # a per-message rule, not a reason to distrust the connection.
    phase("an-ordinary-socket-still-works")
    ws, status = connect(port, "/ws")
    if status is None or "101" not in status:
        fail("handshake on /ws: %r" % (status,))
    ws.send(TEXT, b"hello")
    try:
        # A heartbeat ping may land first; it is not the answer.
        opcode, got = ws.recv_data(deadline=time.monotonic() + DRAIN_SECONDS,
                                   eof_ok=True, pong=False)
    except (EOFError, ConnectionResetError, socket.timeout):
        got = b""
    ws.close()
    if got != b"echo:hello":
        fail("an ordinary echo after the cap case returned %r" % got)
    print("  an ordinary socket on the same server: unaffected")

    print("outbox-cap OK")


if __name__ == "__main__":
    main()
