"""Fragment notes — the notes resource as an htmx-shaped app, written ugly.

`apps/notes_api` serves notes as a JSON API. This is the SAME resource as a
server-rendered app: a page with a form, a list that swaps in place, one
note's detail, delete. The browser talks htmx; the server answers HTML.

It is deliberately written the way every Mojo app in this tree was written
before the framework layer, so that the diff between this file and its
later shape is exactly what that layer adds. The URL table is the one piece
lifted so far — a view is a function and `urls()` names it — and the rest
stays as it was:

- attributes by hand, quotes and all: `hx-target="#notes"` is typed in
  eight places and nothing checks they agree with `id="notes"`
- HTML by `String(...)` concatenation, `escape_html` on every value
- literal URLs everywhere; a renamed route is a dead link nobody sees
- an inline `application/x-www-form-urlencoded` parser, twice
- every view branches on the `HX-Request` header itself

Do not tidy any of that here. The smoke gate (`poe smoke-fragment-notes`)
pins WIRE OUTPUT only, so each of those can be lifted into the framework
one at a time under a green gate — which is how `reply.mojo` was built.

What the app promises on the wire, and the gate asserts:

    GET  /notes          the list; a bare `<section id="notes">` when the
                         request carries `HX-Request: true`, a whole
                         document otherwise — and `Vary: HX-Request` on both
    POST /notes          a urlencoded form: `title`, `body`, and `tag`
                         repeated once per ticked checkbox; answers the list
    GET  /notes/:id      one note, page or fragment the same way
    DELETE /notes/:id    removes it, answers the list
    GET  /               303 to /notes
    GET  /health         {"status":"ok"}

The attribute vocabulary is htmx 2 (`hx-*`), pinned to one CDN version.
That is provisional: the framework will generate these attributes, and the
generator is the only thing that will know the spelling.

The store is in-memory, parallel lists, one process — see `notes_api`.

Run it:  uv run poe serve-fragment-notes
"""

from lightbug_http import Server, HTTPRequest, HTTPResponse
from lightbug_http.header import HeaderKey
from lightbug_http.uri import unquote

from m0_core.html_escape import escape_html

from m0_http import reply
from m0_http import AppConfig, Views, ViewService, install_shutdown_signals

