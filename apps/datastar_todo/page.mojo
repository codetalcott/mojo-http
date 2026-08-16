"""HTML for the todo demo: the full page, and the fragment that gets patched.

Built as Mojo strings rather than read from disk, so the app stays a single
binary with no static-file dependency and no `open()` in the request path.

`render_todos` is the important one: it renders `<section id="todos">`, which
is both part of the initial page *and* the broadcast payload after every
mutation. Datastar's default patch mode morphs elements by id, so one
`patch_elements` frame updates the list in every connected tab. The fragment
is a single line on purpose — SSE is line-framed, and a one-line fragment
keeps every broadcast a single `data: elements` line.
"""

# Pinned deliberately: a floating CDN version would let an upstream release
# break this example without a commit here. Matches the protocol version
# m0-datastar implements (v1.0.2).
comptime DATASTAR_CDN = "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.2/bundles/datastar.js"


def escape_html(s: String) -> String:
    """Escape text for safe interpolation into HTML content.

    Todo text is user input; without this, a note titled `<script>` would run
    in every connected tab — the broadcast would turn stored XSS into
    *distributed* stored XSS.
    """
    var out = String()
    var bytes = s.as_bytes()
    for i in range(s.byte_length()):
        var b = bytes[i]
        if b == UInt8(ord("&")):
            out += "&amp;"
        elif b == UInt8(ord("<")):
            out += "&lt;"
        elif b == UInt8(ord(">")):
            out += "&gt;"
        elif b == UInt8(ord('"')):
            out += "&quot;"
        elif b == UInt8(ord("'")):
            out += "&#39;"
        else:
            out += String(chr(Int(b)))
    return out^


def render_todos(
    ids: List[Int], texts: List[String], done: List[Bool]
) raises -> String:
    """The `<section id="todos">` fragment: list plus remaining count.

    Rendered into the initial page and broadcast verbatim after every
    mutation. Single line — see the module docstring.
    """
    var remaining = 0
    for i in range(len(done)):
        if not done[i]:
            remaining += 1

    var out = String('<section id="todos"><ul>')
    for i in range(len(ids)):
        var id = ids[i]
        out += String('<li><button class="toggle" data-on:click="@post(', "'/toggle/", id, "'", ')">')
        if done[i]:
            out += "&#9745;"
        else:
            out += "&#9744;"
        out += "</button>"
        if done[i]:
            out += String("<s>", escape_html(texts[i]), "</s>")
        else:
            out += String("<span>", escape_html(texts[i]), "</span>")
        out += String('<button class="delete" data-on:click="@post(', "'/delete/", id, "'", ')">&times;</button></li>')
    out += String("</ul><p>", remaining, " left</p></section>")
    return out^


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
        # data-init, not the pre-1.0 data-on-load: v1.0.2 has no on-load
        # plugin, and the misnamed attribute fails silently — nothing opens
        # the stream and nothing errors. Verified against the bundle.
        '<body data-signals=\'{"draft":""}\' data-init="@get(\'/events\')">\n'
        "<main>\n"
        "<h1>Todos, in every tab at once</h1>\n"
        '<p class="sub">Served by <code>mojo-http</code>. Open two tabs; '
        "add or toggle in one, watch the other.</p>\n"
        '<div class="row">\n'
        # Keyed attributes are colon-separated in v1.0.2 (data-on:keydown,
        # data-bind:draft): the bundle parses plugin and key with
        # `name.split(/:(.+)/)`, so the hyphen forms name a nonexistent
        # plugin and fail silently. No __key modifiers either; the event is
        # `evt` in the expression, so Enter filtering is ordinary JS.
        '<input data-bind:draft placeholder="What needs doing?" '
        "data-on:keydown=\"evt.key === 'Enter' && (@post('/add'), $draft = '')\">\n"
        "<button data-on:click=\"@post('/add'); $draft = ''\">Add</button>\n"
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
