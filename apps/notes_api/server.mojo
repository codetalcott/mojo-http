"""Notes API — what the framework adds over the bare server.

`apps/hello` is lightbug alone: one handler, string comparison on the path.
This example is the m0-http layer on top of it, feature by feature:

    Router                GET/POST /notes, GET/PUT/DELETE /notes/:id — and a
                          real 405 with an Allow header, not a lazy 404
    content negotiation   the same note as JSON or HTML, chosen by Accept;
                          `*/*` resolves to JSON, so plain curl gets JSON
    ETag + 304            GET /notes/:id answers If-None-Match with an empty
                          304 when the note hasn't changed
    problem+json          every error body is RFC 9457, machine-readable
    CORS                  one `after_response` hook covers every response,
                          preflight OPTIONS included
    config                M0_PORT via AppConfig — no flags, no config file
    health                GET /health from a HealthRegistry

The store is in-memory, parallel lists (SoA — the repo convention around
`List[Struct]` copyability), and deliberately not a database: the example is
about the HTTP layer. Notes do not survive a restart, and `M0_WORKERS` would
give each worker its own store — run one process.

Run it:  uv run poe serve-notes
"""

from std.os import getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse
from lightbug_http.header import Headers, Header, HeaderKey

from m0_core.json_escape import escape_json_string
from m0_core.json_parse import parse_json_field

from m0_http import (
    AppConfig,
    CorsConfig,
    HealthRegistry,
    Router,
    apply_cors_headers,
    compute_etag,
    etag_matches,
    parse_accept,
    StaticFiles,
)

# Router handler ids. The router maps (method, pattern) to one of these; func
# dispatches on them. comptime, so a typo is a compile error, not a 500.
comptime H_LIST = 0
comptime H_CREATE = 1
comptime H_GET = 2
comptime H_UPDATE = 3
comptime H_DELETE = 4


