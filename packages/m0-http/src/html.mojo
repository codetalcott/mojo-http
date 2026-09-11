"""HTML assembly: a buffer that owns the attribute delimiters, and a fragment
that names itself.

Every byte of HTML in this repo's Mojo apps was a `String(...)` variadic
call, and the worst line in the tree stacked three quoting levels — a Mojo
literal, an HTML attribute, and a Datastar expression inside it — with the
literal chopped at every hole:

    out += String('<li><button class="toggle" data-on:click="@post(', "'/toggle/", id, "'", ')">')

The pain is not the quotes. It is that the author is writing the
attribute's own delimiters by hand. `Html.attr` owns the `="` and the `"`
and escapes what goes between them, because that is what emitting an
attribute *means*; the same line becomes

    h.open("button"); h.attr("class", "toggle")
    h.attr("data-on:click", String("@post('/toggle/", id, "')"))

and the single quotes inside the expression are ordinary characters in an
ordinary Mojo string. `attr` emits them as `&#x27;`, and the HTML parser
un-escapes attribute values before any expression evaluator sees them — so
this is what every templating engine does, and more correct than what the
apps wrote by hand.

These are helpers, not a safety type. `String` stays the currency,
`reply.html(String)` is unchanged, and no app is forced onto them. What
they do is make the escaped path the SHORTER one: `text` and `attr` escape,
`raw` says so by name. They do not make the unsafe path impossible.

Three contexts stay the caller's, as `html_escape.mojo` already refuses
them: a `<script>` or `<style>` body, a `javascript:`/`data:` URL, and an
unquoted attribute. `attr` always quotes, so the last cannot happen here.

**A fragment names itself.** `Fragment` owns its root id, writes it once as
the root element's `id`, and generates the attribute that targets it —
`swap(verb, url)` on any element inside it — from that same id. The two
uses cannot disagree because there is only one of them. The view that
renders a fragment returns one thing; whether to wrap it in a page is the
framework's decision, made from the request header in `m0_http.fragment`.
Datastar's default `outer` morph targets an element by id too, so one
renderer serves an htmx response body and a `patch_elements` frame.

The attribute vocabulary `swap` emits is htmx's (`hx-get`, `hx-target`,
`hx-swap`). This method is the ONLY place that knows the spelling: an app
that calls `swap` never writes the attribute, so changing the vocabulary is
one edit here and none in any app.

Lives in m0-http, beside `fragment.mojo`, which is its consumer; it is the
first caller of m0-core's `escape_html_into` and the fifth m0-core
function m0-http imports. It was first placed in m0-core to keep that
count at four, which mistook an inventory for the constraint: the rule is
zero upward imports and no libpython on the link line, and m0-http
importing m0-core is downward. A specific frontend library's attribute
names do not belong in the zero-dependency package `build-ffi` compiles
into `libm0core`.
"""

from m0_core.html_escape import escape_html_into

comptime _LT = UInt8(60)  # '<'
comptime _GT = UInt8(62)  # '>'
comptime _SPACE = UInt8(32)
comptime _QUOTE = UInt8(34)  # '"'
comptime _EQ = UInt8(61)  # '='
comptime _SLASH = UInt8(47)  # '/'


