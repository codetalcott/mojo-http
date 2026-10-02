"""Fragment notes — the notes resource as an htmx-shaped app.

`apps/notes_api` serves notes as a JSON API. This is the SAME resource as a
server-rendered app: a page with a form, a list that swaps in place, one
note's detail, delete. The browser talks htmx; the server answers HTML.

It was first written the way every Mojo app in this tree was written —
attributes by hand in eight places, `String(...)` concatenation, a
handler-id chain, every view branching on the request header — and gated
on WIRE OUTPUT only (`poe smoke-fragment-notes`), so each of those could be
lifted into the framework under a green gate. This is the app after six
of those lifts, and the smoke has not changed:

- **the URL table names the view.** `note_urls()` is the whole mapping; a view
  is a function, `add_read` hands it the store borrowed and `add_write`
  hands it `mut`, and there is no dispatch chain to fall through.
- **the fragment names itself.** `Frag("notes")` writes `id="notes"`
  once — `NOTES_ID`, given to both renderers — and `f.swap("post", NOTES)`
  on the form generates the `hx-target` from that same id. Nothing in this
  file types `#notes`, and nothing in it types an `hx-` attribute at all,
  the DELETE's `hx-headers` included (`header=csrf_header(csrf)`):
  `Frag` is `Fragment[Htmx]`, named once below, and that one line is what
  this app knows about its frontend library.
- **the view returns one thing.** `page_or_fragment` reads
  `HX-Request-Type`, htmx 4's own `partial` or `full` (and, for a client
  that does not send it, `HX-Request` with `HX-History-Restore-Request`
  and `HX-Boosted`, which ask for the
  page back) and calls `Site.wrap` — this app's `PageShell`, the document
  and everything it knows that a fragment does not — only when a whole
  document is wanted, with `Vary` naming every header it read on both. No
  view branches on a header.

- **routes are values.** `NOTES` and `NOTE` are `comptime` patterns given
  to the table and to `url_for`; no renderer spells a path. A misspelled
  route is a compile error, and `url_for` raises on the wrong arity.
- **the resource is its routes, named once.** `v.resource(NOTES,
  list=index, create=create, show=detail, delete=delete)` is the four
  routes under `/notes`, each view in the slot that says what it does, and
  `NOTE` is `NOTES` and the suffix the same call registers. This app has
  no edit form, so those slots are empty and register nothing.

- **the form is parsed once, by the framework.** `form(req)` is an
  ordered multimap — `f.all("tag")` is every ticked checkbox — and is
  None for any content type but the form's, so a JSON body posted here
  is refused rather than read as a field named after itself, and the
  check cannot be forgotten.
- **the guard is an early return.** There is no middleware (D3): a view
  that needs a session calls `store.login.session_of(req)` on its first
  line and returns `_refuse(req, verdict)` when it is not ok. A write view
  adds one more line, `csrf_refusal`. Nothing is registered twice and
  nothing wraps a view, because a capturing closure is not `thin`.
- **the login is the layer's.** The configuration, the credential check,
  the guard's two answers, the CSRF check and the token's two spellings
  were written here by hand, copied with the names changed by the first
  application outside this repository, and then lifted into
  `m0_http.login` (D53). The smoke, `sabotage-notes-login` and the
  browser run that held the hand-written copy hold the module now.
- **an element is an expression.** `render_list` is `el(...)` nested the
  way its markup nests, `text(...)` at every hole that carries data and
  `f.el(...)` for an element that swaps the fragment; `render_note` is the
  same fragment in the builder, one call per attribute. Both are the same
  bytes, and the smoke did not move when the list changed shape.

Nothing in it is written the old way any more. The diff from the first
commit of this file to this one is what the framework layer adds.

The notes are private. One user, named and authenticated by
`M0_NOTES_USER`/`M0_NOTES_PASSWORD`, holds a session in a signed cookie
this app neither stores nor looks up: `v1.<kid>.<exp>.<subject>.<tag>`,
the tag an HMAC-SHA256 over the rest under `M0_NOTES_KEY`, checked in
constant time against the host clock (`m0_http.session`). Every write
carries a CSRF token derived from that tag: a POST as a hidden field, the
DELETE as an `X-CSRF-Token` header (`m0_http.login`). The server refuses
to start without a key of at least 32 bytes and a password: a demo that
silently ran open would be worse than one that did not run.

What the app promises on the wire, and the gate asserts:

    GET  /login          the login form, page or fragment
    POST /login          `user` and `password`; sets the cookie, 303 to
                         /notes. A wrong one is 401 with the form back
    POST /logout         expires the cookie, 303 to /login; needs the token
    GET  /notes          the list; a bare `<section id="notes">` when the
                         request carries `HX-Request-Type: partial`, a
                         whole document otherwise — and `Vary` naming
                         every header that decision reads on both
    POST /notes          a urlencoded form: `title`, `body`, `tag` repeated
                         once per ticked checkbox, and `csrf`; answers the list
    GET  /notes/:id      one note, page or fragment the same way
    DELETE /notes/:id    removes it, answers the list; needs the token,
                         as an `X-CSRF-Token` HEADER — a DELETE has no body
                         under htmx 4, and a token in its query is refused
    GET  /               303 to /notes
    GET  /health         {"status":"ok"} — the one path outside the session

Everything under /notes answers a request with no usable session with 303
to /login, or 401 carrying the login fragment when the request asked for
a fragment. htmx 4 swaps a 4xx like any other answer (its `noSwap` is 204
and 304 alone), so a session that expires mid-interaction puts the login
form where the list was — which is why that 401 carries a fragment of the
same id. Under htmx 2.0.4 it showed nothing until a reload.

The attribute vocabulary is htmx 4 (`hx-*`), pinned to one CDN version;
`Htmx` in m0-http is the only place a swap, or the request header one
sends, is spelled, and `Frag` below is the only place this app names it.
The DELETE's `hx-headers` was the one attribute this file typed by hand
until a second application needed one and the layer could spell it
(`header=`, SPEC N44; DECISIONS D38, retired).

The store is in-memory, parallel lists, one process — see `notes_api`. It
runs on the Mojo host as `ViewsApp[NoteStore]`, and `NoteStore` says it
serves from one process (`max_workers`), so `M0_WORKERS=2` is refused with
78 instead of serving two workers that each hold a different list.

Run it:  uv run poe serve-fragment-notes
"""

