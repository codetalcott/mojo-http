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

import json
import os
import socket
import struct
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from probelib import CLOSE, TEXT, WebSocket, fail, phase, stamp  # noqa: E402

PORT = int(os.environ.get("M0_PORT", "8099"))
stamp("fastapi chat_probe FAIL", fail="fastapi chat_probe FAIL: {phase}: {msg}")


def frames_within(ws, seconds):
    """Every text frame (str) and close frame (('close', code)) that
    arrives within `seconds`, answering the loop's heartbeat pings.

    The WebSocket keeps whatever arrived with the handshake's 101: a socket
    whose app raises right after its accept sends its close frame straight
    behind the head, and a reader that dropped everything after the head's
    blank line would report that the close never came. A deadline that
    passes leaves a partial frame in the buffer rather than losing it."""
    out = []
    deadline = time.monotonic() + seconds
    while True:
        try:
            op, payload = ws.recv_data(deadline=deadline, eof_ok=True)
        except (socket.timeout, EOFError):
            return out
        if op == TEXT:
            out.append(payload.decode("utf-8"))
        elif op == CLOSE:
            code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
            out.append(("close", code))
            return out


def vanish(ws):
    """Gone with no close frame: the shape of a closed laptop lid."""
    ws.sock.shutdown(socket.SHUT_RDWR)
    ws.sock.close()


def connect(path):
    ws = WebSocket.connect("127.0.0.1", PORT, path, timeout=10)
    if ws.status_line is None:
        fail("no handshake response for %s" % path)
    if b" 101 " not in ws.status_line:
        fail("expected 101 for %s, got %r" % (path, ws.head[:40]))
    return ws


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
    vanish(two)
    got = frames_within(one, 3.0)
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
    one.send(TEXT, b"hi")
    got = frames_within(three, 1.5)
    if got != ["Client #1 says: hi"]:
        fail("client 3 got %r, want exactly ['Client #1 says: hi']: a "
             "second copy is a message addressed to a client who left, "
             "delivered on its recycled slot (SPEC L20)" % (got,))
    n = active()
    if n != 2:
        fail("%d active connections, want 2" % n)

    phase("a socket whose app raises closes with 1011")
    boom = connect("/ws-boom")
    got = frames_within(boom, 3.0)
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
    frames_within(big, 3.0)
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
    big.close()

    phase("the room empties one client at a time")
    # One at a time: the example's own `except` broadcasts "left" to
    # everyone still in its list, and two clients leaving in the same
    # instant would have it broadcast to a socket that is also going --
    # an application error of the example's, which lands in the log.
    vanish(three)
    got = frames_within(one, 3.0)
    if "Client #3 left the chat" not in got:
        fail("client 1 got %r, not 'Client #3 left the chat'" % (got,))
    vanish(one)
    boom.close()
    print("fastapi chat_probe OK")


if __name__ == "__main__":
    main()
