"""The view table: dispatch, the 404/405 shapes, and the drift it prevents.

SPEC section N is the framework layer's; N2 is this file's row.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import HeaderKey, parse_request_headers
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI

from src import reply
from src.router import Mount
from src.router import url_for
from src.views import (
    Views, ViewService, RESOURCE_EDIT, RESOURCE_ITEM, RESOURCE_NEW,
)


struct Counter(Movable):
    """A stand-in for whatever an application keeps between requests."""

    var hits: Int
    var last: String

    def __init__(out self):
        self.hits = 0
        self.last = String("")


def _index(
    req: HTTPRequest, params: List[String], st: Counter
) raises -> HTTPResponse:
    """A reading view: `st` is borrowed, so a write here would not compile."""
    return reply.html(String("<p>index ", st.hits, "</p>"))


def _detail(
    req: HTTPRequest, params: List[String], st: Counter
) raises -> HTTPResponse:
    return reply.html(String("<p>id ", params[0], "</p>"))


def _bump(
    req: HTTPRequest, params: List[String], mut st: Counter
) raises -> HTTPResponse:
    """A writing view: `mut`, so it may touch the state."""
    st.hits += 1
    st.last = String("bump")
    return reply.no_content()


def _health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    """A loop view: no state at all, and non-raising."""
    return reply.json(200, String("OK"), String('{"ok":true}'))


def _raising(
    req: HTTPRequest, params: List[String], st: Counter
) raises -> HTTPResponse:
    """An on-loop view that raises: `before_request` cannot, so it is 500."""
    raise Error("the view raised on purpose")


def _custom_404(
    req: HTTPRequest, params: List[String], st: Counter
) raises -> HTTPResponse:
    var resp = reply.html(String("<h1>no such page</h1>"))
    resp.status_code = 404
    resp.status_text = String("Not Found")
    return resp^


def _req(method: String, path: String) raises -> HTTPRequest:
    var r = HTTPRequest(URI.parse(String("http://127.0.0.1", path)))
    r.method = method
    return r^


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=resp.body_raw))


def _table() raises -> Views[Counter]:
    var v = Views[Counter]()
    v.add_read(String("GET"), String("/notes"), _index)
    v.add_read(String("GET"), String("/notes/:id"), _detail)
    v.add_write(String("POST"), String("/notes"), _bump)
    return v^


comptime THINGS = "/things"
comptime THINGS_NEW = THINGS + RESOURCE_NEW
comptime THING = THINGS + RESOURCE_ITEM
comptime THING_EDIT = THINGS + RESOURCE_EDIT


def _named(name: String, params: List[String]) -> HTTPResponse:
    var who = name
    for p in params:
        who += " " + p
    return reply.html(who)


def _r_list(req: HTTPRequest, params: List[String], st: Counter) raises -> HTTPResponse:
    return _named("list", params)


def _r_new(req: HTTPRequest, params: List[String], st: Counter) raises -> HTTPResponse:
    return _named("new", params)


def _r_show(req: HTTPRequest, params: List[String], st: Counter) raises -> HTTPResponse:
    return _named("show", params)


def _r_edit(req: HTTPRequest, params: List[String], st: Counter) raises -> HTTPResponse:
    return _named("edit", params)


def _r_create(req: HTTPRequest, params: List[String], mut st: Counter) raises -> HTTPResponse:
    st.hits += 1
    return _named("create", params)


def _r_update(req: HTTPRequest, params: List[String], mut st: Counter) raises -> HTTPResponse:
    st.hits += 1
    return _named("update", params)


def _r_delete(req: HTTPRequest, params: List[String], mut st: Counter) raises -> HTTPResponse:
    st.hits += 1
    return _named("delete", params)


def _whole_resource(mount: Mount = Mount()) raises -> Views[Counter]:
    var v = Views[Counter](mount)
    v.resource(
        THINGS, list=_r_list, new=_r_new, create=_r_create, show=_r_show,
        edit=_r_edit, update=_r_update, delete=_r_delete,
    )
    return v^


def _answer(v: Views[Counter], mut st: Counter, method: String, path: String) raises -> String:
    return _body(v.dispatch(_req(method, path), st))


def test_a_resource_registers_each_view_under_its_route() raises:
    """Seven views, eight routes, each answered by the view its slot names.

    covers: N46
    """
    var v = _whole_resource()
    var st = Counter()
    assert_equal(v.route_count(), 8)
    assert_equal(_answer(v, st, "GET", "/things"), "list")
    assert_equal(_answer(v, st, "GET", "/things/new"), "new")
    assert_equal(_answer(v, st, "POST", "/things"), "create")
    assert_equal(_answer(v, st, "GET", "/things/7"), "show 7")
    assert_equal(_answer(v, st, "GET", "/things/7/edit"), "edit 7")
    assert_equal(_answer(v, st, "PUT", "/things/7"), "update 7")
    assert_equal(_answer(v, st, "DELETE", "/things/7"), "delete 7")
    assert_equal(st.hits, 3)


def test_a_resources_update_answers_the_form_that_cannot_put() raises:
    """A plain form posts to the URL it was served from, and reaches the
    view a PUT reaches."""
    var v = _whole_resource()
    var st = Counter()
    assert_equal(_answer(v, st, "POST", "/things/7/edit"), "update 7")
    assert_equal(st.hits, 1)
    assert_equal(v.allow_header("/things/7/edit"), "GET, HEAD, POST, OPTIONS")
    assert_equal(v.allow_header("/things/7"), "GET, HEAD, PUT, DELETE, OPTIONS")


def test_a_resources_new_form_is_not_a_row_named_new() raises:
    """`/things/new` matches `/things/:id` too; the form is registered
    first, and the router answers with the first route that matches."""
    var v = _whole_resource()
    var st = Counter()
    assert_equal(_answer(v, st, "GET", "/things/new"), "new")
    # Without the form, `new` is a row's name like any other.
    var bare = Views[Counter]()
    bare.resource(THINGS, show=_r_show)
    assert_equal(_answer(bare, st, "GET", "/things/new"), "show new")


def test_an_empty_slot_registers_nothing() raises:
    var v = Views[Counter]()
    v.resource(THINGS, list=_r_list, show=_r_show)
    var st = Counter()
    assert_equal(v.route_count(), 2)
    assert_equal(v.dispatch(_req("POST", "/things"), st).status_code, 405)
    assert_equal(v.dispatch(_req("DELETE", "/things/7"), st).status_code, 405)
    assert_equal(v.dispatch(_req("GET", "/things/7/edit"), st).status_code, 404)
    assert_equal(v.allow_header("/things/7"), "GET, HEAD, OPTIONS")
    # An update alone is both of its routes and no form.
    var u = Views[Counter]()
    u.resource(THINGS, update=_r_update)
    assert_equal(u.route_count(), 2)
    assert_equal(u.dispatch(_req("GET", "/things/7/edit"), st).status_code, 405)


def test_a_slot_left_empty_takes_a_view_of_the_other_kind() raises:
    """A list that writes -- one that fills a cache as it answers --
    registers through `add_write` on the collection's own pattern."""
    var v = Views[Counter]()
    v.resource(THINGS, create=_r_create, show=_r_show)
    v.add_write("GET", THINGS, _bump)
    var st = Counter()
    assert_equal(v.dispatch(_req("GET", "/things"), st).status_code, 204)
    assert_equal(st.hits, 1)
    assert_equal(v.allow_header("/things"), "POST, GET, HEAD, OPTIONS")


