from lightbug_http.c.pipe import close_fd
from lightbug_http.cookie import ResponseCookieJar
from lightbug_http.header import (
    HeaderKey, Headers, write_header,
    span_breaks_header_line,
    KH_CONNECTION, KH_CONTENT_LENGTH, KH_CONTENT_TYPE, KH_DATE, KH_SERVER,
)
from lightbug_http.http.date import http_date_now
from lightbug_http.http.encodable import Encodable
from lightbug_http.io.bytes import Bytes, ByteWriter
from lightbug_http.strings import lineBreak, strHttp11, whitespace


def is_bodiless_status(code: Int) -> Bool:
    """Whether a response with this status carries no content: every 1xx, a
    204 and a 304 (RFC 9110 §6.4.1).

    Args:
        code: The response's status code.

    Returns:
        True for 100-199, 204 and 304.
    """
    return (code >= 100 and code < 200) or code == 204 or code == 304


def enforce_bodiless_framing(mut response: HTTPResponse):
    """Strip what a 1xx, 204 or 304 may not carry, whoever set it (SPEC A21).

    RFC 9110 §8.6: a server MUST NOT send `Content-Length` in a 1xx or 204
    response, and in a 304 only as the length the GET would have had -- so
    a 304 keeps a length its handler set and a 1xx or 204 loses one, and
    the same for `Transfer-Encoding` (RFC 9112 §6.1). None
    of the three carries content (§6.4.1), so a body a handler attached
    anyway is dropped and a file body's descriptor closed: written, its
    bytes would be where the connection's next response begins. Django's
    `CommonMiddleware` puts a length on every non-streaming response, a 204
    included, so this is not hypothetical.

    The event loop applies it to every response with such a status before
    the head is encoded; any other status is left as it is.

    Args:
        response: The response about to be written.
    """
    var code = response.status_code
    if not is_bodiless_status(code):
        return
    if code != 304:
        # RFC 9112 §6.1 forbids Transfer-Encoding on a 1xx or 204 as §8.6
        # forbids a length; a 304 keeps both, each describing the GET.
        response.headers.pop(HeaderKey.CONTENT_LENGTH)
        response.headers.pop(HeaderKey.TRANSFER_ENCODING)
    response.body_raw = Bytes()
    if response.body_fd >= 0:
        close_fd(response.body_fd)
        response.body_fd = -1
        response.body_fd_offset = 0
        response.body_fd_len = 0


