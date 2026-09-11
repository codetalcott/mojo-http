"""Grants for a stream the server holds without asking Python again.

A hold view in Django decides, per request and with everything Django
knows, whether this connection may be held and which channel it joins. A
`--mount PREFIX=hold` moves the holding to a Mojo pool thread that never
touches the interpreter -- and takes the decision with it, as a **grant**
in the stream URL that the mount can verify alone:

    v1.<kid>.<exp>.<channel>.<sb>.<sig>

    kid      the first 8 hex characters of SHA-256(key): which key signed it
    exp      unix seconds after which it is refused
    channel  [A-Za-z0-9_:-]{1,64}; anything else is refused on both sides
    sb       session binding: base64url(SHA-256(session cookie value)[:16])
             without padding, or `-` for a grant bound to no session
    sig      base64url(HMAC-SHA256(key, "v1.<kid>.<exp>.<channel>.<sb>"))
             without padding

The key is the bytes of ``M0_GRANT_KEY``, one environment variable read by
this module when it issues and by the server when it verifies; they share
a process tree, so it is shared by construction. ``M0_GRANT_KEY_PREV``
lets a key rotate: the server accepts either, and `kid` says which. Thirty
two random bytes -- ``openssl rand -base64 32`` -- are enough.

Session binding is what makes a URL safe to hand a browser. An
`EventSource` cannot set a header, so the grant has to ride the URL, and
URLs leak (history, `Referer`, logs); bound to the session cookie's value
it is useless to anyone who copied it without also holding the cookie,
which the browser sends with the stream request on its own. Bind by
default; pass ``session=None`` only for a channel that is public anyway.

Revocation is bounded by ``ttl``: a member removed after a grant was
issued keeps reconnecting until it expires, and a stream already held is
not closed. One hour by default; a client that gets 401 asks Django for a
fresh URL, through the same view that issued the first.

Stdlib only, and no Django import, so a script can issue a grant too. The
copy in `apps/django_realtime` is byte-identical to the wheel's on
purpose; `check-docs` insists.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
import time
from urllib.parse import quote

VERSION = "v1"
KEY_ENV = "M0_GRANT_KEY"
PREV_KEY_ENV = "M0_GRANT_KEY_PREV"
DEFAULT_TTL = 3600
CHANNEL_RE = re.compile(r"^[A-Za-z0-9_:-]{1,64}$")
KID_CHARS = 8
UNBOUND = "-"


class GrantError(ValueError):
    """A grant could not be issued: no key, or a channel the format refuses."""


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def key_id(key: bytes) -> str:
    """Which key a grant was signed with: the first 8 hex of SHA-256(key)."""
    return hashlib.sha256(key).hexdigest()[:KID_CHARS]


def session_binding(session) -> str:
    """The `sb` field for a session cookie value, or `-` for none."""
    if session is None:
        return UNBOUND
    if isinstance(session, str):
        session = session.encode("utf-8")
    return _b64u(hashlib.sha256(session).digest()[:16])


def load_key(env=None, name: str = KEY_ENV) -> bytes:
    """The key from the environment, as bytes; raises `GrantError` if unset."""
    value = (os.environ if env is None else env).get(name, "")
    if not value:
        raise GrantError(
            f"{name} is not set; a hold mount cannot verify what nothing signed"
        )
    return value.encode("utf-8")


def issue(channel: str, *, session=None, ttl: int = DEFAULT_TTL, key: bytes | None = None,
          now: float | None = None) -> str:
    """A grant for `channel`, bound to `session` (a cookie value) unless None.

    `ttl` may be negative in a test that wants an expired grant. `key`
    defaults to ``M0_GRANT_KEY``.
    """
    if not CHANNEL_RE.match(channel or ""):
        raise GrantError(
            f"channel {channel!r} is not [A-Za-z0-9_:-]{{1,64}}; the grant "
            "format refuses it, and so would the server"
        )
    if key is None:
        key = load_key()
    exp = int((time.time() if now is None else now) + ttl)
    signed = ".".join((VERSION, key_id(key), str(exp), channel, session_binding(session)))
    sig = _b64u(hmac.new(key, signed.encode("ascii"), hashlib.sha256).digest())
    return signed + "." + sig


def stream_url(prefix: str, channel: str, **kwargs) -> str:
    """`/<prefix>/stream?g=<grant>`: what a template puts in an `EventSource`."""
    return prefix.rstrip("/") + "/stream?g=" + quote(issue(channel, **kwargs), safe="-_.:")
