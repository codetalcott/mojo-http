"""`WSGIApp` — a WSGI or ASGI application, wrapped for use from a handler.

The name predates the ASGI half and stays for churn's sake: every handler
and entry point holds one of these, and the struct's job — one application,
one bridge, one `serve` — is protocol-independent. The protocol lives in
the shim (`bridge.mojo`), resolved at `set_app` time; `is_asgi` reports
what was resolved so the entry point can pick defaults and print it.
"""

from std.python import Python, PythonObject

from lightbug_http import HTTPRequest, HTTPResponse

from .bridge import PyBridge, SHIM_SOURCE
from .response import build_response


def detect_protocol(
    module_name: String, attribute: String, forced: String = "auto"
) raises -> Bool:
    """Whether `module_name:attribute` is an ASGI application.

    Startup-only, for callers that must know the protocol before any
    handler exists (`_serve_threaded` picks per-loop defaults on the main
    thread). Execs the shim into a throwaway namespace so the detection
    logic exists exactly once; the module import is a `sys.modules` hit
    when the caller already imported it. Raises when the module or
    attribute is missing, and with a message naming both expected
    signatures when the attribute is not callable — even under a forced
    protocol, so a bad spec fails at startup, not at the first request.
    """
    var builtins = Python.import_module("builtins")
    var ns = Python.dict()
    builtins.exec(PythonObject(SHIM_SOURCE), ns)
    var result = ns["detect_spec"](
        PythonObject(module_name), PythonObject(attribute)
    )
    if forced == "wsgi":
        return False
    if forced == "asgi":
        return True
    return String(py=result) == "asgi"


struct WSGIApp(Movable):
    """One WSGI or ASGI application, with its interpreter helpers.

    Construct at startup and call `serve` from `HTTPService.func`:

        var app = WSGIApp("myproject.wsgi", server_name="0.0.0.0", server_port="8080")
        ...
        def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
            return self.app.serve(req)

    **Under prefork, construct this after any `fork()`, never before.**
    Forking a process that already holds a live CPython interpreter is not
    safe, so a `WorkerSupervisor` must run first and each child build its own
    `WSGIApp`. **Under the threaded mode, construct one per serving thread,
    on that thread**, after the main thread has initialized the interpreter
    and imported the module — `m0_wsgi.threaded` is that choreography.

    **The application runs on its event loop's thread.** `HTTPService.func`
    is called synchronously, so a slow view blocks every other connection
    that loop holds. Concurrency comes from `M0_WORKERS` processes or, on
    free-threaded CPython, `M0_THREADS` threads — each with its own loop,
    handler and bridge; `wsgi.multithread` reports which.
    """

    var _bridge: PyBridge
    var is_asgi: Bool
    """The protocol `set_app` resolved: detected, or forced by `protocol`."""

    def __init__(
        out self,
        module_name: String,
        *,
        server_name: String = "localhost",
        server_port: String = "8080",
        attribute: String = "application",
        project_path: String = "",
        multiprocess: Bool = False,
        multithread: Bool = False,
        protocol: String = "auto",
        lifespan: Bool = True,
    ) raises:
        """Import `module_name` and take its application callable.

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
            multithread: Value for `wsgi.multithread`. True when this app is
                one of several serving threads in one process.
            protocol: `auto` to detect WSGI vs ASGI from the object, or a
                forced `wsgi`/`asgi` for pathological callables the
                detection misreads.
            lifespan: False builds an ASGI bridge whose lifespan never
                runs — the executor mode's fallback shape, where this app
                serves only queue-overflow requests and the executor's own
                app owns the one lifespan per loop. Ignored for WSGI.
        """
        self._bridge = PyBridge()
        self.is_asgi = False
        if project_path:
            Python.add_to_path(project_path)
        var module = Python.import_module(module_name)
        # The application object and the request-invariant environ entries
        # live on the Python side of the bridge from here on — per-request
        # crossings must not carry Python objects (see bridge.mojo). For an
        # ASGI application, set_app also creates the bridge's asyncio loop
        # and runs lifespan startup, so a failing startup raises out of
        # this constructor.
        var resolved = self._bridge.set_app(
            module.__getattr__(attribute), protocol, lifespan
        )
        self.is_asgi = resolved == "asgi"
        self._bridge.set_base(
            server_name, server_port, multiprocess, multithread
        )

    def __init__(out self, *, deinit move: Self):
        self._bridge = move._bridge^
        self.is_asgi = move.is_asgi

    def serve(mut self, req: HTTPRequest) raises -> HTTPResponse:
        """Run one request through the application.

        Raises whatever the application raised. Callers that want the server's
        generic 500 instead can simply let it propagate — the event loop
        catches handler exceptions and answers `InternalError()`.
        """
        var result = self._bridge.run(req)
        return build_response(
            self._bridge, String(py=result[0]), result[1], result[2]
        )

    def shutdown(mut self):
        """Run the application's teardown; a no-op for WSGI.

        For ASGI this is lifespan shutdown plus closing the bridge's
        asyncio loop, so it must run once, at the end of serving, on the
        thread that owns this app, inside its attached region — and never
        raise, because teardown has nowhere to send an error.
        """
        try:
            self._bridge.lifespan_shutdown()
        except:
            pass
