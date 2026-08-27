from lightbug_http.connection import TCPConnection, default_buffer_size
from lightbug_http.cookie import ResponseCookieJar
from lightbug_http.header import HeaderKey, Headers, ParsedResponseHeaders, parse_response_headers, write_header
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.http.date import http_date_now
from lightbug_http.http.encodable import Encodable
from lightbug_http.io.bytes import ByteReader, Bytes, ByteWriter, byte
from lightbug_http.strings import CR, LF, http, lineBreak, strHttp11, whitespace
from lightbug_http.uri import URI
from std.utils import Variant


@fieldwise_init
struct ResponseHeaderParseError(ImplicitlyCopyable):
    """Failed to parse response headers."""

    var detail: String

    def message(self) -> String:
        return String("Failed to parse response headers: ", self.detail)


@fieldwise_init
struct ResponseBodyReadError(ImplicitlyCopyable):
    """Failed to read response body."""

    var detail: String

    def message(self) -> String:
        return String("Failed to read response body: ", self.detail)


@fieldwise_init
struct ChunkedEncodingError(ImplicitlyCopyable):
    """Invalid chunked transfer encoding."""

    var detail: String

    def message(self) -> String:
        return String("Invalid chunked encoding: ", self.detail)


comptime ResponseParseError = Variant[
    ResponseHeaderParseError,
    ResponseBodyReadError,
    ChunkedEncodingError,
]


struct StatusCode:
    """HTTP status codes (RFC 9110)."""

    # 1xx Informational
    comptime CONTINUE = 100
    comptime SWITCHING_PROTOCOLS = 101
    comptime PROCESSING = 102
    comptime EARLY_HINTS = 103

    # 2xx Success
    comptime OK = 200
    comptime CREATED = 201
    comptime ACCEPTED = 202
    comptime NON_AUTHORITATIVE_INFORMATION = 203
    comptime NO_CONTENT = 204
    comptime RESET_CONTENT = 205
    comptime PARTIAL_CONTENT = 206
    comptime MULTI_STATUS = 207
    comptime ALREADY_REPORTED = 208
    comptime IM_USED = 226

    # 3xx Redirection
    comptime MULTIPLE_CHOICES = 300
    comptime MOVED_PERMANENTLY = 301
    comptime FOUND = 302
    comptime SEE_OTHER = 303
    comptime NOT_MODIFIED = 304
    comptime USE_PROXY = 305
    comptime TEMPORARY_REDIRECT = 307
    comptime PERMANENT_REDIRECT = 308

    # 4xx Client Errors
    comptime BAD_REQUEST = 400
    comptime UNAUTHORIZED = 401
    comptime PAYMENT_REQUIRED = 402
    comptime FORBIDDEN = 403
    comptime NOT_FOUND = 404
    comptime METHOD_NOT_ALLOWED = 405
    comptime NOT_ACCEPTABLE = 406
    comptime PROXY_AUTHENTICATION_REQUIRED = 407
    comptime REQUEST_TIMEOUT = 408
    comptime CONFLICT = 409
    comptime GONE = 410
    comptime LENGTH_REQUIRED = 411
    comptime PRECONDITION_FAILED = 412
    comptime REQUEST_ENTITY_TOO_LARGE = 413
    comptime REQUEST_URI_TOO_LONG = 414
    comptime UNSUPPORTED_MEDIA_TYPE = 415
    comptime REQUESTED_RANGE_NOT_SATISFIABLE = 416
    comptime EXPECTATION_FAILED = 417
    comptime IM_A_TEAPOT = 418
    comptime MISDIRECTED_REQUEST = 421
    comptime UNPROCESSABLE_ENTITY = 422
    comptime LOCKED = 423
    comptime FAILED_DEPENDENCY = 424
    comptime TOO_EARLY = 425
    comptime UPGRADE_REQUIRED = 426
    comptime PRECONDITION_REQUIRED = 428
    comptime TOO_MANY_REQUESTS = 429
    comptime REQUEST_HEADER_FIELDS_TOO_LARGE = 431
    comptime UNAVAILABLE_FOR_LEGAL_REASONS = 451

    # 5xx Server Errors
    comptime INTERNAL_SERVER_ERROR = 500
    comptime INTERNAL_ERROR = 500  # Alias for backwards compatibility
    comptime NOT_IMPLEMENTED = 501
    comptime BAD_GATEWAY = 502
    comptime SERVICE_UNAVAILABLE = 503
    comptime GATEWAY_TIMEOUT = 504
    comptime HTTP_VERSION_NOT_SUPPORTED = 505
    comptime VARIANT_ALSO_NEGOTIATES = 506
    comptime INSUFFICIENT_STORAGE = 507
    comptime LOOP_DETECTED = 508
    comptime NOT_EXTENDED = 510
    comptime NETWORK_AUTHENTICATION_REQUIRED = 511


