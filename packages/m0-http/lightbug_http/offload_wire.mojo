"""The datagrams on the offload channels: their tags and shapes, the
little-endian words they are written in, and the one bounded send every
sender on the channels uses.

`offload.mojo`'s pool and the loop speak them, and so do `m0_wsgi`'s
handler, its pool threads and the executor shim, which mirrors the
numbers it cannot import. Nothing here holds state, and nothing here
imports the fork beyond `c/socket`, so `broadcast.mojo` reads and writes
a bus frame's event id through the same codec. `offload.mojo` imports
every name back, so a caller that imports one from there still finds
it. The bound on an inbound WebSocket datagram, `WS_DATAGRAM_MAX`, and
the room it leaves (`ws_message_room`) stay in `offload.mojo`, where
`scripts/render_shim.py` reads the bound by path.
"""

from std.ffi import ErrNo, c_int, external_call
from std.time import perf_counter_ns, sleep

from lightbug_http.c.socket import send


comptime _JOB_BYTES = 8
"""One job is one little-endian Int64 slot index. `_POISON` ends a thread."""

comptime _POISON = -1

comptime _POKE = -2
"""An 8-byte datagram carrying this value is a WAKE, not a job and not a
completion: the ring holds the work, the datagram only ends a `recv` or a
`kevent` that the other side announced it was parked in. Every reader of
a submit lane or the completion channel skips it."""

comptime TAG_STREAM_ABORT = UInt8(5)
"""First byte of a stream-abort datagram on the COMPLETION channel.

`[tag=5][slot i64 LE][gen i64 LE]`, 17 bytes, sent by a producer whose
stream died after its head went out — a WSGI generator that raised
mid-body, an ASGI app that raised after its first `more_body` chunk. The
loop closes the connection WITHOUT the chunked terminator, so the client
sees a truncated body rather than a clean one; a clean terminator on a
short body is the one lie this server refuses to tell. Rides the
completion channel because it is a loop-level signal about a slot, and
that channel already carries exactly those. Distinguished from a plain
completion by length (a completion is 8 bytes) and by the tag.

The generation is what makes it safe on a recycled slot: the head
carried it (`HTTPResponse.stream_gen`), the loop recorded it, and an
abort for a stream that is no longer the slot's current one is dropped.
"""

comptime _ABORT_BYTES = 17

comptime STREAM_GEN_NONE = 0
"""`HTTPResponse.stream_gen` of a response that is not a channel stream.
Real generations are never 0: `stream_gen_seed` starts every producer
above it."""

comptime COMPLETE_BATCH_MAX = 64
"""Most slots one completion datagram carries.

The executor answers a whole pump pass with ONE datagram — `k` concatenated
8-byte slots — instead of one per response, so the loop wakes once per
pass rather than once per response. The blocking pool's `complete` is the
`k = 1` case, unchanged. No tag: the completion channel has one reader,
and a length that is not a multiple of 8 is simply not a completion.
"""

comptime TAG_JOB_BATCH = UInt8(4)
"""First byte of a job-batch datagram on an EXECUTOR lane's submit channel.

`[tag=4][slot i64 LE] x n`, `1 <= n <= SUBMIT_BATCH_MAX`, so its length is
`1 + 8n` — congruent to 1 mod 8, which no plain job (8 bytes) is, and the
tag byte separates it from the 9-byte disconnect (tag 1), the WS message
(tag 2, >= 10) and the bus frame (tag 3, >= 11). The loop buffers the
slots it submits to an executor during a pass and sends them together at
the bottom of it, so the executor wakes once per pass rather than being
woken by the first submit while the rest are still being sent. A lane
holding exactly one slot sends the legacy 8-byte job: nothing to amortise,
no new shape on the wire. Pool lanes never see a batch — one thread takes
one job — and `next_job` says so loudly if one ever arrives.
"""

comptime SUBMIT_BATCH_MAX = 64

comptime TAG_WS_MESSAGE = UInt8(2)
"""First byte of an inbound-WebSocket datagram on a submit channel.

The channel carries two shapes now. A plain job is `_JOB_BYTES` of slot
index and nothing else — the hot path, unchanged. An inbound WebSocket
message is `[tag=2][slot i64 LE][opcode u8][chan_len u16 LE][channel]
[payload]`, the same shape the executor's shim already decodes, extended
with the channel because a pool thread's own registries are empty: the
socket was subscribed on the loop, and the name it joined with has to
travel with the message.

Length tells the two apart with no ambiguity to reason about: a plain job
is exactly 8 bytes and a message is at least 12.
"""

