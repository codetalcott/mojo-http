from lightbug_http.io.bytes import ByteReader


def _hex_upper(v: Int) -> String:
    """One uppercase hex digit."""
    return String(unsafe_from_utf8="0123456789ABCDEF".as_bytes()[v : v + 1])


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
    comptime ITEM = "&"
    comptime ITEM_ASSIGN = "="


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


def userinfo_separator(uri: StringSpan, authority_start: Int) -> Int:
    """Index of the `@` that ends a userinfo, or -1 if there is none.

    `URI.parse` skipped a userinfo whenever an `@` appeared ANYWHERE after
    the scheme, so an unencoded one in the path or the query -- both allow
    it (RFC 3986 §3.3, §3.4) -- was read as the end of a userinfo, and
    everything before it thrown away: `/echo?x=a@b` reached the application
    as `/` with no query, whatever its method, and a client URL
    `http://a.test/p?x=a@b` was dialled at host `b`. Browsers and htmx
    encode `@` in what they build, which is what kept it rare; a typed or
    hand-built URL does not.

    A userinfo lives inside the authority, so the `@` only counts before
    `authority_end`, the one rule for where the authority ends. The first
    one found is the separator: a userinfo cannot contain `@`, so a second
    one leaves a host that fails to resolve rather than one chosen from
    what follows it.
    """
    var bytes = uri.as_bytes()
    for i in range(authority_start, authority_end(uri, authority_start)):
        if bytes[i] == UInt8(ord("@")):
            return i
    return -1


def authority_end(uri: StringSpan, authority_start: Int) -> Int:
    """Index of the `/`, `?` or `#` that ends an authority, or the end of
    `uri` (RFC 3986 §3.2). `userinfo_separator` and `URI.parse` both ask
    it, so the two cannot disagree about where the authority ends.

    The authority ran to the first `/` alone, so a query right after it
    was read as part of the host: `http://h?q=1` parsed as host `h?q=1`
    with no query, and `http://h:80?q=1` as port 80 with its query thrown
    away (review record LF50). It ignored a `#` too, which the userinfo
    scan stopped at, so `http://h#x` was a host `h#x`.
    """
    var bytes = uri.as_bytes()
    for i in range(authority_start, len(bytes)):
        var c = bytes[i]
        if c == UInt8(ord("/")) or c == UInt8(ord("?")) or c == UInt8(ord("#")):
            return i
    return len(bytes)


struct URIDelimiters:
    comptime PATH = "/"
    comptime QUERY = "?"
    comptime SCHEME = ":"


struct PortBounds:
    comptime NINE: UInt8 = UInt8(ord("9"))
    comptime ZERO: UInt8 = UInt8(ord("0"))


