"""Tests for response cookies: an application's `Set-Cookie` reaches the wire verbatim.

`ResponseCookieJar` has two halves. A Mojo handler builds `Cookie` values and
the jar serialises them; an application behind the WSGI/ASGI bridge hands the
server finished `Set-Cookie` lines, and those must be transmitted exactly as
written. Parsing them into `Cookie` first was lossy — `Expiration` is a stub,
`SameSite` matched only lowercase values, a value was cut at its first `=` —
so Django's `sessionid` reached the browser without `expires` or `SameSite`,
on every response of three real projects. `add_raw` is the path the bridge
takes now, and these tests are what hold it verbatim.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.cookie import Cookie, ResponseCookieJar
from lightbug_http.http import HTTPResponse
from lightbug_http.io.bytes import Bytes

# Byte for byte what Django 6 emits for a persistent session, including the
# attribute order Python's `http.cookies` chooses and the capitalised `Lax`.
comptime DJANGO_SESSION = (
    "sessionid=x2o95n13v103d2mmub6ixwyey14kzagn; "
    "expires=Wed, 09 Sep 2026 16:13:44 GMT; HttpOnly; Max-Age=1209600; "
    "Path=/; SameSite=Lax"
)


def _wire(var jar: ResponseCookieJar) -> String:
    """The response as it would be written, headers and cookies included."""
    var resp = HTTPResponse(owned_body=Bytes(), cookies=jar^)
    return String(resp)


def _count(haystack: String, needle: String) -> Int:
    return len(haystack.split(needle)) - 1


def test_raw_line_reaches_the_wire_verbatim() raises:
    """Attributes survive: expires, HttpOnly, Max-Age, Path, SameSite=Lax.

    covers: G3
    """
    var jar = ResponseCookieJar()
    jar.add_raw(DJANGO_SESSION)
    var wire = _wire(jar^)
    assert_true(
        ("set-cookie: " + DJANGO_SESSION + "\r\n") in wire,
        "the application's line was not transmitted unchanged:\n" + wire,
    )


def test_value_with_equals_is_not_truncated() raises:
    """A cookie-value is opaque and base64 pads with `=`."""
    var jar = ResponseCookieJar()
    jar.add_raw("token=YWJj==; Path=/")
    var wire = _wire(jar^)
    assert_true("set-cookie: token=YWJj==; Path=/\r\n" in wire, wire)


def test_unknown_attribute_survives() raises:
    """An attribute this server has never heard of is not its to drop."""
    var jar = ResponseCookieJar()
    jar.add_raw("id=1; Path=/; Priority=High; Partitioned")
    var wire = _wire(jar^)
    assert_true("set-cookie: id=1; Path=/; Priority=High; Partitioned\r\n" in wire, wire)


def test_each_raw_line_is_its_own_header() raises:
    """Django sets sessionid and csrftoken on one response: two lines out."""
    var jar = ResponseCookieJar()
    jar.add_raw("csrftoken=a; Max-Age=31449600; Path=/; SameSite=Lax")
    jar.add_raw("sessionid=b; HttpOnly; Path=/; SameSite=Lax")
    assert_equal(len(jar), 2)
    assert_false(jar.empty())
    var wire = _wire(jar^)
    assert_equal(_count(wire, "set-cookie: "), 2)


def test_parsed_and_raw_cookies_coexist() raises:
    """A Mojo handler's own cookies and an application's lines share a jar."""
    var jar = ResponseCookieJar()
    jar.set_cookie(Cookie("mojo", "1", path=String("/")))
    jar.add_raw("app=2; Path=/; SameSite=Strict")
    assert_equal(len(jar), 2)
    var wire = _wire(jar^)
    assert_true("set-cookie: mojo=1; Path=/\r\n" in wire, wire)
    assert_true("set-cookie: app=2; Path=/; SameSite=Strict\r\n" in wire, wire)


def test_empty_jar_writes_nothing() raises:
    var jar = ResponseCookieJar()
    assert_true(jar.empty())
    var wire = _wire(jar^)
    assert_equal(_count(wire, "set-cookie: "), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
