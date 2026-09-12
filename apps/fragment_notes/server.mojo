"""Fragment notes — the notes resource as an htmx-shaped app.

`apps/notes_api` serves notes as a JSON API. This is the SAME resource as a
server-rendered app: a page with a form, a list that swaps in place, one
note's detail, delete. The browser talks htmx; the server answers HTML.

It was first written the way every Mojo app in this tree was written —
attributes by hand in eight places, `String(...)` concatenation, a
handler-id chain, every view branching on the request header — and gated
on WIRE OUTPUT only (`poe smoke-fragment-notes`), so each of those could be
lifted into the framework under a green gate. This is the app after five
of those lifts, and the smoke has not changed:

- **the URL table names the view.** `urls()` is the whole mapping; a view
  is a function, `add_read` hands it the store borrowed and `add_write`
  hands it `mut`, and there is no dispatch chain to fall through.
- **the fragment names itself.** `Frag("notes")` writes `id="notes"`
  once — `NOTES_ID`, given to both renderers — and `f.swap("post", NOTES)`
  on the form generates the `hx-target` from that same id. Nothing in this
  file types `#notes`, and nothing in it types an `hx-` attribute either:
  `Frag` is `Fragment[Htmx]`, named once below, and that one line is what
  this app knows about its frontend library.
- **the view returns one thing.** `page_or_fragment` reads `HX-Request`
  (and `HX-History-Restore-Request` and `HX-Boosted`, which ask for the
  page back) and
  calls `wrap` only when a whole document is wanted, with `Vary` naming
  every header it read on both. No view branches on a header.

- **routes are values.** `NOTES` and `NOTE` are `comptime` patterns given
  to the table and to `url_for`; no renderer spells a path. A misspelled
  route is a compile error, and `url_for` raises on the wrong arity.

- **the form is parsed once, by the framework.** `form(req)` is an
  ordered multimap — `f.all("tag")` is every ticked checkbox — and is
  None for any content type but the form's, so a JSON body posted here
  is refused rather than read as a field named after itself, and the
  check cannot be forgotten.
- **the guard is an early return.** There is no middleware (D3): a view
  that needs a session calls `_session(req, store)` on its first line and
  returns `_refuse(req, store, verdict)` when it is not ok. A write view
  adds one more line, `_csrf_refusal`. Nothing is registered twice and
  nothing wraps a view, because a capturing closure is not `thin`.
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
carries a CSRF token derived from that tag, as a hidden field. The server
refuses to start without a key and a password: a demo that silently ran
open would be worse than one that did not run.

What the app promises on the wire, and the gate asserts:

    GET  /login          the login form, page or fragment
    POST /login          `user` and `password`; sets the cookie, 303 to
                         /notes. A wrong one is 401 with the form back
    POST /logout         expires the cookie, 303 to /login; needs the token
    GET  /notes          the list; a bare `<section id="notes">` when the
                         request carries `HX-Request: true`, a whole
                         document otherwise — and `Vary: HX-Request` on both
    POST /notes          a urlencoded form: `title`, `body`, `tag` repeated
                         once per ticked checkbox, and `csrf`; answers the list
    GET  /notes/:id      one note, page or fragment the same way
    DELETE /notes/:id    removes it, answers the list; needs the token
    GET  /               303 to /notes
    GET  /health         {"status":"ok"} — the one path outside the session

Everything under /notes answers a request with no usable session with 303
to /login, or 401 carrying the login fragment when the request asked for
a fragment. htmx 2.0.4 does not swap a 401 by default, so a session that
expires mid-interaction shows nothing until the page is reloaded; making
it swap is `htmx.config.responseHandling`, a vocabulary-specific setting
this app does not spell.

The attribute vocabulary is htmx 2 (`hx-*`), pinned to one CDN version;
`Htmx.swap` in m0-http is the only place it is spelled, and `Frag` below
is the only place this app names it.

The store is in-memory, parallel lists, one process — see `notes_api`.

Run it:  uv run poe serve-fragment-notes
"""

from std.os import getenv

from lightbug_http import Server, HTTPRequest, HTTPResponse
from lightbug_http.c.process import process_exit
from lightbug_http.http.date import unix_now

from m0_core import constant_time_equal, sha256

