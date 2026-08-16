"""`WSGIApp` — a WSGI application callable, wrapped for use from a handler."""

from std.python import Python, PythonObject

from lightbug_http import HTTPRequest, HTTPResponse

from .bridge import PyBridge
from .environ import serialize_request
from .response import build_response


struct WSGIApp(Movable):
    """One WSGI application, with its interpreter helpers.

    Construct at startup and call `serve` from `HTTPService.func`:

        var app = WSGIApp("myproject.wsgi", server_name="0.0.0.0", server_port="8080")
        ...
        def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
            return self.app.serve(req)

    **Construct this after any `fork()`, never before.** Forking a process
    that already holds a live CPython interpreter is not safe, so a
    `WorkerSupervisor` must run first and each child build its own `WSGIApp`.

    **The application runs on the event loop thread.** `HTTPService.func` is
    called synchronously, so a slow view blocks every other connection in this
    process. Concurrency comes from running more processes, not more threads —
    which is also why `wsgi.multithread` is False.
    """

    var _bridge: PyBridge

    def __init__(
        out self,
        module_name: String,
        *,
        server_name: String = "localhost",
        server_port: String = "8080",
        attribute: String = "application",
        project_path: String = "",
        multiprocess: Bool = False,
    ) raises:
        """Import `module_name` and take its WSGI callable.

        Args:
            module_name: Importable module holding the callable, e.g.
                `"myproject.wsgi"`.
            server_name: Value for `SERVER_NAME`.
            server_port: Value for `SERVER_PORT`.
            attribute: Name of the callable in that module. PEP 3333 and
                Django's `manage.py` both default to `application`.
            project_path: Directory to prepend to `sys.path` before importing.
                Needed when the project is not already installed.
            multiprocess: Value for `wsgi.multiprocess`. True when more than
                one worker process is serving.
        """
        self._bridge = PyBridge()
        if project_path:
            Python.add_to_path(project_path)
        var module = Python.import_module(module_name)
        # The application object and the request-invariant environ entries
        # live on the Python side of the bridge from here on — per-request
        # crossings must not carry Python objects (see bridge.mojo).
        self._bridge.set_app(module.__getattr__(attribute))
        self._bridge.set_base(server_name, server_port, multiprocess)

    def __init__(out self, *, deinit move: Self):
        self._bridge = move._bridge^

    def serve(mut self, req: HTTPRequest) raises -> HTTPResponse:
        """Run one request through the application.

        Raises whatever the application raised. Callers that want the server's
        generic 500 instead can simply let it propagate — the event loop
        catches handler exceptions and answers `InternalError()`.
        """
        var payload = serialize_request(req)
        var result = self._bridge.handle(Span(payload))
        return build_response(
            self._bridge, String(py=result[0]), result[1], result[2]
        )
