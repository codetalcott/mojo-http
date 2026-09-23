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

`/chat/{client_id}` is FastAPI's own documented multi-client chat room,
verbatim, because it is what a FastAPI author writes first and it leans on
three contracts at once: a departed client's `except WebSocketDisconnect:`
cleanup runs (SPEC L21), its broadcast from that dead client's task reaches
the sockets still connected (L20), and a message for a client that has gone
never reaches the next one on its slot (L20). `/ws-boom` raises after its
accept, which must close the socket with 1011 (L24). `chat_probe.py` drives
all four.
"""

import asyncio

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
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


class ConnectionManager:
    # FastAPI's documented multi-client chat ("WebSockets", "Handling
    # disconnections and multiple clients"), verbatim. Its cleanup is the
    # `except WebSocketDisconnect:` below, which a server that cancels the
    # task on disconnect never runs (SPEC L21); and the broadcast from that
    # except runs on the departed client's task, which a server that judges
    # a send by its caller refuses (L20).
    def __init__(self):
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        self.active_connections.remove(websocket)

    async def send_personal_message(self, message: str, websocket: WebSocket):
        await websocket.send_text(message)

    async def broadcast(self, message: str):
        for connection in self.active_connections:
            await connection.send_text(message)


manager = ConnectionManager()


@app.websocket("/chat/{client_id}")
async def chat(websocket: WebSocket, client_id: int):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_text()
            await manager.send_personal_message(f"You wrote: {data}", websocket)
            await manager.broadcast(f"Client #{client_id} says: {data}")
    except WebSocketDisconnect:
        manager.disconnect(websocket)
        await manager.broadcast(f"Client #{client_id} left the chat")


@app.get("/chat-count")
async def chat_count():
    return {"active": len(manager.active_connections)}


@app.websocket("/ws-boom")
async def ws_boom(websocket: WebSocket):
    # Raises after its accept: the socket must close with 1011, never the
    # 1000 that tells the client all went well (SPEC L24), and the
    # traceback must reach the log (L23).
    await websocket.accept()
    raise RuntimeError("fastapi-demo ws kaboom")
