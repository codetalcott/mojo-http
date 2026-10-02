"""Table notes — a resource over a SQLite table, cached by the change clock.

`apps/fragment_notes` keeps its notes in a list in one process. These are
rows of a table, in a file any number of loops, workers and other programs
may open, and the app is what that takes:

- **the resource is its routes, named once.** `v.resource(NOTES, new=...,
  create=..., show=..., edit=..., update=..., delete=...)` is the table
  below. Create and edit are PLAIN forms answered with a 303, which is why
  `update` is reached by `POST /notes/:id/edit` as well as by PUT: a form
  cannot PUT. The DELETE is the one swap, a button in the list.
- **two connections per thread, and the reader never writes.** `writer`
  is `open()`, `reader` is `open_readonly()` on the same file. Every view
  renders through the reader, so what it renders and the clock it asks are
  one connection's.
- **the list is rendered when the clock moves, and not before.**
  `reader.data_version()` is a number that differs once another
  connection has committed, this thread's own writer included. The view
  asks it (about a microsecond), and renders only when `Cached` was
  filled at another value. That view fills a cache, so it writes, and
  registers with `add_write` beside the resource rather than in its
  `list` slot.
- **the validator is a hash of what is sent.** `conditional` puts an
  `ETag` over the response's own body and answers 304 to a client that
  names it. A commit to another table moves the clock, costs one
  rendering, and leaves the tag where it was.
- **a row has one name.** The id in a URL is the rowid written the one
  way a number is: `/notes/7` is the row and `/notes/07` is a 404. And a
  name has one row: the key is `AUTOINCREMENT`, so a deleted note's id is
  not given to the next.
- **the page is what is rendered.** A list is `LIST_PAGE` rows after a
  rowid (`?after=`), the same continuation under inserts and deletes
  between two reads; only the first page is kept.

Nothing is shared between threads but the file. Each loop under
`M0_THREADS` and each pool thread builds its own `Notes`, with its own
two connections and its own cache, and every one of them serves what the
others wrote: no lock held across a render, no bus, no `max_workers`.
Their tags agree because they hash the same bytes. The gate runs it at
two loops on threads; forked workers would serve the same way, with the
caution every m0-sqlite application has on macOS, where a connection
opened after a fork wants `OS_ACTIVITY_MODE=disable`.

No session and so no CSRF token: `apps/fragment_notes` is the login, and
`m0 new --template auth` is the two together.

    GET    /notes            the list, a page of it; ETag, 304
    GET    /notes/new        the form that creates
    POST   /notes            `title` and `body`; 303 to the note, or 422
                             with the form and what was wrong
    GET    /notes/:id        one note; ETag, 304
    GET    /notes/:id/edit   the form that updates
    PUT    /notes/:id        the same fields; 303 to the note
    POST   /notes/:id/edit   the same view, for the form
    DELETE /notes/:id        removes it; answers the list
    GET    /stats            this loop's cache: {"worker","fills","clock"}
    GET    /                 303 to /notes
    GET    /health           {"status":"ok"}

The database is `M0_DB`, else `table_notes.db` in the working directory.

Run it:  uv run poe serve-table-notes
"""

from std.os import getenv

from lightbug_http import HTTPRequest, HTTPResponse
from m0_host.flags import host_config
from m0_host.host import HostContext, ViewState, ViewsApp, serve

from m0_http import reply
from m0_http import (
    Cached,
    Fragment,
    Html,
    Htmx,
    PageShell,
    Query,
    RESOURCE_EDIT,
    RESOURCE_ITEM,
    RESOURCE_NEW,
    Views,
    attr,
    conditional,
    el,
    flag,
    form,
    page_or_fragment,
    text,
    url_for,
    void,
)
from m0_sqlite import Connection, open, open_readonly

