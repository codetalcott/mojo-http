"""The views, and the one table that maps URLs to them.

A view here is what the article means by one: a function that takes a
request and returns a response, visible as such at the top of the file.
The state Django reaches through a module-level global arrives as the third
argument, because Mojo has no global `var` and this framework's threaded
mode needs per-thread state anyway.

Each view is flat and returns early. There is no view class, no mixin, and
nothing to trace through to find out what answers a URL — `urls()` at the
bottom of this file is the whole mapping.
"""

from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.header import HeaderKey

from m0_core.json_parse import parse_json_field

from m0_http import reply
from m0_http.health import HealthRegistry
from m0_http.views import Views

from views_pattern.store import NoteStore
from views_pattern.templates import (
    IndexPage,
    NotePage,
    render_index,
    render_missing,
    render_note,
)


# --- views ------------------------------------------------------------------


def index(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes — the list. A reading view: `store` is borrowed, so a
    write here would not compile."""
    return reply.html(render_index(store.index_page()))


def detail(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """GET /notes/:id — one note, or a 404 page."""
    var page = store.note_page(reply.param_int(params[0]))
    if not page:
        return _missing(req.uri.path)
    return reply.html(render_note(page.value()))


def create(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """POST /notes — add a note, then redirect to it.

    The guard is written as an early return rather than a decorator. A
    `thin` function pointer is what makes a view storable in the table, and
    a closure is not thin, so there is nothing to wrap a view *in* and put
    back. Guards are calls at the top of the body instead — which is the
    shape a flat view wanted regardless.
    """
    var denied = require_key(req, store)
    if denied:
        return denied.take()

    var body = reply.body_string(req)
    var title = parse_json_field(body, String("title"))
    if title.byte_length() == 0:
        return reply.problem(
            400,
            String("Invalid Note"),
            String('the request body must be JSON with a non-empty "title"'),
            String("/notes"),
        )

    var id = store.add(title, parse_json_field(body, String("body")))
    return reply.redirect(303, String("/notes/", id))


def delete(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    """DELETE /notes/:id."""
    var denied = require_key(req, store)
    if denied:
        return denied.take()
    if not store.remove(reply.param_int(params[0])):
        return _missing(req.uri.path)
    return reply.no_content()


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    """GET /health, answered on the event loop.

    A loop view, so it never becomes a pool job. It gets no state, which is
    exactly right here: the answer is a constant, and reading the store from
    the loop's handler instance would read a different copy than every other
    view sees.
    """
    var reg = HealthRegistry()
    reg.register(String("store"), True)
    return reply.json(200, String("OK"), reg.to_json())


def not_found(
    req: HTTPRequest, params: List[String], store: NoteStore
) raises -> HTTPResponse:
    """Whatever the table did not match. Registered with `set_not_found`."""
    return _missing(req.uri.path)


# --- guards -----------------------------------------------------------------


def require_key(
    req: HTTPRequest, store: NoteStore
) raises -> Optional[HTTPResponse]:
    """The rejection a writing view should return, or nothing.

    `Optional[HTTPResponse]` rather than a raise: the response is the
    subject here, and this framework answers with responses everywhere
    else. A guard that returns the *reply* also cannot be mistaken for one
    that returns permission.
    """
    if store.api_key.byte_length() == 0:
        return None  # unset: an open demo, not a locked one
    var given = req.headers.get(String("x-api-key"))
    if given:
        if given.value() == store.api_key:
            return None
    return reply.problem(
        401,
        String("Unauthorized"),
        String("this route needs a matching X-API-Key header"),
        req.uri.path,
    )


def _missing(path: String) -> HTTPResponse:
    var resp = reply.html(render_missing(path))
    resp.status_code = 404
    resp.status_text = String("Not Found")
    return resp^


# --- the table --------------------------------------------------------------


def urls() raises -> Views[NoteStore]:
    """The whole URL-to-view mapping, readable top to bottom.

    Each line names the function that answers it, and says whether it
    writes. There is no handler-id constant to keep in step and no dispatch
    chain to fall through.
    """
    var v = Views[NoteStore]()
    v.add_loop(String("GET"), String("/health"), health)
    v.add_read(String("GET"), String("/notes"), index)
    v.add_write(String("POST"), String("/notes"), create)
    v.add_read(String("GET"), String("/notes/:id"), detail)
    v.add_write(String("DELETE"), String("/notes/:id"), delete)
    v.set_not_found(not_found)
    return v^
