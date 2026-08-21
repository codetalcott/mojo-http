"""Serve a bare WSGI application — no framework anywhere in the stack.

    uv run poe serve-wsgi-bare                  # http://localhost:8086
    M0_WORKERS=2 uv run poe serve-wsgi-bare     # prefork: 2 worker processes

This is `apps/django_wsgi/server.mojo` with the framework removed, and the
diff between them is the point: it is empty apart from the module name. What
`m0-wsgi` hosts is WSGI, not Django, and this app is what makes that
demonstrable rather than merely claimed.

It is also the target for `poe smoke-wsgi`. A framework in the middle is a
second suspect for every failure; here a wrong answer is the server's by
construction.

**Two workers are not optional for the whole route table.** `/reentrant`
issues an HTTP request back to this same server from inside a view, and a
worker runs views synchronously on the event loop — with one worker the
sub-request is never accepted, because the only process that could accept it
is blocked in the view that made it. `smoke-wsgi` runs `M0_WORKERS=2`.

The fork rules are `apps/django_wsgi/server.mojo`'s, unchanged and for the
same reasons: bind the listener before forking so every worker accepts from
one socket, and fork before the first Python call, because forking a live
CPython is unsafe and Mojo initializes the interpreter lazily — so each
worker's own `WSGIApp` construction below is its first Python touch.
"""

from std.os import getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse
from lightbug_http.connection import ListenConfig

from m0_http import WorkerSupervisor, install_shutdown_signals, exit_worker
from m0_http.config import AppConfig
from m0_wsgi import WSGIApp


struct BareHandler(HTTPService):
    var app: WSGIApp

    def __init__(out self, var app: WSGIApp):
        self.app = app^

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
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


def main() raises:
    var config = AppConfig(default_port=8086)
    var port = String(config.port)
    # Where `bareapp` lives. The default assumes the repo root as the working
    # directory, which is what the poe tasks give us.
    var project_path = getenv("M0_WSGI_PROJECT", "apps/wsgi_bare")

    var listener = ListenConfig().listen(String("0.0.0.0:", port))

    var multiprocess = config.workers > 1
    if multiprocess:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()

    var app = WSGIApp(
        "bareapp.wsgi",
        server_name="0.0.0.0",
        server_port=port,
        project_path=project_path,
        multiprocess=multiprocess,
    )
    var handler = BareHandler(app^)

    print("Starting bare WSGI server on 0.0.0.0:" + port)
    var server = Server(config.server_config())
    var shutdown_fd = install_shutdown_signals()
    server.serve_nonblocking(listener, handler, shutdown_read_fd=shutdown_fd)
    if config.workers > 1:
        exit_worker()
