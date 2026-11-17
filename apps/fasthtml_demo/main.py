"""A minimal FastHTML app: the flagship ASGI row.

FastHTML is Starlette-based ASGI, so this is served as `main:app` (FastHTML
convention — note m0serve's ATTR otherwise defaults to `application`):

    bin/m0serve main:app --app-dir apps/fasthtml_demo --port 8097

`poe smoke-fasthtml` runs it and skips cleanly when python-fasthtml is not
installed, the same arrangement as the Flask row. `/` and `/plain` work under
the buffered ASGI bridge today; `/sse` is an infinite EventStream, which the
buffered bridge refuses with an explanatory 500 — it exists so the smoke can
pin that refusal now and the streaming behavior later.

`/bg` answers a page with a `BackgroundTask` that sleeps 2 s: the response
must arrive at once and the task run after it (SPEC L22), where the
executor used to hold the response for the whole 2 s. `/bg-log` says whether
it has run. `/boom` raises: Starlette's own 500 is what the client must get,
and the traceback is what the log must get (L23), where the executor used to
answer "Failed to process request" and log one line.

`/live` and `/announce` are the page's recipe for a broadcast across
workers (L38): the block between the `# recipe` markers is what
docs/FASTHTML.md shows, and `check-docs` compares the two.
"""

from fasthtml.common import (
    H1, Div, EventStream, P, Titled, fast_app, serve, sse_message,
)
from starlette.background import BackgroundTask
from starlette.responses import PlainTextResponse
import asyncio
import threading

app, rt = fast_app()


@rt("/")
def get():
    return Titled(
        "FastHTML on mojo-http",
        Div(
            H1("m0serve-fasthtml-demo"),
            P("A FastHTML page served by m0serve's ASGI bridge."),
        ),
    )


@rt("/plain")
def plain():
    return "plain text from fasthtml"


_KEPT = threading.local()


@rt("/thread-kept")
def thread_kept():
    # A `def` handler, as FastHTML's tutorial writes them: it runs on
    # Starlette's thread pool. The answer is how many requests THIS thread
    # has served, so it passes 1 only if the pool's threads outlive a
    # request (SPEC L37).
    _KEPT.n = getattr(_KEPT, "n", 0) + 1
    return PlainTextResponse(str(_KEPT.n))


async def _counter():
    n = 0
    while True:
        yield sse_message(Div(f"tick {n}"))
        n += 1
        await asyncio.sleep(0.05)


@rt("/sse")
async def sse():
    return EventStream(_counter())


BG = []


async def _slow_record(tag):
    await asyncio.sleep(2.0)
    BG.append(tag)


@rt("/bg")
def bg():
    # A response with background work: answered at its final body, the
    # work running after it (SPEC L22). It used to be held for the 2 s.
    return P("queued"), BackgroundTask(_slow_record, "done")


@rt("/bg-log")
def bg_log():
    return ",".join(BG) or "empty"


@rt("/boom")
def boom():
    # Starlette's ServerErrorMiddleware answers a finished 500, then
    # re-raises: that 500 is what the client gets, and the traceback is
    # what the log gets (SPEC L23).
    raise ValueError("fasthtml-demo kaboom")


@app.ws("/ws")
async def ws(msg: str, send):
    await send(f"ws-echo:{msg}")


# recipe: every-worker -- docs/FASTHTML.md shows these lines verbatim, and
# `compare.py --check-page` fails when the two differ.
def bus(scope):
    return (scope.get("state") or {}).get("m0")  # None under uvicorn


listeners = {}  # this worker's sockets, each with the task that feeds it


async def forward(m0, send):
    async with m0.subscribe("live") as frames:
        async for _id, payload in frames:
            await send(payload.decode())


async def live_connect(ws, send):
    m0 = bus(ws.scope)
    if m0:
        listeners[id(ws)] = asyncio.create_task(forward(m0, send))


async def live_disconnect(ws):
    task = listeners.pop(id(ws), None)
    if task:
        task.cancel()


@app.ws("/live", conn=live_connect, disconn=live_disconnect)
async def live(msg: str, send):
    pass


@rt("/announce")
async def announce(req, text: str):
    m0 = bus(req.scope)
    if m0:
        m0.publish("live", text)  # to every worker, this one included
    return "ok"
# /recipe


@rt("/live-here")
def live_here():
    # How many /live sockets THIS worker holds. smoke-fasthtml reads it to
    # know its clients sit on more than one worker before it counts what
    # each received (SPEC L38).
    return PlainTextResponse(str(len(listeners)))


# What every FastHTML tutorial ends with. It starts uvicorn only when this
# file is run as a script; imported by m0serve it must do nothing, which
# smoke-fasthtml holds by serving this module (docs/FASTHTML.md).
serve()
