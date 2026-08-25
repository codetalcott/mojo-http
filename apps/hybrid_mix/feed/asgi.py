"""The SECOND async mount: a bare ASGI app, no framework.

Exists so the two-executor case is proven against two different modules —
mounting one module twice would share the application object (and run its
lifespan twice against shared state), which would make the isolation claim
ambiguous exactly where it matters.

`/stream` is the route the smoke leans on: two mounts streaming
CONCURRENTLY exercises the shared chunk channel (slot-addressed datagrams
from two executor threads) and the per-lane drain acks (credit that must
reach the executor that owns the slot — misrouted credit is not an error
but a stream that stalls forever, which is why the smoke reads both
streams to completion rather than just opening them).
"""

import asyncio


async def application(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    assert scope["type"] == "http"
    path = scope.get("path", "/")
    root = scope.get("root_path", "")
    if path == root + "/stream" or path == "/stream":
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [(b"content-type", b"text/event-stream")],
            }
        )
        for i in range(6):
            await send(
                {
                    "type": "http.response.body",
                    "body": ("data: feed-%d\n\n" % i).encode(),
                    "more_body": True,
                }
            )
            await asyncio.sleep(0.15)
        await send({"type": "http.response.body", "body": b"data: feed-done\n\n"})
        return
    if path == root + "/big" or path == "/big":
        # 256 KB in 32 KB chunks, no sleeps: four times the credit window,
        # so this stream CANNOT complete unless drain acks reach this
        # executor -- credit misrouted to the other lane's executor is a
        # send() that awaits forever, and the reader times out. The
        # cheapest possible proof that per-lane ack routing is real.
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [(b"content-type", b"application/octet-stream")],
            }
        )
        block = b"F" * 32768
        for _ in range(7):
            await send(
                {"type": "http.response.body", "body": block, "more_body": True}
            )
        await send({"type": "http.response.body", "body": block})
        return
    body = b"hello from feed on mojo-http"
    await send(
        {
            "type": "http.response.start",
            "status": 200,
            "headers": [
                (b"content-type", b"text/plain"),
                (b"content-length", str(len(body)).encode()),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body})
