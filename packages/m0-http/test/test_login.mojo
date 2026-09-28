"""The login an application builds on the signed session (`src/login.mojo`).

What is pinned: the configuration fails closed, naming the variable, and
reads what it was given; only the one user's credentials start a session,
whose cookie reads back as that user, under the previous key too while a
rotation lasts; a request with no session is sent to the login page as a
navigation and handed the form as a swap, neither answer cacheable; and a
write passes only with this session's token, in the header or the form
field, never the query string, a header that is present deciding. The
session format itself is `test_session.mojo`'s.
"""

from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.cookie import RequestCookieJar
from lightbug_http.header import Header, Headers
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI

from src.form import form
from src.login import (
    CSRF_HEADER,
    LOGIN_TTL_DEFAULT,
    LOGIN_TTL_MAX,
    Login,
    SignIn,
    csrf_header,
    csrf_input,
    csrf_refusal,
    no_store,
    refuse_signed_out,
)
from src.reply import html
from src.session import session_refused

comptime KEY = "app-key-0123456789abcdef0123456789abcdef"
comptime OTHER_KEY = "app-other-fedcba9876543210fedcba9876543210"
comptime COOKIE = "app-session"


def _put(name: String, value: String):
    """`value` in the environment, or `name` removed from it when empty.

    Never `setenv` with an empty value: on the pinned toolchain an empty
    `String` that arrived as a default argument hands `setenv` a pointer
    to other bytes, and the variable read back as `Runtime`."""
    if value.byte_length() == 0:
        _ = unsetenv(name)
    else:
        _ = setenv(name, value, True)


def _env(key: String = KEY, password: String = "hunter2", prev: String = "", user: String = "",
         ttl: String = "", secure: String = "0"):
    """Every variable `from_env` reads, set; an empty one unset. `SECURE`
    is `0` unless a test says otherwise: it is required, and these run
    over no scheme at all."""
    _put("APP_KEY", key)
    _put("APP_PASSWORD", password)
    _put("APP_KEY_PREV", prev)
    _put("APP_USER", user)
    _put("APP_TTL", ttl)
    _put("APP_SECURE", secure)


def _refusal(cookie: String = COOKIE, default_ttl: Int = LOGIN_TTL_DEFAULT) -> String:
    try:
        _ = Login.from_env("APP", cookie, default_ttl=default_ttl)
    except e:
        return String(e)
    return String("")


def _login(key: String = KEY, prev: String = "", ttl: String = "", secure: String = "0") raises -> Login:
    _env(key=key, prev=prev, ttl=ttl, secure=secure)
    return Login.from_env("APP", COOKIE)


def _sign_in(login: Login) raises -> SignIn:
    var maybe = login.sign_in("admin", "hunter2")
    assert_true(Bool(maybe), "the right credentials were refused")
    return maybe.take()


def _value(line: String) -> String:
    """The cookie value out of a `Set-Cookie` line: after the first `=`,
    up to the first `;`."""
    var start = line.find("=") + 1
    var end = line.find(";")
    return String(unsafe_from_utf8=line.as_bytes()[start:end])


def _request(cookie: String = "", url: String = "http://127.0.0.1/items/1",
             method: String = "GET", body: String = "") raises -> HTTPRequest:
    var jar = RequestCookieJar()
    if cookie.byte_length() > 0:
        jar.add_pairs(cookie)
    var headers = Headers()
    if body.byte_length() > 0:
        headers = Headers(Header("Content-Type", "application/x-www-form-urlencoded"))
    return HTTPRequest(URI.parse(url), headers=headers^, cookies=jar^, method=method,
                       body=Bytes(body.as_bytes()))


def _with_header(name: String, value: String, url: String = "http://127.0.0.1/items/1",
                 body: String = "") raises -> HTTPRequest:
    var headers = Headers(Header(name, value))
    if body.byte_length() > 0:
        headers = Headers(
            Header(name, value), Header("Content-Type", "application/x-www-form-urlencoded")
        )
    return HTTPRequest(URI.parse(url), headers=headers^, method="POST", body=Bytes(body.as_bytes()))


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


def _header(resp: HTTPResponse, name: String) -> String:
    """`name`'s value, or empty when the response has none."""
    var v = resp.headers.get(name)
    if not v:
        return String("")
    return v.value()


