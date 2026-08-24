"""The async third of the example — not mountable beside the other two yet.

Stage 1 routes several applications in one process but serves them all
through one execution mode, so a mixed WSGI/ASGI pair is refused rather
than served badly. This module is what `poe smoke-hybrid` mounts to prove
that refusal is real, and it is what stage 2 will mount for real once each
mount can have its own native mode.
"""


async def application(scope, receive, send):
    assert scope["type"] == "http"
    body = b"hello from asgi on mojo-http"
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
