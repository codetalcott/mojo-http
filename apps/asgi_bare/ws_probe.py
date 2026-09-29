#!/usr/bin/env python3
"""Raw RFC 6455 client for smoke-asgi's WebSocket phase — stdlib only.

The same wire format as apps/ws_echo/ws_probe.py, spoken through
scripts/probelib.py's client, against the ASGI echo at /ws: handshake
(Sec-WebSocket-Accept verified), masked text echo (the app prefixes
"echo:"), binary echo, then "bye" → the app's websocket.close(1000) → close
frame → TCP FIN — proving the executor's accept/perform split, both frame
directions, and the close-after-drain.
"""

import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import (BINARY, CLOSE, PING, PONG, TEXT, WebSocket, fail,  # noqa: E402
                      phase, stamp)

# /ws/flood's shape, kept in step with apps/asgi_bare/bareapp/asgi.py.
FLOOD_FRAMES = 400
FLOOD_SIZE = 4096

# How many app-initiated closes the close-order phase runs at once. The
# server used to close its side the instant its own Close frame drained, so
# the peer's reply reached a socket that was already gone and TCP answered
# with an RST. Concurrency is what widens that window, because the loop's
# pass gets longer: on the broken server 17 of 20 reset, and 100 of 100. On
# a fixed one none do at any width, so 64 is decisive without being slow --
# and `poe stress-asgi` drives this probe every round, so it has to be both.
CLOSE_CONNS = 64

HOST = "127.0.0.1"
PORT = int(os.environ.get("M0_PORT", "8088"))


# Which phase is running, for the crash handler. The 2026-08-30 CI failure
# was an unhandled ConnectionResetError, and its traceback named a line in
# `recv_exact` -- a helper four phases shared -- so the log said which CALL
# reset and not which PHASE was being proven. That is the difference between
# "the flood connection was reset while the client stalled" and "something,
# somewhere, reset".
#
# A reset rather than a clean FIN means the server closed a socket with
# bytes still queued on it, which the kernel turns into an RST (CLAUDE.md,
# the chunked-trailer rule). Reported as a finding with its phase, because a
# bare traceback costs the next investigator the reproduction -- and this
# probe is driven N times a round by `poe stress-asgi`, where the round
# number alone is not enough.
stamp("asgi ws_probe FAIL")


def handshake(path, what):
    """Open a connection and complete the RFC 6455 handshake for `path`.

    The accept value is verified in `main`'s first connection, which is
    where that property belongs; this is for the later phases, which are
    about what happens AFTER the upgrade. Bytes the application sent at once
    stay buffered for the first frame read, rather than going with the head.
    """
    ws = WebSocket.connect(HOST, PORT, path, timeout=30)
    if ws.status_line is None:
        fail("no handshake response on %s" % what)
    if b" 101 " not in ws.status_line:
        fail("%s expected 101, got %r" % (what, ws.status_line))
    return ws


