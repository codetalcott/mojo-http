"""Rendering: the routes as values, the fragment, and the document around it.

Every renderer builds the SAME fragment — `Frag(ROOT_ID)` writes
`id="items"` once, and `f.element("form", "post", ITEMS, ...)` generates
the swap attributes that target it from that id. Nothing here types an
`hx-` attribute or a `#items`.

An element is a call: `Li(title)`, `P(error, role="alert")`. A bare string
child is TEXT and escaped, a keyword is an attribute (`cls` for `class`),
and markup goes in by name, as another element or `Raw("&times;")`. The
document around the fragment is the `Html` builder.
"""

from m0_http import El, Fragment, Html, Htmx, PageShell, Raw, url_for
from m0_http.tags import H1, Button, Input, Li, P, Ul

# Pinned: a floating version lets an upstream release break this app
# without a commit here.
comptime HTMX_CDN = "https://cdn.jsdelivr.net/npm/htmx.org@4.0.0/dist/htmx.min.js"

# The routes, written once: given to the table in `views.mojo` and to
# `url_for` below, so a misspelled route is a compile error.
comptime ITEMS = "/items"
comptime ITEM = "/items/:id"

comptime ROOT_ID = "items"

# The vocabulary, named once. `Fragment[Datastar]` here, and Datastar's
# script tag in `Site.wrap`, is the whole of moving this app to Datastar.
comptime Frag = Fragment[Htmx]

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:36rem;margin:2rem auto;padding:0 1rem}
form.new{display:flex;gap:.5rem;margin-bottom:1rem}
input{font:inherit;padding:.4rem;flex:1}
ul{list-style:none;padding:0}
li{display:flex;gap:.5rem;align-items:center;padding:.3rem 0}
li button{margin-left:auto}
[role=alert]{color:#b00020}
</style>"""


struct Site(PageShell):
    """What the document knows that a fragment does not: the title.
    `wrap` runs only when a whole document was asked for."""

    var title: String

    def __init__(out self, var title: String):
        self.title = title^

    def wrap(self, fragment: String) raises -> String:
        var h = Html(1024)
        h.raw('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n')
        h.raw('<meta name="viewport" content="width=device-width,initial-scale=1">\n')
        h.open("title")
        h.text(self.title)
        h.close("title")
        h.raw("\n")
        h.open("script")
        h.attr("src", HTMX_CDN)
        h.close("script")
        h.raw("\n")
        h.raw(_STYLE)
        h.raw("\n</head>\n<body>\n<main>\n")
        h.raw(fragment)
        h.raw("\n</main>\n</body>\n</html>\n")
        return h^.finish()


def render_list(
    ids: List[Int], titles: List[String], error: String
) raises -> String:
    """The `items` fragment: the form, the error if there is one, the list."""
    var f = Frag(ROOT_ID)
    f.raw(f.element("form", "post", ITEMS,
        Input(name="title", placeholder="a new item"),
        Button("Add"),
        cls="new",
    ))
    if error.byte_length() > 0:
        f.raw(P(error, role="alert"))
    var rows = List[El]()
    for i in range(len(ids)):
        var url = url_for(ITEM, String(ids[i]))
        rows.append(Li(
            f.element("a", "get", url, titles[i], href=url),
            f.element("button", "delete", url, Raw("&times;"), aria_label="delete"),
        ))
    f.raw(Ul(rows))
    if len(ids) == 0:
        f.raw(P("nothing yet"))
    return f^.finish()


def render_item(title: String) raises -> String:
    """The same fragment showing one item, so a swap lands in the same place."""
    var f = Frag(ROOT_ID)
    f.raw(H1(title))
    f.raw(P(f.element("a", "get", ITEMS, "all items", href=ITEMS)))
    return f^.finish()


def render_missing() raises -> String:
    """A 404 a person may see is the fragment too."""
    var f = Frag(ROOT_ID)
    f.raw(P("no item with this id", role="alert"))
    f.raw(P(f.element("a", "get", ITEMS, "all items", href=ITEMS)))
    return f^.finish()
