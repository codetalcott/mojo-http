# Django views the right way, translated to Mojo, 2026-09-10

> A design note from the engineering record. Prompted by reading
> [The Pattern](https://spookylukey.github.io/django-views-the-right-way/the-pattern.html)
> and asking what it should be built out of here instead of Python.

The article's claim is narrow and worth taking literally. A view is a
function that takes a request and returns a response; the recommended
starting point makes all three visible at a glance, and class-based views
hide all three behind `.as_view()`. Its Django form is:

```python
def example_view(request: HttpRequest, arg: str) -> HttpResponse:
    return TemplateResponse(request, 'example.html', {})
```

Three of the four mechanisms that shape make use of do not exist in Mojo:
module-level globals, `dict[str, Any]`, and a decorator that returns a
wrapped callable. Working through what replaces each is most of this note.
The fourth — a plain function in a URL table — ports exactly, and the tree
was not using it.

## What the tree did instead

`Router` answers *which* route matched, as an integer, and turning that
integer back into code was every app's own business. All three Mojo apps
did it the same way: a `comptime H_GET = 2` block, a
`router.add("GET", "/notes/:id", H_GET)` call, and an
`if m.handler_id == H_GET: return self._get_one(...)` chain — the URL and
the code that answers it three edits apart, with nothing checking that they
agree. The views themselves were private methods on a struct that also
owned the router, the CORS config, the health registry and the data store.

That is not quite a class-based view, but it loses the article's property
the same way: you cannot see what answers a URL without reading three
places, and the third is a chain.

It is also unsafe in a way worth recording. `apps/notes_api` ends its chain
with a bare `return self._delete(req, id)` as the fallthrough, so a route
added without a matching arm does not 404 — it deletes.

## The pattern

A view is a free function. The table names it directly:

```mojo
def detail(
    req: HTTPRequest, params: List[String], mut store: NoteStore
) raises -> HTTPResponse:
    var page = store.note_page(reply.param_int(params[0]))
    if not page:
        return _missing(req.uri.path)
    return reply.html(render_note(page.value()))

...

v.add(String("GET"), String("/notes/:id"), detail)
```

`Views[S]` (`packages/m0-http/src/views.mojo`) is a `Router` and a parallel
`List` of view functions. `add` assigns the handler id itself, so an app
never sees one and cannot get one wrong; `dispatch` matches and calls. The
integer still exists and still indexes an allocation-free byte scan —
`Router` is untouched — but it is now an implementation detail of one
struct rather than a constant an app maintains.

`apps/views_pattern` is the worked example, split the way the article's
implicit layout asks: contexts and templates, state and its pure reads, the
views and the URL table, and a `server.mojo` shell whose `func` is two
lines.

## Views are stored as thin function pointers

The load-bearing language fact, and it took a probe to find: `fn` is gone in
Mojo 1.0 and a function type spells `def (...) -> ...`, but *that* type is
an existential and is not `Movable`, so it cannot go in a `List`. The
compiler's own error message names the concrete type — `raises thin` — and
a `thin` function type is `Movable` and stores fine:

```mojo
comptime View = def (
    HTTPRequest, List[String], mut Self.S
) raises thin -> HTTPResponse
```

It works as a struct-level `comptime` referencing `Self.S`, so `Views[S]` is
generic over each app's state type without the spelling appearing four
times.

## Each difference from the Python is paying for something

**State is a parameter, not a global.** Django's views reach `Note.objects`
— a module-level global holding a connection pool. Mojo has no global `var`
(`src/global_slot.mojo` reaches `pop.global_alloc` for the two cases that
genuinely need static storage, and fork copies those rather than sharing
them). This framework could not use one anyway: under `--threads` a
`WSGIApp`, an `SSERegistry`, a `ProvisionPool` and an m0-sqlite
`Connection` are per-thread *by rule*. So the state a view needs is the
caller's, handed in. The third argument is that rule made visible rather
than a workaround for the missing feature.

**Captured parameters arrive as a list, not as named arguments.** Django
passes URL captures as extra positional arguments and can, because its
resolver calls a dynamically-typed callable. A `List[View]` must hold one
uniform type and Mojo cannot vary arity across it.

Wrapping the request and its captures in a single struct was the obvious
alternative, and it is the one measured dead end here: the wrapper wants a
`Pointer[HTTPRequest, o]`, which puts an origin parameter on the struct,
which lands in the stored function type and stops the table being one list.
A wrapper that *owned* the request instead would copy it per dispatch —
exactly the allocation `Router.match` is written to avoid, whose docstring
brags that a 404 allocates nothing at all. A plain borrowed `HTTPRequest`
argument costs neither: it names no origin and copies nothing. So the
captures ride beside the request rather than inside it.

**There is no `TemplateResponse`, and the replacement is stricter.** Its
purpose is to keep the template name and context inspectable instead of
rendering eagerly, so tests and middleware can look at or change them. The
mechanism is `dict[str, Any]`, which Mojo does not have. What ports is the
purpose:

- a **context** is a struct — the data a page needs, with no HTTP in it
- a **template** is a function from that struct to a `String`
- the **`state -> context`** step is a pure method returning `Optional`

A missing context field is then a compile error rather than a template
variable that renders empty, and every part a test would want to assert on
is reachable by calling a function with no request in hand. That is the
repo's own stated design principle — functional core, I/O at the edges —
arriving at the same place the article does from the other direction.

What is genuinely given up is late binding. Middleware cannot rewrite a
response's context on the way out, because by then it is bytes. Nothing in
this framework wanted to.

**Guards are early returns, because a closure is not thin.** A Python
decorator wraps a view and puts the wrapper back where the view was. Mojo
can express the wrapping — as a capturing closure — but a capturing closure
is not `Movable`, so the result cannot go back in the table. Guards are
therefore calls at the top of the body:

```mojo
var denied = require_key(req, store)
if denied:
    return denied.take()
```

`require_key` returns `Optional[HTTPResponse]` — the rejection, or nothing.
Returning the *reply* rather than a permission Bool means a guard cannot be
misread as the inverse of itself, and it keeps this framework's habit of
answering with responses rather than raising across the handler boundary on
a hot path. The article prefers explicit, traceable logic over decorator
magic anyway; here the language does not offer the alternative, which is a
convergence rather than a compromise.

**404 is a view.** `set_not_found` takes one, so an app that wants a styled
404 page writes a page. The default stays RFC 9457 problem+json because most
of this framework's callers are not browsers.

## What is not claimed

Nothing here is measured. The dispatch was an `if` chain over a handful of
integer comparisons and is now one indirect call through a `List`; that is
very likely a wash and was not benchmarked, because the change is about
whether a URL's answer is findable and not about throughput. No existing app
was converted — `notes_api` still carries its handler-id chain, including
the delete fallthrough — so nothing byte-identical on the wire has moved.
`Views` is gated by `test_views.mojo` and `apps/views_pattern` by
`build-apps`; neither is a smoke test against a running server.
