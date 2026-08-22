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


struct WSGIHandler(HTTPService):
    """Serve a WSGI application, with optional static mounts in front of it."""

    var app: WSGIApp
    var mounts: List[StaticFiles]

    def __init__(out self, var app: WSGIApp):
        self.app = app^
        self.mounts = List[StaticFiles]()

    def __init__(out self, var app: WSGIApp, var mounts: List[StaticFiles]):
        self.app = app^
        self.mounts = mounts^

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
        pass

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
