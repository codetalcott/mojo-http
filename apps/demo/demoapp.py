"""The live demo at https://demo.m0serve.dev, in one file.

Open the page in two browser tabs and type in either: the other tab shows it
within the second, once over a held Server-Sent Events stream and once over a
WebSocket, side by side. Every view here is plain synchronous Django. None of
them streams anything -- a view APPROVES a connection by answering with two
response headers, `M0-Hold` and `M0-Channel`, and m0serve holds it from
there; `m0pub.publish()` from any view reaches every subscriber of the
channel on every worker process. This is the quickstart's shape
(QUICKSTART.md) with the two things a public page needs and a tutorial does
not:

- **Channels are namespaced per visitor.** A visitor's browser gets a random
  token in a cookie the first time it loads the page, and every hold and
  every publish is scoped to `demo/<token>`. Two tabs in one browser share
  the cookie and so the channel; strangers never do. The token is the whole
  access check, which is the point of the pattern: the view runs first, with
  the request in hand, and only what it approves is ever held.
- **Abuse limits, in the view.** Messages are capped in size (413) and in
  rate per visitor per worker (429, `Retry-After`), nothing is stored, a
  WebSocket upgrade from a foreign `Origin` is refused, and a binary frame
  is dropped. The limits are per worker process because the app keeps them
  in a dict: with two workers a visitor may get up to twice the nominal
  rate, which is fine for a demo and is said on the page.

Served by `m0serve demoapp:application --realtime --workers 2` (the deploy
CMD is in deploy/demo/Dockerfile; `poe serve-demo` runs the same thing from
the tree). Under gunicorn the same file serves, and the holds degrade to
short plain responses.
"""

import json
import os
import re
import secrets
import threading
import time
from collections import deque
from urllib.parse import urlsplit

import django
from django.conf import settings
from django.core.wsgi import get_wsgi_application
from django.http import HttpResponse, JsonResponse
from django.urls import path
from django.views.decorators.csrf import csrf_exempt

from m0serve import m0pub

# One cookie, one random token, one channel per visitor. The token is 128
# bits from `secrets`, so a stranger cannot guess a channel; the format is
# checked on every request so a hand-edited cookie cannot pick a channel
# name of its own (the server refuses its reserved `\x01` namespace anyway;
# this keeps the name short and printable on top).
COOKIE = "m0demo"
TOKEN = re.compile(r"^[0-9a-f]{32}$")
CHANNEL_PREFIX = "demo/"

# The limits. A message is a line of chat, not a document; the rate is per
# visitor per worker, and the app says so on the page.
MAX_MESSAGE_BYTES = 280
RATE_LIMIT = 30
RATE_WINDOW_S = 60.0

# Nothing here is signed -- no sessions, no forms with CSRF tokens -- so the
# key protects nothing and a constant is honest about it.
settings.configure(
    DEBUG=False,
    ALLOWED_HOSTS=["*"],
    ROOT_URLCONF=__name__,
    SECRET_KEY="demo-not-a-secret-nothing-is-signed",
)
django.setup()


def _m0serve_version():
    """The serving m0serve's version, from the installed wheel's metadata.

    From the source tree (`poe serve-demo`) the wheel is not installed and
    `m0serve` is a staged stub package, so this reads "development tree";
    the page and `/about` show whichever it is, and the deploy image is where
    the version line is asserted.
    """
    try:
        from importlib.metadata import PackageNotFoundError, version

        return version("m0serve")
    except Exception:  # noqa: BLE001 -- PackageNotFoundError, or no metadata module
        return "development tree"


M0SERVE_VERSION = _m0serve_version()


# --- the rate limiter --------------------------------------------------------
# A deque of timestamps per token, pruned on every touch, with the table
# itself swept now and then so a visitor who left does not stay in memory.
# Per process: under prefork each worker keeps its own, which is the "per
# worker" in the limit.

_rate_lock = threading.Lock()
_rate = {}
_rate_touches = 0
_notified = {}


