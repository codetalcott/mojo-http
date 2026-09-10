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
from src.views import Views


struct Counter(Movable):
    """A stand-in for whatever an application keeps between requests."""

    var hits: Int
    var last: String

    def __init__(out self):
        self.hits = 0
        self.last = String("")


def _index(
    req: HTTPRequest, params: List[String], mut st: Counter
) raises -> HTTPResponse:
    st.hits += 1
    st.last = String("index")
    return reply.html(String("<p>index</p>"))


def _detail(
    req: HTTPRequest, params: List[String], mut st: Counter
) raises -> HTTPResponse:
    st.hits += 1
    st.last = String("detail")
    return reply.html(String("<p>id ", params[0], "</p>"))


def _custom_404(
    req: HTTPRequest, params: List[String], mut st: Counter
) raises -> HTTPResponse:
    st.last = String("missing")
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
    v.add(String("GET"), String("/notes"), _index)
    v.add(String("GET"), String("/notes/:id"), _detail)
    return v^


def test_dispatch_calls_the_registered_view() raises:
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("GET"), String("/notes")), st)
    assert_equal(resp.status_code, 200)
    assert_equal(_body(resp), "<p>index</p>")
    assert_equal(st.last, "index")


def test_a_view_receives_its_captured_parameters() raises:
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("GET"), String("/notes/42")), st)
    assert_equal(_body(resp), "<p>id 42</p>")


def test_state_mutations_persist_across_dispatches() raises:
    var v = _table()
    var st = Counter()
    _ = v.dispatch(_req(String("GET"), String("/notes")), st)
    _ = v.dispatch(_req(String("GET"), String("/notes/1")), st)
    assert_equal(st.hits, 2)


def test_ids_are_assigned_in_registration_order() raises:
    """The drift guard. `add` is the only way to register, so the id it
    assigns and the function it stores cannot disagree — there is no
    second edit to forget. Registering N routes stores N views."""
    var v = _table()
    assert_equal(v.route_count(), 2)
    v.add(String("DELETE"), String("/notes/:id"), _index)
    assert_equal(v.route_count(), 3)
    # The route added last dispatches to the view added last.
    var st = Counter()
    _ = v.dispatch(_req(String("DELETE"), String("/notes/9")), st)
    assert_equal(st.last, "index")


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
    assert_equal(st.last, "missing")


def test_wrong_method_is_405_with_allow() raises:
    var v = _table()
    var st = Counter()
    var resp = v.dispatch(_req(String("POST"), String("/notes")), st)
    assert_equal(resp.status_code, 405)
    var allow = resp.headers.get(HeaderKey.ALLOW)
    assert_true(allow)
    # `Router.allow_header` adds OPTIONS itself — every path answers it.
    assert_equal(allow.value(), "GET, OPTIONS")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
