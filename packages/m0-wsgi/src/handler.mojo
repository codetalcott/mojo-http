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
from lightbug_http.offload import OffloadPool, STREAM_GEN_NONE
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.websocket import (
    websocket_upgrade, encode_ws_frame, WS_OP_TEXT,
)
from lightbug_http.c.platform import MSG_DONTWAIT

from std.ffi import c_int, external_call, get_errno
from std.python import Python
from std.time import sleep

from m0_http import SSERegistry, StaticFiles, sse_data_payload
from m0_http.sse.registry import MAX_PENDING_BYTES
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

comptime STREAM_PIECE = 16 * 1024
"""Largest `s` frame a pool thread sends, and its whole credit window:
stop-and-wait, one piece in flight per stream. Small on purpose — the chunk
channel is ONE 256 KB pair shared by every executor (128 KB global window)
and every pool thread, and on Linux the kernel charges each datagram's whole
skb against the receiver's buffer (`rmem_max`, ~212 KB). N threads at one
piece each is what keeps that sum bounded; the never-drop wait in
`_place_stream_frame` is the backstop when it is not."""

comptime STREAM_GEN_HELD = -2
"""`stream_gen` of a slot subscribed by an `M0-Hold` (`h`/`H`): no chunk
frame carries this generation, so a stale `s`/`e` for a stream that used
to have this slot number is dropped rather than queued into the hold."""

def _decline_direct(
    pool_addr: Int, handler_addr: Int, state_addr: Int, lane: Int, slot: Int,
) raises -> Bool:
    """The default `WSGIHandler.direct_fn`: never called, because
    `direct_job` declines before consulting it while `direct_state_addr`
    is 0 — but a function-typed field needs a value, and this is it."""
    return False


