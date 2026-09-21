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

Two tiers over one buffer. The builder (`Html`, `Fragment`) is
statement-shaped and allocates once; the expression tier at the bottom of
this file (`el`, `void`, `attr`, `flag`, `text`, and `Fragment.el` for a
swapping element) makes an element a string so a renderer reads like its
markup, and allocates per element. Same escaping, same vocabulary seam.

Three contexts stay the caller's, as `html_escape.mojo` already refuses
them: a `<script>` or `<style>` body, a `javascript:`/`data:` URL, and an
unquoted attribute. `attr` always quotes, so the last cannot happen here.

**A fragment names itself.** `Fragment` owns its root id, writes it once as
the root element's `id`, and generates the attribute that targets it —
`swap(verb, url)` on any element inside it — from that same id. The two
uses cannot disagree because there is only one of them. The view that
renders a fragment returns one thing; whether to wrap it in a page is the
framework's decision, made from the request header in `m0_http.fragment`.

**The vocabulary is a type parameter.** Two frontend libraries can consume
the same fragment, and they spell "fetch this URL and put the answer where
this fragment is" differently: htmx wants `hx-post`, `hx-target` and
`hx-swap` on the element; Datastar wants `data-on:click="@post('...')"`
and no target at all, because it morphs the answer into the element whose
id it carries — the id the fragment already owns. `Fragment[Htmx]` and
`Fragment[Datastar]` render identical code with different attributes;
an app names its vocabulary once (`comptime Frag = Fragment[Htmx]`) and
never writes an attribute of either. The `Vocabulary` trait below is the
seam, `Htmx` and `Datastar` are the two conformances the layer ships and
gates, and each is the ONLY place its library's spelling lives: switching
a whole app is one edit.

**A third library is an application's own struct.** `Vocabulary` is open:
an app conforms to it from its own source, through the `.mojoc`, and
`Fragment[Theirs]` renders with it (Mojo 1.1.0; through 1.0 an app's
conformance to a trait behind a `.mojoc` got no witness table, which is
the only reason both conformances were ever written here). What a
conformance may rely on is what it can write without an underscore: the
builder's `attr` and `flag`, `Html.open_kind()` for which element it is
on, and `verbs()` for the verbs its library takes. The two built-in
conformances are written against exactly that surface, so it cannot be
narrower than what a real library needed. The verb check is the LAYER's —
`Html.swap` and `Fragment.swap`/`.el` refuse a verb outside `V.verbs()`
before `V.swap` runs — so a conformance that checks nothing still refuses
a typo, and one whose library has a sixth verb (htmx 4's `query`, which
is how `Htmx` itself takes it) says so in one line. `poe check-app-vocabulary` builds such an app from a
directory outside this repository and reads its output with a linter
this layer did not write.

One mode: replace the fragment itself. The two libraries put a non-default
mode on different sides — htmx on the element (`hx-swap="beforeend"`) or
on the response (`HX-Reswap`), Datastar only on the response
(`datastar-mode`) — so a `mode` parameter on `swap` would be a spelling
one of them cannot honour. The response is the place both agree on, and no
app in the tree appends yet; when one does, the mode belongs beside
`page_or_fragment`, not here.

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

comptime _KIND_OTHER = UInt8(0)
comptime _KIND_FORM = UInt8(1)
"""`<form>`: the request is the form's own submit, carrying its fields."""
comptime _KIND_FIELD = UInt8(2)
"""`<input>`, `<textarea>`, `<select>`: the request fires on change."""
comptime _KIND_LINK = UInt8(3)
"""`<a>`, `<button>`: a click whose default (navigate, submit) is cancelled."""


def _kind_of(tag: String) -> UInt8:
    """Which default event an element's request should fire on — htmx's
    own rule (`getTriggerSpecs`: a form submits, a field changes, the
    rest click), so the two vocabularies agree on WHEN. What travels is
    each library's own: htmx sends the element's value, Datastar the
    signal store (see `Datastar`)."""
    if tag == "form":
        return _KIND_FORM
    if tag == "input" or tag == "textarea" or tag == "select":
        return _KIND_FIELD
    if tag == "a" or tag == "button":
        return _KIND_LINK
    return _KIND_OTHER


