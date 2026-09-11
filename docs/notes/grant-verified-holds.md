# Grant-verified holds — shipped 2026-09-11

> A design note from the engineering record: what a Python application
> needs to put its streams on a Mojo pool thread without a Mojo build of
> its own, and the format that carries its decision there.

**Where this comes from.** [An SSE hold from a Mojo mount](hold-from-a-mojo-mount.md)
proved the mechanism: a `MojoPool` thread takes an `M0-Hold` the way a
WSGI pool thread does, and the loop drains it. It also found that the
application this was for, textshelf, authorizes every stream before naming
its channel — a session and a membership query — and that a Mojo view has
neither. The recommendation was to move the holding, not the deciding: a
built-in mount that holds against a grant the application signed, so the
application keeps its views and its ORM and hands the browser a URL. This
is that mount, and the grant.

## The grant

```
v1.<kid>.<exp>.<channel>.<sb>.<sig>

kid      the first 8 hex characters of SHA-256(key)
exp      unix seconds
channel  [A-Za-z0-9_:-]{1,64}
sb       base64url(SHA-256(session cookie value)[:16]) without padding, or -
sig      base64url(HMAC-SHA256(key, "v1.<kid>.<exp>.<channel>.<sb>")) without padding
```

`m0serve.grant` issues it (`issue`, `stream_url`) and
`m0_http.grant.verify_grant` reads it; the wheel's copy and
`apps/django_realtime/grant.py` are byte-identical, and `check-docs`
insists, because each runs where the other is not installed. The key is
the bytes of `M0_GRANT_KEY`, read by the issuer and by the mount; they
share a process tree, so it is shared by construction. `M0_GRANT_KEY_PREV`
is accepted while set, and `kid` says which key signed — a fingerprint,
not a configured index, so neither side has to agree on an order.

Verification refuses in this order: malformed, unknown key, bad signature,
expired, no session cookie, session mismatch. The signature is checked
before the expiry, so an expired grant with a wrong tag is `invalid` and
not `expired`; the mount answers 401 with `expired` (fetch a fresh URL) or
`invalid` (stop) and the reason. The reason names nothing an attacker
could not learn by trying.

## What the design is for

**Performance.** No Python on the connect path, and nothing allocated but
the small strings a verdict returns. A pool thread prepares its
`HmacSha256` states when its handler is built, so a verification costs the
grant's own bytes plus one block, and one SHA-256 of the cookie; every
field is read as bytes and never through a codepoint-checked slice, since
the grant is request-derived (SPEC G14). The hold that follows is the one
[the previous note](hold-from-a-mojo-mount.md) measured: a head answered
in a twentieth of a second behind two busy Python threads.

**Session binding** is what makes a URL safe to hand a browser. An
`EventSource` cannot set a header, so the grant rides the URL, and URLs
leak — history, `Referer`, logs. Bound to the session cookie's value, a
copied URL is useless without the cookie, which the browser sends with the
stream request on its own. The issuer binds by default and takes
`session=None` only for a channel that is public anyway. m0serve's access
log records the path and never the query, so the grant does not land in
the log; that is now load-bearing.

**Revocation** is bounded by the TTL, one hour by default. A member
removed after a grant was issued keeps reconnecting until it expires, and
a stream already held is not closed — nothing on the server closes a hold
from the application side yet, which is D23's retiring condition. A
client that gets `expired` asks the application for a fresh URL through
the same view that issued the first, which is the same authorization
again.

**Rotation** is the key list: set `M0_GRANT_KEY_PREV` to the old key, the
new one in `M0_GRANT_KEY`, restart, and grants signed under either verify
until the previous is unset.

**Fail closed.** A hold mount refuses to start without `--realtime` (what
wires a pool thread's hold to the loop) or without `M0_GRANT_KEY`, exit 2,
and `--doctor` reports the same two checks. The issuer raises without a
key rather than signing with an empty one, and refuses a channel the
format cannot carry before the server has to.

## Rejected

- **Verifying Django's own signer.** `django.core.signing` would spare
  the application a helper, at the cost of reimplementing its salted key
  derivation and base62 timestamps in Mojo and coupling the binary to
  Django's `SECRET_KEY` handling. A dedicated key and a five-field format
  is less to get wrong, and works for Flask.
- **The session cookie alone.** The mount has no session store; a cookie
  proves nothing to it without the binding a grant carries.
- **Opaque server-side grants.** A store the loop consults, or bus frames
  announcing issuance per worker, is state with consistency problems the
  signed form does not have.
- **The grant in a header.** `EventSource` cannot send one.

## The gate

`smoke-hold-mount`, every pull request: the two startup refusals and the
doctor agreeing; a bound grant admitting its own session and a publish
from Django reaching the stream with its id; each refusal by name; a grant
under the previous key admitted while it is listed; an unbound grant with
no cookie; the issuer refusing a bad channel; the slot released. The
verifier's unit form is `test_grant.mojo`, eight cases against grants the
issuer signed with a fixed key and clock, so what Django signs and what
the mount admits are pinned to each other across the language boundary.
The primitive underneath is `m0-core`'s SHA-256 and HMAC (SPEC G15),
gated by the FIPS and RFC 4231 vectors.

## What is not claimed

No timing measurement of the verifier; it is a few SHA-256 blocks, and
the number that matters is the hold's, already recorded. The mount is not
proven with an ASGI application beside it — `--realtime` still needs a
WSGI mount, as the previous note records. And the application layer's
soak is still NOT MET: this is the server holding for textshelf, not
textshelf written on `Views` and `Fragment`; that application is still to
be chosen.
