#!/usr/bin/env python3
"""What an ASGI application is told when its WebSocket client leaves, and an
inbound message the executor's channel cannot carry (SPEC L28, I26).

    python3 scripts/ws_close_probe.py --port 8088

Against apps/asgi_bare's `/ws/record`, which echoes and keeps the code its
`websocket.disconnect` carried, read back from `/ws-last-close`:

- a Close with 1001 is heard as 1001, one with no code as 1005, and a
  connection that ends without a Close as 1006 (RFC 6455 §7.1.5). The
  executor used to say 1006 for every one of them;
- a Close, or a last message, followed at once by the hang-up still
  reaches the application: the loop used to close a socket at EOF before
  reading what it had buffered;
- a 70,000-byte message, larger than the executor channel's 65,546-byte
  datagram, is refused with a Close carrying 1009, and the application
  hears 1009. It used to be parked and retried for ever: no reply, no close,
  no log -- a 70 KB chat message went silent;
- a message at the cap (65,536 bytes) is still delivered whole (the socket
  answers its length);
- and the server answers afterwards.

Stdlib only; exits 0 when every case holds.
"""

import argparse
import os
import socket
import struct
import time

from probelib import BINARY, CLOSE, PING, TEXT, WebSocket, encode_frame, fail, phase, stamp

PORT = 8088

# Which case is running, for the crash handler: a reset or a timeout inside a
# helper four cases share says nothing without it.
stamp("ws_close_probe FAIL", fail="ws_close_probe FAIL: {phase}: {msg}")


def connect():
    ws = WebSocket.connect("127.0.0.1", PORT, "/ws/record", timeout=10,
                           host_header="localhost")
    if ws.status_line is None:
        fail("closed during the handshake")
    if b" 101 " not in ws.status_line:
        fail("handshake answered %r" % ws.status_line)
    if not ws.accept_ok():
        fail("bad Sec-WebSocket-Accept")
    return ws


def http_get(path):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" % path).encode())
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    head, _, body = data.partition(b"\r\n\r\n")
    return head.split(b"\r\n", 1)[0], body.decode("latin-1")


def heard(want, within=5.0):
    """The code the application was told, polled: the disconnect reaches it
    asynchronously."""
    seen = None
    deadline = time.time() + within
    while time.time() < deadline:
        _, seen = http_get("/ws-last-close")
        if seen == str(want):
            return
        time.sleep(0.05)
    fail("the application heard %r, want %d" % (seen, want))


def expect_end(ws, within=5.0):
    """The server's end of a closing connection: EOF, and nothing before it
    but heartbeat pings."""
    deadline = time.monotonic() + within
    while True:
        try:
            op, payload = ws.recv_frame(deadline=deadline, eof_ok=True)
        except (EOFError, ConnectionResetError):
            ws.close()
            return
        except socket.timeout:
            break
        if op == PING:
            continue
        fail("after the closing handshake the server sent opcode %d" % op)
    fail("the connection was still open %.0f s after the closing handshake" % within)


def close_with(payload):
    ws = connect()
    ws.send(TEXT, b"hi")
    op, got = ws.recv_data(eof_ok=True)
    if (op, got) != (TEXT, b"hi"):
        fail("echo was %r" % ((op, got),))
    ws.send(CLOSE, payload)
    try:
        op, _ = ws.recv_data(eof_ok=True)
        if op != CLOSE:
            fail("the server answered a Close with opcode %d" % op)
    except (EOFError, OSError):
        pass
    ws.close()


def main():
    global PORT
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=PORT)
    PORT = ap.parse_args().port

    phase("Close 1001")
    close_with(struct.pack(">H", 1001) + b"going away")
    heard(1001)

    phase("Close with no code")
    close_with(b"")
    heard(1005)

    phase("no Close at all")
    ws = connect()
    ws.send(TEXT, b"hi")
    ws.recv_data(eof_ok=True)
    ws.sock.shutdown(socket.SHUT_RDWR)
    ws.close()
    heard(1006)

    phase("a Close and a hang-up in the same instant")
    # The client's Close and its FIN arrive together, so the loop sees
    # EV_EOF with the Close still unread: it used to close the socket
    # before reading it, and the application heard 1006.
    ws = connect()
    ws.send(TEXT, b"hi")
    ws.recv_data(eof_ok=True)
    ws.send_close(4001)
    ws.close()
    heard(4001)

    phase("a last message and a hang-up in the same instant")
    ws = connect()
    ws.send(TEXT, b"hi")
    ws.recv_data(eof_ok=True)
    ws.send(TEXT, b"last-words-before-the-hang-up")
    ws.close()
    heard(1006)
    _, texts = http_get("/ws-texts")
    if "last-words-before-the-hang-up" not in texts:
        fail("a message sent just before the hang-up never reached the application")

    phase("a message at the channel's cap")
    ws = connect()
    at_cap = os.urandom(65536)
    ws.send(BINARY, at_cap)
    op, got = ws.recv_data(eof_ok=True)
    if (op, got) != (TEXT, b"len:65536"):
        fail("the 65,536-byte message was answered %r" % ((op, got[:40]),))
    # A conforming client waits for the echo before closing TCP (RFC 6455
    # §7.1.1). One that hangs up in the same instant loses its code: the
    # loop closes a socket at EOF without reading what is buffered (tracked).
    ws.send_close(1000)
    try:
        ws.recv_data(eof_ok=True)
    except (EOFError, OSError):
        pass
    ws.close()
    heard(1000)

    phase("a message the channel cannot carry")
    ws = connect()
    # A message right behind it, in the same write: RFC 6455 §7.1.7, no
    # data is processed after the connection is failed.
    behind = b"after-the-refused-one"
    ws.sock.sendall(encode_frame(BINARY, b"o" * 70000) + encode_frame(TEXT, behind))
    # A deadline, not a per-read timeout: heartbeat pings every 300 ms would
    # keep a per-read timeout from ever firing, and a regression would hang
    # the smoke instead of failing it.
    try:
        op, got = ws.recv_data(deadline=time.monotonic() + 5.0, eof_ok=True)
    except socket.timeout:
        op = None
    if op is None:
        fail("no answer but heartbeats to a 70,000-byte message in 5 s: parked, not refused")
    if op != CLOSE:
        fail("a 70,000-byte message was answered with opcode %d, not a Close" % op)
    code = struct.unpack(">H", got[:2])[0] if len(got) >= 2 else None
    if code != 1009:
        fail("the Close carried %r, want 1009" % code)
    # The client answers the Close, as a browser does: the server must end
    # the connection -- no second Close, which Chromium reports as a
    # failed connection (1006) rather than the 1009 it was sent.
    ws.send_close(1009)
    expect_end(ws)
    heard(1009)
    _, texts = http_get("/ws-texts")
    if behind.decode() in texts:
        fail("a message sent behind the refused one reached the application")

    phase("the server afterwards")
    status, _ = http_get("/")
    if b" 200 " not in status:
        fail("GET / answered %r" % status)
    print("ws_close_probe OK: 1001, 1005, 1006, Close+hang-up, last-message+hang-up, at-cap delivery, 1009 refusal")


if __name__ == "__main__":
    main()
