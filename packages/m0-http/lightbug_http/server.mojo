from lightbug_http.address import NetworkType
from lightbug_http.connection import (
    ConnectionState,
    ListenConfig,
    ListenerError,
    NoTLSListener,
    TCPConnection,
    default_buffer_size,
)
from lightbug_http.header import (
    HeaderKey,
    Headers,
    ParsedRequestHeaders,
    RequestParseError,
    find_header_end,
    parse_request_headers,
)
from lightbug_http.http.common_response import BadRequest, InternalError, URITooLong, RequestTimeout, HeadersTooLarge, PayloadTooLarge, StreamingUnsupported
from lightbug_http.io.bytes import Bytes, ByteView
from lightbug_http.strings import strHttp10
from std.memory import unsafe_memcpy
from lightbug_http.service import HTTPService
from lightbug_http.c.sendfile import send_file
from lightbug_http.c.socket import close as close_fd
from lightbug_http.socket import EOF, FatalCloseError, SocketAcceptError, SocketClosedError, SocketRecvError
from lightbug_http.utils.error import CustomError
from std.time import perf_counter_ns
from std.utils import Variant

from lightbug_http.http import HTTPRequest, HTTPResponse, encode
from lightbug_http.http.chunked import HTTPChunkedDecoder
from lightbug_http.server_config import ServerConfig
from lightbug_http.c.platform import PlatformBackend
from lightbug_http.accept_share import AcceptShare


@fieldwise_init
struct ServerError(Movable, Writable):
    """Error variant for server operations."""

    comptime type = Variant[
        ListenerError,
        ProvisionError,
        SocketAcceptError,
        SocketRecvError,
        FatalCloseError,
        Error,
    ]
    var value: Self.type

    @implicit
    def __init__(out self, var value: ListenerError):
        self.value = value^

    @implicit
    def __init__(out self, var value: ProvisionError):
        self.value = value^

    @implicit
    def __init__(out self, var value: SocketAcceptError):
        self.value = value^

    @implicit
    def __init__(out self, var value: SocketRecvError):
        self.value = value^

    @implicit
    def __init__(out self, var value: FatalCloseError):
        self.value = value^

    @implicit
    def __init__(out self, var value: Error):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[ListenerError]():
            writer.write(self.value[ListenerError])
        elif self.value.isa[ProvisionError]():
            writer.write(self.value[ProvisionError])
        elif self.value.isa[SocketAcceptError]():
            writer.write(self.value[SocketAcceptError])
        elif self.value.isa[SocketRecvError]():
            writer.write(self.value[SocketRecvError])
        elif self.value.isa[FatalCloseError]():
            writer.write(self.value[FatalCloseError])
        elif self.value.isa[Error]():
            writer.write(self.value[Error])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)



# ServerConfig imported from lightbug_http.server_config to break circular
# dependency between server.mojo and event_loop.mojo.


@fieldwise_init
struct BodyReadState(Copyable, ImplicitlyCopyable, Movable):
    """State for body reading phase."""

    var content_length: Int
    """Total expected body length from Content-Length header."""

    var bytes_read: Int
    """Bytes of body read so far."""

    var header_end_offset: Int
    """Offset in recv_buffer where headers end and body begins."""

    var is_chunked: Bool
    """Whether the body uses chunked transfer encoding."""