@fieldwise_init
struct ElementKind(ImplicitlyCopyable, Movable):
    """Which kind of element a start tag opened, as a vocabulary reads it
    (`Html.open_kind()`): the default event htmx's own rule gives it. Three
    questions rather than four constants, because "none of the three" is
    the fourth answer and needs no name."""

    var _kind: UInt8

    def is_form(self) -> Bool:
        """`<form>`: the request is the form's own submit."""
        return self._kind == _KIND_FORM

    def is_field(self) -> Bool:
        """`<input>`, `<textarea>`, `<select>`: the request fires on change."""
        return self._kind == _KIND_FIELD

    def is_link(self) -> Bool:
        """`<a>`, `<button>`: a click whose default is cancelled."""
        return self._kind == _KIND_LINK


comptime STANDARD_VERBS = "get post put patch delete"
"""What `Vocabulary.verbs()` answers unless a conformance says otherwise."""


def _verb_is_in(verb: String, verbs: String) -> Bool:
    """Whether `verb` is one of the space-separated words of `verbs`. A
    byte walk, not a split: this runs on every swapping element."""
    var v = verb.as_bytes()
    var b = verbs.as_bytes()
    var n = len(v)
    if n == 0:
        return False
    for k in range(n):
        if v[k] == _SPACE:
            return False
    var i = 0
    while i < len(b):
        var j = i
        while j < len(b) and b[j] != _SPACE:
            j += 1
        if j - i == n:
            var same = True
            for k in range(n):
                if b[i + k] != v[k]:
                    same = False
                    break
            if same:
                return True
        i = j + 1
    return False


def _swap[
    V: Vocabulary
](mut h: Html, verb: String, url: String, target: String, push: Bool = False) raises:
    """Every swap goes through here: refuse a verb `V` does not take, then
    let `V` spell it. `hx-psot` is a silent attribute in htmx and
    `@psot(...)` a runtime error in Datastar, and a typo is the mistake
    this layer exists to catch — so the check is the layer's, and a
    conformance that checks nothing still refuses one.

    `push` makes the swap move the address bar to `url`, and it has a
    check of the layer's too: only a `get` is pushed. A pushed URL is one
    the browser GETs on reload, from a bookmark and on a history restore,
    so pushing a `post`'s is writing an address that answers 405, or
    worse, one that answers."""
    if push and verb != "get":
        raise Error(
            'swap("', verb, '", "', url, '", push=True): only a get is pushed — a '
            "pushed URL is one the browser will GET on reload"
        )
    var verbs = V.verbs()
    if not _verb_is_in(verb, verbs):
        raise Error(
            'swap("', verb, '", ...): the verb must be one of ',
            verbs.replace(" ", ", "),
        )
    V.swap(h, verb, url, target)
    if push:
        V.push_url(h)


def _check_action_url(url: String) raises:
    """Refuse a URL that would end the JavaScript string literal Datastar's
    expression places it in.

    `attr` escapes the value for the HTML context — a `'` reaches the wire
    as `&#x27;` — and the HTML parser un-escapes it before Datastar
    evaluates the attribute, so what Datastar sees is the written `'`,
    closing the literal: `@post('/notes?q=x') ; alert(1) ; ('')`. A URL
    carrying a quote, a backslash or a line break is refused here rather
    than written; `url_for` percent-encodes all of them, and an app that
    builds a query from request data must too (`%27` is the same URL).
    """
    var b = url.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(39) or c == UInt8(92) or c == UInt8(13) or c == UInt8(10):
            raise Error(
                'Datastar swap("', url, '"): a URL inside a Datastar expression '
                "may not contain a quote, a backslash or a line break — "
                "percent-encode the value (url_for does)"
            )


