"""HTML text escaping — the other half of "do not paste input into output".

`escape_json_string` next door makes a value safe inside a JSON document.
This makes one safe inside HTML *text* or a quoted *attribute*, which is a
different set of characters and a different failure if you use the wrong
one: JSON escaping leaves `<`, `>` and `&` untouched, so a title escaped as
JSON and then interpolated into markup still closes a tag and still opens a
`<script>`.

Five characters, the conservative set every server-side escaper uses:

    &  →  &amp;    first, or it would double-escape what follows
    <  →  &lt;
    >  →  &gt;
    "  →  &quot;   so a value can sit inside "..." without ending it
    '  →  &#x27;   and inside '...' likewise

That covers HTML text nodes and quoted attribute values. It is deliberately
NOT enough for: an unquoted attribute (`<a href=VALUE>`, where a space is
already an escape), a `<script>` or `<style>` body (which is not HTML at
all — its own parser runs first), a `javascript:`/`data:` URL, or a CSS or
event-handler context. Those need context-specific encoding, and no
single-argument function can supply it.

**Bytes above 0x7F pass through unchanged, and that is the point.** Mojo
strings are UTF-8. The obvious implementation walks bytes and rebuilds
non-ASCII ones with `chr(Int(b))`, which turns each continuation byte into
its own codepoint: `café` becomes `cafÃ©`. That bug shipped in the todo
demo's hand-rolled escaper and is the direct reason this lives in m0-core
once instead of in each app. UTF-8 has the property that makes the naive
loop safe here — no continuation byte can collide with an ASCII value — so
copying non-ASCII bytes verbatim is both correct and the fast path.
"""


def escape_html(s: String) -> String:
    """Escape `s` for use as HTML text or inside a quoted attribute.

    See the module docstring for the contexts this does *not* cover.
    """
    var out = List[UInt8](capacity=s.byte_length() + 16)
    escape_html_into(out, s)
    return String(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out)))


def escape_html_into(mut out: List[UInt8], s: String):
    """Append the escaped form of `s` to `out`.

    The buffer-appending form, for a caller assembling a page out of many
    values — the same reason `escape_json_string_into` exists.
    """
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("&")):
            _append_ascii(out, "&amp;")
        elif c == UInt8(ord("<")):
            _append_ascii(out, "&lt;")
        elif c == UInt8(ord(">")):
            _append_ascii(out, "&gt;")
        elif c == UInt8(ord('"')):
            _append_ascii(out, "&quot;")
        elif c == UInt8(ord("'")):
            # `&apos;` is XML; `&#x27;` is what HTML 4 documents understand
            # too, and every escaper settled on it for that reason.
            _append_ascii(out, "&#x27;")
        else:
            # Every other byte, ASCII or UTF-8 continuation, verbatim.
            out.append(c)


def _append_ascii(mut out: List[UInt8], lit: String):
    for c in lit.as_bytes():
        out.append(c)