def test_a_resources_patterns_reverse_from_its_suffixes() raises:
    """The constants an application gives `url_for` are the collection's
    pattern and a suffix, so they are the patterns `resource` registered."""
    var v = _whole_resource()
    var st = Counter()
    assert_equal(url_for(THINGS), "/things")
    assert_equal(url_for(THINGS_NEW), "/things/new")
    assert_equal(url_for(THING, "7"), "/things/7")
    assert_equal(url_for(THING_EDIT, "7"), "/things/7/edit")
    assert_equal(_answer(v, st, "GET", url_for(THING_EDIT, "7")), "edit 7")


def test_a_mounted_resource_is_under_its_prefix() raises:
    var at = Mount("/native")
    var v = _whole_resource(at)
    var st = Counter()
    assert_equal(_answer(v, st, "GET", "/native/things/7/edit"), "edit 7")
    assert_equal(_answer(v, st, "POST", at.url_for(THING_EDIT, "7")), "update 7")
    assert_equal(v.dispatch(_req("GET", "/things/7"), st).status_code, 404)


def test_dispatch_calls_the_registered_view() raises:
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("GET"), String("/notes")), st)
    assert_equal(resp.status_code, 200)
    assert_equal(_body(resp), "<p>index 0</p>")


def test_a_view_receives_its_captured_parameters() raises:
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("GET"), String("/notes/42")), st)
    assert_equal(_body(resp), "<p>id 42</p>")


