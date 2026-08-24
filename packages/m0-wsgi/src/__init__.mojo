"""`m0-wsgi`: run a WSGI application — Django, Flask, anything — on this server.

A sibling of `m0-datastar`: it layers on `m0_http`/`lightbug_http` and nothing
here is imported back. **This is the only package that embeds CPython.** Keep
it that way — a Python dependency in `m0-http` or `m0-core` would put libpython
on the link line of every build in the repo.

    var app = WSGIApp("myproject.wsgi", server_name="0.0.0.0", server_port="8080")
    ...
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.app.serve(req)

`WSGIHandler` is that handler, written once, with static mounts in front of
it; `m0serve` (the package-root entry file, built by `poe build-serve`) is the
uvicorn-shaped binary that runs it:

    bin/m0serve myproject.wsgi:application --app-dir /path/to/project --port 8000

Known limits, all inherited from the server rather than the bridge:

- **Responses are fully buffered.** `HTTPResponse` always emits
  `Content-Length`; there is no chunked encoding. Django's
  `StreamingHttpResponse` and `FileResponse` are materialized in memory.
- **Request bodies are fully buffered too**, and capped by
  `ServerConfig.max_request_body_size` (4 MB by default). Raise it for uploads.
- **One request at a time per process.** See `WSGIApp` for why.
- **No TLS.** `wsgi.url_scheme` is always `http`; terminate at a proxy and set
  Django's `SECURE_PROXY_SSL_HEADER`.
"""

from .bridge import PyBridge, SHIM_SOURCE
from .environ import (
    all_ascii,
    append_cgi_name_as_utf8,
    append_latin1_as_utf8,
    cgi_header_name,
    cgi_name_utf8,
)
from .response import build_response, split_status
from .app import WSGIApp, detect_protocol
from .handler import WSGIHandler
from .threaded import (
    ThreadedServer,
    ThreadHandler,
    ThreadContext,
    DetachingBackend,
    FreeThreadingReport,
    probe_free_threading,
    refusal_message,
    require_free_threading,
    EXIT_NOT_FREE_THREADED,
)
from .blocking_pool import BlockingPool
from .asgi_executor import AsgiExecutor
from .cli import (
    ServeOptions,
    parse_args,
    parse_app_spec,
    parse_size,
    parse_int,
    usage,
    zero_config_topology,
    default_blocking_threads,
    resolve_blocking_threads,
    use_asgi_executor,
    effective_cpus,
    discovery_specs,
    M0SERVE_VERSION,
    DEFAULT_PORT,
    EXIT_USAGE,
    EXIT_STARTUP,
    PROTOCOL_AUTO,
    PROTOCOL_WSGI,
    PROTOCOL_ASGI,
    MAX_AUTO_BLOCKING_THREADS,
)
from .hold import (
    HoldResult,
    take_hold,
    take_stream_hold,
    request_last_event_id,
    ws_message_request,
    HOLD_NONE,
    HOLD_STREAM,
    HOLD_WEBSOCKET,
    CHANNEL_HEADER,
    SLOT_HEADER,
    OPCODE_HEADER,
)
