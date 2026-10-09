from lightbug_http.header import (
    HeaderKey, Headers, ParsedRequestHeaders,
    KH_CONNECTION, KH_CONTENT_LENGTH, KH_HOST,
)
from lightbug_http.http.encodable import Encodable
from lightbug_http.io.bytes import Bytes, ByteWriter
from lightbug_http.strings import lineBreak, strHttp10, strHttp11, whitespace
from lightbug_http.uri import URI, QueryMap
from std.utils import Variant

from lightbug_http.cookie import RequestCookieJar


def _drop_final_chunked(mut headers: Headers):
    """Remove `chunked`, the final transfer coding (RFC 9112 §6.1), from a
    de-chunked request's `Transfer-Encoding`, and the header itself when
    nothing else is left.

    The parser has already refused a request whose last coding is anything
    else (400), that applies `chunked` twice (400), or that names another
    coding before it (501, SPEC B21), so what reaches here from the loop is
    `chunked` behind empty members at most. Empty list elements mean nothing
    (RFC 9110 §5.6.1) and are dropped with it, so `, chunked` leaves no
    empty field beside the length. A byte walk, never `[byte=a:b]`: a
    header value may hold obs-text, which is not UTF-8.
    """
    var te = headers.get(HeaderKey.TRANSFER_ENCODING)
    if not te:
        return
    var value = te.value()
    var raw = value.as_bytes()
    var last_comma = -1
    for i in range(len(raw)):
        if raw[i] == 0x2C:  # ','
            last_comma = i
    var kept = List[UInt8]()
    var start = 0
    while start < last_comma:
        var stop = start
        while stop < last_comma and raw[stop] != 0x2C:
            stop += 1
        var a = start
        var b = stop
        while a < b and (raw[a] == 0x20 or raw[a] == 0x09):
            a += 1
        while b > a and (raw[b - 1] == 0x20 or raw[b - 1] == 0x09):
            b -= 1
        if b > a:
            if len(kept) > 0:
                kept.append(0x2C)
                kept.append(0x20)
            for k in range(a, b):
                kept.append(raw[k])
        start = stop + 1
    if len(kept) == 0:
        headers.pop(HeaderKey.TRANSFER_ENCODING)
        return
    headers[HeaderKey.TRANSFER_ENCODING] = String(unsafe_from_utf8=Span(kept))


@fieldwise_init
struct URITooLongError(ImplicitlyCopyable):
    """Request URI exceeded maximum length."""

    def message(self) -> String:
        return "Request URI exceeds maximum allowed length"


@fieldwise_init
struct URIParseError(ImplicitlyCopyable):
    """Failed to parse request URI."""

    def message(self) -> String:
        return "Malformed request URI"


comptime RequestBuildError = Variant[URITooLongError, URIParseError]


comptime strSlash = "/"


def split_server_address(address: String) -> Tuple[String, Optional[UInt16]]:
    """The host and port of the address a server listens on, as a parsed
    request's `uri.host` and `uri.port` carry them: `127.0.0.1:8973` is
    (`127.0.0.1`, 8973), `[::1]:8080` (`[::1]`, 8080), and a scheme or a
    missing port is allowed (`http://localhost` is (`localhost`, None)).

    Split ONCE, where a loop is built (`LoopState`), and handed to every
    `HTTPRequest.from_parsed` it makes: a request's URI names the server the
    same way whatever its target's shape (SPEC A37). An address `URI.parse`
    refuses -- an unclosed `[` -- is the host whole, with no port.
    """
    try:
        var u = URI.parse(address)
        return (u.host, u.port)
    except:
        return (address, None)


