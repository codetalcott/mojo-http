"""HTML for the todo demo: the full page, and the fragment that gets patched.

Built as Mojo strings rather than read from disk, so the app stays a single
binary with no static-file dependency and no `open()` in the request path.

`render_todos` is the important one: it renders `<section id="todos">`, which
is both part of the initial page *and* the broadcast payload after every
mutation. Datastar's default patch mode morphs elements by id, so one
`patch_elements` frame updates the list in every connected tab. The fragment
is a single line on purpose — SSE is line-framed, and a one-line fragment
keeps every broadcast a single `data: elements` line; `Fragment` emits no
newline unless told, so the builder keeps that property for free.

It is built on `Fragment[Datastar]` — the same `Fragment` that
`apps/fragment_notes` instantiates as `Fragment[Htmx]`. One renderer, two
transports: this one's output goes out as the `elements` line of a
broadcast frame to every tab, and would go out unchanged as the
`text/html` body of a `@post` action's response; the only line here that
knows which frontend library is in the page is `Frag` below. Nothing in
this file types a `data-on` attribute.
"""

from m0_http import Datastar, Fragment, url_for

from datastar_todo.routes import ADD, DELETE, EVENTS, TOGGLE

# Pinned deliberately: a floating CDN version would let an upstream release
# break this example without a commit here. Matches the protocol version
# m0-datastar implements (v1.0.3).
comptime DATASTAR_CDN = "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.3/bundles/datastar.js"


# The vocabulary, named once. This app's fragment speaks Datastar; the
# page's own `data-init`/`data-bind` attributes are written by hand because
# they are the page's, not the fragment's.
comptime Frag = Fragment[Datastar]

# Escaping is the builder's (`text`, `attr`) and comes from m0-core. A local
# escaper once rebuilt every byte with `chr(Int(b))`, promoting each UTF-8
# continuation byte to its own codepoint — a todo reading `café` displayed
# as `cafÃ©` in the page and in every broadcast. The XSS defense was sound;
# the mangling was the bug, and one shared implementation keeps it fixed.


def render_todos(
    ids: List[Int], texts: List[String], done: List[Bool]
) raises -> String:
    """The `<section id="todos">` fragment: list plus remaining count.

    Rendered into the initial page and broadcast verbatim after every
    mutation. Single line — see the module docstring. Each button's
    action is `swap`, generated from the route pattern; `Frag` decides
    that it is spelled `data-on:click__prevent="@post('/toggle/7')"`.
    """
    var remaining = 0
    for i in range(len(done)):
        if not done[i]:
            remaining += 1

    var f = Frag("todos")
    f.open("ul")
    for i in range(len(ids)):
        var id = String(ids[i])
        f.open("li")
        f.open("button")
        f.attr("class", "toggle")
        f.swap("post", url_for(TOGGLE, id))
        if done[i]:
            f.raw("&#9745;")
        else:
            f.raw("&#9744;")
        f.close("button")
        if done[i]:
            f.open("s")
            f.text(texts[i])
            f.close("s")
        else:
            f.open("span")
            f.text(texts[i])
            f.close("span")
        f.open("button")
        f.attr("class", "delete")
        f.swap("post", url_for(DELETE, id))
        f.raw("&times;")
        f.close("button")
        f.close("li")
    f.close("ul")
    f.open("p")
    f.text(String(remaining, " left"))
    f.close("p")
    return f^.finish()


def render_page(
    ids: List[Int], texts: List[String], done: List[Bool]
) raises -> String:
    """Full HTML document with the current list already rendered.

    `data-signals` seeds the draft input's signal, `data-init` opens the
    SSE stream. Everything after first paint arrives as broadcasts — including
    mutations made by *other* tabs.
    """
    return String(
        "<!doctype html>\n"
        '<html lang="en">\n'
        "<head>\n"
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        "<title>mojo-http · Datastar todos</title>\n"
        '<script type="module" src="', DATASTAR_CDN, '"></script>\n',
        _STYLE,
        "</head>\n"
        # data-init, not the pre-1.0 data-on-load: v1.0.x has no on-load
        # plugin, and the misnamed attribute fails silently — nothing opens
        # the stream and nothing errors. Verified against the bundle.
        #
        # retry: 'always' is what makes replay-across-restart real in a
        # browser: with the default 'auto', v1.0.x treats a clean stream
        # close — which a dying server produces — as an intentional end and
        # never reconnects. 'always' retries with backoff and re-sends the
        # last seen id as `last-event-id`, and the server catches the tab up
        # from its persisted journal. Also verified against the bundle.
        '<body data-signals=\'{"draft":""}\''
        ' data-init="@get(\'', EVENTS, '\', {retry: \'always\'})">\n'
        "<main>\n"
        "<h1>Todos, in every tab at once</h1>\n"
        '<p class="sub">Served by <code>mojo-http</code>. Open two tabs; '
        "add or toggle in one, watch the other.</p>\n"
        '<div class="row">\n'
        # Keyed attributes are colon-separated in v1.0.x (data-on:keydown,
        # data-bind:draft): the bundle parses plugin and key with
        # `name.split(/:(.+)/)`, so the hyphen forms name a nonexistent
        # plugin and fail silently. No __key modifiers either; the event is
        # `evt` in the expression, so Enter filtering is ordinary JS.
        '<input data-bind:draft placeholder="What needs doing?" '
        "data-on:keydown=\"evt.key === 'Enter' && (@post('", ADD, "'), $draft = '')\">\n"
        "<button data-on:click=\"@post('", ADD, "'); $draft = ''\">Add</button>\n"
        "</div>\n",
        render_todos(ids, texts, done),
        "\n"
        '<p class="hint">Each mutation broadcasts one patch-elements frame; '
        "Datastar morphs <code>#todos</code> by id in every subscriber.</p>\n"
        "</main>\n"
        "</body>\n"
        "</html>\n",
    )


comptime _STYLE = """<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, sans-serif;
    background: Canvas; color: CanvasText;
  }
  main { padding: 2rem; min-width: 20rem; max-width: 28rem; }
  h1 { font-size: 1.25rem; font-weight: 600; margin: 0 0 .5rem; }
  .sub, .hint { color: color-mix(in srgb, CanvasText 60%, Canvas); font-size: .875rem; }
  .sub { margin: 0 0 1.5rem; }
  .hint { margin: 1.5rem 0 0; }
  .row { display: flex; gap: .5rem; }
  .row input { flex: 1; padding: .4rem .6rem; }
  ul { list-style: none; padding: 0; margin: 1rem 0 0; }
  li { display: flex; align-items: center; gap: .5rem; padding: .25rem 0; }
  li span, li s { flex: 1; }
  li s { opacity: .55; }
  button { cursor: pointer; }
  .toggle, .delete { background: none; border: none; font-size: 1rem; }
  .delete { opacity: .5; }
  .delete:hover { opacity: 1; }
</style>
"""
