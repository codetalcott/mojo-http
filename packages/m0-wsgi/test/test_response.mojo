"""Tests for the WSGI response assembly — status parsing and header hygiene.

No interpreter here, same charter as `test_hold` and `test_environ`:
`split_status` and `has_control_bytes` are pure functions over Mojo values,
so every branch is reachable without embedding CPython. What is NOT
reachable here is `build_response` itself, which needs a live `PyBridge` and
real `PythonObject` headers — `smoke-wsgi` drives that against a running
server, and the response-splitting half of it is pinned there too.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.response import has_control_bytes, split_status


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


# --- control bytes -----------------------------------------------------------


def test_has_control_bytes_finds_the_framing_bytes() raises:
    assert_true(has_control_bytes(String("a\r\nInjected: 1")))
    assert_true(has_control_bytes(String("plain\r")))
    assert_true(has_control_bytes(String("plain\n")))
    assert_true(has_control_bytes(String("nul\0here")))


def test_has_control_bytes_passes_ordinary_values() raises:
    """Header values legitimately carry spaces, punctuation, and high bytes;
    refusing those would break real applications."""
    assert_false(has_control_bytes(String("text/html; charset=utf-8")))
    assert_false(has_control_bytes(String("sid=abc; Path=/; SameSite=Lax")))
    assert_false(has_control_bytes(String("")))
    assert_false(has_control_bytes(String("W/\"tag-123\"")))
    # A tab is legal inside a header value (RFC 9110 field-content).
    assert_false(has_control_bytes(String("a\tb")))
    # Bytes above 0x7F reach the wire latin-1 encoded, and are not framing.
    assert_false(has_control_bytes(String("café")))


def test_status_reason_with_crlf_is_emptied_not_transmitted() raises:
    """The reason phrase is written verbatim into the status line, and is
    the part frameworks that validate header PAIRS still leave unchecked:
    `start_response("200 OK\\r\\nSet-Cookie: x=1", ...)` would otherwise put
    a header on the wire that the application never listed.

    The code survives — only the injected text is dropped.
    """
    var got = split_status("200 OK\r\nSet-Cookie: hijack=1")
    assert_equal(got[0], 200)
    assert_equal(got[1], "")
    assert_false(has_control_bytes(got[1]))


def test_status_reason_with_bare_lf_is_emptied() raises:
    """Bare LF ends a line for most parsers, so it is refused with CRLF."""
    var got = split_status("302 Found\nLocation: http://evil.example")
    assert_equal(got[0], 302)
    assert_equal(got[1], "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
