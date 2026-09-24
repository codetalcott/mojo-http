"""The page: a stage of fixed slots that the stream's signals draw.

Nothing on the page computes a shape. Slot `k` is a full-stage `div`
whose `clip-path` is bound to the `_bk` signal, so each step's frame
reshapes every slot at once, and `transition: clip-path` interpolates
between frames — CSS does that only between polygons with the same vertex
count, which is why the kernel always emits `NVERT` of them. The
transition runs for one producer period, carried as `_period_ms`, so the
motion stays smooth when the producer slows down for an idle stage.

The click action is written by hand rather than through `Fragment`: it
computes where the stage was clicked before posting, and it narrows what
it posts. A Datastar fetch sends every signal whose name does not start
with `_`; the slots are underscored, and `filterSignals` keeps the body to
`x` and `y` regardless.

`retry: 'always'` on the stream is what brings a tab back after a
deploy: Datastar 1.0.4's default retries only network and stream errors,
and a draining server closes cleanly.

The footer is `about.mojo`'s, rendered from the image's own facts, and
empty outside an image; the page is rendered once per handler, since
nothing in it varies by request.
"""

from m0_http import attr, el

from blobs.kernel import SLOTS
from blobs.routes import DROP, EVENTS

# Pinned deliberately, as in apps/datastar_todo (D20).
comptime DATASTAR_CDN = "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.4/bundles/datastar.js"

comptime CLICK = (
    "$x = Math.round((evt.clientX - el.getBoundingClientRect().left)"
    " / el.getBoundingClientRect().width * 1000) / 10;"
    " $y = Math.round((evt.clientY - el.getBoundingClientRect().top)"
    " / el.getBoundingClientRect().height * 1000) / 10;"
    " @post('" + DROP + "', {filterSignals: {include: /^(x|y)$/}})"
)


def initial_signals() -> String:
    """Every signal the page reads, declared: `x`/`y` and the underscored rest.

    Reading an undeclared signal creates it as `""`, and a created signal
    without an underscore would ride every click.
    """
    var s = String('{"x":0,"y":0')
    for k in range(SLOTS):
        s += String(',"_b', k, '":""')
    s += ',"_step_us":0,"_viewers":0,"_blobs":0,"_period_ms":100}'
    return s^


def render_stage() raises -> String:
    """The stage and its `SLOTS` slot elements."""
    var slots = String()
    for k in range(SLOTS):
        var signal = String("$_b", k)
        slots += el(
            "div",
            attr("id", String("b", k))
            + attr("class", "blob")
            + attr("style", String("--hue:", (k * 360) // SLOTS))
            + attr("data-style:clip-path", signal)
            + attr("data-show", signal + " != ''"),
        )
    return el(
        "div",
        attr("id", "stage")
        + attr("data-on:click", CLICK)
        + attr("data-style:--period", "$_period_ms + 'ms'"),
        slots,
    )


def render_page(footer: String) raises -> String:
    """The whole document. Every shape arrives over the stream."""
    return String(
        "<!doctype html>\n"
        '<html lang="en">\n'
        "<head>\n"
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        "<title>blobs</title>\n"
        '<script type="module" src="', DATASTAR_CDN, '"></script>\n',
        _STYLE,
        "</head>\n",
        "<body",
        attr("data-signals", initial_signals()),
        attr("data-init", String("@get('", EVENTS, "', {retry: 'always'})")),
        ">\n<main>\n"
        "<h1>blobs</h1>\n"
        '<p class="sub">One world, computed in Mojo on the server and '
        "pushed to every open tab. Click to drop a blob; everyone sees it.</p>\n",
        render_stage(),
        '\n<p class="meta">step <span data-text="$_step_us"></span> µs'
        ' · <span data-text="$_blobs"></span> blobs'
        ' · <span data-text="$_viewers"></span> watching</p>\n',
        footer,
        "</main>\n"
        "</body>\n"
        "</html>\n",
    )


comptime _STYLE = """<style>
  :root { color-scheme: dark; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, sans-serif;
    background: #0d0b12; color: #e8e4f0;
  }
  main { padding: 1.5rem; width: min(92vw, 34rem); }
  h1 { font-size: 1.2rem; font-weight: 600; margin: 0 0 .25rem; }
  .sub, .meta { color: #a49cb4; font-size: .85rem; margin: 0 0 1rem; }
  .meta { margin: .75rem 0 0; font-variant-numeric: tabular-nums; }
  .foot { display: block; margin: 1.5rem 0 0; color: #6f6782; font-size: .75rem; }
  .foot a { color: inherit; }
  #stage {
    position: relative; width: 100%; aspect-ratio: 1; cursor: crosshair;
    background: radial-gradient(circle at 50% 40%, #1d1628, #0d0b12 75%);
    border: 1px solid #2a2338; border-radius: 12px; overflow: hidden;
    --period: 100ms;
  }
  .blob {
    position: absolute; inset: 0; pointer-events: none;
    background: hsl(var(--hue) 85% 62% / .72);
    mix-blend-mode: screen;
    transition: clip-path var(--period) linear;
  }
</style>
"""