def _over_limit(token, now=None):
    """Record one publish for `token`; True if it exceeded the window's budget.

    Returns (over, retry_after_seconds). The publish is not recorded when it
    is over, so a client that keeps hammering does not push its own window
    further out -- the oldest recorded publish ages out on schedule.
    """
    global _rate_touches
    now = time.monotonic() if now is None else now
    with _rate_lock:
        _rate_touches += 1
        if _rate_touches % 256 == 0:
            _sweep(now)
        stamps = _rate.setdefault(token, deque())
        while stamps and now - stamps[0] > RATE_WINDOW_S:
            stamps.popleft()
        if len(stamps) >= RATE_LIMIT:
            return True, max(1, int(RATE_WINDOW_S - (now - stamps[0])) + 1)
        stamps.append(now)
        return False, 0


def _sweep(now):
    for key in [k for k, v in _rate.items() if not v or now - v[-1] > RATE_WINDOW_S]:
        del _rate[key]
    for key in [k for k, v in _notified.items() if now - v > RATE_WINDOW_S]:
        del _notified[key]


def _notice_due(token, now=None):
    """Whether to tell a rate-limited WebSocket sender so, once per window.

    A refused HTTP publish gets its 429; a refused socket message has no
    response the sender sees, so the channel gets one notice per window
    instead of one per refused message -- the notice itself is a publish and
    must not be the thing the limit fails to bound.
    """
    now = time.monotonic() if now is None else now
    with _rate_lock:
        last = _notified.get(token)
        if last is not None and now - last < RATE_WINDOW_S:
            return False
        _notified[token] = now
        return True


# --- the views ---------------------------------------------------------------


def _token(request):
    """The visitor's token from the cookie, or None if absent or malformed."""
    value = request.COOKIES.get(COOKIE, "")
    return value if TOKEN.match(value) else None


def _channel(token):
    return CHANNEL_PREFIX + token


def _payload(kind, **fields):
    """One frame's data: a JSON object with a `type`, so both transports and
    every kind of event parse the same way in the page."""
    fields["type"] = kind
    fields["worker"] = os.getpid()
    return json.dumps(fields, separators=(",", ":"))


def _text_response(status, text):
    return HttpResponse(text + "\n", status=status, content_type="text/plain; charset=utf-8")


def index(request):
    """The page. Hands a new visitor their token; everything else is inline."""
    token = _token(request)
    fresh = token is None
    if fresh:
        token = secrets.token_hex(16)
    response = HttpResponse(PAGE.replace("__VERSION__", M0SERVE_VERSION)
                            .replace("__TOKEN__", token[:8])
                            .replace("__LIMIT__", str(RATE_LIMIT))
                            .replace("__BYTES__", str(MAX_MESSAGE_BYTES)),
                            content_type="text/html; charset=utf-8")
    if fresh:
        # A session cookie: the room lasts as long as the browser does, and
        # a returning visitor gets a fresh, empty one. SameSite=Lax is the
        # browser default and is what keeps a cross-site POST from carrying
        # it. Not `Secure`, so the same file works on http://localhost.
        response.set_cookie(COOKIE, token, samesite="Lax", httponly=False)
    response["Cache-Control"] = "no-store"
    response["Content-Security-Policy"] = (
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
        "connect-src 'self'; img-src data:; base-uri 'none'; frame-ancestors 'none'"
    )
    return response


def about(request):
    """What is serving, as JSON: the version line, machine-readable."""
    return JsonResponse({
        "m0serve": M0SERVE_VERSION,
        "django": django.get_version(),
        "worker": os.getpid(),
        "workers": len(m0pub.bus_write_fds()),
        "limits": {"messages_per_minute_per_worker": RATE_LIMIT,
                   "message_bytes": MAX_MESSAGE_BYTES, "stored": 0},
        "source": SOURCE_URL,
    })


def events(request):
    """Hold an SSE stream for this visitor's channel.

    An ordinary buffered response: `M0-Hold: stream` tells m0serve to keep
    the connection open, subscribed to the channel, with the body as the
    head of the stream -- here a `hello` event naming the worker that holds
    it, which is how the page can show it. Django's part ends when this
    returns. Without a token there is no channel to join, so: 403.
    """
    token = _token(request)
    if token is None:
        return _text_response(403, "no visitor cookie: open / first")
    head = "data: " + _payload("hello", transport="sse", version=M0SERVE_VERSION) + "\n\n"
    response = HttpResponse(head, content_type="text/event-stream")
    response["M0-Hold"] = "stream"
    response["M0-Channel"] = _channel(token)
    response["Cache-Control"] = "no-store"
    return response


