"""`HTTPRequest` → the request blob the bridge ships to Python.

The environ dict itself is built *inside* the interpreter by the bridge's
shim, because building it from Mojo would leak every entry (see
`bridge.mojo`). What lives here is the pure half: the CGI header-name
transform and the blob serializer, both testable without an interpreter.

Blob layout, all integers little-endian u32, strings raw bytes:

    method | path | query | protocol      each as  u32 len + bytes
    u32 header-count
    per header:  cgi-name, value          each as  u32 len + bytes
    u32 body-len + body bytes

`PATH_INFO` comes from `req.uri.path`, which the URI parser has already
percent-decoded — which is what PEP 3333 asks for. `QUERY_STRING` comes from
`req.uri.query_string`, which is deliberately still raw. The shim decodes
every string field as latin-1, PEP 3333's byte-tunneling convention.
"""

from lightbug_http import HTTPRequest


def cgi_header_name(header_key: String) -> String:
    """Lowercased header name → CGI variable name.

    `content-type` → `CONTENT_TYPE`, everything else gets the `HTTP_` prefix:
    `accept-encoding` → `HTTP_ACCEPT_ENCODING`. PEP 3333 requires
    Content-Type and Content-Length *without* the prefix.

    The allocating form, kept because it is the readable statement of the
    rule and what `test_environ.mojo` checks. The serializer does not call
    it — see `_append_cgi_name`, which writes the same bytes straight into
    the blob without building three Strings to do it.
    """
    var upper = header_key.upper().replace("-", "_")
    if upper == "CONTENT_TYPE" or upper == "CONTENT_LENGTH":
        return upper
    return String("HTTP_", upper)


comptime _CONTENT_TYPE = "content-type"
comptime _CONTENT_LENGTH = "content-length"


def _is_unprefixed(name: Span[Byte, _]) -> Bool:
    """Whether this (lowercased) header name is one PEP 3333 leaves bare."""
    var n = len(name)
    if n != len(_CONTENT_TYPE.as_bytes()) and n != len(_CONTENT_LENGTH.as_bytes()):
        return False
    return _bytes_equal(name, _CONTENT_TYPE.as_bytes()) or _bytes_equal(
        name, _CONTENT_LENGTH.as_bytes()
    )


def _bytes_equal(a: Span[Byte, _], b: Span[Byte, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _append_u32(mut out: List[UInt8], value: Int):
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))


def _append_str(mut out: List[UInt8], s: String):
    _append_u32(out, s.byte_length())
    out.extend(s.as_bytes())


def _append_bytes(mut out: List[UInt8], b: Span[Byte, _]):
    _append_u32(out, len(b))
    out.extend(b)


def _append_cgi_name(mut out: List[UInt8], name: Span[Byte, _]):
    """Write `name`'s CGI form into the blob without allocating a String.

    Same rule as `cgi_header_name`: uppercase, `-` → `_`, and the `HTTP_`
    prefix unless PEP 3333 says otherwise. The name arrives already
    lowercased (`Headers` normalizes on insert), so the uppercase is a
    byte-wise subtract on a-z and nothing needs a locale.

    This is the hot one. Projecting twelve headers through
    `cgi_header_name` cost three String allocations each — `upper()`,
    `replace()`, and the prefixed result — and that, with `keys()` and
    `get()` on top, was 48us per request.
    """
    var prefixed = not _is_unprefixed(name)
    _append_u32(out, len(name) + (5 if prefixed else 0))
    if prefixed:
        out.append(UInt8(ord("H")))
        out.append(UInt8(ord("T")))
        out.append(UInt8(ord("T")))
        out.append(UInt8(ord("P")))
        out.append(UInt8(ord("_")))
    for i in range(len(name)):
        var c = name[i]
        if c == UInt8(ord("-")):
            out.append(UInt8(ord("_")))
        elif c >= UInt8(ord("a")) and c <= UInt8(ord("z")):
            out.append(c - 32)
        else:
            out.append(c)


def serialize_request(req: HTTPRequest) raises -> List[UInt8]:
    """Serialize one request into the bridge's blob format."""
    # Reserve the whole blob up front so filling it never reallocates: four
    # length-prefixed fields, then per header a prefixed name and a value,
    # then the body. Over-reserving slightly is free; growing is not.
    var reserve = 16 + req.method.byte_length() + req.uri.path.byte_length()
    reserve += req.uri.query_string.byte_length() + req.protocol.byte_length()
    reserve += 4
    for i in range(req.headers.count()):
        reserve += 8 + 5 + len(req.headers.name_span(i))
        reserve += len(req.headers.value_span(i))
    reserve += 4 + len(req.body_raw)
    var out = List[UInt8](capacity=reserve)

    _append_str(out, req.method)
    _append_str(out, req.uri.path)
    _append_str(out, req.uri.query_string)
    _append_str(out, req.protocol)

    # Walked by index over the header map's own spans: no `keys()` snapshot,
    # no `get()` lookup per key, no String anywhere. `count()` is the number
    # of entries, so the count cannot disagree with what follows it.
    var n_headers = req.headers.count()
    _append_u32(out, n_headers)
    for i in range(n_headers):
        _append_cgi_name(out, req.headers.name_span(i))
        _append_bytes(out, req.headers.value_span(i))

    _append_u32(out, len(req.body_raw))
    out.extend(Span(req.body_raw))

    return out^