@fieldwise_init
struct HTTPRequest(Copyable, Encodable, Writable):
    """Represents a parsed HTTP request.

    This type is constructed from already-parsed components. The server is responsible
    for driving the parsing process (using header.mojo functions) and constructing
    the request once all data is available.
    """

    var headers: Headers
    var cookies: RequestCookieJar
    var uri: URI
    var body_raw: Bytes

    var method: String
    var protocol: String

    var server_is_tls: Bool
    var slot_id: Int

    var remote_addr: String
    var remote_port: Int
    """The accepted connection's peer, stamped by the non-blocking event
    loop after parsing (the same post-construction pattern as `slot_id`);
    empty/0 for outgoing requests and any built without a connection. What
    feeds WSGI's `REMOTE_ADDR` and ASGI's `scope["client"]` — Django reads
    both, and an empty one silently disables every IP-keyed thing an app
    does (rate limits, allow-lists, audit logs) rather than erroring."""

    @staticmethod
    def from_parsed(
        server_host: String,
        server_port: Optional[UInt16],
        var parsed: ParsedRequestHeaders,
        var body: Bytes,
        max_uri_length: Int,
    ) raises RequestBuildError -> HTTPRequest:
        """Construct an HTTPRequest from parsed headers and body.

        This is the primary factory method for creating requests. The server
        should use header.mojo's parse_request_headers() to parse the headers,
        then read the body separately, and finally call this method.

        The URI names the server the same way whatever the target's shape
        (SPEC A37): `uri.host` and `uri.port` are the address the server
        listens on, split once by `split_server_address`, and
        `uri.request_uri` is the request target as it arrived (SPEC A38) --
        origin-form, an absolute-form target already reduced to its path
        (B16) whose authority is the request's `Host` header, or `*`. They
        used to depend on the target: a path with no query or escape got
        the whole address in `host` and no port, one with either got them
        split by a parse of the address and the target together (review
        record LF54).

        Args:
            server_host: The host of the address the server listens on.
            server_port: Its port, if the address names one.
            parsed: The parsed request headers from parse_request_headers().
            body: The request body bytes.
            max_uri_length: Maximum allowed URI length.

        Returns:
            A fully constructed HTTPRequest.

        Raises:
            RequestBuildError: If the target is longer than `max_uri_length`,
                or `URI.parse` refuses it.
        """
        if parsed.path.byte_length() > max_uri_length:
            raise RequestBuildError(URITooLongError())

        var cookies = RequestCookieJar()
        for cookie_ref in parsed.cookies:
            cookies.add_pairs(cookie_ref)

        # Fast path: an origin-form path with no percent-escapes and no query
        # string needs no URI parsing at all — every derived field is the
        # path itself. This is the overwhelmingly common case for API
        # traffic; anything else falls back to the full parser.
        #
        # The asterisk-form target of a server-wide OPTIONS (RFC 9112
        # §3.2.4; the header parse admits `*` for OPTIONS alone) takes the
        # same path, so the application reads `*`: the parser below, handed
        # the address and `*`, answered `/`, and `OPTIONS *` reached the
        # application as `OPTIONS /` (review record LF41).
        var needs_full_parse = parsed.path != "*" and (
            parsed.path.byte_length() == 0
            or parsed.path.as_bytes()[0] != 0x2F  # '/'
            or ("%" in parsed.path)
            or ("?" in parsed.path)
        )

        var parsed_uri: URI
        if not needs_full_parse:
            parsed_uri = URI(
                scheme="http",
                path=parsed.path,
                query_string="",
                queries=QueryMap(),
                host=server_host,
                port=server_port,
                request_uri=parsed.path,
            )
        else:
            # The target alone: a path has no authority for the parse to
            # find, and the server's comes from the caller (LF54).
            try:
                parsed_uri = URI.parse(parsed.path)
            except uri_err:
                raise RequestBuildError(URIParseError())
            parsed_uri.host = server_host
            parsed_uri.port = server_port
            # The target as it arrived, escapes and all, which the writers
            # send back (review record LF62).
            parsed_uri.request_uri = parsed.path

        # Asked before the headers move into the request below.
        var dechunked = parsed.is_chunked_body()

        # Take the parsed headers by swap rather than copying them —
        # `parsed` is owned here, but Mojo cannot destroy a struct with one
        # field moved out, so swap an empty collection into its place.
        var taken_headers = Headers()
        swap(taken_headers, parsed.headers)

        var request = HTTPRequest(
            uri=parsed_uri^,
            headers=taken_headers^,
            method=parsed.method,
            protocol=parsed.protocol,
            cookies=cookies^,
            body=body^,
            invent_headers=False,
        )

        # The headers as the client sent them (SPEC L25). A body the loop
        # de-chunked is now a sized body: it is described by its length, and
        # the `chunked` coding it arrived in is gone, so an application --
        # or a proxy forwarding the headers on -- never sees the
        # contradictory pair. No other coding gets this far: the parser
        # refuses one (SPEC B21). A request that carried no length gets
        # none invented: a GET's `content-length: 0` was ours, not the
        # client's.
        if dechunked:
            _drop_final_chunked(request.headers)
            request.set_content_length(len(request.body_raw))

        return request^

    def __init__(
        out self,
        var uri: URI,
        var headers: Headers = Headers(),
        var cookies: RequestCookieJar = RequestCookieJar(),
        var method: String = "GET",
        var protocol: String = strHttp11,
        var body: Bytes = Bytes(),
        server_is_tls: Bool = False,
        invent_headers: Bool = True,
    ):
        """Initialize a new HTTP request.

        This constructor is for building outgoing requests. For parsing incoming
        requests, use from_parsed() instead.

        `invent_headers` fills in what a client must send -- `Content-Length`,
        `Connection` from the protocol and `Host` from the URI -- and is how
        `from_parsed` turns it off: on the server side each was a header the
        client never sent (SPEC L25).
        """
        self.headers = headers^
        self.cookies = cookies^
        self.method = method^
        self.protocol = protocol^
        self.uri = uri^
        self.body_raw = body^
        self.server_is_tls = server_is_tls
        self.slot_id = -1
        self.remote_addr = String("")
        self.remote_port = 0
        if not invent_headers:
            return
        self.set_content_length(len(self.body_raw))

        if self.headers.known_index(KH_CONNECTION) < 0:
            # HTTP/1.1 defaults to persistent connections; HTTP/1.0 does not
            if self.protocol == strHttp11:
                self.headers.set_known(
                    KH_CONNECTION, HeaderKey.CONNECTION.as_bytes(), "keep-alive".as_bytes()
                )
            else:
                self.headers.set_known(
                    KH_CONNECTION, HeaderKey.CONNECTION.as_bytes(), "close".as_bytes()
                )
        if self.headers.known_index(KH_HOST) < 0:
            if self.uri.port:
                self.headers[HeaderKey.HOST] = String(self.uri.host, ":", self.uri.port.value())
            else:
                self.headers[HeaderKey.HOST] = self.uri.host

    def get_body(self) -> StringSpan[origin_of(self.body_raw)]:
        """Get the request body as a string slice."""
        return StringSpan(unsafe_from_utf8=Span(self.body_raw))

    def set_content_length(mut self, length: Int):
        """Set the Content-Length header."""
        self.headers.set_int_known(
            KH_CONTENT_LENGTH, HeaderKey.CONTENT_LENGTH.as_bytes(), length
        )

    def connection_close(self) -> Bool:
        """Whether the connection closes after this request (RFC 9112 §9.3).

        `Connection: close` closes; otherwise HTTP/1.1 persists and HTTP/1.0
        persists only when it asked with `Connection: keep-alive`. The
        protocol is read here because a parsed request no longer carries the
        `Connection: close` the outgoing constructor used to write into every
        HTTP/1.0 request that sent none (SPEC L25).

        RFC 9110 §7.6.1: `Connection` is a list of option tokens, each
        case-insensitive, so `close` closes wherever it stands in the list
        and `keep-alive` keeps a 1.0 connection likewise. The whole value
        was compared, and `Connection: close, TE` kept the connection
        alive, answering the request pipelined behind it (SPEC B17).

        Answered against the header bytes directly — the `get(...).lower()`
        form built two Strings per request just to compare four characters.
        """
        if self.headers.has_token_ignore_case(HeaderKey.CONNECTION, "close"):
            return True
        if self.protocol != strHttp10:
            return False
        return not self.headers.has_token_ignore_case(
            HeaderKey.CONNECTION, "keep-alive"
        )

    def _target(self) -> String:
        """The request target the writers send: the URI's `request_uri`,
        as it arrived or as the URL spelled it, escapes and all.

        They wrote `uri.path`, which is percent-DECODED, and its query: so
        `/a%20b` went out as `/a b`, no longer one request line's target,
        an encoded CR LF as the real bytes, a request line split in two,
        and an asterisk-form `*` as `/` (review record LF62).
        """
        if self.uri.request_uri.byte_length() == 0:
            return strSlash
        return self.uri.request_uri

    def write_to[T: Writer, //](self, mut writer: T):
        """Write the request in HTTP format to a writer."""
        writer.write(
            self.method,
            whitespace,
            self._target(),
            whitespace,
            self.protocol,
            lineBreak,
            self.headers,
        )
        # A parsed request carries `Cookie` in `headers` as well as in the jar,
        # so writing the jar unconditionally would emit the field twice. A
        # hand-built request (the client's) has the jar and no header, and
        # still gets its cookies written here.
        if HeaderKey.COOKIE not in self.headers:
            writer.write(self.cookies)
        writer.write(
            lineBreak,
            StringSpan(unsafe_from_utf8=Span(self.body_raw)),
        )

    def encode(deinit self) -> Bytes:
        """Encode request as bytes, consuming the request."""
        var writer = ByteWriter()
        writer.write(
            self.method,
            whitespace,
            self._target(),
            whitespace,
            self.protocol,
            lineBreak,
        )
        self.headers.write_latin1_to(writer)
        # See write_to: the jar is written only when `headers` does not already
        # carry the field, so a re-encoded parsed request keeps one `Cookie`.
        if HeaderKey.COOKIE not in self.headers:
            writer.write(self.cookies)
        writer.write(lineBreak)
        writer.consuming_write(self.body_raw^)
        return writer^.consume()
