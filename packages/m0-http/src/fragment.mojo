"""The fragment-or-page decision, made by the framework from request headers.

A view that renders a fragment should return one thing. Whether that
fragment goes out bare — the browser asked for it with `HX-Request: true`
or `Datastar-Request: true` and will swap it into a page it already has —
or wrapped in a whole document, because a person typed the URL, is not the
view's business. It is a property of the request, and this module reads it
so the view never branches. FastHTML's `is_full_page` is the same idea;
`dj-fixi`'s `request.is_fx` is the same idea again.

    def index(req, params, store) raises -> HTTPResponse:
        return page_or_fragment(req, render_list(store), Site("notes"), wrap)

`wrap` is the app's shell: a function that puts a fragment inside the
document — the `<head>`, the script tag, the stylesheet — and is called
only when a document is actually wanted. It takes a context value first
(`Site("notes")` here: a title, a nav, whatever the shell needs) because a
`thin` function cannot capture anything, and `thin` is the only function
shape a precompiled package can accept from an app.

**Three headers decide, and the decision is the same for both libraries.**
htmx sends `HX-Request: true` on every request it makes, INCLUDING a
history restore (`loadHistoryFromServer` in htmx 2.0.4 sets both) — and a
history restore needs the whole document, because htmx swaps the response's
body into the page it is rebuilding; a bare fragment there is a page with
no `<head>`, no script and no styles. So `HX-History-Restore-Request: true`
wins over `HX-Request: true`. Datastar sends `Datastar-Request: true` on
its `@get`/`@post` actions and accepts a `text/html` answer, which it
morphs into the element whose id it carries — the id the fragment owns —
so a Datastar action gets the bare fragment too. One renderer, and the
response constructor is what knows which client asked.

A trait was the first design — `PageShell` with a `wrap` method, so the
context and the function travel together — and it did not survive the
`.mojoc` boundary: an app's conformance to a trait it imports from a
precompiled package was accepted and its witness table never emitted
(*"struct 'Site' does not have witness table for trait"*), even though the
trait's one method names only `String`. That has now been observed twice
on this toolchain, both times with the generic CONSUMER inside the same
`.mojoc` (`MojoPool[T: PoolHandler]`, `wrap_with[S: PageShell]`), and
`Views[S: Movable]` — a `.mojoc` generic over an app type conforming to a
stdlib trait — works, so the exact discriminant is not established.
`PageShell` and `wrap_with` are kept below for `scripts/mojoc_trait_check.py`,
which compiles an app conformance against the built package and insists
it is refused: the day that check flips, the trait is the API to prefer.
Until then the shell is two arguments where one struct would have been
nicer.

`Vary` is not optional here. One URL now has two representations, so a
shared cache that stored the fragment would replay it to a direct
navigation. Both answers name EVERY header the decision reads — `Vary:
HX-Request, HX-History-Restore-Request, Datastar-Request` — ADDED to
whatever `Vary` the response already carries, so a view that negotiated
on `Accept` too keeps that. Naming a header the app's own library never
sends costs nothing (a cache keys on its absence) and is what makes the
decision one function rather than one per vocabulary.

The header names are the libraries'. Each is spelled in one place below,
for the same reason `Htmx.swap` and `Datastar.swap` spell their attributes
in one place.
"""

from lightbug_http.http import HTTPRequest, HTTPResponse

from .reply import html, vary

comptime FRAGMENT_HEADER = "hx-request"
"""The htmx request header. Lowercase, as `Headers` stores every name."""

comptime HISTORY_HEADER = "hx-history-restore-request"
"""The htmx history-restore marker, sent BESIDE `HX-Request: true`."""

comptime DATASTAR_HEADER = "datastar-request"
"""Datastar's request header, sent by every `@get`/`@post` action."""

comptime FRAGMENT_VARY = "HX-Request"
"""The same header as `Vary` names it."""

comptime HISTORY_VARY = "HX-History-Restore-Request"

comptime DATASTAR_VARY = "Datastar-Request"


def wants_fragment(req: HTTPRequest) -> Bool:
    """Whether the request asked for a bare fragment: `Datastar-Request:
    true`, or `HX-Request: true` without `HX-History-Restore-Request: true`.

    Compared without allocating and without regard to the value's case:
    both libraries send `true`, and a proxy that capitalised it should not
    be served a whole document.
    """
    if req.headers.value_equals_ignore_case(DATASTAR_HEADER, "true"):
        return True
    if not req.headers.value_equals_ignore_case(FRAGMENT_HEADER, "true"):
        return False
    return not req.headers.value_equals_ignore_case(HISTORY_HEADER, "true")


def vary_on_fragment_headers(var resp: HTTPResponse) -> HTTPResponse:
    """Name every header `wants_fragment` reads in the response's `Vary`."""
    resp = vary(resp^, FRAGMENT_VARY)
    resp = vary(resp^, HISTORY_VARY)
    return vary(resp^, DATASTAR_VARY)


def page_or_fragment[C: AnyType](
    req: HTTPRequest,
    fragment: String,
    ctx: C,
    shell: def (C, String) raises thin -> String,
    status: Int = 200,
    text: String = "OK",
) raises -> HTTPResponse:
    """`fragment` bare if the request asked for one, else `shell(ctx,
    fragment)`; `Vary` on every header the decision reads either way.
    `shell` runs only when a document is wanted. `status` is for a styled
    error page — a 404 an app wants to render is still a 404, not a soft
    one crawlers index."""
    var resp: HTTPResponse
    if wants_fragment(req):
        resp = html(fragment)
    else:
        resp = html(shell(ctx, fragment))
    resp.status_code = status
    resp.status_text = text
    return vary_on_fragment_headers(resp^)


trait PageShell:
    """The shell as a trait: the shape this module would prefer, kept as
    the target of `scripts/mojoc_trait_check.py` (see the module
    docstring). Not exported from the package."""

    def wrap(self, fragment: String) raises -> String:
        ...


def wrap_with[S: PageShell](shell: S, fragment: String) raises -> String:
    """`shell.wrap(fragment)`, as a generic the probe instantiates from an
    app. Not exported from the package."""
    return shell.wrap(fragment)
