# A login on the notes app — shipped 2026-09-12

> A design note from the engineering record. The fifth phase of the
> application layer's plan: the row the layer had left, and the decision
> it retires.

**Where this comes from.** Decision D15 said no sessions and no CSRF, and
named the reason: `wyhash64` is a hash, not a MAC, so nothing the
framework could sign was worth signing. The primitive landed ahead of the
login — `m0_core.hmac`, HMAC-SHA256 against the seven RFC 4231 vectors —
because the hold mount needed it first (SPEC G15, I21). This is the piece
that was waiting for it, and the last `planned` row in section N.

**The shape.** One user, from the environment. `M0_NOTES_KEY` signs,
`M0_NOTES_PASSWORD` is the secret, `M0_NOTES_USER` names the identity and
defaults to `notes`, `M0_NOTES_TTL` bounds a session, `M0_NOTES_KEY_PREV`
carries a rotation, and `M0_NOTES_SECURE=1` states a fact the server
cannot observe. Without the first two the app prints which one is missing
and exits 78, the code the hold mount refuses with. A demo that quietly
served everyone because a deployment forgot a variable would be worse
than one that did not start, so the refusal is a gated claim and not a
comment.

The session is a cookie and nothing else:

```
v1.<kid>.<exp>.<subject>.<tag>
```

`kid` is the first eight hex characters of the key's SHA-256, `exp` is
Unix seconds, `subject` is the identity, and `tag` is base64url of
HMAC-SHA256 over everything before it. It is the grant's shape
(`grant.mojo`, I21) with the channel and the session binding replaced by
a subject, which is not a coincidence: the two are the same primitive,
they now share a key ring (`find_key`), and having written the second one
is what makes that visible.

Verification refuses in a fixed order — malformed, unknown key, bad
signature, expired — and the signature is checked BEFORE the expiry on
purpose: an expired cookie nobody signed must not come back as merely
expired, because "merely expired" is a thing an application might decide
to forgive. Every field is walked as bytes; the cookie is request-derived
and SPEC G14 is why.

**CSRF costs no state.** The token is `HMAC(key, "m0csrf1." || tag)`: a
MAC over the session's own tag, under the same key. It needs nothing
remembered, it dies with the session, and a token minted for one cookie
verifies under no other — the unit test asserts exactly that against two
sessions. The prefix is domain separation: a CSRF token is a MAC over a
message no session cookie's signed part can be, so neither value can ever
be replayed as the other.

**The guard is an early return**, which is all D3 leaves. A private view
opens with `_session(req, store)` and returns `_refuse(req, session)` when
it is not ok; a write adds `_csrf_refusal(form(req), session, path)`. There
is no middleware, no decorator and no per-route flag saying which views are
private, on purpose: a table that carried it would be a second place to
forget, and the line that reads the state is where the question belongs.

A navigation with no session gets 303 to the login page; a swap gets 401
carrying the login form as the same fragment the list occupies, because a
redirect a swap followed would put the login page inside the element the
list was in with no way back. Both answers are chosen by the fragment
headers, so both carry `Vary` naming all four — which is what
`vary_on_fragment_headers` is now exported for. htmx 2.0.4 does not swap a
401 by default, so a session that expires mid-interaction shows nothing
until the page is reloaded; making it swap is `htmx.config.responseHandling`,
a vocabulary-specific setting the app deliberately does not spell.

## What the round found

**htmx 2.0.4 puts a DELETE's fields in the query string.** Its
`methodsThatUseUrlParams` ships as `["get","delete"]`, so the obvious
shape — a hidden `csrf` field in the form the delete button sits in —
would have sent the token in the URL, where it lands in the access log,
the `Referer` and the browser history. The app narrows the setting to
`get` in one `<meta name="htmx-config">` in the shell, and the server
reads the token from the body and from nowhere else. The smoke asserts
both halves: the meta is in the page, and a DELETE carrying a correct
token in the query string is answered 403 with the note intact. That
second assertion is what keeps the meta from being decorative.

This is the one library setting the app makes, and it is in the shell
rather than on an element because it is about the transport and not about
a fragment — beside the `<script>` tag that is already the only
htmx-specific thing in that function.

Neither of those assertions can say whether the BUNDLE honoured the meta,
which is why there is a browser run. `poe browser-notes-login`
(pre-release) opens the app in Chromium, signs in, adds a note, deletes
it and signs out. What the pinned bundle sent, verbatim:

```
create (POST): POST /notes  content-type 'application/x-www-form-urlencoded'
  body 'csrf=usffgYLb…&title=buy%20milk&body='
delete (DELETE): DELETE /notes/1  content-type 'application/x-www-form-urlencoded'
  body 'csrf=usffgYLb…'
```

With the meta replaced by an unrelated setting, the same run records what
htmx does by default and why it matters:

