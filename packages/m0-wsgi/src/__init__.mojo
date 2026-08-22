"""`m0-wsgi`: run a WSGI application — Django, Flask, anything — on this server.

A sibling of `m0-datastar`: it layers on `m0_http`/`lightbug_http` and nothing
here is imported back. **This is the only package that embeds CPython.** Keep
it that way — a Python dependency in `m0-http` or `m0-core` would put libpython
on the link line of every build in the repo.

    var app = WSGIApp("myproject.wsgi", server_name="0.0.0.0", server_port="8080")
    ...
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return self.app.serve(req)

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
from .environ import cgi_header_name, serialize_request
from .response import build_response, split_status
from .app import WSGIApp
from .hold import HoldResult, take_stream_hold
