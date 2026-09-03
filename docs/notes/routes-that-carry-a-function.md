# Considered, not built: routes that carry a function

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

`Router.match` returns an `Int` and the caller dispatches on it, which is why
three of five Mojo apps skip the router and hand-write `if path == …`.
Route-to-function **is** reachable on Mojo 1.0 — verified by spike, not
assumed. The spelling is `thin`: a closure trait (`def (X) raises -> Y`) is
an `AnyTrait`, refused as a `List` element and refused outright as a struct
field, but `def (X) thin raises -> Y` is a concrete type that lists and
struct fields both take, including generically —
`List[def (mut Self.T, ...) thin raises -> HTTPResponse]` inside a
`struct RouteTable[T]` dispatches and mutates `T` correctly.

What stopped it is a type cycle, not the language. Every Mojo app in this
tree keeps its state in the handler and the handler owns the router, so
`RouteTable[NotesHandler]` as a field of `NotesHandler` is infinitely
recursive. The fix is to split app state into a type the handler owns
alongside the table — a real design, and a real rewrite of the showcase app.
Building the table before an app wants it would add an API with zero call
sites, which is the condition `auth.mojo` and `response_cache.mojo` are
already in. Build it with the first app that asks; the spelling above is the
part that was unknown.
