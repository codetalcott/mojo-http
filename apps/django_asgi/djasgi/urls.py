"""Async Django views, each pinning one clause of the ASGI contract.

`/meta` is the reason this row exists. Django's `ASGIRequest.__init__`
populates REMOTE_ADDR, REMOTE_HOST and REMOTE_PORT only
`if self.scope.get("client")` -- nothing errors when the server sends
`client: None`, the visitor is simply address-less, which silently
disables rate limits, IP allow-lists and audit logs. The smoke asserts a
real address here, and the assertion was verified load-bearing against a
server that sends None.
"""

import asyncio
import json

from django.http import HttpResponse, StreamingHttpResponse
from django.urls import path


async def hello(request):
    return HttpResponse("hello from django-asgi on mojo-http", content_type="text/plain")


async def meta(request):
    return HttpResponse(
        json.dumps(
            {
                "remote_addr": request.META.get("REMOTE_ADDR", ""),
                "remote_port": request.META.get("REMOTE_PORT", ""),
                "scheme": request.scheme,
                "server": request.META.get("SERVER_NAME", ""),
                "path": request.path,
            }
        ),
        content_type="application/json",
    )


async def slow(request):
    """Awaits, so N of these must overlap on the executor's one loop."""
    ms = int(request.GET.get("ms", "300"))
    await asyncio.sleep(ms / 1000)
    return HttpResponse("slept %d" % ms, content_type="text/plain")


async def stream(request):
    """A StreamingHttpResponse over an async generator: Django's own
    streaming shape, riding the executor's chunk channel."""

    async def gen():
        for i in range(5):
            yield ("data: tick-%d\n\n" % i).encode()
            await asyncio.sleep(0.15)
        yield b"data: tick-done\n\n"

    return StreamingHttpResponse(gen(), content_type="text/event-stream")


async def session_bump(request):
    """The cookie round trip: the counter cannot advance unless Set-Cookie
    reaches the client AND Cookie reaches Django -- both directions."""
    count = request.session.get("count", 0) + 1
    request.session["count"] = count
    return HttpResponse("count=%d" % count, content_type="text/plain")


urlpatterns = [
    path("", hello),
    path("meta", meta),
    path("slow", slow),
    path("stream", stream),
    path("session/bump", session_bump),
]
