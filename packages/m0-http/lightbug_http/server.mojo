from lightbug_http.address import NetworkType
from lightbug_http.connection import (
    ConnectionState,
    ListenConfig,
    ListenerError,
    NoTLSListener,
)
from lightbug_http.header import ParsedRequestHeaders
from lightbug_http.io.bytes import Bytes
from lightbug_http.service import HTTPService
from lightbug_http.c.socket import close as close_fd
from lightbug_http.utils.error import CustomError
from std.utils import Variant

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
    def __init__(out self, var value: Error):
        self.value = value^

    def write_to[W: Writer, //](self, mut writer: W):
        if self.value.isa[ListenerError]():
            writer.write(self.value[ListenerError])
        elif self.value.isa[ProvisionError]():
            writer.write(self.value[ProvisionError])
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

    var response_body_len: Int
    """The body bytes that response carries as it goes out -- in memory and
    from `body_fd` alike, none for a HEAD or a bodiless status: the access
    log's `bytes`. Written beside `response_status`, and read only while it
    is set."""

    var response_file_len: Int
    """The part of `response_body_len` sent from `body_fd`, which the
    encoded buffer (`slot_send_offset`) never holds: what the metrics' bytes
    sent add to it."""

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
        self.response_body_len = 0
        self.response_file_len = 0
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
        self.response_body_len = 0
        self.response_file_len = 0
        # encoding_buffer is NOT cleared here — it's already been moved out and replaced.


@fieldwise_init
struct ProvisionPoolExhaustedError(CustomError, ImplicitlyCopyable):
    comptime message = "ProvisionError: Connection provision pool exhausted"

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.message)


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

    def available_count(self) -> Int:
        """Count free slots via popcount across all bitmask words."""
        var count = 0
        for w in range(self.num_words):
            count += Self._popcount64(self.bitmask[w])
        return count

    def size(self) -> Int:
        """Number of currently borrowed (in-use) slots."""
        return self.capacity - self.available_count()


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

    def listen_and_serve[T: HTTPService](mut self, address: StringSpan, mut handler: T) raises ServerError:
        """Listen on `address` and serve it on the event loop.

        `listen_and_serve_nonblocking` with every optional argument at its
        default, so the server's own `shutdown_read_fd` is honoured, SSE and
        WebSocket responses work, and connections are served at once rather
        than in turn. It used to run a blocking accept loop of its own, one
        connection at a time, which answered a stream with 409 and had
        missed fixes the event loop carries; NOTICE records its retirement.

        Parameters:
            T: The type of HTTPService that handles incoming requests.

        Args:
            address: The address (host:port) to listen on.
            handler: An object that handles incoming HTTP requests.

        Raises:
            ServerError: If listener setup fails or an unrecoverable error occurs.
        """
        self.listen_and_serve_nonblocking(address, handler)

    def serve[
        network: NetworkType, //, T: HTTPService
    ](self, var ln: NoTLSListener[network], mut handler: T) raises ServerError:
        """Serve an existing listener on the event loop.

        `serve_nonblocking` with the server's own `shutdown_read_fd`, which
        `listen_and_serve` honours too, and every other optional argument at
        its default. The listener is the loop's from here, as it is there.

        Parameters:
            network: The listener's network, inferred: `tcp` (what
                `ListenConfig.listen` makes unless told otherwise), `tcp4` or
                `tcp6`. The loop reads only its descriptor.
            T: The type of HTTPService that handles incoming requests.

        Args:
            ln: TCP server that listens for incoming connections; the loop
                closes it, so pass it with `^`.
            handler: An object that handles incoming HTTP requests.

        Raises:
            ServerError: If an unrecoverable error occurs.
        """
        self.serve_nonblocking(ln^, handler, self.shutdown_read_fd)

    def listen_and_serve_nonblocking[T: HTTPService](
        mut self, address: StringSpan, mut handler: T,
        shutdown_read_fd: Int = -1,
        bus_read_fd: Int = -1,
        offload_addr: Int = 0,
    ) raises ServerError:
        """Listen and serve on the non-blocking event loop, kqueue or epoll.

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
        var listener: NoTLSListener[NetworkType.tcp]
        try:
            listener = ListenConfig().listen(address)
        except listener_err:
            raise listener_err^

        self.set_address(String(address))

        # Allow caller-supplied fd to override the one stored on self
        var effective_shutdown_fd = shutdown_read_fd if shutdown_read_fd >= 0 else self.shutdown_read_fd

        try:
            self.serve_nonblocking(
                listener^, handler, effective_shutdown_fd, bus_read_fd, offload_addr
            )
        except server_err:
            raise server_err^

    def serve_nonblocking[network: NetworkType, //, T: HTTPService](
        self, var ln: NoTLSListener[network], mut handler: T,
        shutdown_read_fd: Int = -1,
        bus_read_fd: Int = -1,
        offload_addr: Int = 0,
        accept_share: AcceptShare = AcceptShare(),
    ) raises ServerError:
        """Serve HTTP requests on the non-blocking event loop, kqueue or epoll.

        The listener is handed to the loop, which closes it once, as its
        drain begins (review B26). It used to be borrowed, and its owner
        closed the number again after the loop returned -- by then free,
        and often something else's.

        Parameters:
            network: The listener's network, inferred (see `serve`).
            T: The type of HTTPService that handles incoming requests.

        Args:
            ln: TCP server that listens for incoming connections; the loop
                closes it, so pass it with `^`.
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
                ln^.into_fd(),
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
