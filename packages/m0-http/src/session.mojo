"""A signed session cookie and the CSRF token it stands for.

The framework layer's answer to "who is this request", and the piece D15
said would come after an HMAC: `wyhash64` is not a MAC, so nothing here
was buildable until `m0_core.hmac` existed. What it is NOT is a session
framework — there is no store, no backend, no `request.session` dict and
no login machinery. There is a format, a verifier, and one derivation:

    v1.<kid>.<exp>.<subject>.<tag>

`kid` is the first eight hex characters of the key's SHA-256, `exp` is
Unix seconds, `subject` is whatever the application calls the identity,
and `tag` is base64url (no padding) of HMAC-SHA256 over everything
before it. Verification is a pure function of the cookie, the keys and
the clock, in that order of refusal: malformed, an unknown key, a bad
signature (constant time), expired. Nothing is looked up, so a request
costs one SHA-256 of its own cookie and allocates the two small strings
it returns.

The cookie is **stateless**, and every consequence of that is the
application's to accept: a session cannot be revoked before its `exp`,
two devices holding the same value are one session, and signing a
subject is not the same as having issued it. What bounds the damage is
the TTL and the key — a rotation invalidates every cookie under the
retired key at once, which is what `M0_*_KEY_PREV`-style key lists make
survivable. An application that needs revocation needs a store, and that
is a different module.

**CSRF costs no state either.** `csrf_token` is a MAC over the session's
own tag under the same key, so the token a form carries is derived from
the cookie that form was rendered for and verifies under no other; it
dies with the session and needs nothing remembered. The prefix keeps it
out of the cookie's own message space, so neither value can ever be
replayed as the other. `SameSite=Lax` on the cookie is the other half:
it keeps the cookie off every cross-site write, leaving the token to
answer the same-site forgery.

Emission is a LINE, not a `Cookie`: `session_cookie_line` builds what
goes on the wire and the caller hands it to `ResponseCookieJar.add_raw`.
Round-tripping it through the parsed path drops `expires`, `SameSite`,
everything after the first `=` in a value, and any attribute the struct
does not model — the `response_cookie_jar.mojo` docstring measured all
four against Django.

Every field is read as bytes and never sliced with a codepoint-checked
slice: a cookie is request-derived, and SPEC G14 is why.

The key ring is `grant.mojo`'s. A `GrantKey` is a key id and an
`HmacSha256` absorbed once, which is exactly what a session key is, and
a second copy of those lines would be a second place for the key-id rule
to drift. `apps/fragment_notes` is the worked application.
"""

from m0_core import HmacSha256, constant_time_equal

from .grant import GrantKey, base64url, find_key


comptime SESSION_VERSION = "v1"
comptime SESSION_KID_CHARS = 8
comptime SESSION_SIG_CHARS = 43
"""Length of the tag field: base64url of 32 bytes without padding."""
comptime SESSION_SUBJECT_MAX = 64
comptime CSRF_MESSAGE_PREFIX = "m0csrf1."
"""Domain separation: a CSRF token is a MAC over a message no session
cookie's signed part can be, so neither can be replayed as the other."""


struct SessionKeys(Movable, Sized):
    """The keys a session cookie may be signed by: the current one first,
    then any the application still accepts while a rotation completes.

    Issuing always uses the first. A cookie names its key by `kid`, so a
    rotation is "put the new key first, keep the old one in the list until
    the longest TTL has passed, then drop it" — and dropping it is what
    invalidates every session under it.
    """

    var keys: List[GrantKey]

    def __init__(out self):
        self.keys = List[GrantKey]()

    def __init__(out self, *, deinit move: Self):
        self.keys = move.keys^

    def __len__(self) -> Int:
        return len(self.keys)

    def add(mut self, key: Span[UInt8, _]):
        """Append a key, preparing its HMAC state once."""
        self.keys.append(GrantKey(key))

    def find(self, kid: Span[UInt8, _]) -> Int:
        """The index of the key whose id is `kid`, or -1."""
        return find_key(self.keys, kid)


struct SessionVerdict(Movable):
    """`ok` with the subject and the CSRF token the session stands for, or
    a `reason`: `malformed`, `unknown key`, `bad signature`, `expired`.

    The reason is the server's own classification of a cookie it was
    given, and is safe to show — it says which check failed, never
    anything about the key or the correct value.
    """

    var ok: Bool
    var subject: String
    var csrf: String
    var reason: String

    def __init__(
        out self, ok: Bool, var subject: String, var csrf: String, var reason: String
    ):
        self.ok = ok
        self.subject = subject^
        self.csrf = csrf^
        self.reason = reason^


def session_refused(var reason: String) -> SessionVerdict:
    """A refusal naming `reason`. What an application returns for the case
    this module cannot see — a request with no cookie at all."""
    return SessionVerdict(False, String(""), String(""), reason^)


def _is_subject_byte(b: UInt8) -> Bool:
    """What a subject may hold: not `.`, which is the field separator, and
    nothing a `Set-Cookie` value may not carry (RFC 6265 §4.1.1)."""
    return (
        (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("_"))
        or b == UInt8(ord("-"))
        or b == UInt8(ord(":"))
        or b == UInt8(ord("@"))
    )


def _is_b64url_byte(b: UInt8) -> Bool:
    return (
        (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("-"))
        or b == UInt8(ord("_"))
    )


