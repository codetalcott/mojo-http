"""One renderer, two transports: a `Fragment[Datastar]` inside a
`patch_elements` frame.

m0-http's fragment is what an htmx or Datastar action receives as a
`text/html` body. This package's `patch_elements` is the other transport —
the same bytes as the `elements` of an SSE frame to every connected tab.
What is pinned here is that nothing has to change between the two: the
fragment is one line (SSE is line-framed, and the builder emits no newline
unless told), so it is ONE `data: elements` line, verbatim; and it carries
its own id, so the frame needs no `selector` for Datastar's default
`outer` morph to find it.

The app that asks is `apps/datastar_todo`, whose `render_todos` is built on
`Fragment[Datastar]` and is both the page's initial list and every
broadcast; `smoke-todo` greps that renderer's output out of a live
stream's frame. This test pins the property on the framework types, with
a renderer shaped like the app's.
"""

from std.testing import TestSuite, assert_equal, assert_true

from m0_http import Datastar, Fragment

from src.sse import patch_elements


def _todos(texts: List[String]) raises -> String:
    """The todo demo's renderer, in miniature."""
    var f = Fragment[Datastar]("todos")
    f.open("ul")
    for i in range(len(texts)):
        f.open("li")
        f.open("button")
        f.attr("class", "toggle")
        f.swap("post", String("/toggle/", i))
        f.raw("&#9744;")
        f.close("button")
        f.open("span")
        f.text(texts[i])
        f.close("span")
        f.close("li")
    f.close("ul")
    f.open("p")
    f.text(String(len(texts), " left"))
    f.close("p")
    return f^.finish()


def test_a_fragment_goes_out_verbatim_as_one_elements_line() raises:
    """The renderer's output IS the frame's payload: one `data: elements`
    line carrying the fragment byte for byte, no selector, no mode.

    covers: N7
    """
    var fragment = _todos(["buy milk", "walk <the> dog"])
    assert_true(fragment.find("\n") < 0, "a fragment must be one line")
    assert_true(fragment.startswith('<section id="todos">'))
    assert_true(fragment.find("walk &lt;the&gt; dog") >= 0)
    var frame = patch_elements(fragment)
    assert_equal(
        frame,
        String("event: datastar-patch-elements\ndata: elements ", fragment, "\n\n"),
    )


def test_the_same_fragment_is_the_page_s_initial_list() raises:
    """What the page renders at first paint and what the stream later
    morphs over it are the same call: the string is the same either way,
    and the smoke checks the frame's copy against a fresh page load."""
    var a = _todos(["x"])
    var b = _todos(["x"])
    assert_equal(a, b)
    assert_true(patch_elements(a).find(b) >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