@fieldwise_init
struct HTTPResponse(Encodable, Movable, Sized, Writable):
    var headers: Headers
    var cookies: ResponseCookieJar
    var body_raw: Bytes

    var status_code: Int
    var status_text: String
    var protocol: String
    var sse_streaming: Bool

    var body_fd: Int
    """An open file to send as the body instead of `body_raw`, or -1.

    The point is that the bytes never enter this process: the event loop
    hands the descriptor to `sendfile(2)`. `body_raw` stays EMPTY when
    this is set — the two are alternatives, and `encode_into` therefore
    writes only the head, leaving the loop to transfer the body. The
    `Content-Length` still has to be right, because a framed or
    close-delimited body is not what this path produces; `set_file_body`
    sets it.

    Ownership transfers to whoever encodes the response: the event loop
    closes this descriptor when the transfer finishes, when the client
    disconnects, and when it strips the body from a HEAD. A handler that
    builds a response and then drops it without encoding leaks the fd,
    which is why `StaticFiles` opens the file last, after every refusal
    has already returned."""

    var body_fd_offset: Int
    """Where in the file the body starts — a Range response begins mid-file."""

    var body_fd_len: Int
    """How many bytes to send from `body_fd_offset`."""

    var stream_gen: Int
    """Which generation of channel stream this head opens, or 0.

    Set by a producer that streams a body through the event loop's chunk
    channel (the asyncio executor, a `--blocking-threads` pool thread
    streaming a WSGI iterable) beside `sse_streaming`. The loop records it
    per slot and checks a stream-abort datagram against it, so an abort
    for a stream the slot no longer serves is dropped rather than closing
    whatever connection recycled the slot. 0 (`STREAM_GEN_NONE` in
    `offload.mojo`) means "not a channel stream"."""

    @staticmethod
    def from_bytes(b: Span[Byte, _]) raises ResponseParseError -> HTTPResponse:
        var cookies = ResponseCookieJar()

        var properties: ParsedResponseHeaders
        try:
            properties = parse_response_headers(b)
        except parse_err:
            raise ResponseParseError(ResponseHeaderParseError(detail=String(parse_err)))

        try:
            cookies.from_headers(properties.cookies^)
        except cookie_err:
            raise ResponseParseError(ResponseHeaderParseError(detail=String(cookie_err)))

        # Create reader at the position after headers
        var reader = ByteReader(b)
        try:
            _ = reader.read_bytes(properties.bytes_consumed)
        except bounds_err:
            raise ResponseParseError(ResponseBodyReadError(detail=String(bounds_err)))

        # Fields leave `properties` by swap — the ctor takes them by `var`
        # now, and a struct with a field moved out cannot be destroyed.
        var taken_headers = Headers()
        swap(taken_headers, properties.headers)
        try:
            return HTTPResponse(
                reader=reader,
                headers=taken_headers^,
                cookies=cookies^,
                protocol=properties.protocol,
                status_code=properties.status,
                status_text=properties.status_message,
            )
        except body_err:
            raise ResponseParseError(ResponseBodyReadError(detail=String(body_err)))

    @staticmethod
    def from_bytes(b: Span[Byte, _], conn: TCPConnection) raises ResponseParseError -> HTTPResponse:
        var cookies = ResponseCookieJar()

        var properties: ParsedResponseHeaders
        try:
            properties = parse_response_headers(b)
        except parse_err:
            raise ResponseParseError(ResponseHeaderParseError(detail=String(parse_err)))

        try:
            cookies.from_headers(properties.cookies^)
        except cookie_err:
            raise ResponseParseError(ResponseHeaderParseError(detail=String(cookie_err)))

        # Create reader at the position after headers
        var reader = ByteReader(b)
        try:
            _ = reader.read_bytes(properties.bytes_consumed)
        except bounds_err:
            raise ResponseParseError(ResponseBodyReadError(detail=String(bounds_err)))

        # Same swap idiom as the overload above, same reason.
        var taken_headers = Headers()
        swap(taken_headers, properties.headers)
        var response = HTTPResponse(
            Bytes(),
            headers=taken_headers^,
            cookies=cookies^,
            protocol=properties.protocol,
            status_code=properties.status,
            status_text=properties.status_message,
        )

        var transfer_encoding = response.headers.get(HeaderKey.TRANSFER_ENCODING)
        if transfer_encoding and transfer_encoding.value() == "chunked":
            var decoder = HTTPChunkedDecoder()
            decoder.consume_trailer = True

            var b = Bytes(reader.read_bytes().as_bytes())
            var buff = Bytes(capacity=default_buffer_size)
            try:
                while conn.read(buff) > 0:
                    b.extend(buff.copy())

                    if (
                        len(buff) >= 5
                        and buff[-5] == byte["0"]()
                        and buff[-4] == byte["\r"]()
                        and buff[-3] == byte["\n"]()
                        and buff[-2] == byte["\r"]()
                        and buff[-1] == byte["\n"]()
                    ):
                        break

                    # buff.clear()  # TODO: Should this be cleared? This was commented out before.
            except read_err:
                raise ResponseParseError(ResponseBodyReadError(detail=String(read_err)))

            # response.read_chunks(b)
            # Decode chunks
            response._decode_chunks(decoder, b^)
            return response^

        try:
            response.read_body(reader)
            return response^
        except body_err:
            raise ResponseParseError(ResponseBodyReadError(detail=String(body_err)))

    def _decode_chunks(mut self, mut decoder: HTTPChunkedDecoder, var chunks: Bytes) raises ResponseParseError:
        """Decode chunked transfer encoding.
        Args:
            decoder: The chunked decoder state machine.
            chunks: The raw chunked data to decode.
        """
        # Convert Bytes to Pointer
        # var buf_ptr = Span(chunks)
        # var buf_ptr = alloc[Byte](count=len(chunks))
        # for i in range(len(chunks)):
        #     buf_ptr[i] = chunks[i]

        # var bufsz = len(chunks)
        var result = decoder.decode(Span(chunks))
        var ret = result[0]
        var decoded_size = result[1]

        if ret == -1:
            # buf_ptr.unsafe_free()
            raise ResponseParseError(ChunkedEncodingError(detail="Invalid chunked encoding"))
        # ret == -2 means incomplete, but we'll proceed with what we have
        # ret >= 0 means complete, with ret bytes of trailing data

        # Copy decoded data to body
        self.body_raw = Bytes(capacity=decoded_size)
        for i in range(decoded_size):
            self.body_raw.append(Span(chunks)[i])
        # self.body_raw = Bytes(Span(chunks))

        self.set_content_length(len(self.body_raw))
        # buf_ptr.unsafe_free()

    def __init__(
        out self,
        body_bytes: Span[Byte, _],
        var headers: Headers = Headers(),
        var cookies: ResponseCookieJar = ResponseCookieJar(),
        status_code: Int = 200,
        status_text: String = "OK",
        protocol: String = strHttp11,
    ):
        # Move, not copy: the arguments are almost always temporaries built
        # inline at the call site (`Headers(Header(...))`), and copying the
        # whole header blob per response was 2 of the hot path's ~6
        # allocations. A caller that reuses a named Headers still can — a
        # `var` parameter takes an implicit copy of a value that is used
        # again afterwards.
        self.headers = headers^
        self.cookies = cookies^
        if HeaderKey.CONTENT_TYPE not in self.headers:
            self.headers[HeaderKey.CONTENT_TYPE] = "application/octet-stream"
        self.status_code = status_code
        self.status_text = status_text
        self.protocol = protocol
        self.body_raw = Bytes(body_bytes)
        self.sse_streaming = False
        self.body_fd = -1
        self.body_fd_offset = 0
        self.body_fd_len = 0
        self.stream_gen = 0
        if HeaderKey.CONNECTION not in self.headers:
            self.set_connection_keep_alive()
        if HeaderKey.CONTENT_LENGTH not in self.headers:
            self.set_content_length(len(body_bytes))
        # No Date header here: encode() adds one at wire-write time if the
        # response still lacks it (and the event loop injects a per-second
        # cached value first). Formatting a date per construction was pure
        # per-request overhead — measured ~9% of hello-world throughput.

    def __init__(
        out self,
        var owned_body: Bytes,
        var headers: Headers = Headers(),
        var cookies: ResponseCookieJar = ResponseCookieJar(),
        status_code: Int = 200,
        status_text: String = "OK",
        protocol: String = strHttp11,
    ):
        """Initialize with an owned body buffer (zero-copy move)."""
        self.headers = headers^
        self.cookies = cookies^
        if HeaderKey.CONTENT_TYPE not in self.headers:
            self.headers[HeaderKey.CONTENT_TYPE] = "application/octet-stream"
        self.status_code = status_code
        self.status_text = status_text
        self.protocol = protocol
        var body_len = len(owned_body)
        self.body_raw = owned_body^
        self.sse_streaming = False
        self.body_fd = -1
        self.body_fd_offset = 0
        self.body_fd_len = 0
        self.stream_gen = 0
        if HeaderKey.CONNECTION not in self.headers:
            self.set_connection_keep_alive()
        if HeaderKey.CONTENT_LENGTH not in self.headers:
            self.set_content_length(body_len)
        # No Date header here: encode() adds one at wire-write time if the
        # response still lacks it (and the event loop injects a per-second
        # cached value first). Formatting a date per construction was pure
        # per-request overhead — measured ~9% of hello-world throughput.

    def __init__(
        out self,
        mut reader: ByteReader,
        var headers: Headers = Headers(),
        var cookies: ResponseCookieJar = ResponseCookieJar(),
        status_code: Int = 200,
        status_text: String = "OK",
        protocol: String = strHttp11,
    ) raises:
        self.headers = headers^
        self.cookies = cookies^
        if HeaderKey.CONTENT_TYPE not in self.headers:
            self.headers[HeaderKey.CONTENT_TYPE] = "application/octet-stream"
        self.status_code = status_code
        self.status_text = status_text
        self.protocol = protocol
        self.body_raw = Bytes(reader.read_bytes().as_bytes())
        self.sse_streaming = False
        self.body_fd = -1
        self.body_fd_offset = 0
        self.body_fd_len = 0
        self.stream_gen = 0
        self.set_content_length(len(self.body_raw))
        if HeaderKey.CONNECTION not in self.headers:
            self.set_connection_keep_alive()
        if HeaderKey.CONTENT_LENGTH not in self.headers:
            self.set_content_length(len(self.body_raw))
        # No Date header here: encode() adds one at wire-write time if the
        # response still lacks it (and the event loop injects a per-second
        # cached value first). Formatting a date per construction was pure
        # per-request overhead — measured ~9% of hello-world throughput.

    def __len__(self) -> Int:
        return len(self.body_raw)

    def get_body(self) -> StringSlice[origin_of(self.body_raw)]:
        return StringSlice(unsafe_from_utf8=Span(self.body_raw))

    @always_inline
    def set_connection_close(mut self):
        self.headers[HeaderKey.CONNECTION] = "close"

    def connection_close(self) -> Bool:
        """RFC 9110 §7.6.1: Connection option tokens are case-insensitive.

        Compared against the header bytes directly; see the request-side
        twin for why the String-building form was worth replacing.
        """
        return self.headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close")

    @always_inline
    def set_connection_keep_alive(mut self):
        self.headers[HeaderKey.CONNECTION] = "keep-alive"

    @always_inline
    def set_content_length(mut self, l: Int):
        self.headers.set_int(HeaderKey.CONTENT_LENGTH, l)

    @always_inline
    def content_length(self) -> Int:
        var header_val = self.headers.get(HeaderKey.CONTENT_LENGTH)
        if not header_val:
            return 0
        try:
            return Int(header_val.value())
        except:
            return 0

    @always_inline
    def is_redirect(self) -> Bool:
        return (
            self.status_code == StatusCode.MOVED_PERMANENTLY
            or self.status_code == StatusCode.FOUND
            or self.status_code == StatusCode.TEMPORARY_REDIRECT
            or self.status_code == StatusCode.PERMANENT_REDIRECT
        )

    @always_inline
    def read_body(mut self, mut r: ByteReader) raises:
        try:
            self.body_raw = Bytes(r.read_bytes(self.content_length()).as_bytes())
            self.set_content_length(len(self.body_raw))
        except e:
            raise Error(String(e))

    def read_chunks(mut self, chunks: Span[Byte, _]) raises:
        var reader = ByteReader(chunks)
        while True:
            var size = atol(String(reader.read_line()), 16)
            if size == 0:
                break
            try:
                var data = reader.read_bytes(size).as_bytes()
                reader.skip_carriage_return()
                self.set_content_length(self.content_length() + len(data))
                self.body_raw.extend(data)
            except e:
                raise Error(String(e))

    def write_to[T: Writer](self, mut writer: T):
        writer.write(
            self.protocol,
            whitespace,
            self.status_code,
            whitespace,
            self.status_text,
            lineBreak,
        )

        if HeaderKey.SERVER not in self.headers:
            writer.write("server: lightbug_http", lineBreak)

        writer.write(
            self.headers,
            self.cookies,
            lineBreak,
            StringSlice(unsafe_from_utf8=Span(self.body_raw)),
        )

    def encode(deinit self) -> Bytes:
        """Encodes response as bytes.

        This method consumes the data in this request and it should
        no longer be considered valid.
        """
        var writer = ByteWriter()
        writer.write(
            self.protocol,
            whitespace,
            self.status_code,
            whitespace,
            self.status_text,
            lineBreak,
            "server: lightbug_http",
            lineBreak,
        )
        if HeaderKey.DATE not in self.headers:
            write_header(writer, HeaderKey.DATE, http_date_now())
        self.headers.write_latin1_to(writer)
        writer.write(self.cookies, lineBreak)
        writer.consuming_write(self.body_raw^)
        return writer^.consume()

    def set_file_body(mut self, fd: Int, offset: Int, length: Int):
        """Send `length` bytes of `fd` from `offset` as the body.

        Takes ownership of `fd`: from here the event loop closes it, on
        every path including a client that disappears mid-transfer. Clears
        `body_raw`, because the two body kinds are alternatives and a
        buffer left behind would be written in front of the file's bytes.
        """
        self.body_raw = Bytes()
        self.body_fd = fd
        self.body_fd_offset = offset
        self.body_fd_len = length
        self.set_content_length(length)

    def encode_into(deinit self, var buf: Bytes) -> Bytes:
        """Encode response into a pre-allocated buffer (zero new-alloc hot path).

        Takes ownership of `buf`, clears it, writes the response into it, and
        returns the filled buffer.  The caller should swap the returned buffer
        into its slot and replace `buf` with a fresh one for the next request.
        """
        buf.clear()
        var writer = ByteWriter(buf^)
        writer.write(
            self.protocol,
            whitespace,
            self.status_code,
            whitespace,
            self.status_text,
            lineBreak,
            "server: lightbug_http",
            lineBreak,
        )
        if HeaderKey.DATE not in self.headers:
            write_header(writer, HeaderKey.DATE, http_date_now())
        self.headers.write_latin1_to(writer)
        writer.write(self.cookies, lineBreak)
        writer.consuming_write(self.body_raw^)
        return writer^.consume()

    def __str__(self) -> String:
        return String(self)
