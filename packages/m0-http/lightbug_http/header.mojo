from std.memory import unsafe_memcpy
from lightbug_http.http.parsing import (
    HTTPHeader,
    _first_lane,
    http_parse_request_headers,
)
from lightbug_http.io.bytes import Bytes, ByteWriter
from lightbug_http.strings import BytesConstant, lineBreak
from std.collections.span import Span
from std.utils import Variant


struct HeaderKey:
    """Standard HTTP header key constants (lowercase for normalization)."""

    # General Headers
    comptime CONNECTION = "connection"
    comptime DATE = "date"
    comptime TRAILER = "trailer"
    comptime TRANSFER_ENCODING = "transfer-encoding"
    comptime UPGRADE = "upgrade"
    comptime VIA = "via"
    comptime WARNING = "warning"

    # Request Headers
    comptime ACCEPT = "accept"
    comptime ACCEPT_CHARSET = "accept-charset"
    comptime ACCEPT_ENCODING = "accept-encoding"
    comptime ACCEPT_LANGUAGE = "accept-language"
    comptime AUTHORIZATION = "authorization"
    comptime EXPECT = "expect"
    comptime FROM = "from"
    comptime HOST = "host"
    comptime IF_MATCH = "if-match"
    comptime IF_MODIFIED_SINCE = "if-modified-since"
    comptime IF_NONE_MATCH = "if-none-match"
    comptime IF_RANGE = "if-range"
    comptime IF_UNMODIFIED_SINCE = "if-unmodified-since"
    comptime MAX_FORWARDS = "max-forwards"
    comptime PROXY_AUTHORIZATION = "proxy-authorization"
    comptime RANGE = "range"
    comptime REFERER = "referer"
    comptime TE = "te"
    comptime USER_AGENT = "user-agent"

    # Response Headers
    comptime ACCEPT_RANGES = "accept-ranges"
    comptime AGE = "age"
    comptime ETAG = "etag"
    comptime LOCATION = "location"
    comptime PROXY_AUTHENTICATE = "proxy-authenticate"
    comptime RETRY_AFTER = "retry-after"
    comptime SERVER = "server"
    comptime VARY = "vary"
    comptime WWW_AUTHENTICATE = "www-authenticate"

    # Entity Headers (Content)
    comptime ALLOW = "allow"
    comptime CONTENT_ENCODING = "content-encoding"
    comptime CONTENT_LANGUAGE = "content-language"
    comptime CONTENT_LENGTH = "content-length"
    comptime CONTENT_LOCATION = "content-location"
    comptime CONTENT_MD5 = "content-md5"
    comptime CONTENT_RANGE = "content-range"
    comptime CONTENT_TYPE = "content-type"
    comptime CONTENT_DISPOSITION = "content-disposition"
    comptime EXPIRES = "expires"
    comptime LAST_MODIFIED = "last-modified"

    # Caching Headers
    comptime CACHE_CONTROL = "cache-control"
    comptime PRAGMA = "pragma"

    # Cookie Headers
    comptime COOKIE = "cookie"
    comptime SET_COOKIE = "set-cookie"

    # CORS Headers
    comptime ACCESS_CONTROL_ALLOW_ORIGIN = "access-control-allow-origin"
    comptime ACCESS_CONTROL_ALLOW_CREDENTIALS = "access-control-allow-credentials"
    comptime ACCESS_CONTROL_ALLOW_HEADERS = "access-control-allow-headers"
    comptime ACCESS_CONTROL_ALLOW_METHODS = "access-control-allow-methods"
    comptime ACCESS_CONTROL_EXPOSE_HEADERS = "access-control-expose-headers"
    comptime ACCESS_CONTROL_MAX_AGE = "access-control-max-age"
    comptime ACCESS_CONTROL_REQUEST_HEADERS = "access-control-request-headers"
    comptime ACCESS_CONTROL_REQUEST_METHOD = "access-control-request-method"
    comptime ORIGIN = "origin"

    # Security Headers
    comptime STRICT_TRANSPORT_SECURITY = "strict-transport-security"
    comptime CONTENT_SECURITY_POLICY = "content-security-policy"
    comptime CONTENT_SECURITY_POLICY_REPORT_ONLY = "content-security-policy-report-only"
    comptime X_CONTENT_TYPE_OPTIONS = "x-content-type-options"
    comptime X_FRAME_OPTIONS = "x-frame-options"
    comptime X_XSS_PROTECTION = "x-xss-protection"
    comptime REFERRER_POLICY = "referrer-policy"
    comptime PERMISSIONS_POLICY = "permissions-policy"
    comptime CROSS_ORIGIN_EMBEDDER_POLICY = "cross-origin-embedder-policy"
    comptime CROSS_ORIGIN_EMBEDDER_POLICY_REPORT_ONLY = "cross-origin-embedder-policy-report-only"
    comptime CROSS_ORIGIN_OPENER_POLICY = "cross-origin-opener-policy"
    comptime CROSS_ORIGIN_OPENER_POLICY_REPORT_ONLY = "cross-origin-opener-policy-report-only"
    comptime CROSS_ORIGIN_RESOURCE_POLICY = "cross-origin-resource-policy"

    # Other Common Headers
    comptime LINK = "link"
    comptime KEEP_ALIVE = "keep-alive"
    comptime PROXY_CONNECTION = "proxy-connection"
    comptime ALT_SVC = "alt-svc"


@fieldwise_init
struct HeaderKeyNotFoundError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when a header key is not found."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("HeaderKeyNotFoundError: Key not found in headers")


@fieldwise_init
struct InvalidHTTPRequestError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when the HTTP request is malformed."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("InvalidHTTPRequestError: Not a valid HTTP request")


@fieldwise_init
struct IncompleteHTTPRequestError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when the HTTP request is incomplete (need more data)."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("IncompleteHTTPRequestError: Incomplete HTTP request")


@fieldwise_init
struct UnsupportedHTTPRequestError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when a well-formed request asks for what this server
    does not implement: the `CONNECT` method, or a transfer coding before
    the final `chunked`. The event loop answers it 501 (Not Implemented,
    RFC 9110 §15.6.2) and closes, where a malformed request is answered
    400."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("UnsupportedHTTPRequestError: Not implemented by this server")


@fieldwise_init
struct EmptyBufferError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when buffer has no data available."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("EmptyBufferError: No data available in buffer")


