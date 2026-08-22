"""Serve a sync Django project with live SSE and WebSockets — no ASGI anywhere.

    uv run poe serve-django-realtime                  # http://localhost:8080
    M0_WORKERS=2 uv run poe serve-django-realtime     # cross-worker fan-out

The composition `apps/django_wsgi`, `apps/datastar_counter` and `apps/ws_chat`
each show part of: one handler holds a `WSGIApp`, an SSE registry and a
WebSocket registry. Django runs every request synchronously, exactly as in
`django_wsgi` — and when a view answers with `M0-Hold` + `M0-Channel`,
`take_hold` reports it and the handler holds the connection. Django decides
who may subscribe and to what (it can consult sessions, tokens, anything);
the Mojo layer owns the connection from then on — the handshake, heartbeats,
disconnect cleanup, fan-out.

Two hold modes, and the difference is instructive. `M0-Hold: stream` keeps
Django's response — its body becomes the head of the SSE stream. `M0-Hold:
websocket` cannot: the reply on the wire has to be a `101` with a
`Sec-WebSocket-Accept` computed from the client's key, and a WSGI response
is buffered and re-encoded before it leaves. So Django *approves* the
upgrade and the Mojo layer *performs* it. That is the whole trick by which
a synchronous framework gates a protocol it cannot speak — Pushpin's
WebSocket-over-HTTP, collapsed into one process.

Inbound WebSocket messages take the same trip in reverse: `ws_message` fires
on the event loop, `ws_message_request` gives the message the shape of a
`POST`, and a plain Django view handles it. Nothing about that view is
special — it is a synchronous function with `request.body` in its hands.

**Two registries, both `SSERegistry`.** `WSHub` (the `apps/ws_chat` shape) is
one unfiltered room: everything reaches every socket. Here Django assigns a
channel per connection, so what is needed is a per-slot filter url, a
redelivery filter and an outbox — which is exactly `SSERegistry`, and it
never cared whether the bytes in an outbox were an SSE event or an RFC 6455
frame. The registries hold disjoint slots (a connection is one or the other),
so the shared `sse_*` hooks just ask both.

Publishing never enters Mojo at all. `m0pub.py` writes complete SSE frames
as bus datagrams to every worker's inherited channel — including this one's,
whose event loop drains it into `sse_peer_frame` like any peer frame. That
is why `bus_read_fd` is passed even in single-worker mode: draining our own
channel IS local delivery; there is no second path to keep in sync. Frames
destined for WebSocket subscribers are re-encoded at delivery, per slot:
`sse_data_payload` recovers what a browser's `EventSource` would hand to
`onmessage`, and `encode_ws_frame` wraps it. One publish, one wire format on
the bus, both transports served identically.

Fork ordering marries all of it. Everything shared is created BEFORE the fork
(the listener, the bus, the `SharedAtomics` page the event ids come from —
and the `M0_BUS_WRITE_FDS` / `M0_SHARED_ID_ADDR` exports, which must precede
the fork so every worker's environment agrees, and must precede any Python
touch so every embedded interpreter is born seeing them). The first Python
call — constructing `WSGIApp` — stays AFTER the fork, per worker, because
forking a live CPython interpreter is unsafe.
"""

from std.os import getenv, setenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.c.process import getpid
from lightbug_http.connection import ListenConfig
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.websocket import (
    websocket_upgrade, encode_ws_frame, WS_OP_TEXT,
)

from m0_http import (
    AppConfig, SSERegistry, StaticFiles, WorkerSupervisor,
    install_shutdown_signals, exit_worker, sse_data_payload,
)
from m0_http.multiworker import SharedAtomics
from m0_wsgi import (
    WSGIApp, take_hold, request_last_event_id, ws_message_request,
    HOLD_STREAM, HOLD_WEBSOCKET,
)


comptime MAX_SLOTS = 1024
"""Must be at least the server's max connections: slots index the registries."""

