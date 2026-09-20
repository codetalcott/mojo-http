# The layer moves to htmx 4

2026-09-19. `Fragment[Htmx]`, `page_or_fragment` and `apps/fragment_notes`
were gated against htmx 2.0.4, provisionally (DECISIONS D6: "moving the
pin" was the retiring condition, and what would weigh was written down
with it). This is the move: the built-in vocabulary is htmx 4, the notes
app loads 4.0.0, and its gates — wire, browser and sabotage — were re-run
against it. SPEC N22 is the new row; N8, N13 and N21 were re-worded; D6 is
retired and D38 is new.

Every fact below was read out of the 4.0.0 bundle (`dist/htmx.js`, from
npm's `next` tag; `latest` is still 2.0.10) and then watched in Chromium.
None is from memory or from the migration guide.

## What htmx 4 changed that the layer can see

| | htmx 2.0.4 | htmx 4.0.0 |
|---|---|---|
| asks for a fragment with | `HX-Request: true`, minus the restore and boost markers | `HX-Request-Type: partial` or `full`, on every request |
| a history restore sends | `HX-Request` and `HX-History-Restore-Request` | `HX-History-Restore-Request` and `HX-Request-Type: full` — and no `HX-Request` |
| a DELETE's form fields | in the query string, unless `methodsThatUseUrlParams` is narrowed | in the query string, hard-coded (`/GET\|DELETE/.test(method)`) |
| a GET or DELETE from inside a form | includes the enclosing form | includes a form only when the element IS the form |
| a 4xx answer | not swapped | swapped (`noSwap` is 204 and 304) |
| attribute inheritance | implicit | explicit (`implicitInheritance: false`) |
| default swap | `outerHTML` was never the default either | `innerHTML` |
| verbs | five | six: `query` |

## The decision: the new header decides, the old rule stays

The brief for this round named one condition under which to stop: a
page-versus-fragment signal that cannot be made right for htmx 2 and
htmx 4 at once. It did not arise, and the reason is worth a sentence,
because it is the whole design: **the two majors are told apart by a
header only one of them sends.**

`wants_fragment` now reads, in order:

1. `Datastar-Request: true` — a fragment.
2. `HX-Request-Type: partial` — a fragment. `HX-Request-Type: full` — a
   page. Nothing else htmx sent is consulted.
3. Otherwise the htmx 2 rule, unchanged: `HX-Request: true` with neither
   `HX-History-Restore-Request: true` nor `HX-Boosted: true` beside it.

A value of `HX-Request-Type` that is neither word falls through to rule 3
rather than being guessed at.

Rule 2 *decides* rather than advises because there is one place where the
two majors send the same older headers and need different answers. A
boosted element that names its own `hx-target` sends, under htmx 4,
`HX-Boosted: true` beside `HX-Request-Type: partial` — and means it. Given
a whole document, htmx 4's `makeFragment` appends the parsed `<body>`
ELEMENT to the fragment it swaps, which is not what a section's
`outerHTML` swap wants. Under htmx 2 the same `HX-Boosted: true` is
answered a page, which htmx 2 unwraps. Reading the boost marker first
would be wrong for htmx 4; ignoring it would be wrong for htmx 2; keying
on the header's presence is right for both.

The v4 history restore is the other case the old rule got right by
accident. The restore's `request` option replaces htmx's header object
whole, so the request carries no `HX-Request` at all and the old rule
answered a page because *nothing asked for a fragment*. It now answers a
page because the request said `full`.

`Vary` gains `HX-Request-Type` as a fifth name, last, so the four an older
cache already keyed on keep their order. This is the one change visible on
the wire to an application that did nothing: every `page_or_fragment`
answer's `Vary` is one name longer.

## The vocabulary: three attributes, unchanged, and a sixth verb

`Htmx.swap` writes `hx-VERB`, `hx-target` and `hx-swap="outerHTML"` on the
element, exactly as before — byte for byte, which `test_html.mojo` and the
notes gate pin. That was the bet D6 recorded ("the generator is the only
thing that knows the spelling") and it paid in full: all three attributes
sit on the element itself, so explicit inheritance takes nothing away, and
the new `innerHTML` default is never consulted because the swap style is
always spelled.

`Htmx.verbs()` now answers htmx 4's six, so `f.el("button", "query", url,
...)` renders `hx-query`. `Datastar` stays on the default five.

`outerMorph` was considered for the built-in spelling and left alone. It
is htmx 4's morph-by-id and arguably what a fragment that names itself
wants, but it changes what every existing app's swap does to focus and
form state, and nothing in the tree asked. `poe check-app-vocabulary`
keeps building an `outerMorph` vocabulary from outside the repository, so
the door D34 opened stays gated; that vocabulary now differs from the
built-in one in the swap style alone.

## The CSRF token on a DELETE is a header

Under 2.0.4 the notes app narrowed `methodsThatUseUrlParams` to `get` in a
`<meta name="htmx-config">`, so its delete form's hidden `csrf` field rode
the body. htmx 4 has no such setting. A DELETE's fields go in the URL —
where a token is an access-log entry, a `Referer` and a history entry —
and nothing on the page can change that.

So the delete form holds **no field**, and carries
`hx-headers='{"X-CSRF-Token":"…"}'` instead, on the form itself because
inheritance is explicit. The server accepts the token from the
`X-CSRF-Token` header or from the body's `csrf` field, and from nowhere
else; a header that is present decides, so a wrong header is not rescued
by a right field beside it. A POST still carries the field — its fields go
in the body under both majors, and a plain `<form method="post">` (the
sign-out) has no other way. The meta is gone, and the smoke asserts its
absence: left behind, it would read as a protection and be none.

A custom header is also the stronger carrier. A cross-origin page cannot
set one without a CORS preflight, which this server never answers.

**`hx-headers` is the one `hx-` attribute the app writes by hand**
(`_csrf_header`), and that is DECISIONS D38. The layer spells swaps. A
request header is a different thing in each library — an attribute beside
the swap in htmx, an option *inside* the action expression in Datastar
(`@delete('/x', {headers: {...}})`), which `Vocabulary.swap` has no
argument for — and one application is not evidence of what the shared
shape should be. The retiring condition is the usual one: a second app
hand-rolling it.

## What only the browser could say

`poe browser-notes-login` (pre-release; Chromium through Playwright) was
rewritten around what fails silently under htmx 4, and each arm was made
to fail before it was believed:

- the create form's POST says `HX-Request-Type: partial` — the header the
  layer now decides by has to actually be sent;
- the DELETE carries `X-CSRF-Token`, has no `csrf` in its query, and says
  `partial`. Reverting `hx-headers` on the form: 403, caught. Putting the
  field back in the form: `DELETE /notes/1?csrf=…`, caught;
- a session that ends mid-interaction: the cookie is dropped, a note is
  added, and the 401's login fragment appears inside `#notes` with the
  address bar unmoved. Under the 2.0.4 bundle nothing appears, caught —
  along with both request-type arms, since 2.0.4 sends no such header.

One finding for applications, recorded here because the notes app shows
it: **htmx 4 swaps every 4xx.** The delete arm used to wait for the note
to leave the list; with the token reverted the note "left" anyway, because
the 403's `application/problem+json` body had replaced the whole fragment.
The check now reads the DELETE's status. An application moving to htmx 4
should expect its error answers to be swapped in, and answer errors a
person might see as fragments — as the notes app's 401 already did, which
is why that one became correct without an edit.

## The gates

- `test_fragment.mojo`: four new tests — the header is taken at its word
  in both directions and either case, the v4 restore shape with no
  `HX-Request`, the boosted `partial` where the two rules differ, and an
  unknown value falling through. Every `Vary` assertion names five.
- `smoke-fragment-notes` (every PR): the same four shapes on the wire; the
  shell loads 4.0.0 by exact URL and carries no `htmx-config`; the delete
  form carries this session's token as `hx-headers` and the list holds
  exactly two `csrf` fields (create and sign-out); a DELETE with the
  token in its query, with none, with another session's as a header, and
  with a wrong header beside a right field are each 403 and leave the
  note.
- `poe sabotage-notes-login` (pre-release): fourteen rules, ten of them
  new or re-pointed for this move, including both `HX-Request-Type`
  branches and the fifth `Vary` name, which rebuild `m0-http` on the way
  in and on the way out. A sabotage that does not build used to be
  skipped; it is now a failure, since a rule nobody reverted is a rule
  nobody showed to be guarded.

## Not done

- **`hx-boost` and history in an app of ours.** The notes app uses
  neither, so the v4 restore and boost shapes are gated as request shapes
  (curl and unit tests, from headers measured in Chromium on 2026-09-15)
  rather than by clicking Back in a browser. The first app that pushes
  URLs should extend the browser check.
- **SRI on the CDN tag.** Not there under 2.0.4 either; the scaffold's
  template is where it belongs (Phase 6, R3).
- **`fx-*`.** D6 deferred it beside htmx 4 and its retirement does not
  revive it: `Vocabulary` is open (D34), so a house library is an
  application's own conformance, not a third built-in.