```
delete (DELETE): DELETE /notes/1?csrf=usffgYLb…  content-type 'application/x-www-form-urlencoded'
  body ''
```

— and the note is still in the list, because the server read the body and
found nothing. That is the whole failure mode: a token in the URL, a
delete button that 403s on every click, and a suite that stays green.

**A sabotage suite can test a tree nobody has.** The first run of
`scripts/notes_login_sabotage.py` reported all five rules guarded, and two
of them were guarded by the wrong assertion: the script rebuilt `m0-http`
when it applied a sabotage to `session.mojo` but not when it restored it,
so the two later app-side arms ran against a `.mojoc` still holding the
previous sabotage. It now records the text the artifact was built from and
rebuilds whenever the file has moved, in either direction — and prints the
assertion that caught each sabotage, read as the line before the smoke's
`=== fragment.log ===` marker, so a sabotage caught by the wrong
assertion is visible rather than merely counted.

**A login is a navigation.** The sign-in and sign-out forms are the only
forms here that are not swaps: `f.el` generates an attribute that replaces
this fragment, and replacing the fragment on a sign-in would leave the
address bar on `/login` with the notes inside it, so a reload, a bookmark
or the back button would each land somewhere the user did not just come
from. They are plain `<form method="post">` elements and the browser
follows the 303. Everything that genuinely swaps — create, delete, a note's
link — still spells nothing itself.

## What is deliberately not here

**No session store (D24).** The cookie is stateless, so logout expires it
in the CLIENT and a client that kept the value could use it until its own
expiry. Revocation is the TTL and the key ring: dropping a key ends every
session signed under it at once, which is what the `_PREV` list makes
survivable. The gate says which of the two it asserts — the jar is what
honours the expiry — rather than claiming a revocation that is not there.

**No password KDF and no user table (D25).** The password is compared as
a SHA-256 digest so the compare is over two fixed-length byte strings,
which is what `constant_time_equal` needs; it is not a password hash, and
there is nothing at rest to steal, because the secret lives in the
environment of the process that checks it. A second user, or a password
stored anywhere, is what would make a KDF the right answer.

**No CSRF on the login itself.** There is no session yet to derive a
token from. What that leaves is login CSRF — a third party submitting
THEIR credentials to log a visitor into their account — which a
pre-session token answers and which, on one user, is the account the
visitor was going to log into anyway.

## The gate

`smoke-fragment-notes` (every pull request) grew the login and kept every
assertion it already made, now behind the session; the notes app's wire
contract did not otherwise move. The N13 arms:

- the refusal to start, twice: no key, then no password, each exiting 78
  and naming the variable;
- unauthenticated — the page, the fragment, a write, and a note that does
  not exist, which must 303 before the lookup so an anonymous request
  cannot learn whether a note is there;
- the login — wrong password, wrong user, then the right ones, with the
  cookie's four attributes and its shape on the wire asserted;
- the forgeries, each signed by `scripts/notes_session.py`: a cookie
  CPython signed under the server's key is ADMITTED, and an expired one,
  one under another key, one with a flipped tag character and one that is
  not a token at all are each refused by NAME;
- CSRF — no token, another session's token, and a correct token in the
  query string, each 403 with the write not having happened;
- the tokens agreeing across the two implementations: the string the app
  renders into the form is the string CPython derives from the cookie;
- G14 on the cookie, a continuation byte in the subject, over a socket;
- logout, both ways: with the token it expires the cookie and the next
  request is refused, without it nothing happens.

`test_session.mojo` is the unit form, fourteen cases against vectors
`scripts/notes_session.py --vectors` printed. The issuer exists so the
verifier is never checked against itself: what the other implementation
signs, this one must admit, and the CSRF derivation is in the table for
the same reason — a derivation only ever checked against itself can drift
until a form stops submitting.

`poe sabotage-notes-login` (pre-release) reverts five rules one at a time
and insists the smoke goes red for each: the tag check, the expiry, the
CSRF guard, the session guard on a private view, and the cookie's
`HttpOnly`/`SameSite`. Four of the five leave every other assertion in
the smoke passing, which is why each needs its own arm.

`poe browser-notes-login` (pre-release) is the browser arm above. Both
were checked against their own null case: every sabotage names the
assertion that caught it, and the browser run was re-run with the meta
reverted to see it fail for the reason it claims.

## The lift

Written in the app first and moved once the gate was green, which is the
process the last two rounds used. `m0_http.session` holds the format, the
verifier, the CSRF derivation and the cookie line; the app keeps the
policy — who the user is, what the cookie is called, how long a session
lasts, which views are private, what a refusal looks like. The smoke did
not move across the lift, which is the whole point of gating on the wire.

D15 is retired. Section N has no `planned` rows left, and what stands
between the application layer and its milestone is the soak: an
application outside `apps/` running on `Views` and `Fragment`.