trait Vocabulary:
    """How a frontend library spells "fetch `url` with `verb` and put the
    answer where `target` is".

    `swap` is called with the element still open, so the spelling can ask
    `h.open_kind()` which element it is on and write with `h.attr` and
    `h.flag`. `target` is a selector (`#notes`); a library that targets by
    id ignores it, and that is the point of passing it rather than making
    the caller decide who needs it. By the time `swap` runs the verb has
    been checked against `verbs()`, so a conformance does not check it.

    An application may conform to this from its own source. Everything a
    conformance needs is spelled without an underscore; the two below are
    written that way on purpose.
    """

    @staticmethod
    def swap(mut h: Html, verb: String, url: String, target: String) raises:
        ...

    @staticmethod
    def verbs() -> String:
        """The verbs this library takes, space-separated. The layer refuses
        any other before `swap` runs and names these in the error. The
        default is the five every library here shares; htmx 4 has a
        sixth (`query`), and `Htmx` answers with all six."""
        return STANDARD_VERBS

    @staticmethod
    def push_url(mut h: Html) raises:
        """Make the swap just written move the address bar to its URL, so a
        view reached by a swap can be reloaded, linked to and gone back to.
        Called after `swap`, on the same open element, and only for a
        `get`. The default REFUSES: a library with no spelling for it
        raises rather than rendering a swap that looks like it navigated
        and did not."""
        raise Error("swap(..., push=True): this vocabulary cannot push a URL")


comptime HTMX_VERBS = "get post put patch delete query"
"""The `#verbs` of htmx 4, in its order: the five, and `query`."""


struct Htmx(Vocabulary):
    """The htmx 4 spelling: `hx-VERB`, `hx-target`, `hx-swap="outerHTML"`.

    Gated against htmx 4.0.0 since 2026-09-19 (2.0.4 before; DECISIONS D6,
    retired). The three attributes are the ones htmx 2 took, byte for
    byte, and that is deliberate: all three go on the ELEMENT, so htmx 4
    turning inheritance off (`implicitInheritance: false`) takes nothing
    away, and its new default swap (`innerHTML`) is never consulted. What
    the major version adds here is its sixth verb, `query`.

    htmx picks the event itself (a form on submit, a field on change, the
    rest on click) and cancels the default for forms, submit buttons and
    anchors, so nothing about the element needs spelling here.

    What this cannot spell is a request HEADER, and htmx 4 makes an app
    want one: a `delete`'s fields ride the query string there, hard-coded,
    so a CSRF token on one travels as a header (`hx-headers` on the
    element; `apps/fragment_notes` writes it by hand, D38).
    """

    @staticmethod
    def swap(mut h: Html, verb: String, url: String, target: String) raises:
        h.attr(String("hx-", verb), url)
        h.attr("hx-target", target)
        h.attr("hx-swap", "outerHTML")

    @staticmethod
    def verbs() -> String:
        return HTMX_VERBS

    @staticmethod
    def push_url(mut h: Html) raises:
        """`hx-push-url="true"`: htmx pushes the request's URL and owns the
        other half too — back and forward re-request the URL with
        `HX-Request-Type: full`, which `page_or_fragment` answers as a
        document (SPEC N22)."""
        h.attr("hx-push-url", "true")


struct Datastar(Vocabulary):
    """The Datastar 1.0 spelling: `data-on:EVENT="@VERB('url')"`, no target.

    Datastar morphs a `text/html` answer into the element whose id it
    carries (`outer` mode, its default, by id) — so the target is the
    fragment's own id and needs no attribute. The event follows the same
    rule htmx applies for itself: a `<form>` fires on `submit`, with
    `__prevent` so the browser does not also navigate and with
    `{contentType: 'form'}` so the request carries the form's fields
    rather than the signal store (without it a Datastar form sends no
    fields at all); a field fires on `change`; an `<a>` or `<button>`
    fires on `click__prevent`, which stops an anchor's navigation and a
    button's native submit and is a no-op anywhere else; everything else
    fires on a plain `click`.

    WHEN agrees with htmx; WHAT travels is Datastar's own. A field's
    action sends the signal store, not the field — bind the field
    (`data-bind:name`, the page's attribute) for its value to travel.
    `{contentType: 'form'}` is not emitted for a field: it would send the
    enclosing form inside one and raise `FetchFormNotFound` outside one
    (v1.0.3), which is a runtime error for a rule the builder cannot see.

    The single quotes in the expression reach the wire as `&#x27;` because
    `attr` escapes; the HTML parser un-escapes the attribute before
    Datastar evaluates it, so the expression it sees is the one written —
    which protects the HTML context and not the JavaScript one inside it.
    That is why the URL is checked (`_check_action_url`): a `'` in it
    would end the string literal, and `Fragment[Htmx]` tolerating the same
    URL is exactly what makes the hole easy to carry across.
    """

    @staticmethod
    def swap(mut h: Html, verb: String, url: String, target: String) raises:
        _ = target
        _check_action_url(url)
        var kind = h.open_kind()
        if kind.is_form():
            h.attr(
                "data-on:submit__prevent",
                String("@", verb, "('", url, "', {contentType: 'form'})"),
            )
        elif kind.is_field():
            h.attr("data-on:change", String("@", verb, "('", url, "')"))
        elif kind.is_link():
            h.attr("data-on:click__prevent", String("@", verb, "('", url, "')"))
        else:
            h.attr("data-on:click", String("@", verb, "('", url, "')"))

    @staticmethod
    def push_url(mut h: Html) raises:
        """Refused. Datastar 1.0.3 has no history handling at all — its
        bundle names neither `pushState` nor `popstate` — so the only
        spelling is a `history.pushState(...)` appended to the expression,
        and nothing would answer the back button: the address would change
        and the page would not. Half of a navigation is a dead address, so
        this raises instead (DECISIONS D46)."""
        raise Error(
            "swap(..., push=True): Datastar has no history handling, so a pushed "
            "URL could not be gone back to — use a plain link for a view that "
            "needs an address"
        )


