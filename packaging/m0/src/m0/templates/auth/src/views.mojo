"""The state, the views and the table that joins them.

A view is a free function `(req, params, state) raises -> HTTPResponse`.
`add_read` hands it the state borrowed and `add_write` hands it `mut`, so
which views may change the list is in the table, where the compiler checks
it. `add_loop` is a stateless view answered on the event loop itself.

There is no middleware and no decorator: a guard is an early return. Every
view behind the login opens with the same two lines -- the session, and
`_refuse` without one -- and every write adds a third, `csrf_refusal`.
`m0_http.login` is the rest: the configuration, the credential check, the
cookie and the refusals. Every answer the session chose is `no_store`, so a
cache in front never hands one visitor's page to another.
"""

from lightbug_http import HTTPRequest, HTTPResponse
from m0_host.host import HostContext, ViewState

from m0_http import (
    Login,
    SessionVerdict,
    Views,
    csrf_refusal,
    form,
    no_store,
    page_or_fragment,
    refuse_signed_out,
    reply,
)

from pages import (
    ITEM,
    ITEMS,
    LOGIN,
    LOGOUT,
    Site,
    render_item,
    render_list,
    render_login,
    render_missing,
)

comptime LOGIN_ENV = "APP"
"""The configuration's prefix: `APP_KEY`, `APP_PASSWORD` and the rest."""

comptime SESSION_COOKIE = "__M0_APP__-session"


def login_from_env() raises -> Login:
    """The one user and the session's keys, from `APP_*`, or an error naming
    the variable that is missing."""
    return Login.from_env(LOGIN_ENV, SESSION_COOKIE)


struct Items(ViewState):
    """The list, as parallel lists, and the login that guards it. Handed to
    every view as its third argument."""

    var ids: List[Int]
    var titles: List[String]
    var next_id: Int
    var login: Login

    def __init__(out self, var login: Login):
        self.ids = List[Int]()
        self.titles = List[String]()
        self.next_id = 1
        self.login = login^

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Items(login_from_env())

    @staticmethod
    def urls() raises -> Views[Self]:
        return item_urls()

    @staticmethod
    def max_workers() -> Int:
        # The list lives in this struct: a second worker would hold a
        # second, different list, so `M0_WORKERS=2` is refused (exit 78)
        # rather than served. Move the list to a database, then raise this.
        # The session needs nothing of the kind: any worker with the same
        # `APP_KEY` reads any worker's cookie.
        return 1

    def find(self, id: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def add(mut self, var title: String):
        self.ids.append(self.next_id)
        self.next_id += 1
        self.titles.append(title^)

    def remove(mut self, i: Int):
        _ = self.ids.pop(i)
        _ = self.titles.pop(i)


def _index_of(items: Items, param: String) -> Int:
    """The list index for a `:id` capture, or -1. A non-number matches the
    route and can never name an item: that is a 404, not a 400."""
    var id = reply.param_int(param)
    if id < 0:
        return -1
    return items.find(id)


def _refuse(req: HTTPRequest, session: SessionVerdict) raises -> HTTPResponse:
    """No session: a navigation goes to the login page, a swap gets the
    form -- a redirect a swap followed would put the login page inside the
    list."""
    return refuse_signed_out(
        req, LOGIN, render_login(String("signed out (", session.reason, ")"))
    )


def _list(
    req: HTTPRequest, items: Items, session: SessionVerdict, error: String, status: Int = 200
) raises -> HTTPResponse:
    return no_store(page_or_fragment(
        req,
        render_list(items.ids, items.titles, session.subject, session.csrf, error),
        Site("__M0_APP__"),
        status=status,
    ))


def login_page(
    req: HTTPRequest, params: List[String], items: Items
) raises -> HTTPResponse:
    """GET /login — the form."""
    return no_store(page_or_fragment(req, render_login(String("")), Site("sign in")))


def sign_in(
    req: HTTPRequest, params: List[String], items: Items
) raises -> HTTPResponse:
    """POST /login — a PLAIN form, answered with a 303 so the address bar
    leaves /login; the wrong credentials are the form again, 401."""
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Login",
            "the request body must be application/x-www-form-urlencoded", LOGIN,
        )
    var f = maybe.take()
    var signed = items.login.sign_in(f.first("user"), f.first("password"))
    if not signed:
        return no_store(page_or_fragment(
            req, render_login(String("wrong user or password")), Site("sign in"),
            status=401,
        ))
    var resp = reply.redirect(303, ITEMS)
    signed.value().set_cookie(resp)
    return no_store(resp^)


def sign_out(
    req: HTTPRequest, params: List[String], items: Items
) raises -> HTTPResponse:
    """POST /logout — a write, so it carries the token."""
    var session = items.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var refused = csrf_refusal(req, form(req), session, LOGOUT)
    if refused:
        return refused.take()
    var resp = reply.redirect(303, LOGIN)
    items.login.sign_out(resp)
    return no_store(resp^)


def index(
    req: HTTPRequest, params: List[String], items: Items
) raises -> HTTPResponse:
    """GET /items — the list."""
    var session = items.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    return _list(req, items, session, String(""))


def create(
    req: HTTPRequest, params: List[String], mut items: Items
) raises -> HTTPResponse:
    """POST /items — a urlencoded form; answers the list."""
    var session = items.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var maybe = form(req)
    var refused = csrf_refusal(req, maybe, session, ITEMS)
    if refused:
        return refused.take()
    if not maybe:
        # Not a form at all: no browser sends this, so no fragment.
        return reply.problem(
            400, "Invalid Item",
            "the request body must be application/x-www-form-urlencoded",
            ITEMS,
        )
    var title = maybe.take().first("title")
    if title.byte_length() == 0:
        # An error a person may see is a FRAGMENT: htmx 4 swaps every 4xx,
        # so the list comes back with the message in it.
        return _list(req, items, session, String("a title is required"), status=422)
    items.add(title^)
    return _list(req, items, session, String(""))


def detail(
    req: HTTPRequest, params: List[String], items: Items
) raises -> HTTPResponse:
    """GET /items/:id — one item."""
    var session = items.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var i = _index_of(items, params[0])
    if i < 0:
        return no_store(page_or_fragment(
            req, render_missing(), Site("not found"), status=404
        ))
    return no_store(page_or_fragment(
        req, render_item(items.titles[i]), Site(items.titles[i])
    ))


def delete(
    req: HTTPRequest, params: List[String], mut items: Items
) raises -> HTTPResponse:
    """DELETE /items/:id — the token in the `X-CSRF-Token` header, since
    htmx 4 sends a DELETE's fields in the query string; answers the list."""
    var session = items.login.session_of(req)
    if not session.ok:
        return _refuse(req, session)
    var refused = csrf_refusal(req, form(req), session, req.uri.path)
    if refused:
        return refused.take()
    var i = _index_of(items, params[0])
    if i < 0:
        return no_store(page_or_fragment(
            req, render_missing(), Site("not found"), status=404
        ))
    items.remove(i)
    return _list(req, items, session, String(""))


def root(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.redirect(303, ITEMS)


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


def item_urls() raises -> Views[Items]:
    """The whole URL-to-view mapping."""
    var v = Views[Items]()
    v.add_loop("GET", "/health", health)
    v.add_loop("GET", "/", root)
    v.add_read("GET", LOGIN, login_page)
    v.add_read("POST", LOGIN, sign_in)
    v.add_read("POST", LOGOUT, sign_out)
    v.add_read("GET", ITEMS, index)
    v.add_write("POST", ITEMS, create)
    v.add_read("GET", ITEM, detail)
    v.add_write("DELETE", ITEM, delete)
    return v^