struct NotesHandler(HTTPService):
    """CRUD over an in-memory note store, one instance per process."""

    var router: Router
    var cors: CorsConfig
    var health: HealthRegistry
    # The store: three parallel lists plus the id counter. Ids are stable and
    # never reused; deletion swap-pops all three lists in lockstep.
    var ids: List[Int]
    var titles: List[String]
    var bodies: List[String]
    var next_id: Int

    # /static/* — files from apps/notes_api/public, ETag/304 included.
    var static: StaticFiles

    def __init__(out self):
        self.static = StaticFiles("apps/notes_api/public", "/static/")
        self.router = Router()
        self.router.add("GET", "/notes", H_LIST)
        self.router.add("POST", "/notes", H_CREATE)
        self.router.add("GET", "/notes/:id", H_GET)
        self.router.add("PUT", "/notes/:id", H_UPDATE)
        self.router.add("DELETE", "/notes/:id", H_DELETE)
        self.cors = CorsConfig()
        self.health = HealthRegistry()
        self.health.register("store", True)
        self.ids = List[Int]()
        self.titles = List[String]()
        self.bodies = List[String]()
        self.next_id = 1

    # --- store ---------------------------------------------------------------

    def _find(self, id: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def _note_json(self, i: Int) -> String:
        # escape_json_string wraps its result in double quotes itself.
        return String(
            '{"id":', self.ids[i],
            ',"title":', escape_json_string(self.titles[i]),
            ',"body":', escape_json_string(self.bodies[i]), "}",
        )

    def _note_html(self, i: Int) -> String:
        return String(
            "<article><h1>", self.titles[i], "</h1><p>", self.bodies[i],
            "</p></article>",
        )

    # --- request handling ----------------------------------------------------

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            return _json(200, "OK", self.health.to_json())

        # Static files answer before the router: everything under /static/
        # is the mount's business, including its 404s. `serve` returns None
        # for other paths, and routing continues.
        var static_hit = self.static.serve(req)
        if static_hit:
            return static_hit.take()

        # CORS preflight: answer before routing. The actual CORS headers are
        # added in after_response, which runs for this response too.
        if req.method == "OPTIONS":
            var resp = _empty(204, "No Content")
            resp.headers[HeaderKey.ALLOW] = self._allow_header(path)
            return resp^

        var m = self.router.match(req.method, path)

        if m.method_not_allowed:
            # The router distinguishes "no such path" from "path exists, verb
            # doesn't" — surface that distinction the way RFC 9110 asks.
            var resp = _problem(405, "Method Not Allowed", String(
                req.method, " is not supported by ", path
            ), path)
            resp.headers[HeaderKey.ALLOW] = self._allow_header(path)
            return resp^

        if not m.matched:
            return _problem(404, "Not Found", "no route for this path", path)

        if m.handler_id == H_LIST:
            return self._list(req)
        if m.handler_id == H_CREATE:
            return self._create(req)

        # The :id routes. A non-integer id matches the route pattern but can
        # never name a note, and 404 is about the resource, not the syntax.
        var id = _parse_id(m.params[0])
        if id < 0:
            return _problem(404, "Not Found", "note ids are integers", path)

        if m.handler_id == H_GET:
            return self._get_one(req, id)
        if m.handler_id == H_UPDATE:
            return self._update(req, id)
        return self._delete(req, id)

    def _list(self, req: HTTPRequest) raises -> HTTPResponse:
        var accept = parse_accept(_accept_header(req))
        if accept.wants_html:
            var html = String("<ul>")
            for i in range(len(self.ids)):
                html += String(
                    '<li><a href="/notes/', self.ids[i], '">',
                    self.titles[i], "</a></li>",
                )
            html += "</ul>"
            return _vary_accept(_html(html))
        var json = String("[")
        for i in range(len(self.ids)):
            if i > 0:
                json += ","
            json += self._note_json(i)
        json += "]"
        return _vary_accept(_json(200, "OK", json))

    def _create(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var body = _body_string(req)
        var title = parse_json_field(body, "title")
        if title.byte_length() == 0:
            # RFC 9457: the error body says what was wrong, machine-readably,
            # instead of a bare status code.
            return _problem(
                400, "Invalid Note",
                'the request body must be JSON with a non-empty "title"',
                "/notes",
            )
        var note_body = parse_json_field(body, "body")
        var id = self.next_id
        self.next_id += 1
        self.ids.append(id)
        self.titles.append(title)
        self.bodies.append(note_body)
        var resp = _json(201, "Created", self._note_json(len(self.ids) - 1))
        resp.headers[HeaderKey.LOCATION] = String("/notes/", id)
        return resp^

    def _get_one(self, req: HTTPRequest, id: Int) raises -> HTTPResponse:
        var i = self._find(id)
        if i < 0:
            return _problem(
                404, "Not Found", "no note with this id",
                String("/notes/", id),
            )

        var accept = parse_accept(_accept_header(req))
        if accept.wants_html:
            return _vary_accept(_html(self._note_html(i)))

        # ETag + 304 on the JSON representation: hash the exact bytes that
        # would be served, compare against If-None-Match, and skip the body
        # when the client already has it.
        var json = self._note_json(i)
        var json_bytes = List[UInt8]()
        json_bytes.extend(json.as_bytes())
        var etag = compute_etag(json_bytes)
        var inm = req.headers.get(HeaderKey.IF_NONE_MATCH)
        if inm:
            if etag_matches(etag, inm.value()):
                var not_modified = _empty(304, "Not Modified")
                not_modified.headers[HeaderKey.ETAG] = etag
                return _vary_accept(not_modified^)
        var resp = _json(200, "OK", json)
        resp.headers[HeaderKey.ETAG] = etag
        return _vary_accept(resp^)

    def _update(mut self, req: HTTPRequest, id: Int) raises -> HTTPResponse:
        var i = self._find(id)
        if i < 0:
            return _problem(
                404, "Not Found", "no note with this id",
                String("/notes/", id),
            )
        var body = _body_string(req)
        var title = parse_json_field(body, "title")
        if title.byte_length() == 0:
            return _problem(
                400, "Invalid Note",
                'the request body must be JSON with a non-empty "title"',
                String("/notes/", id),
            )
        self.titles[i] = title
        self.bodies[i] = parse_json_field(body, "body")
        return _json(200, "OK", self._note_json(i))

    def _delete(mut self, req: HTTPRequest, id: Int) raises -> HTTPResponse:
        var i = self._find(id)
        if i < 0:
            return _problem(
                404, "Not Found", "no note with this id",
                String("/notes/", id),
            )
        var last = len(self.ids) - 1
        if i != last:
            self.ids[i] = self.ids[last]
            self.titles[i] = self.titles[last]
            self.bodies[i] = self.bodies[last]
        _ = self.ids.pop()
        _ = self.titles.pop()
        _ = self.bodies.pop()
        return _empty(204, "No Content")

    def _allow_header(self, path: String) -> String:
        """Methods the router would accept for this path, plus OPTIONS."""
        var methods = List[String]()
        methods.append("GET")
        methods.append("POST")
        methods.append("PUT")
        methods.append("DELETE")
        var allow = String()
        for method in methods:
            if self.router.match(method, path).matched:
                if allow.byte_length() > 0:
                    allow += ", "
                allow += method
        if allow.byte_length() > 0:
            allow += ", OPTIONS"
        else:
            allow = "OPTIONS"
        return allow

    # --- hooks ---------------------------------------------------------------

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        # One hook, every response — including 304s, problem+json errors, and
        # the OPTIONS preflight. This is the whole CORS story.
        apply_cors_headers(resp, self.cors)

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


# --- response constructors ---------------------------------------------------


def _json(status: Int, text: String, body: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=status,
        status_text=text,
    )


def _html(body: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, "text/html; charset=utf-8")
        ),
        status_code=200,
        status_text="OK",
    )


