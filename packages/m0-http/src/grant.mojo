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
not satisfy. The key states are `HmacSha256` values prepared once per pool
thread (`GrantKeys.from_env`), so a verification costs the grant's own
bytes and one SHA-256 of the cookie -- a microsecond -- and allocates
nothing but the small strings it returns.

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
        for i in range(len(self.keys)):
            var have = self.keys[i].kid.as_bytes()
            if len(have) == len(kid):
                var same = True
                for j in range(len(kid)):
                    if have[j] != kid[j]:
                        same = False
                        break
                if same:
                    return i
        return -1


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
    var n = len(grant)
    if n < 20 or n > 400:
        return _refuse(String("malformed"))
    # Six fields, five dots.
    var dots = List[Int](capacity=5)
    for i in range(n):
        if grant[i] == UInt8(ord(".")):
            if len(dots) == 5:
                return _refuse(String("malformed"))
            dots.append(i)
    if len(dots) != 5:
        return _refuse(String("malformed"))
    var version = grant[0:dots[0]]
    var kid = grant[dots[0] + 1:dots[1]]
    var exp_field = grant[dots[1] + 1:dots[2]]
    var channel = grant[dots[2] + 1:dots[3]]
    var sb = grant[dots[3] + 1:dots[4]]
    var sig = grant[dots[4] + 1:n]
    var signed = grant[0:dots[4]]

    if len(version) != 2 or version[0] != UInt8(ord("v")) or version[1] != UInt8(ord("1")):
        return _refuse(String("malformed"))
    if len(kid) != GRANT_KID_CHARS:
        return _refuse(String("malformed"))
    if len(exp_field) < 1 or len(exp_field) > 12:
        return _refuse(String("malformed"))
    var exp = Int64(0)
    for b in exp_field:
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return _refuse(String("malformed"))
        exp = exp * 10 + Int64(b - UInt8(ord("0")))
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
    if len(sig) != GRANT_SIG_CHARS:
        return _refuse(String("malformed"))
    for b in sig:
        if not _is_b64url_byte(b):
            return _refuse(String("malformed"))

    var which = keys.find(kid)
    if which < 0:
        return _refuse(String("unknown key"))
    var expected = base64url(Span(keys.keys[which].mac.mac(signed)))
    if not constant_time_equal(Span(expected.as_bytes()), sig):
        return _refuse(String("bad signature"))
    if now >= exp:
        return _refuse(String("expired"))
    if bound:
        if not cookie:
            return _refuse(String("no session cookie"))
        var have = session_binding(Span(cookie.value().as_bytes()))
        if not constant_time_equal(Span(have.as_bytes()), sb):
            return _refuse(String("session mismatch"))
    return GrantVerdict(True, String(StringSpan(unsafe_from_utf8=channel)), String(""))