comptime _WS_HEADER = 12
"""tag(1) + slot(8) + opcode(1) + chan_len(2)."""


comptime SEND_TRIES = 64
"""How many times a sender on these channels offers one datagram before it
gives up (`send_bounded`)."""


def send_bounded(fd: Int, datagram: Span[Byte, _], tries: Int = SEND_TRIES) -> Bool:
    """Offer one datagram to `fd` up to `tries` times, yielding the core
    after each refusal; whether it went.

    The one retry every sender on these channels uses -- the pool's
    completions, wakes, pills, aborts, acks, chunks and batches, the hold
    frame, and `m0_wsgi.handler`'s tags -- and it adds no wait of its own:
    each sender runs on the event loop, which must not block, or on a
    thread that must not wait in a send (an attached executor would hold
    the GIL against the loop that drains the channel). Their descriptors
    are non-blocking, the completion channel's write end aside, which is
    sized so it cannot fill (`OffloadPool.complete`). What a refusal after
    the last try means is the caller's: a completion or an ack is kept and
    retried, a chunk is waited for detached, a wake or a disconnect tag is
    dropped.

    Every channel here is an AF_UNIX SOCK_DGRAM pair, where a send takes
    the whole datagram or none of it, so success is the whole length. Any
    failure is retried alike, a full buffer or not, as every copy of this
    loop did."""
    for _ in range(tries):
        var rc = external_call["send", Int](
            c_int(fd), datagram.unsafe_ptr(), UInt(len(datagram)), c_int(0)
        )
        if rc == len(datagram):
            return True
        _sched_yield()
    return False


comptime PILL_WAIT_NS = 5_000_000_000
"""How long `OffloadPool.stop` waits for room to pill a thread that parks
on its lane's socket, when its caller gives no deadline: the 5 s of the
join that follows it (`m0_http.mojo_pool.JOIN_TIMEOUT_NS`). A caller that
joins shares its own deadline instead (`stop_deadline`), so the two waits
are one bound and never stack."""


def stop_deadline(timeout_ns: Int) -> Int:
    """The deadline a pool's `stop_and_join` gives both its pills and its
    join: `timeout_ns` from now, or no deadline at all for a negative
    one, whose join is unbounded too."""
    if timeout_ns < 0:
        return Int.MAX
    return perf_counter_ns() + timeout_ns


def ns_left(deadline_ns: Int) -> Int:
    """What is left of `deadline_ns`: never negative, so a join handed it
    looks once and returns."""
    var left = deadline_ns - perf_counter_ns()
    return left if left > 0 else 0


def _offer_until(fd: Int, datagram: List[UInt8], deadline_ns: Int) -> Bool:
    """Offer `datagram` to `fd` until it is taken or `deadline_ns` passes;
    whether it went. Offered once whatever the deadline.

    For a datagram only its receiver can make room for, by reading: a
    pill for a thread still inside a view, behind the inbound WebSocket
    messages on its lane. `send_bounded`'s 64 yields are microseconds,
    and a full lane stays full for as long as the view runs. Waits only
    on a FULL channel -- EAGAIN, or ENOBUFS, macOS's word for a datagram
    queue with no room -- a millisecond between offers; any other failure
    is final at once, so a closed lane costs nothing. BLOCKS: shutdown's,
    never the loop's."""
    while True:
        try:
            _ = send(FileDescriptor(fd), Span(datagram), 0)
            return True
        except e:
            if not (
                e.would_block() or e.interrupted() or e.errno == ErrNo.ENOBUFS
            ):
                return False
        if perf_counter_ns() >= deadline_ns:
            return False
        sleep(0.001)


def append_i64_le(mut out: List[UInt8], value: Int):
    """Append `value` as eight little-endian bytes, two's complement: the
    slot, generation and event-id words of the datagrams on these channels."""
    var bits = UInt64(Int64(value))
    for shift in range(0, 64, 8):
        out.append(UInt8((bits >> UInt64(shift)) & 0xFF))


