"""A bare ASGI application: every route pins one clause of the spec.

The ASGI sibling of ``apps/wsgi_bare`` and written under the same rule: no
framework, no third-party import, nothing the server could blame. When a
smoke assertion fails against this app, the bug is the server's by
construction.

Routes:
    /               hello, and the smoke's liveness probe
    /scope          JSON dump of the scope's testable parts — header pairs
                    lowercased bytes, query_string bytes, decoded path
    /echo           request body echoed back, byte for byte (binary-safe;
                    pins the one-message ``http.request`` contract)
    /chunks         a FINITE ``more_body=True`` sequence: buffered bridges
                    must join it, streaming servers must stream it
    /cookies        two Set-Cookie headers (a Dict-shaped header map drops
                    one; pins the response cookie jar)
    /status/NNN     answers with status NNN
    /slow?ms=N      awaits N milliseconds before answering
    /lifespan       reports whether lifespan startup ran (state flag)
    /ws-last-close  the code the last /ws/record socket's disconnect
                    carried (SPEC L28, I26); /ws-texts, every text message
                    those sockets received
    /background-forever
                    answers ``ok``, then keeps running for ever, as
                    background work after a response can: the shutdown
                    drain must end it and still run lifespan shutdown
    /stream-forever an infinite SSE-shaped stream: pins the buffered
                    bridge's watchdog error, and later a streaming
                    server's actual streaming
    /redirect, /nocontent, /nocontent-cl, /notmodified, /notmodified-cl,
    /sized, /no-content-type
                    heads with exactly the headers named in each branch,
                    so anything else on the wire is the server's
                    (``scripts/head_probe.py``; SPEC A21, K12)

Lifespan shutdown writes the file named by ``M0_SHUTDOWN_MARKER`` when that
variable is set, so a smoke can assert the application was shut down (and
not merely killed) after a request outlived the server's drain.
"""

import asyncio
import json
import os

_LIFESPAN = {"started": False}
# The disconnect codes /ws/record sockets were told, in order, and every
# text message they received.
_WS_CLOSES = []
_WS_TEXTS = []

# /ws/flood's shape. 400 x 4 KB is ~25 send windows' worth, so the
# executor's backpressure is exercised many times over rather than
# incidentally; the probe asserts the exact byte count, framing included.
FLOOD_FRAMES = 400
FLOOD_SIZE = 4096

# /ws/oversized's shape (SPEC I17). `MAX_PENDING_BYTES` (64 KB) bounds ONE
# frame as well as the whole queue, so a message at or above it can never be
# queued however patient the sender is -- the credit gate cannot help, and
# clamps rather than waiting for a window that can never exist. The server's
# answer is to END the connection, because a dropped frame is a message the
# peer has no protocol-level way to notice it missed. UNDER is delivered
# whole; OVER is never delivered and the marker after it must never arrive.
OVERSIZED_UNDER = 32 * 1024
# Just OVER the cap, not far over: `websocket.send` does not split (only
# `_emit` does), so this crosses the chunk channel as one datagram, and a
# message far above the cap would meet the channel's own limits first --
# which ends the connection too, and would make the gate pass without the
# outbox cap existing at all. 66 KB encodes to 67594, just past 65536.
OVERSIZED_OVER = 66 * 1024
OVERSIZED_MARKER = "after-the-oversized-message"

# /sized's and /notmodified-cl's length: the body a GET of /sized carries.
SIZED = 12345


