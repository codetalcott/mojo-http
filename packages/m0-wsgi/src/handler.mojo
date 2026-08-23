"""`WSGIHandler` — the `HTTPService` that serves one WSGI application.

The whole integration between the server and a WSGI application is one
field and one call: hold a `WSGIApp`, delegate every request to it. Three
example apps in this repo carried that handler as identical copies; this is
the one copy, and `m0serve` is the binary that runs it.

Static mounts come first. A request under a mounted prefix is answered by
`StaticFiles` in Mojo — with type, ETag revalidation, ranges, and whatever
`Cache-Control` the deployment chose — and never enters Python. That is the
WhiteNoise/nginx replacement claim, and it is why a slow view queue cannot
delay a stylesheet. Mounts are a `List`, not an `Optional`: `StaticFiles`
has an explicit copy constructor rather than `ImplicitlyCopyable`, which is
what `Optional` requires, and a list of zero or more mounts is the more
honest shape anyway.

`--realtime` adds the hold machinery `apps/django_realtime` carried in its
own `server.mojo`: two `SSERegistry`s (streams and sockets, holding disjoint
slots), `take_hold` on every application response, the WebSocket handshake
the application cannot perform for itself, and `ws_message_request` to give
an inbound frame the shape of a `POST`. Off by default, because it is not
free and not always wanted — it costs two slot arrays, and it makes
`M0-Hold` a header the server *consumes* rather than one an application may
emit for its own purposes. `--health-path` is opt-in for the mirror-image
reason: an application may already route `/health`, and a server that took
the path silently would shadow it.

**Construct after `fork_all()`, never before.** The handler owns the
`WSGIApp`, whose construction is the process's first Python call, and a
forked copy of a live interpreter is not safe — see `WSGIApp`.
"""

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.c.process import getpid
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.websocket import (
    websocket_upgrade, encode_ws_frame, WS_OP_TEXT,
)

from m0_http import SSERegistry, StaticFiles, sse_data_payload

from .app import WSGIApp
from .cli import ServeOptions
from .hold import (
    take_hold, request_last_event_id, ws_message_request,
    HOLD_STREAM, HOLD_WEBSOCKET,
)
from .threaded import ThreadHandler, ThreadContext


comptime REALTIME_SLOTS = 1024
"""Registry capacity under `--realtime`; must cover the server's max connections.

Slots index the registries directly, so a slot the server can hand out and
the registry cannot hold is a subscription that silently does not happen.
"""

comptime WS_MESSAGE_PATH = "/ws/message"
"""Where an inbound WebSocket message is delivered inside the application.

A constant rather than a flag: it is one half of a contract with the
application's own urlconf, and the application half is not configurable
from here either.
"""


