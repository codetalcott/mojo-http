"""`WSGIApp` — a WSGI or ASGI application, wrapped for use from a handler.

The name predates the ASGI half and stays for churn's sake: every handler
and entry point holds one of these, and the struct's job — one application,
one bridge, one `serve` — is protocol-independent. The protocol lives in
the shim (`bridge.mojo`), resolved at `set_app` time; `is_asgi` reports
what was resolved so the entry point can pick defaults and print it.
"""

from std.python import Python, PythonObject

from lightbug_http import HTTPRequest, HTTPResponse

from .bridge import PyBridge
from .cli import discovery_specs, parse_app_spec
from .shim_source import SHIM_SOURCE
from .response import build_response


def resolve_app(
    module: String, attribute: String, explicit: Bool, forced: String = "auto"
) raises -> Tuple[String, String, Bool]:
    """Import one application spec, run discovery, and detect its protocol.

    Returns `(module, attribute, is_asgi)` for what will actually be
    served. The ONE resolver for the positional spec and for every
    `--mount`, so the two cannot answer the same spec differently -- they
    did: the mount loop was a copy without the re-raise below, so
    `--mount /=proj` whose `proj.asgi` raised on import reported the first
    candidate's miss instead, or served `proj.wsgi` if that one imported.

    An explicit `MODULE:ATTR` detects exactly what it names. A bare
    `MODULE` tries the `discovery_specs` conventions in order -- Django's
    `asgi.py`/`wsgi.py` and the `main:app` shape -- and the first that
    imports and classifies wins. A candidate that exists and RAISES on
    import is the answer, not a miss to be papered over by the next
    convention: the shim attaches the traceback to exactly that case
    (`detect_spec`), and the discovery list would only hide it. On a total
    miss, the primary spec's own error leads and every candidate tried is
    listed.

    Detection only, no lifespan: the caller must have put `--app-dir` on
    `sys.path`, and every import here is a `sys.modules` hit for the
    handlers that follow.
    """
    if explicit:
        return (module, attribute, detect_protocol(module, attribute, forced))
    var specs = discovery_specs(module)
    var first_error = String("")
    for i in range(len(specs)):
        var pair = parse_app_spec(specs[i])
        try:
            var is_asgi = detect_protocol(pair[0], pair[1], forced)
            return (pair[0], pair[1], is_asgi)
        except e:
            if String(e).find("Traceback (most recent call last)") >= 0:
                raise Error(String(e))
            if i == 0:
                first_error = String(e)
    raise Error(first_error + " (tried " + _specs_tried(specs) + ")")


def _specs_tried(specs: List[String]) -> String:
    """The discovery candidates as one comma-separated list, for errors."""
    var joined = String("")
    for i in range(len(specs)):
        if i > 0:
            joined += ", "
        joined += specs[i]
    return joined^


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


def prepend_to_path(directory: String) raises:
    """Put `directory` FIRST on `sys.path`, the way every other server does.

    `Python.add_to_path` appends, which is the opposite of gunicorn,
    uvicorn and `manage.py runserver` — all three `sys.path.insert(0, ...)`.
    The difference is invisible until an application module shares a name
    with an installed package, at which point the installed one wins and the
    application silently is not the one being served. Found by dogfooding
    the wheel against a real Django project, where the reported `sys.path`
    put `--app-dir` after site-packages, and reconfirmed by the
    three-project pass (docs/REAL_APP_VALIDATION.md).

    A `PythonObject` call, so it leaks a reference by the toolchain bug the
    bridge documents — startup-only and once per process, which is the same
    deliberate exception `set_app` takes. Per-request code may not do this.

    Idempotent by construction: an entry already at the front is not moved,
    and a duplicate further down is left alone rather than removed, because
    a path the user put there is not this function's to edit.
    """
    var sys = Python.import_module("sys")
    if Int(py=sys.path.__len__()) > 0:
        if String(py=sys.path[0]) == directory:
            return
    _ = sys.path.insert(0, directory)


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
        script_name: String = "",
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
            script_name: The prefix this application is mounted at, without
                a trailing slash (`--mount`); empty at the root. Reaches
                WSGI as `SCRIPT_NAME` with `PATH_INFO` trimmed to the
                remainder, and ASGI as `root_path` with `path` left whole —
                the two protocols disagree about that, and `set_base` is
                the one place either learns it.
        """
        self._bridge = PyBridge()
        self.is_asgi = False
        if project_path:
            prepend_to_path(project_path)
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
            server_name, server_port, multiprocess, multithread,
            script_name=script_name,
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
        # A 4-tuple whose last element is true is a streamed WSGI body: the
        # shim kept the iterable and this is its head. The pool thread asks
        # `stream_pending` after `func` and produces the body through
        # `stream_next`/`stream_close`. `len()` on a PythonObject is one of
        # the crossings the bridge documents as leak-free.
        var streaming = len(result) >= 4 and Bool(py=result[3])
        self._bridge.stream_pending = streaming
        try:
            return build_response(
                self._bridge, String(py=result[0]), result[1], result[2],
                streaming=streaming, is_head=req.method == "HEAD",
            )
        except e:
            if streaming:
                # The shim kept the iterable for a head that cannot be built
                # -- a header value that is not a str, say. The request
                # becomes a 500, so nothing will ever pull that iterable,
                # and nothing but this would close it: PEP 3333 owes the
                # application its close() however the response ended.
                self._bridge.stream_close()
            raise e^

    def set_stream_capable(mut self, flag: Bool) raises:
        """Startup-only: let the shim stream iterables (a pool thread with a
        chunk channel), or keep joining them (the loop's own handler)."""
        self._bridge.set_stream_capable(flag)

    def stream_next(mut self) raises -> List[UInt8]:
        """The next chunk of the streamed body; empty at the end."""
        return self._bridge.stream_next()

    def stream_close(mut self):
        """Close the streamed iterable. Idempotent; never raises."""
        self._bridge.stream_close()

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