from lightbug_http import HTTPRequest, HTTPResponse
from lightbug_http.c.process import process_exit
from m0_host.host import HostContext, ViewState, ViewsApp, serve
from m0_host.flags import host_config

from m0_http import reply
from m0_http import (
    Fragment,
    Html,
    Htmx,
    Login,
    RESOURCE_ITEM,
    SessionKeys,
    SessionVerdict,
    Views,
    attr,
    csrf_header,
    csrf_input,
    csrf_refusal,
    el,
    flag,
    form,
    no_store,
    PageShell,
    page_or_fragment,
    refuse_signed_out,
    text,
    url_for,
    vary_on_fragment_headers,
    void,
    wants_fragment,
)

# Pinned deliberately, as datastar_todo pins its CDN: a floating version
# would let an upstream release break this example without a commit here.
comptime HTMX_CDN = "https://cdn.jsdelivr.net/npm/htmx.org@4.0.0/dist/htmx.min.js"

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}
form{display:grid;gap:.5rem;margin-bottom:1.5rem}
input,textarea{font:inherit;padding:.4rem}
ul{list-style:none;padding:0}li{display:flex;gap:.5rem;align-items:center;padding:.3rem 0}
.tag{font-size:.8rem;background:#eee;border-radius:.5rem;padding:0 .5rem}
form.delete{margin-left:auto;display:inline;margin-bottom:0}
form.session{display:inline;margin:0}
.who{font-size:.8rem;color:#666}
</style>"""

# The routes, as values: each pattern is written once here, given to the
# table below and to `url_for` in the renderers. A misspelled route is a
# compile error, not a dead link.
comptime NOTES = "/notes"
comptime NOTE = NOTES + RESOURCE_ITEM

# The fragment's id, written once: both renderers build the same element,
# and a list that swapped in a section the detail view's links did not
# target would be the retyped-id drift `Fragment` exists to prevent.
comptime NOTES_ID = "notes"

# The vocabulary, named once. `Fragment[Datastar]` here — and the script
# tag in `wrap` — is the whole of switching this app to the other library;
# no renderer would change.
comptime Frag = Fragment[Htmx]


# --- session policy ------------------------------------------------------------
#
# The format, its verifier and the CSRF derivation were written here
# first, under the wire gate, and lifted into `m0_http.session` once it
# was green; the rest of the glue followed into `m0_http.login` once a
# second application had copied it (D53), and the smoke did not move
# either time. What stays is this app's POLICY: who the user is, what the
# cookie is called, how long a session lasts, which views are private and
# what a refusal looks like. None of that generalises.

comptime LOGIN = "/login"
comptime LOGOUT = "/logout"

comptime SESSION_COOKIE = "m0_notes_session"
comptime SESSION_TTL_DEFAULT = 3600
comptime LOGIN_ENV = "M0_NOTES"
"""The configuration's prefix: `M0_NOTES_KEY`, `M0_NOTES_PASSWORD` and
`M0_NOTES_SECURE` (`1` behind HTTPS, `0` over plain http), and optionally
`M0_NOTES_KEY_PREV`, `M0_NOTES_USER` and `M0_NOTES_TTL`."""


def notes_login() raises -> Login:
    """The one user and what signs their session: `notes` and an hour
    unless the environment says otherwise, or an error naming the variable
    that cannot be served."""
    return Login.from_env(
        LOGIN_ENV, SESSION_COOKIE, default_user="notes", default_ttl=SESSION_TTL_DEFAULT
    )


# --- state --------------------------------------------------------------------


struct NoteStore(ViewState):
    """The notes, as parallel lists, and the one user they belong to.
    Handed to every view as its third argument."""

    var ids: List[Int]
    var titles: List[String]
    var bodies: List[String]
    var tags: List[List[String]]
    var next_id: Int
    var login: Login

    def __init__(out self, var login: Login):
        self.ids = List[Int]()
        self.titles = List[String]()
        self.bodies = List[String]()
        self.tags = List[List[String]]()
        self.next_id = 1
        self.login = login^

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return NoteStore(notes_login())

    @staticmethod
    def urls() raises -> Views[Self]:
        return note_urls()

    @staticmethod
    def max_workers() -> Int:
        # The notes are lists in this struct: a second worker would hold a
        # second, different set.
        return 1

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


struct Site(PageShell):
    """What the document knows that a fragment does not: the title."""

    var title: String

    def __init__(out self, var title: String):
        self.title = title^

    def wrap(self, fragment: String) raises -> String:
        """The document around any fragment: head, the htmx script, the
        stylesheet.

        No library setting. Under htmx 2.0.4 there was one, a
        `<meta name="htmx-config">` narrowing `methodsThatUseUrlParams` to
        `get` so that a `hx-delete` form's fields — the CSRF token among
        them — rode the body rather than the query string. htmx 4 has no
        such setting: `/GET|DELETE/.test(method)` is in the source, so a
        DELETE's fields go in the URL whatever the page says, and the
        token left the form for a header instead
        (`header=csrf_header(csrf)` in `render_list`).
        """
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
        h.text(self.title)
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
        return h^.finish()


def render_login(error: String) raises -> String:
    """The login form, as the same fragment the notes list occupies — so a
    401 answered to a swap lands where the list was, and the whole page
    and the fragment are one renderer.

    A plain `<form method="post">`, not a swap, and it is the one form
    here that is not: signing in is a NAVIGATION. Swapping it would leave
    the address bar on `/login` with the notes in it, so a reload, a
    bookmark or the back button would each land somewhere the user did
    not just come from. `f.el` is for the elements that replace this
    fragment; a login replaces the page.
    """
    var f = Frag(NOTES_ID)
    f.raw(el("form", attr("method", "post") + attr("action", LOGIN),
        void("input", attr("name", "user") + attr("placeholder", "user") + flag("required")),
        void("input", attr("type", "password") + attr("name", "password") + attr("placeholder", "password") + flag("required")),
        el("button", "", "Sign in"),
    ))
    if error.byte_length() > 0:
        f.raw(el("p", attr("class", "error"), text(error)))
    return f^.finish()


def render_list(store: NoteStore, subject: String, csrf: String) raises -> String:
    """The `notes` fragment: the form, then every note with its actions.

    Written in the expression tier — an element per expression, the
    escaping named at each hole (`text` for data, `attr` for a value, a
    bare string for markup this file trusts), `f.el` for an element that
    swaps the fragment — where `render_note` below is the builder, one
    call per attribute. Same `Frag`, same bytes; the two shapes are kept
    side by side on purpose.

    Every write is a `<form>`, and how each carries the CSRF token
    follows from where htmx 4 puts a form's fields: a POST's go in the
    body, so create and sign-out hold the token as a hidden field; a
    DELETE's go in the query string, so the delete form holds no field at
    all and sends the token as a header.
    """
    var f = Frag(NOTES_ID)
    var boxes = String()
    for tag in ["work", "home", "later"]:
        boxes += el("label", "", void("input", attr("type", "checkbox") + attr("name", "tag") + attr("value", tag)), text(String(" ", tag))) + " "
    f.raw(f.el("form", "post", NOTES, "",
        csrf_input(csrf),
        void("input", attr("name", "title") + attr("placeholder", "title") + flag("required")),
        el("textarea", attr("name", "body") + attr("placeholder", "body")),
        el("div", "", boxes),
        el("button", "", "Add"),
    ))
    var items = String()
    for i in range(len(store.ids)):
        var url = url_for(NOTE, String(store.ids[i]))
        var tags = String()
        for t in range(len(store.tags[i])):
            tags += " " + el("span", attr("class", "tag"), text(store.tags[i][t]))
        items += el("li", "",
            # push: the note is a VIEW, so the swap that arrives at it moves
            # the address bar and the note can be reloaded and linked to.
            f.el("a", "get", url, attr("href", url), text(store.titles[i]), push=True),
            tags, " ",
            f.el("form", "delete", url, attr("class", "delete"),
                el("button", "", "&times;"),
                header=csrf_header(csrf),
            ),
        )
    f.raw(el("ul", "", items))
    if len(store.ids) == 0:
        f.raw(el("p", "", text("none yet")))
    # A div, not a p: `p` takes phrasing content only, and a `form` is
    # flow content — a browser would close the paragraph before it.
    f.raw(el("div", attr("class", "who"),
        text(String("signed in as ", subject)), " ",
        el("form", attr("class", "session") + attr("method", "post") + attr("action", LOGOUT),
            csrf_input(csrf),
            el("button", "", "Sign out"),
        ),
    ))
    return f^.finish()


def render_note(store: NoteStore, i: Int) raises -> String:
    """The same fragment showing one note, so a swap lands in the same place."""
    var f = Frag(NOTES_ID)
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
    f.attr("href", NOTES)
    f.swap("get", NOTES, push=True)
    f.text("all notes")
    f.close("a")
    f.close("p")
    return f^.finish()


# --- views ---------------------------------------------------------------------


def _refuse(req: HTTPRequest, verdict: SessionVerdict) raises -> HTTPResponse:
    """What a request with no usable session gets: a 303 to the login page
    for a navigation, and for a swap the login form as a 401 fragment, so
    it lands where the list was (`refuse_signed_out`). What this app adds
    is the form, saying why."""
    return refuse_signed_out(
        req, LOGIN, render_login(String("signed out (", verdict.reason, ")"))
    )


def login_form(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /login — the form. The one page outside the session."""
    return page_or_fragment(req, render_login(String("")), Site("sign in"))


def login(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """POST /login — `user` and `password`; sets the session cookie.

    Carries no CSRF token and cannot: there is no session yet to derive
    one from. What that leaves is login CSRF — a third party submitting
    THEIR credentials to log a visitor into their account — which is
    real and which a pre-session token is the answer to; on one user it
    is the account the visitor was going to log into anyway.
    """
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Login",
            "the request body must be application/x-www-form-urlencoded",
            LOGIN,
        )
    var f = maybe.take()
    var started = store.login.sign_in(f.first("user"), f.first("password"))
    if not started:
        return page_or_fragment(
            req,
            render_login(String("wrong user or password")),
            Site("sign in"),
            401,
            String("Unauthorized"),
        )
    var signed = started.take()
    var resp: HTTPResponse
    if wants_fragment(req):
        resp = page_or_fragment(
            req,
            render_list(store, signed.session.subject, signed.session.csrf),
            Site("notes"),
        )
    else:
        resp = vary_on_fragment_headers(reply.redirect(303, NOTES))
    signed.set_cookie(resp)
    return no_store(resp^)


def logout(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """POST /logout — expires the cookie. A write, so it carries the token."""
    var session = store.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var refused = csrf_refusal(req, form(req), session, LOGOUT)
    if refused:
        return refused.take()
    var resp: HTTPResponse
    if wants_fragment(req):
        resp = page_or_fragment(req, render_login(String("")), Site("sign in"))
    else:
        resp = vary_on_fragment_headers(reply.redirect(303, LOGIN))
    store.login.sign_out(resp)
    return no_store(resp^)


def index(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes — the list."""
    var session = store.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    return no_store(page_or_fragment(
        req, render_list(store, session.subject, session.csrf), Site("notes")
    ))


def create(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """POST /notes — a urlencoded form; answers the list."""
    var session = store.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Note",
            "the request body must be application/x-www-form-urlencoded",
            NOTES,
        )
    var refused = csrf_refusal(req, maybe, session, NOTES)
    if refused:
        return refused.take()
    var f = maybe.take()
    var title = f.first("title")
    if title.byte_length() == 0:
        return reply.problem(
            400, "Invalid Note", 'the form must carry a non-empty "title"', NOTES
        )
    store.add(title, f.first("body"), f.all("tag"))
    return no_store(page_or_fragment(
        req, render_list(store, session.subject, session.csrf), Site("notes")
    ))


def detail(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes/:id — one note."""
    var session = store.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    return no_store(
        page_or_fragment(req, render_note(store, i), Site(store.titles[i]))
    )


def delete(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """DELETE /notes/:id — answers the list without it.

    The token arrives as the `X-CSRF-Token` HEADER, from `hx-headers` on
    the form the button sits in: htmx 4 sends a DELETE with no body and
    its form's fields in the query string, which is why that form has no
    fields. A token in the query is never read, so it is a 403.
    """
    var session = store.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var refused = csrf_refusal(req, form(req), session, req.uri.path)
    if refused:
        return refused.take()
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    store.remove(i)
    return no_store(page_or_fragment(
        req, render_list(store, session.subject, session.csrf), Site("notes")
    ))


def root(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    """GET / — the list lives at /notes. A loop view: no state, no job."""
    return reply.redirect(303, NOTES)


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


def note_urls() raises -> Views[NoteStore]:
    """The whole URL-to-view mapping. Each line names the function that
    answers it and says whether it writes -- for the notes, by the slot it
    sits in -- and there is no id to keep in step and no dispatch chain to
    fall through.

    Which routes are private is not in this table, on purpose: a table
    that carried it would be a second place to forget, and there is no
    middleware to hang it on (D3). Each private view says so on its first
    line, where the state it is about to read is.
    """
    var v = Views[NoteStore]()
    v.add_loop("GET", "/health", health)
    v.add_loop("GET", "/", root)
    v.add_read("GET", LOGIN, login_form)
    v.add_read("POST", LOGIN, login)
    v.add_read("POST", LOGOUT, logout)
    v.resource(NOTES, list=index, create=create, show=detail, delete=delete)
    return v^


def _login_or_exit() raises -> Login:
    """The configuration, or a refusal to start naming what is missing."""
    try:
        return notes_login()
    except e:
        print(String("fragment_notes: ", String(e)), flush=True)
        process_exit(78)
    return Login(String(""), String(""), SessionKeys(), Int64(0), False, String(""))


def main() raises:
    # With the command line applied, so the address printed below is the
    # one `serve` binds under `--port` (`m0_host.flags`).
    var config = host_config()
    var login = _login_or_exit()
    print(
        String(
            "Fragment notes on ", config.base_url,
            " — one user (", login.user, "), sessions for ", login.ttl, "s",
        )
    )
    serve[ViewsApp[NoteStore]](config)
