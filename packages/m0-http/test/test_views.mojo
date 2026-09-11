"""The view table: dispatch, the 404/405 shapes, and the drift it prevents.

No `covers:` line: SPEC.md's sections are protocol, process model and
gateway conformance, and the framework layer (router, reply, negotiation)
has no row there for this to claim. If routing ever gets a section, this
file is its gate.
"""

from std.testing import TestSuite, assert_equal, assert_true

from lightbug_http.header import HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.uri import URI

from src import reply
from src.views import Views, ViewService


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
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("PUT"), String("/notes")), st)
    assert_equal(resp.status_code, 405)
    var allow = resp.headers.get(HeaderKey.ALLOW)
    assert_true(allow)
    # `Router.allow_header` adds OPTIONS itself — every path answers it.
    assert_equal(allow.value(), "GET, POST, OPTIONS")


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