@fieldwise_init
struct RequestParseError(Movable, Writable):
    """Error variant for HTTP request parsing.

    Can be InvalidHTTPRequestError, IncompleteHTTPRequestError,
    EmptyBufferError, or UnsupportedHTTPRequestError.
    """

    comptime type = Variant[
        InvalidHTTPRequestError,
        IncompleteHTTPRequestError,
        EmptyBufferError,
        UnsupportedHTTPRequestError,
    ]
    var value: Self.type

    @implicit
    def __init__(out self, value: InvalidHTTPRequestError):
        self.value = value

    @implicit
    def __init__(out self, value: IncompleteHTTPRequestError):
        self.value = value

    @implicit
    def __init__(out self, value: EmptyBufferError):
        self.value = value

    @implicit
    def __init__(out self, value: UnsupportedHTTPRequestError):
        self.value = value

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[InvalidHTTPRequestError]():
            writer.write(self.value[InvalidHTTPRequestError])
        elif self.value.isa[IncompleteHTTPRequestError]():
            writer.write(self.value[IncompleteHTTPRequestError])
        elif self.value.isa[EmptyBufferError]():
            writer.write(self.value[EmptyBufferError])
        elif self.value.isa[UnsupportedHTTPRequestError]():
            writer.write(self.value[UnsupportedHTTPRequestError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()


@fieldwise_init
struct ParsedRequestHeaders(Movable):
    """Result of parsing HTTP request headers.

    This contains all information extracted from the request line and headers,
    along with the number of bytes consumed from the input buffer.
    """

    var method: String
    var path: String
    var protocol: String
    var headers: Headers
    var cookies: List[String]
    var bytes_consumed: Int
    """Number of bytes consumed from the input buffer (includes the final \\r\\n\\r\\n)."""

    def content_length(self) -> Int:
        """Get the Content-Length header value, or 0 if not present."""
        return self.headers.content_length()

    def is_chunked_body(self) -> Bool:
        """Return True if Transfer-Encoding: chunked is present.

        Phase 1b: used by the server loops to distinguish chunked bodies
        (no Content-Length) from fixed-length bodies.

        Case-INSENSITIVELY, as RFC 9112 §7.1 requires of transfer-coding
        names. It was a plain substring test before, so `Transfer-Encoding:
        CHUNKED` answered False here and, having no Content-Length either,
        was dispatched as a request with an empty body while its actual
        body sat unread in the buffer. Any proxy in front reading the same
        header the way the RFC says would frame that body — a framing
        disagreement between two hops is the ingredient request smuggling
        is made of. The `chunked`-must-be-last check in `parse_request_line`
        had the same gap and is fixed with it.

        The FINAL coding is asked, in the value's bytes with ASCII case
        folding and nothing else, as `parse_request_headers` asks it: a
        Unicode `lower()` read KELVIN SIGN as `k` (review record LF58). A
        parsed request carrying the header has `chunked` last, or the parse
        refused it, so this is True exactly when the header is there.
        """
        var i = self.headers.known_index(KH_TRANSFER_ENCODING)
        if i < 0:
            return False
        var te = self.headers.value_span(i)
        var b = len(te)
        var a = b
        while a > 0 and te[a - 1] != 0x2C:  # the last member, after its comma
            a -= 1
        while a < b and (te[a] == 0x20 or te[a] == 0x09):
            a += 1
        while b > a and (te[b - 1] == 0x20 or te[b - 1] == 0x09):
            b -= 1
        return name_is(te[a:b], "chunked")

    def faulty_framing(self) -> Bool:
        """Whether RFC 9112 §6.1 calls this request's framing faulty.

        An HTTP/1.0 message carrying `Transfer-Encoding` MUST be treated as
        if its framing were faulty, and the connection closed after it is
        processed (SPEC B15). HTTP/1.0 predates the field, so a 1.0 hop in
        front may have framed the body by something else entirely, and the
        bytes after it are not trusted to be the next request. The loop
        serves the request and closes, whatever its `Connection` asked. It
        used to de-chunk the body and keep the connection alive, so a
        request pipelined behind it was answered too.
        """
        return (
            self.protocol == "HTTP/1.0"
            and self.headers.known_index(KH_TRANSFER_ENCODING) >= 0
        )

@fieldwise_init
struct Header(Copyable, Writable):
    """A single HTTP header key-value pair."""

    var key: String
    var value: String

    def write_to[T: Writer, //](self, mut writer: T):
        writer.write(self.key, ": ", self.value, lineBreak)


@always_inline
def write_header[T: Writer](mut writer: T, key: String, value: String):
    """Write a header in HTTP format to a writer."""
    writer.write(key, ": ", value, lineBreak)


def encode_latin1_header_value(value: String) -> List[UInt8]:
    """Transcode a header value from UTF-8 to ISO-8859-1 bytes.

    HTTP/1.1 header field values must be representable in ISO-8859-1 (RFC 9110 §5.5).
    - Codepoints U+0000–U+007F: single byte, passed through unchanged.
    - Codepoints U+0080–U+00FF, the two-byte sequences `C2 80` to `C3 BF`:
      encoded as their single ISO-8859-1 byte. Nothing else is decoded.
    - Every other byte goes out as it came in: a codepoint above U+00FF has
      no ISO-8859-1 byte (best-effort fallback — use RFC 8187 encoding
      instead), and invalid UTF-8 (obs-text from parsing) is not UTF-8.

    An overlong sequence is invalid UTF-8 too, and must stay bytes: this
    runs AFTER the writers have refused a value holding CR, LF or NUL
    (SPEC G2), and decoding the three-byte `E0 80 8D` or the four-byte
    `F0 80 80 8A` -- which `unquote` makes of `%E0%80%8D` or
    `%F0%80%80%8A` in a `?next=` a view redirects to -- wrote the real CR
    or LF it encodes, splitting the response the refusal had passed
    (SPEC G19). Restricting the decode to
    the two lead bytes whose sequences land in U+0080–U+00FF is the whole
    rule: no output byte below 0x80 can come from anything but itself.
    """
    var utf8 = value.as_bytes()
    var n = len(utf8)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var b = utf8[i]
        if (b == 0xC2 or b == 0xC3) and i + 1 < n:
            var b2 = utf8[i + 1]
            if b2 >= 0x80 and b2 <= 0xBF:
                out.append(((b & 0x03) << 6) | (b2 & 0x3F))
                i += 2
                continue
        out.append(b)
        i += 1
    return out^


@always_inline
def ascii_lower_byte(b: Byte) -> Byte:
    """ASCII-lowercase a single byte; non-letters pass through unchanged.

    Header field names are ASCII by definition (RFC 9110 §5.1), so this is
    the whole of case normalization for them — no Unicode tables, no
    allocation.
    """
    return (b | 0x20) if (b >= 0x41 and b <= 0x5A) else b


@always_inline
def name_is(name: Span[Byte, _], lowercase: StaticString) -> Bool:
    """Whether a raw header name equals a known-lowercase constant.

    Lets the parser dispatch on field names without calling `.lower()`,
    which allocated a copy of every header name on every request.
    """
    var want = lowercase.as_bytes()
    if len(name) != len(want):
        return False
    for i in range(len(name)):
        if ascii_lower_byte(name[i]) != want[i]:
            return False
    return True


# The names the server itself asks a `Headers` about, per request, on the
# event loop: framing (content-length, transfer-encoding, expect), the
# connection (connection, upgrade, host), and what it stamps on every
# response (date, content-type, server), plus cookie, which the parser
# rejoins. `Headers` records the entry index of each, so a lookup for one
# of them is O(1) whatever the collection holds; every other name is found
# by the presence-filtered scan.
comptime KNOWN_HEADER_COUNT = 10
comptime KH_CONTENT_LENGTH = 0
comptime KH_CONTENT_TYPE = 1
comptime KH_CONNECTION = 2
comptime KH_TRANSFER_ENCODING = 3
comptime KH_HOST = 4
comptime KH_DATE = 5
comptime KH_COOKIE = 6
comptime KH_UPGRADE = 7
comptime KH_EXPECT = 8
comptime KH_SERVER = 9


@always_inline
def known_header_id(name: Span[Byte, _]) -> Int:
    """Which of the `KH_*` names `name` is, case-insensitively, or -1.

    The length and the first byte narrow the candidates to at most one
    before any full compare runs, so a name that is not one of the ten --
    most of a browser's -- is classified by two integer tests. The parser
    dispatches on this id once per field and `Headers` indexes by it; the
    linear `name_is` chain this replaces asked three questions per field
    and answered every lookup on the loop with a scan.
    """
    var n = len(name)
    if n < 4 or n > 17:
        return -1
    var first = ascii_lower_byte(name[0])
    if n == 14:
        if first == 0x63 and name_is(name, HeaderKey.CONTENT_LENGTH):
            return KH_CONTENT_LENGTH
    elif n == 12:
        if first == 0x63 and name_is(name, HeaderKey.CONTENT_TYPE):
            return KH_CONTENT_TYPE
    elif n == 10:
        if first == 0x63 and name_is(name, HeaderKey.CONNECTION):
            return KH_CONNECTION
    elif n == 17:
        if first == 0x74 and name_is(name, HeaderKey.TRANSFER_ENCODING):
            return KH_TRANSFER_ENCODING
    elif n == 4:
        if first == 0x68:
            if name_is(name, HeaderKey.HOST):
                return KH_HOST
        elif first == 0x64:
            if name_is(name, HeaderKey.DATE):
                return KH_DATE
    elif n == 6:
        if first == 0x63:
            if name_is(name, HeaderKey.COOKIE):
                return KH_COOKIE
        elif first == 0x65:
            if name_is(name, HeaderKey.EXPECT):
                return KH_EXPECT
        elif first == 0x73:
            if name_is(name, HeaderKey.SERVER):
                return KH_SERVER
    elif n == 7:
        if first == 0x75 and name_is(name, HeaderKey.UPGRADE):
            return KH_UPGRADE
    return -1


@always_inline
def _breaks_line_lanes[W: Int](w: SIMD[DType.uint8, W]) -> Bool:
    """Whether a chunk holds CR, LF or NUL. XOR zeroes exactly the lanes
    equal to its operand and a NUL lane is zero already, so the lane-wise
    minimum of the three is zero where any of them sits -- one `reduce_min`
    for the three bytes, `find_header_end`'s idiom."""
    var cr = w ^ SIMD[DType.uint8, W](0x0D)
    var lf = w ^ SIMD[DType.uint8, W](0x0A)
    return min(min(cr, lf), w).reduce_min() == 0


@always_inline
def span_breaks_header_line(s: Span[Byte, _]) -> Bool:
    """Whether `s` holds CR, LF or NUL, which no header name, header value,
    reason phrase or `Set-Cookie` line may carry onto the wire.

    CR and LF end a line, so either one inside a value lets the rest of it
    be read as headers of its own -- and, after a blank line, as a body
    the application never wrote: response splitting. NUL ends a C string.
    Every writer of a head asks this of what it is about to write and
    drops what answers yes (SPEC G1, G2), because the application has
    already run and its body is real; `m0-wsgi` asks the same of an
    application's head as it reads it, for the same reason.

    It runs on every name and value of every response, most of them under
    sixteen bytes, so no length walks a byte at a time past the third: what
    one full-width load cannot cover is read by a second that ENDS at the
    last byte, overlapping bytes already clear -- sixteen lanes for a long
    span, two loads of eight or of four for a short one. A byte loop for
    the tail cost more than the rest of the scan put together.
    """
    var n = len(s)
    var p = s.unsafe_ptr()
    if n >= 16:
        var i = 0
        while i + 16 <= n:
            if _breaks_line_lanes[16](p.unsafe_offset(i).unsafe_load[width=16]()):
                return True
            i += 16
        return i < n and _breaks_line_lanes[16](
            p.unsafe_offset(n - 16).unsafe_load[width=16]()
        )
    if n >= 8:
        return _breaks_line_lanes[8](
            p.unsafe_load[width=8]()
        ) or _breaks_line_lanes[8](p.unsafe_offset(n - 8).unsafe_load[width=8]())
    if n >= 4:
        return _breaks_line_lanes[4](
            p.unsafe_load[width=4]()
        ) or _breaks_line_lanes[4](p.unsafe_offset(n - 4).unsafe_load[width=4]())
    for i in range(n):
        var c = p[unsafe_offset=i]
        if c == 0x0D or c == 0x0A or c == 0x00:
            return True
    return False


comptime HEADER_VALUE_ASCII = 0
"""`header_value_kind`: every byte below 0x80, none of them CR, LF or NUL."""
comptime HEADER_VALUE_HIGH = 1
"""`header_value_kind`: a byte above 0x7F, and no CR, LF or NUL."""
comptime HEADER_VALUE_BREAKS = 2
"""`header_value_kind`: a CR, LF or NUL somewhere. Ordered last, so the
`max` of two chunks' kinds is the span's."""


@always_inline
def _value_lanes[W: Int](w: SIMD[DType.uint8, W]) -> Int:
    if _breaks_line_lanes[W](w):
        return HEADER_VALUE_BREAKS
    return HEADER_VALUE_HIGH if w.reduce_max() >= 0x80 else HEADER_VALUE_ASCII


@always_inline
def header_value_kind(s: Span[Byte, _]) -> Int:
    """`span_breaks_header_line` and an is-it-ASCII test in one pass, for
    the one caller that asks both of every value: `Headers.write_latin1_to`.
    The loads are `span_breaks_header_line`'s, each asked both questions."""
    var n = len(s)
    var p = s.unsafe_ptr()
    if n >= 16:
        var kind = HEADER_VALUE_ASCII
        var i = 0
        while i + 16 <= n:
            var k = _value_lanes[16](p.unsafe_offset(i).unsafe_load[width=16]())
            if k == HEADER_VALUE_BREAKS:
                return k
            kind = max(kind, k)
            i += 16
        if i < n:
            kind = max(
                kind, _value_lanes[16](p.unsafe_offset(n - 16).unsafe_load[width=16]())
            )
        return kind
    if n >= 8:
        return max(
            _value_lanes[8](p.unsafe_load[width=8]()),
            _value_lanes[8](p.unsafe_offset(n - 8).unsafe_load[width=8]()),
        )
    if n >= 4:
        return max(
            _value_lanes[4](p.unsafe_load[width=4]()),
            _value_lanes[4](p.unsafe_offset(n - 4).unsafe_load[width=4]()),
        )
    var kind = HEADER_VALUE_ASCII
    for i in range(n):
        var c = p[unsafe_offset=i]
        if c == 0x0D or c == 0x0A or c == 0x00:
            return HEADER_VALUE_BREAKS
        if c >= 0x80:
            kind = HEADER_VALUE_HIGH
    return kind


@always_inline
def _presence_bit(name: Span[Byte, _]) -> UInt64:
    """The bit `name` sets in a `Headers._present` word.

    Length, first byte and last byte, case-folded: three loads, no loop.
    A clear bit proves the name absent; a set bit only permits the scan.
    """
    var n = len(name)
    if n == 0:
        return UInt64(1)
    var h = n * 5 + Int(ascii_lower_byte(name[0])) * 3 + Int(
        ascii_lower_byte(name[n - 1])
    )
    return UInt64(1) << UInt64(h & 63)


struct Headers(Copyable, Writable):
    """Collection of HTTP headers, stored as spans into one flat buffer.

    Header names are normalized to lowercase, so lookup is case-insensitive.

    Storage is a single byte blob holding every name and value back to back,
    indexed by parallel (offset, length) arrays — the SoA pattern used
    elsewhere in this repo. This replaced a `Dict[String, String]`, which
    cost two String allocations per header to fill plus a third on every
    lookup (`key.lower()` allocates a probe copy before it can hash). A
    request carries 5-15 headers; over that range a linear scan of
    contiguous bytes beats hashing outright, and it allocates nothing.

    Insertion order is preserved, which the Dict did not guarantee.
    """

    var _buf: List[Byte]
    """Every name and value, back to back. Names are stored lowercased."""
    var _idx: List[Int32]
    """One packed entry per header, stride 4: name offset, name length,
    value offset, value length. One array rather than four parallel ones,
    because a Headers is built fresh for every request AND every response —
    four index allocations per construction was a fifth of the hello row's
    allocator traffic, and nothing outside this struct ever saw the four
    arrays."""
    var _present: UInt64
    """One bit per name inserted (`_presence_bit`), never cleared. A
    lookup whose bit is clear answers "absent" without touching the index,
    which is what makes the parser's per-field duplicate check -- twelve
    scans of a growing collection, before -- a single AND per field."""
    var _known: Array[Int16, KNOWN_HEADER_COUNT]
    """Entry index of each `KH_*` name, or -1 while it is absent. The event
    loop asks about these -- and only these -- on every request, and each
    of those lookups used to be a case-folding scan of the whole
    collection (`_name_matches` was the loop thread's largest user-space
    symbol, 5.6 % of it, before this). `pop` rebuilds it."""

    def __init__(out self):
        self._buf = List[Byte]()
        self._idx = List[Int32]()
        self._present = 0
        self._known = Array[Int16, KNOWN_HEADER_COUNT](fill=-1)

    def __init__(out self, var *headers: Header):
        self = Headers()
        for header in headers:
            self[header.key] = header.value

    @always_inline
    def count(self) -> Int:
        return len(self._idx) // 4

    @always_inline
    def empty(self) -> Bool:
        return len(self._idx) == 0

    def _name_matches(self, i: Int, probe: Span[Byte, _]) -> Bool:
        """Whether entry `i`'s name equals `probe`, case-insensitively.

        Stored names are already lowercase, so only the probe needs folding
        — which is what lets a lookup run without allocating.
        """
        var n = Int(self._idx[4 * i + 1])
        if n != len(probe):
            return False
        var off = Int(self._idx[4 * i])
        for j in range(n):
            if self._buf[off + j] != ascii_lower_byte(probe[j]):
                return False
        return True

    @always_inline
    def _find(self, key: Span[Byte, _]) -> Int:
        """Index of the entry named `key`, or -1."""
        var kid = known_header_id(key)
        if kid >= 0:
            return Int(self._known[kid])
        return self._find_unknown(key)

    @always_inline
    def known_index(self, kid: Int) -> Int:
        """Entry index of the `KH_*` name `kid`, or -1: the O(1) lookup for
        a caller that already knows which name it wants, with no
        classification of the name at all."""
        return Int(self._known[kid])

    @always_inline
    def set_known(mut self, kid: Int, name: Span[Byte, _], value: Span[Byte, _]):
        """`set_bytes` for a `KH_*` name the caller has already identified;
        `name` must be that name."""
        self._set_bytes(name, value, kid)

    def _find_unknown(self, key: Span[Byte, _]) -> Int:
        """`_find` for a name outside the `KH_*` set: the presence word
        first, then the scan it permits."""
        if (self._present & _presence_bit(key)) == 0:
            return -1
        for i in range(self.count()):
            if self._name_matches(i, key):
                return i
        return -1

    @always_inline
    def value_span(self, i: Int) -> Span[Byte, origin_of(self._buf)]:
        """Header `i`'s value, as bytes in place. Allocates nothing.

        Public for the same reason `keys()` is: something has to project
        these headers into another representation. `keys()` + `get()` costs
        two String allocations per header and a linear scan per lookup —
        measured at 48us per request projecting twelve headers into a WSGI
        blob, which was 77% of that bridge's entire per-request cost. Walking
        `count()` with these two spans allocates nothing at all.
        """
        var off = Int(self._idx[4 * i + 2])
        return Span(self._buf)[off : off + Int(self._idx[4 * i + 3])]

    @always_inline
    def name_span(self, i: Int) -> Span[Byte, origin_of(self._buf)]:
        """Header `i`'s name, lowercased, as bytes in place. See `value_span`."""
        var off = Int(self._idx[4 * i])
        return Span(self._buf)[off : off + Int(self._idx[4 * i + 1])]

    @always_inline
    def __contains__(self, key: String) -> Bool:
        return self._find(key.as_bytes()) >= 0

    @always_inline
    def __getitem__(self, key: String) raises HeaderKeyNotFoundError -> String:
        var i = self._find(key.as_bytes())
        if i < 0:
            raise HeaderKeyNotFoundError()
        return String(unsafe_from_utf8=self.value_span(i))

    @always_inline
    def get(self, key: String) -> Optional[String]:
        var i = self._find(key.as_bytes())
        if i < 0:
            return None
        return String(unsafe_from_utf8=self.value_span(i))

    def value_equals_ignore_case(self, key: String, expected: String) -> Bool:
        """Whether `key`'s value equals `expected`, case-insensitively.

        The allocation-free form of `headers.get(k).value().lower() == v`,
        which built two Strings to answer a yes/no question. Used by the
        `Connection: close` check on every single request.
        """
        var i = self._find(key.as_bytes())
        if i < 0:
            return False
        var value = self.value_span(i)
        var want = expected.as_bytes()
        if len(value) != len(want):
            return False
        for j in range(len(value)):
            if ascii_lower_byte(value[j]) != ascii_lower_byte(want[j]):
                return False
        return True

    def has_token_ignore_case(self, key: String, token: String) -> Bool:
        """Whether `key`'s value lists `token`, case-insensitively.

        For a field whose value is a comma-separated list of tokens
        (RFC 9110 §5.6.1), such as `Connection` (§7.6.1): each member is
        compared whole, with the optional whitespace around it removed and
        empty members skipped. `value_equals_ignore_case` compares the
        whole value, which read `Connection: close, TE` as not closing
        (SPEC B17). Allocation-free, like it, because the `Connection`
        check runs on every request.
        """
        var i = self._find(key.as_bytes())
        if i < 0:
            return False
        var value = self.value_span(i)
        var want = token.as_bytes()
        var n = len(value)
        var start = 0
        while start <= n:
            var end = start
            while end < n and value[end] != 0x2C:  # the list's comma
                end += 1
            var a = start
            var b = end
            while a < b and (value[a] == 0x20 or value[a] == 0x09):
                a += 1
            while b > a and (value[b - 1] == 0x20 or value[b - 1] == 0x09):
                b -= 1
            if b - a == len(want):
                var same = True
                for j in range(len(want)):
                    if ascii_lower_byte(value[a + j]) != ascii_lower_byte(want[j]):
                        same = False
                        break
                if same:
                    return True
            start = end + 1
        return False

    def keys(self) -> List[String]:
        """Snapshot of every header name present, lowercased.

        Pair each key with `__getitem__` to walk the whole collection —
        needed by anything projecting these headers into another
        representation, such as a WSGI `environ`.
        """
        var out = List[String](capacity=self.count())
        for i in range(self.count()):
            out.append(String(unsafe_from_utf8=self.name_span(i)))
        return out^

    def reserve(mut self, bytes: Int, entries: Int):
        """Size the blob and the index for what is about to be inserted.

        A parse knows both numbers before it inserts anything — the bytes
        it consumed bound the blob, the fields it counted bound the index —
        and without them the twelve inserts of a browser request grew the
        blob through nine reallocations and the index through seven.
        """
        self._buf.reserve(bytes)
        self._idx.reserve(4 * entries)

    def set_bytes(mut self, name: Span[Byte, _], value: Span[Byte, _]):
        """Insert or overwrite, taking both sides as raw bytes.

        The parser's entry point: it hands over slices of the receive
        buffer, and the name is lowercased on the way into the blob so no
        separate `.lower()` copy is ever made. The value goes in as one
        copy; only the name is walked, for the lowercasing.

        An overwrite appends the new value and repoints the index rather
        than compacting the blob. The stranded bytes are bounded by the
        header count and die with the request.
        """
        self._set_bytes(name, value, known_header_id(name))

    def _set_bytes(mut self, name: Span[Byte, _], value: Span[Byte, _], kid: Int):
        """`set_bytes` with the name already classified (`known_header_id`),
        so the parser, which dispatches on the id anyway, classifies once."""
        var i: Int
        if kid >= 0:
            i = Int(self._known[kid])
        else:
            i = self._find_unknown(name)
        var v_off = len(self._buf)
        var n_len = len(name)
        # Room for the value and the name together, grown geometrically:
        # `reserve` sizes a List exactly, so reserving per insert made an
        # unreserved collection (a handler's response) reallocate on every
        # one -- measured as +0.13 µs on `OK()` before this line existed.
        var v_len = len(value)
        var needed = v_off + v_len + n_len
        if self._buf.capacity() < needed:
            var grown = self._buf.capacity() * 2
            if grown < 128:
                grown = 128
            self._buf.reserve(needed if needed > grown else grown)
        # The blob has room for the value and the name now, so both go in
        # by raw copy with one length store at the end -- `extend`'s
        # capacity test and `memcpy` call per header, and an `append` per
        # name byte, were together 3-4 % of the loop thread.
        var dst = self._buf.unsafe_ptr()
        if v_len > 0:
            unsafe_memcpy(dest=dst.unsafe_offset(v_off), src=value.unsafe_ptr(), count=v_len)
        if i >= 0:
            self._buf._len = v_off + v_len
            self._idx[4 * i + 2] = Int32(v_off)
            self._idx[4 * i + 3] = Int32(v_len)
            return
        var n_off = v_off + v_len
        # Lowercased eight bytes at a time: ASCII letters are the only
        # bytes case-folding touches, and a header name is ASCII by
        # definition (RFC 9110 §5.1).
        var src = name.unsafe_ptr()
        var j = 0
        while j + 8 <= n_len:
            var w = src.unsafe_offset(j).unsafe_load[width=8]()
            var upper = w.ge(SIMD[DType.uint8, 8](0x41)) & w.le(SIMD[DType.uint8, 8](0x5A))
            dst.unsafe_offset(n_off + j).unsafe_store[width=8](
                upper.select(w | SIMD[DType.uint8, 8](0x20), w)
            )
            j += 8
        while j < n_len:
            dst.unsafe_offset(n_off + j)[] = ascii_lower_byte(src[unsafe_offset=j])
            j += 1
        self._buf._len = n_off + n_len
        var entry = self.count()
        # Four words per entry, so `append`'s one-at-a-time doubling (1,
        # 2, 4, 8...) reallocated three times for the FIRST header of an
        # unreserved collection; eight entries up front is one allocation
        # for a typical response.
        var at = len(self._idx)
        if self._idx.capacity() < at + 4:
            var grown_idx = self._idx.capacity() * 2
            if grown_idx < 32:
                grown_idx = 32
            self._idx.reserve(grown_idx)
        var ip = self._idx.unsafe_ptr()
        ip.unsafe_offset(at)[] = Int32(n_off)
        ip.unsafe_offset(at + 1)[] = Int32(n_len)
        ip.unsafe_offset(at + 2)[] = Int32(v_off)
        ip.unsafe_offset(at + 3)[] = Int32(v_len)
        self._idx._len = at + 4
        if kid >= 0:
            self._known[kid] = Int16(entry)
        self._present |= _presence_bit(name)

    @always_inline
    def __setitem__(mut self, key: String, value: String):
        self.set_bytes(key.as_bytes(), value.as_bytes())

    def set_int(mut self, key: String, value: Int):
        """Insert or overwrite an integer-valued header without a String.

        `headers[key] = String(n)` costs a heap allocation per call, and the
        two hottest headers in the server are integers set once per request
        (Content-Length on the request and on the response). Twenty bytes of
        stack covers Int64's digits.
        """
        self.set_int_known(known_header_id(key.as_bytes()), key.as_bytes(), value)

    def set_int_known(mut self, kid: Int, name: Span[Byte, _], value: Int):
        """`set_int` for a name already classified; -1 is any other name."""
        var digits = Array[Byte, 20](fill=0)
        var n = value
        if n < 0:
            # No negative header values exist; clamp rather than emit a sign
            # the receiving parser would reject.
            n = 0
        var pos = 20
        if n == 0:
            pos -= 1
            digits[pos] = 0x30
        else:
            while n > 0:
                pos -= 1
                digits[pos] = Byte(0x30 + (n % 10))
                n //= 10
        self._set_bytes(name, Span(digits)[pos:], kid)

    def pop(mut self, key: String):
        """Remove a header by name (no-op if absent).

        Removes the index entry only; the name and value bytes stay in the
        blob as garbage, same rationale as an overwrite in `set_bytes`.
        """
        var i = self._find(key.as_bytes())
        if i < 0:
            return
        for _ in range(4):
            _ = self._idx.pop(4 * i)
        # Every entry after `i` moved down one; the known-name index is
        # rebuilt rather than patched, because a pop is rare (a 101, a
        # stream head) and a patch that missed a case would be a lookup
        # answering with the wrong header's value. `_present` stays a
        # superset, which it is allowed to be.
        for k in range(KNOWN_HEADER_COUNT):
            self._known[k] = -1
        for e in range(self.count()):
            var kid = known_header_id(self.name_span(e))
            if kid >= 0:
                self._known[kid] = Int16(e)

    def content_length(self) -> Int:
        """Content-Length as an Int, or 0 if absent or malformed.

        Reads the digits straight out of the blob; the Dict version built a
        String first, on a path that runs for every request with a body.
        """
        var i = self._find(HeaderKey.CONTENT_LENGTH.as_bytes())
        if i < 0:
            return 0
        var value = self.value_span(i)
        if len(value) == 0:
            return 0
        var total = 0
        for j in range(len(value)):
            var d = value[j]
            if d < 0x30 or d > 0x39:
                return 0
            total = total * 10 + Int(d - 0x30)
        return total

    def write_to[T: Writer, //](self, mut writer: T):
        """The headers as text, dropping what `write_latin1_to` drops, so
        a response printed is the response sent."""
        for i in range(self.count()):
            var name = self.name_span(i)
            var value = self.value_span(i)
            if span_breaks_header_line(value) or span_breaks_header_line(name):
                continue
            writer.write(
                StringSpan(unsafe_from_utf8=name),
                ": ",
                StringSpan(unsafe_from_utf8=value),
                lineBreak,
            )

    def write_latin1_to(self, mut writer: ByteWriter):
        """Write headers with values transcoded to ISO-8859-1 for the wire.

        A header whose name or value holds CR, LF or NUL is DROPPED, and
        the rest are written (SPEC G2). Every head this server sends is
        written here -- a Mojo view's, the Mojo host's, a `--mount X=mojo`
        pool thread's, the gateway's -- so this is the one place the rule
        can live; it used to live only in `m0-wsgi`, which left every
        response built in Mojo writing `name: value\\r\\n` uninspected. A
        view that put request data in a header (a redirect to `next`, say,
        which `unquote` has already turned from `%0D%0A` into CRLF) could
        end its own head and write headers, or a body, of its choosing.
        Dropped rather than raised: the application has run and its body
        is real, and the header is the one part that cannot be sent.

        A value above ASCII is asked again AFTER its transcode, since those
        are the bytes that go out: the transcoder once decoded an overlong
        CR or LF into the real byte past the first look (SPEC G19), and the
        second look keeps any such bug a dropped header, not a split.
        """
        for i in range(self.count()):
            var name = self.name_span(i)
            var value = self.value_span(i)
            var kind = header_value_kind(value)
            if kind == HEADER_VALUE_BREAKS or span_breaks_header_line(name):
                continue
            if kind == HEADER_VALUE_ASCII:
                writer.write_header_line(name, value)
            else:
                var latin1 = encode_latin1_header_value(
                    String(unsafe_from_utf8=value)
                )
                if span_breaks_header_line(Span(latin1)):
                    continue
                writer.write_header_line(name, Span(latin1))

    def __eq__(self, other: Headers) -> Bool:
        if len(self._idx) != len(other._idx):
            return False
        for i in range(self.count()):
            var j = other._find(self.name_span(i))
            if j < 0:
                return False
            var a = self.value_span(i)
            var b = other.value_span(j)
            if len(a) != len(b):
                return False
            for k in range(len(a)):
                if a[k] != b[k]:
                    return False
        return True


def _http_scheme_len(target: Span[Byte, _]) -> Int:
    """The length of an `http://` or `https://` opening `target`, or 0.

    In any letter case: a scheme is case-insensitive (RFC 3986 §3.1), and
    `HTTP://h/p` was left whole, reaching the application as a path with
    no leading slash.
    """
    var n = len(target)
    if n < 7:
        return 0
    if (
        ascii_lower_byte(target[0]) != 0x68  # h
        or ascii_lower_byte(target[1]) != 0x74  # t
        or ascii_lower_byte(target[2]) != 0x74  # t
        or ascii_lower_byte(target[3]) != 0x70  # p
    ):
        return 0
    var i = 4
    if ascii_lower_byte(target[4]) == 0x73:  # s
        i = 5
    if i + 3 > n:
        return 0
    if target[i] != 0x3A or target[i + 1] != 0x2F or target[i + 2] != 0x2F:  # "://"
        return 0
    return i + 3


@always_inline
def _is_hexdig(c: Byte) -> Bool:
    return (
        (c >= 0x30 and c <= 0x39)
        or (c >= 0x41 and c <= 0x46)
        or (c >= 0x61 and c <= 0x66)
    )


@always_inline
def _is_unreserved_or_sub_delim(c: Byte) -> Bool:
    """RFC 3986 §2.3's unreserved (ALPHA / DIGIT / `-` `.` `_` `~`) and
    §2.2's sub-delims (`!` `$` `&` `'` `(` `)` `*` `+` `,` `;` `=`): every
    byte a reg-name may hold unescaped."""
    if (c >= 0x61 and c <= 0x7A) or (c >= 0x41 and c <= 0x5A) or (c >= 0x30 and c <= 0x39):
        return True
    return (
        c == 0x2D or c == 0x2E or c == 0x5F or c == 0x7E  # - . _ ~
        or c == 0x21 or c == 0x24 or c == 0x26 or c == 0x27  # ! $ & '
        or (c >= 0x28 and c <= 0x2C)  # ( ) * + ,
        or c == 0x3B or c == 0x3D  # ; =
    )


def host_value_is_valid(value: Span[Byte, _]) -> Bool:
    """Whether `value` is `uri-host [ ":" port ]` (RFC 9110 §7.2), the one
    shape a `Host` field value may take.

    The host is RFC 3986 §3.2.2's: a bracketed IP literal -- an IPv6
    address's hex digits, colons and dots, or `v`, hex digits, a dot and
    then unreserved, sub-delims or colons for an IPvFuture -- or a
    reg-name of unreserved bytes, sub-delims and `%` escapes, which an
    IPv4 address is too. The port is digits, any number of them (§3.2.3),
    none included. An empty host before a port is refused: an `http`
    authority with an empty host is invalid (RFC 9110 §4.2.1). The EMPTY
    value is the caller's to judge (SPEC B20), and this answers False.

    A server MUST answer 400 to a `Host` with an invalid field value (RFC
    9112 §3.2). `Host: a b` and `Host: u@a` were served, as h11 and llhttp
    serve them, and an application reading the site from `Host` --
    Django's `get_host`, a router keyed on it -- read a name no client can
    have meant (review record LF64). Bytes, never a String: the value is
    request data and may not be UTF-8 (SPEC G14), and a byte above ASCII
    is no part of a uri-host.
    """
    var n = len(value)
    var i = 0
    if n > 0 and value[0] == 0x5B:  # '['
        i = 1
        if i < n and (value[i] == 0x76 or value[i] == 0x56):  # 'v' / 'V'
            # IPvFuture: "v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" )
            i += 1
            var hex_from = i
            while i < n and _is_hexdig(value[i]):
                i += 1
            if i == hex_from or i >= n or value[i] != 0x2E:  # '.'
                return False
            i += 1
            var rest_from = i
            while i < n and (_is_unreserved_or_sub_delim(value[i]) or value[i] == 0x3A):
                i += 1
            if i == rest_from:
                return False
        else:
            # IPv6address: hex digits, colons, and the dots of an embedded
            # IPv4 address; at least one colon.
            var colons = 0
            while i < n and (_is_hexdig(value[i]) or value[i] == 0x3A or value[i] == 0x2E):
                if value[i] == 0x3A:
                    colons += 1
                i += 1
            if colons == 0:
                return False
        if i >= n or value[i] != 0x5D:  # ']'
            return False
        i += 1
    else:
        while i < n and value[i] != 0x3A:  # ':'
            var c = value[i]
            if c == 0x25:  # '%': pct-encoded is "%" HEXDIG HEXDIG
                if i + 2 >= n or not _is_hexdig(value[i + 1]) or not _is_hexdig(value[i + 2]):
                    return False
                i += 3
                continue
            if not _is_unreserved_or_sub_delim(c):
                return False
            i += 1
        if i == 0:
            return False
    if i == n:
        return True
    if value[i] != 0x3A:
        return False
    i += 1
    while i < n:
        if value[i] < 0x30 or value[i] > 0x39:
            return False
        i += 1
    return True


def parse_request_headers(
    buffer: Span[Byte, _],
) raises RequestParseError -> ParsedRequestHeaders:
    """Parse HTTP request headers from a buffer.

    This function parses the request line (method, path, protocol) and all headers
    from the given buffer, from its start: a head that has not all arrived
    raises IncompleteHTTPRequestError. The event loop calls it once, on the
    head `find_header_end` has framed; a `last_len` that resumed a rescan
    for the terminator, which framing had already found, went with
    `is_complete` (review record LF61).

    Args:
        buffer: The buffer containing the HTTP request data.

    Returns:
        ParsedRequestHeaders containing all parsed information and bytes consumed.

    Raises:
        RequestParseError: If parsing fails (invalid or incomplete request).
    """
    if len(buffer) == 0:
        raise RequestParseError(EmptyBufferError())

    var method = String()
    var path = String()
    var minor_version = -1
    var max_headers = 100
    # Uninitialized on purpose: the parser writes all four offsets of entry
    # `i` before it counts it, and nothing below reads past the count. The
    # `fill=` this replaces was 3.2 KB of stores per request — 0.3 µs of a
    # 1.07 µs parse once the scanners around it got cheap.
    var headers_array = Array[HTTPHeader, 100](uninitialized=True)
    var num_headers = max_headers

    var ret = http_parse_request_headers(
        buffer.unsafe_ptr(),
        len(buffer),
        method,
        path,
        minor_version,
        headers_array,
        num_headers,
    )

    if ret < 0:
        if ret == -1:
            raise RequestParseError(InvalidHTTPRequestError())
        else:  # ret == -2
            raise RequestParseError(IncompleteHTTPRequestError())

    # Phase 1a: Normalize absolute-form request targets (RFC 9112 §3.2.2).
    # Proxies and some HTTP clients send "GET http://host/path HTTP/1.1".
    # The handler sees the path and query; the authority becomes the Host
    # below, after the Host field's own checks (SPEC B16).
    var authority = Bytes()
    var scheme_len = _http_scheme_len(path.as_bytes())
    # RFC 9112 §3.2: a request target takes one of four forms. Origin-form
    # opens with `/`; absolute-form is an `http` or `https` URI (the scheme
    # matched above); asterisk-form is `*` and only for a server-wide
    # OPTIONS (§3.2.4); authority-form is CONNECT's alone, which is refused
    # below. Anything else is 400 (SPEC B19): `GET p` and `GET h:80` were
    # served, the application reading a path with no leading slash. The
    # bytes a target may hold are the scanner's rule (`http/parsing.mojo`);
    # this is the shape. A `%` escape is the application's to decode.
    if scheme_len == 0 and path.as_bytes()[0] != 0x2F:  # '/'
        if not (path == "*" and method == "OPTIONS") and method != "CONNECT":
            raise RequestParseError(InvalidHTTPRequestError())
    if scheme_len > 0:
        var target = path.as_bytes()
        # The authority runs to the first `/`, `?` or `#` (RFC 3986 §3.2).
        var end = scheme_len
        while end < len(target):
            var c = target[end]
            if c == 0x2F or c == 0x3F or c == 0x23:  # '/', '?', '#'
                break
            end += 1
        # No host to replace Host with: `http:///p`.
        if end == scheme_len:
            raise RequestParseError(InvalidHTTPRequestError())
        # A userinfo is to be treated as an error (RFC 9110 §4.2.4): it is
        # how a target hides the host it really names.
        for k in range(scheme_len, end):
            if target[k] == 0x40:  # '@'
                raise RequestParseError(InvalidHTTPRequestError())
        # The authority becomes the request's Host below, so it is held to
        # Host's own shape (SPEC B27): `http://a"b/` named no host either.
        if not host_value_is_valid(target[scheme_len:end]):
            raise RequestParseError(InvalidHTTPRequestError())
        authority = Bytes(target[scheme_len:end])
        # Sliced as bytes, never `[byte=a:b]`: the target is request data
        # and may not be UTF-8 (SPEC G14). Built whole before `path` is
        # assigned, while `target` still borrows it.
        var reduced = String()
        if end == len(target) or target[end] != 0x2F:
            reduced = "/"
        reduced += String(unsafe_from_utf8=target[end:])
        path = reduced^

    var headers = Headers()
    # Every name and value is a slice of the bytes consumed, so that is the
    # blob's bound; the index needs exactly the count.
    headers.reserve(ret, num_headers)
    var cookies = List[String]()
    var seen_content_length = False
    var seen_transfer_encoding = False
    # -1 while no Host field has been seen; its length after. A second Host
    # line is refused where it is met, so there is only ever the one.
    var host_len = -1
    # The `Connection` lines after the first, joined onto it (SPEC B22);
    # empty, and never allocated, for a request with one line or none.
    var connection = Bytes()

    # The header array holds OFFSETS into `buffer`; every name and value is a
    # slice of it. Sliced from an immutable view, or two slices of one
    # mutable origin handed to `set_bytes` trip the exclusivity check.
    var view = buffer.as_imm()
    for i in range(num_headers):
        # One `ref` to the element: a second subscript would invalidate the
        # interior reference taken by the first.
        ref h = headers_array[i]
        var name_bytes = view[h.name_start : h.name_start + h.name_len]
        # Phase 1c: RFC 9110 §5.5 — trim OWS (SP / HTAB) from field values.
        # picohttpparser preserves surrounding whitespace; we normalise here.
        # Trimming the span rather than calling `.strip()` keeps this
        # allocation-free: only a cookie (rare) materializes a String.
        var vb = view[h.value_start : h.value_start + h.value_len]
        var vs = 0
        var ve = len(vb)
        while vs < ve and (vb[vs] == 0x20 or vb[vs] == 0x09):
            vs += 1
        while ve > vs and (vb[ve - 1] == 0x20 or vb[ve - 1] == 0x09):
            ve -= 1
        var value = vb[vs:ve]

        var kid = known_header_id(name_bytes)
        if kid == KH_COOKIE:
            # Collected for the jar *and* left in `headers` below, because a
            # WSGI application is handed the raw header and parses cookies
            # itself. Diverting it out of `headers` is what kept `HTTP_COOKIE`
            # out of the environ, and with it every session and CSRF token.
            cookies.append(String(unsafe_from_utf8=value))
        elif kid == KH_CONTENT_LENGTH:
            if seen_content_length:
                raise RequestParseError(InvalidHTTPRequestError())
            seen_content_length = True
            # RFC 9112 §6.3: a Content-Length that is not a plain digit run
            # makes the message unframeable, and the answer is 400 rather
            # than a guess. `Headers.content_length()` returns 0 for
            # anything it cannot parse, which silently turned
            # `Content-Length: 5, 5` (two hops disagreeing already),
            # `0x10`, `+5` and `5abc` into "no body" — the digits' framing
            # intent dropped on the floor while the bytes stayed in the
            # buffer. Rejecting here means that reading of a length is
            # never acted on.
            if len(value) == 0:
                raise RequestParseError(InvalidHTTPRequestError())
            for d in range(len(value)):
                if value[d] < 0x30 or value[d] > 0x39:
                    raise RequestParseError(InvalidHTTPRequestError())
            # A run of digits long enough to overflow Int64 is refused for
            # the same reason: `content_length()` would wrap it silently.
            if len(value) > 18:
                raise RequestParseError(InvalidHTTPRequestError())
            headers._set_bytes(name_bytes, value, kid)
        else:
            # The two fields the RFC checks below ask about are noted on
            # the way past. They used to be three scans of the finished
            # collection — and the Host one built a String to measure it.
            #
            # A SECOND line of either is refused here, as a second
            # Content-Length is above: `set_bytes` keeps the last of a
            # repeated field, so the request was served on whichever line
            # came last. RFC 9112 §3.2 asks for 400 on more than one Host
            # line in ANY request -- a proxy routing on the first and an
            # application reading the last (Django's `HTTP_HOST`) disagreed
            # about the site. Field lines of one name combine into a list
            # (RFC 9110 §5.3), so two `Transfer-Encoding: chunked` lines are
            # the `chunked, chunked` refused below, which the last line
            # alone read as one `chunked`.
            if kid == KH_HOST:
                if host_len >= 0:
                    raise RequestParseError(InvalidHTTPRequestError())
                # A value that is not `uri-host [ ":" port ]` is 400 too
                # (RFC 9112 §3.2, SPEC B27); the empty one is B20's, below.
                if len(value) > 0 and not host_value_is_valid(value):
                    raise RequestParseError(InvalidHTTPRequestError())
                host_len = len(value)
            elif kid == KH_TRANSFER_ENCODING:
                if seen_transfer_encoding:
                    raise RequestParseError(InvalidHTTPRequestError())
                seen_transfer_encoding = True
            elif kid == KH_CONNECTION:
                # A second `Connection` line joins the first as one list,
                # comma-SP, in order (RFC 9110 §5.3), so `close` on either
                # closes (SPEC B22). `set_bytes` keeps the last of a
                # repeated field, and `Connection: close` followed by
                # `Connection: keep-alive` kept the connection alive. Only
                # this field, the list the loop acts on for every request;
                # a request carries no `Set-Cookie`, which never combines,
                # and its `Cookie` lines are joined below, with "; ".
                #
                # Joined OUTSIDE the store and set once after the loop, as
                # `Cookie` is: the store's blob never overwrites, so setting
                # the list so far at every line left a copy of it each
                # time -- 98 lines of a 32 KB head made a 1.5 MB blob.
                var at = headers.known_index(KH_CONNECTION)
                if at >= 0:
                    if len(connection) == 0:
                        connection.extend(headers.value_span(at))
                    connection.append(0x2C)  # ','
                    connection.append(0x20)
                    connection.extend(value)
                    continue
            headers._set_bytes(name_bytes, value, kid)

    if len(connection) > 0:
        headers._set_bytes(
            HeaderKey.CONNECTION.as_bytes(), Span(connection), KH_CONNECTION
        )

    # Put the cookies back as one `Cookie` field. RFC 6265 §5.4 sends a single
    # header, but HTTP/2 downgrades and some proxies split it across several,
    # and the pieces are one "; "-joined list — so joining is what a second
    # header means, not a fallback. Done after the loop because `Headers` is a
    # unique-key map: setting it per header line would keep only the last.
    if len(cookies) > 0:
        var joined = StaticString("; ").join(cookies)
        headers._set_bytes(HeaderKey.COOKIE.as_bytes(), joined.as_bytes(), KH_COOKIE)

    # RFC 9112 §6.3: reject requests with both Transfer-Encoding and Content-Length
    if seen_transfer_encoding and seen_content_length:
        raise RequestParseError(InvalidHTTPRequestError())

    # RFC 9112 §3.2: an HTTP/1.1 request MUST carry exactly one Host field,
    # and a server MUST respond 400 to one that does not. Both halves are
    # checked, "more than one" in the loop above: a *missing* Host used to
    # pass, because the check was an `and` that a None short-circuited —
    # which leaves the request's target host unstated in any deployment
    # that routes or caches on it.
    #
    # An EMPTY value is what RFC 9110 §7.2 asks a client to send when the
    # target URI has no authority, so it is accepted unless the request
    # target names one -- absolute-form, whose Host must be that authority
    # (SPEC B20). Every empty Host was refused, where h11 and llhttp accept
    # it. Whitespace-only values ("Host: " / "Host: \t") are stripped to ""
    # by the parser's OWS skip and read the same way.
    #
    # Every minor version from 1 up: HTTP/1.2 to HTTP/1.9 are processed as
    # HTTP/1.1, the highest this server implements (RFC 9110 §2.5), and the
    # check that asked for 1 exactly served them with no Host (SPEC B15).
    if minor_version >= 1 and (host_len < 0 or (host_len == 0 and scheme_len > 0)):
        raise RequestParseError(InvalidHTTPRequestError())

    # RFC 9112 §3.2.2: with an absolute-form target the server MUST ignore
    # the received Host and use the target's authority. It was thrown away
    # and Host kept, so an application routing on Host read a site the
    # target never named (SPEC B16). The sent Host is still required and
    # checked above: §3.2 asks for it whatever the target says.
    if scheme_len > 0:
        headers._set_bytes(HeaderKey.HOST.as_bytes(), Span(authority), KH_HOST)

    # RFC 9112 §6.1: 'chunked' MUST be the last (outermost) Transfer-Encoding.
    # Reject e.g. "Transfer-Encoding: chunked, zorg".
    if seen_transfer_encoding:
        # The stored value as bytes: a second line was refused in the loop,
        # so the one stored is the only one, and this path runs only for
        # requests that carry the header at all.
        #
        # Each member is compared with ASCII case folding and nothing else:
        # transfer-coding names are case-insensitive (RFC 9112 §7.1), so
        # testing the raw value let `Transfer-Encoding: CHUNKED` skip this
        # check entirely -- and skip being recognised as a chunked body at
        # all (see `is_chunked_body`). It was `String.lower()`, which folds
        # by Unicode's rules and reads the value as UTF-8: KELVIN SIGN
        # (U+212A) lowered to `k`, so `chun<U+212A>ed` was framed as
        # chunked where every other hop reads an unknown coding, and a lead
        # byte that is no UTF-8 swallowed the comma behind it (review record
        # LF58). A field value is bytes, obs-text included (SPEC G14).
        var te = headers.value_span(headers.known_index(KH_TRANSFER_ENCODING))
        var te_len = len(te)
        # `chunked` ONLY last: a sender MUST NOT apply it more than once
        # (RFC 9112 §6.1). The loop decodes one layer, so `chunked, chunked`
        # reached the application as a still-chunked body described by a
        # length -- the contradictory pair SPEC L25 removes. Empty list
        # members mean nothing (RFC 9110 §5.6.1); any other member is a
        # coding, noted for the 501 below.
        var other_coding = False
        var last_is_chunked = False
        var start = 0
        while start <= te_len:
            var stop = start
            while stop < te_len and te[stop] != 0x2C:  # ','
                stop += 1
            var a = start
            var b = stop
            while a < b and (te[a] == 0x20 or te[a] == 0x09):
                a += 1
            while b > a and (te[b - 1] == 0x20 or te[b - 1] == 0x09):
                b -= 1
            var is_chunked = name_is(te[a:b], "chunked")
            if stop == te_len:
                last_is_chunked = is_chunked
            elif is_chunked:
                raise RequestParseError(InvalidHTTPRequestError())
            elif b > a:
                other_coding = True
            start = stop + 1
        # RFC 9112 §6.3: if a request carries Transfer-Encoding, the FINAL
        # coding must be `chunked` — that is the only one that says where
        # the body ends. Testing for `chunked` anywhere in the value let
        # `Transfer-Encoding: gzip` past both this check and
        # `is_chunked_body`, so with no Content-Length either the request
        # was dispatched as bodyless while its body stayed in the buffer:
        # the same two-hops-two-framings disagreement as the rest of this
        # block, and the one member of the family left open. The answer is
        # a MUST: 400, then close -- a lone `gzip`, a list naming no coding
        # or ending in an empty member, `chunked;x=1`.
        if not last_is_chunked:
            raise RequestParseError(InvalidHTTPRequestError())
        # With `chunked` final, any coding before it is one this server
        # does not implement, and a server that receives a transfer coding
        # it does not understand SHOULD answer 501 (RFC 9112 §6.1; SPEC
        # B21): the body's end is known, its content is not decodable here.
        # `gzip, chunked` was de-chunked and its body handed to the
        # application still gzipped (review record LF39).
        if other_coding:
            raise RequestParseError(UnsupportedHTTPRequestError())

    # CONNECT asks the recipient to become a tunnel (RFC 9110 §9.3.6), and
    # this server implements none: 501, answered by the loop, which closes
    # (SPEC B18). It reached the application, which answers every method,
    # and a 2xx answer to CONNECT tells a front end that forwards it that
    # the tunnel is open -- whatever the client sends next goes through
    # unparsed, past every rule in this function. Asked LAST, so a CONNECT
    # that is also malformed -- two `Host` lines, a `Content-Length` beside
    # `Transfer-Encoding` -- is the 400 every other request gets. The method
    # is case-sensitive (RFC 9110 §9.1), so `connect` is some other method.
    if method == "CONNECT":
        raise RequestParseError(UnsupportedHTTPRequestError())

    # The two versions this server speaks are literals; formatting an Int
    # into a String on every request was the only other way to spell them.
    var protocol: String
    if minor_version == 1:
        protocol = "HTTP/1.1"
    elif minor_version == 0:
        protocol = "HTTP/1.0"
    else:
        protocol = String("HTTP/1.", minor_version)

    return ParsedRequestHeaders(
        method=method^,
        path=path^,
        protocol=protocol^,
        headers=headers^,
        cookies=cookies^,
        bytes_consumed=ret,
    )


def find_header_end(buffer: Span[Byte, _], search_start: Int = 0) -> Optional[Int]:
    """Find the end of HTTP headers in a buffer.

    Searches for the \\r\\n\\r\\n sequence that marks the end of headers.
    Uses four overlapping 64-byte SIMD loads to match all four bytes in
    parallel: lane j is True iff \\r\\n\\r\\n starts at position i+j.
    Falls back to scalar for the tail (< 67 bytes remaining).

    Args:
        buffer: The buffer to search.
        search_start: Offset to start searching from (optimization for incremental reads).

    Returns:
        The index of the first byte AFTER the header end sequence (\\r\\n\\r\\n),
        or None if not found.
    """
    if len(buffer) < 4:
        return None

    # Back up three bytes, so a terminator the last read cut short is found
    # whole: from ANY resume point, down to 0. It backed up only from one
    # above 3, so a read that ended one to three bytes into a head opening
    # with two empty lines resumed past the terminator at 0, and the head
    # was framed at a later one (review record LF66; LF59 its duplicate).
    var actual_start = search_start - 3 if search_start > 3 else 0

    var buf_len = len(buffer)
    var ptr = buffer.unsafe_ptr()
    var i = actual_start

    # Splat comparison targets
    var cr_vec = SIMD[DType.uint8, 64](BytesConstant.CR)
    var lf_vec = SIMD[DType.uint8, 64](BytesConstant.LF)

    # SIMD phase: four overlapping 64-byte loads shifted by 0,1,2,3 bytes.
    # At each candidate position j (0..63), checks:
    #   buffer[i+j]==CR, [i+j+1]==LF, [i+j+2]==CR, [i+j+3]==LF
    # Needs 64+3 = 67 bytes readable from position i.
    while i + 67 <= buf_len:
        var v0 = ptr.unsafe_offset(i).unsafe_load[width=64]()
        var v1 = ptr.unsafe_offset(i + 1).unsafe_load[width=64]()
        var v2 = ptr.unsafe_offset(i + 2).unsafe_load[width=64]()
        var v3 = ptr.unsafe_offset(i + 3).unsafe_load[width=64]()

        # XOR each shifted window with expected byte — zero lanes = match.
        # OR all four: lane j is zero iff \r\n\r\n starts at i+j.
        var combined = (v0 ^ cr_vec) | (v1 ^ lf_vec) | (v2 ^ cr_vec) | (v3 ^ lf_vec)

        if combined.reduce_min() == 0:
            # At least one lane matched; `_first_lane` names it without a
            # scalar walk over the vector (see `parsing.mojo`).
            return i + _first_lane[64](combined.eq(SIMD[DType.uint8, 64](0))) + 4
        i += 64

    # Scalar tail: handle remaining < 67 bytes.
    while i + 3 < buf_len:
        if (
            buffer[i] == BytesConstant.CR
            and buffer[i + 1] == BytesConstant.LF
            and buffer[i + 2] == BytesConstant.CR
            and buffer[i + 3] == BytesConstant.LF
        ):
            return i + 4
        i += 1

    return None


def holds_bare_lf(buffer: Span[Byte, _], start: Int = 0) -> Bool:
    """Whether `buffer[start:]` holds an LF that no CR comes right before.

    For a request head still arriving: every line of one ends in CRLF
    (SPEC B12), so a bare LF means the head can only be refused -- and a
    head of bare LFs holds no CRLFCRLF for `find_header_end` to frame, so
    the parser that refuses it never ran (SPEC B23). Each byte from
    `start` is asked with the one before it, which may sit before `start`:
    a read that ended on a CR, and the next opening with its LF, is a
    CRLF. Pass where the last scan stopped and every byte is scanned once.

    Sixty-four lanes a step, the predecessors a second load one byte back;
    the scalar tail takes the rest.
    """
    var n = len(buffer)
    var p = buffer.unsafe_ptr()
    var i = start if start > 0 else 0
    if i >= n:
        return False
    if i == 0:
        if p[unsafe_offset=0] == BytesConstant.LF:
            return True
        i = 1
    var lf_vec = SIMD[DType.uint8, 64](BytesConstant.LF)
    var cr_vec = SIMD[DType.uint8, 64](BytesConstant.CR)
    while i + 64 <= n:
        var cur = p.unsafe_offset(i).unsafe_load[width=64]()
        var prev = p.unsafe_offset(i - 1).unsafe_load[width=64]()
        if _first_lane[64](cur.eq(lf_vec) & prev.ne(cr_vec)) >= 0:
            return True
        i += 64
    while i < n:
        if (
            p[unsafe_offset=i] == BytesConstant.LF
            and p[unsafe_offset=i - 1] != BytesConstant.CR
        ):
            return True
        i += 1
    return False
