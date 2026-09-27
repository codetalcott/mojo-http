# A login in the layer — 2026-09-27

A design note from the engineering record. SPEC N43–N45 are the rows,
D53 the decision; D38 and D44 retire.

## The question

`apps/fragment_notes` wrote its login by hand on 2026-09-12
([a-login-on-the-notes-app](a-login-on-the-notes-app.md)): the
configuration read from the environment and refused when incomplete, the
credentials compared as digests, a session read from its cookie, a guard
answering 303 to a navigation and 401 with the form to a swap, a CSRF check
reading the header before the field and failing closed, the token's two
spellings, and `no-store` on every answer the session chose. About 150
lines, all of them in the application.

The first application outside this repository, `unotes`, copied them with
the names changed (its SOAK_LOG, 2026-09-21). Set side by side, the two
copies differ in three places: the default user's name, the default TTL
(an hour, and twelve hours), and the key's length, which `unotes` refuses
under 32 bytes and `fragment_notes` does not check. Everything else is the
same code, much of it under the same comments.

Two decisions named that second copy as their trigger. D38 kept a request
header out of the layer until a second application needed one on a swap;
D44 kept the scaffold sessionless until the soak's login was the second one
written by hand. Both made the helper and an `auth` template the next step.

## What was built

**`m0_http.login`** (N43) is the glue, lifted. The two differences in
taste became arguments (`default_user`, `default_ttl`), and the one the
copies disagreed on became the stricter rule: a key shorter than the hash
is refused. `from_env` also refuses what the copies accepted and then
failed on later: a user name the cookie cannot carry (at start, rather
than at the first sign-in), a TTL above 400 days (no browser keeps a
cookie longer, and an expiry past the format's twelve digits raised inside
the login view), a previous key shorter than the current one, and a cookie
name that is not a token. The separate-session review found one more:
`PREFIX_SECURE` read anything but `1` as off, so `true` behind HTTPS sent
the session cookie without `Secure` and said nothing. It is `1` or `0`
now, and anything else is refused by name.

Two changes of shape, each for a reason:

- `sign_in(user, password)` is the credential check and the session in one
  call, returning None for anything but the one user's pair. Both copies
  called `accepts` and then `issue_session`, and the order was the view's
  to get right. It still returns in two steps, `.session` and
  `set_cookie(resp)`, because both copies need that: a sign-in answered by
  a swap renders the page behind it, and the page needs the token before
  the response exists.
- `refuse_signed_out` takes no page shell. Only its swap branch reads the
  login form, and that branch answers a bare fragment, so the shell both
  copies passed to `page_or_fragment` was never called.

**A request header on a swap** (N44). `header=RequestHeader(name, value)`
on `swap` and `el` writes the swap, then the push, then
`Vocabulary.request_header`. `Htmx` spells it `hx-headers`, the name and
the value written as JSON strings inside the attribute's HTML escaping.
It is the attribute `fragment_notes` types by hand, and what
`csrf_header(token)` hands a DELETE, since htmx 4 sends a DELETE's fields
in the query string. The trait's default refuses, as `push_url`'s does.
`Datastar` refuses by name: Datastar puts a header in an option inside the
action expression, which `swap` writes whole, so spelling one would mean
spelling the action a second time, and no Datastar application has asked.
A Datastar write carries its token in a field.

The layer checks the header before any vocabulary sees it: a name that is
not an RFC 9110 token, a control byte in the value, and a byte outside
ASCII. The last is not the grammar's rule but the browser's, which sends a
header value as Latin-1: UTF-8 written into `hx-headers` arrives as other
bytes, and a token compared with them fails for no visible reason.

**`m0 new --template auth`** (N45) is the `views` list behind the login.
The closed set grows by a value, as D44 says it must, and not by a
`--login` flag. The template follows the rules that `fragment_notes` paid
for and the scaffold's AGENTS.md already stated. The login and the logout
are plain forms answered with a 303, because a swap would leave the
address bar at `/login`. The POST carries its token as a field and the
DELETE as a header. A test fills its own cookie jar.

One rule is new. `main` reads the configuration BEFORE `serve` and exits
78 on the error. The host's `--doctor` reaches no `make`, so a
configuration refused only in `make` passes the doctor and then fails the
run. `m0 new` prints the `export` that sets both variables, so the first
thing a new project does is not read that refusal.

## The reference moves onto it

The first draft of this change left `apps/fragment_notes` on its
hand-written glue, on the grounds that moving it proved nothing new. Both
halves of that were wrong.

The layer's process is that the reference application is refactored onto
each new piece under the gate that already holds it. A second copy of
security glue in one repository is also the trap this codebase names: a
fix to one copy is not a fix to the other.

And the move does prove something. `smoke-fragment-notes` checks the login
against sessions and forgeries that a CPython issuer signed
(`scripts/notes_session.py`), and `browser-notes-login` submits the delete
form from Chromium under htmx 4.0.0. Before the move, both gates checked
the application's copy. After it, they check `m0_http.login` and the
layer's `hx-headers`.

The wire did not move: `smoke-fragment-notes` passed unchanged. Two things
did:

- The key must be at least 32 bytes, the module's rule, and
  `serve-fragment-notes`' development default is lengthened to meet it.
  The smoke's own key was exactly 32 bytes already.
- `hx-headers` comes after the swap's attributes on the delete form rather
  than before them, because the layer writes it after the swap. The smoke
  finds the form by its class and the attribute anywhere in it.

`sabotage-notes-login`'s three CSRF arms now revert `login.mojo` rather
than the application. A new arm removes the `request_header` call from
`html.mojo`, and the smoke catches it. The harness rebuilds `m0_http` when
either file moves.

## What was not changed

- `unotes` keeps its copy until it moves, which is its own decision.
- There is no session store, no password KDF and no second user: D24 and
  D25 stand, and D53's retiring condition is where either would come back.
- `views` and `live` stay sessionless. Their AGENTS.md section now names
  the module and the template, where it used to name the notes app's
  source in another repository.

## Found on the way

On the pinned toolchain, `setenv(name, value, True)` with an EMPTY
`String` that arrived as a default argument stores other bytes: `Runtime`
in one run, `]` in another. The empty value's pointer is not
NUL-terminated there. An empty `String()`, `String("")` or a string built
at run time is stored correctly. `test_login.mojo` unsets a variable
rather than setting it empty. No `setenv` call in the tree passes a
default argument through.
