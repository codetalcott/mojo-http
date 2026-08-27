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

from lightbug_http.broadcast import encode_bus_frame
from lightbug_http import HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.c.process import getpid
from lightbug_http.utils.owning_list import OwningList
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.websocket import (
    websocket_upgrade, encode_ws_frame, WS_OP_TEXT,
)

from std.ffi import c_int, external_call

from m0_http import SSERegistry, StaticFiles, sse_data_payload
from m0_http.sse.format import NO_EVENT_ID

from .app import WSGIApp
from .cli import match_mount
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

comptime NOT_POOL_HELD = -2
"""`hold_lane` for a slot no pool thread's view is holding.

Not -1: that is the unmounted pool's own lane, and a sentinel a real lane
can equal would route an executor's socket into a pool."""

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

    var apps: OwningList[WSGIApp]
    """The mounted applications, parallel to `mount_prefixes`.

    Always at least one: a server with no `--mount` holds a single app at
    the empty prefix, so routing has one shape and the ordinary case is the
    degenerate mount rather than a separate path. `OwningList` because
    `WSGIApp` owns a bridge and is Movable but not Copyable — copying one
    would duplicate an interpreter handle.
    """
    var mount_prefixes: List[String]
    """Each app's prefix, stored without a trailing slash (`''` at the root).
    Longest match wins; see `match_mount` in `cli.mojo`, which is where the
    matching lives so it can be tested without an interpreter."""
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
    var asgi_done: List[Bool]
    """ASGI stream slots whose end frame arrived while bytes were still
    pending: the final `sse_drain_slot` hands those bytes out and then
    unsubscribes, which is what flips `sse_is_streaming` and lets the loop
    close the connection after they land."""
    var asgi_notify_fd: Int
    """Executor mode only (-1 otherwise): the submit channel's write end,
    used to send the executor a disconnect tag when a streaming slot
    closes — what resolves the app's `receive()` into `http.disconnect`
    and cancels its task."""
    var answers_local: Bool
    """Whether `before_request` answers static mounts and the health path.

    True on every handler that runs on an event loop — the process's own
    under prefork, each serving thread's under `--threads` — and False on a
    pool thread's. The loop calls `before_request` before it submits a job,
    so answering there keeps a stylesheet and `/health` readable whatever
    the pool is busy with, and gives the health path the registries the
    loop drains: a pool thread's own are always empty, and under
    `--realtime --blocking-threads` that reported zero subscribers while
    events were being delivered."""

    var mounted: Bool
    """Whether the SERVER hosts more than one application.

    From `opts`, never from `len(self.apps)`: a pool thread builds only its
    own mount (`only_mount`), so counting applications here would tell that
    handler it was unmounted. A WebSocket hold is refused when this is true
    — an inbound frame comes back as a synthesised POST into ONE urlconf
    (`ws_message` serves `apps[0]`), and which mount should receive it has
    no defensible answer. SSE holds have no inbound half and work on every
    mount."""

    var lane: Int
    """Which mount this handler serves (`ThreadContext.lane`), or -1.

    A pool thread stamps it into the reserved hold frame so the loop learns
    which lane a held socket belongs to, which is where its inbound messages
    have to go back to."""

    var ws_pool_fds: List[Int]
    """Loop side: each lane's pool submit write end, or -1.

    An inbound WebSocket message on a held socket is delivered to the mount
    whose view gated the upgrade — `hold_lane[slot]` names it, the frame
    that subscribed the socket carried it, and this is where it goes."""

    var hold_lane: List[Int]
    """Loop side: for a socket a POOL thread's view held, the lane it belongs
    to; `NOT_POOL_HELD` for every other slot.

    `-1` is a real lane (the unmounted pool), so the sentinel cannot be -1.
    It is what separates the three ways a socket can be held on one loop: by
    a pool thread's view (here), by an executor (a reserved filter url), or
    by the loop's own handler."""

    var hold_notify_fd: Int
    """Set on a `--blocking-threads` handler under `--realtime`: this loop's
    bus write end (`ThreadContext.hold_fd`). A hold taken on a pool thread
    is not subscribed here — this handler's registries are never drained by
    anything — but sent to the loop's handler as a reserved `h` frame, the
    executor's begin-frame seam applied to a second producer. -1 on the
    loop's own handler, whose registries are the ones that count."""

    var lane_notify_fds: List[Int]
    """Per-lane submit write ends, indexed by mount (`--mount` with more
    than one ASGI mount); -1 where a lane has no executor. A disconnect
    tag or an inbound WS message must reach the executor that owns the
    slot — its lane rides in the reserved channel name the executor
    subscribed with, so the lookup is a parse of the slot's own filter
    url, not a table this handler could let drift."""

    def __init__(
        out self,
        var app: WSGIApp,
        var mounts: List[StaticFiles],
        realtime: Bool = False,
        var health_path: String = String(""),
        asgi_streaming: Bool = False,
        var root_prefix: String = String(""),
    ):
        # capacity=1, never `OwningList[WSGIApp]()`: the no-argument form
        # constructs a null `Pointer`, which Mojo 1.0 refuses outright. One
        # slot is exactly the unmounted case; `mount` grows it.
        self.apps = OwningList[WSGIApp](capacity=1)
        self.apps.append(app^)
        self.mount_prefixes = List[String]()
        self.mount_prefixes.append(root_prefix^)
        self.mounts = mounts^
        self.realtime = realtime
        self.health_path = health_path^
        self.thread_index = -1
        self.asgi_notify_fd = -1
        self.lane = -1
        self.ws_pool_fds = List[Int]()
        self.mounted = False
        self.answers_local = True
        self.hold_notify_fd = -1
        self.lane_notify_fds = List[Int]()
        # Capacity 0 when neither mode is on. Every `SSERegistry` method
        # already guards on `slot >= _capacity`, so the hooks below stay
        # correct unconditionally and a plain deployment pays nothing for
        # them — no branch in the hot path, and no branch to get wrong.
        # `asgi_streaming` (the executor mode) needs the same registries:
        # they are the per-slot outboxes ASGI response chunks ride.
        var slots = REALTIME_SLOTS if (realtime or asgi_streaming) else 0
        self.streams = SSERegistry(slots)
        self.sockets = SSERegistry(slots)
        self.asgi_done = List[Bool](capacity=slots)
        self.hold_lane = List[Int](capacity=slots)
        for _ in range(slots):
            self.asgi_done.append(False)
            self.hold_lane.append(NOT_POOL_HELD)

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
            app^, Self.mounts_for(opts), opts.realtime, opts.health_path,
            asgi_streaming=opts.asgi_streaming,
        )

    @staticmethod
    def build(
        opts: ServeOptions,
        multiprocess: Bool,
        multithread: Bool,
        lifespan: Bool,
        project_path: String = String(""),
        only_mount: Int = -1,
    ) raises -> Self:
        """The handler `opts` describes, applications and all.

        The one place applications are constructed, so the mounted and
        unmounted shapes cannot drift: without `--mount` this builds the
        single positional app at the empty prefix, and with it, one app per
        mount carrying its prefix as `script_name`. Every caller that needs
        a handler — m0serve's own path, a `--threads` serving thread, a
        `--blocking-threads` pool thread — comes through here.

        `only_mount >= 0` builds JUST that mount, at its own prefix. That is
        what a pool thread bound to one submit lane wants: it can never
        receive another mount's job, and building the rest would run one
        lifespan per mount per thread for applications it will never call.
        The router still works — a one-mount table has one entry, and every
        job the thread receives already belongs to it.
        """
        if len(opts.mount_prefixes) == 0:
            var app = WSGIApp(
                opts.module,
                server_name=opts.host,
                server_port=String(opts.port),
                attribute=opts.attribute,
                project_path=project_path,
                multiprocess=multiprocess,
                multithread=multithread,
                protocol=opts.protocol,
                lifespan=lifespan,
            )
            return Self.for_options(app^, opts)

        var head = only_mount if only_mount >= 0 else 0
        var first = WSGIApp(
            opts.mount_modules[head],
            server_name=opts.host,
            server_port=String(opts.port),
            attribute=opts.mount_attributes[head],
            project_path=project_path,
            multiprocess=multiprocess,
            multithread=multithread,
            protocol=opts.protocol,
            lifespan=lifespan,
            script_name=opts.mount_prefixes[head],
        )
        var handler = Self(
            first^, Self.mounts_for(opts), opts.realtime, opts.health_path,
            asgi_streaming=opts.asgi_streaming,
            root_prefix=opts.mount_prefixes[head],
        )
        handler.mounted = len(opts.mount_prefixes) > 1
        if only_mount >= 0:
            return handler^
        for i in range(1, len(opts.mount_prefixes)):
            handler.mount(
                opts.mount_prefixes[i],
                WSGIApp(
                    opts.mount_modules[i],
                    server_name=opts.host,
                    server_port=String(opts.port),
                    attribute=opts.mount_attributes[i],
                    multiprocess=multiprocess,
                    multithread=multithread,
                    protocol=opts.protocol,
                    lifespan=lifespan,
                    script_name=opts.mount_prefixes[i],
                ),
            )
        return handler^

    @staticmethod
    def make(ctx: ThreadContext) raises -> Self:
        """Build this thread's handler from the `ServeOptions` at `ctx.user`.

        Two callers, and the same reasoning covers both: a `--threads N`
        serving loop, and a `--blocking-threads N` handler in the pool behind
        one. Either way the module was imported before any thread existed —
        on main under `--threads`, in the forked worker under
        `--blocking-threads` — so `WSGIApp` here is a `sys.modules` hit plus a
        fresh shim namespace; `project_path` is left empty for that reason
        (the path is already on `sys.path`, and appending it again per thread
        would only grow the list).

        Under `--realtime` the registries are per-thread too, which is the
        whole point: a held connection belongs to the loop that accepted it,
        and so does its outbox. Fan-out between threads is the same
        `BroadcastBus` prefork uses — a socketpair does not care whether the
        peer is a process or a thread.
        """
        var opts = Pointer[ServeOptions, MutUntrackedOrigin](
            unsafe_from_address=ctx.user
        )
        var handler = Self.build(
            opts[],
            # True under `--workers W --blocking-threads B`, where this thread
            # really is one of B in one of W processes; False under
            # `--threads`, which is mutually exclusive with `--workers > 1` and
            # so always leaves `workers` at 1. PEP 3333 asks about the
            # deployment, not about who is asking, and `smoke-django` checks
            # both flags against the mode it started.
            multiprocess=opts[].workers > 1,
            multithread=True,
            # False only in executor mode, where this handler is the
            # queue-overflow fallback and the loop's executor owns the one
            # lifespan.
            lifespan=opts[].handler_lifespan,
            only_mount=ctx.lane,
        )
        handler.thread_index = ctx.index
        handler.hold_notify_fd = ctx.hold_fd
        handler.lane = ctx.lane
        handler.answers_local = not ctx.pool
        return handler^

    def mount(mut self, var prefix: String, var app: WSGIApp):
        """Add a second (or later) application at `prefix`.

        The first application is the constructor's, whose prefix is
        `root_prefix` — so this only ever appends, and there is never a
        placeholder app to displace.
        """
        self.mount_prefixes.append(prefix^)
        self.apps.append(app^)

    def app_for(self, path: String) -> Int:
        """Index of the application serving `path`, or -1 for no mount."""
        return match_mount(self.mount_prefixes, path)

    def set_asgi_notify(mut self, fd: Int):
        """Executor-mode wiring: where stream disconnect tags are sent."""
        self.asgi_notify_fd = fd

    def set_ws_pool_notify(mut self, lane: Int, fd: Int):
        """Realtime-with-a-pool wiring: lane `lane`'s submit write end.

        Where an inbound WebSocket message goes when the socket was held by
        a pool thread's view. Grows the table as lanes arrive; lane -1 (the
        unmounted pool) takes slot 0."""
        var at = lane if lane > 0 else 0
        while len(self.ws_pool_fds) <= at:
            self.ws_pool_fds.append(-1)
        self.ws_pool_fds[at] = fd

    def set_lane_notify(mut self, lane: Int, fd: Int):
        """Mounted executor wiring: lane `lane`'s submit write end.

        Grows the table as lanes arrive; the first ASGI lane also becomes
        the default (`asgi_notify_fd`), so the `was_asgi` guard and the
        unmounted path keep one shape."""
        while len(self.lane_notify_fds) <= lane:
            self.lane_notify_fds.append(-1)
        self.lane_notify_fds[lane] = fd
        if self.asgi_notify_fd < 0:
            self.asgi_notify_fd = fd

    def _notify_fd_for(self, url: String) -> Int:
        """The submit fd of the executor that subscribed `url`.

        The lane is the second number of the reserved channel name; absent
        (the unmounted server, or a frame from before lanes existed) means
        the one executor there is."""
        var lane = _parse_stream_lane(url.as_bytes())
        if (
            lane >= 0
            and lane < len(self.lane_notify_fds)
            and self.lane_notify_fds[lane] >= 0
        ):
            return self.lane_notify_fds[lane]
        return self.asgi_notify_fd

    def shutdown(mut self):
        """Every application's teardown (ASGI lifespan shutdown; WSGI no-op).

        Reverse order, the mirror of construction: a later mount may have
        started against state an earlier one set up.
        """
        for i in range(len(self.apps) - 1, -1, -1):
            self.apps[i].shutdown()

    def serve_local(mut self, req: HTTPRequest) raises -> Optional[HTTPResponse]:
        """A static-mount or health answer, entirely in Mojo — or None.

        Split out of `func` for the asyncio executor, whose pump must
        answer these itself (never entering Python) while everything else
        becomes a task on the shim's loop.
        """
        # Static assets first: answered in Mojo, never entering Python, so a
        # slow view queue cannot delay a stylesheet.
        for i in range(len(self.mounts)):
            var hit = self.mounts[i].serve(req)
            if hit:
                return hit^
        if (
            self.health_path.byte_length() > 0
            and req.uri.path == self.health_path
        ):
            return self._health()
        return None

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var local = self.serve_local(req)
        if local:
            return local.take()

        var which = self.app_for(req.uri.path)
        if which < 0:
            return _unmounted()

        if not self.realtime:
            return self.apps[which].serve(req)

        var slot = req.slot_id
        var resp = self.apps[which].serve(req)
        var hold = take_hold(resp)

        if hold.mode == HOLD_STREAM:
            if slot < 0:
                return _conflict()
            if self.hold_notify_fd >= 0:
                # A pool thread. The registries the loop drains are the
                # loop handler's, not this one's, so the hold travels there
                # as a reserved frame on this loop's bus channel — sent
                # BEFORE this response completes, the executor's
                # begin-before-head order. Publishes are FIFO behind it on
                # the same channel, so none is lost to the gap; and with no
                # executor there is no end-of-stream signal for the loop to
                # misread a not-yet-subscribed slot as, so a frame drained
                # a pass late is a stream that starts a pass late, nothing
                # worse. A frame the channel would not take is a client
                # holding a dead stream, which is why that is a 503 and not
                # a shrug.
                if not _send_hold_frame(
                    self.hold_notify_fd, slot,
                    request_last_event_id(req), hold.channel,
                    kind=String("h"), lane=self.lane,
                ):
                    return _hold_unavailable()
                resp.headers["x-worker"] = String(getpid())
                return resp^
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
            if self.hold_notify_fd >= 0:
                # A pool thread: the handshake is ours (the client's key is
                # in the request we hold), but the subscription belongs to
                # the loop, and so does the socket. The frame carries this
                # thread's LANE as well as the channel — an inbound message
                # comes back to the mount whose view gated the upgrade, and
                # nothing else can name it.
                if not _send_hold_frame(
                    self.hold_notify_fd, slot,
                    request_last_event_id(req), hold.channel,
                    kind=String("H"), lane=self.lane,
                ):
                    return _hold_unavailable()
                return ws_resp^
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
        the interpreter busy. Under a pool that means answered on the LOOP
        (`before_request`, `answers_local`): a pool thread's registries are
        never the ones being drained, and its count would be a lie.
        """
        var body = String('{"status":"ok"')
        if self.realtime:
            body += ',"subscribers":' + String(self.streams.active_count())
            body += ',"sockets":' + String(self.sockets.active_count())
        body += "}"
        return OK(body^, "application/json")

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        # The loop's hook, called before a job is submitted: static mounts
        # and the health path are answered here, in Mojo, on the loop — see
        # `answers_local`. A pool thread's handler declines, so the same
        # request is never answered twice. `serve_local` may raise on a
        # static file's I/O; that is `func`'s to report as a 500, not this
        # hook's, which the trait declares non-raising.
        if not self.answers_local:
            return None
        try:
            return self.serve_local(req)
        except:
            return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        if self.thread_index >= 0:
            resp.headers["x-thread"] = String(self.thread_index)

    # --- Held connections. Inert at capacity 0, so no `realtime` branch. ---

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        if self.sockets.is_slot_streaming(slot):
            var ws_out = self.sockets.drain(slot)
            if (
                slot < len(self.asgi_done)
                and self.asgi_done[slot]
                and not self.sockets.has_pending(slot)
            ):
                # The app closed the WebSocket and these bytes end with
                # its close frame: unsubscribing lets the loop close the
                # connection once they land.
                self.sockets.unsubscribe(slot)
                self.asgi_done[slot] = False
            return ws_out^
        var out = self.streams.drain(slot)
        if (
            slot < len(self.asgi_done)
            and self.asgi_done[slot]
            and not self.streams.has_pending(slot)
        ):
            # The end frame arrived and these are the stream's last bytes:
            # unsubscribing here flips `sse_is_streaming`, and the loop
            # closes the connection once they land — how a
            # content-length-free streamed body ends.
            self.streams.unsubscribe(slot)
            self.asgi_done[slot] = False
        return out^

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.streams.is_slot_streaming(
            slot
        ) or self.sockets.is_slot_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        # Read before the unsubscribes erase it: was this an ASGI stream
        # the executor still has a task for?
        var was_asgi = self.asgi_notify_fd >= 0 and (
            self.streams.is_slot_streaming(slot)
            or self.sockets.is_slot_streaming(slot)
            or (slot < len(self.asgi_done) and self.asgi_done[slot])
        )
        # The slot's reserved channel name carries its executor's lane;
        # read it before the unsubscribes erase it.
        var slot_url = self.streams.filter_url(slot)
        if slot_url.byte_length() == 0:
            slot_url = self.sockets.filter_url(slot)
        self.streams.unsubscribe(slot)
        self.sockets.unsubscribe(slot)
        if slot < len(self.hold_lane):
            self.hold_lane[slot] = NOT_POOL_HELD
        if slot < len(self.asgi_done):
            self.asgi_done[slot] = False
        if was_asgi:
            _send_disconnect_tag(self._notify_fd_for(slot_url), slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # The executor's ASGI stream frames first: their channel names open
        # with a control byte, and the early return skips both O(capacity)
        # scans below.
        #
        # These branches act on a SLOT NUMBER the frame chose, so reaching
        # them is equivalent to addressing another connection: `s` queues
        # bytes into its stream, `e` ends it, `h` re-points it. Separation
        # from application channels is therefore enforced at every publish
        # boundary -- `publish_to_channels` (broadcast.mojo), the shim's
        # `_M0Broadcast.publish`, and `m0pub.publish_frame` all refuse a
        # leading 0x01 -- because internal senders bypass those helpers and
        # write `encode_bus_frame` datagrams directly.
        #
        # It was previously argued here that the collision was structurally
        # impossible, on the grounds that an HTTP header value cannot carry
        # a control byte. That covers the `M0-Channel` header only. A
        # channel passed to `publish()` is an ordinary string, and `%01` in
        # a form body decodes to a real 0x01 -- which is how an
        # unauthenticated POST reached another connection's SSE stream.
        # See test_broadcast.mojo::test_publish_rejects_reserved_channel.
        var ub = url.as_bytes()
        if len(ub) >= 3 and ub[0] == ASGI_URL_CONTROL:
            var slot = _parse_stream_slot(ub)
            if slot < 0:
                return
            if ub[1] == UInt8(ord("b")):
                # Begin: sent before the stream's head completion, so this
                # subscription exists before the loop ever drains the slot
                # as a stream.
                self.streams.subscribe(slot, url, NO_EVENT_ID)
                if slot < len(self.asgi_done):
                    self.asgi_done[slot] = False
            elif ub[1] == UInt8(ord("s")):
                # A response chunk — for a SUBSCRIBED slot only. Never
                # subscribe here: a chunk that outlived its connection
                # (sent before the disconnect tag reached the executor)
                # must be dropped, not injected into whatever request the
                # recycled slot serves now. The channel's FIFO guarantees
                # a new stream's begin frame sorts after every frame of
                # the old one.
                if self.streams.is_slot_streaming(slot):
                    _ = self.streams.queue_frame(slot, NO_EVENT_ID, frame)
            elif ub[1] == UInt8(ord("e")):
                # End of stream: hand out anything still pending, then
                # stop being a stream (which is what lets the loop close).
                if self.streams.has_pending(slot):
                    if slot < len(self.asgi_done):
                        self.asgi_done[slot] = True
                else:
                    self.streams.unsubscribe(slot)
            elif ub[1] == UInt8(ord("h")):
                # A hold taken on a pool thread: subscribe the slot HERE,
                # in the registries the loop actually drains. The frame's
                # id field carries the request's `Last-Event-ID` and its
                # payload the channel; the pool thread has already
                # rewritten the response into the stream's head.
                self.streams.subscribe(
                    slot,
                    String(StringSlice(unsafe_from_utf8=Span(frame))),
                    event_id,
                )
            elif ub[1] == UInt8(ord("H")):
                # A socket hold taken on a pool thread. Subscribe it here,
                # where the registries are drained, and remember the lane:
                # an inbound frame has exactly one mount it may be delivered
                # to, and this is the record of which.
                var chan = String(StringSlice(unsafe_from_utf8=Span(frame)))
                self.sockets.subscribe(slot, chan, event_id)
                if slot < len(self.hold_lane):
                    self.hold_lane[slot] = _parse_stream_lane(ub)
            elif ub[1] == UInt8(ord("B")):
                # A WebSocket's begin: sent before its held 101 completes,
                # same FIFO anchor as a stream's begin — but into the
                # sockets registry.
                self.sockets.subscribe(slot, url, NO_EVENT_ID)
                if slot < len(self.asgi_done):
                    self.asgi_done[slot] = False
            elif ub[1] == UInt8(ord("w")):
                # An outbound WS frame, already RFC 6455-encoded by the
                # executor. Subscribed slots only, same recycled-slot
                # safety rule as 's'.
                if self.sockets.is_slot_streaming(slot):
                    _ = self.sockets.queue_frame(slot, NO_EVENT_ID, frame)
            elif ub[1] == UInt8(ord("x")):
                # WebSocket end (the close frame is already queued ahead
                # of this on the same channel).
                if self.sockets.has_pending(slot):
                    if slot < len(self.asgi_done):
                        self.asgi_done[slot] = True
                else:
                    self.sockets.unsubscribe(slot)
            return
        # Every published GRIP frame arrives here — from peer workers or
        # threads AND from this one's own application, because `m0pub`
        # writes every channel, ours included. `url` is the channel name.
        #
        # Executor mode first: an ASGI application's subscribers are
        # asyncio queues on the executor's loop (`state["m0"]`), not
        # registry slots, so the frame is forwarded to every executor as
        # a tagged submit datagram and the shim fans it out from there.
        # The registries still get it below — under --mount a WSGI GRIP
        # app cannot share the process with --realtime, so the notify is
        # a no-op there, but keeping it unconditional keeps one shape.
        if self.asgi_notify_fd >= 0:
            if len(self.lane_notify_fds) > 0:
                for lane in range(len(self.lane_notify_fds)):
                    if self.lane_notify_fds[lane] >= 0:
                        _send_bus_frame_tag(
                            self.lane_notify_fds[lane], event_id, url, frame
                        )
            else:
                _send_bus_frame_tag(self.asgi_notify_fd, event_id, url, frame)
        _ = self.streams.notify_frame(url, event_id, frame)
        if self.sockets.has_subscribers(url):
            # The bus carries SSE frames; a socket needs an RFC 6455 frame.
            # Translating at delivery rather than publishing twice keeps ONE
            # frame per publish on the wire and gives both transports the
            # same payload — `sse_data_payload` returns exactly what an
            # `EventSource` would hand to `onmessage`.
            var data = sse_data_payload(Span(frame))
            _ = self.sockets.notify_frame(
                url, event_id, encode_ws_frame(WS_OP_TEXT, Span(data))
            )

    def tick(mut self, now_ms: Int):
        pass

    def serve_ws_message(
        mut self, slot: Int, opcode: Int, channel: String,
        payload: Span[Byte, _],
    ):
        """A pool thread's half of `ws_message`: serve it here, drop the reply.

        The loop routed this to the mount whose view gated the upgrade, so
        `apps[0]` is that mount — a pool thread builds only its own
        (`only_mount`). The path carries the mount prefix, because the bridge
        trims exactly that many bytes to make PATH_INFO.

        Non-raising by contract, and the try is what keeps it so: a raising
        view must not take the socket, or this thread, down with it.
        """
        try:
            var req = ws_message_request(
                self.mount_prefixes[0] + WS_MESSAGE_PATH,
                channel, slot, opcode, payload,
            )
            _ = self.apps[0].serve(req)
        except e:
            print("ws_message: " + WS_MESSAGE_PATH + " raised: ", e)

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        # Three ways a socket on this loop can be held, and the message goes
        # wherever its own hold went. The POOL first: on a mixed mounted
        # server `asgi_notify_fd` is set for the ASGI mount, and asking that
        # question first would hand every socket's message to an executor
        # that never accepted the connection.
        if slot < len(self.hold_lane) and self.hold_lane[slot] != NOT_POOL_HELD:
            var held_lane = self.hold_lane[slot]
            var at = held_lane if held_lane > 0 else 0
            if at < len(self.ws_pool_fds) and self.ws_pool_fds[at] >= 0:
                if not _send_ws_pool_message(
                    self.ws_pool_fds[at], slot, opcode,
                    self.sockets.filter_url(slot), payload,
                ):
                    print(
                        "ws_message: the pool's channel would not take an"
                        " inbound message for slot " + String(slot)
                        + "; it is lost",
                        flush=True,
                    )
                return
        # Executor mode: the message belongs to the app's own
        # `websocket.receive` loop — forward it to the executor thread as
        # a tagged datagram and never enter Python on the loop thread.
        if self.asgi_notify_fd >= 0 and self.sockets.is_slot_streaming(slot):
            _send_ws_message_tag(
                self._notify_fd_for(self.sockets.filter_url(slot)),
                slot, opcode, payload,
            )
            return
        # GRIP mode: an inbound message, handed to a plain synchronous view
        # as a POST. This runs ON the event loop thread, so it costs
        # exactly what any other view costs — the hold pattern removes the
        # *connection* cost from Python, not the *request* cost.
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
            _ = self.apps[0].serve(req)
        except e:
            print("ws_message: " + WS_MESSAGE_PATH + " raised: ", e)


def _unmounted() -> HTTPResponse:
    """No mount claims this path — answered in Mojo, never entering Python.

    A 404 rather than a 502: the server is fine and the path is simply not
    served here, which is what a reverse proxy in front of two apps would
    also say.
    """
    return HTTPResponse(
        body_bytes=String('{"error":"no application mounted at this path"}')
        .as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=404,
        status_text="Not Found",
    )


def _send_hold_frame(
    fd: Int, slot: Int, last_event_id: Int, channel: String,
    kind: String = String("h"), lane: Int = -1,
) -> Bool:
    """One reserved hold frame on the loop's bus channel: `[id][len][url][channel]`.

    `kind` is `h` for an SSE hold and `H` for a socket — the same two letters
    the executor uses for its own begin frames, and read by the same branch.
    `lane` rides in the url so the loop learns which mount holds the socket;
    an SSE hold has no inbound half and does not need it, but carries it
    anyway rather than having two shapes to reason about.

    Bus codec on purpose — the loop drains this descriptor with
    `drain_bus_channel` and hands every frame to `sse_peer_frame`, which is
    where the `h` kind is turned into a subscription. Bounded retry, never a
    park: a hold frame is ~50 bytes on a 256 KB channel the loop empties
    every pass, so a refusal here means the loop is not draining at all,
    and the caller answers 503 rather than leaving a client on a stream
    nothing will ever feed."""
    var datagram = encode_bus_frame(
        asgi_stream_url(kind, slot, lane), last_event_id,
        Span(channel.as_bytes()),
    )
    for _ in range(64):
        var rc = external_call["send", Int](
            c_int(fd), datagram.unsafe_ptr(), UInt(len(datagram)), c_int(0)
        )
        if rc == len(datagram):
            return True
        _ = external_call["sched_yield", c_int]()
    return False


def _hold_unavailable() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String(
            '{"error":"the stream could not be registered with the event loop; retry"}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=503,
        status_text="Service Unavailable",
    )


def _ws_hold_unavailable(mounted: Bool) -> HTTPResponse:
    """The socket half of a hold, refused — naming which reason applies."""
    var why = String("--mount") if mounted else String("--blocking-threads")
    return HTTPResponse(
        body_bytes=String(
            '{"error":"M0-Hold: websocket is not available with ' + why
            + ' yet; serve the WebSocket application on its own.'
            ' SSE holds work here."}'
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=409,
        status_text="Conflict",
    )


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


# --- the executor's ASGI stream channel names --------------------------------
#
# Chunks and stream-ends travel from the executor thread to the loop as
# bus-shaped datagrams whose "url" is a slot-addressed channel name opening
# with a control byte (0x01). Kinds: 's' — a response chunk for the slot's
# outbox; 'e' — end of stream.
#
# What keeps an application channel out of this namespace is the check at
# each publish boundary (`channel_is_reserved` in broadcast.mojo, and its
# two Python twins), NOT the shape of an HTTP header. A GRIP channel does
# arrive in the `M0-Channel` response header, whose value the request
# parser would refuse control bytes in — but that is only one of the ways a
# channel is named. `m0pub.publish(channel, ...)` and the ASGI
# `state["m0"].publish(...)` take an arbitrary string, and in the reference
# app that string is a request field.

comptime ASGI_URL_CONTROL = UInt8(1)


def asgi_stream_url(kind: String, slot: Int, lane: Int = -1) -> String:
    """Build a reserved channel name: `\\x01<kind>/<slot>[/<lane>]`.

    The lane is the executor's own mount index, appended only under
    `--mount` (so the unmounted wire format is unchanged). It is how the
    handler routes a disconnect tag or an inbound WS message back to the
    executor that owns the slot: the name is stored as the subscription's
    filter url, so the routing needs no side table that could drift.
    """
    var b = List[UInt8]()
    b.append(ASGI_URL_CONTROL)
    for ch in kind.as_bytes():
        b.append(ch)
    b.append(UInt8(ord("/")))
    for ch in String(slot).as_bytes():
        b.append(ch)
    if lane >= 0:
        b.append(UInt8(ord("/")))
        for ch in String(lane).as_bytes():
            b.append(ch)
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _parse_url_number(url_bytes: Span[Byte, _], which: Int) -> Int:
    """The `which`-th `/`-separated number of a reserved channel name
    (0 = slot, 1 = lane); -1 if absent or malformed. Digits only —
    anything else is a frame to drop, not raise over (`sse_peer_frame`
    must not raise)."""
    var seen = -1
    var i = 0
    var n = len(url_bytes)
    while i < n:
        if url_bytes[i] == UInt8(ord("/")):
            seen += 1
            if seen == which:
                break
        i += 1
    if seen != which or i + 1 >= n:
        return -1
    var value = 0
    var j = i + 1
    while j < n and url_bytes[j] != UInt8(ord("/")):
        var c = Int(url_bytes[j])
        if c < ord("0") or c > ord("9"):
            return -1
        value = value * 10 + (c - ord("0"))
        j += 1
    return value


def _parse_stream_slot(url_bytes: Span[Byte, _]) -> Int:
    """The slot number of a reserved channel name; -1 if malformed."""
    return _parse_url_number(url_bytes, 0)


def _parse_stream_lane(url_bytes: Span[Byte, _]) -> Int:
    """The lane of a reserved channel name; -1 when it carries none (the
    unmounted server's frames)."""
    return _parse_url_number(url_bytes, 1)


def _send_bus_frame_tag(fd: Int, event_id: Int, url: String, frame: List[UInt8]):
    """One `[tag=3 u8][event_id i64 LE][url_len u16 LE][url][frame]` datagram.

    A BroadcastBus frame, re-framed for the submit channel so an ASGI
    executor's loop receives what a registry slot would have: the shim's
    `_m0_dispatch` fans it out to `state["m0"]` subscribers. Best-effort
    with the same bounded retry as the WS tag — a dropped broadcast
    matches the bus's own delivery posture.
    """
    var url_bytes = url.as_bytes()
    var msg = List[UInt8](capacity=11 + len(url_bytes) + len(frame))
    msg.append(UInt8(3))
    var eid = UInt64(event_id)
    for i in range(8):
        msg.append(UInt8((eid >> UInt64(8 * i)) & 0xFF))
    var ulen = UInt16(len(url_bytes))
    msg.append(UInt8(ulen & 0xFF))
    msg.append(UInt8((ulen >> UInt16(8)) & 0xFF))
    for b in url_bytes:
        msg.append(b)
    for i in range(len(frame)):
        msg.append(frame[i])
    for _ in range(16):
        var rc = external_call["send", Int](
            c_int(fd), msg.unsafe_ptr(), UInt(len(msg)), c_int(0)
        )
        if rc == len(msg):
            return
        _ = external_call["sched_yield", c_int]()


def _send_ws_pool_message(
    fd: Int, slot: Int, opcode: Int, channel: String, payload: List[UInt8]
) -> Bool:
    """`TAG_WS_MESSAGE` for a pool thread: the executor's shape plus the channel.

    A pool thread's registries are empty — the socket was subscribed on the
    loop — so the name it joined with has to travel with the message. Bounded
    retry, never a park: this runs on the event loop."""
    var chan = channel.as_bytes()
    var msg = List[UInt8](capacity=12 + len(chan) + len(payload))
    msg.append(2)
    var bits = UInt64(Int64(slot))
    for shift in range(0, 64, 8):
        msg.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    msg.append(UInt8(opcode))
    msg.append(UInt8(len(chan) & 0xFF))
    msg.append(UInt8((len(chan) >> 8) & 0xFF))
    for b in chan:
        msg.append(b)
    for b in payload:
        msg.append(b)
    for _ in range(64):
        var rc = external_call["send", Int](
            c_int(fd), msg.unsafe_ptr(), UInt(len(msg)), c_int(0)
        )
        if rc == len(msg):
            return True
        _ = external_call["sched_yield", c_int]()
    return False


def _send_ws_message_tag(fd: Int, slot: Int, opcode: Int, payload: List[UInt8]):
    """One `[tag=2 u8][slot i64 LE][opcode u8][payload]` datagram.

    The payload rides IN the datagram, so it is bounded by the channel's
    frame size; the loop's own `max_message_size` keeps assembled messages
    under it. Retried like the disconnect tag — a lost inbound message is
    an app-visible gap."""
    var msg = List[UInt8](capacity=10 + len(payload))
    msg.append(2)
    var bits = UInt64(Int64(slot))
    for shift in range(0, 64, 8):
        msg.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    msg.append(UInt8(opcode))
    for b in payload:
        msg.append(b)
    for _ in range(64):
        var rc = external_call["send", Int](
            c_int(fd), msg.unsafe_ptr(), UInt(len(msg)), c_int(0)
        )
        if rc == len(msg):
            return
        _ = external_call["sched_yield", c_int]()


def _send_disconnect_tag(fd: Int, slot: Int):
    """One `[tag=1 u8][slot i64 LE]` datagram on the submit channel.

    A raw libc `send` rather than the socket module's wrapper: this is
    nine bytes on a connected SOCK_DGRAM pair, and `sse_slot_disconnected`
    must not raise. Retried briefly rather than dropped — a lost
    disconnect is a leaked task holding state until shutdown — but
    bounded, because this runs on the event loop thread and must never
    park."""
    var msg = List[UInt8](capacity=9)
    msg.append(1)
    var bits = UInt64(Int64(slot))
    for shift in range(0, 64, 8):
        msg.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    for _ in range(64):
        var rc = external_call["send", Int](
            c_int(fd), msg.unsafe_ptr(), UInt(len(msg)), c_int(0)
        )
        if rc == len(msg):
            return
        _ = external_call["sched_yield", c_int]()