def test_the_configuration_fails_closed_naming_the_variable() raises:
    """Every refusal names what to set, and nothing is served on a guess:
    no key, a key shorter than the hash, no password, a previous key
    shorter than the current must be, a TTL that is not 1 second to 400
    days, a `SECURE` that is neither `1` nor `0` (`true` read as off would
    send the cookie without `Secure`), a user name the cookie cannot carry.
    The cookie name and the default TTL are the application's own, refused
    the same way.

    covers: N43
    """
    _env(key="")
    assert_true("APP_KEY is not set" in _refusal(), _refusal())
    _env(key="0123456789abcdef0123456789abcde")
    assert_true("APP_KEY is 31 bytes and must be at least 32" in _refusal(), _refusal())
    _env(password="")
    assert_true("APP_PASSWORD is not set" in _refusal(), _refusal())
    _env(prev="too-short")
    assert_true("APP_KEY_PREV must be at least 32 bytes" in _refusal(), _refusal())
    for ttl in ["0", "-5", "an hour", "34560001", "99999999999999999999"]:
        _env(ttl=ttl)
        assert_true("APP_TTL must be a number of seconds from 1 to" in _refusal(), ttl)
    for secure in ["true", "yes", "on", "TRUE", "2"]:
        _env(secure=secure)
        assert_true("APP_SECURE must be 1" in _refusal(), secure)
    _env(user="two words")
    assert_true("APP_USER is not a name a session can carry" in _refusal(), _refusal())
    _env()
    assert_true("the cookie has no name" in _refusal(cookie=""))
    assert_true("is not a cookie name" in _refusal(cookie="a;b"))
    assert_true("default_ttl must be" in _refusal(default_ttl=0))
    assert_true("default_ttl must be" in _refusal(default_ttl=LOGIN_TTL_MAX + 1))
    assert_equal(_refusal(), "")


def test_the_configuration_reads_what_it_was_given() raises:
    """The optional variables, each read; an empty one is the default, which
    the application may name."""
    _env(prev=OTHER_KEY, user="reader", ttl="600", secure="1")
    var all = Login.from_env("APP", COOKIE)
    assert_equal(all.user, "reader")
    assert_equal(all.ttl, Int64(600))
    assert_true(all.secure)
    assert_equal(len(all.keys), 2)
    assert_equal(all.cookie, COOKIE)
    _env()
    var bare = Login.from_env("APP", COOKIE)
    assert_equal(bare.user, "admin")
    assert_equal(bare.ttl, Int64(LOGIN_TTL_DEFAULT))
    assert_false(bare.secure)
    assert_equal(len(bare.keys), 1)
    _env(secure="0")
    assert_false(Login.from_env("APP", COOKIE).secure)
    _env()
    var own = Login.from_env("APP", COOKIE, default_user="notes", default_ttl=43200)
    assert_equal(own.user, "notes")
    assert_equal(own.ttl, Int64(43200))


def test_secure_is_stated_never_assumed() raises:
    """Whether the cookie carries `Secure` is the deployment's to say, and
    the server cannot see the scheme a proxy terminated. So an unset
    `SECURE` is refused, naming both values, rather than read as off: off
    behind an HTTPS redirect sends the session in clear on a visitor's
    first `http://` request, and the cookie works until it expires. An
    empty value is unset. The configuration's other refusals come first, so
    a shell with nothing set still hears about the key.

    covers: N43
    """
    _env(secure="")
    var said = _refusal()
    assert_true("APP_SECURE is not set" in said, said)
    assert_true("1 when the application is served over HTTPS" in said, said)
    assert_true("0 over plain http" in said, said)
    _env(key="", secure="")
    assert_true("APP_KEY is not set" in _refusal(), _refusal())
    _env(secure="1")
    assert_true(Login.from_env("APP", COOKIE).secure)
    _env(secure="0")
    assert_false(Login.from_env("APP", COOKIE).secure)


def test_only_the_one_users_credentials_start_a_session() raises:
    """`sign_in` is the check and the session in one call: the wrong
    password, the wrong user, a prefix of the password and nothing at all
    are None; the right pair is a session naming the user, whose cookie
    line is the session format's own, `Secure` when configured.

    covers: N43
    """
    var login = _login(ttl="600")
    assert_true(login.accepts("admin", "hunter2"))
    for pair in [("admin", "hunter"), ("admin", "hunter22"), ("root", "hunter2"), ("", "")]:
        assert_false(login.accepts(pair[0], pair[1]), pair[0])
        assert_false(Bool(login.sign_in(pair[0], pair[1])), pair[0])
    var signed = _sign_in(login)
    assert_true(signed.session.ok, signed.session.reason)
    assert_equal(signed.session.subject, "admin")
    assert_equal(signed.session.csrf.byte_length(), 43)
    var resp = html("ok")
    signed.set_cookie(resp)
    assert_equal(len(resp.cookies.raw), 1)
    var line = resp.cookies.raw[0]
    assert_true(line.startswith("app-session=v1."), line)
    assert_true(line.endswith("; Path=/; HttpOnly; SameSite=Lax; Max-Age=600"), line)
    var secure = _sign_in(_login(secure="1"))
    var sresp = html("ok")
    secure.set_cookie(sresp)
    assert_true(sresp.cookies.raw[0].endswith("; Secure"), sresp.cookies.raw[0])


