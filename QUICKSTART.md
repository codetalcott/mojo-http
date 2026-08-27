# Quickstart: live updates from plain sync Django

Ten minutes, one file, one process: a synchronous Django app whose browser
tabs stay in sync — Server-Sent Events and WebSockets held by the server,
no Channels, no Redis, no daphne, no second process.

The trick is that your views never stream anything. A plain sync view
*approves* a connection by answering with two response headers, and m0serve
holds it from there; `m0pub.publish()` from any view reaches every
subscriber on every worker. Django keeps what it is good at — auth,
sessions, the decision — and hands the connection to the server.

Works on macOS arm64 and Linux x86_64/aarch64, CPython 3.10–3.14. No Mojo
toolchain involved.

> Every command below is copy-paste runnable, and this file is executable:
> CI extracts the fenced blocks and runs them against every pull request
> (`poe smoke-quickstart`), so if you can read it, it works.

## 1. Install

```bash setup
mkdir -p m0serve-quickstart && cd m0serve-quickstart
python3 -m venv .venv
source .venv/bin/activate
pip install --quiet m0serve django
m0serve --version
```

```text
m0serve 0.13.0
```

## 2. The app — one file

Everything lives in `realtime.py`: settings, four views, a page. The two
views that matter are `events` and `ws` — each is an ordinary sync view
that returns an ordinary buffered response, plus the two `M0-` headers.