struct URIParseError(Writable):
    var message: String

    def __init__(out self, var message: String):
        self.message = message^

    def write_to[W: Writer, //](self, mut writer: W) -> None:
        writer.write(self.message)


@fieldwise_init
struct URI(Copyable, Writable):
    var scheme: String
    var path: String
    var query_string: String
    var queries: QueryMap
    var host: String
    var port: Optional[UInt16]
    var request_uri: String

    @staticmethod
    def parse(var uri: String) raises URIParseError -> URI:
        """Parses a URI which is defined using the following format.

        `[scheme:][//[user_info@]host][/]path[?query][#fragment]`
        """
        # Computed before the reader borrows `uri`: taking a second interior
        # reference while the reader holds one invalidates it.
        var scheme_sep = scheme_separator(uri)
        var userinfo_at = userinfo_separator(uri, scheme_sep + 3 if scheme_sep >= 0 else 0)
        var host_start = userinfo_at + 1 if userinfo_at >= 0 else (
            scheme_sep + 3 if scheme_sep >= 0 else 0
        )
        # The byte the authority ends at: whichever of `/`, `?` and `#`
        # comes first, so reading to it reads the authority whole. After a
        # `#` comes a fragment, which no request carries: neither the path
        # nor the query below reads it, and the path stays `/`.
        var host_end = authority_end(uri, host_start)
        var authority_delimiter = UInt8(ord(URIDelimiters.PATH))
        if host_end < uri.byte_length():
            authority_delimiter = uri.as_bytes()[host_end]
        var reader = ByteReader(uri.as_bytes())

        # Parse the scheme, if exists.
        # Assume http if no scheme is provided, fairly safe given the context of lightbug.
        var scheme: String = "http"
        if scheme_sep >= 0:
            # `scheme_separator` found `://` at `scheme_sep` with nothing but
            # scheme characters before it, none of them a colon: the first
            # colon is that separator's, and the `://` follows it.
            scheme = String(reader.read_until(UInt8(ord(URIDelimiters.SCHEME))))
            reader.increment(3)

        # Skip a userinfo, if there is one: only an `@` inside the authority
        # ends one (`userinfo_separator`). It is never stored. RFC 9110
        # §4.2.4 forbids one in an `http` or `https` URI a message carries
        # and asks a recipient to treat one as an error, which the header
        # parse does for a request target (SPEC B16), so only a caller's own
        # URL brings one here.
        if userinfo_at >= 0:
            reader.increment(userinfo_at + 1 - reader.read_pos)

        # The host and port run to the authority's end (`authority_end`).
        var host_and_port = reader.read_until(authority_delimiter)
        # An IPv6 literal is bracketed (RFC 3986 section 3.2.2), and its
        # colons are not the port's: `[::1]:8080`. The port's colon is the
        # first after the `]`, and the brackets stay in `host`, as a `Host`
        # header built from it needs them. A server on `::` puts its own
        # address in front of every target that carries a query, so the
        # first colon of `[::]:8080` was read as the port's, `atol` failed on
        # `:]`, and every such request was answered 400 (review R15).
        var port_from = 0
        if len(host_and_port) > 0 and host_and_port[0] == UInt8(ord("[")):
            var close = host_and_port.find(UInt8(ord("]")))
            if close == -1:
                raise URIParseError(
                    String("URI.parse: an IPv6 host with no closing ']': ", uri)
                )
            port_from = close + 1
        var colon = host_and_port[port_from:].find(UInt8(ord(URIDelimiters.SCHEME)))
        if colon != -1:
            colon += port_from
        var host: String
        var port: Optional[UInt16] = None
        if colon != -1:
            host = String(host_and_port[:colon])
            # RFC 3986 §3.2.3: the port is every byte after the colon, all
            # digits, and an empty one is the scheme's default. It was the
            # digits up to the first other byte, narrowed to 16 bits, so
            # `:8x` was port 8, `:99999` port 34463 and `:65536` port 0,
            # and the empty port was refused (review record LF51).
            var value = 0
            var digits = 0
            for b in host_and_port[colon + 1 :]:
                if b < PortBounds.ZERO or b > PortBounds.NINE:
                    raise URIParseError(
                        String("URI.parse: a port is digits only: ", uri)
                    )
                value = value * 10 + Int(b - PortBounds.ZERO)
                if value > 65535:
                    raise URIParseError(
                        String("URI.parse: a port above 65535: ", uri)
                    )
                digits += 1
            if digits > 0:
                port = UInt16(value)
        else:
            host = String(host_and_port)

        # A URL that ends with its authority has the path `/`.
        var result = URI(
            scheme=scheme,
            path="/",
            query_string="",
            queries=QueryMap(),
            host=host,
            port=port,
            request_uri="/",
        )

        # Parse the path
        var path_delimiter: Byte
        try:
            path_delimiter = reader.peek()
        except:
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
        elif path_delimiter == UInt8(ord(URIDelimiters.QUERY)):
            # A query right after the authority: the path is empty, which
            # is `/` (RFC 9110 §4.2.3), and the query is read below.
            var request_uri_reader = reader.copy()
            request_uri = String("/", String(request_uri_reader.read_bytes()))

        result.request_uri = request_uri
        result.path = path

        # Parse query
        var query_delimiter: Byte
        try:
            query_delimiter = reader.peek()
        except:
            return result^

        var query: String = ""
        if query_delimiter == UInt8(ord(URIDelimiters.QUERY)):
            # The query runs to the end. A request target has no fragment
            # (RFC 9112 §3.2), so a `#` that arrives in one is data the
            # header parse accepted as any other visible byte (SPEC B19),
            # kept in the query or the path as h11 keeps it, never a cut.
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

    def __eq__(self, other: URI) -> Bool:
        return (
            self.scheme == other.scheme
            and self.host == other.host
            and self.path == other.path
            and self.query_string == other.query_string
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
            ", query_string=",
            repr(self.query_string),
            ", request_uri=",
            repr(self.request_uri),
            ")",
        )
