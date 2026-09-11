# A fragment that names itself, 2026-09-10

> A design note from the engineering record: the framework layer for an
> application written in Mojo, built app-first under a wire gate. What was
> built, what each lift found, what was refused, and what is not claimed.

Every one of the 172 rows `docs/SPEC.md` carried at 1.0.0 was about serving
Python. The tree's own Mojo apps were seven `server.mojo` files that each
routed by `if path ==` or a handler-id chain, wrote every byte of HTML as a
`String(...)` call, spelled every URL as a literal, and could not read a
`<form method=post>` at all, because nothing in the tree decoded a
urlencoded body. This note is what it took for an htmx app in Mojo to be
something a person, or a coding agent, would write on purpose.

## The pattern, stated once

> A fragment owns its own root id. The attribute that targets it is
> generated from that same id. The view does not branch on which one to
> send; the framework decides from a request header whether to wrap the
> fragment in a page.

The objection to htmx that this dissolves is that it writes behaviour
twice: an attribute in a template and a handler that answers it, with
nothing checking that the two agree. That objection is to **hand-written
attributes**. `dj-fixi`'s `FxForm(action, target, swap)` already emits the
`fx-*` attributes server-side from its own arguments, so the target is one
Python value used twice; FastHTML's `is_full_page` already lets a view
return the same components whether or not the request came from htmx. In
Mojo both get stricter, because the page is code and the compiler checks
the two uses.

Three things follow. The id is written once, by `Fragment("notes")`, and
`swap("post", "/notes")` on an element inside it generates `hx-target`
from that value; nothing in `apps/fragment_notes` types `#notes`. The view
returns one thing — the fragment — and `page_or_fragment` reads
`HX-Request` to decide whether to wrap it. And `Vary` stops being
optional: one URL now has two representations, so a shared cache that
stored the fragment would replay it to a direct navigation, and both
answers say `Vary: HX-Request`.

## Built app-first, and gated on the wire before the first lift

The repo's rule is that an API with no call site is a defect, and
`reply.mojo`'s docstring records that its helpers were *lifted rather than
invented* from three apps that each carried a copy. So the sequence was:

1. **`apps/fragment_notes`, written deliberately ugly** against `main` as
   it stood — `hx-*` attributes by hand in eight places, `String(...)`
   concatenation, literal URLs, a `comptime H_*` id chain, an inline
   urlencoded parser twice, every view branching on the header itself.
2. **A smoke gate pinning wire output only** (`smoke-fragment-notes`, SPEC
   N1): the `Café` round-trip through a form, an escaped `<script>` title
   in the list and on its page, both values of a repeated checkbox key,
   one URL answering a bare fragment under `HX-Request: true` and a whole
   document without it with `Vary` on both, a body declared
   `application/json` refused, `DELETE` on the collection 405 with
   `Allow`, and a 405 on a note leaving the note intact.
3. **Five lifts, each a refactor under that green gate**, in this order:
   the view table, the HTML helpers and the fragment, the fragment-or-page
   decision, `url_for`, and forms last. The smoke did not change from the
   first commit to the last. That, and not a diff of the sources, is what
   "the wire output did not move" rests on.

The gate was sabotaged six ways before the first lift — `Vary` dropped,
escaping skipped, the repeated key truncated to its first value, the
fragment always wrapped, the content type ignored, 405 collapsed into
404 — and one was **missed**. The content-type probe sent a real JSON
document, which fails the empty-title check on a server that ignores the
content type just as it does on one that reads it. The probe that catches
the difference sends form-SHAPED bytes under a JSON content type
(`title=json`): only a server that reads the content type refuses those.
That is the shape the gate keeps, and the reason `form(req)` returns empty
rather than guessing.

## What each lift is, and what building it found

**The view table** (`Views[S]`, `packages/m0-http/src/views.mojo`; the
design is [views-the-mojo-way.md](views-the-mojo-way.md)). A view is a
free function `(req, params, state) raises -> HTTPResponse`; `add_read`
hands the state borrowed and `add_write` hands it `mut`, so a reading
view that writes does not compile — `poe sabotage-views` compiles the
counter-examples and insists they are refused; `add_loop` registers a
stateless view answered in `before_request` so it never becomes a pool
job; `dispatch` answers 405 with `Allow` and 404 with no fallthrough.
Reworked from draft PR #273: both notes apps were converted rather than a
third added, and `apps/notes_api`'s old chain — which ended in a bare
`return self._delete(...)`, so a route registered without its own arm
deleted instead of answering — is gone. The guard is structural:
`dispatch` has no fallthrough to reach, and `test_views.mojo` pins what it
does answer. (A wire assertion in `smoke-notes` was first described as
guarding this; it cannot, since the old chain answered 405 before the
chain for any unregistered method, and the claim is withdrawn.)

