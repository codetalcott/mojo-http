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

**Construct after `fork_all()`, never before.** The handler owns the
`WSGIApp`, whose construction is the process's first Python call, and a
forked copy of a live interpreter is not safe — see `WSGIApp`.
"""

from lightbug_http import HTTPService, HTTPRequest, HTTPResponse

from m0_http import StaticFiles

from .app import WSGIApp
from .cli import ServeOptions
from .threaded import ThreadHandler, ThreadContext


struct WSGIHandler(ThreadHandler):
    """Serve a WSGI application, with optional static mounts in front of it.

    Also a `ThreadHandler`: under `--threads N` each serving thread calls
    `make(ctx)` to build its own instance — and its own `WSGIApp` and bridge
    — on that thread, from the `ServeOptions` whose address is `ctx.user`.
    """

    var app: WSGIApp
    var mounts: List[StaticFiles]
    var thread_index: Int
    """Which serving thread owns this handler; -1 under prefork or alone.

    Reported as `x-thread` on every response when >= 0 — the `X-Worker`
    precedent, and what `smoke-threads` reads to prove connections spread.
    """

    def __init__(out self, var app: WSGIApp):
        self.app = app^
        self.mounts = List[StaticFiles]()
        self.thread_index = -1

    def __init__(out self, var app: WSGIApp, var mounts: List[StaticFiles]):
        self.app = app^
        self.mounts = mounts^
        self.thread_index = -1

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
    def make(ctx: ThreadContext) raises -> Self:
        """Build this thread's handler from the `ServeOptions` at `ctx.user`.

        The module was imported on the main thread before any thread
        existed, so `WSGIApp` here is a `sys.modules` hit plus a fresh shim
        namespace; `project_path` is left empty for that reason (the path is
        already on `sys.path`, and appending it again per thread would only
        grow the list).
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
        var handler = Self(app^, Self.mounts_for(opts[]))
        handler.thread_index = ctx.index
        return handler^

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        for i in range(len(self.mounts)):
            var hit = self.mounts[i].serve(req)
            if hit:
                return hit.take()
        return self.app.serve(req)

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        if self.thread_index >= 0:
            resp.headers["x-thread"] = String(self.thread_index)

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass
