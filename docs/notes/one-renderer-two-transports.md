# One renderer, two transports, 2026-09-11

> A design note from the engineering record: what Datastar 1.0 asks of a
> server-rendered fragment, checked against the shipped bundle rather than
> recalled, and what the framework layer built on the answers.

[A fragment that names itself](a-fragment-that-names-itself.md) built the
fragment layer for htmx and left one claim unproven: that the same
renderer's output could go out as an HTTP body to htmx *and* as a
`datastar-patch-elements` frame to every connected tab, which is the
transport where this server is ahead — a cross-worker bus, a replay
journal, `Last-Event-ID` resumption across a restart. Proving it meant
learning what Datastar actually does, because the tree's Datastar knowledge
was three version traps found in a browser and a wire format copied from
the SDK's test cases. Every fact below names where it was read.

## What was checked

**The version.** Datastar's newest release is v1.0.3 (2026-08-27); the
tree pinned v1.0.2 (2026-06-02). The comparison between the two tags is
fifteen commits with nothing under `sdk/`, a bundle 34,083 bytes to
33,538, and release notes naming an opt-in CSP mode, signal state resent
when a request is retried after a network error, a view-transition
detection fix and a `<select multiple>` binding fix. Every string the
tree's behaviour rests on is in both bundles in the same count: the
request header, the three accepted content types, the key parser
`split(/:(.+)/)` that makes colon-separated keys the only spelling, and
no `on-load` at all. The pin moved to v1.0.3 first, under `smoke-todo`
and `smoke-counter`, and the todo demo was driven in Chromium against the
new bundle for the three recorded traps before the renderer was touched.

**Request detection.** Every `@get`/`@post` sends `Datastar-Request: true`,
with `Accept: text/event-stream, text/html, application/json` — the
counterpart of htmx's `HX-Request: true`, read from the bundle's fetch
action.

**What an action accepts.** The response's `Content-Type` decides.
`text/event-stream` is the stream of events the SDKs generate. `text/html`
is handled as a `datastar-patch-elements` whose options come from response
headers — `datastar-selector`, `datastar-mode`, `datastar-namespace`,
`datastar-use-view-transition` — with the body as the elements.
`application/json` is a `datastar-patch-signals` (`datastar-only-if-missing`),
`text/javascript` is executed, and a 204 is nothing. So "one renderer, two
transports" is literal: the same `text/html` body an htmx request receives
is what a Datastar action receives, and the response constructor, not the
renderer, is what knows which client asked.

**Signals and forms.** Signals travel as the `datastar` query parameter on
GET and as a JSON body otherwise, which `read_signals` already reads. An
action with `contentType: 'form'` sends the closest form (or the one its
`selector` option names) as `application/x-www-form-urlencoded`, or as
`multipart/form-data` when the form's `enctype` says so, and sends no
signals; on GET the fields go into the query string. A Datastar form is
therefore exactly the body `form(req)` decodes for htmx, repeated keys
included.

**The morph.** The default mode is `outer`, and its target, when no
selector is given, is found "by matching top-level elements based on their
ID" — the id a fragment writes once. The other modes are `inner`,
`replace`, `prepend`, `append`, `before`, `after` and `remove`. Where the
mode is spelled differs between the two libraries: for Datastar it is a
property of the *response* (a dataline in a frame, a header on a
`text/html` answer); for htmx it is on the *element* (`hx-swap`), with a
response override (`HX-Reswap`).

**The attribute vocabulary.** Keys are colon-separated (`data-on:click`,
`data-bind:draft`); modifiers attach with a double underscore and dotted
tags (`__prevent`, `__debounce.500ms`, `__window`); the stream opens from
`data-init`. None of it changed between the two versions.

**The SDK specification.** The ADR's mandates — `event`, then `id`, then
`retry`, then `data` lines; a default retry of 1000 ms; datalines with a
trailing space; only non-default options emitted — are what `m0-datastar`
implements, and the v1.0.3 diff does not touch them.

**htmx, for the other side of the seam.** htmx 4.0.0 was released
2026-08-28 and is `next` on npm; 2.x stays `latest` into early 2027. It
adds `HX-Request-Type: partial|full` and morph swaps in the core. The
tree's htmx is 2.0.4, whose `loadHistoryFromServer` sends both
`HX-Request: true` and `HX-History-Restore-Request: true` and swaps the
answer's body into the page it is rebuilding. No unified
hypermedia-vocabulary abstraction turned up in FastHTML or `datastar-py`;
the search was not exhaustive.

## What was built on it

**The vocabulary is a type parameter.** `Fragment[V: Vocabulary]`, with
`Htmx` and `Datastar` as the two conformances in `html.mojo`, each the only
place its library's spelling lives. The same `swap(verb, url)` on an open
element emits `hx-post`/`hx-target`/`hx-swap="outerHTML"` for one and
`data-on:EVENT="@post('url')"` for the other, with no target at all,
because the morph finds the fragment by the id it already carries. The
event follows htmx's own default-trigger rule so the two agree on *when*
(what travels is each library's own: htmx sends the element's value, a
Datastar action the signal store, so a field is bound rather than sent):
a `<form>` submits, with `__prevent` and
`{contentType: 'form'}` so the request carries its fields; a field
changes; an `<a>` or `<button>` clicks with `__prevent`, which cancels an
anchor's navigation and a button's native submit and does nothing
elsewhere; anything else clicks. An app names its vocabulary once
(`comptime Frag = Fragment[Htmx]`) and writes no attribute of either.
The Datastar URL sits inside a JavaScript string literal, which `attr`'s
HTML escaping cannot protect — the browser un-escapes `&#x27;` before the
expression is evaluated — so a URL carrying a quote, a backslash or a
line break is refused; `url_for` percent-encodes all three, and an app
that builds a query from request data must too. Both vocabularies refuse
a verb outside the five, since a typo is a silent attribute in one and a
runtime error in the other.

