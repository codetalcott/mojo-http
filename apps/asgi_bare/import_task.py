"""An application that schedules asyncio work at import.

FastHTML's first official example (``00_game_of_life``) starts its
background loop this way. m0serve imports an application outside any
running event loop, as uvicorn does without ``--reload``, so
``asyncio.create_task`` raises ``RuntimeError: no running event loop``.
``smoke-asgi`` asserts that the load is refused BY NAME, with the fix (a
lifespan startup handler), from the server and from ``--doctor`` alike
(SPEC L26).
"""

import asyncio


async def _tick():
    while True:
        await asyncio.sleep(1)


_task = asyncio.create_task(_tick())


async def app(scope, receive, send):
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"loaded"})
