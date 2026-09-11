"""Notes API — what the framework adds over the bare server.

`apps/hello` is lightbug alone: one handler, string comparison on the path.
This example is the m0-http layer on top of it, feature by feature:

    Views                 GET/POST /notes, GET/PUT/DELETE /notes/:id — a
                          table naming the function that answers each, a
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

A view is a free function taking the request, the `:id` captures and the
store; `urls()` is the whole mapping. The handler struct stays because this
app uses the hooks the table does not cover — `after_response` for CORS,
and the static mount and health registry it owns — and calls
`Views.dispatch` from `func`. It used to dispatch on handler ids itself,
and that chain ended in a bare `return self._delete(...)`: a route added
without its own arm did not 404, it deleted. `poe smoke-notes` now asserts
a 405 leaves the note intact.

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
    Views,
    apply_cors_headers,
    compute_etag,
    etag_matches,
    install_shutdown_signals,
    parse_accept,
    StaticFiles,
)


# --- state --------------------------------------------------------------------


struct NoteStore(Movable):
    """Three parallel lists plus the id counter. Ids are stable and never
    reused; deletion swap-pops all three lists in lockstep."""

    var ids: List[Int]
    var titles: List[String]
    var bodies: List[String]
    var next_id: Int

    def __init__(out self):
        self.ids = List[Int]()
        self.titles = List[String]()
        self.bodies = List[String]()
        self.next_id = 1

    def find(self, id: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def add(mut self, var title: String, var body: String) -> Int:
        var id = self.next_id
        self.next_id += 1
        self.ids.append(id)
        self.titles.append(title^)
        self.bodies.append(body^)
        return id

    def remove(mut self, i: Int):
        var last = len(self.ids) - 1
        if i != last:
            self.ids[i] = self.ids[last]
            self.titles[i] = self.titles[last]
            self.bodies[i] = self.bodies[last]
        _ = self.ids.pop()
        _ = self.titles.pop()
        _ = self.bodies.pop()

    def note_json(self, i: Int) -> String:
        # escape_json_string wraps its result in double quotes itself.
        return String(
            '{"id":', self.ids[i],
            ',"title":', escape_json_string(self.titles[i]),
            ',"body":', escape_json_string(self.bodies[i]), "}",
        )

    def note_html(self, i: Int) -> String:
        # escape_html on every stored value, exactly as note_json uses
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


# --- views ---------------------------------------------------------------------


def list_notes(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    var accept = parse_accept(reply.accept_header(req))
    if accept.wants_html:
        var html = String("<ul>")
        for i in range(len(store.ids)):
            html += String(
                '<li><a href="/notes/', store.ids[i], '">',
                escape_html(store.titles[i]), "</a></li>",
            )
        html += "</ul>"
        return reply.vary_accept(reply.html(html))
    var json = String("[")
    for i in range(len(store.ids)):
        if i > 0:
            json += ","
        json += store.note_json(i)
    json += "]"
    return reply.vary_accept(reply.json(200, "OK", json))


def create(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
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
    var id = store.add(title, parse_json_field(body, "body"))
    var resp = reply.json(201, "Created", store.note_json(len(store.ids) - 1))
    resp.headers[HeaderKey.LOCATION] = String("/notes/", id)
    return resp^


def get_one(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    var id = reply.param_int(params[0])
    if id < 0:
        return _bad_id(req.uri.path)
    var i = store.find(id)
    if i < 0:
        return _missing(id)

    var accept = parse_accept(reply.accept_header(req))
    if accept.wants_html:
        return reply.vary_accept(reply.html(store.note_html(i)))

    # ETag + 304 on the JSON representation: hash the exact bytes that
    # would be served, compare against If-None-Match, and skip the body
    # when the client already has it.
    var json = store.note_json(i)
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


def update(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    var id = reply.param_int(params[0])
    if id < 0:
        return _bad_id(req.uri.path)
    var i = store.find(id)
    if i < 0:
        return _missing(id)
    var body = reply.body_string(req)
    var title = parse_json_field(body, "title")
    if title.byte_length() == 0:
        return reply.problem(
            400, "Invalid Note",
            'the request body must be JSON with a non-empty "title"',
            String("/notes/", id),
        )
    store.titles[i] = title
    store.bodies[i] = parse_json_field(body, "body")
    return reply.json(200, "OK", store.note_json(i))


def delete(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    var id = reply.param_int(params[0])
    if id < 0:
        return _bad_id(req.uri.path)
    var i = store.find(id)
    if i < 0:
        return _missing(id)
    store.remove(i)
    return reply.empty(204, "No Content")


def _bad_id(path: String) -> HTTPResponse:
    # A non-integer id matches the route pattern but can never name a note,
    # and 404 is about the resource, not the syntax.
    return reply.problem(404, "Not Found", "note ids are integers", path)


def _missing(id: Int) -> HTTPResponse:
    return reply.problem(
        404, "Not Found", "no note with this id", String("/notes/", id)
    )


def urls() raises -> Views[NoteStore]:
    """The whole URL-to-view mapping. Registration order is the `Allow`
    order a 405 reports."""
    var v = Views[NoteStore]()
    v.add_read("GET", "/notes", list_notes)
    v.add_write("POST", "/notes", create)
    v.add_read("GET", "/notes/:id", get_one)
    v.add_write("PUT", "/notes/:id", update)
    v.add_write("DELETE", "/notes/:id", delete)
    return v^


# --- the handler ---------------------------------------------------------------


struct NotesHandler(HTTPService):
    """The table, the store, and the hooks the table does not cover."""

    var views: Views[NoteStore]
    var store: NoteStore
    var cors: CorsConfig
    var health: HealthRegistry

    # /static/* — files from apps/notes_api/public, ETag/304 included.
    var static: StaticFiles

    def __init__(out self) raises:
        self.views = urls()
        self.store = NoteStore()
        self.static = StaticFiles("apps/notes_api/public", "/static/")
        self.cors = CorsConfig()
        self.health = HealthRegistry()
        self.health.register("store", True)

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
            resp.headers[HeaderKey.ALLOW] = self.views.router.allow_header(path)
            return resp^

        # Match and call the view that owns the route; 404 and 405 (with
        # Allow) are the table's, and there is no fallthrough.
        return self.views.dispatch(req, self.store)

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        # One hook, every response — including 304s, problem+json errors, and
        # the OPTIONS preflight. This is the whole CORS story.
        apply_cors_headers(resp, self.cors)


def main() raises:
    var config = AppConfig()
    print("Notes API on " + config.base_url)
    var server = Server(config.server_config())
    var handler = NotesHandler()
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
