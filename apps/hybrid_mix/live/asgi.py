"""The async half of the mounted pair: a FastHTML application.

Mounted at a prefix beside a synchronous Django project, and served by the
asyncio executor while Django's requests go to handler-pool threads — one
process, one listener, one shutdown, each application in the concurrency
model it was written for.

FastHTML is Starlette underneath, so `root_path` is all it needs to build
links under the mount; ASGI hands it the WHOLE path and the framework
strips the prefix itself, which is the half of the mount contract WSGI
does the other way round.
"""

import asyncio
import json

from fasthtml.common import FastHTML, Response


app = FastHTML()


@app.get("/")
def home():
    return "hello from fasthtml on mojo-http"


@app.get("/where")
def where(request):
    """The scope-fidelity probe, the ASGI twin of the Django mount's."""
    scope = request.scope
    return Response(
        json.dumps(
            {
                "root_path": scope.get("root_path", ""),
                # ASGI's `path` INCLUDES root_path -- if this came back
                # trimmed, every framework that strips the prefix itself
                # would route the wrong thing.
                "path": scope.get("path", ""),
                "url_path_for_where": str(request.url_for("where")),
            }
        ),
        media_type="application/json",
    )


@app.get("/sse")
async def sse():
    """A live EventStream, so the smoke can hold streams open on TWO async
    mounts at once — the shared chunk channel and per-lane credit under
    real concurrency."""
    from fasthtml.common import EventStream

    async def gen():
        import asyncio

        for i in range(6):
            yield f"data: live-{i}\n\n"
            await asyncio.sleep(0.15)
        yield "data: live-done\n\n"

    return EventStream(gen())


@app.get("/big")
async def big():
    """256 KB streamed with no sleeps -- four credit windows, the ack-routing
    proof on THIS lane while /live/big proves the other."""
    from fasthtml.common import StreamingResponse

    async def gen():
        block = b"L" * 32768
        for _ in range(8):
            yield block

    return StreamingResponse(gen(), media_type="application/octet-stream")


@app.get("/await")
async def slow(ms: int = 300):
    """Awaits, so the executor can overlap it with everything else."""
    await asyncio.sleep(ms / 1000)
    return f"awaited {ms}ms"
