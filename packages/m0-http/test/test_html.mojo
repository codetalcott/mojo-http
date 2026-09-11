"""The HTML builder and the fragment that names itself (`src/html.mojo`).

What is pinned: `attr` owns the delimiters and escapes what goes between
them, `text` escapes and `raw` does not, a start tag is ended by whatever
follows it, a fragment's root id and the attribute that targets it are
one value used twice, and the two vocabularies spell that attribute from
the same call — `Fragment[Htmx]` and `Fragment[Datastar]` differ in the
type parameter and in nothing an app writes.
"""

from std.testing import TestSuite, assert_equal, assert_true

from src.html import Datastar, Fragment, Html, Htmx, attr, el, flag, text, void


def test_attr_owns_the_delimiters_and_escapes_the_value() raises:
    var h = Html()
    h.open("a")
    h.attr("href", String("/notes?q=<x>&r=\"y\""))
    h.text("link")
    h.close("a")
    assert_equal(
        h^.finish(),
        '<a href="/notes?q=&lt;x&gt;&amp;r=&quot;y&quot;">link</a>',
    )


def test_text_escapes_and_raw_does_not() raises:
    var h = Html()
    h.open("p")
    h.text("<script>alert(1)</script>")
    h.raw("<b>ok</b>")
    h.close("p")
    assert_equal(
        h^.finish(), "<p>&lt;script&gt;alert(1)&lt;/script&gt;<b>ok</b></p>"
    )


def test_a_start_tag_is_ended_by_whatever_follows() raises:
    """A void element needs no call of its own: `open` ends the previous
    start tag, and so do `text`, `raw` and `close`."""
    var h = Html()
    h.open("input")
    h.attr("name", "title")
    h.flag("required")
    h.open("br")
    h.open("span")
    h.text("x")
    h.close("span")
    assert_equal(h^.finish(), '<input name="title" required><br><span>x</span>')


def test_finish_ends_an_open_start_tag() raises:
    var h = Html()
    h.open("hr")
    assert_equal(h^.finish(), "<hr>")


def test_attr_outside_an_element_raises() raises:
    """An attribute emitted into text content would render as text; that
    silent shape is what the error replaces."""
    var h = Html()
    h.open("p")
    h.text("t")
    var raised = False
    try:
        h.attr("class", "x")
    except:
        raised = True
    assert_true(raised)


def test_non_ascii_passes_through_both_paths() raises:
    """The continuation-byte regression the todo demo's escaper shipped,
    pinned on the builder: `café` is those bytes in text and in a value."""
    var h = Html()
    h.open("i")
    h.attr("title", "café")
    h.text("café")
    h.close("i")
    assert_equal(h^.finish(), '<i title="café">café</i>')


def test_fragment_emits_its_id_once_and_targets_it() raises:
    """The pattern: the root id is written once, by the constructor, and
    `swap` generates the targeting attribute from the same id. Nothing in
    the fragment's own markup carries the id a second time except through
    that generator.

    covers: N3
    """
    var f = Fragment[Htmx]("notes")
    assert_equal(f.selector(), "#notes")
    f.open("form")
    f.swap("post", "/notes")
    f.close("form")
    var out = f^.finish()
    assert_equal(
        out,
        '<section id="notes"><form hx-post="/notes" hx-target="#notes"'
        ' hx-swap="outerHTML"></form></section>',
    )


def test_fragment_root_tag_is_the_callers() raises:
    var f = Fragment[Htmx]("todos", tag="ul")
    f.open("li")
    f.text("one")
    f.close("li")
    assert_equal(f^.finish(), '<ul id="todos"><li>one</li></ul>')


def test_swap_on_a_page_element_uses_the_fragments_selector() raises:
    """A page-level element that swaps a fragment rendered elsewhere gets
    the target from the fragment value, not from a retyped string."""
    var f = Fragment[Htmx]("notes")
    var page = Html()
    page.open("a")
    page.swap[Htmx]("get", "/notes", f.selector())
    page.text("all")
    page.close("a")
    assert_equal(
        page^.finish(),
        '<a hx-get="/notes" hx-target="#notes" hx-swap="outerHTML">all</a>',
    )


def test_an_expression_with_quotes_survives_as_entities() raises:
    """The three-quoting-levels line from the todo demo, as one level: the
    single quotes inside the expression are ordinary characters and come
    out as `&#x27;`, which the HTML parser un-escapes before any expression
    evaluator sees the value."""
    var h = Html()
    h.open("button")
    h.attr("class", "toggle")
    h.attr("data-on:click", String("@post('/toggle/", 7, "')"))
    h.close("button")
    assert_equal(
        h^.finish(),
        '<button class="toggle" data-on:click="@post(&#x27;/toggle/7&#x27;)"></button>',
    )


