from std.hashlib.hash import Hasher

from lightbug_http.io.bytes import ByteReader, Bytes, ByteView
from lightbug_http.strings import http, https, strHttp10, strHttp11


def _hex_upper(v: Int) -> String:
    """One uppercase hex digit."""
    return String("0123456789ABCDEF"[byte=v : v + 1])


@always_inline
def _hex_value(c: UInt8) -> Int:
    """The value of one hex digit, or -1 for anything else."""
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    return -1


def unquote[expand_plus: Bool = False](input_str: String, disallowed_escapes: List[String] = List[String]()) -> String:
    """Percent-decode `input_str`, leaving `disallowed_escapes` encoded.

    A byte named in `disallowed_escapes` is NOT decoded: its `%XX` form is
    kept (canonicalised to uppercase hex), so the result cannot contain a
    character the caller said must not appear through an escape. Entries
    are matched a byte at a time; the only caller passes `["/"]`, to keep
    `%2F` from becoming a path separator.

    It used to DELETE such a byte instead — `replace(disallowed, "")` — and
    that silently rewrote the request target: `/adm%2Fin` arrived at
    routing, at `PATH_INFO`, and at the access log as `/admin`. Anything in
    front making a decision on the raw target (a WAF, a proxy's location
    rules, a CDN's cache key) sees a path this server does not agree with,
    which is a path-rule bypass wearing a normalisation bug's clothes. It
    also meant an encoded slash inside a segment — an encoded id, say —
    could never survive to the application.

    Decoding it to a literal `/` would be the other wrong answer: that
    fabricates a segment boundary the client did not send. Keeping the
    escape is what nginx does with `AllowEncodedSlashes off`, and it leaves
    the path distinct from every path containing a real slash.

    **A byte walk, never a String slice.** The previous body located every
    `%` and sliced the input with `String[byte=a:b]`, which asserts that
    both ends are codepoint boundaries. A request target is not required
    to be UTF-8, and a lone continuation byte beside an escape put a slice
    end on a non-boundary: the assert trapped the loop thread and one
    `GET /?x=<0x80>%41` killed the process — every app, the production
    WSGI deployment included, since this runs for every request before any
    handler. Percent-decoding is a byte operation; this walks
    `input_str.as_bytes()` once into one output buffer and builds the
    String at the end, so no input can reach a boundary check. It is also
    stricter about what an escape is: exactly two hex digits, where `atol`
    accepted a sign. A `%` not followed by two hex digits is kept verbatim,
    as before. `test_unquote.mojo` pins all of it, and its process dying is
    what the old body does on that file.
    """
    var b = input_str.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var c = b[i]
        if c == UInt8(ord("%")) and i + 2 < n:
            var hi = _hex_value(b[i + 1])
            var lo = _hex_value(b[i + 2])
            if hi >= 0 and lo >= 0:
                var v = UInt8(hi * 16 + lo)
                if _is_disallowed(v, disallowed_escapes):
                    # Re-emit the escape, uppercase, rather than dropping
                    # the byte; see the docstring for why deleting was wrong.
                    out.append(c)
                    for d in _hex_upper(hi).as_bytes():
                        out.append(d)
                    for d in _hex_upper(lo).as_bytes():
                        out.append(d)
                else:
                    out.append(v)
                i += 3
                continue
        comptime if expand_plus:
            if c == UInt8(ord("+")):
                out.append(UInt8(ord(" ")))
                i += 1
                continue
        out.append(c)
        i += 1
    return String(unsafe_from_utf8=Span(out))


@always_inline
def _is_disallowed(v: UInt8, disallowed_escapes: List[String]) -> Bool:
    for disallowed in disallowed_escapes:
        var db = disallowed.as_bytes()
        if len(db) == 1 and db[0] == v:
            return True
    return False


comptime QueryMap = Dict[String, String]


struct QueryDelimiters:
    comptime STRING_START = "?"
    comptime ITEM = "&"
    comptime ITEM_ASSIGN = "="
    comptime PLUS_ESCAPED_SPACE = "+"


