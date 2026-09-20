"""The state, the views and the table that joins them.

A view is a free function `(req, params, state) raises -> HTTPResponse`.
`add_read` hands it the state borrowed and `add_write` hands it `mut`, so
which views may change the list is in the table, where the compiler checks
it. `add_loop` is a stateless view answered on the event loop itself.

There is no middleware and no decorator: a guard is an early return.
"""

from lightbug_http import HTTPRequest, HTTPResponse
from m0_host.host import HostContext, ViewState

from m0_http import Views, form, page_or_fragment, reply

from pages import ITEM, ITEMS, Site, render_item, render_list, render_missing


struct Items(ViewState):
    """The list, as parallel lists. Handed to every view as its third
    argument."""

    var ids: List[Int]
    var titles: List[String]
    var next_id: Int

    def __init__(out self):
        self.ids = List[Int]()
        self.titles = List[String]()
        self.next_id = 1

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Items()

    @staticmethod
    def urls() raises -> Views[Self]:
        return item_urls()

    @staticmethod
    def max_workers() -> Int:
        # The list lives in this struct: a second worker would hold a
        # second, different list, so `M0_WORKERS=2` is refused (exit 78)
        # rather than served. Move the list to a database, then raise this.
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


def index(
    req: HTTPRequest, params: List[String], items: Items
) raises -> HTTPResponse:
    """GET /items — the list."""
    return page_or_fragment(
        req, render_list(items.ids, items.titles, String("")), Site("__M0_APP__")
    )


def create(
    req: HTTPRequest, params: List[String], mut items: Items
) raises -> HTTPResponse:
    """POST /items — a urlencoded form; answers the list."""
    var maybe = form(req)
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
        return page_or_fragment(
            req,
            render_list(items.ids, items.titles, String("a title is required")),
            Site("__M0_APP__"),
            status=422,
        )
    items.add(title^)
    return page_or_fragment(
        req, render_list(items.ids, items.titles, String("")), Site("__M0_APP__")
    )


def detail(
    req: HTTPRequest, params: List[String], items: Items
) raises -> HTTPResponse:
    """GET /items/:id — one item."""
    var i = _index_of(items, params[0])
    if i < 0:
        return page_or_fragment(
            req, render_missing(), Site("not found"), status=404
        )
    return page_or_fragment(
        req, render_item(items.titles[i]), Site(items.titles[i])
    )


def delete(
    req: HTTPRequest, params: List[String], mut items: Items
) raises -> HTTPResponse:
    """DELETE /items/:id — answers the list without it."""
    var i = _index_of(items, params[0])
    if i < 0:
        return page_or_fragment(
            req, render_missing(), Site("not found"), status=404
        )
    items.remove(i)
    return page_or_fragment(
        req, render_list(items.ids, items.titles, String("")), Site("__M0_APP__")
    )


def root(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.redirect(303, ITEMS)


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


def item_urls() raises -> Views[Items]:
    """The whole URL-to-view mapping."""
    var v = Views[Items]()
    v.add_loop("GET", "/health", health)
    v.add_loop("GET", "/", root)
    v.add_read("GET", ITEMS, index)
    v.add_write("POST", ITEMS, create)
    v.add_read("GET", ITEM, detail)
    v.add_write("DELETE", ITEM, delete)
    return v^
