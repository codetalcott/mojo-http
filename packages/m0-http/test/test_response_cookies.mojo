"""Tests for response cookies: an application's `Set-Cookie` reaches the wire verbatim.

`ResponseCookieJar` has two halves. A Mojo handler builds `Cookie` values and
the jar serialises them; an application behind the WSGI/ASGI bridge hands the
server finished `Set-Cookie` lines, and those must be transmitted exactly as
written. Parsing them into `Cookie` first was lossy — `Expiration` was a stub,
`SameSite` matched only lowercase values, a value was cut at its first `=` —
so Django's `sessionid` reached the browser without `expires` or `SameSite`,
on every response of three real projects. `add_raw` is the path the bridge
takes now, and these tests are what hold it verbatim.
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.cookie import Cookie, Duration, ResponseCookieJar, SameSite
from lightbug_http.header import Header, Headers
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


def _bytes_find(hay: List[Byte], needle: List[Byte]) -> Int:
    var n = len(needle)
    if n > len(hay):
        return -1
    for i in range(len(hay) - n + 1):
        var hit = True
        for j in range(n):
            if hay[i + j] != needle[j]:
                hit = False
                break
        if hit:
            return i
    return -1


def _line(text: String, var tail: List[Byte]) -> List[Byte]:
    """`text`'s bytes, then `tail`, then CRLF: a head line whose high bytes
    are spelled out rather than left to a literal's encoding."""
    var out = List[Byte](text.as_bytes())
    out.extend(tail^)
    out.append(0x0D)
    out.append(0x0A)
    return out^


def _latin1_jar() -> ResponseCookieJar:
    """What the bridge stores for three applications' lines. It keeps every
    header as UTF-8 and leaves the transcode back to latin-1 to the writer:
    a WSGI application's `caf\\xe9` arrives as the UTF-8 for U+00E9, an
    ASGI application's own bytes `caf\\xc3\\xa9` as U+00C3 U+00A9, one
    code point per byte it sent."""
    var jar = ResponseCookieJar()
    jar.add_raw("wsgi=café; Path=/")
    jar.add_raw("asgi=cafÃ©; Path=/")
    jar.set_cookie(Cookie("built", "é"))
    return jar^


def _assert_latin1_on_the_wire(wire: List[Byte]) raises:
    var e9 = List[Byte]()
    e9.append(0xE9)
    var wsgi = List[Byte]()
    wsgi.append(0xE9)
    wsgi.extend(String("; Path=/").as_bytes())
    assert_true(
        _bytes_find(wire, _line("set-cookie: wsgi=caf", wsgi^)) >= 0,
        "a WSGI application's latin-1 cookie did not reach the wire as latin-1",
    )
    var asgi = List[Byte]()
    asgi.append(0xC3)
    asgi.append(0xA9)
    asgi.extend(String("; Path=/").as_bytes())
    assert_true(
        _bytes_find(wire, _line("set-cookie: asgi=caf", asgi^)) >= 0,
        "an ASGI application's own cookie bytes did not reach the wire as sent",
    )
    assert_true(
        _bytes_find(wire, _line("set-cookie: built=", e9^)) >= 0,
        "a built cookie's value was not written as latin-1",
    )
    # And the ordinary header beside it, which always went out latin-1:
    # the cookie now agrees with it.
    var header = List[Byte]()
    header.append(0xE9)
    assert_true(_bytes_find(wire, _line("x-latin: caf", header^)) >= 0)


def test_a_line_above_ascii_goes_out_latin1_like_every_header() raises:
    """RFC 9110 §5.5 and PEP 3333: header bytes above 0x7F are latin-1 on
    the wire. `Headers.write_latin1_to` transcoded every other header's
    value from the UTF-8 it is stored in, and the jar wrote its lines'
    UTF-8 as it stood -- so a WSGI application's `caf\\xe9` went out as
    `caf\\xc3\\xa9`, and an ASGI application's own `caf\\xc3\\xa9` as
    `caf\\xc3\\x83\\xc2\\xa9`, both measured against `bin/m0serve`. Held on
    the bytes of both encoders, `encode` and `encode_into`.

    covers: G17
    """
    var r1 = HTTPResponse(
        owned_body=Bytes(),
        headers=Headers(Header("x-latin", "café")),
        cookies=_latin1_jar(),
    )
    _assert_latin1_on_the_wire(r1^.encode())
    var r2 = HTTPResponse(
        owned_body=Bytes(),
        headers=Headers(Header("x-latin", "café")),
        cookies=_latin1_jar(),
    )
    _assert_latin1_on_the_wire(r2^.encode_into(Bytes(capacity=256)))



def test_a_built_cookie_writes_every_attribute() raises:
    """`Cookie.build_header_value`: `name=value`, then each attribute that is
    set, in one order -- `Max-Age` from a `Duration` in any units, `Domain`,
    `Path`, `Secure`, `HttpOnly`, `SameSite` in each of its three values,
    `Partitioned` -- and nothing for one that is not."""
    assert_equal(Cookie("a", "1").build_header_value(), "a=1")
    var full = Cookie(
        "sid",
        "v=1",
        max_age=Duration(seconds=5, minutes=1, hours=1, days=1),
        domain=String("example.test"),
        path=String("/app"),
        same_site=SameSite.strict,
        secure=True,
        http_only=True,
        partitioned=True,
    )
    assert_equal(
        full.build_header_value(),
        "sid=v=1; Max-Age=90065; Domain=example.test; Path=/app; Secure;"
        " HttpOnly; SameSite=strict; Partitioned",
    )
    assert_equal(
        Cookie("a", "1", same_site=SameSite.lax).build_header_value(),
        "a=1; SameSite=lax",
    )
    assert_equal(
        Cookie("a", "1", same_site=SameSite.none, secure=True).build_header_value(),
        "a=1; Secure; SameSite=none",
    )
    assert_equal(
        Cookie("a", "", max_age=Duration(seconds=0)).build_header_value(),
        "a=; Max-Age=0",
    )


def test_one_cookie_per_name_domain_and_path() raises:
    """The jar keys a built cookie by name, domain and path (RFC 6265 §5.3
    step 11): setting the same three again replaces the first, and a second
    path or domain is a second cookie. No domain is the host's, no path
    `/`."""
    var jar = ResponseCookieJar()
    jar.set_cookie(Cookie("a", "1"))
    jar.set_cookie(Cookie("a", "2", path=String("/")))
    assert_equal(len(jar), 1)
    jar.set_cookie(Cookie("a", "3", path=String("/x")))
    jar.set_cookie(Cookie("a", "4", domain=String("example.test")))
    assert_equal(len(jar), 3)
    var wire = _wire(jar^)
    assert_equal(_count(wire, "set-cookie: "), 3)
    assert_true("set-cookie: a=2; Path=/\r\n" in wire, wire)
    assert_true("set-cookie: a=3; Path=/x\r\n" in wire, wire)
    assert_true("set-cookie: a=4; Domain=example.test\r\n" in wire, wire)
    assert_false("a=1" in wire, wire)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