struct Html(Movable):
    """A growing HTML buffer. `open` starts an element and leaves its start
    tag open for `attr`; anything that follows — `text`, `raw`, `open`,
    `close` — ends the start tag first, so a void
    element like `<input name="t">` needs no closing call of its own."""

    var _buf: List[UInt8]
    var _open: Bool
    """Whether a start tag is open, i.e. `attr` is currently legal."""
    var _open_kind: UInt8
    """Which kind of element the open start tag is (`_kind_of`), so a
    vocabulary can pick the event without the caller naming it."""

    def __init__(out self, capacity: Int = 512):
        self._buf = List[UInt8](capacity=capacity)
        self._open = False
        self._open_kind = _KIND_OTHER

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
        self._open_kind = _kind_of(tag)

    def open_kind(self) -> ElementKind:
        """Which kind of element the open start tag is — what a
        `Vocabulary` reads to pick its event. The last element opened, if
        the start tag has since ended."""
        return ElementKind(self._open_kind)

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

    def raw_attrs(mut self, rendered: String) raises:
        """Attributes ALREADY rendered — by `attr`, `flag` and `+` in the
        expression tier below — into the open start tag, raw, and named
        so; the expression tier's `el` is the caller, and an app that has
        attribute text in hand owns the escaping if it uses this.

        One check, because `attr` and `flag` both open with a space: a
        non-empty string that does not is a child that was meant to follow
        the attrs argument — `el("p", "none")` would otherwise render
        `<pnone></p>`, silently, which is the mistake this layer exists
        to catch."""
        if not self._open:
            raise Error(
                "Html.raw_attrs(...): no start tag is open — call open(tag) first"
            )
        if rendered.byte_length() > 0 and rendered.as_bytes()[0] != _SPACE:
            raise Error(
                'Html.raw_attrs("', rendered, '"): attributes start with a '
                "space, as attr() and flag() render them — is this a child "
                "that was meant to follow the attrs argument of el()?"
            )
        self._buf.extend(rendered.as_bytes())

    def swap[V: Vocabulary](
        mut self, verb: String, url: String, target: String, push: Bool = False
    ) raises:
        """The attributes that make the open element fetch `url` with `verb`
        and replace the element `target` selects with the answer, in `V`'s
        spelling.

        `target` is a selector (`#notes`); `Fragment.swap` supplies its own,
        and this form is for an element rendered OUTSIDE the fragment it
        swaps — a page-level link — which takes `frag.selector()`.
        `push=True` also moves the address bar to `url` (a `get` only).
        """
        _swap[V](self, verb, url, target, push)

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