**The HTML helpers and the fragment** (`Html`, `Fragment`,
`packages/m0-core/src/html.mojo`). The diagnosis behind them is that the
worst line in the tree stacked three quoting levels — a Mojo literal, an
HTML attribute, a Datastar expression — and the pain was not the quotes
but that the author was writing the attribute's own delimiters by hand.
`attr` owns the `="` and the `"` and escapes what goes between them;
`text` escapes; `raw` says so by name; a start tag is ended by whatever
follows it, so a void element needs no call of its own. The single quotes
inside a Datastar expression come out as `&#x27;`, which the HTML parser
un-escapes before any expression evaluator sees them — what every
templating engine does, and more correct than the hand-written line. It is
`escape_html_into`'s first caller. It was first placed in m0-core to keep
m0-http's import count from that package at four, which mistook an
inventory for the constraint (zero upward imports, no libpython); it now
lives in m0-http beside `fragment.mojo`, its consumer, and the count is
five. `finish` consumes the builder, so a second call is a compile error
rather than a second closing tag, and the constructor refuses an id that
`#id` could not select. Per the standing decision these are **helpers, not a
safety type**: `String` stays the currency, `reply.html(String)` is
unchanged, no app is forced onto them, and escaping stays a convention
the other apps may ignore. The helpers make the safe path the shorter one;
they do not make the unsafe path impossible. `Html.swap` is the ONLY place
the attribute vocabulary is spelled, and that is what makes the `fx-*`
versus `hx-*` versus htmx 4 question deferrable: the app never writes the
attribute.

**The fragment-or-page decision** (`page_or_fragment`,
`packages/m0-http/src/fragment.mojo`) found the most durable fact of the
round. The first design was a trait — `PageShell` with a `wrap` method,
so the shell's context and its function travel together — and it failed
at app build: *"struct 'Site' does not have witness table for trait"*.
The rule recorded from `PoolHandler` said a trait behind the `.mojoc`
fails when its methods name types the app resolves from source; this
trait's one method named only `String`, and it failed the same way. So
the rule is broader than "types the app resolves from source" — but it is
still generalised from two experiments, both with the generic consumer
inside the same `.mojoc`, and `Views[S]` over an app type works, so the
exact discriminant is not established. It is recorded as observed, with a
probe that can flip: `poe check-mojoc-trait` compiles an app conformance
to `PageShell` (kept in `fragment.mojo` for this) against the built
package and insists it is refused, beside a control that catches a stale
`.mojoc`. `HTTPService` and `PoolHandler` live in the source-resolved fork
for the same reason. The shape that crosses the boundary today is a
`thin` function over a generic context — `page_or_fragment[C](req,
fragment, ctx: C, shell: def (C, String) raises thin -> String)` — probed
standalone and then proven by `build-apps`. Two arguments where one struct
would have been nicer is the cost, paid there.
The same lift fixed `reply.vary_accept`, which **overwrote** `Vary`;
`reply.vary` appends without repeating a name, and both answers carry
`HX-Request` beside whatever `Accept` the view already named.

**Reverse URLs** (`url_for`, `packages/m0-http/src/router.mojo`). Two
designs were probed and closed before this one. FastHTML's shape — pass
the view function, read the URL off it — needs a function value to be
identifiable at the table, and a `thin` function value is not
`==`-comparable on Mojo 1.0. A name registry makes a typo a runtime error
at render. What is left is the pattern string itself, written once as a
`comptime` constant and given to both `add` and `url_for` — the same
trick the fragment plays with its id. A misspelled route is a compile
error; `url_for` raises on the wrong arity, because a bad reverse is a
programming error whose silent form is a dead link (`reply.param_int`
returns -1 instead because it handles untrusted input); each value is
percent-encoded so a slash stays one segment. `Router.pattern_of` reads a
registered pattern back out of the blob, and
`test_every_registered_route_reverses_and_matches` reverses every route
in a table and insists `match` sends it back to the same handler with the
same captures — the property that keeps the two directions honest.