def test_an_id_that_a_selector_cannot_name_is_refused() raises:
    """`id="note.7"` is a valid DOM id and `#note.7` selects id `note`
    with class `7`; `#7` is a syntax error. The constructor refuses the
    ids for which the element and its target attribute would disagree.

    covers: N3
    """
    for bad in ["note.7", "7", "item:7", "a b", "", "x#y"]:
        var raised = False
        try:
            var f = Fragment[Htmx](bad)
            _ = f^.finish()
        except:
            raised = True
        assert_true(raised, String("accepted `", bad, "`"))
    for good in ["notes", "_x", "a-b_c9", "Todos"]:
        var f = Fragment[Htmx](good)
        assert_equal(f.selector(), String("#", good))
        _ = f^.finish()


def test_datastar_spells_the_action_by_element_and_names_no_target() raises:
    """The same `swap` call, the other vocabulary: a form posts on submit
    with its fields (`contentType: 'form'`), a field on change, a button
    or anchor on a cancelled click, anything else on a plain click — and
    NO target attribute, because Datastar morphs the answer into the
    element whose id it carries, which is the fragment's own.

    covers: N7
    """
    var f = Fragment[Datastar]("notes")
    f.open("form")
    f.swap("post", "/notes")
    f.open("input")
    f.attr("name", "q")
    f.swap("get", "/notes")
    f.close("form")
    f.open("a")
    f.attr("href", "/notes/7")
    f.swap("get", "/notes/7")
    f.close("a")
    f.open("button")
    f.swap("delete", "/notes/7")
    f.close("button")
    f.open("li")
    f.swap("post", "/toggle/7")
    f.close("li")
    var out = f^.finish()
    assert_equal(
        out,
        '<section id="notes">'
        '<form data-on:submit__prevent="@post(&#x27;/notes&#x27;, {contentType: &#x27;form&#x27;})">'
        '<input name="q" data-on:change="@get(&#x27;/notes&#x27;)">'
        "</form>"
        '<a href="/notes/7" data-on:click__prevent="@get(&#x27;/notes/7&#x27;)"></a>'
        '<button data-on:click__prevent="@delete(&#x27;/notes/7&#x27;)"></button>'
        '<li data-on:click="@post(&#x27;/toggle/7&#x27;)"></li>'
        "</section>",
    )
    assert_true(out.find("hx-") < 0)
    assert_true(out.find("target") < 0)


def test_the_two_vocabularies_render_the_same_code() raises:
    """What `Fragment[V]` buys: the renderer below is written once, and
    only the attributes differ between its two instantiations. Everything
    outside a `swap` — the id, the text, the structure — is byte-identical."""
    var a = Fragment[Htmx]("todos")
    a.open("button")
    a.attr("class", "toggle")
    a.swap("post", "/toggle/1")
    a.text("done?")
    a.close("button")
    var d = Fragment[Datastar]("todos")
    d.open("button")
    d.attr("class", "toggle")
    d.swap("post", "/toggle/1")
    d.text("done?")
    d.close("button")
    assert_equal(
        a^.finish(),
        '<section id="todos"><button class="toggle" hx-post="/toggle/1"'
        ' hx-target="#todos" hx-swap="outerHTML">done?</button></section>',
    )
    assert_equal(
        d^.finish(),
        '<section id="todos"><button class="toggle"'
        ' data-on:click__prevent="@post(&#x27;/toggle/1&#x27;)">done?</button></section>',
    )


def test_elements_compose_as_expressions_with_escaping_named() raises:
    """The expression tier: an element is a string, attributes are what
    `attr`/`flag` rendered joined with `+`, and each escaping context is
    the function that names it — `attr` and `text` escape, a bare string
    is markup the caller trusts. Same bytes the builder makes.

    covers: N10
    """
    assert_equal(
        el("li", attr("class", "x") + attr("title", "a<b"), text("<b>"), "&times;"),
        '<li class="x" title="a&lt;b">&lt;b&gt;&times;</li>',
    )
    assert_equal(void("input", attr("name", "t") + flag("required")), '<input name="t" required>')
    assert_equal(el("p", "", "none"), "<p>none</p>")
    assert_equal(el("ul", "", el("li", "", text("1")), el("li", "", text("2"))), "<ul><li>1</li><li>2</li></ul>")
    assert_equal(text("café & <x>"), "café &amp; &lt;x&gt;")
    # The same list, both tiers, byte for byte.
    var h = Html()
    h.open("li")
    h.attr("class", "x")
    h.attr("title", "a<b")
    h.text("<b>")
    h.raw("&times;")
    h.close("li")
    assert_equal(h^.finish(), el("li", attr("class", "x") + attr("title", "a<b"), text("<b>"), "&times;"))