def _vary_accept(var resp: HTTPResponse) -> HTTPResponse:
    """Mark a response whose representation was chosen by the Accept header.

    Without `Vary: Accept`, a shared cache that stored the HTML answer would
    happily replay it to a JSON client. Every negotiated representation gets
    it — the 304 included, per RFC 9110 §15.4.5.
    """
    resp.headers[HeaderKey.VARY] = "Accept"
    return resp^


def _empty(status: Int, text: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String("").as_bytes(),
        status_code=status,
        status_text=text,
    )


def _problem(
    status: Int, title: String, detail: String, instance: String
) -> HTTPResponse:
    """An RFC 9457 problem+json response."""
    # escape_json_string wraps its result in double quotes itself.
    var body = String(
        '{"type":"about:blank","title":', escape_json_string(title),
        ',"status":', status,
        ',"detail":', escape_json_string(detail),
        ',"instance":', escape_json_string(instance), "}",
    )
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, "application/problem+json")
        ),
        status_code=status,
        status_text=title,
    )


# --- small helpers -----------------------------------------------------------


def _accept_header(req: HTTPRequest) raises -> String:
    """The Accept header, with absence meaning "anything" per RFC 9110 —
    which this app's negotiation policy resolves to JSON."""
    var accept = req.headers.get(HeaderKey.ACCEPT)
    if accept:
        return accept.value()
    return String("*/*")


def _body_string(req: HTTPRequest) -> String:
    if len(req.body_raw) == 0:
        return String("")
    return String(StringSlice(unsafe_from_utf8=Span(req.body_raw)))


def _parse_id(s: String) -> Int:
    """Parse a decimal note id; -1 when the segment is not a number."""
    if s.byte_length() == 0:
        return -1
    var result = 0
    var bytes = s.as_bytes()
    for i in range(s.byte_length()):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return -1
        result = result * 10 + (c - ord("0"))
    return result


def main() raises:
    var config = AppConfig()
    print("Notes API on " + config.base_url)
    var server = Server()
    var handler = NotesHandler()
    server.listen_and_serve_nonblocking(config.address(), handler)
