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
    /stream-forever an infinite SSE-shaped stream: pins the buffered
                    bridge's watchdog error, and later a streaming
                    server's actual streaming
"""

import asyncio
import json

_LIFESPAN = {"started": False}


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
                await send({"type": "lifespan.shutdown.complete"})
                return
        return

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
    elif path == "/slow":
        ms = 0
        for pair in scope["query_string"].decode("latin-1").split("&"):
            if pair.startswith("ms="):
                ms = int(pair[3:] or 0)
        await asyncio.sleep(ms / 1000.0)
        await _text(send, 200, b"slept %d" % ms)
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