comptime WS_MESSAGE_PATH = "/ws/message"
"""Where an inbound WebSocket message is delivered inside Django."""


struct RealtimeHandler(HTTPService):
    var app: WSGIApp
    var streams: SSERegistry
    var sockets: SSERegistry
    var static: StaticFiles

    def __init__(out self, var app: WSGIApp, var static: StaticFiles):
        self.app = app^
        self.static = static^
        self.streams = SSERegistry(MAX_SLOTS)
        self.sockets = SSERegistry(MAX_SLOTS)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        # Static assets are answered here, before the bridge: the other half
        # of the hybrid's pitch. Django never sees these requests, so a slow
        # view queue cannot delay a stylesheet — and WhiteNoise has nothing
        # left to do.
        var hit = self.static.serve(req)
        if hit:
            return hit.take()

        if req.uri.path == "/health":
            # Answered in Mojo, never enters Django: the live counts are how
            # the smokes assert that a vanished client is actually
            # unsubscribed, and they must stay readable while a slow view has
            # the interpreter busy.
            return OK(
                '{"status":"ok","subscribers":'
                + String(self.streams.active_count())
                + ',"sockets":'
                + String(self.sockets.active_count())
                + "}",
                "application/json",
            )

        var slot = req.slot_id
        var resp = self.app.serve(req)
        var hold = take_hold(resp)

        if hold.mode == HOLD_STREAM:
            if slot < 0:
                return _conflict()
            # A reconnecting client tells us where it left off; the registry's
            # delivery filter then declines to re-send what it already has.
            self.streams.subscribe(
                slot, hold.channel, request_last_event_id(req)
            )
            # Which worker holds this stream — the multi-worker smoke reads
            # this to prove its streams span workers before asserting that
            # one publish reaches all of them.
            resp.headers["x-worker"] = String(getpid())
            return resp^

        if hold.mode == HOLD_WEBSOCKET:
            if slot < 0:
                return _conflict()
            # Django approved the upgrade; performing it is ours. The
            # handshake reads the client's key off the ORIGINAL request —
            # Django never had a way to compute the accept value.
            var upgraded = websocket_upgrade(req)
            if not upgraded:
                # Approved a WebSocket for a request that never asked for
                # one. Nothing to upgrade, and Django's body would be a lie.
                return _upgrade_required()
            var ws_resp = upgraded.take()
            if ws_resp.status_code != 101:
                # A malformed or wrong-version handshake: 400/426, verbatim.
                return ws_resp^
            ws_resp.headers["x-worker"] = String(getpid())
            # Same subscribe as the SSE branch, `Last-Event-ID` included:
            # the upgrade IS an HTTP GET, so a client that knows where it left
            # off can say so, and one rule covers both transports. Browsers
            # never set it on a WebSocket, which is why the practical answer
            # is almost always 0.
            self.sockets.subscribe(
                slot, hold.channel, request_last_event_id(req)
            )
            return ws_resp^

        return resp^

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    # --- Held connections: the two registries are the whole implementation --
    #
    # A slot is in at most one of them, so every hook can simply ask both.

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        if self.sockets.is_slot_streaming(slot):
            return self.sockets.drain(slot)
        return self.streams.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.streams.is_slot_streaming(
            slot
        ) or self.sockets.is_slot_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.streams.unsubscribe(slot)
        self.sockets.unsubscribe(slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # Every published frame arrives here — from peer workers AND from
        # this worker's own Django (m0pub writes all channels, ours
        # included). `url` is the channel name.
        self.streams.notify_frame(url, event_id, frame)
        if self.sockets.has_subscribers(url):
            # The bus carries SSE frames; a socket needs an RFC 6455 frame.
            # Translating here rather than publishing twice keeps ONE frame
            # per publish on the wire and gives both transports the same
            # payload — `sse_data_payload` returns exactly what an
            # `EventSource` would hand to `onmessage`.
            var data = sse_data_payload(Span(frame))
            self.sockets.notify_frame(
                url, event_id, encode_ws_frame(WS_OP_TEXT, Span(data))
            )

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        # An inbound message, handed to a plain synchronous Django view as a
        # POST. This runs ON the event loop thread, so it costs exactly what
        # any other view costs — the hold pattern removes the *connection*
        # cost from Python, not the *request* cost.
        var channel = self.sockets.filter_url(slot)
        if channel.byte_length() == 0:
            return  # not a held socket of ours; nothing names its channel
        # The response is discarded: what the view does — publishing, writing
        # to a database — is the point, and a hold instruction here would
        # subscribe nothing (the synthetic request carries no slot).
        #
        # `ws_message` is the one hook the trait declares non-raising, so the
        # try is mandatory, not defensive: a raising view must not take the
        # socket, or the loop, down with it.
        try:
            var req = ws_message_request(
                WS_MESSAGE_PATH, channel, slot, opcode, Span(payload)
            )
            _ = self.app.serve(req)
        except e:
            print("ws_message: " + WS_MESSAGE_PATH + " raised: ", e)


def _conflict() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String(
            '{"error":"a held connection requires the non-blocking event loop"}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=409,
        status_text="Conflict",
    )


def _upgrade_required() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String(
            "This endpoint holds WebSocket connections — connect with a"
            " WebSocket client\n"
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=426,
        status_text="Upgrade Required",
    )


def main() raises:
    var config = AppConfig()
    var port = String(config.port)
    # Where `djangoproj` and `m0pub` live; see apps/django_wsgi for the rule.
    var project_path = getenv("M0_DJANGO_PROJECT", "apps/django_realtime")

    # Bind before forking; every worker accepts from this one socket.
    var listener = ListenConfig().listen(String("0.0.0.0:", port))

    # The bus and the id counter are created pre-fork so every worker
    # inherits every channel and addresses the same physical word — and
    # exported pre-fork, pre-Python, so every worker's embedded interpreter
    # is born with both variables already in its environment (CPython
    # snapshots the C environ at interpreter init).
    var bus = BroadcastBus(config.workers)
    var fds_csv = String("")
    for i in range(len(bus.write_fds)):
        if i > 0:
            fds_csv += ","
        fds_csv += String(bus.write_fds[i])
    _ = setenv("M0_BUS_WRITE_FDS", fds_csv, True)

    # One MAP_SHARED slot: the event id every publish takes a number from.
    # m0pub fetch-adds it through libm0core's C ABI, because Python has no
    # atomic read-modify-write over a raw address and a racy one would hand
    # two workers the same id.
    var shared = SharedAtomics(1)
    _ = setenv("M0_SHARED_ID_ADDR", String(shared.addr(0)), True)

    # Fork before touching Python — see the module docstring.
    var multiprocess = config.workers > 1
    var worker = 0
    if multiprocess:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()
        worker = supervisor.worker_index

    var app = WSGIApp(
        "djangoproj.wsgi",
        server_name="0.0.0.0",
        server_port=port,
        multiprocess=multiprocess,
        project_path=project_path,
    )
    # The static mount lives beside the Django project and is served by the
    # Mojo layer with a real freshness policy — Django's staticfiles pipeline
    # (and WhiteNoise) are simply not involved.
    var static = StaticFiles(
        project_path + "/static", "/static/",
        cache_control="public, max-age=3600",
    )
    var handler = RealtimeHandler(app^, static^)

    print("Starting Django realtime server on 0.0.0.0:" + port)
    var server = Server(config.server_config())
    # After fork_all — each worker arms its own pipe. See datastar_counter.
    var shutdown_fd = install_shutdown_signals()
    # bus_read_fd unconditionally, unlike datastar_counter: single-worker
    # publish delivery IS the bus (Python writes our channel; we drain it).
    server.serve_nonblocking(
        listener,
        handler,
        shutdown_read_fd=shutdown_fd,
        bus_read_fd=bus.read_fd(worker),
    )
    if multiprocess:
        exit_worker()
