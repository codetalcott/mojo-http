"""Serve a Flask application with mojo-http.

    uv run poe serve-flask                  # http://localhost:8087
    M0_WORKERS=4 uv run poe serve-flask     # prefork: 4 worker processes

The second framework row. Diff this against `apps/django_wsgi/server.mojo` and
`apps/wsgi_bare/server.mojo`: the three are identical apart from the module
name and the default port. That is the point — hosting a new WSGI framework
costs an app directory, not a change to `m0-wsgi`.

The fork rules are the Django row's, unchanged and for the same reasons: bind
the listener before forking so every worker accepts from one socket, and fork
before the first Python call, because forking a live CPython is unsafe and
Mojo initializes the interpreter lazily — so each worker's own `WSGIApp`
construction below is its first Python touch.
"""

from std.os import getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse
from lightbug_http.connection import ListenConfig

from m0_http import WorkerSupervisor, install_shutdown_signals, exit_worker
from m0_http.config import AppConfig
from m0_wsgi import WSGIApp


struct FlaskHandler(HTTPService):
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
    var config = AppConfig(default_port=8087)
    var port = String(config.port)
    var project_path = getenv("M0_FLASK_PROJECT", "apps/flask_wsgi")

    var listener = ListenConfig().listen(String("0.0.0.0:", port))

    var multiprocess = config.workers > 1
    if multiprocess:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()

    var app = WSGIApp(
        "flaskproj.wsgi",
        server_name="0.0.0.0",
        server_port=port,
        project_path=project_path,
        multiprocess=multiprocess,
    )
    var handler = FlaskHandler(app^)

    print("Starting Flask server on 0.0.0.0:" + port)
    var server = Server(config.server_config())
    var shutdown_fd = install_shutdown_signals()
    server.serve_nonblocking(listener, handler, shutdown_read_fd=shutdown_fd)
    if config.workers > 1:
        exit_worker()