def test_a_writing_view_mutates_and_a_reading_one_sees_it() raises:
    """The split is real in both directions: the write lands, and the read
    that follows observes it through a borrow."""
    var v = _table()
    var st = Counter()
    _ = v.dispatch(_req(String("POST"), String("/notes")), st)
    _ = v.dispatch(_req(String("POST"), String("/notes")), st)
    assert_equal(st.hits, 2)
    assert_equal(st.last, "bump")
    var resp = v.dispatch(_req(String("GET"), String("/notes")), st)
    assert_equal(_body(resp), "<p>index 2</p>")


def test_ids_are_assigned_in_registration_order() raises:
    """The drift guard. `add` is the only way to register, so the id it
    assigns and the function it stores cannot disagree — there is no
    second edit to forget. Registering N routes stores N views."""
    var v = _table()
    assert_equal(v.route_count(), 3)
    v.add_write(String("DELETE"), String("/notes/:id"), _bump)
    assert_equal(v.route_count(), 4)
    # The route added last dispatches to the view added last, across two
    # tables: `_slot` indexes the writes while the id indexes both.
    var st = Counter()
    _ = v.dispatch(_req(String("DELETE"), String("/notes/9")), st)
    assert_equal(st.last, "bump")


def test_unmatched_path_is_problem_json_by_default() raises:
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("GET"), String("/nope")), st)
    assert_equal(resp.status_code, 404)
    var ct = resp.headers.get(HeaderKey.CONTENT_TYPE)
    assert_true(ct)
    assert_equal(ct.value(), "application/problem+json")


def test_a_custom_404_is_just_another_view() raises:
    var v = _table()
    v.set_not_found(_custom_404)
    var st = Counter()
    var resp = v.dispatch(_req(String("GET"), String("/nope")), st)
    assert_equal(resp.status_code, 404)
    assert_equal(_body(resp), "<h1>no such page</h1>")


def test_wrong_method_is_405_with_allow() raises:
    """A path that exists, in a method it does not take, is 405 with the
    Allow header RFC 9110 requires — and reaches no view, because there is
    no fallthrough for it to reach.

    covers: N2
    """
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("PUT"), String("/notes")), st)
    assert_equal(resp.status_code, 405)
    var allow = resp.headers.get(HeaderKey.ALLOW)
    assert_true(allow)
    # `Router.allow_header` adds OPTIONS itself — every path answers it.
    assert_equal(allow.value(), "GET, HEAD, POST, OPTIONS")


def test_head_reaches_the_get_view_in_either_table() raises:
    """A server that answers GET answers HEAD (RFC 9110 §9.1): a HEAD with no
    route of its own reaches the view its GET would, in the main table, on
    the loop, and on the loop with the state; the server drops the body. It
    never reaches another method's view, and a path with no GET is still a
    405 for it.

    covers: N38
    """
    var v = _table()
    v.add_loop(String("GET"), String("/health"), _health)
    v.add_read(String("GET"), String("/stats"), _index, on_loop=True)
    v.add_write(String("POST"), String("/drop"), _bump)
    var st = Counter()
    var head = v.dispatch(_req(String("HEAD"), String("/notes/42")), st)
    assert_equal(head.status_code, 200)
    # The GET's view ran: its body is what the server measures, then drops.
    assert_equal(_body(head), "<p>id 42</p>")
    # `/notes` takes GET and POST; the HEAD is the GET's, never the write.
    assert_equal(_body(v.dispatch(_req(String("HEAD"), String("/notes")), st)), "<p>index 0</p>")
    assert_equal(st.hits, 0)
    assert_true(v.answer_on_loop(_req(String("HEAD"), String("/health"))))
    var stats = v.answer_on_loop(_req(String("HEAD"), String("/stats")), st)
    assert_true(stats, "a HEAD to an on-loop GET was not answered on the loop")
    assert_equal(_body(stats.value()), "<p>index 0</p>")
    # A loop route that reaches dispatch is answered there, HEAD as GET.
    assert_equal(v.dispatch(_req(String("HEAD"), String("/health")), st).status_code, 200)
    var refused = v.dispatch(_req(String("HEAD"), String("/drop")), st)
    assert_equal(refused.status_code, 405)
    assert_equal(refused.headers[HeaderKey.ALLOW], "POST, OPTIONS")
    assert_equal(st.hits, 0)