```bash setup
cat > realtime.py <<'PY'
"""Live updates from plain sync Django, served by m0serve."""
import django
from django.conf import settings
from django.core.wsgi import get_wsgi_application
from django.http import HttpResponse, JsonResponse
from django.urls import path
from django.views.decorators.csrf import csrf_exempt

from m0serve import m0pub

settings.configure(
    DEBUG=False,
    ALLOWED_HOSTS=["*"],
    ROOT_URLCONF=__name__,
    SECRET_KEY="quickstart-not-a-secret",
)
django.setup()

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>m0serve quickstart</title>
<style>body{font:16px system-ui;margin:2rem auto;max-width:32rem}</style>
<h1>live channel: news</h1>
<form id="f"><input id="m" autocomplete="off" placeholder="say something">
<button>send</button></form>
<ul id="log"></ul>
<script>
const ws = new WebSocket(`ws://${location.host}/ws?channel=news`);
ws.onmessage = e => {
  const li = document.createElement("li");
  li.textContent = e.data;
  document.getElementById("log").prepend(li);
};
document.getElementById("f").onsubmit = e => {
  e.preventDefault();
  const m = document.getElementById("m");
  ws.send(m.value);
  m.value = "";
};
</script>"""


def index(request):
    return HttpResponse(PAGE)


def events(request):
    # An ordinary buffered response. `M0-Hold: stream` tells m0serve to keep
    # this connection open and subscribe it to the channel; the body becomes
    # the head of the stream. Django's part in the connection ends here --
    # and this is where your real auth goes, because the view runs first,
    # with sessions and permissions in hand. Under gunicorn the headers are
    # ignored and the view degrades to a short plain response.
    response = HttpResponse(": connected\n\n", content_type="text/event-stream")
    response["M0-Hold"] = "stream"
    response["M0-Channel"] = request.GET.get("channel", "news")
    return response


def ws(request):
    # The same decision, a different transport. WSGI cannot produce the 101
    # handshake a WebSocket needs, so the view does not try: it APPROVES the
    # upgrade, and m0serve performs the RFC 6455 handshake it cannot.
    response = HttpResponse("")
    response["M0-Hold"] = "websocket"
    response["M0-Channel"] = request.GET.get("channel", "news")
    return response


@csrf_exempt
def ws_message(request):
    # Each inbound WebSocket message arrives here as a plain POST -- a sync
    # view with request.body in its hands. Rebroadcast it: every subscriber
    # of the channel hears it, WebSocket clients as frames, SSE clients as
    # events, on every worker, the sender included.
    channel = request.headers.get("M0-Channel", "news")
    m0pub.publish(channel, request.body.decode("utf-8", "replace"))
    return JsonResponse({"ok": True})


@csrf_exempt
def publish(request):
    # Publishing is one os.write per worker plus one atomic fetch-add for
    # the event id -- no server API, no connection, callable from any view,
    # management command, or cron job.
    workers, event_id = m0pub.publish_with_id(
        request.POST.get("channel", "news"), request.POST.get("msg", "")
    )
    return JsonResponse({"workers": workers, "id": event_id})


urlpatterns = [
    path("", index),
    path("events", events),
    path("ws", ws),
    path("ws/message", ws_message),
    path("publish", publish),
]

application = get_wsgi_application()
PY
```

## 3. Serve it

```bash serve
m0serve realtime:application --realtime --health-path /health --port 8000
```

`--realtime` is the whole feature: it turns the `M0-` headers into held
connections and wires the publish bus. Leave it off and the same app still
serves — the holds just degrade to short responses.

## 4. Verify — the same checks CI runs

Wait for the server, subscribe a client, publish, and watch the event
arrive on the held connection:

```bash verify
curl -sf --retry 20 --retry-delay 1 --retry-all-errors http://127.0.0.1:8000/health > /dev/null
echo "server is up"

curl -sN --max-time 6 "http://127.0.0.1:8000/events?channel=news" > stream.txt &
sleep 1

curl -s -X POST -d channel=news -d msg="hello from curl" http://127.0.0.1:8000/publish
echo

for i in $(seq 1 25); do
  grep -q "data: hello from curl" stream.txt 2>/dev/null && break
  sleep 0.2
done
grep "data: hello from curl" stream.txt
FIRST_ID=$(grep -oE "^id: [0-9]+" stream.txt | head -1 | cut -d' ' -f2)
test -n "$FIRST_ID"
echo "SSE delivery verified (event id $FIRST_ID)"
```

```text
{"workers": 1, "id": 1}
data: hello from curl
SSE delivery verified (event id 1)
```

The `id:` line is not decoration: every publish takes a globally unique
number from a shared atomic, so a client that reconnects with
`Last-Event-ID` is never re-sent what it already has.

## 5. The part you came for

Open <http://127.0.0.1:8000/> in **two browser tabs** and type in either.
Both update instantly. The page is a WebSocket client; the `curl` above was
SSE; a `publish` from any view reaches both transports at once — and all of
it gated by synchronous Django views.

## 6. Scale out — one publish, every worker

Stop the server (Ctrl-C) and restart with workers. Publishing from a view
on any worker reaches subscribers on every worker: the bus and the shared
id counter are created *before* the fork, so ids stay unique across all of
a server's workers with no coordination in your code. (They belong to the
server's lifetime — a fresh server numbers from 1 again, which is why
`Last-Event-ID` replay is scoped to a running server, not to history.)

```bash serve
m0serve realtime:application --realtime --workers 2 --health-path /health --port 8000
```

```bash verify
curl -sf --retry 20 --retry-delay 1 --retry-all-errors http://127.0.0.1:8000/health > /dev/null

curl -sN --max-time 6 "http://127.0.0.1:8000/events?channel=news" > stream2.txt &
sleep 1

RESPONSE=$(curl -s -X POST -d channel=news -d msg="hello every worker" http://127.0.0.1:8000/publish)
echo "$RESPONSE"
echo "$RESPONSE" | grep -q '"workers": 2'

for i in $(seq 1 25); do
  grep -q "data: hello every worker" stream2.txt 2>/dev/null && break
  sleep 0.2
done
grep "data: hello every worker" stream2.txt

SECOND_ID=$(grep -oE "^id: [0-9]+" stream2.txt | head -1 | cut -d' ' -f2)
test -n "$SECOND_ID"
echo "cross-worker delivery verified (2 workers, event id $SECOND_ID)"
```

## In your real project

The whole integration is what you just read: two headers on a view that
approves a subscription, `m0pub.publish()` wherever something happens, and
`m0serve myproject.wsgi:application --realtime`. No settings changes, no
INSTALLED_APPS, no middleware, and the views degrade — not break — under
any other WSGI server.

The fuller demo, with token auth, channel isolation, and static files
served without entering Python, is
[`apps/django_realtime`](apps/django_realtime/) in the repository; its
behaviour is pinned by `smoke-django-realtime` and a raw RFC 6455 probe.

### Three things the server does not decide for you

The hold pattern moves the *connection* out of Python, not the
*authorisation*. What that leaves you:

- **A view that approves a hold is the access check.** Nothing downstream
  re-asks. The demo above gates on a query token because it is a demo; use
  whatever your project already uses, and remember the view runs before the
  connection becomes a stream, which is exactly where you want the decision.
- **`publish()` reaches every subscriber of a channel, on every worker.**
  If the channel name comes from a request, so does the blast radius — an
  endpoint that publishes what it is told, to the channel it is told, is a
  fan-out primitive for whoever can reach it. The server refuses only its
  own reserved namespace (channels opening with a `\x01` byte, which
  address connection slots internally); everything else is your namespace
  to police.
- **A WebSocket handshake carries no `Origin` check.** The server does not
  make one, because it cannot know your policy. If you authenticate sockets
  with cookies, a page on any origin can open one and the browser will
  attach them — check `Origin` in the view that approves the upgrade, or
  authenticate with something a cross-site page cannot supply.

Inbound WebSocket messages arrive as a `POST` to `/ws/message`, and the
server reserves that path: a request for it from the network is answered
404 before Django sees it, so the view can treat what it receives as
genuinely server-synthesised. That reservation is why the view may be
`csrf_exempt` without it becoming an open endpoint.
