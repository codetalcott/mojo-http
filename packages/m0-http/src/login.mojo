"""One user behind a signed session: the login `apps/fragment_notes` wrote
by hand, and that the first application outside this repository copied
with its names changed (its SOAK_LOG, 2026-09-21). DECISIONS D53; SPEC
N43.

`session.mojo` is the format, a stateless signed cookie and the CSRF token
derived from it. This is what an application built around that format,
the same way both times:

- `Login.from_env(prefix, cookie)` reads the configuration. `PREFIX_KEY`
  (at least `LOGIN_KEY_MIN` bytes) and `PREFIX_PASSWORD` are required;
  `PREFIX_KEY_PREV`, `PREFIX_USER`, `PREFIX_TTL` and `PREFIX_SECURE`
  (`1` or `0`) are optional. It fails closed: anything it cannot serve
  raises, naming the variable, and a host `make` turns that into exit 78
  before anything is served.
- `sign_in(user, password)` is a session for the one user, or None: the
  credential check and the session are one call. What it returns is the
  session a page rendered behind it reads (`.session`, the CSRF token
  included) and `set_cookie(resp)`, two steps because an answer to a
  sign-in may render that page, which needs the token before the response
  exists.
- `session_of(req)` is the request's session, or the reason it has none,
  and `sign_out(resp)` ends one in the client.
- `refuse_signed_out` answers a request with no session: a 303 to the
  login page for a navigation, a 401 carrying the login form for a swap.
- `csrf_refusal` answers 403 unless a write carries this session's token,
  in the `X-CSRF-Token` header or the form's `csrf` field, never in the
  query string.
- `csrf_input(token)` and `csrf_header(token)` are the two places a page
  puts the token: a hidden field, and a header for a swap that sends no
  body.
- `no_store(resp)` marks an answer the session chose as not cacheable.

What it is not: a user table, a password hash or a session store (D24 and
D25 stand). It holds one identity, with its secret in the environment.
"""

from std.os import getenv

from lightbug_http.header import HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.http.date import unix_now

from m0_core import constant_time_equal, sha256

from .form import Form
from .fragment import vary_on_fragment_headers, wants_fragment
from .html import RequestHeader, _is_tchar, attr, void
from .reply import html, param_int, problem, reason_phrase, redirect
from .session import (
    SessionKeys,
    SessionVerdict,
    issue_session,
    session_cookie_line,
    session_refused,
    verify_session,
)


comptime LOGIN_KEY_MIN = 32
"""The shortest session key `from_env` accepts, in bytes: the key is an
HMAC-SHA256 key, and one shorter than the hash is easier to guess than
the tag is to forge."""
comptime LOGIN_TTL_DEFAULT = 3600
"""How long a session lasts when neither the application nor `PREFIX_TTL`
says: an hour."""
comptime LOGIN_TTL_MAX = 34560000
"""400 days: the longest a browser keeps a cookie (RFC 6265bis caps
`Max-Age` there), so a longer session could only outlive its cookie."""
comptime CSRF_FIELD = "csrf"
"""The form field a write carries its token in."""
comptime CSRF_HEADER = "X-CSRF-Token"
"""The header a write with no body carries its token in."""


struct SignIn(Movable):
    """A session just signed for the one user. `session` is what a page
    rendered behind it reads -- the subject and the CSRF token -- and
    `set_cookie(resp)` hands the session to the client."""

    var session: SessionVerdict
    var _line: String

    def __init__(out self, var session: SessionVerdict, var line: String):
        self.session = session^
        self._line = line^

    def set_cookie(self, mut resp: HTTPResponse):
        """Put the session's `Set-Cookie` on `resp`."""
        resp.cookies.add_raw(self._line)