def test_view_service_needs_no_handler_struct() raises:
    """`ViewService` is the shell an app used to write for itself."""
    var svc = ViewService(_table(), Counter())
    var resp = svc.func(_req(String("GET"), String("/notes")))
    assert_equal(resp.status_code, 200)
    _ = svc.func(_req(String("POST"), String("/notes")))
    assert_equal(svc.state.hits, 1)
    # It is an HTTPService, so it reaches the server generically.
    assert_equal(svc.views.route_count(), 3)


def test_a_loop_route_answers_before_dispatch() raises:
    """`answer_on_loop` is what `before_request` calls, so a loop route
    never reaches `func` and never becomes a pool job."""
    var v = _table()
    v.add_loop(String("GET"), String("/health"), _health)
    assert_equal(v.loop_route_count(), 1)
    var hit = v.answer_on_loop(_req(String("GET"), String("/health")))
    assert_true(hit)
    assert_equal(hit.value().status_code, 200)


def test_a_non_loop_route_falls_through_to_dispatch() raises:
    """A miss on the loop router must be None, not a 404: the request has
    a real view waiting for it on the other side."""
    var v = _table()
    v.add_loop(String("GET"), String("/health"), _health)
    assert_true(not v.answer_on_loop(_req(String("GET"), String("/notes"))))
    # And the wrong method on a loop path is a miss here too, so the main
    # table gets to answer it with its own 404/405.
    assert_true(not v.answer_on_loop(_req(String("POST"), String("/health"))))


def test_no_loop_routes_means_no_matching_at_all() raises:
    """The empty case short-circuits before touching the router, because
    `before_request` runs for every request."""
    var v = _table()
    assert_equal(v.loop_route_count(), 0)
    assert_true(not v.answer_on_loop(_req(String("GET"), String("/health"))))


def test_view_service_answers_loop_routes_in_before_request() raises:
    var v = _table()
    v.add_loop(String("GET"), String("/health"), _health)
    var svc = ViewService(v^, Counter())
    var early = svc.before_request(_req(String("GET"), String("/health")))
    assert_true(early)
    assert_true(not svc.before_request(_req(String("GET"), String("/notes"))))


def test_a_loop_route_in_the_wrong_method_is_405_with_allow() raises:
    """A loop route lives in a second router; `dispatch` still knows it.
    Before this, `POST /health` on an app with only `add_loop("GET",
    "/health")` was 404 "no route for this path" with no `Allow`."""
    var v = _table()
    v.add_loop(String("GET"), String("/health"), _health)
    var st = Counter()
    var resp = v.dispatch(_req(String("POST"), String("/health")), st)
    assert_equal(resp.status_code, 405)
    assert_equal(resp.headers[HeaderKey.ALLOW], "GET, HEAD, OPTIONS")


def test_allow_merges_both_tables_for_one_path() raises:
    var v = _table()
    v.add_loop(String("GET"), String("/x"), _health)
    v.add_write(String("POST"), String("/x"), _bump)
    assert_equal(v.allow_header(String("/x")), "POST, GET, HEAD, OPTIONS")
    var st = Counter()
    var resp = v.dispatch(_req(String("PUT"), String("/x")), st)
    assert_equal(resp.status_code, 405)
    assert_equal(resp.headers[HeaderKey.ALLOW], "POST, GET, HEAD, OPTIONS")
    # A path only one table knows keeps that table's list.
    assert_equal(v.allow_header(String("/health")), "OPTIONS")
    assert_equal(v.allow_header(String("/notes")), "GET, HEAD, POST, OPTIONS")


