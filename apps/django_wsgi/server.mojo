"""Serve a Django project with mojo-http.

    uv run poe serve-django                  # http://localhost:8080
    M0_WORKERS=4 uv run poe serve-django     # prefork: 4 worker processes

The handler is the whole integration: `WSGIApp` is built once at startup and
every request is delegated to it. Compare `apps/hello/server.mojo` — the only
difference is what `func` returns.

`func` runs the Django view synchronously on the event loop, so a process
serves one request at a time; concurrency comes from `M0_WORKERS` forking more
processes, never from threads. The listener is bound *before* the fork and
inherited, gunicorn-style: every worker blocks in `accept()` on the one shared
socket, so the kernel hands each connection to a worker that is actually free
to take it. Per-worker `SO_REUSEPORT` binds would also work on Linux, but not
on macOS, where all connections land on a single socket — and even on Linux
they hash connections to workers with no regard for which worker is busy.

**The fork happens before the first Python call, and must stay there.**
Forking a live CPython interpreter is unsafe, and Mojo initializes the
interpreter lazily on first use — so `fork_all()` runs first, and each worker
that returns from it makes its own first Python call by constructing its own
`WSGIApp` below. Moving the `WSGIApp` construction (or any other Python touch)
above the fork would hand every worker a copy of a live interpreter.
"""

from std.os import getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse
from lightbug_http.connection import ListenConfig

from m0_http import WorkerSupervisor
from m0_http.config import AppConfig
from m0_wsgi import WSGIApp


struct DjangoHandler(HTTPService):
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


def main() raises:
    var config = AppConfig()
    var port = String(config.port)
    # Where `djangoproj` lives. The default assumes the repo root as the working
    # directory, which is what the poe tasks give us; a compiled binary run from
    # anywhere else should set M0_DJANGO_PROJECT.
    var project_path = getenv("M0_DJANGO_PROJECT", "apps/django_wsgi")

    # Bind before forking; every worker accepts from this one socket.
    var listener = ListenConfig().listen(String("0.0.0.0:", port))

    # Fork before touching Python — see the module docstring. The parent stays
    # inside fork_all() supervising; only workers (initial or respawned) return
    # here and continue to server startup.
    var multiprocess = config.workers > 1
    if multiprocess:
        var supervisor = WorkerSupervisor(config.workers)
        supervisor.fork_all()

    var app = WSGIApp(
        "djangoproj.wsgi",
        server_name="0.0.0.0",
        server_port=port,
        project_path=project_path,
        multiprocess=multiprocess,
    )
    var handler = DjangoHandler(app^)

    print("Starting Django server on 0.0.0.0:" + port)
    var server = Server()
    server.serve(listener, handler)
