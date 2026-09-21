# A swap that moves the address bar

2026-09-21. The first application outside `apps/` on the layer — `unotes`,
a reader over a private notes corpus, the application-layer soak — has a
filter form and a list of links, all of them swaps. Its log's third
finding: a filter that swaps without changing the URL cannot be reloaded,
bookmarked or sent to anyone, and for a research tool that is the feature.
The scaffold's `AGENTS.md` says never to type an `hx-` swap attribute by
hand; that app typed one, `hx-push-url="true"`, on every link and on the
form. This is the lift. SPEC N37 is the row and D46 the decision.

## What was built

`push=True` on the three places a swap is written — `Fragment.swap`,
`Fragment.el` and `Html.swap[V]` — and one defaulted method on
`Vocabulary`:

```mojo
f.el("a", "get", url, attr("href", url), text(title), push=True)
```

`_swap[V]`, the one function every swap goes through, writes the swap and
then calls `V.push_url(h)` on the same open element. `Htmx` answers with
`hx-push-url="true"`. The trait's default REFUSES, so a conformance an
application wrote before today still compiles and raises if it is asked
for a push it has no spelling for.

## Two refusals

**Only a `get` is pushed**, and the check is the layer's, beside the verb
check, so no conformance can forget it. A pushed URL is one the browser
GETs on reload, from a bookmark and on a history restore. Pushing a
`post`'s URL writes an address that answers 405, or one that answers.
htmx 4's `query` is refused with the writes: its parameters travel in the
body, so its URL alone does not name the view.

**`Datastar` refuses a push.** Datastar's free bundle was read for it and
names neither `pushState`, `replaceState` nor `popstate`: it has no history
handling of any kind. Re-read at v1.0.4 (2026-09-21) with the same result,
and the reason is now visible: the two attributes that would spell one,
`data-replace-url` and `data-query-string`, are **Pro** features. So the
condition that would retire this is a pricing decision, not a release. The only spelling would be a `history.pushState(...)`
appended to the action expression, and nothing would answer the back
button — the address would change back and the page would not. The note on
the one swap mode argues the same way from the other side: a parameter on
`swap` is a promise both vocabularies keep or one of them breaks silently.
Here the break would not be silent if it raises, so it raises, and the
error names the way out (a plain link, for a view that needs an address).
The refusal is a raise and not a no-op because the failure this piece
exists to stop is exactly a filter that quietly stopped being linkable.

## The other half was already there

A pushed address is only real if asking for it rebuilds the view. htmx 4
re-requests a pushed URL on back and forward with `HX-Request-Type: full`
and no `HX-Request`, and `page_or_fragment` has answered that as a
document since N22. So the push needed nothing from the server. The wire
gate asserts both halves together anyway: `smoke-fragment-notes` reads
`hx-push-url` off the list's link (expression tier) and the detail's link
back (builder), checks nothing else in the list pushes, then requests the
pushed URL as a restore and insists on the note inside a document. Each
push reverted alone fails the gate at its own line.

In a browser: `unotes` carries the same bytes, hand-typed, against htmx
4.0.0 in Chrome — the URL moves, back restores the list AND the filter
form's values.

## Not built

- **`hx-replace-url`.** No application has asked.
- **A tidy pushed URL for a form.** A GET form sends every field, so the
  pushed URL is `/notes?q=football&era=&type=`. `Query` (N36) writes only
  what is set for a link the application renders; what the browser
  serializes from a form is the browser's.
- **Response-side pushes** (`HX-Push-Url`). D17 stands: three applications
  writing the same header setter is its condition, and this is none.