def scheme_separator(uri: StringSpan) -> Int:
    """Index of the `://` that introduces a scheme, or -1 if there is none.

    A request target may carry a URL of its own inside a query parameter, and
    an unencoded one puts a literal `://` in the middle of the target:
    `/go?url=http://example.test`. Searching the whole string for `://` reads
    that as an absolute URI, and the parse then fails on a "scheme" of
    `/go?url=http` — a `400` for a request the application never sees. The
    encoded form every browser form and every `urlencode` produces was never
    affected, which is what kept this rare.

    So the `://` only counts when everything before it could actually be a
    scheme. RFC 3986 §3.1 defines one as `ALPHA *( ALPHA / DIGIT / "+" / "-"
    / "." )`, which cannot contain `/`, `?` or `#` — testing the character
    set is therefore both the specified rule and the fix.
    """
    var sep = uri.find("://")
    if sep <= 0:
        # -1: no separator. 0: an empty scheme, which is not a scheme.
        return -1
    var bytes = uri.as_bytes()
    for i in range(sep):
        var c = bytes[i]
        var alpha = (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or (
            c >= UInt8(ord("A")) and c <= UInt8(ord("Z"))
        )
        if i == 0:
            if not alpha:
                return -1  # a scheme must start with a letter
            continue
        var digit = c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        if not (
            alpha
            or digit
            or c == UInt8(ord("+"))
            or c == UInt8(ord("-"))
            or c == UInt8(ord("."))
        ):
            return -1
    return sep


struct URIDelimiters:
    comptime SCHEMA = "://"
    comptime PATH = "/"
    comptime ROOT_PATH = "/"
    comptime CHAR_ESCAPE = "%"
    comptime AUTHORITY = "@"
    comptime QUERY = "?"
    comptime SCHEME = ":"


struct PortBounds:
    comptime NINE: UInt8 = UInt8(ord("9"))
    comptime ZERO: UInt8 = UInt8(ord("0"))


@fieldwise_init
struct Scheme(Equatable, Hashable, ImplicitlyCopyable, Writable):
    var value: UInt8
    comptime HTTP = Self(0)
    comptime HTTPS = Self(1)

    def __hash__[H: Hasher](self, mut hasher: H):
        hasher.update(self.value)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to[W: Writer, //](self, mut writer: W):
        if self == Self.HTTP:
            writer.write("HTTP")
        else:
            writer.write("HTTPS")

    def __repr__(self) -> String:
        return String("Scheme(", self, ")")

    def __str__(self) -> String:
        return String(self)


struct URIParseError(Writable):
    var message: String

    def __init__(out self, var message: String):
        self.message = message^

    def write_to[W: Writer, //](self, mut writer: W) -> None:
        writer.write(self.message)

    def __str__(self) -> String:
        return self.message.copy()


@fieldwise_init
struct URI(Copyable, Writable):
    var _original_path: String
    var scheme: String
    var path: String
    var query_string: String
    var queries: QueryMap
    var _hash: String
    var host: String
    var port: Optional[UInt16]

    var full_uri: String
    var request_uri: String

    var username: String
    var password: String

    @staticmethod
    def parse(var uri: String) raises URIParseError -> URI:
        """Parses a URI which is defined using the following format.

        `[scheme:][//[user_info@]host][/]path[?query][#fragment]`
        """
        # Computed before the reader borrows `uri`: taking a second interior
        # reference while the reader holds one invalidates it.
        var scheme_sep = scheme_separator(uri)
        var reader = ByteReader(uri.as_bytes())

        # Parse the scheme, if exists.
        # Assume http if no scheme is provided, fairly safe given the context of lightbug.
        var scheme: String = "http"
        if scheme_sep >= 0:
            scheme = String(reader.read_until(UInt8(ord(URIDelimiters.SCHEME))))
            # `uri.as_bytes()` is now bound to an interior origin of `uri`,
            # so the reader's slices carry that origin rather than the whole
            # string's.
            var scheme_delimiter: ByteView[
                origin_of(uri)._get_owned_interior["bytes"]
            ]
            try:
                scheme_delimiter = reader.read_bytes(3)
            except EndOfReaderError:
                raise URIParseError(
                    "URI.parse: Incomplete URI, expected scheme delimiter after scheme but reached the end of the URI."
                )

            if scheme_delimiter != "://".as_bytes():
                raise URIParseError(
                    String(
                        "URI.parse: Invalid URI format, scheme should be followed by `://`. Received: ",
                        uri,
                    )
                )

        # Parse the user info, if exists.
        # TODO (@thatstoasty): Store the user information (username and password) if it exists.
        if UInt8(ord(URIDelimiters.AUTHORITY)) in reader:
            _ = reader.read_until(UInt8(ord(URIDelimiters.AUTHORITY)))
            reader.increment(1)

        # TODOs (@thatstoasty)
        # Handle ipv4 and ipv6 literal
        # Handle string host
        # A query right after the domain is a valid uri, but it's equivalent to example.com/?query
        # so we should add the normalization of paths
        var host_and_port = reader.read_until(UInt8(ord(URIDelimiters.PATH)))
        var colon = host_and_port.find(UInt8(ord(URIDelimiters.SCHEME)))
        var host: String
        var port: Optional[UInt16] = None
        if colon != -1:
            host = String(host_and_port[:colon])
            var port_end = colon + 1
            # loop through the post colon chunk until we find a non-digit character
            for b in host_and_port[colon + 1 :]:
                if b < PortBounds.ZERO or b > PortBounds.NINE:
                    break
                port_end += 1

            try:
                port = UInt16(atol(String(host_and_port[colon + 1 : port_end])))
            except conversion_err:
                raise URIParseError(
                    String(
                        "URI.parse: Failed to convert port number from a String to Integer, received: ",
                        uri,
                    )
                )
        else:
            host = String(host_and_port)

        # Reads until either the start of the query string, or the end of the uri.
        var unquote_reader = reader.copy()
        var original_path_bytes = unquote_reader.read_until(UInt8(ord(URIDelimiters.QUERY)))
        var original_path: String
        if not original_path_bytes:
            original_path = "/"
        else:
            original_path = unquote(String(original_path_bytes), disallowed_escapes=["/"])

        var result = URI(
            _original_path=original_path,
            scheme=scheme,
            path=original_path,
            query_string="",
            queries=QueryMap(),
            _hash="",
            host=host,
            port=port,
            full_uri=uri,
            request_uri=original_path,
            username="",
            password="",
        )

        # Parse the path
        var path_delimiter: Byte
        try:
            path_delimiter = reader.peek()
        except EndOfReaderError:
            return result^

        var path: String = "/"
        var request_uri: String = "/"
        if path_delimiter == UInt8(ord(URIDelimiters.PATH)):
            # Copy the remaining bytes to read the request uri.
            var request_uri_reader = reader.copy()
            request_uri = String(request_uri_reader.read_bytes())

            # Read until the query string, or the end if there is none.
            path = unquote(
                String(reader.read_until(UInt8(ord(URIDelimiters.QUERY)))),
                disallowed_escapes=["/"],
            )

        result.request_uri = request_uri
        result.path = path

        # Parse query
        var query_delimiter: Byte
        try:
            query_delimiter = reader.peek()
        except EndOfReaderError:
            return result^

        var query: String = ""
        if query_delimiter == UInt8(ord(URIDelimiters.QUERY)):
            # TODO: Handle fragments for anchors
            query = String(reader.read_bytes()[1:])

        var queries = QueryMap()
        if query:
            var query_items = query.split(QueryDelimiters.ITEM)

            for item in query_items:
                var key_val = item.split(QueryDelimiters.ITEM_ASSIGN, 1)
                var key = unquote[expand_plus=True](String(key_val[0]))

                if key:
                    queries[key] = ""
                    if len(key_val) == 2:
                        queries[key] = unquote[expand_plus=True](String(key_val[1]))

        result.queries = queries^
        result.query_string = query^
        return result^

    def __str__(self) -> String:
        var result = String(self.scheme, URIDelimiters.SCHEMA, self.host, self.path)
        if self.query_string.byte_length() > 0:
            result.write(QueryDelimiters.STRING_START, self.query_string)
        return result^

    def __repr__(self) -> String:
        return String(self)

    def __eq__(self, other: URI) -> Bool:
        return (
            self.scheme == other.scheme
            and self.host == other.host
            and self.path == other.path
            and self.query_string == other.query_string
            and self._original_path == other._original_path
            and self.full_uri == other.full_uri
            and self.request_uri == other.request_uri
        )

    def write_to[T: Writer](self, mut writer: T):
        writer.write(
            "URI(",
            "scheme=",
            repr(self.scheme),
            ", host=",
            repr(self.host),
            ", path=",
            repr(self.path),
            ", _original_path=",
            repr(self._original_path),
            ", query_string=",
            repr(self.query_string),
            ", full_uri=",
            repr(self.full_uri),
            ", request_uri=",
            repr(self.request_uri),
            ")",
        )

    def is_https(self) -> Bool:
        return self.scheme == https

    def is_http(self) -> Bool:
        return self.scheme == http or self.scheme.byte_length() == 0