struct Html(Movable):
    """A growing HTML buffer. `open` starts an element and leaves its start
    tag open for `attr`; anything that follows — `text`, `raw`, `open`,
    `close` — ends the start tag first, so a void
    element like `<input name="t">` needs no closing call of its own."""

    var _buf: List[UInt8]
    var _open: Bool
    """Whether a start tag is open, i.e. `attr` is currently legal."""

    def __init__(out self, capacity: Int = 512):
        self._buf = List[UInt8](capacity=capacity)
        self._open = False

    @always_inline
    def _end_tag(mut self):
        if self._open:
            self._buf.append(_GT)
            self._open = False

    def open(mut self, tag: String):
        """Start `<tag`, leaving it open for attributes."""
        self._end_tag()
        self._buf.append(_LT)
        self._buf.extend(tag.as_bytes())
        self._open = True

    def attr(mut self, name: String, value: String) raises:
        """` name="value"`, with `value` escaped. Raises if no element is
        open: an attribute emitted into text content would render as text,
        silently, which is the failure this exists to remove."""
        if not self._open:
            raise Error(
                'Html.attr("', name, '"): no start tag is open — call open(tag) first'
            )
        self._buf.append(_SPACE)
        self._buf.extend(name.as_bytes())
        self._buf.append(_EQ)
        self._buf.append(_QUOTE)
        escape_html_into(self._buf, value)
        self._buf.append(_QUOTE)

    def flag(mut self, name: String) raises:
        """A boolean attribute: ` required`, ` checked`, ` disabled`."""
        if not self._open:
            raise Error(
                'Html.flag("', name, '"): no start tag is open — call open(tag) first'
            )
        self._buf.append(_SPACE)
        self._buf.extend(name.as_bytes())

    def swap(mut self, verb: String, url: String, target: String) raises:
        """The attributes that make the open element fetch `url` with `verb`
        and replace the element `target` selects with the answer.

        `target` is a selector (`#notes`); `Fragment.swap` supplies its own.
        This is the one place the attribute vocabulary is spelled.
        """
        self.attr(String("hx-", verb), url)
        self.attr("hx-target", target)
        self.attr("hx-swap", "outerHTML")

    def text(mut self, s: String):
        """`s` as text content, escaped."""
        self._end_tag()
        escape_html_into(self._buf, s)

    def raw(mut self, s: String):
        """`s` verbatim. Markup the caller already trusts — a rendered
        fragment, a `comptime` stylesheet, an entity like `&times;`."""
        self._end_tag()
        self._buf.extend(s.as_bytes())

    def close(mut self, tag: String):
        """`</tag>`."""
        self._end_tag()
        self._buf.append(_LT)
        self._buf.append(_SLASH)
        self._buf.extend(tag.as_bytes())
        self._buf.append(_GT)

    def finish(var self) -> String:
        """The markup, with any open start tag ended. Consumes the builder:
        a second `finish` is a compile error, not a second closing tag."""
        self._end_tag()
        return String(unsafe_from_utf8=Span(self._buf))


struct Fragment(Movable):
    """An element that owns its id, and everything rendered inside it.

    ```mojo
    var f = Fragment("notes")            # <section id="notes"
    f.open("form"); f.swap("post", "/notes")
    ...
    return f.finish()                    # ...</section>
    ```

    The id is written once, by the constructor. `swap` reads it back to
    generate `hx-target`, so a swapping element inside the fragment always
    targets the fragment it is in. `selector()` hands the same id to an
    element rendered elsewhere — a page-level link, say — that should swap
    this fragment; that is the one seam where the id travels as a string,
    and it still comes from this value rather than being retyped.
    """

    var id: String
    var tag: String
    var html: Html

    def __init__(
        out self, var id: String, tag: String = "section", capacity: Int = 512
    ) raises:
        """Raises unless `id` is a plain identifier: a letter or underscore,
        then letters, digits, `_` or `-`. `id="note.7"` is a valid DOM id
        but `#note.7` selects id `note` with class `7`, and `#7` is a
        syntax error to `querySelector` — so a looser id would put the
        element and the attribute that targets it in silent disagreement,
        which is the one thing this type exists to prevent. An id is code,
        not data; the check is the constructor's, once."""
        if not _is_identifier(id):
            raise Error(
                'Fragment("', id, '"): an id must be a letter or underscore, '
                "then letters, digits, `_` or `-`, so that `#id` selects it"
            )
        self.id = id^
        self.tag = tag
        self.html = Html(capacity)
        self.html.open(self.tag)
        self.html.attr("id", self.id)

    def selector(self) -> String:
        """`#id`: what an attribute that targets this fragment says."""
        return String("#", self.id)

    def swap(mut self, verb: String, url: String) raises:
        """Make the open element fetch `url` with `verb` and replace THIS
        fragment with the answer. Generated from the fragment's own id."""
        self.html.swap(verb, url, self.selector())

    # --- the builder, delegated, so a fragment reads like a page -------------

    def open(mut self, tag: String):
        self.html.open(tag)

    def attr(mut self, name: String, value: String) raises:
        self.html.attr(name, value)

    def flag(mut self, name: String) raises:
        self.html.flag(name)

    def text(mut self, s: String):
        self.html.text(s)

    def raw(mut self, s: String):
        self.html.raw(s)

    def close(mut self, tag: String):
        self.html.close(tag)

    def finish(var self) -> String:
        """Close the root element and return the whole fragment. Consumes
        the fragment, so it cannot be closed twice."""
        self.html.close(self.tag)
        # Read the buffer in place rather than moving the field out of a
        # value being consumed, which the compiler refuses.
        self.html._end_tag()
        return String(unsafe_from_utf8=Span(self.html._buf))


def _is_identifier(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var alpha = (c >= ord("a") and c <= ord("z")) or (c >= ord("A") and c <= ord("Z"))
        if i == 0:
            if not (alpha or c == ord("_")):
                return False
        elif not (alpha or (c >= ord("0") and c <= ord("9")) or c == ord("_") or c == ord("-")):
            return False
    return True
