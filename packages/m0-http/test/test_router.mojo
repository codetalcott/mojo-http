"""Tests for the HTTP router."""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from src.router import Router, MatchResult


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
