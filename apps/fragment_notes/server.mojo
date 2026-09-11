"""Fragment notes — the notes resource as an htmx-shaped app.

`apps/notes_api` serves notes as a JSON API. This is the SAME resource as a
server-rendered app: a page with a form, a list that swaps in place, one
note's detail, delete. The browser talks htmx; the server answers HTML.

It was first written the way every Mojo app in this tree was written —
attributes by hand in eight places, `String(...)` concatenation, a
handler-id chain, every view branching on the request header — and gated
on WIRE OUTPUT only (`poe smoke-fragment-notes`), so each of those could be
lifted into the framework under a green gate. This is the app after three
of those lifts, and the smoke has not changed:

- **the URL table names the view.** `urls()` is the whole mapping; a view
  is a function, `add_read` hands it the store borrowed and `add_write`
  hands it `mut`, and there is no dispatch chain to fall through.
- **the fragment names itself.** `Fragment("notes")` writes `id="notes"`
  once, and `f.swap("post", "/notes")` on the form generates the
  `hx-target` from that same id. Nothing in this file types `#notes`.
- **the view returns one thing.** `page_or_fragment` reads `HX-Request`
  and calls `wrap` only when a whole document is wanted, with
  `Vary: HX-Request` on both. No view branches on the header.

Two things are still written the old way, on purpose, because their lifts
are the next two steps: every URL is a literal (`"/notes/"` plus an id, in
three places), and the urlencoded form is parsed by two inline loops at
the bottom of the file.

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

The attribute vocabulary is htmx 2 (`hx-*`), pinned to one CDN version;
`Html.swap` in m0-core is the only place it is spelled.

The store is in-memory, parallel lists, one process — see `notes_api`.

Run it:  uv run poe serve-fragment-notes
"""

from lightbug_http import Server, HTTPRequest, HTTPResponse
from lightbug_http.header import HeaderKey
from lightbug_http.uri import unquote

from m0_core.html import Fragment, Html

from m0_http import reply
from m0_http import (
    AppConfig,
    Views,
    ViewService,
    install_shutdown_signals,
    page_or_fragment,
)

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


# --- templates -----------------------------------------------------------------


struct Site:
    """What the document knows that a fragment does not: the title."""

    var title: String

    def __init__(out self, var title: String):
        self.title = title^


def wrap(site: Site, fragment: String) raises -> String:
    """The document around any fragment: head, the htmx script, the stylesheet."""
    var h = Html(1024)
    h.raw("<!doctype html>\n")
    h.open("html")
    h.attr("lang", "en")
    h.raw("\n")
    h.open("head")
    h.raw("\n")
    h.open("meta")
    h.attr("charset", "utf-8")
    h.raw("\n")
    h.open("meta")
    h.attr("name", "viewport")
    h.attr("content", "width=device-width,initial-scale=1")
    h.raw("\n")
    h.open("title")
    h.text(site.title)
    h.close("title")
    h.raw("\n")
    h.open("script")
    h.attr("src", HTMX_CDN)
    h.close("script")
    h.raw("\n")
    h.raw(_STYLE)
    h.raw("\n")
    h.close("head")
    h.raw("\n")
    h.open("body")
    h.raw("\n")
    h.open("main")
    h.raw("\n")
    h.raw(fragment)
    h.raw("\n")
    h.close("main")
    h.raw("\n")
    h.close("body")
    h.raw("\n")
    h.close("html")
    h.raw("\n")
    return h.finish()


def render_list(store: NoteStore) raises -> String:
    """The `notes` fragment: the form, then every note with its actions."""
    var f = Fragment("notes")
    f.open("form")
    f.swap("post", "/notes")
    f.open("input")
    f.attr("name", "title")
    f.attr("placeholder", "title")
    f.flag("required")
    f.open("textarea")
    f.attr("name", "body")
    f.attr("placeholder", "body")
    f.close("textarea")
    f.open("div")
    for tag in ["work", "home", "later"]:
        f.open("label")
        f.open("input")
        f.attr("type", "checkbox")
        f.attr("name", "tag")
        f.attr("value", tag)
        f.text(String(" ", tag))
        f.close("label")
        f.raw(" ")
    f.close("div")
    f.open("button")
    f.text("Add")
    f.close("button")
    f.close("form")
    f.open("ul")
    for i in range(len(store.ids)):
        var url = String("/notes/", store.ids[i])
        f.open("li")
        f.open("a")
        f.attr("href", url)
        f.swap("get", url)
        f.text(store.titles[i])
        f.close("a")
        for t in range(len(store.tags[i])):
            f.raw(" ")
            f.open("span")
            f.attr("class", "tag")
            f.text(store.tags[i][t])
            f.close("span")
        f.raw(" ")
        f.open("button")
        f.attr("class", "delete")
        f.swap("delete", url)
        f.raw("&times;")
        f.close("button")
        f.close("li")
    f.close("ul")
    if len(store.ids) == 0:
        f.open("p")
        f.text("none yet")
        f.close("p")
    return f.finish()


def render_note(store: NoteStore, i: Int) raises -> String:
    """The same fragment showing one note, so a swap lands in the same place."""
    var f = Fragment("notes")
    f.open("article")
    f.open("h1")
    f.text(store.titles[i])
    f.close("h1")
    f.open("p")
    f.text(store.bodies[i])
    f.close("p")
    if len(store.tags[i]) > 0:
        f.open("p")
        f.attr("class", "tags")
        for t in range(len(store.tags[i])):
            f.open("span")
            f.attr("class", "tag")
            f.text(store.tags[i][t])
            f.close("span")
            f.raw(" ")
        f.close("p")
    f.close("article")
    f.open("p")
    f.open("a")
    f.attr("href", "/notes")
    f.swap("get", "/notes")
    f.text("all notes")
    f.close("a")
    f.close("p")
    return f.finish()


# --- views ---------------------------------------------------------------------


def index(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes — the list."""
    return page_or_fragment(req, render_list(store), Site("notes"), wrap)


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
    return page_or_fragment(req, render_list(store), Site("notes"), wrap)


def detail(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes/:id — one note."""
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    return page_or_fragment(req, render_note(store, i), Site(store.titles[i]), wrap)


def delete(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """DELETE /notes/:id — answers the list without it."""
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    store.remove(i)
    return page_or_fragment(req, render_list(store), Site("notes"), wrap)


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


# --- form parsing, still inline ------------------------------------------------


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


def main() raises:
    var config = AppConfig()
    print("Fragment notes on " + config.base_url)
    var server = Server(config.server_config())
    var handler = ViewService(urls(), NoteStore())
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