struct WSGIHandler(ThreadHandler):
    """Serve a WSGI application, with optional static mounts in front of it.

    Also a `ThreadHandler`: under `--threads N` each serving thread calls
    `make(ctx)` to build its own instance — and its own `WSGIApp` and bridge
    — on that thread, from the `ServeOptions` whose address is `ctx.user`.
    """

    var app: WSGIApp
    var mounts: List[StaticFiles]
    var streams: SSERegistry
    """Slots held open as SSE streams; capacity 0 unless `--realtime`."""
    var sockets: SSERegistry
    """Slots held open as WebSockets; capacity 0 unless `--realtime`.

    A second `SSERegistry` rather than a `WSHub`, for the reason
    `apps/django_realtime` recorded: a hub is one unfiltered room, and what a
    per-connection channel needs is a filter url, a redelivery filter and an
    outbox — which is what this is. The registry never cared whether the
    bytes in an outbox were an SSE event or an RFC 6455 frame. The two hold
    disjoint slots (a connection is one or the other), so every hook can
    simply ask both.
    """
    var realtime: Bool
    var health_path: String
    var thread_index: Int
    """Which serving thread owns this handler; -1 under prefork or alone.

    Reported as `x-thread` on every response when >= 0 — the `X-Worker`
    precedent, and what `smoke-threads` reads to prove connections spread.
    """

    def __init__(
        out self,
        var app: WSGIApp,
        var mounts: List[StaticFiles],
        realtime: Bool = False,
        var health_path: String = String(""),
    ):
        self.app = app^
        self.mounts = mounts^
        self.realtime = realtime
        self.health_path = health_path^
        self.thread_index = -1
        # Capacity 0 when the mode is off. Every `SSERegistry` method already
        # guards on `slot >= _capacity`, so the hooks below stay correct
        # unconditionally and a non-realtime deployment pays nothing for
        # them — no branch in the hot path, and no branch to get wrong.
        var slots = REALTIME_SLOTS if realtime else 0
        self.streams = SSERegistry(slots)
        self.sockets = SSERegistry(slots)

    @staticmethod
    def mounts_for(opts: ServeOptions) -> List[StaticFiles]:
        """The static mounts `opts` names, in order."""
        var mounts = List[StaticFiles]()
        for i in range(len(opts.static_prefixes)):
            mounts.append(
                StaticFiles(
                    opts.static_dirs[i], opts.static_prefixes[i],
                    cache_control=opts.static_cache_control,
                )
            )
        return mounts^

    @staticmethod
    def for_options(var app: WSGIApp, opts: ServeOptions) raises -> Self:
        """The handler `opts` describes, around an already-built `WSGIApp`."""
        return Self(
            app^, Self.mounts_for(opts), opts.realtime, opts.health_path
        )

    @staticmethod
    def make(ctx: ThreadContext) raises -> Self:
        """Build this thread's handler from the `ServeOptions` at `ctx.user`.

        The module was imported on the main thread before any thread
        existed, so `WSGIApp` here is a `sys.modules` hit plus a fresh shim
        namespace; `project_path` is left empty for that reason (the path is
        already on `sys.path`, and appending it again per thread would only
        grow the list).

        Under `--realtime` the registries are per-thread too, which is the
        whole point: a held connection belongs to the loop that accepted it,
        and so does its outbox. Fan-out between threads is the same
        `BroadcastBus` prefork uses — a socketpair does not care whether the
        peer is a process or a thread.
        """
        var opts = Pointer[ServeOptions, MutUntrackedOrigin](
            unsafe_from_address=ctx.user
        )
        var app = WSGIApp(
            opts[].module,
            server_name=opts[].host,
            server_port=String(opts[].port),
            attribute=opts[].attribute,
            multiprocess=False,
            multithread=True,
        )
        var handler = Self.for_options(app^, opts[])
        handler.thread_index = ctx.index
        return handler^

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        # Static assets first: answered in Mojo, never entering Python, so a
        # slow view queue cannot delay a stylesheet.
        for i in range(len(self.mounts)):
            var hit = self.mounts[i].serve(req)
            if hit:
                return hit.take()

        if (
            self.health_path.byte_length() > 0
            and req.uri.path == self.health_path
        ):
            return self._health()

        if not self.realtime:
            return self.app.serve(req)

        var slot = req.slot_id
        var resp = self.app.serve(req)
        var hold = take_hold(resp)

        if hold.mode == HOLD_STREAM:
            if slot < 0:
                return _conflict()
            # A reconnecting client tells us where it left off; the
            # registry's delivery filter then declines to re-send what it
            # already has.
            self.streams.subscribe(
                slot, hold.channel, request_last_event_id(req)
            )
            resp.headers["x-worker"] = String(getpid())
            return resp^

        if hold.mode == HOLD_WEBSOCKET:
            if slot < 0:
                return _conflict()
            # The application approved the upgrade; performing it is ours.
            # The handshake reads the client's key off the ORIGINAL request
            # — a buffered, re-encoded WSGI response has no way to compute
            # the accept value, which is why approval and performance are
            # split at all.
            var upgraded = websocket_upgrade(req)
            if not upgraded:
                # Approved a WebSocket for a request that never asked for
                # one. Nothing to upgrade, and the app's body would be a lie.
                return _upgrade_required()
            var ws_resp = upgraded.take()
            if ws_resp.status_code != 101:
                # A malformed or wrong-version handshake: 400/426, verbatim.
                return ws_resp^
            ws_resp.headers["x-worker"] = String(getpid())
            # Same subscribe as the SSE branch, `Last-Event-ID` included: the
            # upgrade IS an HTTP GET, so one rule covers both transports.
            self.sockets.subscribe(
                slot, hold.channel, request_last_event_id(req)
            )
            return ws_resp^

        return resp^

    def _health(self) -> HTTPResponse:
        """Liveness, and under `--realtime` the live subscriber counts.

        Answered here rather than in the application on purpose: the counts
        are how a smoke asserts that a vanished client was actually
        unsubscribed, and they have to stay readable while a slow view has
        the interpreter busy.
        """
        var body = String('{"status":"ok"')
        if self.realtime:
            body += ',"subscribers":' + String(self.streams.active_count())
            body += ',"sockets":' + String(self.sockets.active_count())
        body += "}"
        return OK(body^, "application/json")

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        if self.thread_index >= 0:
            resp.headers["x-thread"] = String(self.thread_index)

    # --- Held connections. Inert at capacity 0, so no `realtime` branch. ---

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
        # Every published frame arrives here — from peer workers or threads
        # AND from this one's own application, because `m0pub` writes every
        # channel, ours included. `url` is the channel name.
        self.streams.notify_frame(url, event_id, frame)
        if self.sockets.has_subscribers(url):
            # The bus carries SSE frames; a socket needs an RFC 6455 frame.
            # Translating at delivery rather than publishing twice keeps ONE
            # frame per publish on the wire and gives both transports the
            # same payload — `sse_data_payload` returns exactly what an
            # `EventSource` would hand to `onmessage`.
            var data = sse_data_payload(Span(frame))
            self.sockets.notify_frame(
                url, event_id, encode_ws_frame(WS_OP_TEXT, Span(data))
            )

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        # An inbound message, handed to a plain synchronous view as a POST.
        # This runs ON the event loop thread, so it costs exactly what any
        # other view costs — the hold pattern removes the *connection* cost
        # from Python, not the *request* cost.
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
