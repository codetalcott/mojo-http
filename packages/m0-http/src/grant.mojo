"""Verify a stream grant: the Mojo side of `m0serve.grant`.

A `--mount PREFIX=hold` holds an SSE stream on a pool thread that never
touches Python, so the decision a Django hold view makes -- may this
connection be held, and on which channel -- has to reach that thread
without Django. It travels in the stream URL as a grant the Python side
issued (`packaging/m0serve/src/m0serve/grant.py`, whose docstring is the
format's definition), and this module is the only reader:

    v1.<kid>.<exp>.<channel>.<sb>.<sig>

Verification is a pure function of the grant, the keys, the clock and the
session cookie, in that order of refusal: malformed, an unknown key, a bad
signature (constant time), expired, then a session binding the cookie does
not satisfy. All but the last are the signed envelope's, `SignedToken`,
which `session.mojo` reads its cookie with too. The key states are
`HmacSha256` values prepared once per pool thread (`GrantKeys.from_env`),
so a verification costs the grant's own bytes and one SHA-256 of the
cookie -- a microsecond -- and allocates nothing but the small strings it
returns.

Every field is read as bytes and never sliced with a codepoint-checked
slice: the grant is request-derived, and SPEC G14 is why.
"""

from std.base64 import b64encode
from std.os import getenv

from m0_core import HmacSha256, sha256, hex_digest, constant_time_equal


comptime GRANT_VERSION = "v1"
comptime GRANT_KEY_ENV = "M0_GRANT_KEY"
comptime GRANT_PREV_KEY_ENV = "M0_GRANT_KEY_PREV"
comptime GRANT_COOKIE_ENV = "M0_GRANT_COOKIE"
comptime GRANT_COOKIE_DEFAULT = "sessionid"
comptime GRANT_KID_CHARS = 8
comptime GRANT_CHANNEL_MAX = 64
comptime GRANT_SIG_CHARS = 43
"""Length of the tag field: base64url of 32 bytes without padding."""
comptime GRANT_SB_CHARS = 22
"""Length of the session-binding field: base64url of 16 bytes without padding."""
comptime TOKEN_EXP_DIGITS = 12
"""The most digits of expiry a signed token carries, grant or session: Unix
seconds to the year 33658."""
comptime TOKEN_MAX = 400
"""The longest token either verifier reads; anything longer is malformed."""


def base64url(data: Span[UInt8, _]) -> String:
    """Encodes `data` as base64url (RFC 4648 §5) without padding, via the stdlib's encoder."""
    var std = b64encode(data)
    var out = List[UInt8](capacity=std.byte_length())
    for ch in std.as_bytes():
        if ch == UInt8(ord("+")):
            out.append(UInt8(ord("-")))
        elif ch == UInt8(ord("/")):
            out.append(UInt8(ord("_")))
        elif ch == UInt8(ord("=")):
            break
        else:
            out.append(ch)
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def grant_key_id(key: Span[UInt8, _]) -> String:
    """The `kid` of a key: the first 8 hex characters of its SHA-256."""
    var full = hex_digest(Span(sha256(key)))
    return String(StringSpan(unsafe_from_utf8=Span(full.as_bytes())[0:GRANT_KID_CHARS]))


def session_binding(cookie_value: Span[UInt8, _]) -> String:
    """The `sb` field a cookie value binds to: base64url of SHA-256's first 16 bytes."""
    var digest = sha256(cookie_value)
    return base64url(Span(digest)[0:16])


struct GrantKey(Copyable, Movable):
    """One key the mount accepts: its id, and its HMAC state prepared once."""

    var kid: String
    var mac: HmacSha256

    def __init__(out self, key: Span[UInt8, _]):
        self.kid = grant_key_id(key)
        self.mac = HmacSha256(key)

    def __init__(out self, *, copy: Self):
        self.kid = copy.kid
        self.mac = copy.mac.copy()

    def __init__(out self, *, deinit move: Self):
        self.kid = move.kid^
        self.mac = move.mac^