def ws(request):
    """Approve a WebSocket for this visitor's channel.

    Same decision, other transport: WSGI cannot produce the 101, so the view
    does not try -- it answers `M0-Hold: websocket` and m0serve performs the
    RFC 6455 handshake. The body is discarded, so there is no `hello` here;
    the page shows "connected" and learns the worker from the first echo.

    The server makes no `Origin` check because it cannot know the policy,
    and this view authenticates with a cookie, which a page on any origin
    could get the browser to attach: so the policy is here. A browser always
    sends `Origin` on an upgrade; a non-browser client (the probe) sends
    none and is let through, having no cookie jar to be tricked with.
    """
    token = _token(request)
    if token is None:
        return _text_response(403, "no visitor cookie: open / first")
    origin = request.headers.get("Origin")
    if origin and urlsplit(origin).netloc.lower() != request.get_host().lower():
        return _text_response(403, "cross-origin WebSocket refused")
    response = HttpResponse("")
    response["M0-Hold"] = "websocket"
    response["M0-Channel"] = _channel(token)
    return response


@csrf_exempt
def ws_message(request):
    """One inbound WebSocket message, delivered by the server as a POST.

    The server reserves this path (a request for it from the network is
    answered 404 before Django sees it), synthesises the request in-process
    and carries the socket's channel in `M0-Channel` -- which this view
    trusts for that reason, and which is the visitor's channel because `ws`
    put it there. Rebroadcast, within the limits: every tab hears it, the
    sender's included. A refused message has no response the sender can see,
    so the first refusal in a window publishes one notice to the channel.
    """
    channel = request.headers.get("M0-Channel", "")
    if not channel.startswith(CHANNEL_PREFIX):
        return _text_response(400, "not a visitor channel")
    token = channel[len(CHANNEL_PREFIX):]
    if request.headers.get("M0-Opcode") != "1":
        return _text_response(415, "text frames only")
    if len(request.body) > MAX_MESSAGE_BYTES:
        if _notice_due(token):
            m0pub.publish(channel, _payload(
                "notice", text="message dropped: over %d bytes" % MAX_MESSAGE_BYTES))
        return _text_response(413, "message too long")
    over, retry_after = _over_limit(token)
    if over:
        if _notice_due(token):
            m0pub.publish(channel, _payload(
                "notice", text="slowing you down: %d messages a minute" % RATE_LIMIT))
        response = _text_response(429, "rate limited")
        response["Retry-After"] = str(retry_after)
        return response
    text = request.body.decode("utf-8", "replace")
    workers, event_id = m0pub.publish_with_id(
        channel, _payload("message", text=text, via="websocket",
                          slot=request.headers.get("M0-Slot", "")))
    return JsonResponse({"ok": True, "id": event_id, "workers": workers})


@csrf_exempt
def publish(request):
    """Publish from the page over plain HTTP: the SSE pane's send button.

    `m0pub.publish_with_id` is one `os.write` per worker and one atomic
    fetch-add for the event id. The channel is the visitor's own, from the
    cookie -- never from the request body, which is what keeps one visitor's
    publish out of another's tabs.
    """
    if request.method != "POST":
        return _text_response(405, "POST only")
    token = _token(request)
    if token is None:
        return _text_response(403, "no visitor cookie: open / first")
    text = request.POST.get("text", "")
    if len(text.encode("utf-8")) > MAX_MESSAGE_BYTES:
        return JsonResponse({"error": "message over %d bytes" % MAX_MESSAGE_BYTES}, status=413)
    over, retry_after = _over_limit(token)
    if over:
        response = JsonResponse({"error": "rate limited: %d messages a minute" % RATE_LIMIT,
                                 "retry_after": retry_after}, status=429)
        response["Retry-After"] = str(retry_after)
        return response
    workers, event_id = m0pub.publish_with_id(
        _channel(token), _payload("message", text=text, via="http"))
    return JsonResponse({"ok": True, "id": event_id, "workers": workers})


SOURCE_URL = "https://github.com/codetalcott/mojo-http/blob/main/apps/demo/demoapp.py"