struct Login(Movable):
    """The one user, and what a session of theirs is signed with.

    The password is kept as a SHA-256 digest so the compare is over two
    fixed-length byte strings: `constant_time_equal` reads all of both
    whatever the first mismatch, which a compare of raw passwords of
    different lengths cannot. It is NOT a password hash: there is no salt
    and no work factor, because there is nothing at rest to steal -- the
    secret lives in the environment of the process that checks it (D25).
    """

    var user: String
    var password_digest: List[UInt8]
    var keys: SessionKeys
    var ttl: Int64
    var secure: Bool
    var cookie: String

    def __init__(
        out self,
        var user: String,
        password: String,
        var keys: SessionKeys,
        ttl: Int64,
        secure: Bool,
        var cookie: String,
    ):
        self.user = user^
        self.password_digest = sha256(Span(password.as_bytes()))
        self.keys = keys^
        self.ttl = ttl
        self.secure = secure
        self.cookie = cookie^

    @staticmethod
    def from_env(
        prefix: String,
        var cookie: String,
        default_user: String = "admin",
        default_ttl: Int = LOGIN_TTL_DEFAULT,
    ) raises -> Self:
        """The configuration under `prefix`, or an error naming what cannot
        be served.

        Fail closed: an application that quietly served everyone because a
        deployment forgot a variable is worse than one that did not start.
        A user name the cookie cannot carry is refused here too, rather
        than at the first sign-in, and so is a cookie name that is not a
        token -- that one is the application's own mistake.
        """
        if cookie.byte_length() == 0:
            raise Error("Login.from_env: the cookie has no name")
        for b in cookie.as_bytes():
            if not _is_tchar(b):
                raise Error(String(
                    "Login.from_env: '", cookie, "' is not a cookie name ",
                    "(letters, digits and !#$%&'*+-.^_`|~ alone)",
                ))
        if default_ttl <= 0 or default_ttl > LOGIN_TTL_MAX:
            raise Error(String(
                "Login.from_env: default_ttl must be from 1 to ", LOGIN_TTL_MAX,
                " seconds",
            ))
        var key_env = String(prefix, "_KEY")
        var key = getenv(key_env, "")
        if key.byte_length() == 0:
            raise Error(String(key_env, " is not set: it signs the session cookie"))
        if key.byte_length() < LOGIN_KEY_MIN:
            raise Error(String(
                key_env, " is ", key.byte_length(), " bytes and must be at least ",
                LOGIN_KEY_MIN, " (`openssl rand -hex 32` makes one)",
            ))
        var password_env = String(prefix, "_PASSWORD")
        var password = getenv(password_env, "")
        if password.byte_length() == 0:
            raise Error(String(password_env, " is not set: it is the one user's password"))
        var keys = SessionKeys()
        keys.add(Span(key.as_bytes()))
        var previous_env = String(prefix, "_KEY_PREV")
        var previous = getenv(previous_env, "")
        if previous.byte_length() > 0:
            if previous.byte_length() < LOGIN_KEY_MIN:
                raise Error(String(
                    previous_env, " must be at least ", LOGIN_KEY_MIN, " bytes, as ",
                    key_env, " must",
                ))
            keys.add(Span(previous.as_bytes()))
        var ttl = Int64(default_ttl)
        var ttl_env = String(prefix, "_TTL")
        var ttl_text = getenv(ttl_env, "")
        if ttl_text.byte_length() > 0:
            var parsed = param_int(ttl_text)
            if parsed <= 0 or parsed > LOGIN_TTL_MAX:
                raise Error(String(
                    ttl_env, " must be a number of seconds from 1 to ", LOGIN_TTL_MAX,
                    " (400 days, the longest a browser keeps a cookie)",
                ))
            ttl = Int64(parsed)
        # `1` or `0`, and nothing else: `true` read as off would send the
        # session cookie without `Secure` behind HTTPS and say nothing.
        var secure_env = String(prefix, "_SECURE")
        var secure = getenv(secure_env, "")
        if secure != "" and secure != "0" and secure != "1":
            raise Error(String(
                secure_env, " must be 1 (the deployment is HTTPS, so the cookie ",
                "carries Secure) or 0, and '", secure, "' is neither",
            ))
        var user = getenv(String(prefix, "_USER"), "")
        if user.byte_length() == 0:
            user = default_user
        try:
            _ = issue_session(keys, user, Int64(0))
        except:
            raise Error(String(
                prefix, "_USER is not a name a session can carry: 1 to 64 of ",
                "letters, digits and _-:@",
            ))
        return Self(user^, password, keys^, ttl, secure == "1", cookie^)

    def accepts(self, user: String, password: String) -> Bool:
        """Whether these are the one user's credentials. Both compares are
        over digests, so neither the password nor the name leaks its
        length or its first differing byte."""
        var want_user = sha256(Span(self.user.as_bytes()))
        var have_user = sha256(Span(user.as_bytes()))
        var have_pass = sha256(Span(password.as_bytes()))
        var user_ok = constant_time_equal(Span(want_user), Span(have_user))
        var pass_ok = constant_time_equal(Span(self.password_digest), Span(have_pass))
        return user_ok and pass_ok

    def sign_in(self, user: String, password: String) raises -> Optional[SignIn]:
        """A session for the one user if these are their credentials, and
        None if they are not. The check and the session are one call, so a
        view cannot start a session without the check."""
        if not self.accepts(user, password):
            return None
        var now = unix_now()
        var value = issue_session(self.keys, self.user, now + self.ttl)
        return SignIn(
            verify_session(Span(value.as_bytes()), self.keys, now),
            session_cookie_line(self.cookie, value, self.ttl, self.secure),
        )

    def session_of(self, req: HTTPRequest) -> SessionVerdict:
        """The request's session, or the reason it has none: `no cookie`,
        or one of `verify_session`'s."""
        var raw = req.cookies.get(self.cookie)
        if not raw:
            return session_refused(String("no cookie"))
        return verify_session(Span(raw.value().as_bytes()), self.keys, unix_now())

    def sign_out(self, mut resp: HTTPResponse):
        """End the session in the client: the cookie, empty, with `Max-Age=0`.
        A copy of the old value still verifies until its own expiry; that is
        the stateless cookie's bargain (D24)."""
        resp.cookies.add_raw(
            session_cookie_line(self.cookie, String(""), Int64(0), self.secure)
        )


