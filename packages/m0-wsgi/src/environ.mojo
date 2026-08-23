"""The WSGI environ mapping, the half that needs no interpreter.

The environ dict itself is built by `bridge.mojo` through the CPython C API.
What lives here is the pure half — the CGI header-name transform and the
latin-1 → UTF-8 byte mapping the C API needs — both testable without an
interpreter, which is why they are not in `bridge.mojo`.

**Why latin-1 arrives as UTF-8.** PEP 3333 tunnels raw request bytes through
`str` by decoding them as latin-1, so every byte 0x00–0xFF maps to the
codepoint of the same value. Mojo 1.0's CPython bindings expose
`PyUnicode_DecodeUTF8` and no latin-1 decoder at all (checked against the
pinned toolchain: there is no `PyUnicode_DecodeLatin1`, and no `PyBytes_*`
of any kind). But UTF-8 *encoding* those same codepoints is a two-line
transform — one byte below 0x80, two above — so encoding latin-1 text as
UTF-8 here and decoding it as UTF-8 there produces exactly the `str` a
latin-1 decode would have. Bytes ≥ 0x80 are rare but real: `PATH_INFO`
arrives percent-*decoded*, so any non-ASCII path carries them.

`PATH_INFO` comes from `req.uri.path`, which the URI parser has already
percent-decoded — which is what PEP 3333 asks for. `QUERY_STRING` comes from
`req.uri.query_string`, which is deliberately still raw.
"""


def cgi_header_name(header_key: String) -> String:
    """Lowercased header name → CGI variable name.

    `content-type` → `CONTENT_TYPE`, everything else gets the `HTTP_` prefix:
    `accept-encoding` → `HTTP_ACCEPT_ENCODING`. PEP 3333 requires
    Content-Type and Content-Length *without* the prefix.

    The allocating form, kept because it is the readable statement of the
    rule and what `test_environ.mojo` checks. The serving path does not call
    it — see `append_cgi_name_as_utf8`, which writes the same bytes straight
    into a reused buffer without building three Strings to do it.
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


def all_ascii(b: Span[Byte, _]) -> Bool:
    """Whether every byte is below 0x80.

    The fast path that makes the latin-1 mapping free in the common case:
    ASCII text is its own UTF-8 encoding, so the bytes can be handed to
    `PyUnicode_DecodeUTF8` where they already are, with no copy at all.
    """
    for i in range(len(b)):
        if b[i] >= 0x80:
            return False
    return True


def _append_byte_as_utf8(mut out: List[UInt8], c: UInt8):
    """Append the UTF-8 encoding of the codepoint numbered `c`.

    One byte below 0x80, two above — the whole of latin-1 → UTF-8.
    """
    if c < 0x80:
        out.append(c)
    else:
        out.append(0xC0 | (c >> 6))
        out.append(0x80 | (c & 0x3F))


def append_latin1_as_utf8(mut out: List[UInt8], b: Span[Byte, _]):
    """Append `b`'s latin-1 text to `out`, encoded as UTF-8.

    Callers should test `all_ascii` first and skip this entirely when it
    answers True; this is the slow path for the bytes that need it.
    """
    for i in range(len(b)):
        _append_byte_as_utf8(out, b[i])


def append_cgi_name_as_utf8(mut out: List[UInt8], name: Span[Byte, _]):
    """Append `name`'s CGI form to `out` as UTF-8, allocating no String.

    Same rule as `cgi_header_name`: uppercase, `-` → `_`, and the `HTTP_`
    prefix unless PEP 3333 says otherwise. The name arrives already
    lowercased (`Headers` normalizes on insert), so the uppercase is a
    byte-wise subtract on a-z and nothing needs a locale.

    This is the hot one — it runs once per header per request. Projecting
    twelve headers through `cgi_header_name` cost three String allocations
    each (`upper()`, `replace()`, and the prefixed result), which with
    `keys()` and `get()` on top was 48us per request.

    A header name is very nearly always ASCII, but nothing on the wire
    guarantees it, so bytes ≥ 0x80 go through the same latin-1 → UTF-8
    mapping as every other field rather than producing a name that is not
    valid UTF-8 — which `PyUnicode_DecodeUTF8` rejects, turning one
    malformed header into a failed request.
    """
    if not _is_unprefixed(name):
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
            _append_byte_as_utf8(out, c)


def cgi_name_utf8(name: Span[Byte, _]) -> List[UInt8]:
    """`append_cgi_name_as_utf8` into a fresh list.

    The allocating convenience form, for tests and for callers with no
    scratch buffer to reuse. The serving path does not use it — `PyBridge`
    appends into a buffer it keeps between requests.
    """
    var out = List[UInt8](capacity=len(name) + 5)
    append_cgi_name_as_utf8(out, name)
    return out^
