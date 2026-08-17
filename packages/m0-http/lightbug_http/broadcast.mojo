"""Cross-worker SSE broadcast bus.

`M0_WORKERS>1` forks, and each worker's SSE registry only reaches the
connections that worker accepted. This bus is what carries a broadcast to the
*other* workers: one datagram channel per worker, created before the fork so
every process inherits every descriptor. A worker that broadcasts writes one
datagram to each peer's channel; each worker's event loop watches its own
channel and hands received frames to the handler through `sse_peer_frame`.

Why SOCK_DGRAM socketpairs and not pipes: datagrams preserve message
boundaries, so concurrent writers on one channel can never interleave bytes
mid-frame — a pipe only guarantees that up to PIPE_BUF, and a rendered HTML
fragment clears 4KB easily. Delivery is fire-and-forget on a full buffer
(non-blocking send, drop on EAGAIN), the same policy the registry applies to
a slot past MAX_PENDING_BYTES: a stalled peer loses frames rather than
stalling the broadcaster.

Wire format, one datagram per frame:

    [event_id: 8 bytes little-endian][url_len: 2 bytes LE][url][frame bytes]

The frame bytes are the complete SSE frame, verbatim — the receiving worker
queues them with `notify_frame` exactly as if it had broadcast them itself.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory import alloc
from std.sys.info import CompilationTarget

from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.socket import (
    send, recv, setsockopt, SocketOption, SOL_SOCKET,
)

# Per-call non-blocking I/O. `set_nonblocking` was a silent no-op on ARM64
# macOS until `_fcntl` learned the Darwin variadic convention (see
# c/kqueue.mojo) — a blocking recv() inside the drain loop wedged the event
# loop until the next datagram arrived. O_NONBLOCK works now, but the
# per-call flag stays: it makes each recv/send non-blocking by construction
# rather than by fd state, and it costs nothing.
comptime _MSG_DONTWAIT = c_int(0x80) if CompilationTarget.is_macos() else c_int(0x40)

# One frame per datagram, so the socket buffers bound the largest broadcast
# that can cross workers. 64KB matches the registry's MAX_PENDING_BYTES: a
# frame too big for this bus is also too big for any subscriber's pending
# buffer, so nothing deliverable is ever dropped here.
comptime BUS_MAX_FRAME = 65536
comptime _BUS_HEADER = 10  # 8-byte event id + 2-byte url length
comptime _BUS_SOCKET_BUF = 262144

comptime _AF_UNIX = 1
comptime _SOCK_DGRAM = 2


def _socketpair() raises -> Tuple[Int, Int]:
    """One SOCK_DGRAM AF_UNIX pair. Returns (receive end, send end)."""
    # NOTE: `alloc` without a Layout is deprecated — same story as c/pipe.mojo:
    # the Layout form returns a non-subscriptable Allocation and `unsafe_alloc`
    # does not exist in Mojo 1.0.
    var fds = alloc[c_int](count=2)
    var rc = external_call[
        "socketpair", c_int, c_int, c_int, c_int, type_of(fds)
    ](c_int(_AF_UNIX), c_int(_SOCK_DGRAM), c_int(0), fds)
    if rc != 0:
        var errno = get_errno()
        fds.unsafe_free()
        raise Error("socketpair() failed, errno: ", errno)
    var read_end = Int(fds[unsafe_offset=0])
    var write_end = Int(fds[unsafe_offset=1])
    fds.unsafe_free()
    return (read_end, write_end)


struct BroadcastBus(Copyable, Movable):
    """One receive channel per worker, every worker holding every send end.

    Create **before** `fork_all()` so the descriptors are inherited; the fds
    are plain ints, so copying the bus into per-worker state is free. Worker
    `i` passes `read_fd(i)` to the server (the event loop drains it) and
    publishes with `publish(i, ...)`, which skips its own channel — the local
    registry already queued the frame directly.
    """

    var read_fds: List[Int]
    var write_fds: List[Int]

    def __init__(out self, num_workers: Int) raises:
        """Create channels for `num_workers` workers, pre-fork."""
        self.read_fds = List[Int]()
        self.write_fds = List[Int]()
        for _ in range(num_workers):
            var pair = _socketpair()
            # Belt (O_NONBLOCK on the fds) and braces (MSG_DONTWAIT on
            # every send/recv): either alone suffices now that fcntl works
            # on ARM64 macOS, and both together survive either regressing.
            set_nonblocking(FileDescriptor(pair[0]))
            set_nonblocking(FileDescriptor(pair[1]))
            # Default UNIX dgram buffers are far too small for a 64KB frame
            # (2KB on macOS). Sized to hold a few max-size frames.
            setsockopt(
                FileDescriptor(pair[1]), Int32(SOL_SOCKET),
                SocketOption.SO_SNDBUF.value, Int32(_BUS_SOCKET_BUF),
            )
            setsockopt(
                FileDescriptor(pair[0]), Int32(SOL_SOCKET),
                SocketOption.SO_RCVBUF.value, Int32(_BUS_SOCKET_BUF),
            )
            self.read_fds.append(pair[0])
            self.write_fds.append(pair[1])

    def __init__(out self, *, copy: Self):
        self.read_fds = copy.read_fds.copy()
        self.write_fds = copy.write_fds.copy()

    def __init__(out self, *, deinit move: Self):
        self.read_fds = move.read_fds^
        self.write_fds = move.write_fds^

    def size(self) -> Int:
        return len(self.read_fds)

    def read_fd(self, worker: Int) -> Int:
        """The channel worker `worker` drains — pass to the server."""
        if worker < 0 or worker >= len(self.read_fds):
            return -1
        return self.read_fds[worker]

    def publish(self, from_worker: Int, url: String, event_id: Int, frame: Span[Byte, _]):
        """Send one frame to every worker except `from_worker`."""
        publish_to_channels(self.write_fds, from_worker, url, event_id, frame)


def publish_to_channels(
    write_fds: List[Int], skip_worker: Int,
    url: String, event_id: Int, frame: Span[Byte, _],
):
    """Send one frame to every channel except `skip_worker`'s.

    The free-function form exists so a consumer can hold just the write fds
    (plain ints) instead of the whole bus — `DatastarStream` does, keeping
    its constructor non-raising. Best-effort by design: a peer whose channel
    is full misses the frame (matching per-slot backpressure), and frames
    over BUS_MAX_FRAME are not sent at all — no subscriber could accept them
    anyway.
    """
    if len(frame) > BUS_MAX_FRAME:
        return
    var datagram = encode_bus_frame(url, event_id, frame)
    for w in range(len(write_fds)):
        if w == skip_worker:
            continue
        try:
            _ = send(
                FileDescriptor(write_fds[w]),
                Span(datagram),
                UInt(len(datagram)),
                _MSG_DONTWAIT,
            )
        except:
            pass  # full or gone: drop for that peer alone


def encode_bus_frame(url: String, event_id: Int, frame: Span[Byte, _]) -> List[UInt8]:
    """[event_id: 8 LE][url_len: 2 LE][url][frame]."""
    var out = List[UInt8](capacity=_BUS_HEADER + url.byte_length() + len(frame))
    var id_bits = UInt64(event_id)
    for shift in range(0, 64, 8):
        out.append(UInt8((id_bits >> UInt64(shift)) & 0xFF))
    var url_len = url.byte_length()
    out.append(UInt8(url_len & 0xFF))
    out.append(UInt8((url_len >> 8) & 0xFF))
    out.extend(Span(url.as_bytes()))
    out.extend(frame)
    return out^


struct BusFrame(Movable):
    """One decoded bus datagram."""
    var url: String
    var event_id: Int
    var frame: List[UInt8]

    def __init__(out self, var url: String, event_id: Int, var frame: List[UInt8]):
        self.url = url^
        self.event_id = event_id
        self.frame = frame^


def decode_bus_frame(datagram: Span[Byte, _]) -> Optional[BusFrame]:
    """Inverse of `encode_bus_frame`; None for anything malformed.

    A truncated or garbage datagram is dropped, never delivered partially —
    the bus is same-machine same-binary, so malformed here means a bug, and
    a dropped frame is a far smaller failure than corrupt bytes on an SSE
    stream.
    """
    if len(datagram) < _BUS_HEADER:
        return None
    var id_bits = UInt64(0)
    for i in range(8):
        id_bits |= UInt64(datagram[i]) << UInt64(i * 8)
    var url_len = Int(datagram[8]) | (Int(datagram[9]) << 8)
    if _BUS_HEADER + url_len > len(datagram):
        return None
    var url_bytes = List[UInt8](capacity=url_len)
    for i in range(url_len):
        url_bytes.append(datagram[_BUS_HEADER + i])
    var url = String(StringSlice(unsafe_from_utf8=Span(url_bytes)))
    var frame = List[UInt8](capacity=len(datagram) - _BUS_HEADER - url_len)
    for i in range(_BUS_HEADER + url_len, len(datagram)):
        frame.append(datagram[i])
    return BusFrame(url^, Int(Int64(id_bits)), frame^)


def drain_bus_channel(read_fd: Int) raises -> List[BusFrame]:
    """Read every waiting datagram off a bus channel; decode what parses.

    The channel is non-blocking; EAGAIN ends the drain. The event loop calls
    this on read-readiness — edge-triggered registration means every pending
    datagram must be consumed before returning.
    """
    var frames = List[BusFrame]()
    var buf = List[UInt8](capacity=BUS_MAX_FRAME + _BUS_HEADER + 4096)
    for _ in range(BUS_MAX_FRAME + _BUS_HEADER + 4096):
        buf.append(0)
    var fd = FileDescriptor(read_fd)
    while True:
        var n: UInt
        try:
            n = recv(fd, Span(buf), UInt(len(buf)), _MSG_DONTWAIT)
        except:
            break  # EAGAIN: drained (or the channel died; either way, done)
        if n == 0:
            break
        var decoded = decode_bus_frame(Span(buf)[: Int(n)])
        if decoded:
            frames.append(decoded.take())
    return frames^
