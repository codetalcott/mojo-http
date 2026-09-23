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
"""

from fasthtml.common import (
    H1, Div, EventStream, P, Titled, fast_app, sse_message,
)
from starlette.background import BackgroundTask
import asyncio

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