def find_key(keys: List[GrantKey], kid: Span[UInt8, _]) -> Int:
    """The index of the key in `keys` whose id is `kid`, or -1.

    A free function rather than a method because `session.mojo` asks the
    same question of its own ring, and a second copy of this loop would be
    a second place for the key-id rule to drift. Not constant time and
    does not need to be: a key id is public, and the tag compare that
    follows is what must not leak.
    """
    for i in range(len(keys)):
        var have = keys[i].kid.as_bytes()
        if len(have) == len(kid):
            var same = True
            for j in range(len(kid)):
                if have[j] != kid[j]:
                    same = False
                    break
            if same:
                return i
    return -1


struct GrantKeys(Movable):
    """What a hold mount verifies against: its keys, and the cookie it binds to."""

    var keys: List[GrantKey]
    var cookie: String
    """The session cookie's name (`M0_GRANT_COOKIE`, default `sessionid`)."""

    def __init__(out self, cookie: String = String(GRANT_COOKIE_DEFAULT)):
        self.keys = List[GrantKey]()
        self.cookie = cookie

    def __init__(out self, *, deinit move: Self):
        self.keys = move.keys^
        self.cookie = move.cookie^

    def add(mut self, key: Span[UInt8, _]):
        self.keys.append(GrantKey(key))

    @staticmethod
    def from_env() -> Self:
        """`M0_GRANT_KEY`, then `M0_GRANT_KEY_PREV` if set; empty when neither is.

        An empty key set verifies nothing -- every grant is refused -- and
        `m0serve` refuses to start a hold mount without the first variable,
        so a running mount always has at least one.
        """
        var out = Self(getenv(GRANT_COOKIE_ENV, GRANT_COOKIE_DEFAULT))
        var current = getenv(GRANT_KEY_ENV, "")
        if current.byte_length() > 0:
            out.add(Span(current.as_bytes()))
        var previous = getenv(GRANT_PREV_KEY_ENV, "")
        if previous.byte_length() > 0:
            out.add(Span(previous.as_bytes()))
        return out^

    def find(self, kid: Span[UInt8, _]) -> Int:
        return find_key(self.keys, kid)


struct GrantVerdict(Movable):
    """`ok` with the channel, or a `reason`: `malformed`, `unknown key`,
    `bad signature`, `expired`, `no session cookie`, `session mismatch`."""

    var ok: Bool
    var channel: String
    var reason: String

    def __init__(out self, ok: Bool, var channel: String, var reason: String):
        self.ok = ok
        self.channel = channel^
        self.reason = reason^


def _refuse(reason: String) -> GrantVerdict:
    return GrantVerdict(False, String(""), reason)


def _is_channel_byte(b: UInt8) -> Bool:
    return (
        (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("_"))
        or b == UInt8(ord(":"))
        or b == UInt8(ord("-"))
    )


def _is_b64url_byte(b: UInt8) -> Bool:
    return (
        (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("-"))
        or b == UInt8(ord("_"))
    )


