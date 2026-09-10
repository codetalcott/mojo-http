"""Contexts and the templates that render them.

Django's `TemplateResponse` exists so a view can return the template name
and a context `dict` without rendering, leaving the response inspectable by
tests and middleware. Mojo has no `dict[str, Any]` to carry that context, so
the mechanism does not port. Its purpose does, and gets stricter on the way:

- a **context** is a struct — the data a page needs, with no HTTP in it
- a **template** is a function from that struct to a `String`

A missing context field is then a compile error rather than a template
variable that silently renders empty, and rendering is testable by calling
the function. What is lost is late binding: middleware cannot rewrite the
context of a response on its way out, because by then it is bytes. Nothing
in this framework wanted to.

Every value interpolated here goes through `escape_html`. These pages render
whatever a POST body carried, and one unescaped `<script>` is stored XSS in
every browser that views the page, not a formatting nit.
"""

from m0_core.html_escape import escape_html


struct NotePage(Copyable, Movable):
    """One note, as a page needs it."""

    var id: Int
    var title: String
    var body: String

    def __init__(out self, id: Int, var title: String, var body: String):
        self.id = id
        self.title = title^
        self.body = body^


struct IndexPage(Movable):
    """The note list. Ids and titles only — the bodies are not on this page."""

    var ids: List[Int]
    var titles: List[String]

    def __init__(out self, var ids: List[Int], var titles: List[String]):
        self.ids = ids^
        self.titles = titles^


def render_note(ctx: NotePage) -> String:
    """The note detail template."""
    return String(
        "<!doctype html><title>",
        escape_html(ctx.title),
        '</title><article><h1>',
        escape_html(ctx.title),
        "</h1><p>",
        escape_html(ctx.body),
        '</p></article><p><a href="/notes">all notes</a></p>',
    )


def render_index(ctx: IndexPage) -> String:
    """The note list template."""
    var out = String("<!doctype html><title>notes</title><h1>notes</h1><ul>")
    for i in range(len(ctx.ids)):
        out += String(
            '<li><a href="/notes/',
            ctx.ids[i],
            '">',
            escape_html(ctx.titles[i]),
            "</a></li>",
        )
    out += "</ul>"
    if len(ctx.ids) == 0:
        out += "<p>none yet</p>"
    return out


def render_missing(path: String) -> String:
    """The 404 page. A 404 an app wants to style is a page like any other."""
    return String(
        "<!doctype html><title>not found</title><h1>404</h1><p>",
        escape_html(path),
        ' does not exist.</p><p><a href="/notes">all notes</a></p>',
    )
