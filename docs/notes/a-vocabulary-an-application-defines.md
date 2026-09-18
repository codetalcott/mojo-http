# A vocabulary an application defines — 2026-09-18

`Fragment[V: Vocabulary]` takes the frontend library as a type parameter.
DECISIONS D7 kept its two conformances, `Htmx` and `Datastar`, inside
`html.mojo`, because on Mojo 1.0 an application's conformance to a trait
behind a `.mojoc` was accepted and its witness table never emitted
([a-trait-and-a-directory-name](a-trait-and-a-directory-name.md)). Mojo
1.1.0 fixed that and the pin moved the same day
([the-pin-moves-to-1-1-0](the-pin-moves-to-1-1-0.md)). D7's retiring
condition read "opening `Vocabulary` to an application-defined conformance,
with a gate that an app outside this repo can emit a third library's
attributes". This is the record of that round, the last of the three the
pin unblocked (D28, D12, D7).

It was not D12 again. `Vocabulary` was already exported; what was closed
was everything a conformance needed. `Datastar.swap` read `h._open_kind`
and compared it with four module-private constants, and both conformances
called a module-private `_check_verb`. A stranger's vocabulary written
against that trait could emit attributes and nothing else: it could not
tell a form from a button, and it skipped the verb check the layer
promises. So the round's question was what the trait's contract is once
someone else implements it.

## The probes

Each is an application compiled from a directory outside the repository
against the built `m0_http.mojoc`, at `46da0e8`.

| probe | answer |
|---|---|
| `struct Htmx4(Vocabulary)` with a `@staticmethod swap`, used as `Fragment[Htmx4]` — builder tier, `Fragment.el`, and `Html.swap[Htmx4]` | compiles; emits its own attributes in all three |
| a trait `@staticmethod` with a DEFAULT body, behind a `.mojoc` built from a renamed directory; one conformance takes the default, one overrides | `1five 2six` — both work |
| `print(h._open_kind)` from the app | compiles, prints `1` |
| `from m0_http.html import _check_verb` and a call | compiles, raises the verb error |
| `from m0_http.html import _KIND_FORM, _kind_of` | compiles, prints `1 1` |

The static witness crosses like the instance one did. And **nothing is
private**: the underscore field, the module-private functions and the
`comptime` constants are all reachable through the `.mojoc`. So the design
question was never "what must be exposed for this to be possible" — it is
"what is blessed", and the answer has to be enforced by something other
than the compiler.

## What is blessed (D34)

**A conformance is written without an underscore.** That is the contract,
and it is mechanical: `poe check-app-vocabulary` refuses its own app
source if an underscore-led name appears in it. Three things make the rule
sufficient.

*The element kind is an accessor, not an argument.* `Html.open_kind()`
answers an `ElementKind` with three questions — `is_form`, `is_field`,
`is_link` — "none of the three" being the fourth answer. Passing the kind
into `swap` was the alternative, on the argument that the signature would
then carry everything a conformance may read and `Html` could stay opaque.
It was rejected because `Html` is not opaque to a vocabulary and cannot
be: `swap` receives it `mut` and writes with `attr` and `flag`, so the
builder's public surface is already the contract, and a fifth positional
argument would be one more thing every conformance names and only one
reads. The accessor changed no signature and no call site.

*The verb check is the layer's, and the verb list is the vocabulary's.*
Left in each conformance, a stranger's vocabulary skips it and the promise
becomes "both built-in vocabularies". Hoisted with the five verbs
hard-coded, `Fragment[Htmx4].swap("query", ...)` is impossible from
outside — the layer refusing a verb the library defines, since htmx 4 has
six. So the trait grew a second static member with a default:

```mojo
@staticmethod
def verbs() -> String:
    return STANDARD_VERBS      # "get post put patch delete"
```

Every swap now goes through one function, `_swap[V]`, which refuses a verb
outside `V.verbs()` — naming that vocabulary's own list in the error — and
then calls `V.swap`. A string rather than a list because it is also the
error message, and because a conformance that overrides it writes one
line. `_check_action_url` stayed in `Datastar`: it is about a JavaScript
string literal, which is Datastar's context and nobody else's.

*The built-in conformances use only the blessed surface.* `Datastar` now
reads `h.open_kind()` and neither conformance checks a verb, so the
surface cannot be narrower than what a real library needed. That is the
honest proof of `open_kind()`; see below for what the outside gate adds.

## The third library is htmx 4

Not fixi, which was the first pick: the layer's own `Htmx` is gated against
2.0.4 (D6), any new htmx use here is 4.x, and an application-defined
`Htmx4` is how the layer meets htmx 4 without moving its own pin. Facts
were read out of the vendored 4.0.0 bundle in `~/projects/hx-flask` and
that repository's `HTMX4.md`, whose rows are tests.

Two problems with htmx 4 as the gate, and what was done about each.

**With `outerHTML`, `Htmx4` emits what `Htmx` emits**, byte for byte, and a
green gate would prove only that a conformance compiles. The gate's
`Htmx4` spells `hx-swap="outerMorph"` — htmx 4's built-in morph by id,
which is what Datastar does with the same fragment, and arguably the right
htmx 4 spelling for a layer whose claim is one renderer for both — and
allows `hx-query`. Both are asserted by exact string, the gate fails if
`outerHTML` appears, and the five-verb `Htmx` is shown still refusing
`query` in the same run.