def test_options_on_a_registered_path_is_204_with_allow() raises:
    """`Router.allow_header` appends OPTIONS because "the server answers
    preflight itself"; `dispatch` now does, so a preflight is never a 405
    whose `Allow` names the method it refused."""
    var v = _table()
    v.add_loop(String("GET"), String("/health"), _health)
    var st = Counter()
    var resp = v.dispatch(_req(String("OPTIONS"), String("/notes")), st)
    assert_equal(resp.status_code, 204)
    assert_equal(resp.headers[HeaderKey.ALLOW], "GET, HEAD, POST, OPTIONS")
    resp = v.dispatch(_req(String("OPTIONS"), String("/health")), st)
    assert_equal(resp.status_code, 204)
    assert_equal(resp.headers[HeaderKey.ALLOW], "GET, HEAD, OPTIONS")
    # On a path nothing serves it is a 404, like any other method.
    resp = v.dispatch(_req(String("OPTIONS"), String("/nope")), st)
    assert_equal(resp.status_code, 404)


def _server_wide_options() raises -> HTTPRequest:
    """`OPTIONS *` as the server builds it from the wire."""
    var parsed = parse_request_headers(
        "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes()
    )
    try:
        return HTTPRequest.from_parsed("127.0.0.1:8080", parsed^, Bytes(), 8192)
    except:
        raise Error("fixture request failed to build")


def test_a_server_wide_options_routes_as_a_path_of_one_segment() raises:
    """`OPTIONS *` reaches a Mojo application with `*` as its path (SPEC
    B19, review record LF41), and the router reads `*` as a path of one
    segment. A table with a one-segment parameter route answers it as that
    route's preflight, 204 with the route's `Allow`; a route registered for
    OPTIONS itself runs with `*` as its parameter; a table with no such
    route answers 404, as for any path it does not serve.

    covers: B19
    """
    var req = _server_wide_options()
    assert_equal(req.uri.path, "*")
    var st = Counter()
    var slug = Views[Counter]()
    slug.add_read(String("GET"), String("/:slug"), _detail)
    var resp = slug.dispatch(_server_wide_options(), st)
    assert_equal(resp.status_code, 204)
    assert_equal(resp.headers[HeaderKey.ALLOW], "GET, HEAD, OPTIONS")
    var own = Views[Counter]()
    own.add_read(String("OPTIONS"), String("/:slug"), _detail)
    resp = own.dispatch(_server_wide_options(), st)
    assert_equal(resp.status_code, 200)
    assert_equal(_body(resp), "<p>id *</p>")
    resp = _table().dispatch(_server_wide_options(), st)
    assert_equal(resp.status_code, 404)


def test_a_loop_route_reaching_dispatch_is_answered_inline() raises:
    """A handler struct that forgot to wire `before_request` used to have
    silently dead loop routes: 404 under every load-balancer probe. The
    view is answered from `dispatch` instead, one round trip slower."""
    var v = _table()
    v.add_loop(String("GET"), String("/health"), _health)
    var st = Counter()
    var resp = v.dispatch(_req(String("GET"), String("/health")), st)
    assert_equal(resp.status_code, 200)
    assert_equal(_body(resp), '{"ok":true}')


def test_a_mounted_table_matches_under_its_prefix_only() raises:
    """A table built with `Mount("/native")` answers `/native/...` — the
    paths the loop routes to a mount — and nothing outside it; `Allow`
    and the mount's own `url_for` agree with it about where things are.

    covers: N9
    """
    var v = Views[Counter](Mount("/native"))
    v.add_read(String("GET"), String("/"), _index)
    v.add_read(String("GET"), String("/notes/:id"), _detail)
    v.add_write(String("POST"), String("/notes"), _bump)
    v.add_loop(String("GET"), String("/health"), _health)
    var st = Counter()
    assert_equal(_body(v.dispatch(_req(String("GET"), String("/native/notes/42")), st)), "<p>id 42</p>")
    assert_equal(v.dispatch(_req(String("GET"), String("/native")), st).status_code, 200)
    assert_equal(v.dispatch(_req(String("GET"), String("/native/")), st).status_code, 200)
    assert_equal(v.dispatch(_req(String("POST"), String("/native/notes")), st).status_code, 204)
    assert_equal(st.hits, 1)
    assert_true(v.answer_on_loop(_req(String("GET"), String("/native/health"))))
    # Outside the prefix the table knows nothing: 404, not a match on the
    # unprefixed pattern, and no loop answer either.
    assert_equal(v.dispatch(_req(String("GET"), String("/notes/42")), st).status_code, 404)
    assert_equal(v.dispatch(_req(String("GET"), String("/")), st).status_code, 404)
    assert_false(v.answer_on_loop(_req(String("GET"), String("/health"))))
    assert_equal(v.allow_header(String("/native/notes")), "POST, OPTIONS")
    assert_equal(v.mount.url_for(String("/notes/:id"), String("42")), "/native/notes/42")


