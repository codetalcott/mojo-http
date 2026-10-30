"""Tests for the `Origin` check on a held WebSocket's handshake.

Pure functions of strings, so no interpreter, as `test_cli`. What the
handler does with the answer (a 403 before any subscription, the notice)
is `smoke-django-realtime-ws`'s, against a real server.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true, TestSuite

from src.ws_origin import normalize_ws_origin, ws_origin_allowed


def _none() -> List[String]:
    return List[String]()


def test_a_handshake_is_upgraded_from_its_own_origin_and_refused_from_another() raises:
    """A handshake from the request's own host is upgraded, one with no
    `Origin` (no browser) too, and every other origin is refused.

    covers: I48
    """
    var none = _none()
    assert_true(ws_origin_allowed("", "example.com", "", none))
    assert_true(ws_origin_allowed("https://example.com", "example.com", "", none))
    assert_true(ws_origin_allowed("http://localhost:8000", "localhost:8000", "", none))
    assert_true(ws_origin_allowed("http://[::1]:8000", "[::1]:8000", "", none))
    assert_false(ws_origin_allowed("https://evil.example", "example.com", "", none))
    assert_false(ws_origin_allowed("http://localhost:5173", "localhost:8000", "", none))
    # A sibling host is another origin, the case SameSite cookies do not
    # cover: `a.example.com` and `example.com` are one site.
    assert_false(ws_origin_allowed("https://a.example.com", "example.com", "", none))
    assert_false(ws_origin_allowed("https://example.com.evil", "example.com", "", none))
    assert_false(ws_origin_allowed("null", "example.com", "", none))
    assert_false(ws_origin_allowed("https://example.com", "", "", none))


def test_case_folds_in_ascii_and_a_default_port_is_the_same_origin() raises:
    var none = _none()
    assert_true(ws_origin_allowed("HTTPS://Example.COM", "example.com", "", none))
    assert_true(ws_origin_allowed("https://example.com", "EXAMPLE.com:443", "", none))
    assert_true(ws_origin_allowed("http://example.com:80", "example.com", "", none))
    # A default port is the scheme's own: 443 is not http's.
    assert_false(ws_origin_allowed("http://example.com", "example.com:443", "", none))
    # KELVIN SIGN (U+212A) is `k` to a Unicode fold and not to a browser,
    # which sends hosts in ASCII: no fold here may make it match.
    assert_false(
        ws_origin_allowed("https://Kiwi.example", "kiwi.example", "", none)
    )


def test_a_proxy_s_forwarded_host_is_the_same_origin_and_the_first_one_counts() raises:
    var none = _none()
    assert_true(
        ws_origin_allowed("https://example.com", "app:8000", "example.com", none)
    )
    assert_true(
        ws_origin_allowed(
            "https://example.com", "app:8000", "example.com, internal:8000", none
        )
    )
    assert_false(
        ws_origin_allowed(
            "https://example.com", "app:8000", "internal:8000, example.com", none
        )
    )


def test_an_operator_names_the_origins_beside_its_own_or_any() raises:
    var allowed = List[String]()
    allowed.append(normalize_ws_origin("https://app.example.com/"))
    allowed.append(normalize_ws_origin("HTTP://Localhost:5173"))
    assert_true(ws_origin_allowed("https://app.example.com", "api.example.com", "", allowed))
    assert_true(ws_origin_allowed("http://localhost:5173", "localhost:8000", "", allowed))
    assert_true(ws_origin_allowed("https://api.example.com", "api.example.com", "", allowed))
    assert_false(ws_origin_allowed("https://evil.example", "api.example.com", "", allowed))
    var any = List[String]()
    any.append(normalize_ws_origin("*"))
    assert_true(ws_origin_allowed("https://evil.example", "example.com", "", any))
    assert_true(ws_origin_allowed("null", "example.com", "", any))
    var sandboxed = List[String]()
    sandboxed.append(normalize_ws_origin("null"))
    assert_true(ws_origin_allowed("null", "example.com", "", sandboxed))


def test_an_origin_that_is_not_one_is_refused_as_a_setting() raises:
    assert_equal(normalize_ws_origin("https://example.com:443"), "https://example.com")
    assert_equal(normalize_ws_origin(" http://example.com:8080 "), "http://example.com:8080")
    with assert_raises(contains="--ws-origin expects an origin"):
        _ = normalize_ws_origin("example.com")
    with assert_raises(contains="--ws-origin expects an origin"):
        _ = normalize_ws_origin("https://example.com/app")
    with assert_raises(contains="--ws-origin expects an origin"):
        _ = normalize_ws_origin("ws://example.com")
    with assert_raises(contains="--ws-origin expects an origin"):
        _ = normalize_ws_origin("https://")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