@fieldwise_init
struct ConnectionProvision(Movable):
    """All resources needed to handle a connection.

    Pre-allocated and reused (pooled) across connections.
    """

    var recv_buffer: Bytes
    """Accumulated receive data."""

    var recv_staging: Bytes
    """Staging buffer for recv syscalls; reused across requests to avoid per-recv allocation."""

    var parsed_headers: Optional[ParsedRequestHeaders]
    """Parsed headers (available after header parsing completes)."""

    var request: Optional[HTTPRequest]
    """Constructed request (available after body is complete)."""

    var response: Optional[HTTPResponse]
    """Response to send."""

    var state: ConnectionState
    """Current state in the connection state machine."""

    var body_state: Optional[BodyReadState]
    """Body reading state (only valid during READING_BODY)."""

    var peer_eof: Bool
    """The client has shut down its write side; no more request bytes exist.

    Not the same as the connection being over — a half-close is how a
    client says "that is the whole request" while still waiting to read the
    response, and answering it is the point. What this flag is for is the
    other half: once it is set, a request that is still INCOMPLETE can
    never be completed, so the slot is released at once instead of being
    held until the header timeout.
    """

    var chunk_decoder: HTTPChunkedDecoder
    """Decoder for a chunked request body, resumed across read events.

    Built with `consume_trailer = True`, which is what makes the body end
    where RFC 9112 §7.1 says it ends: last-chunk, trailer section, CRLF.
    Without it the decoder stopped at `0\r\n` and the terminating `\r\n`
    every conforming client sends was left sitting in the receive buffer —
    and closing a socket with unread data queued makes the kernel send RST
    instead of FIN, which discards the response already written to it. On a
    `Connection: close` request that is a response the client never sees:
    measured at 3-23% of chunked requests locally, rising the more TCP
    segments the body arrived in, and 100% when the client paced its writes.
    Keep-alive hid it because that path never closes the socket.

    One decoder per connection, fed only the bytes that just arrived. It
    used to be constructed fresh inside the read handler, which meant every
    read re-decoded the entire body accumulated so far: K reads of a body of
    size N cost O(N*K) copying and scanning on the EVENT LOOP thread, before
    any offload to a handler pool. Measured on this tree, one connection
    dribbling a chunked body in 1 KB segments: 1 MB took 0.15 s, 2 MB 0.61 s,
    3 MB 1.37 s -- a 4x cost for 2x the bytes, which is an attacker turning
    a few MB/s of upload into a saturated loop.

    Reconstructing it also reset `_total_overhead`, so the decoder's own
    abuse-ratio guard (a body that is mostly chunk framing and little data)
    could never trip. Persisting it fixes both.
    """

    var last_parse_len: Int
    """Length of buffer at last parse attempt (for incremental parsing)."""

    var request_end: Int
    """Where the CURRENT request ends in `recv_buffer`, once known; 0 before.

    Set at dispatch — headers alone for a bodyless request, headers plus
    declared length for Content-Length (known at parse time), headers plus
    decoded size at chunked completion. Bytes past it are the NEXT
    pipelined request, already read off the socket, and
    `prepare_for_new_request(keep_pipelined=True)` preserves them where it
    used to clear them — RFC 9112 §9.3: a server MUST be able to receive
    pipelined requests, and losing the tail was a hang for any client that
    pipelines (no event will ever announce bytes that were consumed with a
    previous request's read).
    """

    var keepalive_count: Int
    """Number of requests handled on this connection."""

    var should_close: Bool
    """Whether to close connection after response."""

    var log_method: String
    """HTTP method for structured access log."""

    var log_path: String
    """Request path for structured access log."""

    var response_status: Int
    """HTTP status code of the last response (for metrics); 0 if not yet set."""

    var encoding_buffer: Bytes
    """Pre-allocated buffer for response encoding; swapped into slot_response to avoid per-request allocation."""

    var body_fd: Int
    """An open file whose bytes are still owed to this connection, or -1.

    Lives on the provision rather than in a loop-side array for one
    reason: closing it must not be forgotten, and the provision is what
    every close path already has in hand. `_close_slot` releases it, so a
    client that vanishes mid-transfer cannot leak the descriptor.

    Set only after the response head is encoded, and the loop sends from
    it once that head has fully landed — the head is bytes and the body is
    not, so they are two transfers and the order between them matters."""

    var body_fd_offset: Int
    """Next byte of `body_fd` to send; advanced by each partial sendfile."""

    var body_fd_remaining: Int
    """Bytes still owed from `body_fd`. Zero with a live fd means done."""

    var peer_host: String
    var peer_port: Int
    """The accepted peer, written once per connection at accept and stamped
    onto every request this slot parses (keep-alive included). Feeds WSGI's
    `REMOTE_ADDR` and ASGI's `scope["client"]`; empty/0 outside the
    non-blocking loop."""

    def __init__(out self, config: ServerConfig):
        # Empty, not `capacity=socket_buffer_size`: see `ensure_buffers`.
        self.recv_buffer = Bytes()
        self.recv_staging = Bytes()
        self.parsed_headers = None
        self.request = None
        self.response = None
        self.state = ConnectionState.reading_headers()
        self.body_state = None
        self.peer_eof = False
        self.chunk_decoder = HTTPChunkedDecoder()
        self.chunk_decoder.consume_trailer = True
        self.last_parse_len = 0
        self.request_end = 0
        self.keepalive_count = 0
        self.should_close = False
        self.log_method = String()
        self.log_path = String()
        self.response_status = 0
        self.encoding_buffer = Bytes()
        self.body_fd = -1
        self.body_fd_offset = 0
        self.body_fd_remaining = 0
        self.peer_host = String("")
        self.peer_port = 0

    def close_body_fd(mut self):
        """Release any file this connection was still sending. Idempotent.

        Every path that abandons a response goes through here — completion,
        client disconnect, HEAD stripping — so the descriptor has exactly
        one owner and one release.
        """
        if self.body_fd >= 0:
            try:
                close_fd(FileDescriptor(self.body_fd))
            except:
                pass
            self.body_fd = -1
        self.body_fd_offset = 0
        self.body_fd_remaining = 0

    def ensure_buffers(mut self, size: Int):
        """Size this connection's buffers, once, the first time it is used.

        The pool builds every provision up front — `max_connections` of them,
        1024 by default — so sizing the buffers in `__init__` meant a server
        allocated for its worst case before accepting anything. Three buffers
        at `socket_buffer_size` each is ~12 KB per provision, and it is
        resident, not merely reserved: measured at 26.4 MB RSS at startup
        against 13.4 MB with a 64-slot pool, and it multiplies per worker
        (26 / 45 / 78 MB at 1 / 2 / 4 workers).

        Sizing here instead makes the cost track the concurrency actually
        reached. Provisions are never reconstructed — `release` only clears a
        bit — so a slot keeps its buffers once it has been used, and the peak
        is the high-water mark of concurrent connections rather than the
        configured ceiling. A server that never sees more than 20 at once
        pays for 20.

        `recv_staging`'s capacity is load-bearing rather than an
        optimization: the read path passes `capacity()` as the recv size and
        then sets `_len` from the result, so a zero-capacity buffer would
        read nothing at all. Hence one place that guarantees the sizing,
        called before a slot is handed out.
        """
        if self.recv_staging.capacity() > 0:
            return
        self.recv_buffer.reserve(size)
        self.recv_staging.reserve(size)
        self.encoding_buffer.reserve(size)

    def prepare_for_new_request(mut self, keep_pipelined: Bool = False):
        """Reset provision for next request in keepalive connection.

        `keep_pipelined=True` — passed ONLY by the keep-alive resets, after
        a response has gone out — keeps any bytes past `request_end`: they
        are the next pipelined request, and the recv that took them off the
        socket consumed the only readiness event they will ever get.
        Everywhere else (accept, close) the buffer clears whole, so a tail
        left behind by one client can never leak into another connection's
        first request.
        """
        self.parsed_headers = None
        self.request = None
        self.response = None
        if (
            keep_pipelined
            and self.request_end > 0
            and self.request_end < len(self.recv_buffer)
        ):
            var tail = Bytes(Span(self.recv_buffer)[self.request_end :])
            self.recv_buffer = tail^
        else:
            self.recv_buffer.clear()
        self.recv_staging.clear()
        self.state = ConnectionState.reading_headers()
        self.body_state = None
        self.peer_eof = False
        self.chunk_decoder = HTTPChunkedDecoder()
        self.chunk_decoder.consume_trailer = True
        self.last_parse_len = 0
        self.request_end = 0
        self.should_close = False
        self.log_method = String()
        self.log_path = String()
        self.response_status = 0
        # encoding_buffer is NOT cleared here — it's already been moved out and replaced.