struct WSGIHandler(ThreadHandler):
    """Serve a WSGI application, with optional static mounts in front of it.

    Also a `ThreadHandler`: under `--threads N` each serving thread calls
    `make(ctx)` to build its own instance — and its own `WSGIApp` and bridge
    — on that thread, from the `ServeOptions` whose address is `ctx.user`.
    """

    var attach_in_func: Bool
    """This handler serves on a thread that holds NO thread state (the loop
    of `_serve_offloaded`, docs/notes/detached-loop.md), so `func` and the
    inline WebSocket serve attach for their own duration. False on pool
    threads and the executor, whose threads are attached for life."""
    var apps: List[WSGIApp]
    """The mounted applications, parallel to `mount_prefixes`.

    Always at least one: a server with no `--mount` holds a single app at
    the empty prefix, so routing has one shape and the ordinary case is the
    degenerate mount rather than a separate path. `WSGIApp` owns a bridge
    and is Movable but not Copyable — copying one would duplicate an
    interpreter handle — and `List` takes a Movable-only element as it is.
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
    var stream_gen: List[Int]
    """Per slot, the generation of the channel stream it is subscribed to
    — the begin frame's id (`b`/`B`/`P`) — or `STREAM_GEN_HELD` for a hold,
    `STREAM_GEN_NONE` for nothing. Every `s`/`e`/`w`/`x` frame carries its
    stream's generation and is dropped on a mismatch. The FIFO argument
    covers one writer; this covers two: a slot freed by `_close_slot` is
    reused at the next accept, and a producer still inside the application
    can send its next chunk after a DIFFERENT producer's begin subscribed
    the recycled slot — a pool thread's stream and an executor's, or an
    executor's and a hold arriving on the other bus fd — with no channel
    order between them at all."""
    var stream_fd: Int
    """The chunk channel's write end, or -1: where this handler streams a
    WSGI iterable's body when it is a pool thread's (`ThreadContext.
    stream_fd`). The loop's own handler never has one."""
    var stream_app: Int
    """Which application `func` last served; the one `stream_pending` and
    the stream methods ask."""
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

    var stream_lost: List[Bool]
    """Loop side, per slot: this stream's outbox has already refused a frame
    and the connection is being torn down.

    Without it the tear-down is announced and attempted once per refused
    frame — measured at 336 log lines and 336 aborts for ONE flooding
    WebSocket, because the producer does not learn the connection is gone
    until the loop closes it. Cleared where a slot subscribes, which is the
    only place it can still be true of the previous stream."""

    var abort_pool_addr: Int
    """Loop side: this loop's `OffloadPool` address, or 0.

    The one thing a handler cannot otherwise do about a frame it must
    refuse. `sse_peer_frame` runs ON the loop, and its `s`/`w` branches
    queue a producer's bytes into a slot's outbox — a queue that can say
    no (`MAX_PENDING_BYTES`). Refused and discarded, an `s` frame's bytes
    are never drained, so their credit never returns and the producer
    awaits it for ever, while the client is served a body that is short
    under a clean chunked terminator; a refused `w` frame is a WebSocket
    message the peer has no protocol-level way to notice is missing. Both
    end the connection instead, so the truncation is something the client
    can see — a response through `abort_stream`, which is on the pool and
    is the only reason the pool has to be reachable from here; a socket
    through `asgi_done`, because a held 101 never sets `sse_streaming` and
    the loop's abort path requires it."""

    var direct_fn: def (Int, Int, Int, Int, Int) thin raises -> Bool
    """The loop inversion's job entry, or `_decline_direct`.

    Set by `set_direct_executor` on the ONE handler that is both the loop's
    and the executor's under `M0_INVERTED`: `direct_job` calls it with the
    pool, this handler, the executor state, the lane and the slot, and it
    runs the port's job branch on this thread. A function value rather than
    an import so `handler.mojo` never imports `asgi_executor.mojo`, which
    imports it. The default declines, which is what every other handler
    does."""
    var direct_pool_addr: Int
    var direct_state_addr: Int
    var direct_lane: Int
    var lane_notify_fds: List[Int]
    """Per-lane submit write ends, indexed by mount (`--mount` with more
    than one ASGI mount); -1 where a lane has no executor. A disconnect
    tag or an inbound WS message must reach the executor that owns the
    slot — its lane rides in the reserved channel name the executor
    subscribed with, so the lookup is a parse of the slot's own filter
    url, not a table this handler could let drift."""

    var ws_in_sent: List[Int]
    """Per slot: datagram bytes charged toward `WS_IN_WINDOW` since this
    socket's begin ('B' seeds it to zero)."""
    var ws_in_acked: List[Int]
    """Per slot: the shim's cumulative consumed counter, as of the last 'r'
    frame — monotonic, clamped to `ws_in_sent` so a stale ack cannot open
    the window wider than what was charged."""
    var ws_parked: List[List[UInt8]]
    """Per slot: messages taken off the wire that the channel or the window
    refused — `[opcode u8][len u32 LE][payload]` records, FIFO. Bounded by
    ONE `recv_staging` batch past the window, because the loop stops
    reading the socket while this is non-empty. Parked is owed: nothing
    here is ever dropped, only delivered late."""
    var ws_parked_count: Int
    """How many slots hold parked messages — the guard that keeps
    `take_ws_resumes`'s retry scan off the per-pass hot path."""
    var ws_resume: List[Int]
    """Slots whose parked queue just drained; handed to the loop once via
    `take_ws_resumes` so it re-arms their reads."""

    def __init__(
        out self,
        var app: WSGIApp,
        var mounts: List[StaticFiles],
        realtime: Bool = False,
        var health_path: String = String(""),
        asgi_streaming: Bool = False,
        var root_prefix: String = String(""),
    ):
        # One slot is exactly the unmounted case; `mount` grows it.
        self.apps = List[WSGIApp](capacity=1)
        self.apps.append(app^)
        self.attach_in_func = False
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
        self.abort_pool_addr = 0
        self.direct_fn = _decline_direct
        self.direct_pool_addr = 0
        self.direct_state_addr = 0
        self.direct_lane = -1
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
        self.stream_gen = List[Int](capacity=slots)
        self.stream_lost = List[Bool](capacity=slots)
        self.ws_in_sent = List[Int](capacity=slots)
        self.ws_in_acked = List[Int](capacity=slots)
        self.ws_parked = List[List[UInt8]](capacity=slots)
        for _ in range(slots):
            self.asgi_done.append(False)
            self.hold_lane.append(NOT_POOL_HELD)
            self.stream_gen.append(STREAM_GEN_NONE)
            self.stream_lost.append(False)
            self.ws_in_sent.append(0)
            self.ws_in_acked.append(0)
            self.ws_parked.append(List[UInt8]())
        self.ws_parked_count = 0
        self.ws_resume = List[Int]()
        self.stream_fd = -1
        self.stream_app = -1

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
        handler.stream_fd = ctx.stream_fd
        if ctx.pool and ctx.stream_fd >= 0:
            # A pool thread with a chunk channel streams the iterables an
            # application does not size. Never the loop's own handler: a
            # body produced on the loop thread is the hostage problem the
            # pool exists to remove, so there the shim keeps joining.
            for i in range(len(handler.apps)):
                handler.apps[i].set_stream_capable(True)
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

    def set_abort_pool(mut self, addr: Int):
        """Loop-side wiring: this loop's `OffloadPool`, for `abort_stream`.

        Set unconditionally beside the pool the loop is given, on the LOOP's
        handler only — a pool thread aborts through the pool it is already
        holding. See `abort_pool_addr`."""
        self.abort_pool_addr = addr

    def set_direct_executor(
        mut self, pool_addr: Int, state_addr: Int, lane: Int,
        job_fn: def (Int, Int, Int, Int, Int) thin raises -> Bool,
    ):
        """Inverted-mode wiring: this handler is the loop's AND the executor's,
        on one thread, and `direct_job` takes jobs itself through `job_fn`."""
        self.direct_pool_addr = pool_addr
        self.direct_state_addr = state_addr
        self.direct_lane = lane
        self.direct_fn = job_fn

    def direct_job(mut self, slot: Int) -> Bool:
        """`HTTPService.direct_job`: take the parked request on this thread.

        Only the inverted executor's handler has a `direct_fn` that does
        anything; everywhere else this is the trait's default, declining.
        A raise inside the job branch is already a 500 parked for the slot,
        so it is logged rather than propagated — the read path that calls
        this is non-raising, like every other hook it calls.
        """
        if self.direct_state_addr == 0:
            return False
        var self_ptr = Pointer(to=self)
        var self_addr = Pointer(to=self_ptr).unsafe_bitcast[Int]()[]
        try:
            _ = self.direct_fn(
                self.direct_pool_addr, self_addr, self.direct_state_addr,
                self.direct_lane, slot,
            )
        except e:
            print("inverted executor: direct job raised: " + String(e), flush=True)
        return True

    def _claim_lost(mut self, slot: Int, what: String) -> Bool:
        """Name a frame this handler's outbox refused, ONCE per stream.

        Returns whether this caller is the one that has to tear the
        connection down — False if the stream has already been given up on,
        which is the common case: the producer goes on sending until the
        loop closes the connection and its disconnect reaches it, so one
        overflowing WebSocket produced 336 refusals where one is the news.
        Named at all because every one of these was silent before: the
        queue's refusal was discarded at both call sites and the frame
        simply vanished."""
        if slot < 0 or slot >= len(self.stream_lost):
            return False
        if self.stream_lost[slot]:
            return False
        self.stream_lost[slot] = True
        print(
            "m0serve: slot " + String(slot) + "'s outbox refused a "
            + what + " (backpressure at " + String(MAX_PENDING_BYTES)
            + " bytes pending) — ending this connection rather than "
            "dropping bytes the client cannot know are missing",
            flush=True,
        )
        return True

    def _abort_stream(mut self, slot: Int, gen: Int):
        """Close a streamed RESPONSE without its chunked terminator.

        The abort rides the completion channel and the loop applies it after
        that batch's completions. Unsubscribing instead would end the stream
        the ordinary way — a short body under a clean terminator, which is
        exactly the silent-wrong this refuses. Only for an `s` stream: the
        loop's abort path requires the slot to be `slot_sse`, which a
        WebSocket's 101 never sets."""
        if self.abort_pool_addr == 0:
            return
        ref pool = Pointer[OffloadPool, MutUntrackedOrigin](
            unsafe_from_address=self.abort_pool_addr
        )[]
        _ = pool.abort_stream(slot, gen)

    def _end_socket(mut self, slot: Int):
        """Close a WebSocket after flushing what is already queued.

        A socket's outbox is unframed, so `asgi_done` is the whole
        mechanism: the next drain hands out every pending byte, unsubscribes,
        and the loop's `ended and not framed` branch closes the connection.
        The peer sees the bytes that exist and then a close with no close
        frame — the truth about a message stream with a hole in it."""
        if slot >= 0 and slot < len(self.asgi_done):
            self.asgi_done[slot] = True

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
        # `/ws/message` is the server's to synthesise, not a client's to
        # request. An inbound WebSocket frame is delivered to the
        # application as a POST there, carrying `M0-Channel`, `M0-Slot` and
        # `M0-Opcode` — headers a client can also simply send, to a URL
        # that is an ordinary route in the application's urlconf and must
        # be CSRF-exempt to accept the synthetic request at all. So the
        # view's premise, that "the client is the server itself, on the far
        # side of a connection Django already authorised at upgrade time",
        # held only because nobody had tried the other way in.
        #
        # A request that arrived over the wire is refused here; the
        # synthetic one never passes through `serve_local` (`ws_message`
        # calls `apps[0].serve` directly), so the real path is untouched.
        # 404 rather than 403: the route's existence is not a client's
        # business.
        #
        # Only under `--realtime`, which is what makes the path mean
        # anything. Without it an application may route `/ws/message`
        # itself and this must not shadow it.
        if self.realtime and self._is_ws_message_path(req.uri.path):
            return _not_found_response()
        return None

    def _is_ws_message_path(self, path: String) -> Bool:
        """Whether `path` names the synthetic WebSocket-message endpoint.

        Under every mount, not just the bare one: the pool thread builds
        the synthetic request as `mount_prefixes[0] + WS_MESSAGE_PATH`
        (`_deliver_ws_message`), so on `--mount /app=...` the application's
        route is at `/app/ws/message` and a reservation that only compared
        the bare path would have left it reachable from the network — the
        exact hole the reservation exists to close, still open in the one
        configuration where the path is not obvious.
        """
        if path == WS_MESSAGE_PATH:
            return True
        for i in range(len(self.mount_prefixes)):
            if self.mount_prefixes[i].byte_length() > 0:
                if path == self.mount_prefixes[i] + WS_MESSAGE_PATH:
                    return True
        return False

    def set_attach_in_func(mut self):
        """This handler's thread holds no thread state: `func` attaches itself."""
        self.attach_in_func = True

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if not self.attach_in_func:
            return self._func_attached(req)
        # The detached loop's inline fallback (a full submit queue, or a pool
        # that is not accepting): the one place the loop thread runs Python.
        # `PyGILState_Ensure` re-attaches the thread's own saved state and
        # `Release` puts it back, so the loop leaves as it came.
        ref cpy = Python().cpython()
        var gs = cpy.PyGILState_Ensure()
        var resp: HTTPResponse
        try:
            resp = self._func_attached(req)
        except e:
            cpy.PyGILState_Release(gs)
            raise e^
        cpy.PyGILState_Release(gs)
        return resp^

    def _serve_synthetic(mut self, req: HTTPRequest) raises:
        """Run a synthetic `/ws/message` POST through the root app, attaching
        first when this handler's thread holds no thread state; the response
        is discarded (what the view does is the point)."""
        if not self.attach_in_func:
            _ = self.apps[0].serve(req)
            return
        ref cpy = Python().cpython()
        var gs = cpy.PyGILState_Ensure()
        try:
            _ = self.apps[0].serve(req)
        except e:
            cpy.PyGILState_Release(gs)
            raise e^
        cpy.PyGILState_Release(gs)

    def _func_attached(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var local = self.serve_local(req)
        if local:
            return local.take()

        var which = self.app_for(req.uri.path)
        if which < 0:
            return _unmounted()

        self.stream_app = which
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

    # --- Streamed WSGI bodies: the pool thread as a chunk-channel producer. ---

    def stream_pending(self) -> Bool:
        return (
            self.stream_app >= 0
            and self.stream_app < len(self.apps)
            and self.apps[self.stream_app]._bridge.stream_pending
        )

    def stream_begin(mut self, slot: Int, gen: Int, ack_fd: Int) -> Bool:
        if self.stream_fd < 0 or not self.stream_pending():
            return False
        var empty = List[UInt8]()
        var frame = encode_bus_frame(
            pool_stream_url(slot, self.lane, ack_fd), gen, Span(empty)
        )
        if _send_frame_bounded(self.stream_fd, frame):
            return True
        # The channel would not take ~60 bytes after 64 tries: the loop is
        # not draining it. Nothing will feed this stream; close the iterable
        # so the caller can answer with a response the client can parse.
        self.apps[self.stream_app].stream_close()
        self.stream_app = -1
        return False

    def stream_pump(
        mut self, slot: Int, gen: Int, ack_read_fd: Int, mut pool: OffloadPool
    ):
        if self.stream_app < 0 or self.stream_app >= len(self.apps):
            return
        var app_index = self.stream_app
        var credit = STREAM_PIECE
        var gone = False
        var aborted = False
        while True:
            var chunk: List[UInt8]
            try:
                chunk = self.apps[app_index].stream_next()
            except e:
                # The generator raised after its head went out. The head
                # is on the wire, so the only honest answer is a truncated
                # body: abort, and the loop closes without a terminator.
                print(
                    "m0serve: streamed response raised after its head: "
                    + String(e),
                    flush=True,
                )
                aborted = True
                break
            if len(chunk) == 0:
                break
            var offset = 0
            while offset < len(chunk):
                var n = STREAM_PIECE
                if len(chunk) - offset < n:
                    n = len(chunk) - offset
                # Before every piece, take whatever the loop has already
                # acked without blocking — credit, or the disconnect that
                # rides the same fd. A stream of small events never runs
                # out of a 16 KB window, so without this poll a thread
                # whose client vanished would produce until shutdown.
                var polled = _poll_acks(ack_read_fd, slot, credit)
                if polled < 0:
                    gone = True
                    break
                credit = polled
                # Stop-and-wait: the previous piece must have been drained
                # and acked before the next goes out. The wait is detached;
                # a disconnect arrives on the same fd as credit does.
                while credit < n:
                    var acked = _wait_ack(ack_read_fd, slot)
                    if acked < 0:
                        gone = True
                        break
                    credit += acked
                if gone:
                    break
                var frame = encode_bus_frame(
                    asgi_stream_url(String("s"), slot, self.lane), gen,
                    Span(chunk)[offset : offset + n],
                )
                var placed = _place_stream_frame(
                    self.stream_fd, frame, ack_read_fd, slot
                )
                if placed == 0:
                    gone = True
                    break
                if placed < 0:
                    # Unplaceable after waiting detached ~5 s: the loop is
                    # not draining the channel at all. Abort rather than
                    # let a truncated body look complete.
                    print(
                        "m0serve: chunk channel full, abandoning slot "
                        + String(slot) + "'s stream — the response is truncated",
                        flush=True,
                    )
                    aborted = True
                    break
                credit -= n
                offset += n
            if gone or aborted:
                break
        # Always: the application's close(), once, whatever ended this.
        self.apps[app_index].stream_close()
        self.stream_app = -1
        if gone:
            return
        if aborted:
            _ = pool.abort_stream(slot, gen)
            return
        var empty = List[UInt8]()
        var end = encode_bus_frame(
            asgi_stream_url(String("e"), slot, self.lane), gen, Span(empty)
        )
        if _place_stream_frame(self.stream_fd, end, ack_read_fd, slot) < 0:
            _ = pool.abort_stream(slot, gen)

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
        # The slot's reserved channel name carries its producer's address
        # — an executor's lane, or a pool thread's own ack fd; read it
        # before the unsubscribes erase it.
        var slot_url = self.streams.filter_url(slot)
        if slot_url.byte_length() == 0:
            slot_url = self.sockets.filter_url(slot)
        var pool_ack_fd = pool_stream_ack_fd(slot_url) if (
            self.streams.is_slot_streaming(slot)
        ) else -1
        self.streams.unsubscribe(slot)
        self.sockets.unsubscribe(slot)
        if slot < len(self.hold_lane):
            self.hold_lane[slot] = NOT_POOL_HELD
        if slot < len(self.asgi_done):
            self.asgi_done[slot] = False
        if slot < len(self.stream_gen):
            self.stream_gen[slot] = STREAM_GEN_NONE
        if slot < len(self.stream_lost):
            self.stream_lost[slot] = False
        if slot < len(self.ws_in_sent):
            self.ws_in_sent[slot] = 0
            self.ws_in_acked[slot] = 0
            if len(self.ws_parked[slot]) > 0:
                # The connection is gone; what it still owed goes with it.
                self.ws_parked[slot].clear()
                self.ws_parked_count -= 1
        if pool_ack_fd >= 0:
            # A pool thread's stream: its disconnect is an ack of -1 on the
            # thread's own pair — the fd it is already waiting on — never
            # the executor's tag, which on a POOL submit lane would be a
            # nine-byte datagram `next_job` cannot decode.
            _send_pool_disconnect(pool_ack_fd, slot)
        elif was_asgi:
            if self.direct_state_addr != 0:
                # Inverted: the executor is this thread; tell it directly
                # so the disconnect lands before the slot's next job, which
                # would otherwise overtake a tag on the channel (see
                # `PyBridge.notify_disconnect`).
                try:
                    self.apps[0]._bridge.notify_disconnect(slot)
                except e:
                    print("inverted executor: disconnect notify raised: " + String(e), flush=True)
            else:
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
            if ub[1] == UInt8(ord("b")) or ub[1] == UInt8(ord("P")):
                # Begin — an executor's (`b`) or a pool thread's (`P`, whose
                # name also carries the thread's ack fd): sent before the
                # stream's head completion, so this subscription exists
                # before the loop ever drains the slot as a stream. The
                # frame's id is the stream's generation; every chunk and
                # the end must carry the same one.
                self.streams.subscribe(slot, url, NO_EVENT_ID)
                if slot < len(self.asgi_done):
                    self.asgi_done[slot] = False
                self._clear_lost(slot)
                self._set_stream_gen(slot, event_id)
            elif ub[1] == UInt8(ord("s")):
                # A response chunk — for a SUBSCRIBED slot only, and only
                # for the stream that subscribed it. Never subscribe here:
                # a chunk that outlived its connection must be dropped,
                # not injected into whatever the recycled slot serves now.
                # One writer's frames are FIFO behind its own begin; the
                # generation is what tells two writers' apart.
                if self.streams.is_slot_streaming(slot) and self._gen_matches(slot, event_id):
                    if not self.streams.queue_frame(slot, NO_EVENT_ID, frame):
                        # Only backpressure can refuse here (the slot is
                        # streaming and the id is NO_EVENT_ID), and the
                        # producer's credit window is sized to make that
                        # unreachable: a stream may have at most one
                        # window of un-acked bytes outstanding, bytes are
                        # acked only once they have left this outbox, and
                        # the window equals `MAX_PENDING_BYTES`. Reaching
                        # this is therefore a broken invariant, not a busy
                        # server — and the cost of being wrong about it
                        # silently is a stream that stalls for ever, since
                        # the dropped bytes are never drained and so never
                        # credited back.
                        if self._claim_lost(slot, String("response chunk")):
                            self._abort_stream(slot, event_id)
            elif ub[1] == UInt8(ord("e")):
                # End of stream: hand out anything still pending, then
                # stop being a stream (which is what lets the loop close).
                if not self._gen_matches(slot, event_id):
                    return
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
                self._clear_lost(slot)
                self._set_stream_gen(slot, STREAM_GEN_HELD)
            elif ub[1] == UInt8(ord("H")):
                # A socket hold taken on a pool thread. Subscribe it here,
                # where the registries are drained, and remember the lane:
                # an inbound frame has exactly one mount it may be delivered
                # to, and this is the record of which.
                var chan = String(StringSlice(unsafe_from_utf8=Span(frame)))
                self.sockets.subscribe(slot, chan, event_id)
                if slot < len(self.hold_lane):
                    self.hold_lane[slot] = _parse_stream_lane(ub)
                self._clear_lost(slot)
                self._set_stream_gen(slot, STREAM_GEN_HELD)
            elif ub[1] == UInt8(ord("B")):
                # A WebSocket's begin: sent before its held 101 completes,
                # same FIFO anchor as a stream's begin — but into the
                # sockets registry.
                self.sockets.subscribe(slot, url, NO_EVENT_ID)
                if slot < len(self.asgi_done):
                    self.asgi_done[slot] = False
                self._clear_lost(slot)
                self._set_stream_gen(slot, event_id)
                if slot < len(self.ws_in_sent):
                    # A NEW socket on this slot: its inbound window opens
                    # whole, and whatever the last tenant left parked was
                    # that connection's, not this one's.
                    self.ws_in_sent[slot] = 0
                    self.ws_in_acked[slot] = 0
                    if len(self.ws_parked[slot]) > 0:
                        self.ws_parked[slot].clear()
                        self.ws_parked_count -= 1
            elif ub[1] == UInt8(ord("w")):
                # An outbound WS frame, already RFC 6455-encoded by the
                # executor. Subscribed slots only, same recycled-slot
                # safety rule as 's', same generation check.
                if self.sockets.is_slot_streaming(slot) and self._gen_matches(slot, event_id):
                    if not self.sockets.queue_frame(slot, NO_EVENT_ID, frame):
                        # Reachable, unlike the `s` case above: an ASGI
                        # application's `websocket.send` is not credit-gated
                        # at all, so a producer faster than the socket
                        # drains fills this outbox. A dropped frame is a
                        # message the peer cannot know it missed, which is
                        # worse than a closed socket — so close it.
                        if self._claim_lost(slot, String("websocket frame")):
                            self._end_socket(slot)
            elif ub[1] == UInt8(ord("x")):
                # WebSocket end (the close frame is already queued ahead
                # of this on the same channel).
                if not self._gen_matches(slot, event_id):
                    return
                if self.sockets.has_pending(slot):
                    if slot < len(self.asgi_done):
                        self.asgi_done[slot] = True
                else:
                    self.sockets.unsubscribe(slot)
            elif ub[1] == UInt8(ord("r")):
                # Inbound consumption ack: the shim's CUMULATIVE count of
                # datagram bytes the application's `receive()` has taken
                # off its queue — cumulative so a frame this channel had
                # to drop heals at the next one, where a delta would be
                # credit lost for ever. Gen-checked like every sibling
                # (an ack names a slot, and the slot may already belong
                # to a successor), then clamped to what was charged, then
                # monotonic — the same discipline as the loop's own drain
                # acks, for the same recycled-slot reasons.
                if not self._gen_matches(slot, event_id):
                    return
                if slot < len(self.ws_in_acked) and len(frame) >= 8:
                    var consumed = 0
                    for shift in range(8):
                        consumed |= Int(frame[shift]) << (shift * 8)
                    if consumed > self.ws_in_sent[slot]:
                        consumed = self.ws_in_sent[slot]
                    if consumed > self.ws_in_acked[slot]:
                        self.ws_in_acked[slot] = consumed
                    self._ws_drain_parked(slot)
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

    def _clear_lost(mut self, slot: Int):
        """A slot subscribing is a NEW stream; whatever the last one lost is
        no longer this one's business."""
        if slot >= 0 and slot < len(self.stream_lost):
            self.stream_lost[slot] = False

    def _set_stream_gen(mut self, slot: Int, gen: Int):
        if slot >= 0 and slot < len(self.stream_gen):
            self.stream_gen[slot] = gen

    def _gen_matches(self, slot: Int, gen: Int) -> Bool:
        """Whether a chunk/end frame belongs to the stream the slot is
        subscribed to. A slot outside the table (no registries) matches
        nothing, which is the same answer its registry gives."""
        return slot >= 0 and slot < len(self.stream_gen) and self.stream_gen[slot] == gen

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
            self._serve_synthetic(req)
        except e:
            print("ws_message: " + WS_MESSAGE_PATH + " raised: ", e)

    def ws_message_take(mut self, slot: Int, opcode: Int, payload: List[UInt8]) -> Bool:
        # Three ways a socket on this loop can be held, and the message goes
        # wherever its own hold went (`_ws_forward`). What is new is the
        # answer when the hold's channel says no: PARK and return False —
        # the loop stops reading the socket, TCP's zero window stops the
        # client, and the message is delivered when the channel drains —
        # instead of dropping it with a log line the client can never see
        # (2 881 of 3 000 lost at 4 KB, found by an Autobahn run's
        # fragmentation cases). FIFO is the reason a non-empty parked queue
        # parks unconditionally: a message that jumped its parked
        # predecessors would reorder the application's receive stream.
        if slot < len(self.ws_parked) and len(self.ws_parked[slot]) > 0:
            self._ws_park(slot, opcode, payload)
            return False
        if self._ws_forward(slot, opcode, payload):
            return True
        if slot < len(self.ws_parked):
            self._ws_park(slot, opcode, payload)
            return False
        # No parking table (a plain server has capacity 0, and nothing
        # routes through a channel there) — the legacy drop, kept only for
        # a slot the tables cannot cover.
        print(
            "ws_message: no channel would take an inbound message for slot "
            + String(slot) + "; it is lost",
            flush=True,
        )
        return True

    def _ws_forward(mut self, slot: Int, opcode: Int, payload: List[UInt8]) -> Bool:
        """One delivery attempt, shared by the live path and the parked
        drain so the two cannot route differently. True = delivered (or
        served inline); False = the channel or the window refused."""
        # The POOL first: on a mixed mounted server `asgi_notify_fd` is set
        # for the ASGI mount, and asking that question first would hand
        # every socket's message to an executor that never accepted the
        # connection. No credit here — pool threads send no consumption
        # acks — so the channel's own refusal is the whole gate, and the
        # parked drain retries on every pass with something parked.
        if slot < len(self.hold_lane) and self.hold_lane[slot] != NOT_POOL_HELD:
            var held_lane = self.hold_lane[slot]
            var at = held_lane if held_lane > 0 else 0
            if at < len(self.ws_pool_fds) and self.ws_pool_fds[at] >= 0:
                return _send_ws_pool_message(
                    self.ws_pool_fds[at], slot, opcode,
                    self.sockets.filter_url(slot), payload,
                )
            return True
        # Executor mode: the message belongs to the app's own
        # `websocket.receive` loop — forward it to the executor thread as
        # a tagged datagram and never enter Python on the loop thread.
        # Credit-gated on `WS_IN_WINDOW`, charged in datagram bytes and
        # refilled by the shim's cumulative 'r' acks as `receive()`
        # actually consumes: without the gate, the bound on unconsumed
        # inbound bytes was the kernel's channel buffer, and past it the
        # message was lost.
        if self.asgi_notify_fd >= 0 and self.sockets.is_slot_streaming(slot):
            var cost = _ws_in_cost(len(payload))
            if (
                slot < len(self.ws_in_sent)
                and self.ws_in_sent[slot] - self.ws_in_acked[slot] + cost
                > WS_IN_WINDOW
            ):
                return False
            if not _send_ws_message_tag(
                self._notify_fd_for(self.sockets.filter_url(slot)),
                slot, opcode, payload,
            ):
                return False
            if slot < len(self.ws_in_sent):
                self.ws_in_sent[slot] += cost
            return True
        # GRIP mode: an inbound message, handed to a plain synchronous view
        # as a POST. This runs ON the event loop thread, so it costs
        # exactly what any other view costs — the hold pattern removes the
        # *connection* cost from Python, not the *request* cost. Nothing
        # here can refuse, so this path always reports delivered.
        var channel = self.sockets.filter_url(slot)
        if channel.byte_length() == 0:
            return True  # not a held socket of ours; nothing names its channel
        # The response is discarded: what the view does — publishing, writing
        # to a database — is the point, and a hold instruction here would
        # subscribe nothing (the synthetic request carries no slot).
        #
        # `ws_message` is the one hook the trait declares non-raising, so the
        # try is mandatory, not defensive: a raising view must not take the
        # socket, or the loop, down with it.
        try:
            # Same expression the pool path uses, so the two cannot
            # synthesise different paths for the same server.
            var req = ws_message_request(
                self.mount_prefixes[0] + WS_MESSAGE_PATH,
                channel, slot, opcode, Span(payload),
            )
            self._serve_synthetic(req)
        except e:
            print("ws_message: " + WS_MESSAGE_PATH + " raised: ", e)
        return True

    def _ws_park(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        """Append one `[opcode u8][len u32 LE][payload]` record. Parked is
        owed, never dropped; the count is `take_ws_resumes`'s guard."""
        if len(self.ws_parked[slot]) == 0:
            self.ws_parked_count += 1
        self.ws_parked[slot].append(UInt8(opcode))
        var n = UInt32(len(payload))
        for shift in range(0, 32, 8):
            self.ws_parked[slot].append(UInt8((n >> UInt32(shift)) & 0xFF))
        for b in payload:
            self.ws_parked[slot].append(b)

    def _ws_drain_parked(mut self, slot: Int):
        """Replay parked records through `_ws_forward`, in order, stopping
        at the first refusal. A fully drained slot is named for the loop
        to re-arm its read."""
        if slot >= len(self.ws_parked) or len(self.ws_parked[slot]) == 0:
            return
        var at = 0
        while at + 5 <= len(self.ws_parked[slot]):
            var opcode = Int(self.ws_parked[slot][at])
            var n = 0
            for shift in range(4):
                n |= Int(self.ws_parked[slot][at + 1 + shift]) << (shift * 8)
            if at + 5 + n > len(self.ws_parked[slot]):
                break  # malformed tail; drop below rather than loop forever
            var payload = List[UInt8](capacity=n)
            for i in range(n):
                payload.append(self.ws_parked[slot][at + 5 + i])
            if not self._ws_forward(slot, opcode, payload):
                break
            at += 5 + n
        if at >= len(self.ws_parked[slot]):
            self.ws_parked[slot].clear()
            self.ws_parked_count -= 1
            self.ws_resume.append(slot)
        elif at > 0:
            # Shift the undelivered tail down — cheaper than it looks,
            # because this path only runs while a slot is suspended.
            var rest = List[UInt8](capacity=len(self.ws_parked[slot]) - at)
            for i in range(at, len(self.ws_parked[slot])):
                rest.append(self.ws_parked[slot][i])
            self.ws_parked[slot] = rest^

    def take_ws_resumes(mut self) -> List[Int]:
        # The per-pass retry: acks drive the executor path's drain (the
        # 'r' branch), but a pool-held slot has no ack, and an executor
        # drain stopped by a TRANSIENT channel refusal would otherwise
        # wait for an ack that need not come. One scan per pass, guarded
        # by the count so an idle or ordinary pass pays one integer test.
        if self.ws_parked_count > 0:
            for s in range(len(self.ws_parked)):
                if len(self.ws_parked[s]) > 0:
                    self._ws_drain_parked(s)
        if len(self.ws_resume) == 0:
            return List[Int]()
        var out = self.ws_resume.copy()
        self.ws_resume.clear()
        return out^


def _not_found_response() -> HTTPResponse:
    """A plain 404, for a path the server answers itself rather than routes.

    Used for a wire request to `WS_MESSAGE_PATH` under `--realtime`: that
    path exists for the server to synthesise into, and a client asking for
    it directly is told only that there is nothing there.
    """
    return HTTPResponse(
        body_bytes=String('{"error":"not found"}').as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=404,
        status_text="Not Found",
    )


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

comptime WS_CHANNEL_DATAGRAM_MAX = 65546

# The INBOUND window: unacked bytes the loop may have in flight toward one
# executor-held socket's `receive()` queue. Charged in DATAGRAM bytes
# (`_ws_in_cost`) and acked CUMULATIVELY by the shim as the application's
# `receive()` actually consumes ('r' frames on the chunk channel), so a
# lost ack heals at the next one. Must mirror the clamp in the shim's
# `_exec_on_ws_message` (64 KB) — a drift here is a window that never
# fills or never opens. Fits the 256 KB submit channel with 4x headroom
# (`_OFFLOAD_SOCKET_BUF`), which is what makes a mid-window channel
# refusal rare rather than routine.
comptime WS_IN_WINDOW = 65536
"""The receive buffer both channel readers post for an inbound WS message.

`blocking_pool.WS_JOB_BUFFER` and the executor shim's own read size are
this number, and both READ WITHOUT `MSG_TRUNC`: a SOCK_DGRAM datagram
larger than the buffer is copied up to the buffer and the remainder is
DISCARDED, with the short count looking exactly like a short message. The
comment at each of those buffers claimed the loop's `max_message_size` kept
assembled messages underneath it, which is wrong by a factor of 64 --
`max_message_size` is `max_request_body_size`, 4 MB by default, so any
inbound frame between ~64 KB and the socket's send-buffer limit was handed
to the application truncated and presented as complete.

Refusing to send is the honest answer: an oversized message is dropped and
logged, the same way one too big for the socket buffer already was. It is
declared here rather than beside either buffer because both senders live in
this file, and a bound that is not shared with the check is not a bound.
"""

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


def pool_stream_url(slot: Int, lane: Int, ack_fd: Int) -> String:
    """A pool thread's begin-frame name: `\x01P/<slot>/<lane>/<ack_fd>`.

    Its own encoder rather than `asgi_stream_url`, which omits a negative
    lane: the unmounted pool's lane IS -1, and the ack fd has to sit at a
    fixed position for `pool_stream_ack_fd` to find it. The lane is written
    literally, `-1` included; nothing parses it out of a `P` name.
    """
    var b = List[UInt8]()
    b.append(ASGI_URL_CONTROL)
    b.append(UInt8(ord("P")))
    b.append(UInt8(ord("/")))
    for ch in String(slot).as_bytes():
        b.append(ch)
    b.append(UInt8(ord("/")))
    for ch in String(lane).as_bytes():
        b.append(ch)
    b.append(UInt8(ord("/")))
    for ch in String(ack_fd).as_bytes():
        b.append(ch)
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def pool_stream_ack_fd(url: String) -> Int:
    """The ack fd a `P` name carries, or -1 for any other name."""
    var ub = url.as_bytes()
    if len(ub) < 3 or ub[0] != ASGI_URL_CONTROL or ub[1] != UInt8(ord("P")):
        return -1
    return _parse_url_number(ub, 2)


def _send_pool_disconnect(fd: Int, slot: Int):
    """`(slot: i32, -1: i32)` on a pool thread's ack pair: the client is
    gone. The same shape as a credit ack, so the thread's one blocking
    read learns both. Bounded retry, never a park: this runs on the loop."""
    var msg = List[UInt8](capacity=8)
    var s = UInt32(slot)
    for i in range(4):
        msg.append(UInt8((s >> UInt32(8 * i)) & 0xFF))
    for _ in range(4):
        msg.append(UInt8(0xFF))
    for _ in range(64):
        var rc = external_call["send", Int](
            c_int(fd), msg.unsafe_ptr(), UInt(len(msg)), c_int(0)
        )
        if rc == len(msg):
            return
        _ = external_call["sched_yield", c_int]()


def _send_frame_bounded(fd: Int, frame: List[UInt8]) -> Bool:
    """One datagram on a non-blocking channel, 64 tries with yields."""
    for _ in range(64):
        var rc = external_call["send", Int](
            c_int(fd), frame.unsafe_ptr(), UInt(len(frame)), c_int(0)
        )
        if rc == len(frame):
            return True
        _ = external_call["sched_yield", c_int]()
    return False


def _read_ack(fd: Int, flags: c_int, mut slot_out: Int, mut credit_out: Int) -> Int:
    """One `(slot i32, credit i32)` datagram off an ack pair.

    Returns 1 with the fields filled, 0 for nothing there (non-blocking
    only), -1 for EOF or an error other than EINTR (retried inside)."""
    var buf = List[UInt8](capacity=8)
    for _ in range(8):
        buf.append(0)
    while True:
        var rc = external_call["recv", Int](
            c_int(fd), buf.unsafe_ptr(), UInt(8), flags
        )
        if rc == 8:
            var s = UInt32(0)
            var c = UInt32(0)
            for i in range(4):
                s |= UInt32(buf[i]) << UInt32(8 * i)
                c |= UInt32(buf[4 + i]) << UInt32(8 * i)
            slot_out = _i32(s)
            credit_out = _i32(c)
            return 1
        if rc < 0:
            var err = get_errno()
            if err == err.EINTR:
                continue
            # EAGAIN on a non-blocking read, or a dead channel.
            return 0 if flags != c_int(0) else -1
        return -1


def _poll_acks(fd: Int, slot: Int, credit: Int) -> Int:
    """Consume every ack already waiting, without blocking: the new credit
    total, or -1 if one of them was the disconnect for `slot`."""
    var total = credit
    var got_slot = -1
    var amount = 0
    while True:
        var rc = _read_ack(fd, MSG_DONTWAIT, got_slot, amount)
        if rc <= 0:
            return total
        if got_slot != slot:
            continue
        if amount < 0:
            return -1
        total += amount


def _i32(v: UInt32) -> Int:
    """Sign-extend a wire `i32`. `Int(Int32(UInt32(0xFFFFFFFF)))` is
    4294967295 on Mojo 1.0, not -1 — the conversion does not wrap — so the
    disconnect ack (`-1`) has to be recovered by hand."""
    var n = Int(v)
    if n >= 0x80000000:
        n -= 0x100000000
    return n


def _wait_ack(fd: Int, slot: Int) -> Int:
    """Block, DETACHED, until an ack for `slot` arrives on this thread's own
    pair: the credited byte count, or -1 for a disconnect (`-1` credit) or
    a dead channel. Acks naming another slot are stale — the previous
    stream's — and skipped."""
    ref cpy = Python().cpython()
    var got_slot = -1
    var credit = 0
    while True:
        var ts = cpy.PyEval_SaveThread()
        var rc = _read_ack(fd, c_int(0), got_slot, credit)
        cpy.PyEval_RestoreThread(ts)
        if rc < 0:
            return -1
        if got_slot != slot:
            continue
        return credit


def _place_stream_frame(fd: Int, frame: List[UInt8], ack_fd: Int, slot: Int) -> Int:
    """Place one chunk datagram: 1 placed, 0 the client is gone, -1 gave up.

    A dropped chunk is a corrupt body, so a full channel is waited out —
    but DETACHED, the `_send_chunk_frame` discipline: the thread that has
    to drain the channel is the loop, which needs to attach for other
    work. While waiting, the ack pair is polled for a disconnect, so a dead
    client's stream does not sit against a full channel until shutdown.
    Bounded at ~5 s, matching the drain: past that the loop is not
    draining at all and nothing this thread does will help."""
    if _send_frame_bounded(fd, frame):
        return 1
    ref cpy = Python().cpython()
    var ts = cpy.PyEval_SaveThread()
    var result = -1
    var got_slot = -1
    var credit = 0
    for _ in range(25000):
        sleep(0.0002)
        var rc = _read_ack(ack_fd, MSG_DONTWAIT, got_slot, credit)
        if rc == 1 and got_slot == slot and credit < 0:
            result = 0
            break
        if _send_frame_bounded(fd, frame):
            result = 1
            break
    cpy.PyEval_RestoreThread(ts)
    return result


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
    # See WS_CHANNEL_DATAGRAM_MAX: past this the reader silently drops the
    # tail, so the message must not be sent at all.
    if 12 + len(chan) + len(payload) > WS_CHANNEL_DATAGRAM_MAX:
        return False
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


def _ws_in_cost(payload_len: Int) -> Int:
    """What one inbound message charges against `WS_IN_WINDOW`: the DATAGRAM
    bytes (`_send_ws_message_tag`'s 10-byte header plus payload), clamped to
    the window so a single maximal message can still travel. Mirrored by the
    shim's `_exec_on_ws_message`, which acks these exact bytes back — charge
    payload here and be acked datagrams there and the window drifts by ten
    bytes on every message."""
    var cost = 10 + payload_len
    if cost > WS_IN_WINDOW:
        return WS_IN_WINDOW
    return cost


def _send_ws_message_tag(
    fd: Int, slot: Int, opcode: Int, payload: List[UInt8]
) -> Bool:
    """One `[tag=2 u8][slot i64 LE][opcode u8][payload]` datagram.

    The payload rides IN the datagram, so it is bounded by the channel's
    frame size — and by WS_CHANNEL_DATAGRAM_MAX, which is what the reader
    can actually take. Over that it is refused rather than truncated;
    `ws_message` logs the drop. Retried like the disconnect tag — a lost
    inbound message is an app-visible gap."""
    if 10 + len(payload) > WS_CHANNEL_DATAGRAM_MAX:
        return False
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
            return True
        _ = external_call["sched_yield", c_int]()
    return False


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