struct Fragment[V: Vocabulary](Movable):
    """An element that owns its id, and everything rendered inside it, in
    one library's vocabulary.

    ```mojo
    var f = Fragment[Htmx]("notes")      # <section id="notes"
    f.open("form"); f.swap("post", "/notes")
    ...
    return f.finish()                    # ...</section>
    ```

    The id is written once, by the constructor. `swap` reads it back to
    generate the targeting attribute — for htmx an `hx-target`, for
    Datastar nothing, since it morphs by that id — so a swapping element
    inside the fragment always targets the fragment it is in. `selector()`
    hands the same id to an element rendered elsewhere — a page-level link,
    say — that should swap this fragment; that is the one seam where the
    id travels as a string, and it still comes from this value rather than
    being retyped.
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

    def swap(mut self, verb: String, url: String, push: Bool = False) raises:
        """Make the open element fetch `url` with `verb` and replace THIS
        fragment with the answer. Generated from the fragment's own id, in
        `V`'s spelling. `push=True` also moves the address bar to `url`, so
        the view the swap arrives at can be reloaded and linked to: a `get`
        only, and only in a vocabulary that can (`Htmx`; `Datastar`
        refuses)."""
        _swap[Self.V](self.html, verb, url, self.selector(), push)

    def el(
        self, tag: String, verb: String, url: String, attrs: String, *children: String,
        push: Bool = False,
    ) raises -> String:
        """`swap` in the expression tier: a whole `<tag>` that fetches `url`
        with `verb` and replaces this fragment, as a string, with `attrs`
        (rendered by `attr`/`flag`) and `children` (each already markup —
        `text(...)` for data, a bare string for markup the caller trusts,
        another `el(...)`). Reads nothing from and writes nothing to the
        fragment's own buffer; `raw` it in where it belongs. The tag is
        given here because the vocabulary reads it — a Datastar form
        submits where a button clicks — and giving it once, to the
        element that is being made, is what keeps it from being spelled
        twice. `push=True` is `swap`'s: the address bar follows the swap."""
        var h = Html(128)
        h.open(tag)
        h.raw_attrs(attrs)
        _swap[Self.V](h, verb, url, self.selector(), push)
        for c in children:
            h.raw(c)
        h.close(tag)
        return h^.finish()

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


# --- the expression tier -------------------------------------------------------
#
# The builder above is statement-shaped: one call per attribute, and a list
# item is five lines. That made escaping and delimiters correct, and it is
# the wrong surface for a renderer someone writes by hand — `render_list` in
# `apps/fragment_notes` was 58 lines with 47 calls, about four per element.
# These are the same builder, one element per expression: `el("li", attrs,
# child, child)` is a string, so a renderer is a nested expression whose
# shape is the markup's. The escaping contexts stay explicit and named —
# `text(...)` for data, `attr(...)` for a value, a bare string for markup
# the caller trusts — which is the property the builder has and a template
# language does not. `Fragment.el` is `swap` in this form. Each `el`
# renders into a scratch buffer and returns a `String`, so this tier
# allocates per element; the builder is there for a renderer that cares.


def attr(name: String, value: String) -> String:
    """` name="value"`, escaped: an attribute as a string, for `el`."""
    var out = List[UInt8](capacity=name.byte_length() + value.byte_length() + 4)
    out.append(_SPACE)
    out.extend(name.as_bytes())
    out.append(_EQ)
    out.append(_QUOTE)
    escape_html_into(out, value)
    out.append(_QUOTE)
    return String(unsafe_from_utf8=Span(out))


def flag(name: String) -> String:
    """` name`: a boolean attribute as a string, for `el`."""
    return String(" ", name)


def text(s: String) -> String:
    """`s` escaped: data as text content, for `el`."""
    var out = List[UInt8](capacity=s.byte_length() + 8)
    escape_html_into(out, s)
    return String(unsafe_from_utf8=Span(out))


def el(tag: String, attrs: String, *children: String) raises -> String:
    """`<tag attrs>children</tag>`: an element as a string. `attrs` is
    what `attr`, `flag` and `+` rendered, `""` for none; each child is
    already markup — `text(...)` for data, a bare string for markup the
    caller trusts, another `el(...)`. Always closed; `void` is for the
    elements that are not."""
    var h = Html(128)
    h.open(tag)
    h.raw_attrs(attrs)
    for c in children:
        h.raw(c)
    h.close(tag)
    return h^.finish()


def void(tag: String, attrs: String) raises -> String:
    """`<tag attrs>`: a void element (`input`, `meta`, `br`) as a string."""
    var h = Html(64)
    h.open(tag)
    h.raw_attrs(attrs)
    return h^.finish()


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
