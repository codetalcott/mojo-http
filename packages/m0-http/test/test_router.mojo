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

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
