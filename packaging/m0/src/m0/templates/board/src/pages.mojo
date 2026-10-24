"""Rendering: the routes, the two fragments and the document.

ONE renderer serves both transports: `render_board` is what the document
holds at first paint and, verbatim, the `elements` of every frame `post`
sends. Datastar morphs a patch into the element whose id it carries, so the
fragment's own id is the whole of the targeting.

The form is a fragment of its own, outside the board: a frame replaces the
board in every tab, and a visitor halfway through a message keeps it.

An element is a call: `Li(message)`, `P("nothing yet", cls="meta")`. A
bare string child is TEXT and escaped, and a keyword is an attribute
(`cls` for `class`, `data_bind` for `data-bind`). The document around the
fragments is the `Html` builder.
"""

from m0_http import Datastar, El, Fragment, Html
from m0_http.tags import H1, Button, Input, Li, P, Ul

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

# A frame bigger than a slot's outbox is refused for every slot, however
# empty: `MAX_PENDING_BYTES` in m0-http's `sse/registry.mojo`, not exported
# from `m0_http`, so it is spelled again here.
comptime OUTBOX_BYTES = 65536
# What the framing adds to the rendered board: the event and id lines, the
# closing blank line, the wrapper elements, and `data: elements ` once on
# the first line. 512 is more than twice that; every further line of a
# message is counted by `_framing_bytes`.
comptime FRAME_MARGIN = 512
comptime BOARD_BUDGET = OUTBOX_BYTES - FRAME_MARGIN
# `data: elements `: Datastar's SSE framing writes it before EVERY line of
# the fragment, and a message may hold line breaks (a textarea, or curl).
comptime _DATA_PREFIX = 15

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:36rem;margin:2rem auto;padding:0 1rem}
form{display:flex;gap:.5rem;margin-bottom:1rem}
input{font:inherit;padding:.4rem;flex:1}
ul{list-style:none;padding:0}
li{padding:.4rem 0;border-bottom:1px solid #eee;white-space:pre-wrap}
.meta{color:#666;font-size:.85rem}
</style>"""


def _framing_bytes(row: String) -> Int:
    """What the frame spends on `row` beyond its own bytes: the `data:` prefix
    of every line break it holds (CR, LF and CRLF each start a line, and
    counting both bytes of a CRLF only over-counts)."""
    var extra = 0
    for b in row.as_bytes():
        if b == UInt8(ord("\n")) or b == UInt8(ord("\r")):
            extra += _DATA_PREFIX
    return extra


def render_board(messages: List[String]) raises -> String:
    """The `board` fragment: the newest messages that fit, newest first,
    each escaped.

    A full-state frame must fit the 64 KB outbox of a slot, or no tab is
    sent it at all and the poster still gets a 200. Fifty messages of 1500
    bytes, each byte escaped to six, are far over it, so the oldest are left
    out of the render (the list keeps them) until `BOARD_BUDGET` holds.
    """
    var f = Frag(BOARD_ID)
    if len(messages) == 0:
        f.raw(P("nothing yet", cls="meta"))
        return f^.finish()
    var rows = List[El]()
    var used = 0
    for i in range(len(messages) - 1, -1, -1):
        var row = Li(messages[i])
        var cost = row.byte_length() + _framing_bytes(row.html())
        if used + cost > BOARD_BUDGET:
            break
        used += cost
        rows.append(row^)
    f.raw(Ul(rows))
    return f^.finish()


def render_compose() raises -> String:
    """The `compose` fragment: the form.

    `f.element` writes the submit action,
    `data-on:submit__prevent="@post('/messages', {contentType: 'form'})"`,
    which posts the form's fields urlencoded and no signals.
    `data_bind="text"` ties the field to `$text`, which `post`'s answer
    empties: Datastar takes the signal from the value when the attribute
    has no `:key`, and a keyword cannot spell a `:`. `Input` is a void
    element, so it takes no children and writes no `</input>`.
    """
    var f = Frag(COMPOSE_ID)
    f.raw(f.element("form", "post", MESSAGES,
        Input(
            name="text", data_bind="text", required=True, maxlength=500,
            autocomplete="off", placeholder="say something",
        ),
        Button("Post"),
    ))
    return f^.finish()


def render_page(messages: List[String]) raises -> String:
    """The whole document. `retry: 'always'` is what brings a tab back
    after a restart: a draining server closes the stream cleanly, and
    Datastar's default retries only errors."""
    var h = Html(4096)
    h.raw('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n')
    h.raw('<meta name="viewport" content="width=device-width,initial-scale=1">\n')
    h.open("title")
    h.text("__M0_APP__")
    h.close("title")
    h.raw("\n")
    h.open("script")
    h.attr("type", "module")
    h.attr("src", DATASTAR_CDN)
    h.close("script")
    h.raw("\n")
    h.raw(_STYLE)
    h.raw("\n</head>\n")
    h.open("body")
    h.attr("data-init", String("@get('", EVENTS, "', {retry: 'always'})"))
    h.raw("\n<main>\n")
    h.raw(H1("__M0_APP__"))
    h.raw("\n")
    h.raw(render_compose())
    h.raw("\n")
    h.raw(render_board(messages))
    h.raw("\n</main>\n</body>\n</html>\n")
    return h^.finish()
