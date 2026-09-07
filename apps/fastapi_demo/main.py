"""A minimal FastAPI app: the second Starlette-family ASGI row.

FastAPI is Starlette-based ASGI, served as `main:app` (m0serve's ATTR
otherwise defaults to `application`):

    bin/m0serve main:app --app-dir apps/fastapi_demo --port 8099

`poe smoke-fastapi` runs it and skips cleanly when fastapi is not installed,
the same arrangement as the FastHTML and Flask rows.

What this app exists to exercise is the SEAM, not the framework. FastAPI's
own request validation, dependency injection and OpenAPI page are FastAPI's
to test; what m0serve has to get right is that a Starlette response driven
by FastAPI's routing reaches the executor intact. So the routes here are the
three that touch the executor differently: a buffered response, a streamed
one, and a WebSocket the app closes itself.

`/stream` is deliberately infinite. Under the executor it streams for real
and the smoke reads live ticks off it; the buffered escape hatch refuses it
with the 10 s watchdog (docs/notes/wsgi-vs-asgi-history.md §8), which is the
distinction the row is claiming.
"""

import asyncio

from fastapi import FastAPI, WebSocket
from fastapi.responses import PlainTextResponse, StreamingResponse

app = FastAPI(docs_url=None, redoc_url=None)


@app.get("/", response_class=PlainTextResponse)
async def index():
    return "m0serve-fastapi-demo"


@app.get("/plain", response_class=PlainTextResponse)
async def plain():
    return "plain text from fastapi"


async def _ticks():
    n = 0
    while True:
        yield ("data: tick %d\n\n" % n).encode()
        n += 1
        await asyncio.sleep(0.05)


@app.get("/stream")
async def stream():
    # Starlette produces this body from a child task inside an anyio task
    # group, so the shim must mark the SLOT's owning task rather than
    # `asyncio.current_task()`. It marked the child once (PR #223): the
    # ticks arrived intact and one traceback per streamed response went to
    # the log, which is why the smoke reads the log and not just the body.
    return StreamingResponse(_ticks(), media_type="text/event-stream")


@app.websocket("/ws")
async def ws(websocket: WebSocket):
    await websocket.accept()
    while True:
        msg = await websocket.receive_text()
        if msg == "bye":
            # The app closes first, which is the order RFC 6455 5.5.1 makes
            # the server linger for the peer's reply (SPEC L15/L16). Driving
            # it through FastAPI's own API rather than a raw send is the
            # point of doing it here as well as in the bare app.
            await websocket.close(code=1000)
            return
        await websocket.send_text("ws-echo:%s" % msg)