@fieldwise_init
struct HTTPResponse(Encodable, Movable, Writable):
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

    def __init__(
        out self,
        body_bytes: Span[Byte, _],
        var headers: Headers = Headers(),
        var cookies: ResponseCookieJar = ResponseCookieJar(),
        status_code: Int = 200,
        status_text: String = "OK",
        protocol: String = strHttp11,
        invent_entity_headers: Bool = True,
    ):
        # Move, not copy: the arguments are almost always temporaries built
        # inline at the call site (`Headers(Header(...))`), and copying the
        # whole header blob per response was 2 of the hot path's ~6
        # allocations. A caller that reuses a named Headers still can — a
        # `var` parameter takes an implicit copy of a value that is used
        # again afterwards.
        self.headers = headers^
        self.cookies = cookies^
        # The two entity defaults are for a native handler's body: never
        # for a status that has none (a 1xx, 204 or 304 went out as
        # `content-length: 0` and octet-stream), and never for a head a
        # caller relays as sent -- the gateway passes False (SPEC A21, K12).
        var invent = invent_entity_headers and not is_bodiless_status(status_code)
        if invent and self.headers.known_index(KH_CONTENT_TYPE) < 0:
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
        if self.headers.known_index(KH_CONNECTION) < 0:
            self.set_connection_keep_alive()
        if invent and self.headers.known_index(KH_CONTENT_LENGTH) < 0:
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
        invent_entity_headers: Bool = True,
    ):
        """Initialize with an owned body buffer (zero-copy move)."""
        self.headers = headers^
        self.cookies = cookies^
        # The defaults' rule is the `body_bytes` constructor's, above.
        var invent = invent_entity_headers and not is_bodiless_status(status_code)
        if invent and self.headers.known_index(KH_CONTENT_TYPE) < 0:
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
        if self.headers.known_index(KH_CONNECTION) < 0:
            self.set_connection_keep_alive()
        if invent and self.headers.known_index(KH_CONTENT_LENGTH) < 0:
            self.set_content_length(body_len)
        # No Date header here: encode() adds one at wire-write time if the
        # response still lacks it (and the event loop injects a per-second
        # cached value first). Formatting a date per construction was pure
        # per-request overhead — measured ~9% of hello-world throughput.

    def get_body(self) -> StringSpan[origin_of(self.body_raw)]:
        return StringSpan(unsafe_from_utf8=Span(self.body_raw))

    @always_inline
    def set_connection_close(mut self):
        self.headers.set_known(
            KH_CONNECTION, HeaderKey.CONNECTION.as_bytes(), "close".as_bytes()
        )

    @always_inline
    def set_connection_keep_alive(mut self):
        self.headers.set_known(
            KH_CONNECTION, HeaderKey.CONNECTION.as_bytes(), "keep-alive".as_bytes()
        )

    @always_inline
    def set_content_length(mut self, l: Int):
        self.headers.set_int_known(
            KH_CONTENT_LENGTH, HeaderKey.CONTENT_LENGTH.as_bytes(), l
        )

    def write_to[T: Writer](self, mut writer: T):
        # The status line's rule is `encode`'s, so the text is the wire's.
        writer.write(self.protocol, whitespace, self.status_code, whitespace)
        if not span_breaks_header_line(self.status_text.as_bytes()):
            writer.write(self.status_text)
        writer.write(lineBreak)

        if HeaderKey.SERVER not in self.headers:
            writer.write("server: lightbug_http", lineBreak)

        writer.write(
            self.headers,
            self.cookies,
            lineBreak,
            StringSpan(unsafe_from_utf8=Span(self.body_raw)),
        )

    def encode(deinit self) -> Bytes:
        """Encodes response as bytes.

        This method consumes the data in this request and it should
        no longer be considered valid.

        A reason phrase holding CR, LF or NUL goes out as the empty phrase
        and the code is kept (SPEC G1): the phrase is written verbatim into
        the status line, where a CRLF ends the line and starts a header the
        application never listed. Headers and `Set-Cookie` lines carrying
        one are dropped by their own writers (SPEC G2).
        """
        var writer = ByteWriter()
        writer.write(self.protocol, whitespace, self.status_code, whitespace)
        if not span_breaks_header_line(self.status_text.as_bytes()):
            writer.write(self.status_text)
        writer.write(lineBreak)
        if self.headers.known_index(KH_SERVER) < 0:
            writer.write("server: lightbug_http", lineBreak)
        if self.headers.known_index(KH_DATE) < 0:
            write_header(writer, HeaderKey.DATE, http_date_now())
        self.headers.write_latin1_to(writer)
        self.cookies.write_latin1_to(writer)
        writer.write(lineBreak)
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
        # The head's rules are `encode`'s: an injected reason phrase is
        # emptied, an injected header or `Set-Cookie` line dropped.
        writer.write(self.protocol, whitespace, self.status_code, whitespace)
        if not span_breaks_header_line(self.status_text.as_bytes()):
            writer.write(self.status_text)
        writer.write(lineBreak)
        if self.headers.known_index(KH_SERVER) < 0:
            writer.write("server: lightbug_http", lineBreak)
        if self.headers.known_index(KH_DATE) < 0:
            write_header(writer, HeaderKey.DATE, http_date_now())
        self.headers.write_latin1_to(writer)
        self.cookies.write_latin1_to(writer)
        writer.write(lineBreak)
        writer.consuming_write(self.body_raw^)
        return writer^.consume()
