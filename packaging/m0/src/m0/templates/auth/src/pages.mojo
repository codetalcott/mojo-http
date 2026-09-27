"""Rendering: the routes as values, the fragment, and the document around it.

Every renderer builds the SAME fragment — `Frag(ROOT_ID)` writes
`id="items"` once, and `f.el("form", "post", ITEMS, ...)` generates the
swap attributes that target it from that id. Nothing here types an `hx-`
attribute or a `#items`.

Every write carries the session's CSRF token, spelled once each way: a
POST as a hidden field (`csrf_input`), a DELETE as a request header
(`header=csrf_header(csrf)`), because htmx 4 sends a DELETE's fields in
the query string and a token in a URL is a token in every log. The login
and the logout are PLAIN forms, never swaps: a swap changes the fragment
and not the address bar, so signing in would leave the list under /login.

Escaping is named at every hole: `text(...)` for data in an element,
`attr(name, value)` for data in an attribute, a bare string only for
markup this file wrote itself.
"""

from m0_http import (
    Fragment,
    Html,
    Htmx,
    PageShell,
    attr,
    csrf_header,
    csrf_input,
    el,
    text,
    url_for,
    void,
)

# Pinned: a floating version lets an upstream release break this app
# without a commit here.
comptime HTMX_CDN = "https://cdn.jsdelivr.net/npm/htmx.org@4.0.0/dist/htmx.min.js"

# The routes, written once: given to the table in `views.mojo` and to
# `url_for` below, so a misspelled route is a compile error.
comptime ITEMS = "/items"
comptime ITEM = "/items/:id"
comptime LOGIN = "/login"
comptime LOGOUT = "/logout"

comptime ROOT_ID = "items"

# The vocabulary, named once. `Fragment[Datastar]` refuses a request
# header, so moving this app to Datastar also moves the DELETE's token
# into a form field.
comptime Frag = Fragment[Htmx]

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:36rem;margin:2rem auto;padding:0 1rem}
form.new,form.login{display:flex;gap:.5rem;margin-bottom:1rem}
form.login{flex-direction:column;max-width:20rem}
input{font:inherit;padding:.4rem;flex:1}
ul{list-style:none;padding:0}
li{display:flex;gap:.5rem;align-items:center;padding:.3rem 0}
li button{margin-left:auto}
.who{display:flex;gap:.5rem;align-items:center;color:#555}
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
    ids: List[Int], titles: List[String], user: String, csrf: String, error: String
) raises -> String:
    """The `items` fragment: the form, the error if there is one, the list,
    and who is signed in."""
    var f = Frag(ROOT_ID)
    f.raw(f.el("form", "post", ITEMS, attr("class", "new"),
        csrf_input(csrf),
        void("input", attr("name", "title") + attr("placeholder", "a new item")),
        el("button", "", "Add"),
    ))
    if error.byte_length() > 0:
        f.raw(el("p", attr("role", "alert"), text(error)))
    var rows = String()
    for i in range(len(ids)):
        var url = url_for(ITEM, String(ids[i]))
        rows += el("li", "",
            f.el("a", "get", url, attr("href", url), text(titles[i])),
            f.el("button", "delete", url, attr("aria-label", "delete"), "&times;",
                 header=csrf_header(csrf)),
        )
    f.raw(el("ul", "", rows))
    if len(ids) == 0:
        f.raw(el("p", "", text("nothing yet")))
    # A div, not a p: `p` takes phrasing content only, and a `form` is flow
    # content -- a browser would close the paragraph before it.
    f.raw(el("div", attr("class", "who"),
        text(String("signed in as ", user)),
        el("form", attr("method", "post") + attr("action", LOGOUT),
            csrf_input(csrf),
            el("button", "", "Sign out"),
        ),
    ))
    return f^.finish()


def render_login(error: String) raises -> String:
    """The login form, as the same fragment the list occupies, so the 401 a
    signed-out swap gets lands where the list was. A plain form: it posts
    as a navigation, and the 303 that answers it moves the address bar."""
    var f = Frag(ROOT_ID)
    f.raw(el("h1", "", "Sign in"))
    if error.byte_length() > 0:
        f.raw(el("p", attr("role", "alert"), text(error)))
    f.raw(el("form", attr("class", "login") + attr("method", "post") + attr("action", LOGIN),
        void("input", attr("name", "user") + attr("autocomplete", "username")
                      + attr("placeholder", "user")),
        void("input", attr("name", "password") + attr("type", "password")
                      + attr("autocomplete", "current-password")
                      + attr("placeholder", "password")),
        el("button", "", "Sign in"),
    ))
    return f^.finish()


def render_item(title: String) raises -> String:
    """The same fragment showing one item, so a swap lands in the same place."""
    var f = Frag(ROOT_ID)
    f.raw(el("h1", "", text(title)))
    f.raw(el("p", "", f.el("a", "get", ITEMS, attr("href", ITEMS), text("all items"))))
    return f^.finish()


def render_missing() raises -> String:
    """A 404 a person may see is the fragment too."""
    var f = Frag(ROOT_ID)
    f.raw(el("p", attr("role", "alert"), text("no item with this id")))
    f.raw(el("p", "", f.el("a", "get", ITEMS, attr("href", ITEMS), text("all items"))))
    return f^.finish()