PAGE = """<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>m0serve live demo</title>
<link rel="icon" href="data:,">
<style>
  :root { color-scheme: light dark; --fg: #1a1a1a; --bg: #fafaf7; --muted: #6b6b66; --line: #d8d8d2;
          --pane: #ffffff; --accent: #b3261e; --ok: #2f7d4f; --warn: #a15c00; --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #ecece8; --bg: #161616; --muted: #9a9a94; --line: #333330; --pane: #1f1f1e; --accent: #ff7b6e; --ok: #6fcf97; --warn: #f2b45c; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 1.5rem 1rem 3rem; background: var(--bg); color: var(--fg);
         font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 64rem; margin: 0 auto; }
  h1 { font-size: 1.6rem; margin: 0 0 .25rem; letter-spacing: -.01em; }
  h1 .zero { color: var(--accent); font-family: var(--mono); font-feature-settings: "zero"; }
  .lead { margin: 0 0 1.5rem; color: var(--muted); }
  .lead b { color: var(--fg); }
  .panes { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
  @media (max-width: 40rem) { .panes { grid-template-columns: 1fr; } }
  .pane { background: var(--pane); border: 1px solid var(--line); border-radius: .5rem; padding: 1rem; min-width: 0; }
  .pane h2 { font-size: 1rem; margin: 0 0 .25rem; display: flex; align-items: center; gap: .5rem; }
  .dot { width: .6rem; height: .6rem; border-radius: 50%; background: var(--muted); flex: none; }
  .dot.on { background: var(--ok); } .dot.off { background: var(--accent); }
  .status { font-size: .85rem; color: var(--muted); margin: 0 0 .75rem; min-height: 1.3em; }
  form { display: flex; gap: .5rem; margin: 0 0 .75rem; }
  input { flex: 1; min-width: 0; font: inherit; padding: .45rem .6rem; border: 1px solid var(--line); border-radius: .35rem; background: var(--bg); color: var(--fg); }
  button { font: inherit; padding: .45rem .9rem; border: 1px solid var(--line); border-radius: .35rem; background: var(--fg); color: var(--bg); cursor: pointer; }
  button:disabled { opacity: .5; cursor: default; }
  .how { font-size: .8rem; color: var(--muted); margin: 0 0 .75rem; font-family: var(--mono); }
  ul { list-style: none; margin: 0; padding: 0; max-height: 22rem; overflow-y: auto; }
  li { padding: .35rem 0; border-top: 1px solid var(--line); overflow-wrap: anywhere; }
  li .meta { display: block; font-size: .75rem; color: var(--muted); font-family: var(--mono); }
  li.notice { color: var(--warn); }
  li.notice .meta { color: var(--warn); }
  footer { margin-top: 1.5rem; font-size: .85rem; color: var(--muted); }
  footer p { margin: .35rem 0; }
  footer code { font-family: var(--mono); font-size: .85em; }
  a { color: inherit; }
</style>
<main>
  <h1>m<span class="zero">0</span>serve live demo</h1>
  <p class="lead"><b>Open this page in a second tab</b> and type in either pane, in either tab.
    Every pane in every tab shows it within the second. The left pane is a held Server-Sent Events stream,
    the right a WebSocket. Both were approved by an ordinary synchronous Django view answering with two
    response headers; the server holds the connection from there.</p>
  <div class="panes">
    <section class="pane" id="sse">
      <h2><span class="dot" id="sse-dot"></span>Server-Sent Events</h2>
      <p class="status" id="sse-status">connecting&hellip;</p>
      <form id="sse-form"><input id="sse-input" maxlength="__BYTES__" autocomplete="off" placeholder="say something (sent with fetch, received on the stream)"><button>send</button></form>
      <p class="how">new EventSource("/events") &middot; POST /publish</p>
      <ul id="sse-log"></ul>
    </section>
    <section class="pane" id="ws">
      <h2><span class="dot" id="ws-dot"></span>WebSocket</h2>
      <p class="status" id="ws-status">connecting&hellip;</p>
      <form id="ws-form"><input id="ws-input" maxlength="__BYTES__" autocomplete="off" placeholder="say something (sent and received on the socket)"><button>send</button></form>
      <p class="how">new WebSocket("/ws") &middot; ws.send(text)</p>
      <ul id="ws-log"></ul>
    </section>
  </div>
  <footer>
    <p>Served by <b>m0serve __VERSION__</b> on one small Fly.io machine, two worker processes, from
      <a href="https://github.com/codetalcott/mojo-http/blob/main/apps/demo/demoapp.py">one Python file</a>.
      A message published by one worker reaches tabs held by the other over the server's bus; each line says which worker published it.</p>
    <p>Your channel is <code>demo/__TOKEN__&hellip;</code>, from a cookie this browser was handed: tabs sharing it share the channel,
      and nobody else sees your messages. Limits: __LIMIT__ messages a minute per worker, __BYTES__ bytes each, nothing stored.</p>
    <p><a href="https://m0serve.dev/">Documentation</a> &middot; <a href="https://m0serve.dev/quickstart/">Quickstart</a> &middot;
      <a href="https://pypi.org/project/m0serve/">pip install m0serve</a></p>
  </footer>
</main>
<script>
(() => {
  const $ = id => document.getElementById(id);
  const MAX = 50;

  function line(pane, ev) {
    const log = $(pane + "-log");
    const li = document.createElement("li");
    const meta = document.createElement("span");
    meta.className = "meta";
    if (ev.type === "notice") {
      li.className = "notice";
      li.textContent = ev.text;
      meta.textContent = "notice · worker " + ev.worker;
    } else {
      li.textContent = ev.text;
      meta.textContent = "via " + ev.via + " · published by worker " + ev.worker
        + (ev.id ? " · #" + ev.id : "") + " · " + new Date().toLocaleTimeString();
    }
    li.appendChild(meta);
    log.prepend(li);
    while (log.children.length > MAX) log.removeChild(log.lastChild);
  }

  function status(pane, on, text) {
    $(pane + "-dot").className = "dot " + (on === null ? "" : on ? "on" : "off");
    $(pane + "-status").textContent = text;
  }

  function parse(data) {
    try { return JSON.parse(data); } catch (e) { return { type: "message", text: data, via: "?", worker: "?" }; }
  }

  // --- Server-Sent Events: the browser reconnects on its own, sending
  // Last-Event-ID, and the server never re-sends what this tab has seen.
  const es = new EventSource("/events");
  es.onmessage = e => {
    const ev = parse(e.data);
    if (ev.type === "hello") { status("sse", true, "held by worker " + ev.worker + " · m0serve " + ev.version); return; }
    if (ev.id === undefined && e.lastEventId) ev.id = e.lastEventId;
    line("sse", ev);
  };
  es.onerror = () => status("sse", false, "reconnecting…");
  $("sse-form").onsubmit = async e => {
    e.preventDefault();
    const input = $("sse-input"), text = input.value.trim();
    if (!text) return;
    input.value = "";
    const r = await fetch("/publish", { method: "POST", body: new URLSearchParams({ text }) });
    if (!r.ok) {
      const body = await r.json().catch(() => ({ error: r.status + " " + r.statusText }));
      line("sse", { type: "notice", text: body.error, worker: "—" });
    }
  };

  // --- WebSocket: the socket is held by the server; what this tab sends
  // reaches a Django view as a POST, which rebroadcasts it to every tab.
  let ws, backoff = 500;
  function connect() {
    const scheme = location.protocol === "https:" ? "wss://" : "ws://";
    ws = new WebSocket(scheme + location.host + "/ws");
    ws.onopen = () => { backoff = 500; status("ws", true, "connected · the first echo names the worker holding it"); };
    ws.onmessage = e => {
      const ev = parse(e.data);
      if (ev.type === "hello") return;
      if (ev.via === "websocket" && ev.slot !== undefined) status("ws", true, "connected · slot " + ev.slot + " on worker " + ev.worker + " answered a message");
      line("ws", ev);
    };
    ws.onclose = () => { status("ws", false, "reconnecting…"); setTimeout(connect, backoff); backoff = Math.min(backoff * 2, 8000); };
    ws.onerror = () => ws.close();
  }
  connect();
  $("ws-form").onsubmit = e => {
    e.preventDefault();
    const input = $("ws-input"), text = input.value.trim();
    if (!text) return;
    input.value = "";
    if (ws.readyState === WebSocket.OPEN) ws.send(text);
    else line("ws", { type: "notice", text: "socket not open; reconnecting", worker: "—" });
  };
})();
</script>
</html>
"""

urlpatterns = [
    path("", index),
    path("about", about),
    path("events", events),
    path("ws", ws),
    path("ws/message", ws_message),
    path("publish", publish),
]

application = get_wsgi_application()