async def application(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                _LIFESPAN["started"] = True
                # state is per-server-lifetime, shallow-copied into each
                # request scope; /lifespan asserts this arrived.
                scope.get("state", {})["bare_started"] = True
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                # Pins that shutdown reaches the application even when a
                # request outlived the loop's drain: the smoke sets the
                # marker path and asserts the file exists after exit.
                marker = os.environ.get("M0_SHUTDOWN_MARKER")
                if marker:
                    with open(marker, "w") as fh:
                        fh.write("lifespan.shutdown\n")
                await send({"type": "lifespan.shutdown.complete"})
                return
        return

    if scope["type"] == "websocket":
        # The echo server: accept, prefix-echo text, byte-echo binary,
        # close(1000) on "bye", reject any path but /ws.
        if scope["path"] == "/ws/oversized":
            # One message the outbox can hold, then one it cannot, then a
            # marker. A server that dropped the oversized frame silently
            # would deliver the marker and close(1000) — the client would
            # see a clean, complete-looking conversation with a message
            # missing from the middle of it.
            await send({"type": "websocket.accept"})
            await send({"type": "websocket.send",
                        "bytes": b"u" * OVERSIZED_UNDER})
            await send({"type": "websocket.send",
                        "bytes": b"o" * OVERSIZED_OVER})
            await send({"type": "websocket.send", "text": OVERSIZED_MARKER})
            await send({"type": "websocket.close", "code": 1000})
            return
        if scope["path"] == "/ws/flood":
            # The backpressure exerciser: FLOOD_FRAMES x FLOOD_SIZE with no
            # pause and no reads. A client that stalls before reading cannot
            # keep up, so every one of these sends has to WAIT on the
            # executor's send window; ungated they filled the loop's 64 KB
            # outbox and the frames it then refused were messages the peer
            # had no way to know it had missed.
            await send({"type": "websocket.accept"})
            for _ in range(FLOOD_FRAMES):
                await send({"type": "websocket.send",
                            "bytes": b"x" * FLOOD_SIZE})
            await send({"type": "websocket.close", "code": 1000})
            return
        if scope["path"] == "/ws/record":
            # Echoes text like /ws, answers a binary message with its length
            # (an echo of a 64 KB message would exceed the executor's own
            # outbound window), and keeps the code its disconnect carried:
            # `/ws-last-close` answers it, so a probe can read back what the
            # application was told (SPEC L28, I26).
            await send({"type": "websocket.accept"})
            while True:
                message = await receive()
                if message["type"] == "websocket.disconnect":
                    _WS_CLOSES.append(message.get("code"))
                    return
                if message["type"] != "websocket.receive":
                    continue  # websocket.connect comes first
                data = message.get("bytes")
                if data is not None:
                    reply = "len:%d" % len(data)
                else:
                    reply = message.get("text") or ""
                    _WS_TEXTS.append(reply)
                try:
                    await send({"type": "websocket.send", "text": reply})
                except OSError:
                    # Its client has gone (ClientDisconnected): keep
                    # receiving, because the disconnect and its code are
                    # what a probe reads back.
                    pass
        if scope["path"] != "/ws":
            await send({"type": "websocket.close"})
            return
        await send({"type": "websocket.accept"})
        while True:
            message = await receive()
            t = message["type"]
            if t == "websocket.disconnect":
                return
            if t == "websocket.receive":
                text = message.get("text")
                if text == "bye":
                    await send({"type": "websocket.close", "code": 1000})
                    return
                if text is not None:
                    await send({"type": "websocket.send",
                                "text": "echo:" + text})
                else:
                    await send({"type": "websocket.send",
                                "bytes": bytes(message.get("bytes") or b"")})

    assert scope["type"] == "http"
    path = scope["path"]

    if path == "/":
        await _text(send, 200, b"hello from asgi_bare")
    elif path == "/scope":
        await _scope_dump(scope, send)
    elif path == "/echo":
        body = await _drain_body(receive)
        await _send_start(send, 200, [(b"content-type", b"application/octet-stream")])
        await send({"type": "http.response.body", "body": body})
    elif path == "/chunks":
        await _send_start(send, 200, [(b"content-type", b"text/plain")])
        for piece in (b"one-", b"two-", b"three"):
            await send({"type": "http.response.body", "body": piece,
                        "more_body": True})
        await send({"type": "http.response.body", "body": b""})
    elif path == "/cookies":
        await _send_start(send, 200, [
            (b"content-type", b"text/plain"),
            (b"set-cookie", b"first=1; Path=/"),
            (b"set-cookie", b"second=2; Path=/"),
        ])
        await send({"type": "http.response.body", "body": b"cookies"})
    elif path.startswith("/status/"):
        await _text(send, int(path.rsplit("/", 1)[1]), b"status as asked")
    elif path == "/ws-texts":
        await _text(send, 200, "\n".join(_WS_TEXTS).encode())
    elif path == "/ws-last-close":
        await _text(send, 200, str(_WS_CLOSES[-1] if _WS_CLOSES else "none").encode())
    elif path == "/background-forever":
        await _text(send, 200, b"ok")
        while True:
            await asyncio.sleep(0.05)
    elif path == "/slow":
        ms = 0
        for pair in scope["query_string"].decode("latin-1").split("&"):
            if pair.startswith("ms="):
                ms = int(pair[3:] or 0)
        await asyncio.sleep(ms / 1000.0)
        await _text(send, 200, b"slept %d" % ms)
    elif path == "/validate/canary":
        # The engagement canary, mirroring /pep3333/canary on the WSGI
        # row: a message type the spec does not define. This server
        # ignores unknown send types, so unvalidated this route is an
        # ordinary 200 -- and under M0_ASGI_VALIDATE it is a 500, which
        # is what proves the wrapper is actually on rather than skipped
        # by a misspelled variable.
        await send({"type": "http.response.bogus"})
        await _text(send, 200, b"canary was not caught")
    elif path == "/lifespan":
        payload = json.dumps({
            "started": _LIFESPAN["started"],
            "state_flag": bool(scope.get("state", {}).get("bare_started")),
        }).encode()
        await _send_start(send, 200, [(b"content-type", b"application/json")])
        await send({"type": "http.response.body", "body": payload})
    elif path == "/stream-forever":
        await _send_start(send, 200, [(b"content-type", b"text/event-stream")])
        n = 0
        while True:
            await send({"type": "http.response.body",
                        "body": b"data: %d\n\n" % n, "more_body": True})
            n += 1
            await asyncio.sleep(0.05)
    elif path == "/stream":
        # A finite streamed body larger than the credit window: pins the
        # chunk split, backpressure, byte-exactness, and the end-close.
        # Deterministic content so the smoke can hash it.
        size = 1024 * 1024
        piece_size = 64 * 1024
        for pair in scope["query_string"].decode("latin-1").split("&"):
            if pair.startswith("size="):
                size = int(pair[5:] or 0)
            elif pair.startswith("piece="):
                # Django's FileResponse streams 4 KB pieces; many small
                # datagrams is the shape that overflowed the chunk channel.
                piece_size = int(pair[6:] or 0)
        await _send_start(send, 200, [(b"content-type", b"application/octet-stream")])
        block = (bytes(range(256)) * 256)[:piece_size]
        sent_total = 0
        while sent_total < size:
            piece = block[: min(len(block), size - sent_total)]
            await send({"type": "http.response.body", "body": piece,
                        "more_body": True})
            sent_total += len(piece)
        await send({"type": "http.response.body", "body": b""})
    elif path == "/stream-events":
        # Datastar-shaped named events — and one event deliberately split
        # across two sends mid-line: a protocol heartbeat landing between
        # them would corrupt the frame, which is exactly what the smoke
        # asserts cannot happen.
        await _send_start(send, 200, [(b"content-type", b"text/event-stream")])
        await send({"type": "http.response.body",
                    "body": b"event: datastar-patch-elements\n"
                            b"data: elements <div id=\"n1\">one</div>\n\n",
                    "more_body": True})
        await send({"type": "http.response.body",
                    "body": b"event: datastar-patch-sig",
                    "more_body": True})
        await asyncio.sleep(0.7)  # longer than the smoke's heartbeat cadence
        await send({"type": "http.response.body",
                    "body": b"nals\ndata: signals {\"n\": 2}\n\n",
                    "more_body": True})
        await send({"type": "http.response.body", "body": b""})
    elif path == "/redirect":
        # Starlette's RedirectResponse: a location and no content type.
        await _send_start(send, 303, [(b"location", b"/")])
        await send({"type": "http.response.body", "body": b""})
    elif path == "/nocontent":
        await _send_start(send, 204, [])
        await send({"type": "http.response.body", "body": b""})
    elif path == "/nocontent-cl":
        # Django's CommonMiddleware shape: a length and a body on a 204,
        # neither of which may reach the wire (RFC 9110 §8.6, §15.3.5).
        await _send_start(send, 204, [(b"content-length", b"7")])
        await send({"type": "http.response.body", "body": b"ignored"})
    elif path == "/notmodified":
        await _send_start(send, 304, [(b"etag", b'"v1"')])
        await send({"type": "http.response.body", "body": b""})
    elif path == "/notmodified-cl":
        # The length the GET would have had, which a 304 may keep.
        await _send_start(send, 304, [(b"etag", b'"v1"'),
                                      (b"content-length", b"%d" % SIZED)])
        await send({"type": "http.response.body", "body": b""})
    elif path == "/sized":
        # A HEAD answered as FileResponse answers one: the GET's length and
        # no body.
        await _send_start(send, 200, [
            (b"content-type", b"application/octet-stream"),
            (b"content-length", b"%d" % SIZED),
        ])
        body = b"" if scope["method"] == "HEAD" else b"s" * SIZED
        await send({"type": "http.response.body", "body": body})
    elif path == "/no-content-type":
        await _send_start(send, 200, [])
        await send({"type": "http.response.body", "body": b"canary"})
    else:
        await _text(send, 404, b"not found")


async def _drain_body(receive):
    chunks = []
    while True:
        message = await receive()
        if message["type"] != "http.request":
            break
        chunks.append(message.get("body", b""))
        if not message.get("more_body", False):
            break
    return b"".join(chunks)


async def _scope_dump(scope, send):
    payload = json.dumps({
        "method": scope["method"],
        "path": scope["path"],
        "raw_path": scope.get("raw_path", b"").decode("latin-1"),
        "query_string": scope["query_string"].decode("latin-1"),
        "http_version": scope["http_version"],
        "scheme": scope["scheme"],
        "root_path": scope.get("root_path", ""),
        "headers": sorted(
            [n.decode("latin-1"), v.decode("latin-1")]
            for n, v in scope["headers"]
        ),
        "server": list(scope.get("server") or []),
        "asgi_version": scope.get("asgi", {}).get("version", ""),
    }).encode()
    await _send_start(send, 200, [(b"content-type", b"application/json")])
    await send({"type": "http.response.body", "body": payload})


async def _send_start(send, status, headers):
    await send({"type": "http.response.start", "status": status,
                "headers": headers})


async def _text(send, status, body):
    await _send_start(send, status, [(b"content-type", b"text/plain")])
    await send({"type": "http.response.body", "body": body})


if os.environ.get("M0_ASGI_VALIDATE"):
    from .validate import validator

    application = validator(application)
