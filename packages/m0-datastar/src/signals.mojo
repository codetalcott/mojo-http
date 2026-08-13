"""Reading Datastar signals off an inbound request.

Datastar is bidirectional: the server patches signals down over SSE, and the
browser sends the whole signal store back up on every action. This is that
upward half — without it a Datastar app can render but never react.

Depends on `lightbug_http`. Keep `consts.mojo` and `sse.mojo` free of that
dependency so the wire format stays usable on its own.
"""

# Import from the top-level package, not `lightbug_http.http`. Reaching
# straight into the subpackage leaves the parent uninitialised, and
# `lightbug_http/uri.mojo`'s bare `from hashlib.hash import ...` then fails to
# resolve for anything consuming this module through its .mojoc.
from lightbug_http import HTTPRequest


comptime SIGNALS_QUERY_PARAM = "datastar"
"""Query parameter carrying the signal store on GET requests."""

comptime EMPTY_SIGNALS = "{}"
"""Returned when a request carries no signals at all."""


def read_signals(req: HTTPRequest) -> String:
    """Return the client's signal JSON, or `{}` when the request carries none.

    Per the Datastar protocol, signals travel in the `datastar` query parameter
    on GET and in the request body on every other method.

    The query value arrives already percent-decoded (the URI parser applies
    `unquote` with `expand_plus`), so the JSON is returned verbatim. A literal
    `+` inside the JSON reaches us intact because the browser's
    `encodeURIComponent` escapes it to `%2B`.

    The result is a JSON object as text; parse fields out of it with
    `m0_core.json_parse` (`parse_json_field`, `parse_json_int`, ...). This
    returns text rather than a parsed structure so the package stays free of a
    JSON model, and so callers pay only for the fields they actually read.
    """
    if req.method.upper() == "GET":
        var raw = req.uri.queries.get(SIGNALS_QUERY_PARAM)
        if raw:
            var value = raw.value()
            if value.byte_length() > 0:
                return value
        return String(EMPTY_SIGNALS)

    if len(req.body_raw) == 0:
        return String(EMPTY_SIGNALS)
    return String(StringSlice(unsafe_from_utf8=Span(req.body_raw)))