struct SignedToken(Movable):
    """A signed token's envelope, read: `v1.<kid>.<exp>.` in front, `.<tag>`
    last, and the tag base64url of an HMAC-SHA256 over everything before it.

    A grant (`v1.<kid>.<exp>.<channel>.<sb>.<tag>`) and a session cookie
    (`v1.<kid>.<exp>.<subject>.<tag>`, `session.mojo`) are this envelope
    around fields of their own, and each verifier carried a copy of it until
    2026-09-28. So is the order of refusal: malformed, an unknown key, a bad
    signature, expired -- the signature BEFORE the expiry, so a token nobody
    signed is never reported as merely old. A format reads its own fields
    between the constructor and `check`, which keeps every malformed refusal
    ahead of the key lookup.
    """

    var dots: List[Int]
    """Where each `.` is: field i runs from `start(i)` to `end(i)`."""
    var length: Int
    var exp: Int64
    """The expiry field, read: Unix seconds."""
    var key: Int
    """The index of the key whose tag matched, once `check` has passed;
    -1 before."""
    var well_formed: Bool
    """Whether the envelope held: the length, exactly `fields` fields, `v1`,
    an 8-character key id, 1 to `TOKEN_EXP_DIGITS` digits of expiry, and a
    43-character base64url tag. False is `malformed`."""

    def __init__(out self, token: Span[UInt8, _], fields: Int, min_length: Int):
        self.dots = List[Int](capacity=fields - 1)
        self.length = len(token)
        self.exp = 0
        self.key = -1
        self.well_formed = False
        var n = len(token)
        if n < min_length or n > TOKEN_MAX:
            return
        for i in range(n):
            if token[i] == UInt8(ord(".")):
                if len(self.dots) == fields - 1:
                    return
                self.dots.append(i)
        if len(self.dots) != fields - 1:
            return
        var version = token[0 : self.dots[0]]
        if (
            len(version) != 2
            or version[0] != UInt8(ord("v"))
            or version[1] != UInt8(ord("1"))
        ):
            return
        if self.end(1) - self.start(1) != GRANT_KID_CHARS:
            return
        var exp_field = token[self.start(2) : self.end(2)]
        if len(exp_field) < 1 or len(exp_field) > TOKEN_EXP_DIGITS:
            return
        var exp = Int64(0)
        for b in exp_field:
            if b < UInt8(ord("0")) or b > UInt8(ord("9")):
                return
            exp = exp * 10 + Int64(b - UInt8(ord("0")))
        var tag = token[self.start(fields - 1) : n]
        if len(tag) != GRANT_SIG_CHARS:
            return
        for b in tag:
            if not _is_b64url_byte(b):
                return
        self.exp = exp
        self.well_formed = True

    def start(self, field: Int) -> Int:
        """Where field `field` begins."""
        return 0 if field == 0 else self.dots[field - 1] + 1

    def end(self, field: Int) -> Int:
        """Where field `field` ends: its dot, or the end of the token."""
        return self.dots[field] if field < len(self.dots) else self.length

    def check(
        mut self, token: Span[UInt8, _], keys: List[GrantKey], now: Int64
    ) -> String:
        """Why a well-formed `token` is refused -- `unknown key`, `bad
        signature`, `expired`, in that order -- or empty when it is not, and
        `key` then names the key that signed it. The tag is compared in
        constant time; the expiry is against the clock the caller gives."""
        var last = len(self.dots)
        var which = find_key(keys, token[self.start(1) : self.end(1)])
        if which < 0:
            return String("unknown key")
        var signed = token[0 : self.dots[last - 1]]
        var tag = token[self.start(last) : self.length]
        var expected = base64url(Span(keys[which].mac.mac(signed)))
        if not constant_time_equal(Span(expected.as_bytes()), tag):
            return String("bad signature")
        if now >= self.exp:
            return String("expired")
        self.key = which
        return String("")


def verify_grant(
    grant: Span[UInt8, _],
    keys: GrantKeys,
    now: Int64,
    cookie: Optional[String],
) -> GrantVerdict:
    """Whether `grant` admits a hold now, for a client presenting `cookie`.

    `cookie` is the session cookie's value, or None when the request has
    none; a grant whose `sb` is `-` ignores it, any other `sb` requires it.
    """
    # Six fields, five dots; the envelope is `SignedToken`'s to read.
    var token = SignedToken(grant, 6, 20)
    if not token.well_formed:
        return _refuse(String("malformed"))
    var channel = grant[token.start(3) : token.end(3)]
    var sb = grant[token.start(4) : token.end(4)]
    if len(channel) < 1 or len(channel) > GRANT_CHANNEL_MAX:
        return _refuse(String("malformed"))
    for b in channel:
        if not _is_channel_byte(b):
            return _refuse(String("malformed"))
    var bound = not (len(sb) == 1 and sb[0] == UInt8(ord("-")))
    if bound:
        if len(sb) != GRANT_SB_CHARS:
            return _refuse(String("malformed"))
        for b in sb:
            if not _is_b64url_byte(b):
                return _refuse(String("malformed"))

    var refused = token.check(grant, keys.keys, now)
    if refused:
        return _refuse(refused)
    if bound:
        if not cookie:
            return _refuse(String("no session cookie"))
        var have = session_binding(Span(cookie.value().as_bytes()))
        if not constant_time_equal(Span(have.as_bytes()), sb):
            return _refuse(String("session mismatch"))
    return GrantVerdict(True, String(StringSpan(unsafe_from_utf8=channel)), String(""))