def read_i64_le(bytes: Span[Byte, _], at: Int) -> Int:
    """The eight little-endian bytes at `at`, as `append_i64_le` wrote them."""
    var bits = UInt64(0)
    for i in range(8):
        bits |= UInt64(bytes[at + i]) << UInt64(i * 8)
    return Int(Int64(bits))


comptime ACK_BYTES = 8
"""A drain ack: `(slot: i32 LE, credit: i32 LE)`, the one datagram on
every ack pair -- an executor's and a pool thread's. `encode_ack` is its
only writer and `decode_ack` its only reader in Mojo; the shim reads the
executor's with `int.from_bytes(..., 'little')`, where a credit is never
negative."""

comptime ACK_DISCONNECT = -1
"""The credit of the ack that tells a pool thread its client is gone
(`m0_wsgi.handler`'s `_send_pool_disconnect`): the same shape as a
credit, so the thread's one blocking read learns both."""


def append_i32_le(mut out: List[UInt8], value: Int):
    """Append `value` as four little-endian bytes, two's complement: the
    words of a drain ack."""
    var bits = UInt32(value & 0xFFFFFFFF)
    for shift in range(0, 32, 8):
        out.append(UInt8((bits >> UInt32(shift)) & 0xFF))


def read_i32_le(bytes: Span[Byte, _], at: Int) -> Int:
    """The four little-endian bytes at `at`, sign-extended, as
    `append_i32_le` wrote them. By hand: `Int(Int32(UInt32(0xFFFFFFFF)))`
    was 4294967295 on Mojo 1.0, not -1 -- the conversion did not wrap --
    and the disconnect ack (`ACK_DISCONNECT`) depends on getting -1 back."""
    var bits = 0
    for i in range(4):
        bits |= Int(bytes[at + i]) << (i * 8)
    if bits >= 0x80000000:
        bits -= 0x100000000
    return bits


def encode_ack(slot: Int, credit: Int) -> List[UInt8]:
    """One drain ack (`ACK_BYTES`): the loop's credit for `slot`
    (`OffloadPool.ack_stream`), or its disconnect (`ACK_DISCONNECT`)."""
    var out = List[UInt8](capacity=ACK_BYTES)
    append_i32_le(out, slot)
    append_i32_le(out, credit)
    return out^


def decode_ack(bytes: Span[Byte, _]) -> Tuple[Int, Int]:
    """`(slot, credit)` from an `ACK_BYTES` datagram `encode_ack` wrote."""
    return (read_i32_le(bytes, 0), read_i32_le(bytes, 4))


def _encode_job(slot: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=_JOB_BYTES)
    append_i64_le(out, slot)
    return out^


def _decode_job(buf: Span[Byte, _]) -> Int:
    return read_i64_le(buf, 0)


def stream_gen_seed(producer: Int) -> Int:
    """The first generation a stream producer hands out; it counts up from here.

    A generation names ONE stream on a slot, so a frame that outlived its
    connection cannot be mistaken for the next stream's — and it must be
    unique across every producer on a loop (an executor per ASGI lane, N
    pool threads), which would otherwise need a shared counter. Instead
    each producer owns a disjoint range: the high 32 bits are its id, the
    low 32 its own count. Executors use `1 + lane` (the unmounted executor's
    lane is -1, so it takes 0 → seed 1), pool threads `1024 + index`; both
    start their low half at 1, so no generation is ever `STREAM_GEN_NONE`.
    """
    return ((producer + 1) << 32) + 1


def _encode_job_batch(slots: List[Int]) -> List[UInt8]:
    """`[TAG_JOB_BATCH][slot i64 LE] x n`; see the tag's docstring."""
    var out = List[UInt8](capacity=1 + _JOB_BYTES * len(slots))
    out.append(TAG_JOB_BATCH)
    for i in range(len(slots)):
        append_i64_le(out, slots[i])
    return out^


def _encode_completions(slots: List[Int]) -> List[UInt8]:
    """`k` concatenated 8-byte LE slots; see `COMPLETE_BATCH_MAX`."""
    var out = List[UInt8](capacity=_JOB_BYTES * len(slots))
    for i in range(len(slots)):
        append_i64_le(out, slots[i])
    return out^


def _sched_yield():
    _ = external_call["sched_yield", c_int]()
