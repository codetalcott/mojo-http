from lightbug_http.http.parsing import (
    HTTPHeader,
    http_parse_headers,
    http_parse_request_headers,
    http_parse_response_headers,
)
from lightbug_http.io.bytes import ByteReader, Bytes, ByteWriter, byte, is_newline, is_space
from lightbug_http.strings import CR, LF, BytesConstant, lineBreak
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

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct InvalidHTTPRequestError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when the HTTP request is malformed."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("InvalidHTTPRequestError: Not a valid HTTP request")

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct IncompleteHTTPRequestError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when the HTTP request is incomplete (need more data)."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("IncompleteHTTPRequestError: Incomplete HTTP request")

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct InvalidHTTPResponseError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when the HTTP response is malformed."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("InvalidHTTPResponseError: Not a valid HTTP response")

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct IncompleteHTTPResponseError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when the HTTP response is incomplete."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("IncompleteHTTPResponseError: Incomplete HTTP response")

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct EmptyBufferError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when buffer has no data available."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("EmptyBufferError: No data available in buffer")

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct RequestParseError(Movable, Writable):
    """Error variant for HTTP request parsing.

    Can be InvalidHTTPRequestError, IncompleteHTTPRequestError, or EmptyBufferError.
    """

    comptime type = Variant[InvalidHTTPRequestError, IncompleteHTTPRequestError, EmptyBufferError]
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

    def is_incomplete(self) -> Bool:
        """Returns True if this error indicates we need more data."""
        return self.value.isa[IncompleteHTTPRequestError]()

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[InvalidHTTPRequestError]():
            writer.write(self.value[InvalidHTTPRequestError])
        elif self.value.isa[IncompleteHTTPRequestError]():
            writer.write(self.value[IncompleteHTTPRequestError])
        elif self.value.isa[EmptyBufferError]():
            writer.write(self.value[EmptyBufferError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct ResponseParseError(Movable, Writable):
    """Error variant for HTTP response parsing."""

    comptime type = Variant[InvalidHTTPResponseError, IncompleteHTTPResponseError, EmptyBufferError]
    var value: Self.type

    @implicit
    def __init__(out self, value: InvalidHTTPResponseError):
        self.value = value

    @implicit
    def __init__(out self, value: IncompleteHTTPResponseError):
        self.value = value

    @implicit
    def __init__(out self, value: EmptyBufferError):
        self.value = value

    def is_incomplete(self) -> Bool:
        """Returns True if this error indicates we need more data."""
        return self.value.isa[IncompleteHTTPResponseError]()

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[InvalidHTTPResponseError]():
            writer.write(self.value[InvalidHTTPResponseError])
        elif self.value.isa[IncompleteHTTPResponseError]():
            writer.write(self.value[IncompleteHTTPResponseError])
        elif self.value.isa[EmptyBufferError]():
            writer.write(self.value[EmptyBufferError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


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
        """
        var te = self.headers.get(HeaderKey.TRANSFER_ENCODING)
        if te:
            return "chunked" in te.value()
        return False

    def expects_body(self) -> Bool:
        """Check if this request expects a body based on method and Content-Length."""
        var cl = self.content_length()
        if cl > 0:
            return True
        if self.method == "POST" or self.method == "PUT" or self.method == "PATCH":
            if self.is_chunked_body():
                return True
        return False


@fieldwise_init
struct ParsedResponseHeaders(Movable):
    """Result of parsing HTTP response headers."""

    var protocol: String
    var status: Int
    var status_message: String
    var headers: Headers
    var cookies: List[String]
    var bytes_consumed: Int


@fieldwise_init
struct Header(Copyable, Writable):
    """A single HTTP header key-value pair."""

    var key: String
    var value: String

    def __str__(self) -> String:
        return String(self)

    def write_to[T: Writer, //](self, mut writer: T):
        writer.write(self.key, ": ", self.value, lineBreak)


@always_inline
def write_header[T: Writer](mut writer: T, key: String, value: String):
    """Write a header in HTTP format to a writer."""
    writer.write(key, ": ", value, lineBreak)


def encode_latin1_header_value(value: String) -> List[UInt8]:
    """Transcode a header value from UTF-8 to ISO-8859-1 bytes.

    HTTP/1.1 header field values must be representable in ISO-8859-1 (RFC 7230 §3.2).
    - Codepoints U+0000–U+007F: single byte, passed through unchanged.
    - Codepoints U+0080–U+00FF: encoded as their single ISO-8859-1 byte.
    - Codepoints above U+00FF: cannot be represented in ISO-8859-1; the raw UTF-8
      bytes are written as-is (best-effort fallback — use RFC 5987 encoding instead).
    - Invalid UTF-8 byte sequences (obs-text from parsing): passed through as-is.
    """
    var utf8 = value.as_bytes()
    var out = List[UInt8](capacity=len(utf8))
    var i = 0
    while i < len(utf8):
        var b = utf8[i]
        if b < 0x80:
            out.append(b)
            i += 1
        else:
            var seq_len = 0
            var codepoint = 0
            if b >= 0xC2 and b <= 0xDF and i + 1 < len(utf8):
                var b2 = utf8[i + 1]
                if b2 >= 0x80 and b2 <= 0xBF:
                    seq_len = 2
                    codepoint = ((Int(b) & 0x1F) << 6) | (Int(b2) & 0x3F)
            elif b >= 0xE0 and b <= 0xEF and i + 2 < len(utf8):
                var b2 = utf8[i + 1]
                var b3 = utf8[i + 2]
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF:
                    seq_len = 3
                    codepoint = ((Int(b) & 0x0F) << 12) | ((Int(b2) & 0x3F) << 6) | (Int(b3) & 0x3F)
            elif b >= 0xF0 and b <= 0xF7 and i + 3 < len(utf8):
                var b2 = utf8[i + 1]
                var b3 = utf8[i + 2]
                var b4 = utf8[i + 3]
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF:
                    seq_len = 4
                    codepoint = ((Int(b) & 0x07) << 18) | ((Int(b2) & 0x3F) << 12) | ((Int(b3) & 0x3F) << 6) | (Int(b4) & 0x3F)

            if seq_len > 0 and codepoint <= 0xFF:
                out.append(UInt8(codepoint))
                i += seq_len
            elif seq_len > 0:
                for j in range(seq_len):
                    out.append(utf8[i + j])
                i += seq_len
            else:
                out.append(b)
                i += 1
    return out^


def write_header_latin1(mut writer: ByteWriter, key: String, value: String):
    """Write a header with the value transcoded to ISO-8859-1."""
    writer.write(key, ": ")
    # ASCII fast path: transcoding only changes bytes >= 0x80, so a pure
    # ASCII value (the overwhelmingly common case) can be written directly
    # instead of allocating a transcode buffer per header per response.
    var bytes = value.as_bytes()
    var all_ascii = True
    for i in range(len(bytes)):
        if bytes[i] >= 0x80:
            all_ascii = False
            break
    if all_ascii:
        writer.write(value)
    else:
        writer.consuming_write(encode_latin1_header_value(value))
    writer.write(lineBreak)


@always_inline
def ascii_lower_byte(b: Byte) -> Byte:
    """ASCII-lowercase a single byte; non-letters pass through unchanged.

    Header field names are ASCII by definition (RFC 9110 §5.1), so this is
    the whole of case normalization for them — no Unicode tables, no
    allocation.
    """
    return (b | 0x20) if (b >= 0x41 and b <= 0x5A) else b


@always_inline
def name_is(name: Span[Byte, _], lowercase: String) -> Bool:
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
    var _name_off: List[Int32]
    var _name_len: List[Int32]
    var _val_off: List[Int32]
    var _val_len: List[Int32]

    def __init__(out self):
        self._buf = List[Byte]()
        self._name_off = List[Int32]()
        self._name_len = List[Int32]()
        self._val_off = List[Int32]()
        self._val_len = List[Int32]()

    def __init__(out self, var *headers: Header):
        self = Headers()
        for header in headers:
            self[header.key] = header.value

    @always_inline
    def count(self) -> Int:
        return len(self._name_off)

    @always_inline
    def empty(self) -> Bool:
        return len(self._name_off) == 0

    def _name_matches(self, i: Int, probe: Span[Byte, _]) -> Bool:
        """Whether entry `i`'s name equals `probe`, case-insensitively.

        Stored names are already lowercase, so only the probe needs folding
        — which is what lets a lookup run without allocating.
        """
        var n = Int(self._name_len[i])
        if n != len(probe):
            return False
        var off = Int(self._name_off[i])
        for j in range(n):
            if self._buf[off + j] != ascii_lower_byte(probe[j]):
                return False
        return True

    def _find(self, key: Span[Byte, _]) -> Int:
        """Index of the entry named `key`, or -1."""
        for i in range(len(self._name_off)):
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
        var off = Int(self._val_off[i])
        return Span(self._buf)[off : off + Int(self._val_len[i])]

    @always_inline
    def name_span(self, i: Int) -> Span[Byte, origin_of(self._buf)]:
        """Header `i`'s name, lowercased, as bytes in place. See `value_span`."""
        var off = Int(self._name_off[i])
        return Span(self._buf)[off : off + Int(self._name_len[i])]

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

    def keys(self) -> List[String]:
        """Snapshot of every header name present, lowercased.

        Pair each key with `__getitem__` to walk the whole collection —
        needed by anything projecting these headers into another
        representation, such as a WSGI `environ`.
        """
        var out = List[String](capacity=len(self._name_off))
        for i in range(len(self._name_off)):
            out.append(String(unsafe_from_utf8=self.name_span(i)))
        return out^

    def set_bytes(mut self, name: Span[Byte, _], value: Span[Byte, _]):
        """Insert or overwrite, taking both sides as raw bytes.

        The parser's entry point: it hands over slices of the receive
        buffer, and the name is lowercased on the way into the blob so no
        separate `.lower()` copy is ever made.

        An overwrite appends the new value and repoints the index rather
        than compacting the blob. The stranded bytes are bounded by the
        header count and die with the request.
        """
        var i = self._find(name)
        var v_off = len(self._buf)
        for j in range(len(value)):
            self._buf.append(value[j])
        if i >= 0:
            self._val_off[i] = Int32(v_off)
            self._val_len[i] = Int32(len(value))
            return
        var n_off = len(self._buf)
        for j in range(len(name)):
            self._buf.append(ascii_lower_byte(name[j]))
        self._name_off.append(Int32(n_off))
        self._name_len.append(Int32(len(name)))
        self._val_off.append(Int32(v_off))
        self._val_len.append(Int32(len(value)))

    @always_inline
    def __setitem__(mut self, key: String, value: String):
        self.set_bytes(key.as_bytes(), value.as_bytes())

    def pop(mut self, key: String):
        """Remove a header by name (no-op if absent).

        Removes the index entry only; the name and value bytes stay in the
        blob as garbage, same rationale as an overwrite in `set_bytes`.
        """
        var i = self._find(key.as_bytes())
        if i < 0:
            return
        _ = self._name_off.pop(i)
        _ = self._name_len.pop(i)
        _ = self._val_off.pop(i)
        _ = self._val_len.pop(i)

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
        for i in range(len(self._name_off)):
            writer.write(
                StringSlice(unsafe_from_utf8=self.name_span(i)),
                ": ",
                StringSlice(unsafe_from_utf8=self.value_span(i)),
                lineBreak,
            )

    def write_latin1_to(self, mut writer: ByteWriter):
        """Write headers with values transcoded to ISO-8859-1 for the wire."""
        for i in range(len(self._name_off)):
            writer.write(StringSlice(unsafe_from_utf8=self.name_span(i)), ": ")
            var value = self.value_span(i)
            var all_ascii = True
            for j in range(len(value)):
                if value[j] >= 0x80:
                    all_ascii = False
                    break
            if all_ascii:
                writer.write(StringSlice(unsafe_from_utf8=value))
            else:
                writer.consuming_write(
                    encode_latin1_header_value(String(unsafe_from_utf8=value))
                )
            writer.write(lineBreak)

    def __str__(self) -> String:
        return String(self)

    def __eq__(self, other: Headers) -> Bool:
        if len(self._name_off) != len(other._name_off):
            return False
        for i in range(len(self._name_off)):
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


def parse_request_headers(
    buffer: Span[Byte, _],
    last_len: Int = 0,
) raises RequestParseError -> ParsedRequestHeaders:
    """Parse HTTP request headers from a buffer.

    This function parses the request line (method, path, protocol) and all headers
    from the given buffer. It uses incremental parsing - if the request is incomplete,
    it raises IncompleteHTTPRequestError.

    Args:
        buffer: The buffer containing the HTTP request data.
        last_len: Number of bytes that were already parsed in a previous call.
                  Use 0 for first parse attempt, or the previous buffer length
                  for incremental parsing.

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
    var headers_array = Array[HTTPHeader, 100](fill=HTTPHeader())
    var num_headers = max_headers

    var ret = http_parse_request_headers(
        buffer.unsafe_ptr(),
        len(buffer),
        method,
        path,
        minor_version,
        headers_array,
        num_headers,
        last_len,
    )

    if ret < 0:
        if ret == -1:
            raise RequestParseError(InvalidHTTPRequestError())
        else:  # ret == -2
            raise RequestParseError(IncompleteHTTPRequestError())

    # Phase 1a: Normalize absolute-form request targets (RFC 9112 §3.2.2).
    # Proxies and some HTTP clients send "GET http://host/path HTTP/1.1".
    # Strip scheme + authority so the handler only sees the path component.
    if path.startswith("http://") or path.startswith("https://"):
        var sep = 7 if path.startswith("http://") else 8
        var path_bytes = path.as_bytes()
        var found_slash = False
        for i in range(sep, len(path_bytes)):
            if path_bytes[i] == 47:  # ASCII '/'
                # Materialize into a temp first: constructing directly into
                # `path` while `path_bytes` still borrows it now trips the
                # aliasing check.
                var trimmed = String(path[byte=i:])
                path = trimmed^
                found_slash = True
                break
        if not found_slash:
            path = "/"

    var headers = Headers()
    var cookies = List[String]()
    var seen_content_length = False

    for i in range(num_headers):
        # One `ref` to the element: a second subscript would invalidate the
        # interior reference taken by the first.
        ref h = headers_array[i]
        var name_bytes = h.name.as_bytes()
        # Phase 1c: RFC 9110 §5.5 — trim OWS (SP / HTAB) from field values.
        # picohttpparser preserves surrounding whitespace; we normalise here.
        # Trimming the span rather than calling `.strip()` keeps this
        # allocation-free: only a cookie (rare) materializes a String.
        var vb = h.value.as_bytes()
        var vs = 0
        var ve = len(vb)
        while vs < ve and (vb[vs] == 0x20 or vb[vs] == 0x09):
            vs += 1
        while ve > vs and (vb[ve - 1] == 0x20 or vb[ve - 1] == 0x09):
            ve -= 1
        var value = vb[vs:ve]

        if name_is(name_bytes, HeaderKey.COOKIE):
            # Collected for the jar *and* left in `headers` below, because a
            # WSGI application is handed the raw header and parses cookies
            # itself. Diverting it out of `headers` is what kept `HTTP_COOKIE`
            # out of the environ, and with it every session and CSRF token.
            cookies.append(String(unsafe_from_utf8=value))
        elif name_is(name_bytes, HeaderKey.CONTENT_LENGTH):
            if seen_content_length:
                raise RequestParseError(InvalidHTTPRequestError())
            seen_content_length = True
            headers.set_bytes(name_bytes, value)
        else:
            headers.set_bytes(name_bytes, value)

    # Put the cookies back as one `Cookie` field. RFC 6265 §5.4 sends a single
    # header, but HTTP/2 downgrades and some proxies split it across several,
    # and the pieces are one "; "-joined list — so joining is what a second
    # header means, not a fallback. Done after the loop because `Headers` is a
    # unique-key map: setting it per header line would keep only the last.
    if len(cookies) > 0:
        var joined = StaticString("; ").join(cookies)
        headers.set_bytes(HeaderKey.COOKIE.as_bytes(), joined.as_bytes())

    # RFC 7230 §3.3.3: reject requests with both Transfer-Encoding and Content-Length
    if HeaderKey.TRANSFER_ENCODING in headers and HeaderKey.CONTENT_LENGTH in headers:
        raise RequestParseError(InvalidHTTPRequestError())

    # RFC 9110 §7.2: HTTP/1.1 requires a non-empty Host field value.
    # Whitespace-only Host values ("Host: " / "Host: \t") are stripped to ""
    # by the parser's OWS skip and must be rejected as invalid.
    if minor_version == 1:
        var host_opt = headers.get(HeaderKey.HOST)
        if host_opt and host_opt.value().byte_length() == 0:
            raise RequestParseError(InvalidHTTPRequestError())

    # RFC 9112 §6.1: 'chunked' MUST be the last (outermost) Transfer-Encoding.
    # Reject e.g. "Transfer-Encoding: chunked, zorg".
    var te_opt = headers.get(HeaderKey.TRANSFER_ENCODING)
    if te_opt:
        var te_str = te_opt.value()
        var te_parts = te_str.split(",")
        var last_te = String(te_parts[len(te_parts) - 1]).strip().lower()
        if "chunked" in te_str and last_te != "chunked":
            raise RequestParseError(InvalidHTTPRequestError())

    var protocol = String("HTTP/1.", minor_version)

    return ParsedRequestHeaders(
        method=method^,
        path=path^,
        protocol=protocol^,
        headers=headers^,
        cookies=cookies^,
        bytes_consumed=ret,
    )


def parse_response_headers(
    buffer: Span[Byte, _],
    last_len: Int = 0,
) raises ResponseParseError -> ParsedResponseHeaders:
    """Parse HTTP response headers from a buffer.

    Args:
        buffer: The buffer containing the HTTP response data.
        last_len: Number of bytes already parsed in previous call (0 for first attempt).

    Returns:
        ParsedResponseHeaders containing all parsed information and bytes consumed.

    Raises:
        ResponseParseError: If parsing fails (invalid or incomplete response).
    """
    if len(buffer) == 0:
        raise ResponseParseError(EmptyBufferError())

    if len(buffer) < 5:
        raise ResponseParseError(IncompleteHTTPResponseError())

    if not (
        buffer[0] == BytesConstant.H
        and buffer[1] == BytesConstant.T
        and buffer[2] == BytesConstant.T
        and buffer[3] == BytesConstant.P
        and buffer[4] == BytesConstant.SLASH
    ):
        raise ResponseParseError(InvalidHTTPResponseError())

    var minor_version = -1
    var status = 0
    var msg = String()
    var max_headers = 100
    var headers_array = Array[HTTPHeader, 100](fill=HTTPHeader())
    var num_headers = max_headers

    var ret = http_parse_response_headers(
        buffer.unsafe_ptr(),
        len(buffer),
        minor_version,
        status,
        msg,
        headers_array,
        num_headers,
        last_len,
    )

    if ret < 0:
        if ret == -1:
            raise ResponseParseError(InvalidHTTPResponseError())
        else:  # ret == -2
            raise ResponseParseError(IncompleteHTTPResponseError())

    # Build headers dict and extract cookies
    var headers = Headers()
    var cookies = List[String]()

    for i in range(num_headers):
        # One `ref` to the element: two separate subscripts would invalidate
        # the first interior reference before the second is taken.
        ref h = headers_array[i]
        var name_bytes = h.name.as_bytes()
        var value = h.value.as_bytes()

        if name_is(name_bytes, HeaderKey.SET_COOKIE):
            cookies.append(String(unsafe_from_utf8=value))
        else:
            headers.set_bytes(name_bytes, value)

    var protocol = String("HTTP/1.", minor_version)

    return ParsedResponseHeaders(
        protocol=protocol^,
        status=status,
        status_message=msg^,
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

    # Adjust search start to account for partial matches at boundary
    var actual_start = search_start
    if actual_start > 3:
        actual_start -= 3

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
            # At least one lane matched — find the first zero
            for lane in range(64):
                if combined[lane] == 0:
                    return i + lane + 4
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
