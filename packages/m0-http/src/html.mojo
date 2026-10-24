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

Three tiers over one escaping rule. The builder (`Html`, `Fragment`) is
statement-shaped and allocates once; the expression tier (`el`, `void`,
`attr`, `flag`, `text`, and `Fragment.el` for a swapping element) makes
an element a string so a renderer reads like its markup, and allocates per
element; the component tier at the bottom of this file (`El`, `Child`, the
tag functions of `m0_http.tags`, and `Fragment.element`) does the same
with a bare string meaning TEXT, escaped by construction, so nothing is
named at the hole. The expression tier is superseded by the component
tier (D67) and kept while the applications still on it move, one under
its own gate at a time. Same vocabulary seam throughout.

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
first caller of m0-core's `escape_html_into`. It was first placed in
m0-core to keep m0-http's m0-core imports few, which mistook an inventory
for the constraint: the rule is
zero upward imports and no libpython on the link line, and m0-http
importing m0-core is downward. A specific frontend library's attribute
names do not belong in the zero-dependency package `build-ffi` compiles
into `libm0core`.
"""

from std.collections import StringDict

from lightbug_http.strings import is_token_char
from m0_core.html_escape import escape_html_into
from m0_core.json_escape import escape_json_string

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


struct RequestHeader(Copyable, Movable):
    """A header a swap sends with its request: `csrf_header(token)` in
    `m0_http.login` is the one the layer names, and an application may
    make its own.

    For the write that carries no body. htmx 4 sends a DELETE's fields in
    the query string, with no setting to change it, so a CSRF token on one
    travels as a header or not at all -- a token in a URL is a token in the
    access log, the `Referer` and the history (DECISIONS D38, retired).
    """

    var name: String
    var value: String

    def __init__(out self, var name: String, var value: String):
        self.name = name^
        self.value = value^


def _check_request_header(header: RequestHeader) raises:
    """Refuse a header no client would send as written: a name that is not
    a token, a value holding a control byte (a line break would end it),
    or a value that is not ASCII -- a browser sends a header value as
    Latin-1, so UTF-8 written here would arrive as other bytes."""
    var name = header.name.as_bytes()
    if len(name) == 0:
        raise Error("swap(..., header=...): the header has no name")
    for b in name:
        if not is_token_char(b):
            raise Error(
                'swap(..., header=RequestHeader("', header.name, '", ...)): a '
                "header name is letters, digits and !#$%&'*+-.^_`|~ alone"
            )
    for b in header.value.as_bytes():
        if (b < 0x20 and b != 0x09) or b == 0x7F:
            raise Error(
                'swap(..., header=RequestHeader("', header.name, '", ...)): the '
                "value holds a control byte, which would end the header"
            )
        if b >= 0x80:
            raise Error(
                'swap(..., header=RequestHeader("', header.name, '", ...)): the '
                "value is not ASCII, and a browser sends a header as Latin-1, "
                "not as the UTF-8 it was written in"
            )


def _swap[
    V: Vocabulary
](
    mut h: Html,
    verb: String,
    url: String,
    target: String,
    push: Bool = False,
    header: Optional[RequestHeader] = None,
) raises:
    """Every swap goes through here: refuse a verb `V` does not take, then
    let `V` spell it. `hx-psot` is a silent attribute in htmx and
    `@psot(...)` a runtime error in Datastar, and a typo is the mistake
    this layer exists to catch — so the check is the layer's, and a
    conformance that checks nothing still refuses one.

    `push` makes the swap move the address bar to `url`, and it has a
    check of the layer's too: only a `get` is pushed. A pushed URL is one
    the browser GETs on reload, from a bookmark and on a history restore,
    so pushing a `post`'s is writing an address that answers 405, or
    worse, one that answers.

    `header` is a request header the swap sends (`RequestHeader`), checked
    by the layer -- a name that is a token, a value of ASCII with no
    control byte -- before the vocabulary spells it."""
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
    if header:
        _check_request_header(header.value())
    V.swap(h, verb, url, target)
    if push:
        V.push_url(h)
    if header:
        V.request_header(h, header.value())


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

    @staticmethod
    def request_header(mut h: Html, header: RequestHeader) raises:
        """Make the swap just written send `header` with its request.
        Called after `swap` (and `push_url`), on the same open element.
        The default REFUSES, as `push_url`'s does: a vocabulary with no
        spelling raises rather than render a swap that sends nothing, and
        fails the server's check only when someone clicks."""
        raise Error("swap(..., header=...): this vocabulary cannot send a request header")


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

    htmx 4 makes an app want a request HEADER: a `delete`'s fields ride
    the query string there, hard-coded, so a CSRF token on one travels as
    a header. `request_header` spells it (`hx-headers` on the element),
    which is how `apps/fragment_notes`' delete form carries its token, the
    attribute that app typed by hand before the layer could (D38,
    retired).
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

    @staticmethod
    def request_header(mut h: Html, header: RequestHeader) raises:
        """`hx-headers='{"NAME":"VALUE"}'`, which htmx reads from the element
        itself (inheritance is explicit in htmx 4, so it goes on each
        element rather than once on a parent). The name and the value are
        written as JSON strings, and `attr` escapes the whole for HTML."""
        h.attr(
            "hx-headers",
            String("{", escape_json_string(header.name), ":",
                   escape_json_string(header.value), "}"),
        )


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
    (v1.0.4), which is a runtime error for a rule the builder cannot see.

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
        """Refused. Datastar 1.0.4's free bundle has no history handling at
        all — it names neither `pushState` nor `popstate`, and the two
        attributes that would spell one, `data-replace-url` and
        `data-query-string`, are Pro — so the only
        spelling is a `history.pushState(...)` appended to the expression,
        and nothing would answer the back button: the address would change
        and the page would not. Half of a navigation is a dead address, so
        this raises instead (DECISIONS D46)."""
        raise Error(
            "swap(..., push=True): Datastar has no history handling, so a pushed "
            "URL could not be gone back to — use a plain link for a view that "
            "needs an address"
        )

    @staticmethod
    def request_header(mut h: Html, header: RequestHeader) raises:
        """Refused. Datastar sends a header from an option INSIDE the
        action expression (`@delete('/x', {headers: {...}})`), which `swap`
        writes whole and this call cannot reach, so the spelling would be
        a second one of the action. No application on the layer has asked
        for one; a Datastar write carries its token in the signal store or
        a form field instead."""
        raise Error(
            "swap(..., header=...): Datastar sends a header from inside the "
            "action, which this layer does not write — carry the token in a "
            "form field"
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
        mut self,
        verb: String,
        url: String,
        target: String,
        push: Bool = False,
        header: Optional[RequestHeader] = None,
    ) raises:
        """The attributes that make the open element fetch `url` with `verb`
        and replace the element `target` selects with the answer, in `V`'s
        spelling.

        `target` is a selector (`#notes`); `Fragment.swap` supplies its own,
        and this form is for an element rendered OUTSIDE the fragment it
        swaps — a page-level link — which takes `frag.selector()`.
        `push=True` also moves the address bar to `url` (a `get` only), and
        `header` is a request header the swap sends (`RequestHeader`).
        """
        _swap[V](self, verb, url, target, push, header)

    def text(mut self, s: String):
        """`s` as text content, escaped."""
        self._end_tag()
        escape_html_into(self._buf, s)

    def raw(mut self, s: String):
        """`s` verbatim. Markup the caller already trusts — a rendered
        fragment, a `comptime` stylesheet, an entity like `&times;`."""
        self._end_tag()
        self._buf.extend(s.as_bytes())

    def raw(mut self, e: El):
        """An element the component tier rendered, into the buffer as it
        stands: markup by construction, so `raw` is the honest name."""
        self._end_tag()
        self._buf.extend(e._buf.copy())

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

    def swap(
        mut self,
        verb: String,
        url: String,
        push: Bool = False,
        header: Optional[RequestHeader] = None,
    ) raises:
        """Make the open element fetch `url` with `verb` and replace THIS
        fragment with the answer. Generated from the fragment's own id, in
        `V`'s spelling. `push=True` also moves the address bar to `url`, so
        the view the swap arrives at can be reloaded and linked to: a `get`
        only, and only in a vocabulary that can (`Htmx`; `Datastar`
        refuses). `header` is a request header the swap sends -- the CSRF
        token on a write with no body (`csrf_header` in `m0_http.login`);
        `Htmx` spells it, `Datastar` refuses."""
        _swap[Self.V](self.html, verb, url, self.selector(), push, header)

    def el(
        self, tag: String, verb: String, url: String, attrs: String, *children: String,
        push: Bool = False,
        header: Optional[RequestHeader] = None,
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
        twice. `push=True` and `header` are `swap`'s."""
        var h = Html(128)
        h.open(tag)
        h.raw_attrs(attrs)
        _swap[Self.V](h, verb, url, self.selector(), push, header)
        for c in children:
            h.raw(c)
        h.close(tag)
        return h^.finish()

    def element(
        self, tag: String, verb: String, url: String, *children: Child,
        push: Bool = False,
        header: Optional[RequestHeader] = None,
        var **attrs: AttrValue,
    ) raises -> El:
        """`swap` in the component tier: a whole `<tag>` that fetches `url`
        with `verb` and replaces this fragment, as an `El`, with keyword
        attributes and `Child` children — a bare string is text, an `El`
        is markup. The tag is given here because the vocabulary reads it,
        as in `el`; the attributes come first and the swap after them, so
        `f.element("a", "get", url, title, href=url)` renders the bytes
        `f.el("a", "get", url, attr("href", url), text(title))` does. A
        swap attribute among the keywords is refused as everywhere in the
        tier: the point of this method is that nobody types one. `push=True`
        and `header` are `swap`'s. Reads nothing from and writes nothing to
        the fragment's own buffer; `raw` it in where it belongs."""
        var h = Html(128)
        h.open(tag)
        _write_component_attrs(h._buf, attrs)
        _swap[Self.V](h, verb, url, self.selector(), push, header)
        h._end_tag()
        for c in children:
            h._buf.extend(c._buf.copy())
        h.close(tag)
        return El(h._buf.copy())

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

    def raw(mut self, e: El):
        self.html.raw(e)

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


# --- the component tier ----------------------------------------------------
#
# The expression tier above made an element a string, and left one hole in
# its own rule: a bare string child is markup the caller trusts, so a
# request-derived value passed without `text(...)` is an injection that
# reads like every other argument. This tier closes it from the other
# side. A bare `String` is TEXT and is escaped by construction; markup
# goes in by name, as an `El` another tag function made or `Raw` wrapped.
# The tag functions (`Div`, `P`, `Input` ...) live in `m0_http.tags`, each
# one line over `_element`/`_void_element` here, and a void element takes
# no children, so `Input(P("x"))` is a compile error rather than
# `<input><p>x</p></input>`.
#
# Measured on 2026-10-24 (docs/notes/a-component-tier.md): one `List[UInt8]`
# per element, presized from its parts, renders a 50-item list in 24 us
# against the expression tier's 28 and the builder's 7.5. A tree rendered
# once at the root was tried and did not pay (38 us): the children are
# evaluated before the parent whatever the shape, so each allocates, and
# the keyword dictionary is a quarter of the cost. The builder stays for a
# renderer that is hot (D19); this tier replaces the expression tier for
# the rest, application by application under each one's gate (D67).


comptime _HYPHEN = UInt8(45)  # '-'
comptime _UNDERSCORE = UInt8(95)  # '_'


struct El(Copyable, Movable):
    """An element already rendered: the bytes of its markup.

    Made by a tag function (`m0_http.tags`), by `element` for a tag the
    module does not name, by `void_element`, or by `Raw` for markup the
    caller wrote. It is a child of another element as it stands, goes into
    a builder or a fragment through `raw`, and `html()` reads it as a
    `String` for `reply.html`.
    """

    var _buf: List[UInt8]

    def __init__(out self, var buf: List[UInt8]):
        self._buf = buf^

    def html(self) -> String:
        """The markup as a `String` — the boundary where the tier hands
        over to `reply.html`, a `Fragment.raw` or a frame."""
        return String(unsafe_from_utf8=Span(self._buf))

    def byte_length(self) -> Int:
        return len(self._buf)


struct Child(Copyable, Movable):
    """What a tag function takes as a child: a `String` or literal, which
    is TEXT and escaped; an `El`, which is markup; or a `List[El]`, which
    is each in turn. The conversions are implicit, so a call site reads
    as its markup; the escaping follows from the type and is never named
    at the hole, which is the whole difference from `el`."""

    var _buf: List[UInt8]

    @implicit
    def __init__(out self, s: String):
        self._buf = List[UInt8](capacity=s.byte_length() + 8)
        escape_html_into(self._buf, s)

    @implicit
    def __init__(out self, s: StringLiteral):
        var st = String(s)
        self._buf = List[UInt8](capacity=st.byte_length() + 8)
        escape_html_into(self._buf, st)

    @implicit
    def __init__(out self, e: El):
        self._buf = e._buf.copy()

    @implicit
    def __init__(out self, xs: List[El]):
        var n = 0
        for x in xs:
            n += len(x._buf)
        self._buf = List[UInt8](capacity=n)
        for x in xs:
            self._buf.extend(x._buf.copy())


struct AttrValue(Copyable, Movable):
    """What a keyword attribute takes: a `String` or literal, escaped and
    quoted; an `Int`, written in decimal; or a `Bool`, which is the
    attribute's presence — `checked=True` renders ` checked` and
    `checked=False` renders nothing."""

    var _value: String
    var _present: Bool
    var _bare: Bool

    @implicit
    def __init__(out self, s: String):
        self._value = s
        self._present = True
        self._bare = False

    @implicit
    def __init__(out self, s: StringLiteral):
        self._value = String(s)
        self._present = True
        self._bare = False

    @implicit
    def __init__(out self, n: Int):
        self._value = String(n)
        self._present = True
        self._bare = False

    @implicit
    def __init__(out self, b: Bool):
        self._value = String()
        self._present = b
        self._bare = True


def _attr_name(key: String) -> String:
    """The attribute a keyword spells: `cls` is `class` (a keyword in
    Mojo), a leading `_` is dropped (`_for` is `for`), and every other
    `_` is `-` (`hx_boost`, `aria_label`, `data_n`)."""
    if key == "cls":
        return "class"
    var b = key.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    if len(b) > 1 and b[0] == _UNDERSCORE:
        i = 1
    while i < len(b):
        out.append(_HYPHEN if b[i] == _UNDERSCORE else b[i])
        i += 1
    return String(unsafe_from_utf8=Span(out))


def _check_component_attr(name: String) raises:
    """Refuse a swap attribute typed as a keyword. The layer's rule is
    that an application never spells one — the id and the vocabulary
    come from the fragment — and this tier has no `attrs` string to grep,
    so the rule is held here, at render, where an application outside the
    tree meets it too. Refused: the attributes the two shipped
    vocabularies write (`hx-VERB`, `hx-target`, `hx-swap`,
    `hx-push-url`, `hx-headers`) and `data-on` or anything under
    `data-on-`, which a keyword cannot spell anyway (Datastar's keys
    carry a `:`). Compared lowercased, because HTML reads an attribute
    name that way: `HX_GET=` is htmx's `hx-get`. Other `hx-*` attributes
    pass (`hx_boost`, `hx_confirm`, `hx_indicator` are not a swap), and
    so does a `data-` name that only begins with the letters
    (`data_one`)."""
    var swap = False
    var low = name.lower()
    if low == "data-on" or low.startswith("data-on-"):
        swap = True
    elif low.startswith("hx-"):
        var tail = String(unsafe_from_utf8=low.as_bytes()[3:])
        swap = (
            tail == "target" or tail == "swap" or tail == "push-url"
            or tail == "headers" or _verb_is_in(tail, HTMX_VERBS)
        )
    if swap:
        raise Error(
            'tag(..., ', name, '=...): a swap attribute is the vocabulary\'s to '
            "spell — write the element with Fragment.element(tag, verb, url, ...) "
            "so the target id and the attribute names come from the fragment"
        )


def _write_component_attrs(mut buf: List[UInt8], attrs: StringDict[AttrValue]) raises:
    for item in attrs.items():
        ref v = item.value
        if not v._present:
            continue
        var name = _attr_name(item.key)
        _check_component_attr(name)
        buf.append(_SPACE)
        buf.extend(name.as_bytes())
        if v._bare:
            continue
        buf.append(_EQ)
        buf.append(_QUOTE)
        escape_html_into(buf, v._value)
        buf.append(_QUOTE)


def _attrs_size(attrs: StringDict[AttrValue]) -> Int:
    var n = 0
    for item in attrs.items():
        n += item.key.byte_length() + item.value._value.byte_length() + 4
    return n


def _element(tag: String, children: VariadicList[Child, False], attrs: StringDict[AttrValue]) raises -> El:
    """`<tag attrs>children</tag>` as an `El`, into one buffer sized from
    its parts. What every tag function in `m0_http.tags` calls."""
    var n = 2 * tag.byte_length() + 5 + _attrs_size(attrs)
    for c in children:
        n += len(c._buf)
    var buf = List[UInt8](capacity=n)
    buf.append(_LT)
    buf.extend(tag.as_bytes())
    _write_component_attrs(buf, attrs)
    buf.append(_GT)
    for c in children:
        buf.extend(c._buf.copy())
    buf.append(_LT)
    buf.append(_SLASH)
    buf.extend(tag.as_bytes())
    buf.append(_GT)
    return El(buf^)


def _void_element(tag: String, attrs: StringDict[AttrValue]) raises -> El:
    """`<tag attrs>` as an `El`: a void element, which has no children and
    no closing tag."""
    var buf = List[UInt8](capacity=tag.byte_length() + 2 + _attrs_size(attrs))
    buf.append(_LT)
    buf.extend(tag.as_bytes())
    _write_component_attrs(buf, attrs)
    buf.append(_GT)
    return El(buf^)


def element(tag: String, *children: Child, var **attrs: AttrValue) raises -> El:
    """An element whose tag `m0_http.tags` does not name — a custom element,
    or `html`, whose name the builder already holds: `element("my-card",
    P("x"), cls="wide")`. Everything else is a tag function."""
    return _element(tag, children, attrs)


def void_element(tag: String, var **attrs: AttrValue) raises -> El:
    """A void element whose tag `m0_http.tags` does not name."""
    return _void_element(tag, attrs)


def Raw(markup: String) -> El:
    """Markup the caller wrote, as an `El`, so it can be a child: an
    entity (`Raw("&times;")`), a `comptime` stylesheet, a fragment another
    renderer finished. It says so by name, as the builder's `raw` does;
    a request-derived value here is an injection."""
    var buf = List[UInt8](capacity=markup.byte_length())
    buf.extend(markup.as_bytes())
    return El(buf^)