def test_fragment_el_spells_the_swap_from_the_tag_it_is_given() raises:
    """`Fragment.el` is `swap` in the expression tier: the tag is given
    once, to the element being made, and the vocabulary reads it from
    there — a Datastar form submits where its button clicks. Nothing is
    written to the fragment's own buffer.

    covers: N10
    """
    var hx = Fragment[Htmx]("notes")
    assert_equal(
        hx.el("a", "get", "/notes/7", attr("href", "/notes/7"), text("t")),
        '<a href="/notes/7" hx-get="/notes/7" hx-target="#notes" hx-swap="outerHTML">t</a>',
    )
    var ds = Fragment[Datastar]("notes")
    assert_equal(
        ds.el("a", "get", "/notes/7", attr("href", "/notes/7"), text("t")),
        '<a href="/notes/7" data-on:click__prevent="@get(&#x27;/notes/7&#x27;)">t</a>',
    )
    assert_equal(
        ds.el("form", "post", "/notes", "", void("input", attr("name", "q"))),
        '<form data-on:submit__prevent="@post(&#x27;/notes&#x27;, {contentType: &#x27;form&#x27;})">'
        '<input name="q"></form>',
    )
    # The fragment itself is untouched by its expression-form elements.
    assert_equal(hx^.finish(), '<section id="notes"></section>')
    assert_equal(ds^.finish(), '<section id="notes"></section>')


def test_a_datastar_url_that_would_end_the_expression_is_refused() raises:
    """`attr` escapes for the HTML context; the browser un-escapes before
    Datastar evaluates the expression, so a `'` in the URL would close the
    string literal and run what follows. Refused for Datastar, where the
    URL sits inside JavaScript; tolerated for htmx, where it is only an
    attribute value. `%27` is the same URL and passes.

    covers: N7
    """
    for bad in [
        "/notes?q=x') ; alert(1) ; ('",
        "/notes?q=\\",
        "/notes?q=a\nb",
        "/notes?q=a\rb",
    ]:
        var f = Fragment[Datastar]("notes")
        f.open("button")
        var raised = False
        try:
            f.swap("post", bad)
        except:
            raised = True
        assert_true(raised, String("accepted `", bad, "`"))
        _ = f^.finish()
    var ok = Fragment[Datastar]("notes")
    ok.open("button")
    ok.swap("post", "/notes?q=x%27")
    assert_true(ok^.finish().find("@post(&#x27;/notes?q=x%27&#x27;)") >= 0)
    var hx = Fragment[Htmx]("notes")
    hx.open("a")
    hx.swap("get", "/notes?q='")
    assert_true(hx^.finish().find('hx-get="/notes?q=&#x27;"') >= 0)


def test_an_unknown_verb_is_refused_by_both_vocabularies() raises:
    """`hx-psot` is a silent attribute and `@psot(...)` a runtime error;
    a typo is the mistake the layer exists to catch, so it raises."""
    var hx = Fragment[Htmx]("notes")
    hx.open("a")
    var raised = False
    try:
        hx.swap("psot", "/x")
    except:
        raised = True
    assert_true(raised)
    _ = hx^.finish()
    var ds = Fragment[Datastar]("notes")
    ds.open("a")
    raised = False
    try:
        ds.swap("GET", "/x")
    except:
        raised = True
    assert_true(raised)
    _ = ds^.finish()


def test_a_forgotten_attrs_argument_is_refused() raises:
    """`el("p", "none")` used to render `<pnone></p>`, silently. Rendered
    attributes always open with a space, so a child in the attrs slot is
    refused, naming the mistake.

    covers: N10
    """
    var shapes = List[String]()
    shapes.append("none")
    shapes.append(text("hi"))
    shapes.append("<b>x</b>")
    for i in range(len(shapes)):
        var raised = False
        try:
            _ = el("p", shapes[i])
        except:
            raised = True
        assert_true(raised, String("el accepted `", shapes[i], "` as attrs"))
        raised = False
        try:
            _ = void("br", shapes[i])
        except:
            raised = True
        assert_true(raised, String("void accepted `", shapes[i], "` as attrs"))
    var f = Fragment[Htmx]("notes")
    var raised = False
    try:
        _ = f.el("a", "get", "/x", "none")
    except:
        raised = True
    assert_true(raised)
    _ = f^.finish()
    # The intended spellings still work: an empty attrs slot, rendered ones.
    assert_equal(el("p", "", "none"), "<p>none</p>")
    assert_equal(el("p", attr("class", "c"), text("hi")), '<p class="c">hi</p>')
    assert_equal(void("br", ""), "<br>")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
