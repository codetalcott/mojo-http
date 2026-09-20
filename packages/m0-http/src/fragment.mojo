"""The fragment-or-page decision, made by the framework from request headers.

A view that renders a fragment should return one thing. Whether that
fragment goes out bare — the browser asked for it with `HX-Request: true`
or `Datastar-Request: true` and will swap it into a page it already has —
or wrapped in a whole document, because a person typed the URL, is not the
view's business. It is a property of the request, and this module reads it
so the view never branches. FastHTML's `is_full_page` is the same idea;
`dj-fixi`'s `request.is_fx` is the same idea again.

    struct Site(PageShell):
        var title: String

        def wrap(self, fragment: String) raises -> String:
            return String("<title>", self.title, "</title>", fragment)

    def index(req, params, store) raises -> HTTPResponse:
        return page_or_fragment(req, render_list(store), Site("notes"))

`PageShell` is the app's document. `wrap` puts a fragment inside the
`<head>`, the script tag and the stylesheet, and is called only when a
document is actually wanted. Whatever the shell needs to do that — a
title, a nav — are the struct's own fields, so the context and the
function travel as one value. A shell that needs no context is a struct
with no fields, which is why there is no second form for one.

**Five headers decide, and the decision is one function for every
library.** htmx 4 says what it wants outright: every request it makes
carries `HX-Request-Type`, `full` when the target is the body or a
`select` will pick from the answer, `partial` otherwise (htmx 4.0.0,
`ctx.target === document.body || ctx.select`). When that header is present
it DECIDES — `partial` is a fragment, `full` is a page — and nothing else
htmx sent is consulted, for two measured reasons. A v4 history restore
carries `HX-History-Restore-Request: true` and `HX-Request-Type: full` and
almost nothing else: no `HX-Request` at all, the restore's own `request`
option replacing the whole header object. And a v4 boosted link with an
explicit `hx-target` sends `HX-Boosted: true` beside `partial`, and means
it: handed a whole document, v4's `makeFragment` lifts the `<body>`
ELEMENT into the fragment, which is not what a section's `outerHTML` swap
wants.

htmx 2 never sends `HX-Request-Type`, so a request without it is read by
the rule htmx 2 needs, unchanged. There `HX-Request: true` rides every
request, INCLUDING a
history restore (`loadHistoryFromServer` in htmx 2.0.4 sets both) and a
boosted navigation (`hx-boost` adds `HX-Boosted: true`) — and both need
the whole document: a history restore swaps the response's body into the
page it is rebuilding, and a boosted request targets the body with
`innerHTML` and takes a full document's body (`makeFragment`), so a bare
fragment in either place is a page with no `<head>`, no script and no
styles, or a body that is one section. So `HX-History-Restore-Request:
true` and `HX-Boosted: true` each win over `HX-Request: true`. The two
rules cannot collide: which one runs is keyed on a header only one major
version sends, and a value of it that is neither word falls through to
the second rule rather than being guessed at. Datastar
sends `Datastar-Request: true` on its `@get`/`@post` actions and accepts a
`text/html` answer, which it morphs into the element whose id it
carries — the id the fragment owns — so a Datastar action gets the bare
fragment. One renderer, and the response constructor is what knows which
client asked.

**The shell was a `thin` function over a separate context struct until
2026-09-18**, and the reason was a toolchain bug rather than a design one.
An app's conformance to a trait it imported from a precompiled package was
accepted and its witness table never emitted — *"struct 'Site' does not
have witness table for trait 'src::fragment::PageShell'"* — and the error
named the cause all along: a package compiled from a directory of another
name recorded its traits under the DIRECTORY's name while a consumer
resolved them under the package's, and every package here runs `mojo
precompile src -o <name>.mojoc`. Mojo 1.1.0 fixed it and the pin moved
(docs/notes/the-pin-moves-to-1-1-0.md), so `scripts/mojoc_trait_check.py`,
which compiles an app's `PageShell` conformance against the built package
and calls this function through it, flipped from a countdown to the
regression guard that the fix is still there. DECISIONS D12 is the row,
retired 2026-09-18.

`Vary` is not optional here. One URL now has two representations, so a
shared cache that stored the fragment would replay it to a direct
navigation. Both answers name EVERY header the decision reads — `Vary:
HX-Request, HX-History-Restore-Request, HX-Boosted, Datastar-Request,
HX-Request-Type` (the fifth last, so the four an older cache already keyed
on keep their order) — ADDED to
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

comptime BOOSTED_HEADER = "hx-boosted"
"""The htmx boost marker, sent BESIDE `HX-Request: true` by `hx-boost`."""

comptime REQUEST_TYPE_HEADER = "hx-request-type"
"""What htmx 4 itself answers to the question: `full` or `partial`, on every
request it makes, a history restore included. htmx 2 never sends it."""

comptime DATASTAR_HEADER = "datastar-request"
"""Datastar's request header, sent by every `@get`/`@post` action."""