def main():
    phase("the echo connection's handshake")
    ws = WebSocket.connect(HOST, PORT, "/ws", timeout=10)
    if ws.status_line is None:
        fail("no handshake response")
    if b" 101 " not in ws.status_line:
        fail("expected 101, got %r" % ws.status_line)
    # Case-insensitive header name, exact accept value.
    if not ws.accept_ok():
        fail("bad Sec-WebSocket-Accept")

    phase("the text and binary echoes")
    ws.send(TEXT, b"hello")
    op, payload = ws.recv_data()
    if op != TEXT or payload != b"echo:hello":
        fail("text echo wrong: op=%d payload=%r" % (op, payload))

    ws.send(BINARY, bytes([0, 1, 255, 128]))
    op, payload = ws.recv_data()
    if op != BINARY or payload != bytes([0, 1, 255, 128]):
        fail("binary echo wrong: op=%d payload=%r" % (op, payload))

    phase("the app-initiated close handshake")
    ws.send(TEXT, b"bye")
    op, payload = ws.recv_data()
    if op != CLOSE:
        fail("expected close frame after bye, got op=%d %r" % (op, payload))
    if len(payload) >= 2 and struct.unpack(">H", payload[:2])[0] != 1000:
        fail("close code != 1000: %r" % payload[:2])
    # Close handshake reply, then the server should FIN.
    ws.send(CLOSE, payload[:2])
    ws.settimeout(5)
    try:
        rest = ws.recv_raw(1024)
    except socket.timeout:
        fail("no FIN after close handshake")
    if rest not in (b"",):
        # Tolerate a duplicate close echo before FIN.
        try:
            rest = ws.recv_raw(1024)
        except socket.timeout:
            fail("no FIN after close echo")
        if rest != b"":
            fail("unexpected bytes after close: %r" % rest)
    ws.close()

    # --- backpressure: a flooding app against a client that stalls -------
    # 400 x 4 KB with no pause, from a client that reads nothing for two
    # seconds. Ungated, `websocket.send` filled the loop's 64 KB per-slot
    # outbox and every frame past it was REFUSED -- 430,693 of 1,638,400
    # bytes delivered under a clean close frame, a message stream with
    # holes the peer had no protocol-level way to detect. The send window
    # makes the application wait instead, so the count here is exact.
    phase("the flood connection (a stalled client against a flooding app)")
    ws = handshake("/ws/flood", "the flood connection")
    time.sleep(2.0)          # stall: the outbox is the only place to go
    got = frames = 0
    closed = False
    while True:
        try:
            op, payload = ws.recv_frame(eof_ok=True)
        except EOFError:
            # The server hung up mid-stream: what the loud-refusal guard
            # does when the outbox overflows. Counted and diagnosed below.
            break
        if op == CLOSE:
            closed = True
            break
        if op == PING:
            ws.send(PONG, payload)
            continue
        if op != BINARY:
            fail("flood: unexpected opcode 0x%x" % op)
        if payload != b"x" * FLOOD_SIZE:
            fail("flood: frame %d is %d bytes, not %d -- the payload was "
                 "corrupted, not merely dropped" % (frames, len(payload),
                                                    FLOOD_SIZE))
        frames += 1
        got += len(payload)
    if frames != FLOOD_FRAMES or got != FLOOD_FRAMES * FLOOD_SIZE:
        fail(
            "flood: %d of %d frames (%d of %d bytes) arrived -- the send "
            "window is not applying backpressure, so the loop's outbox "
            "refused what it could not hold"
            % (frames, FLOOD_FRAMES, got, FLOOD_FRAMES * FLOOD_SIZE)
        )
    if not closed:
        fail("flood: the app's close(1000) never arrived")
    ws.close()

    # --- close order: a Close reply must not be met with an RST ---------
    # RFC 6455 §5.5.1 has the endpoint that sends Close FIRST wait to
    # RECEIVE one before closing the connection. Closing straight after the
    # send instead means the peer's reply lands on a socket that is already
    # gone, and the RST that answers it flushes the peer's receive queue --
    # taking our FIN with it and, on a client far enough behind, the Close
    # frame itself. Measured against the `websockets` library at this width
    # before the fix: 33 of 200 saw `no close frame received or sent`
    # instead of the application's own code 1000, so this is not merely a
    # strict probe being strict.
    #
    # Concurrent because that is what widens the window: one connection at
    # a time, a fast loop closes before the reply is even sent, and the bug
    # hides. It hid for two investigations.
    phase("the close order under %d concurrent closes" % CLOSE_CONNS)
    outcomes = []
    outcomes_lock = threading.Lock()
    gate = threading.Barrier(CLOSE_CONNS)

    def close_once():
        result = "?"
        try:
            conn = handshake("/ws", "a close-order connection")
            gate.wait()
            conn.send(TEXT, b"bye")
            op, body = conn.recv_data()
            if op != CLOSE:
                result = "op=0x%x, not a close frame" % op
            else:
                conn.send(CLOSE, body[:2])
                conn.settimeout(10)
                tail = conn.recv_raw(1024)
                if tail == b"":
                    result = "FIN"
                else:
                    # Named by opcode: the one seen was 0x9, the heartbeat
                    # ping, sent to a slot that was lingering for this very
                    # reply (stress-asgi, 3 rounds of 30 under CPU hogs).
                    result = "a 0x%x frame after the Close exchange" % (tail[0] & 0x0F)
            conn.close()
        except ConnectionResetError:
            # The finding: our close reply was answered with a reset.
            result = "RST"
        except Exception as exc:
            result = type(exc).__name__
        with outcomes_lock:
            outcomes.append(result)

    workers = [threading.Thread(target=close_once) for _ in range(CLOSE_CONNS)]
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    clean = outcomes.count("FIN")
    if clean != CLOSE_CONNS:
        summary = ", ".join(
            "%dx %s" % (outcomes.count(o), o) for o in sorted(set(outcomes))
        )
        fail(
            "close order: %d of %d closes ended in a clean FIN (%s) -- an RST "
            "is the server closing before the peer's Close reply, and the "
            "reset that answers the reply discards the close frame with it; "
            "a frame is the server still sending after its own Close"
            % (clean, CLOSE_CONNS, summary)
        )

    # --- the quiet linger: nothing follows this side's Close ------------
    # RFC 6455 §1.4: after sending a Close "a peer does not send any
    # further data". The stream heartbeat used to ping a slot lingering
    # for the peer's reply, and under CPU hogs the 300 ms beat landed
    # inside the window between the Close going out and the reply being
    # read: the phase above read 0x89 0x02 "hb" where it expected the FIN,
    # in 3 rounds of 30 (`poe stress-asgi`). Deterministic here because the
    # reply is what the ping raced, and a reply held for a second -- three
    # heartbeat periods, inside the two-second linger -- loses that race
    # every time on the old server: three pings, where silence is required.
    phase("the quiet linger: nothing follows the server's Close")
    conn = handshake("/ws", "a slow-to-reply connection")
    conn.send(TEXT, b"bye")
    op, body = conn.recv_data()
    if op != CLOSE:
        fail("quiet linger: expected the app's Close, got op=0x%x" % op)
    conn.settimeout(1.0)
    try:
        early = conn.recv_raw(1024)
    except socket.timeout:
        early = None
    if early == b"":
        fail("quiet linger: the server closed before our Close reply (the linger is two seconds)")
    if early is not None:
        fail(
            "quiet linger: a 0x%x frame arrived after the server's Close and "
            "before our reply -- nothing may follow a Close (RFC 6455 §1.4)"
            % (early[0] & 0x0F)
        )
    conn.send(CLOSE, body[:2])
    conn.settimeout(10)
    if conn.recv_raw(1024) != b"":
        fail("quiet linger: bytes after our Close reply where the FIN was due")
    conn.close()

    phase("the abrupt disconnect")
    # Second connection: vanish abruptly after the 101, no close
    # handshake — the disconnect tag must cancel the app task and the
    # server must stay healthy (the smoke checks health right after).
    ws = WebSocket.connect(HOST, PORT, "/ws", timeout=10)
    if ws.status_line is None:
        fail("no handshake response on the abrupt connection")
    if b" 101 " not in ws.status_line:
        fail("abrupt connection expected 101")
    ws.close()
    print("asgi ws_probe OK")


if __name__ == "__main__":
    main()
