from lightbug_http.header import Header, HeaderKey, Headers, ParsedRequestHeaders, write_header
from lightbug_http.http.encodable import Encodable
from lightbug_http.io.bytes import Bytes, ByteWriter
from lightbug_http.io.sync import Duration
from lightbug_http.strings import lineBreak, strHttp11, whitespace
from lightbug_http.uri import URI, QueryMap
from std.utils import Variant

from lightbug_http.cookie import RequestCookieJar


@fieldwise_init
struct URITooLongError(ImplicitlyCopyable):
    """Request URI exceeded maximum length."""

    def message(self) -> String:
        return "Request URI exceeds maximum allowed length"


@fieldwise_init
struct RequestBodyTooLargeError(ImplicitlyCopyable):
    """Request body exceeded maximum size."""

    def message(self) -> String:
        return "Request body exceeds maximum allowed size"


@fieldwise_init
struct URIParseError(ImplicitlyCopyable):
    """Failed to parse request URI."""

    def message(self) -> String:
        return "Malformed request URI"


@fieldwise_init
struct CookieParseError(ImplicitlyCopyable):
    """Failed to parse cookies."""

    var detail: String

    def message(self) -> String:
        return String("Invalid cookies: ", self.detail)


comptime RequestBuildError = Variant[
    URITooLongError,
    RequestBodyTooLargeError,
    URIParseError,
    CookieParseError,
]


@fieldwise_init
struct RequestMethod:
    """HTTP request method constants."""

    var value: String

    comptime get = RequestMethod("GET")
    comptime post = RequestMethod("POST")
    comptime put = RequestMethod("PUT")
    comptime delete = RequestMethod("DELETE")
    comptime head = RequestMethod("HEAD")
    comptime patch = RequestMethod("PATCH")
    comptime options = RequestMethod("OPTIONS")


comptime strSlash = "/"


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
    var timeout: Duration
    var slot_id: Int

    @staticmethod
    def from_parsed(
        server_addr: String,
        var parsed: ParsedRequestHeaders,
        var body: Bytes,
        max_uri_length: Int,
    ) raises RequestBuildError -> HTTPRequest:
        """Construct an HTTPRequest from parsed headers and body.

        This is the primary factory method for creating requests. The server
        should use header.mojo's parse_request_headers() to parse the headers,
        then read the body separately, and finally call this method.

        Args:
            server_addr: The server address (used for URI construction).
            parsed: The parsed request headers from parse_request_headers().
            body: The request body bytes.
            max_uri_length: Maximum allowed URI length.

        Returns:
            A fully constructed HTTPRequest.

        Raises:
            RequestBuildError: If URI is too long, URI parsing fails, or cookie parsing fails.
        """
        if parsed.path.byte_length() > max_uri_length:
            raise RequestBuildError(URITooLongError())

        var cookies = RequestCookieJar()
        for cookie_ref in parsed.cookies:
            if "=" in cookie_ref:
                var key_value = cookie_ref.split("=")
                var key = String(key_value[0])
                var value = String(key_value[1]) if len(key_value) > 1 else String("")
                cookies._inner[key] = value

        # Fast path: an origin-form path with no percent-escapes and no query
        # string needs no URI parsing at all — every derived field is the
        # path itself. This is the overwhelmingly common case for API
        # traffic; anything else falls back to the full parser.
        var needs_full_parse = (
            parsed.path.byte_length() == 0
            or parsed.path.as_bytes()[0] != 0x2F  # '/'
            or ("%" in parsed.path)
            or ("?" in parsed.path)
        )

        var parsed_uri: URI
        if not needs_full_parse:
            parsed_uri = URI(
                _original_path=parsed.path,
                scheme="http",
                path=parsed.path,
                query_string="",
                queries=QueryMap(),
                _hash="",
                host=server_addr,
                port=None,
                full_uri=parsed.path,
                request_uri=parsed.path,
                username="",
                password="",
            )
        else:
            var full_uri_string = String(server_addr, parsed.path)
            try:
                parsed_uri = URI.parse(full_uri_string)
            except uri_err:
                raise RequestBuildError(URIParseError())

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
        )

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
        timeout: Duration = Duration(),
    ):
        """Initialize a new HTTP request.

        This constructor is for building outgoing requests. For parsing incoming
        requests, use from_parsed() instead.
        """
        self.headers = headers^
        self.cookies = cookies.copy()
        self.method = method^
        self.protocol = protocol^
        self.uri = uri^
        self.body_raw = body^
        self.server_is_tls = server_is_tls
        self.timeout = timeout
        self.slot_id = -1
        self.set_content_length(len(self.body_raw))

        if HeaderKey.CONNECTION not in self.headers:
            # HTTP/1.1 defaults to persistent connections; HTTP/1.0 does not
            if self.protocol == strHttp11:
                self.headers[HeaderKey.CONNECTION] = "keep-alive"
            else:
                self.headers[HeaderKey.CONNECTION] = "close"
        if HeaderKey.HOST not in self.headers:
            if self.uri.port:
                self.headers[HeaderKey.HOST] = String(self.uri.host, ":", self.uri.port.value())
            else:
                self.headers[HeaderKey.HOST] = self.uri.host

    def get_body(self) -> StringSlice[origin_of(self.body_raw)]:
        """Get the request body as a string slice."""
        return StringSlice(unsafe_from_utf8=Span(self.body_raw))

    def set_connection_close(mut self):
        """Set the Connection header to 'close'."""
        self.headers[HeaderKey.CONNECTION] = "close"

    def set_content_length(mut self, length: Int):
        """Set the Content-Length header."""
        self.headers[HeaderKey.CONTENT_LENGTH] = String(length)

    def connection_close(self) -> Bool:
        """Check if the Connection header is set to 'close'.

        RFC 9110 §7.6.1: Connection option tokens are case-insensitive.

        Answered against the header bytes directly — the `get(...).lower()`
        form built two Strings per request just to compare four characters.
        """
        return self.headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close")

    def write_to[T: Writer, //](self, mut writer: T):
        """Write the request in HTTP format to a writer."""
        path = self.uri.path if self.uri.path.byte_length() > 1 else strSlash
        if self.uri.query_string.byte_length() > 0:
            path.write("?", self.uri.query_string)

        writer.write(
            self.method,
            whitespace,
            path,
            whitespace,
            self.protocol,
            lineBreak,
            self.headers,
            self.cookies,
            lineBreak,
            StringSlice(unsafe_from_utf8=Span(self.body_raw)),
        )

    def encode(deinit self) -> Bytes:
        """Encode request as bytes, consuming the request."""
        var path = self.uri.path if self.uri.path.byte_length() > 1 else strSlash
        if self.uri.query_string.byte_length() > 0:
            path.write("?", self.uri.query_string)

        var writer = ByteWriter()
        writer.write(
            self.method,
            whitespace,
            path,
            whitespace,
            self.protocol,
            lineBreak,
        )
        self.headers.write_latin1_to(writer)
        writer.write(self.cookies, lineBreak)
        writer.consuming_write(self.body_raw^)
        return writer^.consume()

    def __str__(self) -> String:
        return String(self)

    def __eq__(self, other: HTTPRequest) -> Bool:
        return (
            self.method == other.method
            and self.protocol == other.protocol
            and self.uri == other.uri
            and self.headers == other.headers
            and self.cookies == other.cookies
            and len(self.body_raw) == len(other.body_raw)
        )

    def __isnot__(self, other: HTTPRequest) -> Bool:
        return not self.__eq__(other)