# Pinned deliberately, as datastar_todo pins its CDN: a floating version
# would let an upstream release break this example without a commit here.
comptime HTMX_CDN = "https://cdn.jsdelivr.net/npm/htmx.org@2.0.4/dist/htmx.min.js"

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}
form{display:grid;gap:.5rem;margin-bottom:1.5rem}
input,textarea{font:inherit;padding:.4rem}
ul{list-style:none;padding:0}li{display:flex;gap:.5rem;align-items:center;padding:.3rem 0}
.tag{font-size:.8rem;background:#eee;border-radius:.5rem;padding:0 .5rem}
button.delete{margin-left:auto}
</style>"""


# --- state --------------------------------------------------------------------


struct NoteStore(Movable):
    """The notes, as parallel lists. Handed to every view as its third argument."""

    var ids: List[Int]
    var titles: List[String]
    var bodies: List[String]
    var tags: List[List[String]]
    var next_id: Int

    def __init__(out self):
        self.ids = List[Int]()
        self.titles = List[String]()
        self.bodies = List[String]()
        self.tags = List[List[String]]()
        self.next_id = 1

    def find(self, id: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def add(mut self, var title: String, var body: String, var tags: List[String]):
        self.ids.append(self.next_id)
        self.next_id += 1
        self.titles.append(title^)
        self.bodies.append(body^)
        self.tags.append(tags^)

    def remove(mut self, i: Int):
        var last = len(self.ids) - 1
        if i != last:
            self.ids[i] = self.ids[last]
            self.titles[i] = self.titles[last]
            self.bodies[i] = self.bodies[last]
            self.tags[i] = self.tags[last].copy()
        _ = self.ids.pop()
        _ = self.titles.pop()
        _ = self.bodies.pop()
        _ = self.tags.pop()


# --- html, by hand -------------------------------------------------------------


def _page(fragment: String) -> String:
    return String(
        "<!doctype html>\n"
        '<html lang="en">\n'
        "<head>\n"
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        "<title>notes</title>\n"
        '<script src="', HTMX_CDN, '"></script>\n',
        _STYLE,
        "\n</head>\n<body>\n<main>\n",
        fragment,
        "\n</main>\n</body>\n</html>\n",
    )


def _list_fragment(store: NoteStore) -> String:
    var out = String('<section id="notes">')
    out += (
        '<form hx-post="/notes" hx-target="#notes" hx-swap="outerHTML">'
        '<input name="title" placeholder="title" required>'
        '<textarea name="body" placeholder="body"></textarea>'
        '<div><label><input type="checkbox" name="tag" value="work"> work</label>'
        ' <label><input type="checkbox" name="tag" value="home"> home</label>'
        ' <label><input type="checkbox" name="tag" value="later"> later</label></div>'
        "<button>Add</button></form><ul>"
    )
    for i in range(len(store.ids)):
        out += String(
            '<li><a href="/notes/', store.ids[i], '" hx-get="/notes/', store.ids[i],
            '" hx-target="#notes" hx-swap="outerHTML">',
            escape_html(store.titles[i]), "</a>",
        )
        for t in range(len(store.tags[i])):
            out += String(' <span class="tag">', escape_html(store.tags[i][t]), "</span>")
        out += String(
            ' <button class="delete" hx-delete="/notes/', store.ids[i],
            '" hx-target="#notes" hx-swap="outerHTML">&times;</button></li>',
        )
    out += "</ul>"
    if len(store.ids) == 0:
        out += "<p>none yet</p>"
    out += "</section>"
    return out


def _detail_fragment(store: NoteStore, i: Int) -> String:
    var out = String(
        '<section id="notes"><article><h1>', escape_html(store.titles[i]),
        "</h1><p>", escape_html(store.bodies[i]), "</p>",
    )
    if len(store.tags[i]) > 0:
        out += '<p class="tags">'
        for t in range(len(store.tags[i])):
            out += String('<span class="tag">', escape_html(store.tags[i][t]), "</span> ")
        out += "</p>"
    out += (
        '</article><p><a href="/notes" hx-get="/notes" hx-target="#notes"'
        ' hx-swap="outerHTML">all notes</a></p></section>'
    )
    return out


# --- the fragment-or-page decision, per view -----------------------------------


def _respond(req: HTTPRequest, fragment: String) -> HTTPResponse:
    var is_hx = False
    var hx = req.headers.get("hx-request")
    if hx:
        is_hx = hx.value() == "true"
    var resp: HTTPResponse
    if is_hx:
        resp = reply.html(fragment)
    else:
        resp = reply.html(_page(fragment))
    # One URL, two representations: a shared cache that stored the
    # fragment would replay it to a direct navigation without this.
    resp.headers[HeaderKey.VARY] = "HX-Request"
    return resp^


# --- form parsing, inline ------------------------------------------------------


def _is_form(req: HTTPRequest) -> Bool:
    var ct = req.headers.get(HeaderKey.CONTENT_TYPE)
    if not ct:
        return False
    return ct.value().lower().startswith("application/x-www-form-urlencoded")


def _form_first(body: String, name: String) raises -> String:
    for item in body.split("&"):
        var kv = String(item).split("=", 1)
        if unquote[expand_plus=True](String(kv[0])) == name:
            if len(kv) == 2:
                return unquote[expand_plus=True](String(kv[1]))
            return String("")
    return String("")


def _form_all(body: String, name: String) raises -> List[String]:
    var out = List[String]()
    for item in body.split("&"):
        var kv = String(item).split("=", 1)
        if unquote[expand_plus=True](String(kv[0])) == name:
            if len(kv) == 2:
                out.append(unquote[expand_plus=True](String(kv[1])))
            else:
                out.append(String(""))
    return out^


# --- views ---------------------------------------------------------------------


def index(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes — the list, as a fragment or a page."""
    return _respond(req, _list_fragment(store))


def create(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """POST /notes — a urlencoded form; answers the list."""
    if not _is_form(req):
        return reply.problem(
            400, "Invalid Note",
            "the request body must be application/x-www-form-urlencoded",
            "/notes",
        )
    var body = reply.body_string(req)
    var title = _form_first(body, "title")
    if title.byte_length() == 0:
        return reply.problem(
            400, "Invalid Note", 'the form must carry a non-empty "title"', "/notes"
        )
    store.add(title, _form_first(body, "body"), _form_all(body, "tag"))
    return _respond(req, _list_fragment(store))


def detail(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes/:id — one note, as a fragment or a page."""
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    return _respond(req, _detail_fragment(store, i))


def delete(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """DELETE /notes/:id — answers the list without it."""
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    store.remove(i)
    return _respond(req, _list_fragment(store))


def root(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    """GET / — the list lives at /notes. A loop view: no state, no job."""
    return reply.redirect(303, "/notes")


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


def _index_of(store: NoteStore, param: String) -> Int:
    """The store index for a `:id` capture, or -1: a non-integer id matches
    the route pattern but can never name a note, and 404 is about the
    resource, not the syntax."""
    var id = reply.param_int(param)
    if id < 0:
        return -1
    return store.find(id)


# --- the table -----------------------------------------------------------------


def urls() raises -> Views[NoteStore]:
    """The whole URL-to-view mapping. Each line names the function that
    answers it and says whether it writes; there is no id to keep in step
    and no dispatch chain to fall through."""
    var v = Views[NoteStore]()
    v.add_loop("GET", "/health", health)
    v.add_loop("GET", "/", root)
    v.add_read("GET", "/notes", index)
    v.add_write("POST", "/notes", create)
    v.add_read("GET", "/notes/:id", detail)
    v.add_write("DELETE", "/notes/:id", delete)
    return v^


def main() raises:
    var config = AppConfig()
    print("Fragment notes on " + config.base_url)
    var server = Server(config.server_config())
    var handler = ViewService(urls(), NoteStore())
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