from m0_http import reply
from m0_http import (
    AppConfig,
    Form,
    Fragment,
    Html,
    Htmx,
    SessionKeys,
    SessionVerdict,
    Views,
    ViewService,
    attr,
    el,
    flag,
    form,
    install_shutdown_signals,
    issue_session,
    page_or_fragment,
    session_cookie_line,
    session_refused,
    text,
    url_for,
    vary_on_fragment_headers,
    verify_session,
    void,
    wants_fragment,
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
form.delete{margin-left:auto;display:inline;margin-bottom:0}
form.session{display:inline;margin:0}
.who{font-size:.8rem;color:#666}
</style>"""

# The routes, as values: each pattern is written once here, given to the
# table below and to `url_for` in the renderers. A misspelled route is a
# compile error, not a dead link.
comptime NOTES = "/notes"
comptime NOTE = "/notes/:id"

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
# was green — the smoke did not move. What stays is this app's POLICY:
# who the user is, what the cookie is called, how long a session lasts,
# which views are private and what a refusal looks like. None of that
# generalises, and all of it is four screens above the views that read it.

comptime LOGIN = "/login"
comptime LOGOUT = "/logout"

comptime SESSION_COOKIE = "m0_notes_session"
comptime SESSION_TTL_DEFAULT = 3600
comptime CSRF_FIELD = "csrf"

comptime KEY_ENV = "M0_NOTES_KEY"
comptime PREV_KEY_ENV = "M0_NOTES_KEY_PREV"
comptime PASSWORD_ENV = "M0_NOTES_PASSWORD"
comptime USER_ENV = "M0_NOTES_USER"
comptime TTL_ENV = "M0_NOTES_TTL"
comptime SECURE_ENV = "M0_NOTES_SECURE"


# --- state --------------------------------------------------------------------


struct NotesAuth(Movable):
    """The one user, and what a session of theirs is signed with.

    No user table: a demo with a login needs an identity, not a directory.
    The password is compared as a SHA-256 digest so the compare is over
    two fixed-length byte strings — `constant_time_equal` reads all of
    both whatever the first mismatch, which a compare of raw passwords of
    different lengths cannot. It is NOT a password hash: there is no salt
    and no work factor, because there is nothing at rest to steal — the
    secret lives in the environment of the process that checks it (D24).
    """

    var user: String
    var password_digest: List[UInt8]
    var keys: SessionKeys
    var ttl: Int64
    var secure: Bool

    def __init__(
        out self,
        var user: String,
        password: String,
        var keys: SessionKeys,
        ttl: Int64,
        secure: Bool,
    ):
        self.user = user^
        self.password_digest = sha256(Span(password.as_bytes()))
        self.keys = keys^
        self.ttl = ttl
        self.secure = secure

    def __init__(out self, *, deinit move: Self):
        self.user = move.user^
        self.password_digest = move.password_digest^
        self.keys = move.keys^
        self.ttl = move.ttl
        self.secure = move.secure

    def accepts(self, user: String, password: String) -> Bool:
        """Whether these credentials are the one user's. Both compares are
        over digests, so neither the password nor the user name leaks its
        length or its first differing byte."""
        var want_user = sha256(Span(self.user.as_bytes()))
        var have_user = sha256(Span(user.as_bytes()))
        var have_pass = sha256(Span(password.as_bytes()))
        var user_ok = constant_time_equal(Span(want_user), Span(have_user))
        var pass_ok = constant_time_equal(Span(self.password_digest), Span(have_pass))
        return user_ok and pass_ok

    @staticmethod
    def from_env() raises -> Self:
        """The configuration, or an error naming the variable that is missing.

        Fail closed, the way a hold mount refuses to start without
        `M0_GRANT_KEY`: a notes app that quietly served everyone because a
        deployment forgot a variable is worse than one that did not start.
        """
        var key = getenv(KEY_ENV, "")
        if key.byte_length() == 0:
            raise Error(String(KEY_ENV, " is not set: it signs the session cookie"))
        var password = getenv(PASSWORD_ENV, "")
        if password.byte_length() == 0:
            raise Error(String(PASSWORD_ENV, " is not set: it is the one user's password"))
        var keys = SessionKeys()
        keys.add(Span(key.as_bytes()))
        var previous = getenv(PREV_KEY_ENV, "")
        if previous.byte_length() > 0:
            keys.add(Span(previous.as_bytes()))
        var ttl = Int64(SESSION_TTL_DEFAULT)
        var ttl_env = getenv(TTL_ENV, "")
        if ttl_env.byte_length() > 0:
            var parsed = reply.param_int(ttl_env)
            if parsed <= 0:
                raise Error(String(TTL_ENV, " must be a positive number of seconds"))
            ttl = Int64(parsed)
        return Self(
            getenv(USER_ENV, "notes"),
            password,
            keys^,
            ttl,
            getenv(SECURE_ENV, "") == "1",
        )


struct NoteStore(Movable):
    """The notes, as parallel lists, and the one user they belong to.
    Handed to every view as its third argument."""

    var ids: List[Int]
    var titles: List[String]
    var bodies: List[String]
    var tags: List[List[String]]
    var next_id: Int
    var auth: NotesAuth

    def __init__(out self, var auth: NotesAuth):
        self.ids = List[Int]()
        self.titles = List[String]()
        self.bodies = List[String]()
        self.tags = List[List[String]]()
        self.next_id = 1
        self.auth = auth^

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
    """The document around any fragment: head, the htmx config and script,
    the stylesheet.

    The one library setting this app makes, and it is here rather than on
    an element because it is about the transport and not about a
    fragment: htmx 2.0.4 ships `methodsThatUseUrlParams: ["get","delete"]`,
    so a `hx-delete` form puts its fields in the query string. The CSRF
    token is one of those fields, and a token in a URL is a token in the
    access log, the Referer and the browser history. Narrowing the
    setting to `get` puts every write's fields in the body, where
    `form(req)` reads them and the server accepts them from nowhere else.
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
    h.open("meta")
    h.attr("name", "htmx-config")
    h.attr("content", '{"methodsThatUseUrlParams":["get"]}')
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
    return h^.finish()


def _csrf_input(csrf: String) raises -> String:
    """The token as a hidden field. Written once: a write the renderer
    forgets to carry it on is a write the server answers 403, so the
    spelling belongs in one place."""
    return void(
        "input",
        attr("type", "hidden") + attr("name", CSRF_FIELD) + attr("value", csrf),
    )


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

    Every write is a `<form>`, delete included, because a form is what
    carries the CSRF token: htmx serialises the enclosing form's fields
    into the request, and the shell's `htmx-config` puts them in the body.
    """
    var f = Frag(NOTES_ID)
    var boxes = String()
    for tag in ["work", "home", "later"]:
        boxes += el("label", "", void("input", attr("type", "checkbox") + attr("name", "tag") + attr("value", tag)), text(String(" ", tag))) + " "
    f.raw(f.el("form", "post", NOTES, "",
        _csrf_input(csrf),
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
            f.el("a", "get", url, attr("href", url), text(store.titles[i])),
            tags, " ",
            f.el("form", "delete", url, attr("class", "delete"),
                _csrf_input(csrf),
                el("button", "", "&times;"),
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
            _csrf_input(csrf),
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
    f.swap("get", NOTES)
    f.text("all notes")
    f.close("a")
    f.close("p")
    return f^.finish()


# --- views ---------------------------------------------------------------------


def _session(req: HTTPRequest, store: NoteStore) -> SessionVerdict:
    """The request's session, or the reason it has none."""
    var raw = req.cookies.get(SESSION_COOKIE)
    if not raw:
        return session_refused(String("no cookie"))
    return verify_session(
        Span(raw.value().as_bytes()), store.auth.keys, unix_now()
    )


def _refuse(req: HTTPRequest, verdict: SessionVerdict) raises -> HTTPResponse:
    """What a request with no usable session gets: the login form.

    A navigation is sent there with a 303, which is what a browser
    address bar needs. A swap gets 401 carrying the same form as a bare
    fragment, because a redirect a swap follows would put the login page
    inside the element the list was in with no way back.
    """
    if wants_fragment(req):
        return page_or_fragment(
            req,
            render_login(String("signed out (", verdict.reason, ")")),
            Site("sign in"),
            wrap,
            401,
            String("Unauthorized"),
        )
    return vary_on_fragment_headers(reply.redirect(303, LOGIN))


def _csrf_refusal(
    body: Optional[Form], verdict: SessionVerdict, instance: String
) -> Optional[HTTPResponse]:
    """403 unless the request carries THIS session's token, in the body.

    The guard, in the shape D3 leaves for one: an early return, not a
    decorator. It takes `form(req)` rather than a `Form` so that a body
    that is not a form and a form with no token are the same answer —
    both are a write arriving without the token, and telling them apart
    tells a forger which half they got wrong. `SameSite=Lax` already
    keeps the cookie off a cross-site write, so what this catches is the
    same-site forgery: another tab, another session's token, a form
    replayed after a re-login.
    """
    if body:
        var got = body.value().get(CSRF_FIELD)
        if got:
            if constant_time_equal(
                Span(verdict.csrf.as_bytes()), Span(got.value().as_bytes())
            ):
                return None
    return reply.problem(
        403,
        String("Forbidden"),
        String("the request did not carry this session's CSRF token"),
        instance,
    )


def login_form(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /login — the form. The one page outside the session."""
    return page_or_fragment(req, render_login(String("")), Site("sign in"), wrap)


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
    if not store.auth.accepts(f.first("user"), f.first("password")):
        return page_or_fragment(
            req,
            render_login(String("wrong user or password")),
            Site("sign in"),
            wrap,
            401,
            String("Unauthorized"),
        )
    var value = issue_session(
        store.auth.keys, store.auth.user, unix_now() + store.auth.ttl
    )
    var session = verify_session(Span(value.as_bytes()), store.auth.keys, unix_now())
    var resp: HTTPResponse
    if wants_fragment(req):
        resp = page_or_fragment(
            req, render_list(store, session.subject, session.csrf), Site("notes"), wrap
        )
    else:
        resp = vary_on_fragment_headers(reply.redirect(303, NOTES))
    resp.cookies.add_raw(
        session_cookie_line(
            SESSION_COOKIE, value, store.auth.ttl, store.auth.secure
        )
    )
    return resp^


def logout(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """POST /logout — expires the cookie. A write, so it carries the token."""
    var session = _session(req, store)
    if not session.ok:
        return _refuse(req, session)
    var refused = _csrf_refusal(form(req), session, LOGOUT)
    if refused:
        return refused.take()
    var resp: HTTPResponse
    if wants_fragment(req):
        resp = page_or_fragment(req, render_login(String("")), Site("sign in"), wrap)
    else:
        resp = vary_on_fragment_headers(reply.redirect(303, LOGIN))
    resp.cookies.add_raw(
        session_cookie_line(SESSION_COOKIE, String(""), Int64(0), store.auth.secure)
    )
    return resp^


def index(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes — the list."""
    var session = _session(req, store)
    if not session.ok:
        return _refuse(req, session)
    return page_or_fragment(
        req, render_list(store, session.subject, session.csrf), Site("notes"), wrap
    )


def create(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """POST /notes — a urlencoded form; answers the list."""
    var session = _session(req, store)
    if not session.ok:
        return _refuse(req, session)
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Note",
            "the request body must be application/x-www-form-urlencoded",
            NOTES,
        )
    var refused = _csrf_refusal(maybe, session, NOTES)
    if refused:
        return refused.take()
    var f = maybe.take()
    var title = f.first("title")
    if title.byte_length() == 0:
        return reply.problem(
            400, "Invalid Note", 'the form must carry a non-empty "title"', NOTES
        )
    store.add(title, f.first("body"), f.all("tag"))
    return page_or_fragment(
        req, render_list(store, session.subject, session.csrf), Site("notes"), wrap
    )


def detail(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes/:id — one note."""
    var session = _session(req, store)
    if not session.ok:
        return _refuse(req, session)
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    return page_or_fragment(req, render_note(store, i), Site(store.titles[i]), wrap)


def delete(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """DELETE /notes/:id — answers the list without it.

    The token arrives in the BODY, from the hidden field in the form the
    button sits in: the shell's `htmx-config` narrows
    `methodsThatUseUrlParams` to `get`, so htmx body-encodes this one.
    `form(req)` is the only place it is read, so a token that reached the
    query string instead would be a 403 rather than a quiet acceptance.
    """
    var session = _session(req, store)
    if not session.ok:
        return _refuse(req, session)
    var refused = _csrf_refusal(form(req), session, req.uri.path)
    if refused:
        return refused.take()
    var i = _index_of(store, params[0])
    if i < 0:
        return reply.problem(404, "Not Found", "no note with this id", req.uri.path)
    store.remove(i)
    return page_or_fragment(
        req, render_list(store, session.subject, session.csrf), Site("notes"), wrap
    )


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


def urls() raises -> Views[NoteStore]:
    """The whole URL-to-view mapping. Each line names the function that
    answers it and says whether it writes; there is no id to keep in step
    and no dispatch chain to fall through.

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
    v.add_read("GET", NOTES, index)
    v.add_write("POST", NOTES, create)
    v.add_read("GET", NOTE, detail)
    v.add_write("DELETE", NOTE, delete)
    return v^


def _auth_or_exit() raises -> NotesAuth:
    """The configuration, or a refusal to start naming what is missing."""
    try:
        return NotesAuth.from_env()
    except e:
        print(String("fragment_notes: ", String(e)), flush=True)
        process_exit(78)
    return NotesAuth(String(""), String(""), SessionKeys(), Int64(0), False)


def main() raises:
    var config = AppConfig()
    var auth = _auth_or_exit()
    print(
        String(
            "Fragment notes on ", config.base_url,
            " — one user (", auth.user, "), sessions for ", auth.ttl, "s",
        )
    )
    var server = Server(config.server_config())
    var handler = ViewService(urls(), NoteStore(auth^))
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
