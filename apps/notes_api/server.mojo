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
from m0_core.html_escape import escape_html
from m0_core.json_parse import parse_json_field

from m0_http import reply
from m0_http import (
    AppConfig,
    CorsConfig,
    HealthRegistry,
    Router,
    apply_cors_headers,
    compute_etag,
    etag_matches,
    install_shutdown_signals,
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
        # escape_html on every stored value, exactly as _note_json uses
        # escape_json_string on the same two fields. Titles and bodies are
        # whatever a POST body carried, and this representation is served as
        # text/html to any client whose Accept prefers it — so an
        # unescaped `<script>` here is stored XSS in every browser that
        # views the note, not a formatting nit.
        return String(
            "<article><h1>", escape_html(self.titles[i]),
            "</h1><p>", escape_html(self.bodies[i]),
            "</p></article>",
        )

    # --- request handling ----------------------------------------------------

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            return reply.json(200, "OK", self.health.to_json())

        # Static files answer before the router: everything under /static/
        # is the mount's business, including its 404s. `serve` returns None
        # for other paths, and routing continues.
        var static_hit = self.static.serve(req)
        if static_hit:
            return static_hit.take()

        # CORS preflight: answer before routing. The actual CORS headers are
        # added in after_response, which runs for this response too.
        if req.method == "OPTIONS":
            var resp = reply.empty(204, "No Content")
            resp.headers[HeaderKey.ALLOW] = self.router.allow_header(path)
            return resp^

        var m = self.router.match(req.method, path)

        if m.method_not_allowed:
            # The router distinguishes "no such path" from "path exists, verb
            # doesn't" — surface that distinction the way RFC 9110 asks.
            var resp = reply.problem(405, "Method Not Allowed", String(
                req.method, " is not supported by ", path
            ), path)
            resp.headers[HeaderKey.ALLOW] = self.router.allow_header(path)
            return resp^

        if not m.matched:
            return reply.problem(404, "Not Found", "no route for this path", path)

        if m.handler_id == H_LIST:
            return self._list(req)
        if m.handler_id == H_CREATE:
            return self._create(req)

        # The :id routes. A non-integer id matches the route pattern but can
        # never name a note, and 404 is about the resource, not the syntax.
        var id = reply.param_int(m.params[0])
        if id < 0:
            return reply.problem(404, "Not Found", "note ids are integers", path)

        if m.handler_id == H_GET:
            return self._get_one(req, id)
        if m.handler_id == H_UPDATE:
            return self._update(req, id)
        return self._delete(req, id)

    def _list(self, req: HTTPRequest) raises -> HTTPResponse:
        var accept = parse_accept(reply.accept_header(req))
        if accept.wants_html:
            var html = String("<ul>")
            for i in range(len(self.ids)):
                html += String(
                    '<li><a href="/notes/', self.ids[i], '">',
                    escape_html(self.titles[i]), "</a></li>",
                )
            html += "</ul>"
            return reply.vary_accept(reply.html(html))
        var json = String("[")
        for i in range(len(self.ids)):
            if i > 0:
                json += ","
            json += self._note_json(i)
        json += "]"
        return reply.vary_accept(reply.json(200, "OK", json))

    def _create(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var body = reply.body_string(req)
        var title = parse_json_field(body, "title")
        if title.byte_length() == 0:
            # RFC 9457: the error body says what was wrong, machine-readably,
            # instead of a bare status code.
            return reply.problem(
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
        var resp = reply.json(201, "Created", self._note_json(len(self.ids) - 1))
        resp.headers[HeaderKey.LOCATION] = String("/notes/", id)
        return resp^

    def _get_one(self, req: HTTPRequest, id: Int) raises -> HTTPResponse:
        var i = self._find(id)
        if i < 0:
            return reply.problem(
                404, "Not Found", "no note with this id",
                String("/notes/", id),
            )

        var accept = parse_accept(reply.accept_header(req))
        if accept.wants_html:
            return reply.vary_accept(reply.html(self._note_html(i)))

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
                var not_modified = reply.empty(304, "Not Modified")
                not_modified.headers[HeaderKey.ETAG] = etag
                return reply.vary_accept(not_modified^)
        var resp = reply.json(200, "OK", json)
        resp.headers[HeaderKey.ETAG] = etag
        return reply.vary_accept(resp^)

    def _update(mut self, req: HTTPRequest, id: Int) raises -> HTTPResponse:
        var i = self._find(id)
        if i < 0:
            return reply.problem(
                404, "Not Found", "no note with this id",
                String("/notes/", id),
            )
        var body = reply.body_string(req)
        var title = parse_json_field(body, "title")
        if title.byte_length() == 0:
            return reply.problem(
                400, "Invalid Note",
                'the request body must be JSON with a non-empty "title"',
                String("/notes/", id),
            )
        self.titles[i] = title
        self.bodies[i] = parse_json_field(body, "body")
        return reply.json(200, "OK", self._note_json(i))

    def _delete(mut self, req: HTTPRequest, id: Int) raises -> HTTPResponse:
        var i = self._find(id)
        if i < 0:
            return reply.problem(
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
        return reply.empty(204, "No Content")

    # --- hooks ---------------------------------------------------------------

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        # One hook, every response — including 304s, problem+json errors, and
        # the OPTIONS preflight. This is the whole CORS story.
        apply_cors_headers(resp, self.cors)

# --- response constructors ---------------------------------------------------







# --- small helpers -----------------------------------------------------------





def main() raises:
    var config = AppConfig()
    print("Notes API on " + config.base_url)
    var server = Server(config.server_config())
    var handler = NotesHandler()
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