comptime HTMX_CDN = "https://cdn.jsdelivr.net/npm/htmx.org@4.0.0/dist/htmx.min.js"

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}
form.note{display:grid;gap:.5rem}
input,textarea{font:inherit;padding:.4rem}
ul{list-style:none;padding:0}li{display:flex;gap:.5rem;align-items:center;padding:.3rem 0}
li button{margin-left:auto}
[role=alert]{color:#b00020}
</style>"""

# The collection's pattern, and the three `resource` registers under it.
comptime NOTES = "/notes"
comptime NOTES_NEW = NOTES + RESOURCE_NEW
comptime NOTE = NOTES + RESOURCE_ITEM
comptime NOTE_EDIT = NOTES + RESOURCE_EDIT

comptime NOTES_ID = "notes"
comptime Frag = Fragment[Htmx]

comptime LIST_PAGE = 50
"""Rows a list renders. The cache holds one page, so what a change costs
is a page and not the table."""

comptime DB_ENV = "M0_DB"
comptime DB_DEFAULT = "table_notes.db"


# --- state --------------------------------------------------------------------


struct Notes(ViewState):
    """One thread's two connections and its rendering of the first page."""

    var writer: Connection
    var reader: Connection
    """Read-only, and the one every view renders through: its
    `data_version` moves for the writer's commits as for anyone's."""
    var rows: Cached
    var worker: Int

    def __init__(out self, path: String, worker: Int) raises:
        self.writer = open(path)
        # IMMEDIATE: `CREATE TABLE IF NOT EXISTS` reads first and upgrades
        # to a write, which SQLite refuses at once, not through the busy
        # handler, when two loops open one fresh file together.
        self.writer.begin_immediate()
        self.writer.execute(
            "CREATE TABLE IF NOT EXISTS notes ("
            "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "  title TEXT NOT NULL,"
            "  body TEXT NOT NULL DEFAULT '')"
        )
        self.writer.commit()
        # AUTOINCREMENT, so a deleted note's id is never handed to another:
        # without it SQLite reuses the highest rowid once its row is gone,
        # and a URL someone kept would name a different note.
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.worker = worker

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Notes(getenv(DB_ENV, DB_DEFAULT), ctx.worker)

    @staticmethod
    def urls() raises -> Views[Self]:
        return note_urls()

    def first_page(mut self) raises -> String:
        """The first page of the list, rendered only if the clock has
        moved since it last was. The clock is asked BEFORE the rendering:
        a commit between the two leaves current rows under an old value,
        which costs one more rendering; the other order keeps stale ones."""
        var now = self.reader.data_version()
        if not self.rows.current(now):
            var body = render_list(self.reader, 0)
            _ = self.rows.fill(now, body^)
        return self.rows.body


# --- templates -----------------------------------------------------------------


struct Site(PageShell):
    var title: String

    def __init__(out self, var title: String):
        self.title = title^

    def wrap(self, fragment: String) raises -> String:
        var h = Html(1024)
        h.raw('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n')
        h.raw('<meta name="viewport" content="width=device-width,initial-scale=1">\n')
        h.open("title")
        h.text(self.title)
        h.close("title")
        h.raw("\n")
        h.open("script")
        h.attr("src", HTMX_CDN)
        h.close("script")
        h.raw("\n")
        h.raw(_STYLE)
        h.raw("\n</head>\n<body>\n<main>\n")
        h.raw(fragment)
        h.raw("\n</main>\n</body>\n</html>\n")
        return h^.finish()


def render_list(db: Connection, after: Int) raises -> String:
    """The `notes` fragment: `LIST_PAGE` rows after rowid `after`, and a
    link to the rows after those when there are any."""
    var f = Frag(NOTES_ID)
    f.raw(el("p", "", el("a", attr("href", NOTES_NEW), "New note")))
    var q = db.prepare("SELECT id, title FROM notes WHERE id > ?1 ORDER BY id LIMIT ?2")
    q.bind_int(1, after)
    q.bind_int(2, LIST_PAGE + 1)
    var items = String()
    var shown = 0
    var last = after
    var more = False
    while q.step():
        if shown == LIST_PAGE:
            more = True
            break
        last = q.column_int(0)
        var url = url_for(NOTE, String(last))
        items += el("li", "",
            f.el("a", "get", url, attr("href", url), text(q.column_text(1)), push=True),
            f.el("button", "delete", url, attr("aria-label", "delete"), "&times;"),
        )
        shown += 1
    f.raw(el("ul", "", items))
    if shown == 0:
        f.raw(el("p", "", text("none yet")))
    if more:
        var next = Query()
        next.add("after", String(last))
        var url = next.on(url_for(NOTES))
        f.raw(el("p", "", f.el("a", "get", url, attr("href", url), "More", push=True)))
    return f^.finish()


def render_note(id: Int, title: String, body: String) raises -> String:
    var f = Frag(NOTES_ID)
    f.raw(el("article", "", el("h1", "", text(title)), el("p", "", text(body))))
    var edit = url_for(NOTE_EDIT, String(id))
    f.raw(el("p", "",
        el("a", attr("href", edit), "Edit"), " ",
        f.el("a", "get", NOTES, attr("href", NOTES), "all notes", push=True),
    ))
    return f^.finish()


def render_form(action: String, title: String, body: String, error: String) raises -> String:
    """The form that creates or updates: a plain `<form method="post">`
    to `action`, answered with a 303. Not a swap: saving is a navigation,
    and the address it lands on is the note's."""
    var f = Frag(NOTES_ID)
    if error.byte_length() > 0:
        f.raw(el("p", attr("role", "alert"), text(error)))
    f.raw(el("form", attr("class", "note") + attr("method", "post") + attr("action", action),
        void("input", attr("name", "title") + attr("value", title) + attr("placeholder", "title") + flag("required")),
        el("textarea", attr("name", "body") + attr("placeholder", "body"), text(body)),
        el("button", "", "Save"),
    ))
    f.raw(el("p", "", el("a", attr("href", NOTES), "all notes")))
    return f^.finish()


def render_missing() raises -> String:
    var f = Frag(NOTES_ID)
    f.raw(el("p", attr("role", "alert"), text("no note with this id")))
    f.raw(el("p", "", el("a", attr("href", NOTES), "all notes")))
    return f^.finish()


# --- views ---------------------------------------------------------------------


def rowid(param: String) -> Int:
    """The row a `:id` capture names, or -1. A row has ONE name: its
    rowid in decimal, no sign and no leading zero, so `07` names nothing
    and two URLs never answer one row. SQLite's rowids start at 1."""
    if param.byte_length() == 0 or Int(param.as_bytes()[0]) == ord("0"):
        return -1
    return reply.param_int(param)


def _missing(req: HTTPRequest) raises -> HTTPResponse:
    return page_or_fragment(req, render_missing(), Site("not found"), status=404)


def index(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """GET /notes — a page of the list. It fills the cache, so it writes."""
    var after = 0
    ref q = req.uri.queries
    if "after" in q:
        after = rowid(q["after"])
        if after < 0:
            return _missing(req)
    if after == 0:
        return conditional(req, page_or_fragment(req, st.first_page(), Site("notes")))
    return conditional(
        req, page_or_fragment(req, render_list(st.reader, after), Site("notes"))
    )


def new_form(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /notes/new — the form that creates."""
    return page_or_fragment(
        req, render_form(NOTES, String(""), String(""), String("")), Site("new note")
    )


def create(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """POST /notes — 303 to the note it made."""
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Note",
            "the request body must be application/x-www-form-urlencoded",
            NOTES,
        )
    var f = maybe.take()
    var title = f.first("title")
    var body = f.first("body")
    if title.byte_length() == 0:
        return page_or_fragment(
            req,
            render_form(NOTES, title, body, String("a title is required")),
            Site("new note"),
            status=422,
        )
    var ins = st.writer.prepare("INSERT INTO notes (title, body) VALUES (?1, ?2)")
    ins.bind_text(1, title)
    ins.bind_text(2, body)
    _ = ins.step()
    return reply.redirect(303, url_for(NOTE, String(st.writer.last_insert_rowid())))


def detail(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /notes/:id — one note."""
    var id = rowid(params[0])
    var q = st.reader.prepare("SELECT title, body FROM notes WHERE id = ?1")
    q.bind_int(1, id)
    if id < 0 or not q.step():
        return _missing(req)
    var title = q.column_text(0)
    return conditional(
        req, page_or_fragment(req, render_note(id, title, q.column_text(1)), Site(title))
    )


def edit_form(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /notes/:id/edit — the form that updates, posting to itself."""
    var id = rowid(params[0])
    var q = st.reader.prepare("SELECT title, body FROM notes WHERE id = ?1")
    q.bind_int(1, id)
    if id < 0 or not q.step():
        return _missing(req)
    return page_or_fragment(
        req,
        render_form(
            url_for(NOTE_EDIT, String(id)), q.column_text(0), q.column_text(1), String("")
        ),
        Site("edit note"),
    )


def update(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """PUT /notes/:id, and POST /notes/:id/edit — 303 to the note."""
    var id = rowid(params[0])
    # The row first: a form for a note that is not there is a 404, whatever
    # is wrong with the form.
    var there = st.reader.prepare("SELECT 1 FROM notes WHERE id = ?1")
    there.bind_int(1, id)
    if id < 0 or not there.step():
        return _missing(req)
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Note",
            "the request body must be application/x-www-form-urlencoded",
            req.uri.path,
        )
    var f = maybe.take()
    var title = f.first("title")
    var body = f.first("body")
    if title.byte_length() == 0:
        return page_or_fragment(
            req,
            render_form(url_for(NOTE_EDIT, String(id)), title, body, String("a title is required")),
            Site("edit note"),
            status=422,
        )
    var up = st.writer.prepare("UPDATE notes SET title = ?1, body = ?2 WHERE id = ?3")
    up.bind_text(1, title)
    up.bind_text(2, body)
    up.bind_int(3, id)
    _ = up.step()
    if st.writer.changes() == 0:
        return _missing(req)
    return reply.redirect(303, url_for(NOTE, String(id)))


def delete(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """DELETE /notes/:id — the one swap: answers the list without it."""
    var id = rowid(params[0])
    if id < 0:
        return _missing(req)
    var del_ = st.writer.prepare("DELETE FROM notes WHERE id = ?1")
    del_.bind_int(1, id)
    _ = del_.step()
    if st.writer.changes() == 0:
        return _missing(req)
    return page_or_fragment(req, st.first_page(), Site("notes"))


def stats(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /stats — how often this loop rendered the list, for the gate."""
    return reply.json(
        200, "OK",
        String(
            '{"worker":', st.worker, ',"fills":', st.rows.fills,
            ',"clock":', st.reader.data_version(), "}",
        ),
    )


def root(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.redirect(303, NOTES)


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


# --- the table -----------------------------------------------------------------


def note_urls() raises -> Views[Notes]:
    var v = Views[Notes]()
    v.add_loop("GET", "/health", health)
    v.add_loop("GET", "/", root)
    v.add_read("GET", "/stats", stats)
    # The list fills a cache as it answers, so it is a write and takes the
    # collection's GET itself; `resource` registers the rest.
    v.add_write("GET", NOTES, index)
    v.resource(
        NOTES, new=new_form, create=create, show=detail, edit=edit_form,
        update=update, delete=delete,
    )
    return v^


def main() raises:
    var config = host_config()
    print(
        String("Table notes on ", config.base_url, " over ", getenv(DB_ENV, DB_DEFAULT)),
        flush=True,
    )
    serve[ViewsApp[Notes]](config)
