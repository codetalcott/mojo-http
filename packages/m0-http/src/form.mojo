"""`application/x-www-form-urlencoded` request bodies.

The only thing an htmx or plain `<form method=post>` app could not do
without writing its own parser: nothing in the tree decoded a form body.
`form(req)` does, into a `Form` — an ORDERED MULTIMAP, because
`<input type=checkbox name=tag>` legitimately repeats one key and every
tick must survive.

Refuses to guess: `form(req)` returns None unless the request says
`Content-Type: application/x-www-form-urlencoded` (parameters such as
`; charset=UTF-8` allowed, case ignored; the media type itself compared
whole, so a look-alike subtype is not one). Without that rule a JSON body
posted to a form route would parse as one field named after the whole
document — or, if its bytes happened to be form-shaped, as a real form the
client never meant to send. `Optional` rather than an empty `Form`, so
"no form" and "a form with nothing in it" cannot be confused and the
check cannot be forgotten: a view that answers 400 on None gets that
status for a JSON POST even when every field it reads has a default.

**Deliberately not factored out of `URI.parse`.** The query loop at
`lightbug_http/uri.mojo` looks identical and means something different: it
fills `Dict[String, String]`, last-wins, because `req.uri.queries` has a
long-standing contract; this preserves repeats. A single shared loop would
force one of the two to change, and routing the query through two lists
and a copy would add two allocations to every request carrying a query
string. What is genuinely shared is already shared — `unquote` and the
delimiters. The anti-drift device is a TEST, not a type:
`test_form.mojo` runs one table of encodings through both parsers and
asserts they decode each value identically.

`multipart/form-data` is not here (a boundary scanner, per-part headers, a
disposition model and a spill-to-disk policy; the app that uploads a file
is what would justify it).
"""

from lightbug_http.header import HeaderKey, ascii_lower_byte
from lightbug_http.http import HTTPRequest
from lightbug_http.uri import QueryDelimiters, unquote

from .reply import body_string

comptime FORM_CONTENT_TYPE = "application/x-www-form-urlencoded"


struct Form(Movable, Sized):
    """Decoded form fields, in body order, repeats kept."""

    var _keys: List[String]
    var _values: List[String]

    def __init__(out self):
        self._keys = List[String]()
        self._values = List[String]()

    def __len__(self) -> Int:
        """How many fields the body carried, repeats counted."""
        return len(self._keys)

    def key(self, i: Int) -> String:
        return self._keys[i]

    def value(self, i: Int) -> String:
        return self._values[i]

    def has(self, name: String) -> Bool:
        """Whether the body carried `name` at all, even with an empty value."""
        return Bool(self.get(name))

    def get(self, name: String) -> Optional[String]:
        """The first value for `name`, or None when the body has no such
        field. Tells absent from empty, which `first` does not. The one
        place a key is matched; `has`, `first` and `all` go through it."""
        for i in range(len(self._keys)):
            if self._keys[i] == name:
                return self._values[i]
        return None

    def first(self, name: String) -> String:
        """The first value for `name`, empty when absent — the convention
        `parse_json_field` uses, for a view that treats both the same."""
        return self.get(name).or_else(String(""))

    def all(self, name: String) -> List[String]:
        """Every value for `name`, in body order: a checkbox group."""
        var out = List[String]()
        for i in range(len(self._keys)):
            if self._keys[i] == name:
                out.append(self._values[i])
        return out^

    def _add(mut self, var key: String, var value: String):
        self._keys.append(key^)
        self._values.append(value^)


def is_form(req: HTTPRequest) -> Bool:
    """Whether the request declares a urlencoded form body: the media
    type, before any `;`, equals `application/x-www-form-urlencoded`
    ignoring case. Compared over the header's bytes, without allocating."""
    var i = req.headers._find(HeaderKey.CONTENT_TYPE.as_bytes())
    if i < 0:
        return False
    var v = req.headers.value_span(i)
    var want = FORM_CONTENT_TYPE.as_bytes()
    # Skip leading whitespace, then the media type runs to `;` or a space.
    var s = 0
    while s < len(v) and (v[s] == UInt8(32) or v[s] == UInt8(9)):
        s += 1
    var e = s
    while e < len(v) and v[e] != UInt8(59) and v[e] != UInt8(32) and v[e] != UInt8(9):
        e += 1
    if e - s != len(want):
        return False
    for j in range(len(want)):
        if ascii_lower_byte(v[s + j]) != want[j]:
            return False
    return True


def form(req: HTTPRequest) -> Optional[Form]:
    """The request's form fields, or None when the body is not a form."""
    if not is_form(req):
        return None
    return parse_form(body_string(req))


def parse_form(body: String) -> Form:
    """Decode a urlencoded body, whatever content type it arrived under.

    Same decoding as the query string: `+` is a space, `%XX` is a byte, a
    field with no `=` has an empty value, and a field whose name decodes
    to nothing is skipped (`a=1&&b=2` is two fields).
    """
    var out = Form()
    if body.byte_length() == 0:
        return out^
    for item in body.split(QueryDelimiters.ITEM):
        var kv = String(item).split(QueryDelimiters.ITEM_ASSIGN, 1)
        var key = unquote[expand_plus=True](String(kv[0]))
        if key.byte_length() == 0:
            continue
        if len(kv) == 2:
            out._add(key^, unquote[expand_plus=True](String(kv[1])))
        else:
            out._add(key^, String(""))
    return out^
