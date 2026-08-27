"""Tests for HTML text escaping.

Two things are being pinned here, and they failed independently before this
module existed: that the five HTML metacharacters cannot survive into
markup, and that everything else — non-ASCII especially — comes out exactly
as it went in.
"""

from std.testing import assert_equal, assert_true, TestSuite

from src.html_escape import escape_html, escape_html_into


def test_plain_text_is_unchanged() raises:
    assert_equal(escape_html("hello world"), "hello world")
    assert_equal(escape_html(""), "")


def test_the_five_metacharacters() raises:
    assert_equal(escape_html("<"), "&lt;")
    assert_equal(escape_html(">"), "&gt;")
    assert_equal(escape_html("&"), "&amp;")
    assert_equal(escape_html('"'), "&quot;")
    assert_equal(escape_html("'"), "&#x27;")


def test_ampersand_is_escaped_first() raises:
    """`&lt;` must not come back as `&amp;lt;`-of-something-else: the
    ampersand rule runs on the INPUT's ampersands only, so an already-safe
    entity in the input is escaped once, not twice by two passes."""
    assert_equal(escape_html("&lt;"), "&amp;lt;")
    assert_equal(escape_html("a & b < c"), "a &amp; b &lt; c")


def test_script_tag_cannot_survive() raises:
    """The case that made this function necessary: a stored note title
    rendered into an HTML representation."""
    var got = escape_html("<script>alert(document.domain)</script>")
    assert_equal(
        got, "&lt;script&gt;alert(document.domain)&lt;/script&gt;"
    )
    # Nothing that could start or end a tag is left.
    for c in got.as_bytes():
        assert_true(c != UInt8(ord("<")) and c != UInt8(ord(">")))


def test_attribute_breakout_is_prevented() raises:
    """A value interpolated into `<img src="VALUE">` must not be able to
    close the quote and add an event handler."""
    var got = escape_html('" onerror="alert(1)')
    assert_equal(got, "&quot; onerror=&quot;alert(1)")
    for c in got.as_bytes():
        assert_true(c != UInt8(ord('"')))


def test_single_quote_breakout_is_prevented() raises:
    var got = escape_html("' onmouseover='alert(1)")
    assert_equal(got, "&#x27; onmouseover=&#x27;alert(1)")


def test_non_ascii_is_preserved_byte_for_byte() raises:
    """UTF-8 must pass through untouched.

    The naive byte-walking escaper rebuilds each byte with `chr(Int(b))`,
    which promotes every UTF-8 continuation byte to its own codepoint and
    turns `café` into `cafÃ©`. That shipped in a demo's hand-rolled copy;
    this asserts the shared one does not repeat it.
    """
    assert_equal(escape_html("café"), "café")
    assert_equal(escape_html("naïve résumé"), "naïve résumé")
    assert_equal(escape_html("日本語"), "日本語")
    assert_equal(escape_html("emoji 🎉 here"), "emoji 🎉 here")
    # Byte length is preserved exactly when nothing needs escaping.
    assert_equal(escape_html("café").byte_length(), String("café").byte_length())


def test_non_ascii_mixed_with_metacharacters() raises:
    assert_equal(escape_html("<b>café</b>"), "&lt;b&gt;café&lt;/b&gt;")


def test_into_form_appends_without_clobbering() raises:
    """The buffer form is what a page builder uses across many values."""
    var out = List[UInt8]()
    escape_html_into(out, "<a>")
    escape_html_into(out, "&b")
    assert_equal(
        String(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out))),
        "&lt;a&gt;&amp;b",
    )


def test_control_bytes_pass_through() raises:
    """Newlines and tabs are legal HTML text and are left alone — escaping
    them is a presentation decision, not a safety one."""
    assert_equal(escape_html("a\nb\tc"), "a\nb\tc")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
