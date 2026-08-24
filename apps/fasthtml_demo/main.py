"""A minimal FastHTML app: the flagship ASGI row.

FastHTML is Starlette-based ASGI, so this is served as `main:app` (FastHTML
convention — note m0serve's ATTR otherwise defaults to `application`):

    bin/m0serve main:app --app-dir apps/fasthtml_demo --port 8097

`poe smoke-fasthtml` runs it and skips cleanly when python-fasthtml is not
installed, the same arrangement as the Flask row. `/` and `/plain` work under
the buffered ASGI bridge today; `/sse` is an infinite EventStream, which the
buffered bridge refuses with an explanatory 500 — it exists so the smoke can
pin that refusal now and the streaming behavior later.
"""

from fasthtml.common import (
    H1, Div, EventStream, P, Titled, fast_app, sse_message,
)
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