@fieldwise_init
struct ProvisionPoolExhaustedError(CustomError, ImplicitlyCopyable):
    comptime message = "ProvisionError: Connection provision pool exhausted"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.message)

    def __str__(self) -> String:
        return String(self)


@fieldwise_init
struct ProvisionError(Movable, Writable):
    """Error variant for provision pool operations."""

    comptime type = Variant[ProvisionPoolExhaustedError]
    var value: Self.type

    @implicit
    def __init__(out self, value: ProvisionPoolExhaustedError):
        self.value = value

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.value[ProvisionPoolExhaustedError])

    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    def __getitem__[T: AnyType](self) -> ref [origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    def __str__(self) -> String:
        return String(self)


struct ProvisionPool(Movable):
    """Pool of ConnectionProvision objects with bitmask slab allocator.

    Uses UInt64 bitmask words for O(1) borrow/release via countl_zero.
    Bit=1 means free, bit=0 means in-use. MSB-first ordering.
    """

    var provisions: List[ConnectionProvision]
    var bitmask: List[UInt64]
    var num_words: Int
    var capacity: Int
    var buffer_size: Int
    """Size each provision's buffers are given on first use."""

    def __init__(out self, capacity: Int, config: ServerConfig):
        self.provisions = List[ConnectionProvision](capacity=capacity)
        self.capacity = capacity
        self.buffer_size = config.socket_buffer_size
        self.num_words = (capacity + 63) // 64

        # Initialize bitmask: all bits=1 (free)
        self.bitmask = List[UInt64](capacity=self.num_words)
        for _ in range(self.num_words):
            self.bitmask.append(~UInt64(0))

        # Mask off invalid bits in last word (bits beyond capacity)
        var remainder = capacity % 64
        if remainder != 0:
            # Keep only the top `remainder` bits set
            self.bitmask[self.num_words - 1] = ~UInt64(0) << UInt64(64 - remainder)

        for _ in range(capacity):
            self.provisions.append(ConnectionProvision(config))

    @staticmethod
    def _clz64(val: UInt64) -> Int:
        """Count leading zeros without importing bit module (avoids codegen bug)."""
        if val == 0:
            return 64
        var n = 0
        var v = val
        if v & UInt64(0xFFFFFFFF00000000) == 0:
            n += 32
            v <<= 32
        if v & UInt64(0xFFFF000000000000) == 0:
            n += 16
            v <<= 16
        if v & UInt64(0xFF00000000000000) == 0:
            n += 8
            v <<= 8
        if v & UInt64(0xF000000000000000) == 0:
            n += 4
            v <<= 4
        if v & UInt64(0xC000000000000000) == 0:
            n += 2
            v <<= 2
        if v & UInt64(0x8000000000000000) == 0:
            n += 1
        return n

    @staticmethod
    def _popcount64(val: UInt64) -> Int:
        """Hamming weight without importing bit module (avoids codegen bug)."""
        var v = val
        v = v - ((v >> 1) & UInt64(0x5555555555555555))
        v = (v & UInt64(0x3333333333333333)) + ((v >> 2) & UInt64(0x3333333333333333))
        v = (v + (v >> 4)) & UInt64(0x0F0F0F0F0F0F0F0F)
        return Int((v * UInt64(0x0101010101010101)) >> 56)

    def borrow(mut self) raises ProvisionError -> Int:
        """Allocate a slot. O(1) via leading-zero count on bitmask words."""
        for w in range(self.num_words):
            var word = self.bitmask[w]
            if word != 0:
                var bit_pos = Self._clz64(word)
                # Clear bit (mark in-use)
                self.bitmask[w] = word & ~(UInt64(1) << UInt64(63 - bit_pos))
                var index = w * 64 + bit_pos
                # First use of this slot sizes its buffers; a no-op after that.
                self.provisions[index].ensure_buffers(self.buffer_size)
                return index
        raise ProvisionPoolExhaustedError()

    def release(mut self, index: Int):
        """Release a slot. O(1) bit set."""
        var w = index // 64
        var bit_pos = index % 64
        self.bitmask[w] |= UInt64(1) << UInt64(63 - bit_pos)

    def get_ptr(mut self, index: Int) -> Pointer[ConnectionProvision, origin_of(self.provisions)]:
        return Pointer(to=self.provisions[index])

    def available_count(self) -> Int:
        """Count free slots via popcount across all bitmask words."""
        var count = 0
        for w in range(self.num_words):
            count += Self._popcount64(self.bitmask[w])
        return count

    def size(self) -> Int:
        """Number of currently borrowed (in-use) slots."""
        return self.capacity - self.available_count()


def gate_streaming_response(var response: HTTPResponse) -> HTTPResponse:
    """Refuse a response the blocking loop cannot honour, else pass it through.

    Two shapes qualify. An `sse_streaming` response asks the loop to keep
    the connection open and drain a registry outbox; a `101` asks it to
    switch the socket to WebSocket frame mode. Both are event-loop
    machinery (`listen_and_serve_nonblocking`), and the blocking loop
    honouring neither used to be SILENT: the stream went out as a one-shot
    body and the 101 as a plain response on a socket that then stayed in
    HTTP mode. The comments in two apps and CLAUDE.md always claimed "the
    plain accept loop answers every stream open with 409" -- but that 409
    lived only inside DatastarStream.open, so apps on the lower-level
    `sse_response()` + `SSERegistry` path got the silent version (#118).
    This makes the claim true where it was always said to be true.
    """
    if response.sse_streaming or response.status_code == 101:
        return StreamingUnsupported()
    return response^


def handle_connection[
    T: HTTPService
](
    mut conn: TCPConnection[NetworkType.tcp4],
    mut provision: ConnectionProvision,
    mut handler: T,
    config: ServerConfig,
    server_address: String,
    tcp_keep_alive: Bool,
) raises SocketRecvError:
    """Handle a single HTTP connection through its lifecycle.

    Args:
        conn: The TCP connection to handle.
        provision: Pre-allocated resources for this connection.
        handler: The HTTP service handler.
        config: Server configuration.
        server_address: The server's address string.
        tcp_keep_alive: Whether to enable TCP keep-alive.

    Raises:
        SocketRecvError: If a socket read operation fails (not including clean EOF/close).
    """
    # Set initial header read timeout
    if config.header_read_timeout > 0:
        try:
            conn.set_recv_timeout(config.header_read_timeout)
        except:
            return  # Cannot protect this connection without a timeout

    var header_start_ns = perf_counter_ns()

    while True:
        if provision.state.kind == ConnectionState.READING_HEADERS:
            # Wall-clock deadline for total header parsing (slowloris protection)
            if config.header_read_timeout > 0:
                var elapsed_s = (perf_counter_ns() - header_start_ns) / 1_000_000_000
                if elapsed_s >= Int(config.header_read_timeout):
                    _send_error_response(conn, RequestTimeout())
                    provision.state = ConnectionState.closed()
                    break

            # Bytes the keep-alive reset preserved are parsed BEFORE
            # blocking on the socket: the client already sent them and is
            # waiting on their responses, so a blocking read here would sit
            # out the idle timeout for data that is never coming.
            if len(provision.recv_buffer) <= provision.last_parse_len:
                var buffer = Bytes(capacity=config.socket_buffer_size)
                var bytes_read: UInt

                try:
                    bytes_read = conn.read(buffer)
                except read_err:
                    if read_err.isa[EOF]():
                        provision.state = ConnectionState.closed()
                        break
                    # On keep-alive connections, treat timeout (EAGAIN) as clean close
                    # so the server can accept new connections.
                    if provision.keepalive_count > 0:
                        provision.state = ConnectionState.closed()
                        break
                    # First request timeout: send 408 Request Timeout
                    if config.header_read_timeout > 0:
                        _send_error_response(conn, RequestTimeout())
                        provision.state = ConnectionState.closed()
                        break
                    raise read_err^

                if bytes_read == 0:
                    provision.state = ConnectionState.closed()
                    break

                provision.recv_buffer.extend(buffer^)

            if len(provision.recv_buffer) > config.recv_buffer_limit():
                _send_error_response(conn, BadRequest())
                provision.state = ConnectionState.closed()
                break

            var search_start = provision.last_parse_len
            if search_start > 3:
                search_start -= 3  # Account for partial \r\n\r\n match

            var header_end = find_header_end(
                Span(provision.recv_buffer),
                search_start,
            )

            if header_end:
                var header_end_offset = header_end.value()

                # Check total header size
                if header_end_offset > config.max_total_header_size:
                    _send_error_response(conn, HeadersTooLarge())
                    provision.state = ConnectionState.closed()
                    break

                var parsed: ParsedRequestHeaders
                try:
                    parsed = parse_request_headers(
                        Span(provision.recv_buffer)[:header_end_offset],
                        provision.last_parse_len,
                    )
                except parse_err:
                    _send_error_response(conn, BadRequest())
                    provision.state = ConnectionState.closed()
                    break

                if parsed.path.byte_length() > config.max_request_uri_length:
                    _send_error_response(conn, URITooLong())
                    provision.state = ConnectionState.closed()
                    break

                var content_length = parsed.content_length()
                var is_chunked = parsed.is_chunked_body()

                if not is_chunked and content_length > config.max_request_body_size:
                    _send_error_response(conn, PayloadTooLarge())
                    provision.state = ConnectionState.closed()
                    break

                var body_bytes_in_buffer = len(provision.recv_buffer) - header_end_offset

                provision.parsed_headers = parsed^

                if content_length > 0 or is_chunked:
                    # Switch to body read timeout
                    if config.body_read_timeout > 0:
                        try:
                            conn.set_recv_timeout(config.body_read_timeout)
                        except:
                            _send_error_response(conn, InternalError())
                            provision.state = ConnectionState.closed()
                            break
                    # RFC 9110 §10.1.1: send 100 Continue before reading the
                    # body. Case-INSENSITIVE on the expectation-name, and
                    # never to an HTTP/1.0 client, which has no 1xx and would
                    # read the interim response as the real one. The event
                    # loop carries the same two rules; a rule in one copy and
                    # not the other is not a rule.
                    if provision.parsed_headers.value().headers.value_equals_ignore_case(
                        HeaderKey.EXPECT, "100-continue"
                    ) and provision.parsed_headers.value().protocol != strHttp10:
                        try:
                            _ = conn.write("HTTP/1.1 100 Continue\r\n\r\n".as_bytes())
                        except:
                            provision.state = ConnectionState.closed()
                            break

                    var effective_length = config.max_request_body_size if is_chunked else content_length
                    # `bytes_read` counts DECODED bytes for a chunked body,
                    # and nothing has been decoded yet — the bytes already
                    # buffered are still raw. Same rule as the loop's branch.
                    provision.body_state = BodyReadState(
                        content_length=effective_length,
                        bytes_read=0 if is_chunked else body_bytes_in_buffer,
                        header_end_offset=header_end_offset,
                        is_chunked=is_chunked,
                    )
                    # Where this request will end. Chunked cannot know yet
                    # (0 = whole buffer); the completion below stamps it.
                    provision.request_end = (
                        0 if is_chunked else header_end_offset + content_length
                    )
                    provision.state = ConnectionState.reading_body(effective_length)
                else:
                    provision.request_end = header_end_offset
                    provision.state = ConnectionState.processing()

            provision.last_parse_len = len(provision.recv_buffer)

        elif provision.state.kind == ConnectionState.READING_BODY:
            var body_st = provision.body_state.value()

            if body_st.is_chunked:
                # Phase 1b: resume the CONNECTION's decoder over the bytes
                # that have not been decoded yet — the same shape as the
                # non-blocking loop's branch, and for the same two reasons.
                # Rebuilding a decoder here and re-decoding the whole body
                # each pass was O(N^2) in the number of reads, and it
                # disagreed with the loop about where a chunked body ends
                # (`consume_trailer`), which is the difference between a
                # clean close and an RST that discards the response.
                var raw_body_start = body_st.header_end_offset
                var decoded_so_far = body_st.bytes_read
                var tail_start = raw_body_start + decoded_so_far
                var buf_len = len(provision.recv_buffer)
                # Decoded size and raw size are bounded separately; see the
                # matching check in `event_loop.mojo`.
                if (
                    buf_len - raw_body_start > config.max_request_body_size
                    or provision.chunk_decoder._total_read
                    > 2 * config.max_request_body_size
                ):
                    _send_error_response(conn, PayloadTooLarge())
                    provision.state = ConnectionState.closed()
                    break
                if buf_len > tail_start:
                    var ret: Int
                    var produced: Int
                    ret, produced = provision.chunk_decoder.decode(
                        Span(provision.recv_buffer)[tail_start:]
                    )
                    if ret == -1:
                        _send_error_response(conn, BadRequest())
                        provision.state = ConnectionState.closed()
                        break
                    var leftover = provision.chunk_decoder.pending_bytes
                    provision.recv_buffer.resize(
                        tail_start + produced + leftover, 0
                    )
                    decoded_so_far += produced
                    body_st.bytes_read = decoded_so_far
                    provision.body_state = body_st
                    if ret >= 0:
                        # `pending_bytes` bytes remain past the chunked
                        # data — the next pipelined request. The buffer was
                        # already resized to keep exactly them above; the
                        # resize that used to discard them here is why a
                        # pipelined request behind a chunked body was lost.
                        provision.request_end = raw_body_start + decoded_so_far
                        body_st.content_length = decoded_so_far
                        body_st.bytes_read = decoded_so_far
                        body_st.is_chunked = False
                        provision.body_state = body_st
                        provision.state = ConnectionState.processing()
                        continue
                    # ret == -2: incomplete, fall through to recv more
            else:
                if body_st.bytes_read >= body_st.content_length:
                    provision.state = ConnectionState.processing()
                    continue

            var buffer = Bytes(capacity=config.socket_buffer_size)
            var bytes_read: UInt

            try:
                bytes_read = conn.read(buffer)
            except read_err:
                if read_err.isa[EOF]():
                    provision.state = ConnectionState.closed()
                    break
                raise read_err^

            if bytes_read == 0:
                provision.state = ConnectionState.closed()
                break

            provision.recv_buffer.extend(buffer^)

            if not body_st.is_chunked:
                body_st.bytes_read += Int(bytes_read)
                provision.body_state = body_st

            if len(provision.recv_buffer) > config.recv_buffer_limit():
                _send_error_response(conn, BadRequest())
                provision.state = ConnectionState.closed()
                break

            if not body_st.is_chunked and body_st.bytes_read >= body_st.content_length:
                provision.state = ConnectionState.processing()

        elif provision.state.kind == ConnectionState.PROCESSING:
            var parsed = provision.parsed_headers.take()

            var body = Bytes()
            if provision.body_state:
                var body_st = provision.body_state.value()
                var body_start = body_st.header_end_offset
                var body_end = body_start + body_st.content_length

                if body_end <= len(provision.recv_buffer):
                    body = Bytes(capacity=body_st.content_length)
                    unsafe_memcpy(
                        dest=body.unsafe_ptr(),
                        src=provision.recv_buffer.unsafe_ptr().unsafe_offset(body_start),
                        count=body_st.content_length,
                    )
                    body._len = body_st.content_length

            var request: HTTPRequest
            try:
                request = HTTPRequest.from_parsed(
                    server_address,
                    parsed^,
                    body^,
                    config.max_request_uri_length,
                )
            except build_err:
                _send_error_response(conn, BadRequest())
                provision.state = ConnectionState.closed()
                break

            provision.should_close = (not tcp_keep_alive) or request.connection_close()
            var request_method = request.method
            var request_path = request.uri.path

            var response: HTTPResponse
            # Before hook: short-circuit if it returns a response
            var early = handler.before_request(request)
            if early:
                var early_resp = early.take()
                response = early_resp^
            else:
                try:
                    response = handler.func(request^)
                except handler_err:
                    response = InternalError()
                    provision.should_close = True

            # A held stream or an upgrade cannot work here -- see
            # `gate_streaming_response`. Gated before the after hook so the
            # 409 is what gets logged, because it is what goes on the wire.
            response = gate_streaming_response(response^)

            # After hook: add headers, log, etc.
            handler.after_response(request_method, request_path, response)

            if (not provision.should_close) and (config.max_keepalive_requests > 0):
                if (provision.keepalive_count + 1) >= config.max_keepalive_requests:
                    provision.should_close = True

            # RFC 9110 §9.3.2: HEAD response must not contain a body. An
            # fd-backed body is dropped by closing the file; the headers,
            # Content-Length included, still describe what a GET returns.
            if request_method == "HEAD":
                response.body_raw = Bytes()
                if response.body_fd >= 0:
                    try:
                        close_fd(FileDescriptor(response.body_fd))
                    except:
                        pass
                    response.body_fd = -1
                    response.body_fd_len = 0

            # No `Keep-Alive: timeout=..., max=...` header, deliberately, and
            # the event loop -- the path every shipped binary runs -- has
            # never sent one. It is not in RFC 9110 or 9112 (RFC 2068 §19.7.1
            # described it and RFC 2616 dropped it), browsers ignore it, and
            # this loop emitted it where nothing could read it: nothing in
            # this tree calls `listen_and_serve`, and no test asserted the
            # header. The value was also wrong -- `max` is the number of
            # ADDITIONAL requests, and `keepalive_count` is not incremented
            # until after the response is built, so request 99 of 100
            # advertised `max=2` and served one more.
            #
            # Emitting it from the event loop instead would put a header
            # nobody reads on every keep-alive response of the hot path. If a
            # client pool ever needs `timeout=` to avoid racing the idle
            # close, that is the place to add it, with a row and a gate.
            if provision.should_close:
                response.set_connection_close()
            else:
                response.set_connection_keep_alive()

            provision.response = response^
            provision.state = ConnectionState.responding()

        elif provision.state.kind == ConnectionState.RESPONDING:
            var response = provision.response.take()

            # The file body, taken before `encode` consumes the response.
            # This loop is blocking, so the transfer is a plain loop over
            # `sendfile` rather than the event loop's readiness dance —
            # but it has to exist, or an fd-backed response would go out
            # as headers promising a body that never arrives.
            var body_fd = response.body_fd
            var body_off = response.body_fd_offset
            var body_rem = response.body_fd_len
            response.body_fd = -1

            try:
                _ = conn.write(encode(response^))
            except write_err:
                if body_fd >= 0:
                    try:
                        close_fd(FileDescriptor(body_fd))
                    except:
                        pass
                provision.state = ConnectionState.closed()
                break

            if body_fd >= 0:
                var send_failed = False
                while body_rem > 0:
                    var r = send_file(
                        conn.socket.fd.value, body_fd, body_off, body_rem
                    )
                    body_off += r.sent
                    body_rem -= r.sent
                    if r.failed():
                        send_failed = True
                        break
                    if r.sent == 0 and not r.again:
                        send_failed = True
                        break
                try:
                    close_fd(FileDescriptor(body_fd))
                except:
                    pass
                if send_failed:
                    provision.state = ConnectionState.closed()
                    break

            if provision.should_close:
                provision.state = ConnectionState.closed()
                break

            if (config.max_keepalive_requests > 0) and (provision.keepalive_count >= config.max_keepalive_requests):
                provision.state = ConnectionState.closed()
                break

            provision.keepalive_count += 1
            provision.prepare_for_new_request(keep_pipelined=True)
            header_start_ns = perf_counter_ns()
            # Switch to idle timeout for next request on keep-alive
            if config.idle_timeout > 0:
                try:
                    conn.set_recv_timeout(config.idle_timeout)
                except:
                    provision.state = ConnectionState.closed()
                    break

        else:
            break


struct Server(Movable):
    """HTTP/1.1 Server implementation."""

    var config: ServerConfig
    var _address: String
    var tcp_keep_alive: Bool
    var shutdown_read_fd: Int
    """Read end of a self-pipe for graceful shutdown (-1 = disabled).

    Set via create_shutdown_pipe() and pass the read_fd here, or use the
    shutdown_read_fd keyword argument on listen_and_serve_nonblocking().
    When the write end is closed (ShutdownHandle.signal()), the event loop
    detects EV_EOF on this fd and exits cleanly.
    """

    def __init__(
        out self,
        var address: String = "127.0.0.1",
        tcp_keep_alive: Bool = True,
        shutdown_read_fd: Int = -1,
    ):
        self.config = ServerConfig()
        self._address = address^
        self.tcp_keep_alive = tcp_keep_alive
        self.shutdown_read_fd = shutdown_read_fd

    def __init__(
        out self,
        var config: ServerConfig,
        var address: String = "127.0.0.1",
        tcp_keep_alive: Bool = True,
        shutdown_read_fd: Int = -1,
    ):
        self.config = config^
        self._address = address^
        self.tcp_keep_alive = tcp_keep_alive
        self.shutdown_read_fd = shutdown_read_fd

    def address(self) -> ref [self._address] String:
        return self._address

    def set_address(mut self, var own_address: String):
        self._address = own_address^

    def max_request_body_size(self) -> Int:
        return self.config.max_request_body_size

    def set_max_request_body_size(mut self, size: Int):
        self.config.max_request_body_size = size

    def max_request_uri_length(self) -> Int:
        return self.config.max_request_uri_length

    def set_max_request_uri_length(mut self, length: Int):
        self.config.max_request_uri_length = length

    def listen_and_serve[T: HTTPService](mut self, address: StringSlice, mut handler: T) raises ServerError:
        """Listen for incoming connections and serve HTTP requests.

        Parameters:
            T: The type of HTTPService that handles incoming requests.

        Args:
            address: The address (host:port) to listen on.
            handler: An object that handles incoming HTTP requests.

        Raises:
            ServerError: If listener setup fails or serving encounters fatal errors.
        """
        var listener: NoTLSListener[NetworkType.tcp4]
        try:
            listener = ListenConfig().listen(address)
        except listener_err:
            raise listener_err^

        self.set_address(String(address))

        try:
            self.serve(listener, handler)
        except server_err:
            raise server_err^

    def serve[T: HTTPService](self, ln: NoTLSListener[NetworkType.tcp4], mut handler: T) raises ServerError:
        """Serve HTTP requests from an existing listener.

        Parameters:
            T: The type of HTTPService that handles incoming requests.

        Args:
            ln: TCP server that listens for incoming connections.
            handler: An object that handles incoming HTTP requests.

        Raises:
            ServerError: If accept fails or critical connection handling errors occur.
        """
        var provision_pool = ProvisionPool(self.config.max_connections, self.config)

        while True:
            var conn: TCPConnection[NetworkType.tcp4]
            try:
                conn = ln.accept()
            except listener_err:
                raise listener_err^

            var index: Int
            try:
                index = provision_pool.borrow()
            except provision_err:
                # Pool exhausted - close the connection and continue
                try:
                    conn^.teardown()
                except:
                    pass
                continue

            try:
                handle_connection(
                    conn,
                    provision_pool.provisions[index],
                    handler,
                    self.config,
                    self.address(),
                    self.tcp_keep_alive,
                )
            except socket_err:
                # Connection handling failed - just close the connection
                pass
            finally:
                try:
                    conn^.teardown()
                except:
                    pass
                provision_pool.provisions[index].prepare_for_new_request()
                provision_pool.provisions[index].keepalive_count = 0
                provision_pool.release(index)


    def listen_and_serve_nonblocking[T: HTTPService](
        mut self, address: StringSlice, mut handler: T,
        shutdown_read_fd: Int = -1,
        bus_read_fd: Int = -1,
        offload_addr: Int = 0,
    ) raises ServerError:
        """Listen and serve using the non-blocking kqueue event loop.

        Parameters:
            T: The type of HTTPService that handles incoming requests.

        Args:
            address: The address (host:port) to listen on.
            handler: An object that handles incoming HTTP requests.
            shutdown_read_fd: Read end of the graceful-shutdown pipe, or -1.
            bus_read_fd: This worker's `BroadcastBus` channel, or -1.
            offload_addr: A caller-owned `OffloadPool`'s address, or 0.
                Non-zero makes the loop an acceptor: it parks each request and
                submits the slot instead of calling `handler.func` itself, and
                the pool's threads answer. `m0serve` passed this to
                `run_event_loop` directly because it needed a `DetachingBackend`
                for the GIL; a Mojo handler needs no such thing, so the plain
                entry point carries it. See `m0_http.mojo_pool`.

        Raises:
            ServerError: If listener setup fails or an unrecoverable error occurs.
        """
        var listener: NoTLSListener[NetworkType.tcp4]
        try:
            listener = ListenConfig().listen(address)
        except listener_err:
            raise listener_err^

        self.set_address(String(address))

        # Allow caller-supplied fd to override the one stored on self
        var effective_shutdown_fd = shutdown_read_fd if shutdown_read_fd >= 0 else self.shutdown_read_fd

        try:
            self.serve_nonblocking(
                listener, handler, effective_shutdown_fd, bus_read_fd, offload_addr
            )
        except server_err:
            raise server_err^

    def serve_nonblocking[T: HTTPService](
        self, ln: NoTLSListener[NetworkType.tcp4], mut handler: T,
        shutdown_read_fd: Int = -1,
        bus_read_fd: Int = -1,
        offload_addr: Int = 0,
        accept_share: AcceptShare = AcceptShare(),
    ) raises ServerError:
        """Serve HTTP requests using the non-blocking kqueue event loop.

        Parameters:
            T: The type of HTTPService that handles incoming requests.

        Args:
            ln: TCP server that listens for incoming connections.
            handler: An object that handles incoming HTTP requests.

            shutdown_read_fd: Read end of the graceful-shutdown pipe, or -1.
            bus_read_fd: This worker's `BroadcastBus` channel, or -1.
            offload_addr: A caller-owned `OffloadPool`'s address, or 0. See
                `listen_and_serve_nonblocking`.
            accept_share: This worker's `AcceptShare` under `--workers N`;
                the inactive default otherwise.

        Raises:
            ServerError: If an unrecoverable error occurs.
        """
        from lightbug_http.event_loop import run_event_loop

        try:
            var backend = PlatformBackend()
            run_event_loop(
                ln.socket.fd,
                handler,
                backend,
                self.config,
                self.address(),
                self.tcp_keep_alive,
                shutdown_read_fd,
                bus_read_fd,
                offload_addr,
                accept_share=accept_share,
            )
        except e:
            raise e^


def _send_error_response(mut conn: TCPConnection[NetworkType.tcp4], var response: HTTPResponse):
    """Helper to send an error response, ignoring write errors."""
    try:
        _ = conn.write(encode(response^))
    except:
        pass  # Ignore write errors for error responses
