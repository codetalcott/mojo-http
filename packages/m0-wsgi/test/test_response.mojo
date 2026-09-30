"""Tests for the WSGI response assembly — status parsing.

No interpreter here, same charter as `test_hold` and `test_environ`:
`split_status` is a pure function over Mojo values, so every branch is
reachable without embedding CPython. What is NOT reachable here is
`build_response` itself, which needs a live `PyBridge` and real
`PythonObject` headers: `test_read_head.mojo` drives it through an
interpreter, and `smoke-wsgi` against a running server, where the
response-splitting half is pinned too.
"""

from std.testing import assert_equal, TestSuite

from src.response import split_status


# --- split_status ------------------------------------------------------------


def test_split_status_ordinary() raises:
    var got = split_status("404 Not Found")
    assert_equal(got[0], 404)
    assert_equal(got[1], "Not Found")


def test_split_status_code_only() raises:
    var got = split_status("204")
    assert_equal(got[0], 204)
    assert_equal(got[1], "")


def test_split_status_malformed_becomes_500() raises:
    """A bad status is not worth discarding a real body over."""
    var got = split_status("not-a-status here")
    assert_equal(got[0], 500)
    assert_equal(got[1], "Internal Server Error")


def test_split_status_multiword_reason_survives() raises:
    var got = split_status("418 I'm a teapot")
    assert_equal(got[0], 418)
    assert_equal(got[1], "I'm a teapot")


# --- an injected status ------------------------------------------------------


def test_an_injected_status_keeps_its_code() raises:
    """`start_response("200 OK\\r\\nSet-Cookie: hijack=1", ...)` is still a
    200: the code is the application's choice and survives. The phrase is
    passed on as written, and the fork's encoders write an empty one in its
    place (SPEC G1, `test_response_splitting.mojo`): they are the only
    readers of `status_text`, so a refusal here was a second copy with
    nothing left to protect, and was deleted on 2026-09-29."""
    assert_equal(split_status("200 OK\r\nSet-Cookie: hijack=1")[0], 200)
    assert_equal(split_status("302 Found\nLocation: http://evil.example")[0], 302)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
