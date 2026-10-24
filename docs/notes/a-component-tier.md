# A component tier — 2026-10-24

A design review of the layer's HTML surface, written against `2d28ad2`,
asked whether m0 should render markup the way FastHTML does —
`Div(P("x"), cls="card")`, a function per tag, children positional,
attributes as keywords — and compared eight shapes on the same page and
the same 50-item list. This is the record of what the probes found, what
was decided (D67) and what was built (SPEC N54, N55), in the repository's
own order: an application that asks, a wire gate, then the lift. The
application is `apps/fragment_notes`, the gate `smoke-fragment-notes`,
unchanged.

## Where it stood

`html.mojo` had two tiers over one escaping rule. The builder (`Html`,
`Fragment`) is statement-shaped — `open`, `attr`, `text`, `close` — and
allocates once per render. The expression tier (`el`, `void`, `attr`,
`flag`, `text`, `Fragment.el`) makes an element a `String` so a renderer
reads like its markup, and allocates per element
([one-renderer-two-transports](one-renderer-two-transports.md), D19).
Both name the escaping at each hole: `text(x)` for data, `attr(name, x)`
for a value, a bare string for markup the caller trusts (D1).

That last clause is the hole. In `el("li", "", title)` a request-derived
`title` is markup, and the injection reads like every other argument;
nothing in the type system notices that `text(...)` was left off. The
review's recommendation was a tier where a bare string is TEXT by
construction, so the escaped path is not the shorter one but the only one
a child can take without saying so.

## The probes

Every figure below is from the pinned toolchain (Mojo 1.2.0, 2016d0cd) on
a 4-vCPU Linux container, `mojo build` defaults, best of five rounds of
20,000 renders, two runs agreeing within 5%. The list is 50 `<li>` items,
each with an id, two `hx-` attributes and escaped text, 3,153 bytes; every
form below renders byte-identical output, checked before timing.

**The review's probes reproduce.** A component form over `String` with
`@implicit` constructors on a `Child` type (from `String`, `StringLiteral`,
`El`, `List[El]`) and `var **attrs` compiles and runs; so does a
compile-time HTML literal (`html["<li id=\"{}\">{}</li>"](id, title)`),
whose unquoted hole in a tag and whose wrong arity are compile errors; so
does a form bound to a struct through `std.reflection` (`field_names`,
`field_types`, `field_ref`). The review's render figures reproduce too.

**Option 5 — a tree rendered once — does not pay.** The review left it
open, since the builder is five times faster than any per-element form on
a list and a tree rendered into one buffer at the root looked like the way
to that figure. Measured, with the dictionary's cost separated out:

| form, the 50-item list | µs |
|---|---|
| `Html` builder | 7.5 |
| expression tier (`el`, `attr`, `text`) | 28 |
| components, `String` per element, `**attrs` dictionary | 38 |
| components, `String` per element, attributes pre-rendered (no dictionary) | 29 |
| components, a tree of recorded builder operations rendered once at the root | 38 |
| components, one `List[UInt8]` per element presized from its parts | 24 |

The tree is no faster than the strings it replaces: the children are
evaluated before their parent whatever the shape, so each allocates, and
what the tree saves in escaping it spends copying operation records. The
keyword dictionary is a quarter of the per-element cost. The presized byte
buffer is the form to build — slightly faster than the expression tier,
three times the builder — and the builder stays for a renderer that is hot
(D19 stands).

**The 3b overload coexists.** A `Fragment.el` taking `Child` children
beside the one taking `String` children resolves without ambiguity on
today's call shapes, the exact type winning. It was still given its own
name, `Fragment.element`: in the new tier a bare string is text, and a
call that hands one to the old overload as its `attrs` argument would
raise from `raw_attrs` with a message about the wrong thing.

**Two things the review's probe got wrong, fixed in the tier.** Its
`_tag` closed every element, so `Input(...)` rendered `<input></input>`;
the tier's void elements take keywords only, and a child handed to one is
a compile error. Its own `Todo.__ft__` typed `hx_swap_oob=True` as a raw
keyword, which is the attribute the layer forbids an application to spell
([a-fragment-that-names-itself](a-fragment-that-names-itself.md)); the
tier refuses the swap attributes at render, below.

**The reflection probe fails the warning ratchet as written.**
`UnsafePointer(to=...)` is deprecated on 1.2.0 and warns; `Pointer(to=...)`
with the same `unsafe_bitcast` compiles clean. The dispatch compares type
names as strings (`SIMD[DType.int, 1]` for `Int`), which a pin move can
change silently, and the probe defaults a missing field to zero where the
tree's `form(req)` is `Optional` precisely so that absent cannot read as
empty. Reflection is not part of this round; it waits for an application
that asks, with a `check-*` probe guarding the API as `check-mojoc-trait`
guards the trait fix.

