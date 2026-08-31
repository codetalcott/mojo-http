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

import base64
import errno
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 4096
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8354
LOG = os.environ.get("M0_WSIN_LOG", "ws_inbound.log")

# Phase A must stall well inside the payload, or phase B never exercises a
# suspended read -- that is the precondition, not the assertion.
STALL_LIMIT_FRACTION = 0.5


# Which phase is running, for the crash handler below. A traceback names the
# CALL that failed -- here a `send` or `recv` two phases share -- and never
# the PHASE being proven.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("ws_inbound FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("ws_inbound FAIL:", msg)
    sys.exit(1)


def ws_frame(opcode, payload):
    mask = os.urandom(4)
    hdr = bytes([0x80 | opcode])
    if len(payload) < 126:
        hdr += bytes([0x80 | len(payload)])
    elif len(payload) < 65536:
        hdr += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
    else:
        hdr += bytes([0x80 | 127]) + struct.pack(">Q", len(payload))
    return hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def count_text_frames(buf):
    """(complete text frames, bytes consumed) from a server frame stream."""
    seen = at = 0
    while at + 2 <= len(buf):
        ln = buf[at + 1] & 0x7F
        hdr = 2
        if ln == 126:
            if at + 4 > len(buf):
                break
            ln = struct.unpack(">H", buf[at + 2:at + 4])[0]
            hdr = 4
        elif ln == 127:
            if at + 10 > len(buf):
                break
            ln = struct.unpack(">Q", buf[at + 2:at + 10])[0]
            hdr = 10
        if at + hdr + ln > len(buf):
            break
        if buf[at] & 0x0F == 0x1:
            seen += 1
        at += hdr + ln
    return seen, at


def handshake(sock):
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % key
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            fail("no handshake response")
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        fail("expected 101, got %r" % head.split(b"\r\n", 1)[0])


def main():
    log = open(LOG, "w")
    srv = subprocess.Popen(
        ["./bin/m0serve", "bareapp.asgi:application",
         "--app-dir", "apps/asgi_bare", "--port", str(PORT)],
        stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ),
    )
    try:
        phase("waiting for the server")
        for _ in range(300):
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=0.5).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            fail("the server never accepted a connection")
        time.sleep(0.5)

        phase("the handshake")
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=60)
        handshake(sock)

        frames = [ws_frame(0x1, b"m" * SIZE) for _ in range(N)]
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
            buf = b""
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
        try:
            sock.close()
        except OSError:
            pass
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=10)
        except subprocess.TimeoutExpired:
            srv.kill()
        log.close()

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
