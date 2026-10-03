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

- **what changed is asked of the database.** The table is watched
  (`m0_sqlite`'s stamps), so each row written, here or by any program,
  carries the number of its last change. `GET /notes/changes?since=N`
  answers the rows stamped above N in one statement: the ones that live
  with their titles, `born` when the client cannot have them, and the
  ones that are gone. A client keeps `head` and asks again from it; no
  loop keeps anything for it, so either loop answers. Below the floor
  tombstones were pruned to, the answer is `reset`: read the list again.
  The list's cache stays on the clock, which no write can get past; a
  stamp can be (a REPLACE without the pragma, a rebuilt table).
- **the list is live, from either loop, and the server keeps nothing for
  the page.** `GET /notes/events` is a `Feed` (`m0_http.feed`): each
  subscriber stands at a stamp, the loop's tick asks the clock, and when
  it has moved each subscriber is sent the rows stamped above where IT
  stands -- an `<li>` per row, `hx-swap-oob` saying replace or delete,
  the new ones inside a `<ul id="notes-list" hx-swap-oob="beforeend">`
  -- as one event carrying the new stamp as its id. A reconnect
  with `Last-Event-ID` is the same question; below the floor, or above
  the head, the event is `resync` and carries the first page whole. The
  page's script is one line: an `EventSource` from the stamp the fragment
  was rendered at, and `htmx.swap`. A fragment rendered again opens the
  feed again from its own stamp, so no row is appended twice.

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
    GET    /notes/changes    `?since=N`: the rows stamped above N, as JSON
    GET    /notes/events     SSE: the same rows as `<li>`s, as they change
    GET    /stats            this loop's cache and stamp:
                             {"worker","fills","clock","head","watched",
                              "subscribers","feed_sent","feed_refused"}
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
    Feed,
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
from m0_http.sse import format_sse_event
from m0_core.json_escape import escape_json_string
from m0_sqlite import (
    Connection,
    install_stamps,
    open,
    open_readonly,
    stamp_floor,
    stamp_head,
    watch,
    watched,
)

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
comptime NOTES_CHANGES = NOTES + "/changes"
comptime NOTES_EVENTS = NOTES + "/events"
"""Both registered before the resource: `/notes/:id` matches them too."""
comptime LIST_ID = "notes-list"

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
    var rows_head: Int
    """The stamp the kept page was rendered at: where its reader stands."""
    var feed: Feed
    var clock: Int
    """The clock the feed last fanned out at."""
    var worker: Int

    def __init__(out self, path: String, worker: Int, capacity: Int) raises:
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
        install_stamps(self.writer)
        watch(self.writer, "notes")
        self.writer.commit()
        # A REPLACE that displaces a row deletes it with no delete trigger
        # unless the writing connection says this. The app has no REPLACE;
        # the line is here for the one somebody adds.
        self.writer.execute("PRAGMA recursive_triggers = ON")
        # AUTOINCREMENT, so a deleted note's id is never handed to another:
        # without it SQLite reuses the highest rowid once its row is gone,
        # and a URL someone kept would name a different note.
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.rows_head = 0
        self.feed = Feed(capacity)
        self.clock = 0
        self.worker = worker

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Notes(getenv(DB_ENV, DB_DEFAULT), ctx.worker, ctx.capacity)

    def refresh(mut self) raises:
        """The feed's fan-out: when the clock has moved, or a subscriber is
        known to stand behind, bring each from where it stands to the head.
        Most stand together, so one delta serves them all."""
        var now = self.reader.data_version()
        if now == self.clock and not self.feed.lagging():
            return
        self.clock = now
        var head = stamp_head(self.reader)
        var have = -1
        var frames = String()
        var to = 0
        for slot in self.feed.behind(head):
            var at = self.feed.at(slot)
            if at != have:
                have = at
                to = at
                frames = delta_frames(self.reader, at, to)
            if to == at:
                self.feed.skip(slot, head)
            else:
                _ = self.feed.send(slot, to, frames)

    def tick(mut self, now_ms: Int):
        try:
            self.refresh()
        except e:
            print("table_notes: the feed's tick failed:", e)

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.feed.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.feed.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.feed.closed(slot)

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
            # The stamp and the rows in one snapshot: a row born after
            # the stamp would be in the page AND appended by the feed.
            self.reader.begin()
            try:
                self.rows_head = stamp_head(self.reader)
                var body = render_list(self.reader, 0, self.rows_head)
                self.reader.commit()
                _ = self.rows.fill(now, body^)
            except e:
                self.reader.rollback()
                raise e^
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


def render_item(f: Frag, id: Int, title: String, oob: String) raises -> String:
    """One row of the list. `oob` is empty in the list itself and in the
    rows a feed event appends (those travel inside a `<ul id="notes-list"
    hx-swap-oob="beforeend">`, since htmx 4 inserts an out-of-band
    element's CHILDREN for a positional swap); a changed row carries
    `true`, to replace its own by id."""
    var url = url_for(NOTE, String(id))
    var attrs = attr("id", "n" + String(id))
    if oob.byte_length() > 0:
        attrs += attr("hx-swap-oob", oob)
    return el("li", attrs,
        f.el("a", "get", url, attr("href", url), text(title), push=True),
        f.el("button", "delete", url, attr("aria-label", "delete"), "&times;"),
    )


comptime _FEED_SCRIPT = (
    "if(window.notesFeed)window.notesFeed.close();window.notesFeed=new EventSource('"
    + NOTES_EVENTS + "?since="
)
"""Opens the feed from the stamp THIS rendering was made at, closing the
one before: a fragment rendered again (the DELETE's answer, "all notes")
holds rows the old feed had not yet sent, and a feed left at its old
place would append them twice. Each event goes to htmx: an oob event
swaps nothing itself and lets its rows find their places; a resync
replaces the whole fragment. `htmx.swap` is htmx 4's public swap."""
comptime _FEED_SCRIPT_TAIL = (
    "');notesFeed.addEventListener('notes',e=>htmx.swap({text:e.data,target:document.body,"
    "swap:'none'}));notesFeed.addEventListener('resync',e=>htmx.swap({text:e.data,"
    "target:document.getElementById('" + NOTES_ID + "'),swap:'outerHTML'}))"
)


def render_list(db: Connection, after: Int, head: Int = -1) raises -> String:
    """The `notes` fragment: `LIST_PAGE` rows after rowid `after`, and a
    link to the rows after those when there are any. With `head`, the
    first page carries the script that keeps it live from that stamp."""
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
        items += render_item(f, last, q.column_text(1), String(""))
        shown += 1
    f.raw(el("ul", attr("id", LIST_ID), items))
    if shown == 0:
        f.raw(el("p", attr("id", "none-yet"), text("none yet")))
    if more:
        var next = Query()
        next.add("after", String(last))
        var url = next.on(url_for(NOTES))
        f.raw(el("p", "", f.el("a", "get", url, attr("href", url), "More", push=True)))
    if head >= 0:
        f.raw(el("script", "", _FEED_SCRIPT + String(head) + _FEED_SCRIPT_TAIL))
    return f^.finish()


def delta_frames(db: Connection, since: Int, mut head: Int) raises -> String:
    """The feed's event for a subscriber at `since`: the rows stamped above
    it as `<li>`s with their `hx-swap-oob`, the new stamp as the id; or
    `resync` with the first page whole, below the floor or above the head.
    One read transaction, so one snapshot. `head` is left where the
    subscriber will stand, `since` when there is nothing for it."""
    db.begin()
    try:
        var top = stamp_head(db)
        var low = stamp_floor(db)
        var out = String()
        if since < low or since > top:
            head = top
            out = format_sse_event(top, "resync", render_list(db, 0, top))
        else:
            var q = db.prepare(
                "SELECT c.row, c.seq, c.born, c.gone, n.title FROM m0_changes c"
                " LEFT JOIN notes n ON n.id = c.row"
                " WHERE c.tbl = 'notes' AND c.seq > ?1 ORDER BY c.seq"
            )
            q.bind_int(1, since)
            var f = Frag(NOTES_ID)
            var rows = String()
            var born = String()
            var last = since
            while q.step():
                last = q.column_int(1)
                var id = q.column_int(0)
                if q.column_int(3) == 1 or q.is_null(4):
                    rows += el("li", attr("id", "n" + String(id)) + attr("hx-swap-oob", "delete"))
                elif q.column_int(2) > since:
                    born += render_item(f, id, q.column_text(4), String(""))
                else:
                    rows += render_item(f, id, q.column_text(4), String("true"))
            _ = f^.finish()
            if born.byte_length() > 0:
                # The empty list's "none yet" goes when the first row comes;
                # htmx skips a target that is not there.
                rows += el("p", attr("id", "none-yet") + attr("hx-swap-oob", "delete"))
                rows += el("ul", attr("id", LIST_ID) + attr("hx-swap-oob", "beforeend"), born)
            head = last
            if last > since:
                out = format_sse_event(last, "notes", rows)
        db.commit()
        return out
    except e:
        db.rollback()
        raise e^


def events(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """GET /notes/events — the list, live. Answered on the loop, whose
    state holds the feed; the next tick sends what the client is missing
    (a refresh here would turn its raise into a 500 on a stream half
    opened)."""
    return st.feed.open(req, NOTES_ID)


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


def stamp(param: String) -> Int:
    """The stamp a `since` names, or -1: decimal digits, no sign, and no
    leading zero but for 0 itself."""
    if param == "0":
        return 0
    return rowid(param)


def json_text(s: String) -> String:
    """`s` as a JSON string. A title is what a form or another program
    stored, so it may hold bytes that are not UTF-8: each such byte
    becomes U+FFFD, since one undecodable row would make every delta
    that includes it unreadable, and a delta cannot skip a row."""
    var b = s.as_bytes()
    var n = len(b)
    var clean = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var c = Int(b[i])
        var want = 0
        if c < 0x80:
            want = 1
        elif c >= 0xC2 and c <= 0xDF:
            want = 2
        elif c >= 0xE0 and c <= 0xEF:
            want = 3
        elif c >= 0xF0 and c <= 0xF4:
            want = 4
        var ok = want > 0 and i + want <= n
        if ok:
            for k in range(1, want):
                var t = Int(b[i + k])
                if t < 0x80 or t > 0xBF:
                    ok = False
            # Overlong forms, surrogates and what lies past U+10FFFF.
            if want == 3 and ok:
                var t = Int(b[i + 1])
                ok = not (c == 0xE0 and t < 0xA0) and not (c == 0xED and t > 0x9F)
            if want == 4 and ok:
                var t = Int(b[i + 1])
                ok = not (c == 0xF0 and t < 0x90) and not (c == 0xF4 and t > 0x8F)
        if ok:
            for k in range(want):
                clean.append(b[i + k])
            i += want
        else:
            clean.append(0xEF)
            clean.append(0xBF)
            clean.append(0xBD)
            i += 1
    return escape_json_string(String(unsafe_from_utf8=Span(clean)))


def _changes(db: Connection, since: Int) raises -> String:
    """The answer for a client at `since`, read inside one transaction."""
    var head = stamp_head(db)
    if since < stamp_floor(db) or since > head:
        # Below the floor, deletions are no longer recorded, and a delta
        # could leave the client a note that is gone. Above the head, the
        # client's stamp is not this database's (a file restored or made
        # again): it would hear nothing until the counter passed it, then
        # miss what lay between.
        return String('{"since":', since, ',"head":', head, ',"reset":true,"rows":[]}')
    var q = db.prepare(
        "SELECT c.row, c.seq, c.born, c.gone, n.title FROM m0_changes c"
        " LEFT JOIN notes n ON n.id = c.row"
        " WHERE c.tbl = 'notes' AND c.seq > ?1 ORDER BY c.seq"
    )
    q.bind_int(1, since)
    var rows = String()
    while q.step():
        if rows.byte_length() > 0:
            rows += ","
        rows += String('{"id":', q.column_int(0), ',"seq":', q.column_int(1))
        if q.column_int(3) == 1 or q.is_null(4):
            rows += ',"gone":true}'
        else:
            rows += String(
                ',"born":', "true" if q.column_int(2) > since else "false",
                ',"title":', json_text(q.column_text(4)), "}",
            )
    q.finalize()
    return String('{"since":', since, ',"head":', head, ',"reset":false,"rows":[', rows, "]}")


def changes(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /notes/changes?since=N — the rows stamped above N.

    The floor, the head and the rows are read in one transaction, so one
    snapshot: `head` is the last stamp given as of it, and a client that
    asks again from `head` misses nothing. The answer is whole however
    long: `born` says the row was created above N, which tells a client
    it lacks the row only when N was some answer's `head`.
    """
    var since = 0
    ref query = req.uri.queries
    if "since" in query:
        since = stamp(query["since"])
    if since < 0:
        return reply.problem(
            400, "Invalid Stamp", "since is a stamp: decimal digits", NOTES_CHANGES
        )
    st.reader.begin()
    try:
        var body = _changes(st.reader, since)
        st.reader.commit()
        return reply.json(200, "OK", body)
    except e:
        st.reader.rollback()
        raise e^


def stats(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /stats — how often this loop rendered the list, and where the
    stamps stand, for the gate."""
    return reply.json(
        200, "OK",
        String(
            '{"worker":', st.worker, ',"fills":', st.rows.fills,
            ',"clock":', st.reader.data_version(),
            ',"head":', stamp_head(st.reader),
            ',"watched":', "true" if watched(st.reader, "notes") else "false",
            ',"subscribers":', st.feed.subscribers(NOTES_ID),
            ',"feed_sent":', st.feed.sent, ',"feed_refused":', st.feed.refused, "}",
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
    # Before the resource: the router answers with the first match. The
    # feed opens on the loop, whose state holds it (D32).
    v.add_read("GET", NOTES_CHANGES, changes)
    v.add_write("GET", NOTES_EVENTS, events, on_loop=True)
    v.resource(
        NOTES, new=new_form, create=create, show=detail, edit=edit_form,
        update=update, delete=delete,
    )
    return v^


def main() raises:
    var config = host_config()
    if config.app_tick_ms == 0:
        config.app_tick_ms = 50
    print(
        String("Table notes on ", config.base_url, " over ", getenv(DB_ENV, DB_DEFAULT)),
        flush=True,
    )
    serve[ViewsApp[Notes]](config)
