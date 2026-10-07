"""Rendering: the routes, the two fragments and the document.

ONE renderer serves both transports: `render_board` is what the document
holds at first paint and, verbatim, the `elements` of every frame `post`
sends. Datastar morphs a patch into the element whose id it carries, so the
fragment's own id is the whole of the targeting.

The form is a fragment of its own, outside the board: a frame replaces the
board in every tab, and a visitor halfway through a message keeps it.
"""

from m0_http import Datastar, Fragment, attr, el, flag, text, void

# Pinned: a floating version lets an upstream release break this app
# without a commit here.
comptime DATASTAR_CDN = "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.4/bundles/datastar.js"

# The routes, written once: given to the table in `views.mojo` and used
# below, so a misspelled route is a compile error.
comptime PAGE = "/"
comptime EVENTS = "/events"
comptime MESSAGES = "/messages"
comptime HEALTH = "/health"

comptime BOARD_ID = "board"
comptime COMPOSE_ID = "compose"

comptime Frag = Fragment[Datastar]

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:36rem;margin:2rem auto;padding:0 1rem}
form{display:flex;gap:.5rem;margin-bottom:1rem}
input{font:inherit;padding:.4rem;flex:1}
ul{list-style:none;padding:0}
li{padding:.4rem 0;border-bottom:1px solid #eee;white-space:pre-wrap}
.meta{color:#666;font-size:.85rem}
</style>"""


def render_board(messages: List[String]) raises -> String:
    """The `board` fragment: every message, newest first, each escaped."""
    var f = Frag(BOARD_ID)
    if len(messages) == 0:
        f.raw(el("p", attr("class", "meta"), text("nothing yet")))
        return f^.finish()
    var rows = String()
    for i in range(len(messages) - 1, -1, -1):
        rows += el("li", "", text(messages[i]))
    f.raw(el("ul", "", rows))
    return f^.finish()


def render_compose() raises -> String:
    """The `compose` fragment: the form.

    `f.el` writes the submit action,
    `data-on:submit__prevent="@post('/messages', {contentType: 'form'})"`,
    which posts the form's fields urlencoded and no signals. `data-bind:text`
    ties the field to `$text`, which `post`'s answer empties. An `<input>`
    is a void element: `void` writes it, where `el` would close it.
    """
    var f = Frag(COMPOSE_ID)
    f.raw(f.el("form", "post", MESSAGES, "",
        void("input",
            attr("name", "text") + flag("data-bind:text") + flag("required")
            + attr("maxlength", "500") + attr("autocomplete", "off")
            + attr("placeholder", "say something"),
        ),
        el("button", "", "Post"),
    ))
    return f^.finish()


def render_page(messages: List[String]) raises -> String:
    """The whole document. `retry: 'always'` is what brings a tab back
    after a restart: a draining server closes the stream cleanly, and
    Datastar's default retries only errors."""
    return String(
        '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n',
        el("title", "", text("__M0_APP__")),
        '\n<script type="module" src="', DATASTAR_CDN, '"></script>\n',
        _STYLE,
        "\n</head>\n<body",
        attr("data-init", String("@get('", EVENTS, "', {retry: 'always'})")),
        ">\n<main>\n",
        el("h1", "", text("__M0_APP__")),
        "\n",
        render_compose(),
        "\n",
        render_board(messages),
        "\n</main>\n</body>\n</html>\n",
    )