comptime FRAGMENT_VARY = "HX-Request"
"""The same header as `Vary` names it."""

comptime HISTORY_VARY = "HX-History-Restore-Request"

comptime BOOSTED_VARY = "HX-Boosted"

comptime DATASTAR_VARY = "Datastar-Request"

comptime REQUEST_TYPE_VARY = "HX-Request-Type"


def wants_fragment(req: HTTPRequest) -> Bool:
    """Whether the request asked for a bare fragment: `Datastar-Request:
    true`; else what `HX-Request-Type` says when it says `partial` or
    `full` (htmx 4); else `HX-Request: true` with neither
    `HX-History-Restore-Request: true` nor `HX-Boosted: true` beside it
    (htmx 2).

    Compared without allocating and without regard to the value's case:
    the libraries send lowercase, and a proxy that capitalised a value
    should not be served a whole document.
    """
    if req.headers.value_equals_ignore_case(DATASTAR_HEADER, "true"):
        return True
    if req.headers.value_equals_ignore_case(REQUEST_TYPE_HEADER, "partial"):
        return True
    if req.headers.value_equals_ignore_case(REQUEST_TYPE_HEADER, "full"):
        return False
    if not req.headers.value_equals_ignore_case(FRAGMENT_HEADER, "true"):
        return False
    if req.headers.value_equals_ignore_case(HISTORY_HEADER, "true"):
        return False
    return not req.headers.value_equals_ignore_case(BOOSTED_HEADER, "true")


def vary_on_fragment_headers(var resp: HTTPResponse) -> HTTPResponse:
    """Name every header `wants_fragment` reads in the response's `Vary`."""
    resp = vary(resp^, FRAGMENT_VARY)
    resp = vary(resp^, HISTORY_VARY)
    resp = vary(resp^, BOOSTED_VARY)
    resp = vary(resp^, DATASTAR_VARY)
    return vary(resp^, REQUEST_TYPE_VARY)


trait PageShell:
    """An application's document: `wrap` puts a fragment inside it.

    Everything the document knows that a fragment does not — the title,
    the nav — are the conforming struct's own fields, so one value carries
    both the context and the function. A shell with nothing to carry is a
    struct with no fields.
    """

    def wrap(self, fragment: String) raises -> String:
        ...


def page_or_fragment[S: PageShell](
    req: HTTPRequest,
    fragment: String,
    shell: S,
    status: Int = 200,
    text: String = "OK",
) raises -> HTTPResponse:
    """`fragment` bare if the request asked for one, else
    `shell.wrap(fragment)`; `Vary` on every header the decision reads
    either way. `wrap` runs only when a document is wanted. `status` is
    for a styled error page — a 404 an app wants to render is still a 404,
    not a soft one crawlers index."""
    var resp: HTTPResponse
    if wants_fragment(req):
        resp = html(fragment)
    else:
        resp = html(shell.wrap(fragment))
    resp.status_code = status
    resp.status_text = text
    return vary_on_fragment_headers(resp^)