def test_an_on_loop_route_is_answered_with_its_state_before_dispatch() raises:
    """`add_read`/`add_write` with `on_loop=True` keep the route in the
    table -- one `Allow`, one 404, one `url_for` -- and `answer_on_loop`
    with the state answers it on the loop, reads borrowed and writes `mut`.

    covers: N19
    """
    var v = _table()
    v.add_read(String("GET"), String("/stats"), _index, on_loop=True)
    v.add_write(String("POST"), String("/events"), _bump, on_loop=True)
    var st = Counter()
    var got = v.answer_on_loop(_req(String("GET"), String("/stats")), st)
    assert_true(got, "the on-loop read was not answered on the loop")
    assert_equal(_body(got.value()), "<p>index 0</p>")
    var wrote = v.answer_on_loop(_req(String("POST"), String("/events")), st)
    assert_true(wrote, "the on-loop write was not answered on the loop")
    assert_equal(wrote.value().status_code, 204)
    assert_equal(st.hits, 1)
    # Still a plain route everywhere else: the table dispatches it, counts
    # it, and names it in `Allow` exactly once.
    assert_equal(v.route_count(), 5)
    assert_equal(_body(v.dispatch(_req(String("GET"), String("/stats")), st)), "<p>index 1</p>")
    assert_equal(v.allow_header(String("/stats")), "GET, HEAD, OPTIONS")
    assert_equal(v.allow_header(String("/events")), "POST, OPTIONS")
    # A route not flagged is not answered on the loop, and the wrong method
    # on a flagged one falls through to dispatch's 405.
    assert_false(v.answer_on_loop(_req(String("GET"), String("/notes")), st))
    assert_false(v.answer_on_loop(_req(String("DELETE"), String("/stats")), st))
    assert_equal(v.dispatch(_req(String("DELETE"), String("/stats")), st).status_code, 405)


def test_an_on_loop_route_needs_the_state_to_answer_early() raises:
    """The stateless `answer_on_loop` -- a handler with no state at hand,
    or `m0serve`'s loop, which holds no Mojo table -- declines an `on_loop`
    route, and `dispatch` answers it one round trip later, bytes identical.
    A stateless `add_loop` route is still answered by both."""
    var v = _table()
    v.add_read(String("GET"), String("/stats"), _index, on_loop=True)
    v.add_loop(String("GET"), String("/health"), _health)
    assert_false(v.answer_on_loop(_req(String("GET"), String("/stats"))))
    assert_true(v.answer_on_loop(_req(String("GET"), String("/health"))))
    var st = Counter()
    assert_true(v.answer_on_loop(_req(String("GET"), String("/health")), st))
    assert_equal(_body(v.dispatch(_req(String("GET"), String("/stats")), st)), "<p>index 0</p>")


def test_a_raising_on_loop_view_is_500_not_a_crash() raises:
    """`before_request` is non-raising, so the loop answers 500 for it."""
    var v = _table()
    v.add_read(String("GET"), String("/boom"), _raising, on_loop=True)
    var st = Counter()
    var got = v.answer_on_loop(_req(String("GET"), String("/boom")), st)
    assert_true(got)
    assert_equal(got.value().status_code, 500)


def test_a_view_service_answers_on_loop_routes_with_its_state() raises:
    """`ViewService.before_request` hands its own state to the table."""
    var v = _table()
    v.add_read(String("GET"), String("/stats"), _index, on_loop=True)
    var svc = ViewService(v^, Counter())
    var got = svc.before_request(_req(String("GET"), String("/stats")))
    assert_true(got, "ViewService answered no on-loop route")
    assert_equal(_body(got.value()), "<p>index 0</p>")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
