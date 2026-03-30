"""CORS (Cross-Origin Resource Sharing) configuration and header application.

Provides a CorsConfig struct and a pure function to apply CORS headers
to an HTTPResponse. Replaces per-server _add_cors_headers() boilerplate.
"""

from lightbug_http import HTTPResponse, HeaderKey


struct CorsConfig(Copyable, Movable):
    """CORS policy configuration."""
    var allow_origin: String
    var allow_methods: String
    var allow_headers: String
    var expose_headers: String
    var max_age: String

    def __init__(out self):
        """Default CORS config matching existing demo server patterns."""
        self.allow_origin = "*"
        self.allow_methods = "GET,POST,PUT,DELETE,OPTIONS"
        self.allow_headers = "Content-Type,Accept,If-None-Match"
        self.expose_headers = "ETag,X-Request-Id"
        self.max_age = "3600"

    def __init__(out self, *, copy: Self):
        self.allow_origin = copy.allow_origin
        self.allow_methods = copy.allow_methods
        self.allow_headers = copy.allow_headers
        self.expose_headers = copy.expose_headers
        self.max_age = copy.max_age

    def __init__(out self, *, deinit take: Self):
        self.allow_origin = take.allow_origin^
        self.allow_methods = take.allow_methods^
        self.allow_headers = take.allow_headers^
        self.expose_headers = take.expose_headers^
        self.max_age = take.max_age^


def apply_cors_headers(mut resp: HTTPResponse, config: CorsConfig):
    """Apply CORS headers to a response based on config."""
    resp.headers[HeaderKey.ACCESS_CONTROL_ALLOW_ORIGIN] = config.allow_origin
    resp.headers[HeaderKey.ACCESS_CONTROL_ALLOW_METHODS] = config.allow_methods
    resp.headers[HeaderKey.ACCESS_CONTROL_ALLOW_HEADERS] = config.allow_headers
    if len(config.expose_headers) > 0:
        resp.headers[HeaderKey.ACCESS_CONTROL_EXPOSE_HEADERS] = config.expose_headers
    if len(config.max_age) > 0:
        resp.headers[HeaderKey.ACCESS_CONTROL_MAX_AGE] = config.max_age