**The dev loop is untouched.** A one-line edit to `apps/fragment_notes`
(678 lines) rebuilds in 31 s here against the ~10 s `m0 dev`'s docstring
assumes; 200 call sites of either tier compile in 17.9 s. Authoring
ergonomics were the review's whole case, and this is the number that
dominates them. It is recorded here as the open cost, not answered.

## The decision (D67)

An auto-escaping element type, in the component tier alone. `El` is markup
by construction and a bare `String` child is text; `String` stays the
currency at every boundary — a fragment finishes to a `String`,
`reply.html` takes one, the builder is unchanged — so D1's helpers stand
where they stood and the hole they left is closed where an application
writes its elements.

The expression tier is superseded, not removed. The two spellings invert
what a bare string means (`el`: markup; `Li`: text), so one file holding
both is the quiet mis-escaping hazard this round exists to remove: no file
mixes them, and each application leaves `el` whole, under its own gate.
`fragment_notes` went first, in this round; `table_notes`, `blobs`, the
four scaffold templates and `login.mojo`'s `csrf_input` follow a round
each, and `el` goes when the last has left. N10 says so.

Not built with it, each an application's ask away: a `Component` trait
(FastHTML's `__ft__`), the form bound to a struct by reflection, the
compile-time literal. The literal is worth a line: D2's recorded reasons
are new syntax and attack surface, an `open()` in the request path and the
loss of the compile-checked context struct, and a `comptime` literal has
none of the three — so D2 as written does not forbid it, and the question
when an application asks is whether a hole syntax inside a Mojo string is
a template language in the sense that matters. It escapes every hole alike
in the probe, with no trusted-markup hole.

## What was built

In `html.mojo`, below the expression tier:

- `El`, the bytes of a rendered element; `html()` reads it as a `String`.
- `Child`, with implicit constructors from `String` and `StringLiteral`
  (escaped), `El` (markup) and `List[El]` (each in turn).
- `AttrValue`, from `String` and `StringLiteral` (escaped and quoted),
  `Int` (decimal) and `Bool` (presence: `checked=True` is ` checked`,
  `checked=False` is nothing).
- `_element` and `_void_element`, one buffer presized from the parts;
  `element` and `void_element` for a tag the module does not name; `Raw`
  for markup in a string, named as the builder's `raw` is.
- The keyword's spelling: `cls` is `class`, a leading `_` is dropped
  (`_for`), every other `_` is `-` (`hx_boost`, `aria_label`, `data_n`).
- The refusal: a keyword that spells a swap — `hx-VERB` for the six htmx
  verbs, `hx-target`, `hx-swap`, `hx-push-url`, `hx-headers`, anything
  under `data-on` — raises at render, naming `Fragment.element`. At render
  and not in a source check, because an application outside the tree
  meets the rule there and nowhere else; `hx_boost`, `hx_confirm`,
  `hx_indicator` pass, since they are not a swap.
- `Html.raw(El)` and `Fragment.raw(El)`, so an element goes into a builder
  or a fragment as it stands.
- `Fragment.element(tag, verb, url, children..., push=, header=,
  **attrs)`: the keywords, then the swap, then the push and header, then
  the children — the bytes `Fragment.el` writes for the same element, in
  both vocabularies, held by `test_html.mojo`.

`src/tags.mojo` holds the tag functions, one line each over `_element` or
`_void_element`: 98 elements and 13 void ones from the living standard,
without the obsolete elements and without `html`, whose name the builder
holds (the document element is the page shell's, or `element("html",
...)`). They are imported by name from `m0_http.tags`, not from
`m0_http`'s root, where `Form` is the parsed form.

`apps/fragment_notes`' `render_list` and `render_login` moved onto it;
`render_note` stays in the builder on purpose, the two shapes side by
side. `csrf_input` still renders a `String`, so the field goes in as
`Raw(csrf_input(csrf))` until `login.mojo`'s round. The smoke did not
change.

## Not built, and why

- **Migrating the other applications and the templates here.** Each has a
  gate of its own (`smoke-table-notes`, `smoke-blobs`, the scaffold smoke
  and `sabotage-scaffold`), and the method is one application per round
  under its gate. The scaffold's `AGENTS.md` still teaches `el`; it moves
  with the templates.
- **A `Component` trait.** Four lines, and nothing asks yet; a trait
  behind a `.mojoc` is also the shape that lost its witness table through
  Mojo 1.0 ([a-trait-and-a-directory-name](a-trait-and-a-directory-name.md)).
- **A faster tier.** The builder's figure is not reachable by a form that
  evaluates children first; a form that writes into the parent's buffer
  needs a storable closure or a statement, and the statement form exists.
