"""Routes for the realtime example.

Every view here is plain synchronous Django — no ASGI, no Channels, no
async. The realtime behaviour comes from the server: `/events` and `/ws`
answer with hold headers that the Mojo layer converts into a live
subscription, and `/publish` writes frames onto the server's broadcast bus
through `m0pub`.

`/ws` is the interesting one. Django cannot emit a `101 Switching
Protocols` — its response is buffered and re-encoded before it leaves the
process, and the handshake needs a `Sec-WebSocket-Accept` computed from the
client's key. So it does not try: it *approves* the upgrade with
`M0-Hold: websocket`, having run whatever auth it likes first, and the Mojo
handler performs the handshake. Inbound messages come back the other way, as
ordinary POSTs to `/ws/message`.

Run the same project under gunicorn and nothing errors: `/events` and `/ws`
serve short buffered responses (the hold headers reach the client, who
ignores them... which is why the Mojo layer strips them), `/publish` reports
`workers: 0`, and `/ws/message` is simply never called. The views degrade
instead of breaking — the GRIP property.
"""

import os

from django.http import HttpResponse, JsonResponse
from django.urls import path
from django.views.decorators.csrf import csrf_exempt

import m0pub

# The demo's "auth": real apps put sessions, tokens, or object permissions
# here. What matters is that the decision runs in Django, per request, with
# everything Django knows — the server only ever holds what Django approved.
TOKEN = "letmein"


def index(request):
    return HttpResponse(
        "django_realtime — sync Django, live SSE and WebSockets, Mojo-served static files.\n"
        "\n"
        "  GET  /events?channel=news&token=letmein   subscribe (SSE)\n"
        "  GET  /ws?channel=news&token=letmein       subscribe (WebSocket)\n"
        "  POST /publish  channel=news msg=hello     broadcast to both transports\n"
        "  GET  /static/app.css                      served in Mojo, never enters Python\n",
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


def websocket(request):
    """Gate a WebSocket connection — the same decision, a different hold.

    Identical in shape to `events`: check the request, name a channel, answer
    with instruction headers. What differs is what the server does with the
    answer. An SSE hold keeps this response and streams from it; a WebSocket
    hold *discards* it and replies `101` with a computed accept key instead,
    because that is the only thing a WebSocket client will accept and it is
    the one thing WSGI cannot produce.

    So this view never sees a frame, never blocks, and returns in
    microseconds — and yet the connection it approved is a real WebSocket,
    held for as long as the client keeps it, by a server this code has no
    reference to.
    """
    if request.GET.get("token") != TOKEN:
        return HttpResponse("forbidden\n", status=403, content_type="text/plain")

    channel = request.GET.get("channel", "news")
    response = HttpResponse("", content_type="text/plain")
    response["M0-Hold"] = "websocket"
    response["M0-Channel"] = channel
    return response


@csrf_exempt
def ws_message(request):
    """One inbound WebSocket message, delivered as a POST.

    The server synthesises this request in `ws_message_request`: the payload
    is the body, and three headers carry what HTTP has no room for — the
    channel the socket joined, which slot it is, and the RFC 6455 opcode.
    There is nothing else special about it. It is a synchronous view with
    `request.body` in its hands, and it may do anything a view may do.

    This one is a chat room: whatever one socket says, every subscriber of
    the channel hears — WebSocket clients as frames, `EventSource` clients as
    events, on every worker. Echoing to the sender included; their own
    message coming back is the delivery confirmation.

    CSRF-exempt because there is no browser session and no cookie here — the
    "client" is the server itself, on the far side of a connection Django
    already authorised at upgrade time.
    """
    channel = request.headers.get("M0-Channel", "")
    slot = request.headers.get("M0-Slot", "?")
    if not channel:
        return HttpResponse("no channel\n", status=400, content_type="text/plain")

    text = request.body.decode("utf-8", "replace")
    m0pub.publish(channel, text, event="message")
    return JsonResponse({"channel": channel, "slot": slot, "pid": os.getpid()})


def publish(request):
    """Broadcast a message to every subscriber of a channel, on every worker.

    `m0pub.publish_with_id` is one `os.write` per worker plus one atomic
    fetch-add — no Mojo call, nothing across the WSGI bridge. The counts it
    returns are worker channels written and the event id allocated, not
    subscribers reached: delivery to individual connections is the server's
    business (and is best-effort under backpressure, like any fan-out).

    The id is what makes redelivery suppression work. A client reconnecting
    with `Last-Event-ID: 12` is not re-sent event 12 — see
    `request_last_event_id` in `packages/m0-wsgi/src/hold.mojo`. It is -1
    when the server exported no shared counter, which is exactly what
    happens under a plain WSGI host.
    """
    if request.method != "POST":
        return HttpResponse("POST only\n", status=405, content_type="text/plain")

    channel = request.POST.get("channel") or request.GET.get("channel") or "news"
    msg = request.POST.get("msg") or request.GET.get("msg") or ""
    workers, event_id = m0pub.publish_with_id(channel, msg, event="message")
    return JsonResponse(
        {"channel": channel, "workers": workers, "id": event_id, "pid": os.getpid()}
    )


urlpatterns = [
    path("", index),
    path("events", events),
    path("ws", websocket),
    path("ws/message", ws_message),
    path("publish", publish),
]
