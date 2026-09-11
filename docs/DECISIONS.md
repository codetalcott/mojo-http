# Decisions

One row per standing decision about the application layer, with what would
retire it. The design notes argue each at length and are kept as written;
this page is the index of which decisions stand, so a session that reads
nothing else meets the constraint before re-proposing a piece.

Rows have a permanent id (`D7`). Ids are never renumbered or reused: a
retired or superseded row keeps its id and its line, and a new row takes
the next number. A decision id and a [SPEC](SPEC.md) row id are different
tables — SPEC's section D is graceful shutdown, so `D9` there is a
capability and `D9` here is a decision — and prose says which.

| status | means |
|---|---|
| `standing` | in force; not to be re-proposed until the retiring condition holds |
| `superseded by Dn` | replaced by the row named |
| `retired YYYY-MM-DD` | the retiring condition was met on that date |

**recorded in** names the note under `docs/notes/` that records the
decision, or a CLAUDE.md heading written `CLAUDE.md: <heading>`.
**retired by** is the condition that would reopen it; `—` says there is
none foreseeable.

`poe check-docs` fails when a `recorded in` does not resolve, a retiring
condition is empty, an id is repeated or out of order, a status is not one
of the three, or a `superseded by` names an id that is not here
(`check_decisions_ledger` in `scripts/check_docs.py`; its `--selftest`
reverts each rule against this page and insists the checker catches it).
What no check can tell is whether a decision is still right; that is the
retiring condition's job, and the reason each row has one.

## The application layer

Seeded from the three notes that built the layer. Server decisions join
as each is next revisited, one row at a time; until then CLAUDE.md's
"properties of the design, not defects to fix in passing" list is where
they are recorded.

| id | decision | recorded in | status | retired by |
|---|---|---|---|---|
| D1 | HTML helpers, not a safety type: `String` stays the currency, `attr` and `text` escape, `raw` says so by name, and nothing forces an application to migrate | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | a decision to accept the migration to an auto-escaping newtype across every app |
| D2 | No template language and no template files: an application's markup is Mojo, compiled with its context struct | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | nothing foreseeable |
| D3 | No middleware and no decorators: a capturing closure is not `thin`, so there is nothing to put back in the table, and guards are early returns of `Optional[HTTPResponse]` | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | a language change that makes a capturing function value storable |
| D4 | Route params are positional: origins are not spellable as struct parameters on the pinned toolchain, so a borrowing `RouteParams` cannot be written and an owning one allocates per name per request | [views-the-mojo-way](notes/views-the-mojo-way.md) | standing | origins spellable as struct parameters |
| D5 | Routes are patterns, not function values: `thin` values are not `==`-comparable, so the pattern is the `comptime` constant given to both `add` and `url_for` | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | comparable function values |
| D6 | `hx-*` against htmx 2.0.4, provisionally; `fx-*` and htmx 4 are deferred, and what weighs when the pin moves is recorded with the decision | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | moving the pin |
| D7 | The frontend vocabulary is a type parameter (`Fragment[Htmx]`, `Fragment[Datastar]`) and its conformances live inside `html.mojo`, because an application cannot conform to a trait defined in a `.mojoc` package | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | `check-mojoc-trait` flipping |
| D8 | One swap mode: a non-default mode belongs on the response beside `page_or_fragment`, where both libraries take a header, never on `swap` | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | an application that appends a row rather than replacing its list |
| D9 | `page_or_fragment` reads four headers — `Datastar-Request`, `HX-Request`, `HX-History-Restore-Request`, `HX-Boosted` — and every answer's `Vary` names all four | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | — |
| D10 | A Datastar URL carrying `'`, `\`, CR or LF is refused, not encoded: `url_for` encodes them, and an application building a query from request data must too | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | a query builder on `url_for` |
| D11 | The mount prefix is a value threaded through state (`Mount`, used once for registration and once for `url_for`); `PoolContext.prefix` comes from the pool's own lane table, the one the loop routes by | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | — |
| D12 | The page shell is a `thin` function over a context, not a trait; `PageShell` stays in `fragment.mojo` as the probe target `check-mojoc-trait` compiles against | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | `check-mojoc-trait` flipping |
| D13 | `form(req)` is `Optional`, compares the media type whole, and keeps a decoding loop of its own rather than sharing `URI.parse`'s last-wins one | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | — |
| D14 | `ViewService` does not conform to `PoolHandler`; a mounted application is a three-line struct in its entry file holding a `Views` table and its per-thread state | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | the trait boundary lifting, and an app whose state is a per-thread SQLite `Connection` |
| D15 | No sessions and no CSRF: `wyhash64` is not a MAC, so an HMAC-SHA256 with published test vectors comes first, and whatever is built emits through `ResponseCookieJar.add_raw` | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | an application with a login (SPEC N13) |
| D16 | No `multipart/form-data`: a boundary scanner, per-part headers, a spill-to-disk policy and a size story the whole-body cap does not answer | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | an application that uploads a file |
| D17 | No `HX-*` setter helpers: `resp.headers["HX-Trigger"] = x` is the API | [a-fragment-that-names-itself](notes/a-fragment-that-names-itself.md) | standing | three apps writing the same setter |
| D18 | No streaming from a Mojo mount: `MojoPool` refuses a streaming response, because a stream begun on a pool thread has no producer the loop drains | [mojo-handler-pool](notes/mojo-handler-pool.md) | standing | an application that needs it (SPEC N11), settled by the probe: a `MojoPool` thread sending the hold frame a WSGI pool thread sends |
| D19 | The expression tier allocates per element and has no `join`; the builder is for a renderer that cares | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | storable closures, or a `List[String]` form of `el` that an application asks for |
| D20 | Datastar is pinned at 1.0.3; re-check the version before any vocabulary work | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | the next Datastar release with a protocol change |
| D21 | A Datastar field's action sends the signal store, not the field, so a field is bound and a form arm reads what the store carries | [one-renderer-two-transports](notes/one-renderer-two-transports.md) | standing | the browser run SPEC N12 plans finding that the field travels alone |