Three seams were candidates. A fragment emitting both vocabularies through
two methods puts the choice back in every renderer; a vocabulary *value*
passed alongside the fragment is one more argument through every renderer,
because a `thin` view cannot close over it; the type parameter carries the
choice in the type and costs nothing at a call site. It works across the
`.mojoc` boundary because the conformances are inside the package — the
same reason `Views[S]` over an app type works while an app conforming to a
package trait does not — and `build-apps` is the proof.

**One mode, deliberately.** A `mode` parameter on `swap` would be a
spelling one library cannot honour, since Datastar keeps the mode on the
response. The response is where the two agree (`HX-Reswap` and
`datastar-mode` are both headers), and no application in the tree appends
a row, so the mode is not built; when an application asks, it belongs
beside `page_or_fragment`.

**Four headers decide the page.** `page_or_fragment` answers the bare
fragment for `Datastar-Request: true`, and for `HX-Request: true` unless
`HX-History-Restore-Request: true` or `HX-Boosted: true` is beside it — a
history restore needs the whole document, and so does a boosted
navigation, which targets the body with `innerHTML` and takes a full
document's body. Every answer's `Vary` names all four, added to any
`Vary` the view already set; naming a header the app's own library never
sends costs nothing and keeps the decision one function. (Review of the
pull request found the boost case; it is the history-restore failure in
a different coat.)

**The todo demo is the proof.** `apps/datastar_todo`'s `render_todos` is a
`Fragment[Datastar]`, its routes are values reversed with `url_for`, and
`smoke-todo` did not change: it still greps `<section id="todos">` out of a
live stream's frame and again out of a fresh page load. `m0-datastar`'s
`test_fragment_frame.mojo` pins the property on the types — one line,
verbatim as the single `elements` line, no selector — and the demo was
driven in Chromium after the conversion: a todo added in one tab reaches
the other by broadcast, a toggle strikes through across tabs, and a todo
added by `curl` after a server restart reaches a tab that never reloaded.

**A table knows where it is mounted.** `Views[S](Mount("/native"))`
registers every route under the prefix, `Mount.url_for` reverses to those
paths, and `PoolContext.prefix` carries the prefix from the pool's own
lane table — the table the loop routes by — so a `PoolHandler` cannot
disagree with the loop about where it is. `m0serve`'s `MojoMount` is now a
`Views` table over per-thread state whose index renders its two routes as
links, and `smoke-mojo-mount` follows one under `--mount /native=mojo`,
then follows the same link without its prefix and insists the root
application answers 404. That is the gate `smoke-hybrid` applies to
Django's `reverse()`, and it is the rung where a Mojo mount serving a
computed fragment into a Python page stops producing dead links.

**An element as an expression.** The builder is statement-shaped, and
`apps/fragment_notes`'s list was 56 lines with about four calls per
element. The expression tier — `el(tag, attrs, children...)`, `void`,
`attr`, `flag`, `text`, and `Fragment.el(tag, verb, url, ...)` for an
element that swaps the fragment — makes an element a string, so the
renderer nests the way its markup nests and each hole names its escaping
(`text` for data, `attr` for a value, a bare string for markup the file
trusts). The list is now 25 lines of body against 54: half, not the
third the assessment asked for, and the remainder is loop scaffolding —
three `for` loops with an accumulator each — that a language with
closures or comprehensions would fold into a `join`, and a `thin`
function cannot. The tag is given once, to `Fragment.el`, because the
vocabulary reads it; giving it separately to a swap-attributes function
would spell it twice. `test_html.mojo` pins the two tiers byte-identical
on the same list item, and `smoke-fragment-notes` did not change when
`render_list` moved onto the tier while `render_note` stayed in the
builder, deliberately, so the reference app shows both shapes. The attrs
slot is positional, and a child left in it — `el("p", "none")` — used to
render `<pnone></p>` without a sound; rendered attributes always open
with a space, so `raw_attrs` refuses a value that does not, naming the
slip.

## Not built, and what would retire each

| Not built | Why | What would retire it |
| --- | --- | --- |
| A swap mode or target on the response (`HX-Reswap`/`HX-Retarget`, `datastar-mode`/`datastar-selector`) | no application appends; the response is the right place for both libraries, and it is one function when needed | an application that appends a row rather than replacing its list |
| Signal attributes from a fragment (`data-bind`, `data-text`, `data-signals`) | they are the page's, written by hand in the todo demo; a fragment's job is the swap | a second Datastar application needing them inside a fragment |
| htmx 4's `HX-Request-Type` | the tree pins 2.0.4 and 2.x is `latest`; a history restore is already a page | moving the pin to 4 |
| A `Vocabulary` an application defines | a trait from a `.mojoc` package cannot be conformed to from an application on this toolchain (`check-mojoc-trait` is the probe that flips) | the probe flipping; until then a third library is a struct in `html.mojo` |
| A `join` or comprehension over children | a `thin` function cannot capture, so a per-item renderer has nothing to close over; the loops stay loops | closures that can be stored, or a `List[String]` form of `el` that an application asks for |
