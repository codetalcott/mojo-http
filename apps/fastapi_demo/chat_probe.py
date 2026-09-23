#!/usr/bin/env python3
"""Stdlib WS client for smoke-fastapi's chat phases (SPEC L20, L21, L24).

`/chat/{client_id}` is FastAPI's own documented multi-client chat room, and
it leans on three server contracts at once:

* a departed client's `except WebSocketDisconnect:` cleanup RUNS -- the
  disconnect arrives through `receive()`, not as a cancellation (L21);
* that cleanup's broadcast, made on the departed client's own task, REACHES
  the sockets still connected -- a send is judged by the connection it
  addresses, not by the task making it (L20);
* a message for a client that has gone never reaches the client the server
  gave its slot to (L20).

Measured against 1.5.0: "left the chat" never arrived, the manager's list
kept the departed client for ever, and the next client to connect received
every message addressed to the one that left. `/ws-boom` raises after its
accept, which must close with 1011, not 1000 (L24).

Which of these a failure broke is what each phase's message says; a
traceback names the call that raised and never the phase, which is why
`PHASE` exists (apps/asgi_bare/ws_probe.py has the history).
"""

import base64
import json
import os
import socket
import struct
import sys
import time
import traceback
import urllib.request

PORT = int(os.environ.get("M0_PORT", "8099"))
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("fastapi chat_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    print("fastapi chat_probe FAIL: %s: %s" % (PHASE, msg))
    sys.exit(1)


class Conn:
    """A client socket plus the bytes read past what was asked for.

    Buffered because a frame can arrive in the same read as the handshake's
    101: a socket whose app raises right after its accept sends its close
    frame straight behind the head, and a reader that dropped everything
    after the head's blank line would report that the close never came.
    A timeout leaves a partial frame in the buffer rather than losing it."""

    def __init__(self, sock, pending=b""):
        self.sock = sock
        self.pending = pending

    def recv_exact(self, n):
        while len(self.pending) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EOFError("connection closed wanting %d bytes" % n)
            self.pending += chunk
        out, self.pending = self.pending[:n], self.pending[n:]
        return out

    def send_frame(self, opcode, payload):
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(
            struct.pack(">BB", 0x80 | opcode, 0x80 | len(payload)) + mask + masked
        )

    def read_frame(self):
        b0, b1 = self.recv_exact(2)
        if b1 & 0x80:
            fail("server frame is masked (servers MUST NOT mask)")
        ln = b1 & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", self.recv_exact(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self.recv_exact(8))[0]
        return b0 & 0x0F, (self.recv_exact(ln) if ln else b"")

    def frames_within(self, seconds):
        """Every text frame (str) and close frame (('close', code)) that
        arrives within `seconds`, answering the loop's heartbeat pings."""
        out = []
        deadline = time.time() + seconds
        while True:
            left = deadline - time.time()
            if left <= 0:
                return out
            self.sock.settimeout(left)
            try:
                op, payload = self.read_frame()
            except (socket.timeout, EOFError):
                return out
            if op == 0x9:
                self.send_frame(0xA, payload)
            elif op == 0x1:
                out.append(payload.decode("utf-8"))
            elif op == 0x8:
                code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
                out.append(("close", code))
                return out

    def vanish(self):
        """Gone with no close frame: the shape of a closed laptop lid."""
        self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()


def connect(path):
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET %s HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (path, PORT, key)
        ).encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            fail("no handshake response for %s" % path)
        head += chunk
    head, rest = head.split(b"\r\n\r\n", 1)
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        fail("expected 101 for %s, got %r" % (path, head[:40]))
    return Conn(sock, rest)


def get_json(path):
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (PORT, path), timeout=5) as r:
        return json.loads(r.read())


def active():
    return get_json("/chat-count")["active"]


def main():
    phase("two clients join the room")
    one = connect("/chat/1")
    two = connect("/chat/2")
    time.sleep(0.3)

    phase("client 2 vanishes and the room is told")
    two.vanish()
    got = one.frames_within(3.0)
    if "Client #2 left the chat" not in got:
        fail("client 1 got %r, not 'Client #2 left the chat': the departed "
             "client's `except WebSocketDisconnect:` cleanup did not run "
             "(SPEC L21), or its broadcast was refused (L20)" % (got,))

    phase("the manager's list lost the departed client")
    n = active()
    if n != 1:
        fail("%d active connections after client 2 left, want 1: its "
             "cleanup never removed it (SPEC L21)" % n)

    phase("a new client never receives another client's messages")
    three = connect("/chat/3")
    time.sleep(0.3)
    one.send_frame(0x1, b"hi")
    got = three.frames_within(1.5)
    if got != ["Client #1 says: hi"]:
        fail("client 3 got %r, want exactly ['Client #1 says: hi']: a "
             "second copy is a message addressed to a client who left, "
             "delivered on its recycled slot (SPEC L20)" % (got,))
    n = active()
    if n != 2:
        fail("%d active connections, want 2" % n)

    phase("a socket whose app raises closes with 1011")
    boom = connect("/ws-boom")
    got = boom.frames_within(3.0)
    closes = [f for f in got if isinstance(f, tuple)]
    if not closes or closes[0][1] != 1011:
        fail("the raising socket closed with %r, want 1011: 1000 tells the "
             "client all went well (SPEC L24)" % (closes,))

    phase("a socket the server ends itself still tells its application")
    # Its one message is over the 64 KB outbox cap, so the SERVER ends the
    # socket. Nothing about that reached the executor -- the loop tagged a
    # disconnect only for a slot still subscribed -- so the application's
    # receive() waited for ever and its cleanup never ran (SPEC L21).
    big = connect("/ws-big")
    big.frames_within(3.0)
    told = 0
    deadline = time.time() + 3.0
    while time.time() < deadline:
        told = get_json("/ws-big-told")["told"]
        if told:
            break
        time.sleep(0.1)
    if told != 1:
        fail("the server ended a socket over its outbox cap and the "
             "application never heard: /ws-big-told says %d (SPEC L21)" % told)
    big.sock.close()

    phase("the room empties one client at a time")
    # One at a time: the example's own `except` broadcasts "left" to
    # everyone still in its list, and two clients leaving in the same
    # instant would have it broadcast to a socket that is also going --
    # an application error of the example's, which lands in the log.
    three.vanish()
    got = one.frames_within(3.0)
    if "Client #3 left the chat" not in got:
        fail("client 1 got %r, not 'Client #3 left the chat'" % (got,))
    one.vanish()
    boom.sock.close()
    print("fastapi chat_probe OK")


if __name__ == "__main__":
    main()
