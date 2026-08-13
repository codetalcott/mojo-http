"""Serve a Django project with mojo-http.

    uv run poe serve-django      # http://localhost:8080

The handler is the whole integration: `WSGIApp` is built once at startup and
every request is delegated to it. Compare `apps/hello/server.mojo` — the only
difference is what `func` returns.

Blocking `listen_and_serve`, one process. That is the honest shape today:
`func` runs the Django view on the event loop thread, so concurrency would
have to come from `WorkerSupervisor` forking first and each child building its
own `WSGIApp`. See the `m0_wsgi` package docstring.
"""

from std.os import getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse

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
    var port = getenv("M0_PORT", "8080")
    # Where `djangoproj` lives. The default assumes the repo root as the working
    # directory, which is what the poe tasks give us; a compiled binary run from
    # anywhere else should set M0_DJANGO_PROJECT.
    var project_path = getenv("M0_DJANGO_PROJECT", "apps/django_wsgi")

    var app = WSGIApp(
        "djangoproj.wsgi",
        server_name="0.0.0.0",
        server_port=port,
        project_path=project_path,
    )
    var handler = DjangoHandler(app^)

    print("Starting Django server on 0.0.0.0:" + port)
    var server = Server()
    server.listen_and_serve(String("0.0.0.0:", port), handler)