def csrf_token(mac: HmacSha256, tag: Span[UInt8, _]) -> String:
    """The CSRF token a session tag stands for.

    Args:
        mac: The key the session was signed under.
        tag: The session cookie's tag field, as bytes.

    Returns:
        43 base64url characters, to be carried as a hidden form field and
        compared with `constant_time_equal`.
    """
    var message = List[UInt8](capacity=len(tag) + 8)
    message.extend(String(CSRF_MESSAGE_PREFIX).as_bytes())
    message.extend(tag)
    return base64url(Span(mac.mac(Span(message))))


def issue_session(keys: SessionKeys, subject: String, exp: Int64) raises -> String:
    """Sign a session for `subject` expiring at `exp`, under the CURRENT key.

    Args:
        keys: The ring; the first key signs.
        subject: The identity, in the byte set a cookie value may carry.
        exp: Unix seconds after which `verify_session` refuses it.

    Returns:
        The cookie VALUE, for `session_cookie_line`.

    Raises:
        If the ring is empty, or the subject is empty, too long, or holds
        a byte the format cannot carry — each of which would otherwise
        produce a cookie that reads back as `malformed`.
    """
    if len(keys) == 0:
        raise Error("issue_session: no key")
    var bytes = subject.as_bytes()
    if len(bytes) == 0 or len(bytes) > SESSION_SUBJECT_MAX:
        raise Error("issue_session: subject length")
    for b in bytes:
        if not _is_subject_byte(b):
            raise Error("issue_session: subject byte")
    var signed = String(SESSION_VERSION, ".", keys.keys[0].kid, ".", exp, ".", subject)
    var tag = base64url(Span(keys.keys[0].mac.mac(Span(signed.as_bytes()))))
    return String(signed, ".", tag)


def verify_session(
    cookie: Span[UInt8, _], keys: SessionKeys, now: Int64
) -> SessionVerdict:
    """Whether `cookie` is a session this server signed that is still in date.

    Args:
        cookie: The cookie value as it arrived, unparsed.
        keys: The ring to verify against; an empty one refuses everything.
        now: The clock, in Unix seconds.

    Returns:
        The subject and its CSRF token, or the reason for the refusal:
        `malformed`, `unknown key`, `bad signature`, `expired`, in that
        order — the signature is checked before the expiry so an expired
        cookie nobody signed is not reported as merely expired.
    """
    var n = len(cookie)
    if n < 16 or n > 400:
        return session_refused(String("malformed"))
    # Five fields, four dots.
    var dots = List[Int](capacity=4)
    for i in range(n):
        if cookie[i] == UInt8(ord(".")):
            if len(dots) == 4:
                return session_refused(String("malformed"))
            dots.append(i)
    if len(dots) != 4:
        return session_refused(String("malformed"))
    var version = cookie[0 : dots[0]]
    var kid = cookie[dots[0] + 1 : dots[1]]
    var exp_field = cookie[dots[1] + 1 : dots[2]]
    var subject = cookie[dots[2] + 1 : dots[3]]
    var sig = cookie[dots[3] + 1 : n]
    var signed = cookie[0 : dots[3]]

    if (
        len(version) != 2
        or version[0] != UInt8(ord("v"))
        or version[1] != UInt8(ord("1"))
    ):
        return session_refused(String("malformed"))
    if len(kid) != SESSION_KID_CHARS:
        return session_refused(String("malformed"))
    if len(exp_field) < 1 or len(exp_field) > 12:
        return session_refused(String("malformed"))
    var exp = Int64(0)
    for b in exp_field:
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return session_refused(String("malformed"))
        exp = exp * 10 + Int64(b - UInt8(ord("0")))
    if len(subject) < 1 or len(subject) > SESSION_SUBJECT_MAX:
        return session_refused(String("malformed"))
    for b in subject:
        if not _is_subject_byte(b):
            return session_refused(String("malformed"))
    if len(sig) != SESSION_SIG_CHARS:
        return session_refused(String("malformed"))
    for b in sig:
        if not _is_b64url_byte(b):
            return session_refused(String("malformed"))

    var which = keys.find(kid)
    if which < 0:
        return session_refused(String("unknown key"))
    var expected = base64url(Span(keys.keys[which].mac.mac(signed)))
    if not constant_time_equal(Span(expected.as_bytes()), sig):
        return session_refused(String("bad signature"))
    if now >= exp:
        return session_refused(String("expired"))
    return SessionVerdict(
        True,
        String(StringSpan(unsafe_from_utf8=subject)),
        csrf_token(keys.keys[which].mac, sig),
        String(""),
    )


def session_cookie_line(
    name: String, value: String, max_age: Int64, secure: Bool = False
) -> String:
    """One `Set-Cookie` line, for `ResponseCookieJar.add_raw`.

    Built as the line that goes on the wire rather than as a `Cookie` the
    jar re-serialises, because that path is lossy by four attributes —
    `response_cookie_jar.mojo` measured every one against Django.

    `HttpOnly` keeps the value out of scripts, `SameSite=Lax` keeps it off
    every cross-site write, and `Path=/` scopes it to the application.
    `Secure` is a deployment fact the server cannot observe — `REMOTE_ADDR`
    is the socket peer and the scheme is configuration — so the caller
    states it. `max_age` of 0 is how a session is ended in the client.

    Args:
        name: The cookie's name.
        value: What `issue_session` returned, or empty to expire it.
        max_age: Seconds the client should keep it; 0 expires it now.
        secure: Whether to add `Secure` (the deployment is HTTPS).

    Returns:
        The header value.
    """
    var line = String(
        name, "=", value, "; Path=/; HttpOnly; SameSite=Lax; Max-Age=", max_age
    )
    if secure:
        line += "; Secure"
    return line