**Form bodies** (`form(req)`, `packages/m0-http/src/form.mojo`). An
ordered multimap, because `<input type=checkbox>` legitimately repeats
one key; `first`, `get` (which tells absent from empty), `all`, `has`.
`Optional`: None unless the content type is
`application/x-www-form-urlencoded`, compared whole, for the reason the
missed sabotage gave — and so that "not a form" can never be read as an
empty one by a view whose fields all have defaults. **Deliberately not factored out
of `URI.parse`**: the query loop there fills a last-wins `Dict` by
contract, and a shared loop would force one of the two to change; the
anti-drift device is a test, not a type — one table of encodings runs
through both parsers and every value must decode identically.

## Decisions taken, and not to relitigate

- **Helpers, escaping stays opt-in.** No newtype that makes `reply.html`
  refuse a `String`; no forced migration of the other apps.
- **`hx-*` against a pinned htmx 2 CDN, provisionally.** The generator is
  the only thing that knows the spelling. What weighs when it comes up
  again: `fx-*` is a house library with almost no presence in model
  training data, a real cost for agent-written code that pulls against
  portfolio consistency; htmx 4 adds an `HX-Request-Type` header and
  changed the wire shape.
- **Draft PR #273 was reworked, not landed as-is.** Two apps converted,
  `apps/views_pattern` dropped.
- **Datastar is the second consumer of one renderer, not a rival.** Its
  default `outer` morph targets the id the fragment already carries. Not
  built this round; see below.

## Refused, and what would retire each

| Not built | Why | What would retire it |
| --- | --- | --- |
| `multipart/form-data` | a boundary scanner, per-part headers, a disposition model, a spill-to-disk policy, and a size story the whole-body cap does not answer | an app that uploads a file |
| A template language or template files | new syntax and attack surface; breaks the single-binary, no-`open()`-in-the-request-path property; discards the compile-checked context struct — an agent writes Mojo far better than a bespoke DSL | nothing foreseeable |
| An auto-escaping newtype | decided against: helpers, `String` stays the currency | a decision to accept the migration |
| Sessions and CSRF | the app has no session, so there is nothing to forge; and `wyhash64` is not a MAC — signing a cookie with it is a forgeable session. HMAC-SHA256 with test vectors is the prerequisite, and whatever is built must emit through `ResponseCookieJar.add_raw` | an app with a login |
| `HX-Trigger`/`HX-Redirect` setters | `resp.headers["HX-Trigger"] = x` works today; six APIs with one call site each is the defect this repo names | three apps writing the same setter |
| Named route params | toolchain-blocked: none of `ImmutableAnyOrigin`, `Origin[False]`, `Origin[False]._mlir_type`, `type_of(MutUntrackedOrigin)` resolves as a struct parameter, so a borrowing `RouteParams` cannot be spelled and an owning one allocates per name per request | origins spellable as struct parameters |
| Middleware / decorators | a capturing closure is not `thin`, so there is nothing to put back in the table; guards are early returns of `Optional[HTTPResponse]` | a language change |
| Routes as function values | `thin` values are not comparable | comparable function values |
| `ViewService` conforming to `PoolHandler` | a pool thread owns its handler, so the state must be per-thread; a shared in-memory store is wrong for it — and a `.mojoc` conformance would get no witness table anyway. The shape is a three-line struct in the entry file holding a `Views` and its state (`m0serve`'s `MojoMount`, since the following note) | the trait boundary lifting, and an app whose state is a per-thread SQLite `Connection` |
| Streaming from a Mojo mount | `MojoPool` refuses it | an app that needs it |

## What is not claimed

Nothing here is measured; the change is about whether an app is writable,
not about throughput, and no row of this layer has a benchmark.

The Datastar skin — the same renderer's output going out as a
`patch_elements` frame — was not built in this round. It was built the
next day, as `Fragment[Datastar]`, and `apps/datastar_todo` renders its
fragment through it; what Datastar was found to need, and the seam
chosen, are in [one-renderer-two-transports](one-renderer-two-transports.md).

One seam still carries the id as a string: an element rendered OUTSIDE a
fragment that should swap it (a page-level link) takes `frag.selector()`.
It still comes from the fragment value rather than being retyped, but it
is a value handed across rather than a value used twice.

`ViewService` is not proven under `--blocking-threads`; an app using the
pool writes its own handler struct, as `apps/pool_spike` does.
