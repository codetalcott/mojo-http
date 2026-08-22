"""Routes for the realtime example.

Every view here is plain synchronous Django — no ASGI, no Channels, no
async. The realtime behaviour comes from the server: `/events` answers with
hold headers that the Mojo layer converts into a live SSE subscription, and
`/publish` writes frames onto the server's broadcast bus through `m0pub`.

Run the same project under gunicorn and nothing errors: `/events` serves a
short buffered response (the hold headers reach the client, who ignores
them... which is why the Mojo layer strips them) and `/publish` reports
`workers: 0`. The views degrade instead of breaking — the GRIP property.
"""

import os

from django.http import HttpResponse, JsonResponse
from django.urls import path

import m0pub

# The demo's "auth": real apps put sessions, tokens, or object permissions
# here. What matters is that the decision runs in Django, per request, with
# everything Django knows — the server only ever holds what Django approved.
TOKEN = "letmein"


def index(request):
    return HttpResponse(
        "django_realtime — sync Django, live SSE.\n"
        "\n"
        "  GET  /events?channel=news&token=letmein   subscribe (SSE)\n"
        "  POST /publish  channel=news msg=hello     broadcast to subscribers\n",
        content_type="text/plain",
    )


def events(request):
    """Subscribe this connection to a channel — by answering with headers.

    The response below is an ordinary buffered Django response. The Mojo
    handler sees `M0-Hold: stream`, strips both instruction headers, keeps
    the body as the head of the stream, and subscribes the connection to the
    channel. Django's part in the connection ends here; the server holds it
    from now on.
    """
    if request.GET.get("token") != TOKEN:
        return HttpResponse("forbidden\n", status=403, content_type="text/plain")

    channel = request.GET.get("channel", "news")
    response = HttpResponse(": connected\n\n", content_type="text/event-stream")
    response["M0-Hold"] = "stream"
    response["M0-Channel"] = channel
    return response


def publish(request):
    """Broadcast a message to every subscriber of a channel, on every worker.

    `m0pub.publish` is one `os.write` per worker — no Mojo call. The count it
    returns is worker channels written, not subscribers reached: delivery to
    individual connections is the server's business (and is best-effort under
    backpressure, like any fan-out).
    """
    if request.method != "POST":
        return HttpResponse("POST only\n", status=405, content_type="text/plain")

    channel = request.POST.get("channel") or request.GET.get("channel") or "news"
    msg = request.POST.get("msg") or request.GET.get("msg") or ""
    workers = m0pub.publish(channel, msg, event="message")
    return JsonResponse({"channel": channel, "workers": workers, "pid": os.getpid()})


urlpatterns = [
    path("", index),
    path("events", events),
    path("publish", publish),
]