**htmx picks its own event, so `Htmx4.swap` never asks the element kind.**
A real use was looked for. The candidate is htmx 4's DELETE rule — a
`delete` on a non-form element inside a form sends none of the form's
values (`hxlint` reports it as `delete-without-include`) — but the
vocabulary sees the open element, not its ancestors, and the fix
(`hx-include="closest form"`) moves fields into the query string, which is
the application's decision and not a spelling. So the gate carries a
second, plainly synthetic vocabulary, `KindEcho`, whose only job is to
read `open_kind()` from outside the package in both tiers for all four
answers. `Htmx4` is not evidence for that surface and the gate's docstring
says so; `Datastar` is its real consumer.

## The gate

`scripts/app_vocabulary_check.py` (`poe check-app-vocabulary`, inside
`test-all`; SPEC N21). It writes the app into a temporary directory,
refuses to continue if that directory is under the repository root,
compiles it with `-I` to the two `.mojoc`s and nothing else, runs it, and
asserts: the whole rendered document by exact string; the two attributes
that differ from `Htmx`'s; `KindEcho`'s four answers; a typo refused BY
THE LAYER with `Htmx4`'s six-verb list in the message, `Htmx4.swap` having
checked nothing; `query` allowed for `Htmx4` and refused for `Htmx`; and no
warning from the app's own build.

Then it hands the document to **`hxlint`**, vendored from hx-flask with
`hx_vocab`, which is generated from htmx 4's source tree — a second
implementation, so the vocabulary is never checked against itself
(`scripts/notes_session.py` is the precedent). A linter that says nothing
has said nothing until it has failed, so the gate first breaks the
document three ways — a target naming no id (`missing-target`, which is an
outside check of the claim `Fragment` exists to make), a miscased swap
style, a misspelt verb attribute — and insists each is reported.

Sabotaged by hand, each restored from a copy:

| reverted | caught by |
|---|---|
| the conformance's `swap` renamed | the compile |
| `outerMorph` → `outerHTML` in the app | the exact-string assertion |
| `ElementKind(h._open_kind)` in the app | the underscore rule |
| `verbs()` answering five | the app raising on `query` |
| a null case that changes no id | "hxlint did not report…" |
| `_swap`'s check removed in `html.mojo` | three tests in `test_html.mojo`, and the gate |

The vendored files are another project's (MIT, the owner's own). NOTICE
names them, `licenses/LICENSE.hx-flask.txt` is the licence, and
`check_vendored_files` in `scripts/check_docs.py` holds each file's sha256
with the upstream commit beside it, its three rules reverted in
`--selftest`. CI cannot see the upstream checkout, and dj-hx's copy of the
same two files was eighty lines stale within two days of its upstream,
which is the argument for the guard made by the owner's own repositories.
`mapcore.py` stayed behind: it maps template controls to Python handlers
by AST, and this layer has neither.

## What did not change

`poe smoke-fragment-notes` and `poe smoke-todo` are the wire gates for the
two built-in vocabularies. Both apps were built at `46da0e8` and again
after the change, driven through every swapping call site — four in
`fragment_notes` (the create form, the title link and the delete form in
the list, the back link in the detail; three `hx-target` in the list and
one in the detail, counted in the capture) and three in `datastar_todo`
(toggle, the rename form, delete; the `submit__prevent` arm present) — and
nine captured bodies compared with `cmp`: identical. The session cookie
was signed by `notes_session.py` with a fixed expiry so the CSRF token in
the page is the same in both runs.

## Not built, and flagged rather than added

- **`HX-Request-Type`.** Everything `Fragment` emits targets `#id`, so its
  htmx 4 requests are `partial` and the four-header rule answers them
  correctly. A hand-written `hx-target="body"` or `hx-select` on a page
  this layer serves is `full` to htmx 4 and a fragment to
  `wants_fragment`. Closing that is a fifth header, a `Vary` change on
  every answer, a D9 amendment and SPEC N8 — its own round.
  [one-renderer-two-transports](one-renderer-two-transports.md)'s "Not
  built" table already names it.
- **An htmx 4 application.** `Htmx4` here is a vocabulary in a gate. An app
  on it that deletes must answer what `hxlint` cannot see: htmx 4 has no
  `methodsThatUseUrlParams`, a DELETE's fields always ride the query
  string, and `fragment_notes`' CSRF token would be in the URL, the access
  log and the Referer. A POST to a delete route, or the token in
  `hx-headers`. A clean lint is not a clean htmx 4 app.
- **Control → handler method agreement.** `f.swap("delete", NOTE)` against
  a table that registered `NOTE` for GET only is a 405 at click time.
  `Views` answers `OPTIONS` with a merged `Allow`, so a gate could read
  every control out of a rendered page and ask the server. A follow-up,
  not this round's.
- **fixi** sends `FX-Request: true`, which `wants_fragment` does not read.
  Same D9 territory.
