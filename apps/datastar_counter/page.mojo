"""The single HTML page served by the counter demo.

Built as a Mojo string rather than read from disk, so the app stays a single
binary with no static-file dependency and no `open()` in the request path.
"""

# Pinned deliberately: a floating CDN version would let an upstream release
# break this example without a commit here. Matches the protocol version
# m0-datastar implements (v1.0.2).
comptime DATASTAR_CDN = "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.2/bundles/datastar.js"


def render_page(count: Int) -> String:
    """Full HTML document with the current count already rendered.

    `data-signals` seeds the client store, `data-init` opens the SSE stream,
    and the two buttons POST the signal store back. After that every update
    arrives over the stream — including updates caused by *other* tabs.
    """
    return String(
        '<!doctype html>\n'
        '<html lang="en">\n'
        '<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        '<title>mojo-http · Datastar counter</title>\n'
        '<script type="module" src="', DATASTAR_CDN, '"></script>\n',
        _STYLE,
        '</head>\n'
        '<body data-signals=\'{"count":', String(count), '}\' '
        # data-init, not the pre-1.0 data-on-load: v1.0.2 has no on-load
        # plugin, and the misnamed attribute fails silently.
        'data-init="@get(\'/events\')">\n'
        '<main>\n'
        '<h1>Datastar counter</h1>\n'
        '<p class="sub">Served by <code>mojo-http</code>. '
        'Open this page in two tabs — both track the same number.</p>\n'
        '<output id="count" data-text="$count">', String(count), '</output>\n'
        '<div class="row">\n'
        '<button data-on:click="@post(\'/decrement\')">−1</button>\n'
        '<button data-on:click="@post(\'/increment\')">+1</button>\n'
        '</div>\n'
        '<p class="hint">The buttons POST the signal store. The new value comes '
        'back to <em>every</em> connected tab over one SSE stream.</p>\n'
        '</main>\n'
        '</body>\n'
        '</html>\n'
    )


comptime _STYLE = """<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, sans-serif;
    background: Canvas; color: CanvasText;
  }
  main { text-align: center; padding: 2rem; }
  h1 { font-size: 1.25rem; font-weight: 600; margin: 0 0 .5rem; }
  .sub, .hint { color: color-mix(in srgb, CanvasText 60%, Canvas); font-size: .875rem; }
  .sub { margin: 0 0 2rem; }
  .hint { margin: 2rem auto 0; max-width: 34ch; }
  output {
    display: block; font-size: 4rem; font-weight: 650;
    font-variant-numeric: tabular-nums; letter-spacing: -.02em;
  }
  .row { display: flex; gap: .5rem; justify-content: center; margin-top: 1.5rem; }
  button {
    font: inherit; font-weight: 550; padding: .5rem 1.25rem; min-width: 5rem;
    border: 1px solid color-mix(in srgb, CanvasText 25%, Canvas);
    border-radius: .5rem; background: Canvas; color: CanvasText; cursor: pointer;
  }
  button:hover { background: color-mix(in srgb, CanvasText 8%, Canvas); }
  button:active { transform: translateY(1px); }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; }
</style>
"""
