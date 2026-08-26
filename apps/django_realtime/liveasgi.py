"""A bare ASGI application, mounted beside the realtime Django project.

No framework: `poe smoke-django-realtime`'s mounted phase must run wherever
the repo runs, and a FastHTML dependency would make it conditional. What it
provides is the one thing Django-under-a-hold cannot — a request-scoped
generator stream, where the view *is* the producer — which is the shape that
makes an ASGI mount worth having beside a held one (`ai/streaming.py` in the
application that motivated this; docs/REAL_APP_VALIDATION.md).

Held streams and this one share a loop and are told apart by lane
(`OffloadPool.slot_is_executor`): this one is chunk-framed and credit-gated
by its executor, the held ones are drained from the loop's registries and
keep their comment heartbeat.
"""

import asyncio


async def _text(send, status, body):
    await send({
        "type": "http.response.start",
        "status": status,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": body})


async def application(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return

    path = scope.get("path", "")
    if path.endswith("/stream"):
        # Five events, 100 ms apart, produced as they are sent: the thing a
        # buffered WSGI response cannot do at all.
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/event-stream")],
        })
        for i in range(5):
            await asyncio.sleep(0.1)
            await send({
                "type": "http.response.body",
                "body": b"event: tick\ndata: %d\n\n" % i,
                "more_body": True,
            })
        await send({"type": "http.response.body", "body": b""})
        return

    await _text(send, 200, b"hello from the asgi mount\n")
