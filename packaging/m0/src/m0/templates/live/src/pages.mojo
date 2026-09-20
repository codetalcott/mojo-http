"""Rendering: the routes, the live fragment, the frame and the document.

ONE renderer serves both transports: `render_live` is what the document
holds at first paint and, verbatim, the `elements` of every frame the
producer publishes. Datastar morphs a patch into the element whose id it
carries, so the fragment's own id is the whole of the targeting.

Every frame is the FULL state, never a delta. A viewer whose 64 KB outbox
overflows misses frames; a missed full frame is healed by the next one, a
missed delta would leave that screen wrong forever.
"""

from m0_datastar.sse import patch_elements
from m0_http import Datastar, Fragment, attr, el, text

# Pinned: a floating version lets an upstream release break this app
# without a commit here.
comptime DATASTAR_CDN = "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.3/bundles/datastar.js"

comptime PAGE = "/"
comptime EVENTS = "/events"
comptime KICK = "/kick"
comptime STATS = "/stats"
comptime HEALTH = "/health"

comptime ROOT_ID = "live"
comptime BARS = 12

comptime Frag = Fragment[Datastar]

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:36rem;margin:2rem auto;padding:0 1rem}
.bars{display:flex;gap:4px;align-items:flex-end;height:8rem;margin:1rem 0}
.bars i{flex:1;background:#5b6ee1;border-radius:3px 3px 0 0;transition:height .4s linear}
.meta{color:#666;font-size:.85rem;font-variant-numeric:tabular-nums}
</style>"""


def render_live(step: Int, heights: List[Int], viewers: Int) raises -> String:
    """The `live` fragment: the bars, the readout, the button.

    `heights` are percentages, clamped here: a renderer is the last place
    to trust a number that becomes CSS.
    """
    var f = Frag(ROOT_ID)
    var bars = String()
    for i in range(len(heights)):
        var h = heights[i]
        h = 0 if h < 0 else (100 if h > 100 else h)
        bars += el("i", attr("style", String("height:", h, "%")))
    f.raw(el("div", attr("class", "bars"), bars))
    f.raw(el("p", attr("class", "meta"),
        text(String("step ", step, " · ", viewers, " watching")),
    ))
    # `f.el` writes the click action: data-on:click="@post('/kick')".
    f.raw(f.el("button", "post", KICK, "", text("Kick")))
    return f^.finish()


def state_frame(
    event_id: Int, step: Int, heights: List[Int], viewers: Int
) raises -> String:
    """One `datastar-patch-elements` SSE frame carrying the whole fragment."""
    return patch_elements(
        elements=render_live(step, heights, viewers),
        event_id=String(event_id),
    )


def render_page() raises -> String:
    """The whole document. `retry: 'always'` is what brings a tab back
    after a deploy: a draining server closes the stream cleanly, and
    Datastar's default retries only errors."""
    var still = List[Int](length=BARS, fill=0)
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
        render_live(0, still, 0),
        "\n</main>\n</body>\n</html>\n",
    )