def no_store(var resp: HTTPResponse) -> HTTPResponse:
    """`Cache-Control: no-store` on an answer a session chose.

    The list with its token, the 303 to the login page and the 401 form are
    all chosen by the cookie, and `Vary` names only the fragment headers. A
    shared cache in front would otherwise hand the anonymous redirect to a
    signed-in user, or a rendered token to anyone. It is `no-store` rather
    than `Vary: Cookie`, because a private page is not one to keep at all.
    """
    resp.headers[HeaderKey.CACHE_CONTROL] = "no-store"
    return resp^


def refuse_signed_out(
    req: HTTPRequest, login_url: String, login_form: String
) -> HTTPResponse:
    """What a request with no usable session gets, neither answer
    cacheable.

    A navigation is sent to `login_url` with a 303, which is what a browser
    address bar needs. A swap gets 401 carrying `login_form` as a bare
    fragment, because a redirect that a swap follows would put the login
    page inside the element the view was in, with no way back. Only the
    swap reads `login_form`.
    """
    if wants_fragment(req):
        var resp = html(login_form)
        resp.status_code = 401
        resp.status_text = reason_phrase(401)
        return no_store(vary_on_fragment_headers(resp^))
    return no_store(vary_on_fragment_headers(redirect(303, login_url)))


def _token_matches(verdict: SessionVerdict, got: String) -> Bool:
    return constant_time_equal(Span(verdict.csrf.as_bytes()), Span(got.as_bytes()))


def csrf_refusal(
    req: HTTPRequest, body: Optional[Form], verdict: SessionVerdict, instance: String
) -> Optional[HTTPResponse]:
    """403 unless the request carries THIS session's token: in the
    `X-CSRF-Token` header, or in the body's `csrf` field. Never the query
    string -- nothing here reads it, so a token that reached the URL is a
    403 rather than a quiet acceptance.

    A header that is present decides: a wrong one is not rescued by a
    right field, so a request cannot offer two tokens and pass on either.
    A header is also the stronger of the two, since a page on another
    origin cannot set one without a preflight this server never answers.
    `SameSite=Lax` on the cookie keeps it off every cross-site write, so
    what this catches is the same-site forgery: another tab, another
    session's token, a form replayed after a new sign-in.

    It fails closed on a verdict that is not ok. A refused session carries
    an empty token, and two empty strings compare equal, so without this a
    write view that forgot its session guard would accept `csrf=` from
    anyone.
    """
    if not verdict.ok:
        return problem(403, String("Forbidden"), String("no session to hold a token"), instance)
    var sent = req.headers.get(CSRF_HEADER)
    if sent:
        if _token_matches(verdict, sent.value()):
            return None
    elif body:
        var got = body.value().get(CSRF_FIELD)
        if got:
            if _token_matches(verdict, got.value()):
                return None
    return problem(
        403,
        String("Forbidden"),
        String("the request did not carry this session's CSRF token"),
        instance,
    )


def csrf_input(token: String) raises -> String:
    """The token as a hidden form field, for a write that sends a body."""
    return void(
        "input", attr("type", "hidden") + attr("name", CSRF_FIELD) + attr("value", token)
    )


def csrf_header(token: String) -> RequestHeader:
    """The token as a request header, for a swap that sends no body:
    `f.el("form", "delete", url, ..., header=csrf_header(token))`.

    htmx 4 sends a DELETE's fields in the query string, with no setting to
    change it, and a token in a URL is a token in the access log, the
    `Referer` and the history. `Htmx` writes it as `hx-headers`, and
    `Datastar` refuses one."""
    return RequestHeader(CSRF_HEADER, token)
