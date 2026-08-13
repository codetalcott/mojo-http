"""`HTTPRequest` → WSGI `environ` (PEP 3333).

The CGI-variable half of the mapping is pure string work and is tested without
an interpreter; only `build_environ` needs Python.
"""

from std.python import Python, PythonObject

from lightbug_http import HTTPRequest, HeaderKey

from .bridge import PyBridge


def cgi_header_name(header_key: String) -> String:
    """Lowercased header name → CGI variable name.

    `content-type` → `CONTENT_TYPE`, everything else gets the `HTTP_` prefix:
    `accept-encoding` → `HTTP_ACCEPT_ENCODING`. PEP 3333 requires
    Content-Type and Content-Length *without* the prefix.
    """
    var upper = header_key.upper().replace("-", "_")
    if upper == "CONTENT_TYPE" or upper == "CONTENT_LENGTH":
        return upper
    return String("HTTP_", upper)


def build_environ(
    bridge: PyBridge,
    req: HTTPRequest,
    server_name: String,
    server_port: String,
    multiprocess: Bool = False,
) raises -> PythonObject:
    """Build the WSGI `environ` dict for one request.

    `PATH_INFO` comes from `req.uri.path`, which the URI parser has already
    percent-decoded — which is what PEP 3333 asks for. `QUERY_STRING` comes
    from `req.uri.query_string`, which is deliberately still raw.
    """
    var environ = Python.dict()

    environ["REQUEST_METHOD"] = req.method
    environ["PATH_INFO"] = req.uri.path
    environ["QUERY_STRING"] = req.uri.query_string
    environ["SERVER_NAME"] = server_name
    environ["SERVER_PORT"] = server_port
    environ["SERVER_PROTOCOL"] = req.protocol
    environ["SCRIPT_NAME"] = ""
    environ["REMOTE_ADDR"] = ""

    for key in req.headers.keys():
        var value = req.headers.get(key)
        if value:
            environ[cgi_header_name(key)] = value.value()

    environ["wsgi.version"] = Python.tuple(1, 0)
    # No TLS in this server; a proxy terminating TLS should send
    # X-Forwarded-Proto, which Django reads via SECURE_PROXY_SSL_HEADER.
    environ["wsgi.url_scheme"] = "http"
    environ["wsgi.input"] = bridge.make_input(Span(req.body_raw))
    environ["wsgi.errors"] = bridge.stderr()
    # The event loop is single-threaded and calls the handler synchronously,
    # so an application never sees two concurrent requests in one process.
    environ["wsgi.multithread"] = False
    environ["wsgi.multiprocess"] = multiprocess
    environ["wsgi.run_once"] = False

    return environ^
