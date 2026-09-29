#!/usr/bin/env python3
"""Inbound ASGI WebSocket messages are DELIVERED, not dropped under pressure.

The defect this gates shipped in every release up to 0.15.1: the outbound
direction was credit-gated (`websocket.send` awaits its window) and the
inbound direction had no backpressure of any kind, so once the executor's
submit channel filled, `ws_message` discarded each further message with a
log line the client can never see. Measured at **2932 of 3000 lost**.

**The two directions are coupled, which is why the threshold is so low.**
The echo app awaits `send` inside its `receive` loop, so a client that stops
reading blocks that send on its OUTBOUND window -- which stops the app
calling `receive`, which stops the executor draining the submit channel that
INBOUND messages ride. The outbound backpressure produced the inbound loss.

**What a naive gate gets wrong, measured both ways.** A client that reads
CONCURRENTLY loses nothing on the BROKEN build -- 3000 of 3000 echoed, zero
drop lines. So a "send a lot and count the echoes" test passes on the
defect it was written for, which is worse than no gate. The loss needs a
client that stalls, and the shape below is what separates the builds:

    phase A  send WITHOUT reading until the socket stops taking bytes
    phase B  then read AND send concurrently, and require every message

Phase A is not itself the assertion -- BOTH builds stall there, because
socket buffers fill either way (measured 380 KB broken, 360 KB fixed).
Phase B is the discriminator, and it is decisive: 68 echoed broken, 3000
fixed, on the same workload against the same app.

What phase B proves is the design's own claim -- **a parked message is owed,
not dropped.** The loop stops reading a socket whose messages the executor
cannot take, TCP's zero window stops the client, and everything already
taken off the wire is delivered when the window reopens. Nothing is lost;
it is only late.

    python3 scripts/ws_inbound_loss_probe.py [N] [SIZE] [PORT]

Exits 0 on success, 1 naming the shortfall.
"""

import errno
import os
import socket
import sys
import threading
import time

from probelib import TEXT, WebSocket, encode_frame, fail, parse_frames, phase, server, stamp

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 4096
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8354
LOG = os.environ.get("M0_WSIN_LOG", "ws_inbound.log")

# Phase A must stall well inside the payload, or phase B never exercises a
# suspended read -- that is the precondition, not the assertion.
STALL_LIMIT_FRACTION = 0.5


# Which phase is running, for the crash handler. A traceback names the CALL
# that failed -- here a `send` or `recv` two phases share -- and never the
# PHASE being proven.
stamp("ws_inbound FAIL")


def count_text_frames(buf):
    """(complete text frames, bytes consumed) from a server frame stream."""
    frames, at = parse_frames(buf)
    return sum(1 for f in frames if f.opcode == TEXT), at


def main():
    phase("waiting for the server")
    # The listener is what is waited for; a server that exits first is
    # reported at once, with its log.
    with server(["./bin/m0serve", "bareapp.asgi:application",
                 "--app-dir", "apps/asgi_bare", "--port", str(PORT)],
                ("127.0.0.1", PORT), timeout=30, log=LOG, grace=10):
        time.sleep(0.5)

        phase("the handshake")
        ws = WebSocket.connect("127.0.0.1", PORT, "/ws", timeout=60, host_header="x")
        if ws.status_line is None:
            fail("no handshake response")
        if b" 101 " not in ws.status_line:
            fail("expected 101, got %r" % ws.status_line)
        sock = ws.sock

        frames = [encode_frame(TEXT, b"m" * SIZE) for _ in range(N)]
        total = sum(len(f) for f in frames)

        phase("phase A: sending WITHOUT reading, until the socket stops taking")
        sock.setblocking(False)
        pushed = msgs = 0
        blob = b""
        stalled = False
        deadline = time.time() + 15
        while msgs < N and time.time() < deadline:
            if not blob:
                blob = frames[msgs]
                msgs += 1
            try:
                n = sock.send(blob)
            except BlockingIOError:
                stalled = True
                break
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    stalled = True
                    break
                raise
            pushed += n
            blob = blob[n:]
        print("  phase A: pushed %d of %d bytes (%d of %d messages) before %s"
              % (pushed, total, msgs, N, "a stall" if stalled else "running out"))
        if not stalled:
            fail(
                "the client pushed its whole %d-byte payload without ever "
                "stalling, so phase B never exercises a suspended read -- "
                "raise N or SIZE. This is the probe's precondition, not the "
                "server's fault" % total
            )
        if pushed > total * STALL_LIMIT_FRACTION:
            fail(
                "the stall came at %d of %d bytes (over %.0f%%), too late to "
                "leave a meaningful backlog for phase B"
                % (pushed, total, STALL_LIMIT_FRACTION * 100)
            )

        phase("phase B: reading and sending together; every message is owed")
        got = [0]

        def reader():
            buf = bytes(ws.buf)
            end = time.time() + 120
            while got[0] < N and time.time() < end:
                try:
                    chunk = sock.recv(1 << 20)
                except (BlockingIOError, socket.timeout):
                    time.sleep(0.01)
                    continue
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
                seen, at = count_text_frames(buf)
                got[0] += seen
                buf = buf[at:]

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        end = time.time() + 120
        while time.time() < end:
            if not blob:
                if msgs >= N:
                    break
                blob = frames[msgs]
                msgs += 1
            try:
                blob = blob[sock.send(blob):]
            except (BlockingIOError, OSError):
                time.sleep(0.005)
        thread.join(timeout=125)

        lost = N - got[0]
        print("  phase B: sent %d, echoed %d, lost %d" % (N, got[0], lost))
        ws.close()

    dropped = [ln for ln in open(LOG) if "it is lost" in ln]
    if dropped:
        for ln in dropped[:3]:
            print("   ", ln.strip())
        fail(
            "the server logged %d dropped inbound messages. A parked message "
            "is OWED, never dropped: the loop must stop reading the socket "
            "rather than discard what it cannot forward" % len(dropped)
        )
    if lost:
        fail(
            "%d of %d inbound messages never came back. The broken build "
            "measured 2932 of 3000 here; a client that stalls must lose "
            "nothing, only wait" % (lost, N)
        )
    os.unlink(LOG)
    print("ws_inbound OK: %d messages, none lost, none dropped" % N)


if __name__ == "__main__":
    main()