def test_a_session_reads_back_from_its_cookie_and_across_a_rotation() raises:
    """What `sign_in` set, `session_of` reads as the same user with the same
    token. A request with no cookie, or only another, is `no cookie`; a
    value with one byte changed is refused. After a rotation -- the old key
    moved to `APP_KEY_PREV` -- the session still reads; with the old key
    gone it does not, which is how every session under a key ends at once
    (D24).

    covers: N43
    """
    var login = _login()
    var signed = _sign_in(login)
    var resp = html("ok")
    signed.set_cookie(resp)
    var value = _value(resp.cookies.raw[0])
    var back = login.session_of(_request(String(COOKIE, "=", value)))
    assert_true(back.ok, back.reason)
    assert_equal(back.subject, "admin")
    assert_equal(back.csrf, signed.session.csrf)
    assert_equal(login.session_of(_request()).reason, "no cookie")
    assert_equal(login.session_of(_request(String("other=", value))).reason, "no cookie")
    var bent = String(unsafe_from_utf8=value.as_bytes()[: value.byte_length() - 1]) + (
        "A" if not value.endswith("A") else "B"
    )
    assert_false(login.session_of(_request(String(COOKIE, "=", bent))).ok)
    var rotated = _login(key=OTHER_KEY, prev=KEY)
    assert_true(rotated.session_of(_request(String(COOKIE, "=", value))).ok)
    var retired = _login(key=OTHER_KEY)
    assert_false(retired.session_of(_request(String(COOKIE, "=", value))).ok)


def test_sign_out_expires_the_cookie_in_the_client() raises:
    var login = _login()
    var resp = html("bye")
    login.sign_out(resp)
    assert_equal(
        resp.cookies.raw[0], "app-session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
    )


def test_a_signed_out_request_is_sent_to_the_login_page_or_handed_the_form() raises:
    """A navigation -- a history restore among them -- is a 303 to the login
    page, and a swap is a 401 carrying the form, so the login does not
    land inside the element the swap targeted. Both vary on the fragment
    headers and neither may be stored.

    covers: N43
    """
    var form_html = String('<form id="login"></form>')
    for nav in [("", ""), ("HX-Request-Type", "full")]:
        var req = _request() if nav[0] == "" else _with_header(nav[0], nav[1])
        var resp = refuse_signed_out(req, "/login", form_html)
        assert_equal(resp.status_code, 303, nav[1])
        assert_equal(_header(resp, "Location"), "/login")
        assert_equal(_header(resp, "Cache-Control"), "no-store")
        assert_true("HX-Request-Type" in _header(resp, "Vary"))
    for swap in [("HX-Request-Type", "partial"), ("HX-Request", "true"), ("Datastar-Request", "true")]:
        var resp = refuse_signed_out(_with_header(swap[0], swap[1]), "/login", form_html)
        assert_equal(resp.status_code, 401, swap[0])
        assert_equal(resp.status_text, "Unauthorized")
        assert_equal(_body(resp), form_html)
        assert_equal(_header(resp, "Cache-Control"), "no-store")
        assert_true("HX-Request" in _header(resp, "Vary"))
    assert_equal(_header(no_store(html("x")), "Cache-Control"), "no-store")


def test_a_write_passes_only_with_this_sessions_token() raises:
    """The header, in any case, or the form field; nothing else. A header
    that is present decides, so a wrong one is not rescued by a right
    field. A token in the query string is not read. Another session's
    token is refused, and a refused session refuses everything -- its
    empty token would otherwise match an empty field.

    covers: N43
    """
    var login = _login()
    var signed = _sign_in(login)
    var token = signed.session.csrf
    assert_false(Bool(csrf_refusal(_with_header(CSRF_HEADER, token), None, signed.session, "/x")))
    var lower = _with_header("x-csrf-token", token)
    assert_false(Bool(csrf_refusal(lower, form(lower), signed.session, "/x")))
    var field = _request(method="POST", body=String("csrf=", token))
    assert_false(Bool(csrf_refusal(field, form(field), signed.session, "/x")))

    var refusals = List[HTTPRequest]()
    refusals.append(_with_header(CSRF_HEADER, "wrong"))
    refusals.append(_with_header(CSRF_HEADER, "wrong", body=String("csrf=", token)))
    refusals.append(_request(method="POST", body="csrf=wrong"))
    refusals.append(_request(method="POST", body="title=no+token"))
    refusals.append(_request(url=String("http://127.0.0.1/items/1?csrf=", token), method="POST"))
    for i in range(len(refusals)):
        var refused = csrf_refusal(refusals[i], form(refusals[i]), signed.session, "/x")
        assert_true(Bool(refused), String(i))
        assert_equal(refused.value().status_code, 403)

    var other = _sign_in(_login(key=OTHER_KEY))
    assert_true(other.session.csrf != token)
    assert_true(Bool(csrf_refusal(_with_header(CSRF_HEADER, other.session.csrf), None, signed.session, "/x")))

    var nobody = session_refused(String("no cookie"))
    var empty = _request(method="POST", body="csrf=")
    var closed = csrf_refusal(empty, form(empty), nobody, "/x")
    assert_true(Bool(closed))
    assert_true("no session to hold a token" in _body(closed.value()))


def test_the_token_goes_in_a_hidden_field_or_a_header() raises:
    """The two places a page puts the token, each spelled once: a field for
    a write with a body, a header for one without."""
    assert_equal(csrf_input("tok"), '<input type="hidden" name="csrf" value="tok">')
    var h = csrf_header("tok")
    assert_equal(h.name, "X-CSRF-Token")
    assert_equal(h.value, "tok")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
