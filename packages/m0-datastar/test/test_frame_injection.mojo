"""A Datastar frame cannot be split by what it carries (SPEC I29).

SSE is line-framed, so a line break inside a value that must stay on one
line ends its field early, and two of them end the event -- whatever
follows is an event of its own. `elements` and `signals` may span lines and
are split into datalines; every other field is refused when it carries CR
or LF, and `redirect`'s location is escaped into a string literal it cannot
leave. `poe sabotage-datastar-sdk` reverts each of these rules against this
file.

A file of its own because the spec sheet indexes test files by NAME, and
m0-http has a `test_sse.mojo` too.
"""

from std.testing import assert_equal, assert_true, assert_raises, TestSuite

from src.sse import execute_script, patch_elements, patch_signals, redirect


def _raw_text(*bytes: Int) -> String:
    """A String holding exactly these bytes, valid UTF-8 or not."""
    var buf = List[UInt8]()
    for b in bytes:
        buf.append(UInt8(b))
    return String(unsafe_from_utf8=Span(buf))


def test_a_line_break_in_a_single_line_field_is_refused() raises:
    """CR or LF in a selector, mode, namespace or event id raises.

    Written into its dataline, the break ends the field early; two of them
    end the EVENT, and what follows is an event of the sender's choosing --
    a selector built from request data could patch any HTML into the page.
    Stripping or cutting would name a different target silently, so the
    frame is refused.

    covers: I29
    """
    var attack = String(
        "#x\n\nevent: datastar-patch-elements\n"
        "data: elements <img id=\"a\" src=\"x\" onerror=\"alert(1)\">"
    )
    with assert_raises(contains="line break"):
        _ = patch_elements("<p/>", selector=attack)
    with assert_raises(contains="selector"):
        _ = patch_elements("<p/>", selector="#a\rb")
    with assert_raises(contains="mode"):
        _ = patch_elements("<p/>", selector="#a", mode="inner\n")
    with assert_raises(contains="namespace"):
        _ = patch_elements("<p/>", namespace="svg\r\n")
    with assert_raises(contains="view transition selector"):
        _ = patch_elements(
            "<p/>", use_view_transition=True, view_transition_selector="#m\n"
        )
    with assert_raises(contains="event id"):
        _ = patch_elements("<p/>", event_id="7\nretry: 1")
    with assert_raises(contains="event id"):
        _ = patch_signals("{}", event_id="7\n")
    with assert_raises(contains="event id"):
        _ = execute_script("go()", event_id="\r7")
    with assert_raises(contains="event id"):
        _ = redirect("/next", event_id="7\n")
    # The control: the same calls without a break go out.
    assert_true(patch_elements("<p/>", selector="#a b > c").find("data: selector #a b > c\n") >= 0)


def test_redirect_location_cannot_leave_its_literal() raises:
    """The location is a JavaScript string literal no byte of it can end.

    It used to be pasted between single quotes, so `'` ended the literal
    and the rest ran as script; `</script>` ends the element whatever the
    quoting. Now `"`, the backslash, `<`, every control byte and U+2028/9
    are escaped, and the frame holds exactly one `</script>`, its own.

    covers: I29
    """
    var location = String('/x";alert(1);//</script><script>alert(2)</script>\n')
    location += _raw_text(0xE2, 0x80, 0xA8)
    var s = redirect(location)
    assert_equal(s.count("</script>"), 1)
    assert_true(
        s.find(
            'window.location = "/x\\";alert(1);//\\u003c/script>'
            '\\u003cscript>alert(2)\\u003c/script>\\u000a\\u2028")'
        )
        >= 0
    )
    # One elements line: the escaped newline did not split the script.
    assert_equal(s.count("data: elements "), 1)
    # A plain path is unchanged apart from the quotes.
    assert_true(
        redirect("/next?a=1&b='2'").find(
            "window.location = \"/next?a=1&b='2'\")"
        )
        >= 0
    )


def test_redirect_refuses_a_location_that_runs_script_or_leaves_the_site() raises:
    """Only an http(s) URL, or a reference that stays on the site, is sent.

    Escaped perfectly, `javascript:alert(1)` still runs when it is assigned
    to `window.location`, in the page's own origin, and `//evil.example`
    leaves the site: a `next=` parameter carries either. The check reads a
    location as the browser's URL parser does (WHATWG URL) -- leading C0
    controls and spaces stripped, a tab, LF or CR anywhere removed, the
    scheme case-insensitive, `\\` a slash in an http(s) URL -- and each
    spelling below resolves, by that parser, to a scheme other than http(s)
    or to another host, so every one is refused.

    covers: I29
    """
    var runs_script = [
        String("javascript:alert(1)"),
        String("JavaScript:alert(1)"),
        String(" javascript:alert(1)"),
        _raw_text(0x01) + "javascript:alert(1)",
        String("java\tscript:alert(1)"),
        String("java\nscript:alert(1)"),
        String("java\r\nscript:alert(1)"),
        String("data:text/html,<script>alert(1)</script>"),
        String("vbscript:msgbox(1)"),
    ]
    for loc in runs_script:
        with assert_raises(contains="scheme is not http or https"):
            _ = redirect(loc)
    var leaves_the_site = [
        String("//evil.example/x"),
        String("/\\evil.example/x"),
        String("\\\\evil.example/x"),
        String("\\/evil.example/x"),
        String("/\t/evil.example/x"),
        String(" //evil.example/x"),
    ]
    for loc in leaves_the_site:
        with assert_raises(contains="two slashes"):
            _ = redirect(loc)
    # The control: what stays on the site, and an off-site target that says
    # so with its scheme, still go out -- verbatim, inside the literal.
    var allowed = [
        String("/next"),
        String("/next?a=1&b=2#top"),
        String("next"),
        String("../up"),
        String("?page=2"),
        String("#top"),
        String("/a:b"),
        String("a/b:c"),
        String("\\next"),
        String("https://example.com/x"),
        String("HTTP://example.com/x"),
    ]
    for loc in allowed:
        var s = redirect(loc)
        assert_equal(s.count("</script>"), 1)
    assert_true(
        redirect("https://example.com/x").find(
            'window.location = "https://example.com/x")'
        )
        >= 0
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
