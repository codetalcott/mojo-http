"""The HTML builder and the fragment that names itself (`src/html.mojo`).

What is pinned: `attr` owns the delimiters and escapes what goes between
them, `text` escapes and `raw` does not, a start tag is ended by whatever
follows it, and a fragment's root id and the attribute that targets it are
one value used twice.
"""

from std.testing import TestSuite, assert_equal, assert_true

from src.html import Fragment, Html


def test_attr_owns_the_delimiters_and_escapes_the_value() raises:
    var h = Html()
    h.open("a")
    h.attr("href", String("/notes?q=<x>&r=\"y\""))
    h.text("link")
    h.close("a")
    assert_equal(
        h.finish(),
        '<a href="/notes?q=&lt;x&gt;&amp;r=&quot;y&quot;">link</a>',
    )


def test_text_escapes_and_raw_does_not() raises:
    var h = Html()
    h.open("p")
    h.text("<script>alert(1)</script>")
    h.raw("<b>ok</b>")
    h.close("p")
    assert_equal(
        h.finish(), "<p>&lt;script&gt;alert(1)&lt;/script&gt;<b>ok</b></p>"
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
    assert_equal(h.finish(), '<input name="title" required><br><span>x</span>')


def test_finish_ends_an_open_start_tag() raises:
    var h = Html()
    h.open("hr")
    assert_equal(h.finish(), "<hr>")


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
    assert_equal(h.finish(), '<i title="café">café</i>')


def test_fragment_emits_its_id_once_and_targets_it() raises:
    """The pattern: the root id is written once, by the constructor, and
    `swap` generates the targeting attribute from the same id. Nothing in
    the fragment's own markup carries the id a second time except through
    that generator.

    covers: N3
    """
    var f = Fragment("notes")
    f.open("form")
    f.swap("post", "/notes")
    f.close("form")
    var out = f.finish()
    assert_equal(
        out,
        '<section id="notes"><form hx-post="/notes" hx-target="#notes"'
        ' hx-swap="outerHTML"></form></section>',
    )
    assert_equal(f.selector(), "#notes")


def test_fragment_root_tag_is_the_callers() raises:
    var f = Fragment("todos", tag="ul")
    f.open("li")
    f.text("one")
    f.close("li")
    assert_equal(f.finish(), '<ul id="todos"><li>one</li></ul>')


def test_swap_on_a_page_element_uses_the_fragments_selector() raises:
    """A page-level element that swaps a fragment rendered elsewhere gets
    the target from the fragment value, not from a retyped string."""
    var f = Fragment("notes")
    var page = Html()
    page.open("a")
    page.swap("get", "/notes", f.selector())
    page.text("all")
    page.close("a")
    assert_equal(
        page.finish(),
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
        h.finish(),
        '<button class="toggle" data-on:click="@post(&#x27;/toggle/7&#x27;)"></button>',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
