"""The fragment-or-page decision, made by the framework from a request header.

A view that renders a fragment should return one thing. Whether that
fragment goes out bare — the browser asked for it with `HX-Request: true`
and will swap it into a page it already has — or wrapped in a whole
document, because a person typed the URL, is not the view's business. It
is a property of the request, and this module reads it so the view never
branches. FastHTML's `is_full_page` is the same idea; `dj-fixi`'s
`request.is_fx` is the same idea again.

    def index(req, params, store) raises -> HTTPResponse:
        return page_or_fragment(req, render_list(store), Site("notes"), wrap)

`wrap` is the app's shell: a function that puts a fragment inside the
document — the `<head>`, the script tag, the stylesheet — and is called
only when a document is actually wanted. It takes a context value first
(`Site("notes")` here: a title, a nav, whatever the shell needs) because a
`thin` function cannot capture anything, and `thin` is the only function
shape a precompiled package can accept from an app.

A trait was the first design — `PageShell` with a `wrap` method, so the
context and the function travel together — and it does not survive the
`.mojoc` boundary: an app's conformance to a trait it imports from a
precompiled package is accepted and its witness table is never emitted
(*"struct 'Site' does not have witness table for trait"*), even when the
trait's methods name only prelude types. `HTTPService` and `PoolHandler`
live in the source-resolved fork for the same reason. Two arguments where
one struct would have been nicer is the cost of that, paid here.

`Vary` is not optional here. One URL now has two representations, so a
shared cache that stored the fragment would replay it to a direct
navigation. Both answers carry `Vary: HX-Request`, ADDED to whatever
`Vary` the response already names — a view that negotiated on `Accept` too
keeps that.

The header name is htmx's. It is spelled in one place, `FRAGMENT_HEADER`,
for the same reason `Html.swap` spells the attributes in one place.
"""

from lightbug_http.http import HTTPRequest, HTTPResponse

from .reply import html, vary

comptime FRAGMENT_HEADER = "hx-request"
"""The request header that asks for a bare fragment. Lowercase, as
`Headers` stores every name."""

comptime FRAGMENT_VARY = "HX-Request"
"""The same header as `Vary` names it."""


def wants_fragment(req: HTTPRequest) -> Bool:
    """Whether the request asked for a bare fragment (`HX-Request: true`)."""
    var h = req.headers.get(FRAGMENT_HEADER)
    if h:
        return h.value() == "true"
    return False


def page_or_fragment[C: AnyType](
    req: HTTPRequest,
    fragment: String,
    ctx: C,
    shell: def (C, String) raises thin -> String,
) raises -> HTTPResponse:
    """`fragment` bare if the request asked for one, else `shell(ctx,
    fragment)`; `Vary: HX-Request` either way. `shell` runs only when a
    document is wanted."""
    if wants_fragment(req):
        return vary(html(fragment), FRAGMENT_VARY)
    return vary(html(shell(ctx, fragment)), FRAGMENT_VARY)
