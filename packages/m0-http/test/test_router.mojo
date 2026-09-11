"""Tests for the HTTP router."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.router import Router, MatchResult, reverse, url_for


def test_exact_match() raises:
    """Exact path should match."""
    var r = Router()
    r.add("GET", "/orders", 1)
    var m = r.match("GET", "/orders")
    assert_true(m.matched)
    assert_equal(m.handler_id, 1)
    assert_equal(len(m.params), 0)


def test_param_extraction() raises:
    """Route with :param should extract the value."""
    var r = Router()
    r.add("GET", "/orders/:id", 2)
    var m = r.match("GET", "/orders/42")
    assert_true(m.matched)
    assert_equal(m.handler_id, 2)
    assert_equal(len(m.params), 1)
    assert_equal(m.params[0], "42")


def test_multi_param() raises:
    """Multiple :param segments should all be extracted."""
    var r = Router()
    r.add("GET", "/users/:uid/orders/:oid", 3)
    var m = r.match("GET", "/users/alice/orders/99")
    assert_true(m.matched)
    assert_equal(len(m.params), 2)
    assert_equal(m.params[0], "alice")
    assert_equal(m.params[1], "99")


def test_no_match_404() raises:
    """Unregistered path should not match (404)."""
    var r = Router()
    r.add("GET", "/orders", 1)
    var m = r.match("GET", "/users")
    assert_false(m.matched)
    assert_false(m.method_not_allowed)


def test_method_not_allowed_405() raises:
    """Path match with wrong method should signal 405."""
    var r = Router()
    r.add("GET", "/orders", 1)
    var m = r.match("POST", "/orders")
    assert_false(m.matched)
    assert_true(m.method_not_allowed)


def test_multiple_methods() raises:
    """Same path with different methods should route correctly."""
    var r = Router()
    r.add("GET", "/orders", 1)
    r.add("POST", "/orders", 2)
    var g = r.match("GET", "/orders")
    var p = r.match("POST", "/orders")
    assert_equal(g.handler_id, 1)
    assert_equal(p.handler_id, 2)


def test_segment_count_mismatch() raises:
    """Paths with different segment counts should not match."""
    var r = Router()
    r.add("GET", "/orders/:id", 1)
    var m = r.match("GET", "/orders")
    assert_false(m.matched)


def test_trailing_slash() raises:
    """Trailing slash should still match (empty segments filtered)."""
    var r = Router()
    r.add("GET", "/orders", 1)
    var m = r.match("GET", "/orders/")
    assert_true(m.matched)

# --- the span-based rewrite ------------------------------------------------
#
# Matching moved from splitting the path into Strings to walking it with
# span endpoints. These pin the behaviour the rewrite had to preserve, and
# `test_matches_the_string_splitting_reference` is the differential check:
# a transcription of the old implementation, run against the new one over
# every method x path pair below.


struct _RefRoute(Copyable, Movable):
    var method: String
    var segments: List[String]
    var handler_id: Int

    def __init__(out self, method: String, pattern: String, handler_id: Int):
        self.method = method
        self.handler_id = handler_id
        self.segments = List[String]()
        var parts = pattern.split("/")
        for i in range(len(parts)):
            var p = String(parts[i])
            if p.byte_length() > 0:
                self.segments.append(p)


def _ref_match(
    routes: List[_RefRoute], method: String, path: String
) -> MatchResult:
    """The String-splitting matcher the span walk replaced, kept as oracle."""
    var req_segments = List[String]()
    var parts = path.split("/")
    for i in range(len(parts)):
        var p = String(parts[i])
        if p.byte_length() > 0:
            req_segments.append(p)

    var req_count = len(req_segments)
    var path_matched = False
    for i in range(len(routes)):
        if len(routes[i].segments) != req_count:
            continue
        var params = List[String]()
        var matched = True
        for j in range(req_count):
            var rs = String(routes[i].segments[j])
            if rs.byte_length() > 0 and rs.startswith(":"):
                params.append(req_segments[j])
            elif rs != req_segments[j]:
                matched = False
                break
        if not matched:
            continue
        if routes[i].method == method:
            return MatchResult(routes[i].handler_id, params^)
        path_matched = True

    if path_matched:
        var r = MatchResult()
        r.method_not_allowed = True
        return r^
    return MatchResult()


def _table() -> List[Tuple[String, String, Int]]:
    var t = List[Tuple[String, String, Int]]()
    t.append(("GET", String("/"), 0))
    t.append(("GET", String("/health"), 1))
    t.append(("GET", String("/notes"), 2))
    t.append(("POST", String("/notes"), 3))
    t.append(("GET", String("/notes/:id"), 4))
    t.append(("PUT", String("/notes/:id"), 5))
    t.append(("DELETE", String("/notes/:id"), 6))
    t.append(("GET", String("/notes/:id/comments"), 7))
    t.append(("GET", String("/a/:x/b/:y/c/:z"), 8))
    t.append(("GET", String("/static/:path"), 9))
    return t^


def test_matches_the_string_splitting_reference() raises:
    var table = _table()
    var new = Router()
    var oracle = List[_RefRoute]()
    for i in range(len(table)):
        new.add(table[i][0], table[i][1], table[i][2])
        oracle.append(_RefRoute(table[i][0], table[i][1], table[i][2]))

    var paths = List[String]()
    paths.append("/")
    paths.append("")
    paths.append("/health")
    paths.append("/notes")
    paths.append("/notes/42")
    paths.append("/notes/42/comments")
    paths.append("/notes/42/comments/9")
    paths.append("/a/1/b/2/c/3")
    paths.append("/static/app.css")
    paths.append("/nope")
    paths.append("/notes/1/nope")
    paths.append("//notes//42//")      # repeated separators
    paths.append("/notes/")            # trailing slash
    paths.append("/NOTES/42")          # case differs
    paths.append("/health/extra")

    var methods = List[String]()
    methods.append("GET")
    methods.append("POST")
    methods.append("PUT")
    methods.append("DELETE")
    methods.append("PATCH")
    methods.append("get")              # method match is case-sensitive

    for p in range(len(paths)):
        for m in range(len(methods)):
            var a = _ref_match(oracle, methods[m], paths[p])
            var b = new.match(methods[m], paths[p])
            assert_equal(a.matched, b.matched)
            assert_equal(a.method_not_allowed, b.method_not_allowed)
            assert_equal(a.handler_id, b.handler_id)
            assert_equal(len(a.params), len(b.params))
            for k in range(len(a.params)):
                assert_equal(a.params[k], b.params[k])


def test_captures_several_params_in_order() raises:
    var r = Router()
    r.add("GET", "/a/:x/b/:y/c/:z", 8)
    var m = r.match("GET", "/a/1/b/two/c/3")
    assert_true(m.matched)
    assert_equal(len(m.params), 3)
    assert_equal(m.params[0], "1")
    assert_equal(m.params[1], "two")
    assert_equal(m.params[2], "3")


def test_param_capture_is_unaffected_by_repeated_slashes() raises:
    var r = Router()
    r.add("GET", "/notes/:id", 4)
    var m = r.match("GET", "//notes//42//")
    assert_true(m.matched)
    assert_equal(len(m.params), 1)
    assert_equal(m.params[0], "42")


def test_deep_path_has_no_segment_cap() raises:
    # The matcher keeps no fixed-size scratch, so depth is unbounded.
    var pattern = String("")
    var path = String("")
    for i in range(64):
        pattern += "/:p" + String(i)
        path += "/v" + String(i)
    var r = Router()
    r.add("GET", pattern, 7)
    var m = r.match("GET", path)
    assert_true(m.matched)
    assert_equal(m.handler_id, 7)
    assert_equal(len(m.params), 64)
    assert_equal(m.params[0], "v0")
    assert_equal(m.params[63], "v63")


def test_a_miss_still_reports_405_from_a_later_route() raises:
    # The 405 signal must survive the segment-count fast rejection.
    var r = Router()
    r.add("GET", "/a/b/c", 1)
    r.add("POST", "/notes", 2)
    var m = r.match("GET", "/notes")
    assert_false(m.matched)
    assert_true(m.method_not_allowed)


def test_param_does_not_match_across_a_separator() raises:
    var r = Router()
    r.add("GET", "/notes/:id", 4)
    var m = r.match("GET", "/notes/42/extra")
    assert_false(m.matched)
    assert_false(m.method_not_allowed)


def test_allow_header_lists_registered_methods() raises:
    """`Allow:` is read off the table, not probed with a guessed method list."""
    var r = Router()
    r.add("GET", "/notes/:id", 1)
    r.add("PUT", "/notes/:id", 2)
    r.add("DELETE", "/notes/:id", 3)
    assert_equal(r.allow_header("/notes/7"), "GET, PUT, DELETE, OPTIONS")


def test_allow_header_includes_methods_nobody_enumerated() raises:
    """The old hand-rolled version probed a hardcoded GET/POST/PUT/DELETE list.

    A route registered in any other method was silently missing from the 405.
    """
    var r = Router()
    r.add("GET", "/notes/:id", 1)
    r.add("PATCH", "/notes/:id", 2)
    assert_equal(r.allow_header("/notes/7"), "GET, PATCH, OPTIONS")


def test_allow_header_on_an_unrouted_path_is_options_only() raises:
    """Never an empty header value: a path with no routes still allows OPTIONS."""
    var r = Router()
    r.add("GET", "/notes", 1)
    assert_equal(r.allow_header("/nothing/here"), "OPTIONS")


def test_allow_header_ignores_paths_that_do_not_match() raises:
    """Segment count and literal segments both gate a route out."""
    var r = Router()
    r.add("GET", "/notes", 1)
    r.add("POST", "/notes", 2)
    r.add("DELETE", "/notes/:id", 3)
    assert_equal(r.allow_header("/notes"), "GET, POST, OPTIONS")
    assert_equal(r.allow_header("/notes/7"), "DELETE, OPTIONS")


def test_allow_header_does_not_repeat_a_method() raises:
    """Two routes sharing a path and method must not double the header value."""
    var r = Router()
    r.add("GET", "/notes/:id", 1)
    r.add("GET", "/notes/:slug", 2)
    assert_equal(r.allow_header("/notes/7"), "GET, OPTIONS")


def test_allow_header_agrees_with_match() raises:
    """The two must not disagree — they share `_path_matches` for that reason."""
    var r = Router()
    r.add("GET", "/a/:x/b", 1)
    r.add("POST", "/a/:x/b", 2)
    var allow = r.allow_header("/a/1/b")
    assert_true("GET" in allow)
    assert_true("POST" in allow)
    assert_true(r.match("GET", "/a/1/b").matched)
    assert_true(r.match("POST", "/a/1/b").matched)
    # a method absent from Allow must be a 405, not a match
    assert_false("DELETE" in allow)
    assert_true(r.match("DELETE", "/a/1/b").method_not_allowed)


def test_method_of_reads_back_the_registration() raises:
    var r = Router()
    r.add("GET", "/x", 1)
    r.add("DELETE", "/y", 2)
    assert_equal(r.method_of(0), "GET")
    assert_equal(r.method_of(1), "DELETE")


def test_pattern_of_reads_back_the_registration() raises:
    """The pattern as the router understands it: repeated and trailing
    slashes gone, `:name` segments kept, the root as `/`."""
    var r = Router()
    r.add("GET", "/notes/:id", 1)
    r.add("GET", "//a///b/", 2)
    r.add("GET", "/", 3)
    r.add("GET", "/x/:a/:b", 4)
    assert_equal(r.route_count(), 4)
    assert_equal(r.pattern_of(0), "/notes/:id")
    assert_equal(r.pattern_of(1), "/a/b")
    assert_equal(r.pattern_of(2), "/")
    assert_equal(r.pattern_of(3), "/x/:a/:b")
    assert_equal(r.param_count_of(0), 1)
    assert_equal(r.param_count_of(1), 0)
    assert_equal(r.param_count_of(3), 2)
    assert_equal(r.handler_of(3), 4)


def test_url_for_fills_captures_in_order() raises:
    assert_equal(url_for("/notes"), "/notes")
    assert_equal(url_for("/"), "/")
    assert_equal(url_for("/notes/:id", String(7)), "/notes/7")
    assert_equal(url_for("/a/:x/b/:y", "1", "2"), "/a/1/b/2")


def test_url_for_refuses_the_wrong_arity() raises:
    """A bad reverse is a programming error whose silent form is a dead
    link, so it raises — unlike `param_int`, which handles untrusted input
    and returns -1."""
    var raised = False
    try:
        _ = url_for("/notes/:id")
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = url_for("/notes", "7")
    except:
        raised = True
    assert_true(raised)


def test_url_for_refuses_an_empty_value() raises:
    """`url_for("/notes/:id", "")` used to give `/notes/`, which `match`
    collapses to the `/notes` collection — the reverse of one route
    naming another, silently. A blank id is a programming error."""
    var raised = False
    try:
        _ = url_for("/notes/:id", "")
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = reverse("/a/:x/:y", [String("1"), String("")])
    except:
        raised = True
    assert_true(raised)


def test_url_for_encodes_a_parameter_to_one_segment() raises:
    """A value with a slash or a space cannot add a segment or break the
    path; unreserved characters pass through, everything else is `%XX`."""
    assert_equal(url_for("/n/:id", "a b/c?d"), "/n/a%20b%2Fc%3Fd")
    assert_equal(url_for("/n/:id", "A-z.0_9~"), "/n/A-z.0_9~")
    assert_equal(url_for("/n/:id", "café"), "/n/caf%C3%A9")


def test_every_registered_route_reverses_and_matches() raises:
    """The property that keeps the two directions honest: for every route
    a router holds, reversing its pattern with synthetic parameters gives
    a path that `match` sends back to the same handler with those same
    parameters captured. A table with a route `url_for` cannot rebuild,
    or a pattern `match` reads differently from `pattern_of`, fails here.

    covers: N5
    """
    var r = Router()
    r.add("GET", "/", 10)
    r.add("GET", "/notes", 11)
    r.add("POST", "/notes", 12)
    r.add("GET", "/notes/:id", 13)
    r.add("DELETE", "/notes/:id", 14)
    r.add("PUT", "/users/:user/notes/:id", 15)
    r.add("GET", "/deep/a/b/c/:d/e", 16)
    assert_equal(r.route_count(), 7)
    for i in range(r.route_count()):
        var params = List[String]()
        for k in range(r.param_count_of(i)):
            params.append(String("p", k))
        var path = reverse(r.pattern_of(i), params)
        var m = r.match(r.method_of(i), path)
        assert_true(m.matched, String("route ", i, " did not match its own reverse ", path))
        assert_equal(m.handler_id, r.handler_of(i))
        assert_equal(len(m.params), len(params))
        for k in range(len(params)):
            assert_equal(m.params[k], params[k])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
