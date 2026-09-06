"""The work queue behind `--blocking-threads`: an acceptor loop, a pool of
handler threads, and two datagram channels between them.

The problem this exists for is measured, not argued
(`docs/WSGI_PERFORMANCE.md`, "A slow view strands the connections pinned
behind it"): `HTTPService.func` runs synchronously on the event loop, so one
slow view stops every keep-alive connection that loop happens to hold. One
`/slow?ms=200` beside fast traffic takes fast-request p99 from 1.6 ms to
~194 ms while p50 does not move at all — not general slowdown, a subset of
connections stopped dead. More loops does not fix it: a keep-alive connection
belongs to the loop that accepted it under `--workers` and under `--threads`
alike.

The fix is to stop running the handler on the loop. The loop parses the
request, parks it here, and returns to `wait()`; a pool thread picks it up,
calls the handler, parks the response, and pokes the loop; the loop encodes
and writes it through the same `RESPONDING` path every other response takes.
No connection is hostage to whichever request some other connection is
running.

**This module knows nothing about Python or about handlers.** It is storage
and two socketpairs. The threads that consume it live in `m0_wsgi`, which is
the only package that may attach to an interpreter — the split is what keeps
libpython off the link line of everything else.

## Ownership, which is the whole safety argument

A job slot's entry is owned by exactly ONE thread at any moment, and the
ownership handoff is a sequentially consistent publish in memory:

    loop: park_request(slot)  ->  submit(slot)   ~~>  next_job() -> take_request(slot)
    pool: put_response(slot)  ->  complete(slot) ~~>  drain_completions() -> take_response(slot)

`submit` pushes the slot onto its lane's ring and `complete` onto the
completion ring (`ring.mojo`); a push is an atomic store that the pop's
atomic load synchronises with, so the writes before a `submit` are
visible to the thread that pops it. Nothing else is shared: the loop never
touches a slot between `submit` and its completion, and a pool thread
never touches one it did not receive. With `M0_POOL_RING=0` there are no
rings and the same two crossings are the socketpair syscalls they were
before 2026-09-05, whose kernel lock is the same fence.

The slot is also never *recycled* mid-flight. A client that disconnects while
its request is in a pool thread detaches the fd but leaves the provision
borrowed; the completion arrives, finds `slot_fds[slot] == UNUSED`, drops the
response and releases the slot then. A generation counter would detect that
race instead; holding the slot removes it.

## The socketpairs: the wake, and everything that carries a payload

Two `SOCK_DGRAM` pairs per lane, as before, and they still carry
everything that is not a bare slot: an inbound WebSocket message
(`TAG_WS_MESSAGE`), the poison pill, a stream abort, and an executor's job
batch and completion batch — the executor is the shim's asyncio loop,
which reads its lane with `add_reader`, and its datagram protocol is
untouched. Datagrams preserve message boundaries, so N pool threads
reading one channel each dequeue exactly one whole one: a pill retires one
thread, a message reaches one thread. And the completion end is something
kqueue/epoll can wake the loop on, exactly as a `BroadcastBus` channel is.

What a plain job or completion sends on them is a WAKE (`_POKE`, an 8-byte
datagram no reader mistakes for a slot), and only when the other side has
announced that it is parked:

- a pool thread that finds its ring empty spins for `POOL_SPIN_NS`
  (yielding after `POOL_YIELD_AFTER_NS`), then counts itself parked,
  re-checks the ring, and blocks; `submit` pushes, then reads that count,
  and wakes only if the lane needs it (below);
- the loop raises its own flag before `backend.wait` and re-checks the
  completion ring after raising it (`event_loop._wait_for_events`);
  `complete` pushes, then reads the flag, and pokes the completion
  channel only if it is set.

Announce, then re-check, then block — and push, then read the
announcement, then poke. Every one of those is sequentially consistent
(the stdlib's default), so one side always sees the other and a wake is
never lost. Reordering either sequence is a lost wakeup: a request
answered a second late, or at shutdown a thread that never reads its pill.

## The wake is elastic: one thread until a job has waited

Measured 2026-09-06 (docs/notes/elastic-pool.md): the zero-config pool
of eight threads served a trivial view at 0.67x the one-thread rate on
1.6x the cores, because a burst of jobs was taken by as many threads as
were awake and they then serialized on the GIL with an OS wake per
hand-off. Four rules, all in `next_job`, `submit` and `wake_aged`, and
all off under `M0_POOL_ELASTIC=0` (the A/B knob, which restores the
rules of 2026-09-05):

- **One idle spinner per lane.** A thread that finds its ring empty spins
  only if no sibling is already spinning idle; otherwise it parks at
  once. The spinner sees every push itself.
- **`submit` wakes nobody while any thread of the lane is busy or
  spinning.** A busy thread with an empty ring behind it comes back in
  microseconds and takes the job faster than a wake could land; a wake
  beside it is a second thread on the GIL for nothing. Only a lane whose
  every thread is parked (`_all_idle`: `threads <= parked`, spinners
  zero) gets a wake — and exactly one, because the wake retires the
  woken thread's parked count before the next push can look.
- **A job that has waited is behind a slow view, and the LOOP wakes a
  sibling for it.** Once per pass `wake_aged` peeks each lane's ring head
  and, if it was parked (`submit_ns`) more than `POOL_WAKE_AGE_NS` ago,
  wakes one parked thread; `_wait_for_events` caps its timeout at
  `POOL_WAKE_WAIT_MS` while any job is pending, so an idle loop looks
  within a millisecond. This replaced the chained wake (a thread that
  took a job poking a sibling for the rest — `_chain_wake`, kept for the
  knob-off arm): the hole the chain filled, a woken thread's socket poll
  consuming a sibling's wake, is now closed on every pass rather than
  once, because the head is re-examined until it is gone.
- **Every pool thread parks on a channel of its OWN, and is woken by
  name — the one that parked LAST first** (`register_thread`,
  `_park_on_own`, `_wake_registered`). The kernel's choice for N
  receivers blocked on one socket is wrong on both platforms: macOS
  wakes all of them (one datagram into eight blocked receivers costs
  59 µs of CPU against 3 into one) and Linux wakes the oldest,
  round-robin, so every job landed on the coldest thread and its cold
  interpreter thread state. Pills go to those channels too (`stop`),
  and a WebSocket message sent on the lane socket is followed by a wake
  to a parked thread, which polls the socket first thing. A thread that
  never registered (a test's, or every thread under the knob) parks on
  the lane socket under the old rule: one poke per parked thread, never
  one per push.

The spin is what makes a pool thread's park rare rather than free. At
130–180k rps the gap between jobs on one thread is a microsecond or two,
inside the spin, so most jobs are taken without a park and most submits
without a poke — the shape crossbeam's backoff gives Granian's blocking
thread. The spin runs DETACHED (the pool body saves its thread state
before `next_job`), so it holds no GIL. While spinning or working, the
thread polls its socket non-blocking once per `POOL_DGRAM_POLL_NS`, which
is how a pill or a WebSocket message reaches a thread that never runs dry.
The loop's flag starts SET and the inversion's driver never clears it: it
waits inside asyncio rather than in `_wait_for_events`, so every
completion pokes it — the datagram shape that path always had.

Submit is non-blocking on the loop side: a full ring (or, without rings, a
full queue) means "the pool is saturated", and the loop's answer is to run
that one request inline rather than drop it. Completion cannot fill: at
most `OFFLOAD_MAX_INFLIGHT` jobs exist at once and both the ring and the
channel are sized for that many.
"""

from std.collections import Optional
from std.ffi import c_int, external_call

from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.socket import (
    send, recv, close, setsockopt, SocketOption, SOL_SOCKET,
)
from lightbug_http.c.socket_error import RecvEAGAINError, RecvEINTRError
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.c.platform import MSG_DONTWAIT
from lightbug_http.ring import Ring, atomic_at
from std.atomic import Atomic
from std.os import getenv
from std.time import perf_counter_ns


comptime OFFLOAD_MAX_INFLIGHT = 256
"""Jobs that may be outstanding at once, across all pool threads.

Not a throughput knob — a bound on how much the channels must hold. Linux
charges a UNIX datagram's whole `skb` (several hundred bytes of overhead for
an 8-byte payload) against the RECEIVER's `SO_RCVBUF`, and caps a
non-privileged `SO_RCVBUF` at `net.core.rmem_max` (212 KB by default). 256
jobs fit that with room to spare on every platform this runs on. Past the
bound the loop runs requests inline, which is exactly today's behaviour — the
degradation is graceful and never drops a request.
"""

comptime _JOB_BYTES = 8
"""One job is one little-endian Int64 slot index. `_POISON` ends a thread."""

comptime _POISON = -1

comptime _POKE = -2
"""An 8-byte datagram carrying this value is a WAKE, not a job and not a
completion: the ring holds the work, the datagram only ends a `recv` or a
`kevent` that the other side announced it was parked in. Every reader of
a submit lane or the completion channel skips it."""

comptime POOL_SPIN_NS = 10_000
"""How long a pool thread whose ring is empty keeps looking before it
parks. Longer than the gap between jobs at the rates the pool serves
(1–2 µs at 130–180k rps). Measured against 30 µs on the same day: the
same throughput at 16 and 256 connections, and ten points less CPU on
the pool thread at 16 (docs/notes/pool-ring-handoff.md)."""

comptime POOL_YIELD_AFTER_NS = 2_000
"""Into the spin, the point after which each look is followed by
`sched_yield`, so a thread waiting past the common gap gives its core up
to whatever else wants it."""

comptime POOL_DGRAM_POLL_NS = 100_000
"""How often a pool thread that is not parked polls its socket
non-blocking. Only pills and payload datagrams (an inbound WebSocket
message) ride the socket now, so this bounds how late one is noticed by a
thread that never runs out of ring work: one recv per 100 µs is a few
tenths of a percent of the thread."""

comptime POOL_WAKE_AGE_NS = 200_000
"""How long the SAME job may sit at the head of a lane's ring, unmoved,
before the LOOP wakes a parked sibling for it (`wake_aged`, once per
pass).

The elastic pool's threshold, `T`. Below it the pool behaves as ONE
handler thread: `submit` wakes nobody while a thread is busy or spinning
on the lane, because a thread that is a few microseconds from coming back
takes the job faster than a wake can land, and a burst of trivial jobs
taken by N threads serializes on the GIL with an OS wake per hand-off —
zero-config's eight threads served a trivial view at 0.67x the one-thread
rate on 1.6x the cores (docs/notes/elastic-pool.md). Above it a thread is
inside a view that is not coming back soon, and the isolation the pool
exists for needs a sibling: a fast request behind two 200 ms views waits
this long plus a wake, against the view's whole hold time without the
pool.

It is time WITHOUT PROGRESS that is measured, not the head's age since
submit. A ring 256 deep behind one thread taking 4 µs a job holds a head
that is a millisecond old and moving every 4 µs, and waking a sibling
for its age puts N threads on the GIL for a queue one thread drains
faster — measured at 256 connections as 0.90x the one-thread rate with
400 such wakes a run; and looking for the SAME job at the head across
the loop's passes is no better there, because a pass at 256 connections
is longer than `T` and every look finds a fresh head as old as the
backlog. The ring's pop counter is the signal: if it advanced since the
loop last looked, the ring is being drained, however deep; if it did
not, the head has waited since the later of its push and the last look
that saw progress, and past `T` of that a thread is not coming back —
the case a sibling is for. Chosen by measurement, recorded in the note."""

comptime POOL_WAKE_WAIT_MS = 1
"""The loop's longest `wait` while a job sits on a lane's ring.

The age check runs once per pass, and under load a pass is every 10–30
µs; an IDLE loop parks in `kevent`/`epoll_wait` for up to a second, which
would be a job behind a slow view waiting a second for its sibling.
`_wait_for_events` bounds the timeout to this whenever `jobs_pending`, so
the wait costs nothing while the rings are empty and a pending job is
looked at within a millisecond, the backends' timer granularity."""

comptime _WAKE_BYTES = 8192
"""The wake words: the loop's parked flag at +0, the registered-thread
counter at +8 and the park sequence at +16; then per lane at
`_WAKE_LANE_BASE + lane * _WAKE_LANE_STRIDE` a count of threads parked on
the LANE socket (+0), the last datagram-poll time (+8), the wakes in
flight to that socket (+16), the idle spinners (+24), the threads serving
the lane (+32), the wakes `wake_aged` sent (+40), the wakes `submit` sent
(+48) and the threads parked on their OWN channel (+56), each lane on its
own cache line."""
comptime _WAKE_THREADS = 8
comptime _WAKE_SEQ = 16
comptime _WAKE_LANE_BASE = 128
comptime _WAKE_LANE_STRIDE = 64
comptime _WAKE_MAX_LANES = (_WAKE_BYTES - _WAKE_LANE_BASE) // _WAKE_LANE_STRIDE

comptime _THREAD_STRIDE = 64
"""Bytes per registered pool thread in the thread block (`reserve_threads`):
its state (+0: running, parked, woken), the sequence it parked with (+8),
its lane (+16; -1 before registration, -2 after leaving), the two ends of
its own wake channel (+24 read, +32 write) and a pill it read while
holding a job (+40). One cache line per thread.

Why a channel per thread: the kernel decides which of N threads blocked
in `recv` on one socket a datagram wakes, and both platforms decide
badly for this pool. macOS wakes EVERY one of them (measured: one
datagram into eight blocked receivers costs 59 µs of CPU against 3 into
one, and they take turns serving), and Linux wakes exactly one but the
OLDEST — round-robin, so each job lands on the coldest thread. With its
own channel a thread is woken by name, and `_wake_registered` names the
one that parked LAST: the thread whose caches, and whose interpreter
thread state, are still warm. docs/notes/elastic-pool.md has the
measurement."""
comptime _TR_STATE = 0
comptime _TR_SEQ = 8
comptime _TR_LANE = 16
comptime _TR_READ = 24
comptime _TR_WRITE = 32
comptime _TR_PILL = 40
comptime _TS_RUNNING = 0
comptime _TS_PARKED = 1
comptime _TS_WOKEN = 2
comptime _OWN_NONE = 0
comptime _OWN_POKE = 1
comptime _OWN_PILL = 2
comptime _OWN_DEAD = -1

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

comptime WS_DATAGRAM_MAX = 65546
"""Largest `TAG_WS_MESSAGE` datagram a pool thread or the shim will read.

Equal to `m0_wsgi.blocking_pool.WS_JOB_BUFFER` and to the shim's own read
size; `m0_wsgi.handler.WS_CHANNEL_DATAGRAM_MAX` is the same number on the
other side of the package boundary, which m0-http may not import from."""

comptime _WS_HEADER = 12
"""tag(1) + slot(8) + opcode(1) + chan_len(2)."""

comptime JOB_REQUEST = 0
"""`PoolJob.kind`: an ordinary request, `slot` names it."""
comptime JOB_WS_MESSAGE = 1
"""`PoolJob.kind`: an inbound WebSocket message, in the caller's buffer."""
comptime JOB_STOP = 2
"""`PoolJob.kind`: the poison pill; this thread is done."""
comptime JOB_NONE = 3
"""`PoolJob.kind`: nothing to serve — a wake datagram, an empty
non-blocking read, or a shape this version does not serve. Internal to
`next_job`, which never returns it."""


@fieldwise_init
struct PoolJob(Copyable, Movable):
    """What `next_job` took off the channel — a view into the caller's buffer.

    The payload is deliberately NOT copied out: a WebSocket message can be
    the size of the whole receive buffer, and the thread that read it is the
    only thread that will look at it.
    """

    var kind: Int
    var slot: Int
    var opcode: Int
    var chan_start: Int
    var chan_len: Int
    var payload_start: Int
    var payload_len: Int

comptime _OFFLOAD_SOCKET_BUF = 262144


def _size_socket(fd: Int):
    """Best-effort: default UNIX datagram buffers are far too small (2 KB on
    macOS) to hold `OFFLOAD_MAX_INFLIGHT` jobs."""
    try:
        setsockopt(
            FileDescriptor(fd), Int32(SOL_SOCKET),
            SocketOption.SO_SNDBUF.value, Int32(_OFFLOAD_SOCKET_BUF),
        )
    except:
        pass
    try:
        setsockopt(
            FileDescriptor(fd), Int32(SOL_SOCKET),
            SocketOption.SO_RCVBUF.value, Int32(_OFFLOAD_SOCKET_BUF),
        )
    except:
        pass


def _encode_job(slot: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=_JOB_BYTES)
    var bits = UInt64(slot)
    for shift in range(0, 64, 8):
        out.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    return out^


def _decode_job(buf: Span[Byte, _]) -> Int:
    var bits = UInt64(0)
    for i in range(_JOB_BYTES):
        bits |= UInt64(buf[i]) << UInt64(i * 8)
    return Int(Int64(bits))


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
        var bits = UInt64(Int64(slots[i]))
        for shift in range(0, 64, 8):
            out.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    return out^


def _encode_completions(slots: List[Int]) -> List[UInt8]:
    """`k` concatenated 8-byte LE slots; see `COMPLETE_BATCH_MAX`."""
    var out = List[UInt8](capacity=_JOB_BYTES * len(slots))
    for i in range(len(slots)):
        var bits = UInt64(Int64(slots[i]))
        for shift in range(0, 64, 8):
            out.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    return out^


def match_path_prefix(prefixes: List[String], path: String) -> Int:
    """Index of the longest prefix in `prefixes` that `path` falls under, or -1.

    A prefix matches only on a segment boundary, so `/app` covers `/app` and
    `/app/x` but never `/application`. The empty prefix is the root and needs
    no special case: every request target starts with `/`, so it matches at
    length 0 and any deeper prefix outranks it.

    Lives here rather than in the WSGI layer because both callers need the
    same answer and there must be exactly one of it -- `m0serve`'s mount
    router picks the application, this pool's `lane_for` picks the worker,
    and a second copy of segment-boundary matching is how `/app` starts
    swallowing `/application` again.
    """
    var best = -1
    var best_len = -1
    for i in range(len(prefixes)):
        ref prefix = prefixes[i]
        var n = prefix.byte_length()
        if n <= best_len:
            continue
        if not path.startswith(prefix):
            continue
        if path.byte_length() > n and path.as_bytes()[n] != UInt8(ord("/")):
            continue
        best = i
        best_len = n
    return best


struct OffloadPool(Movable):
    """Job storage plus the two channels; created by the caller, not the loop.

    Constructed BEFORE `run_event_loop` and outliving it, because the pool
    threads hold its address for their whole lives and the loop's own locals
    do not exist yet when they are spawned. `capacity` must be the server's
    `max_connections`: slots index this directly, exactly as they index the
    provision pool.

    Pass `addr()` to `run_event_loop` as `offload_addr`, and to each pool
    thread's argument block.
    """

    var lane_prefixes: List[String]
    """Path prefixes naming the extra submit lanes, parallel to
    `lane_submit_read`/`lane_submit_write` with lane 0's prefix first.

    Empty for an unmounted server: one lane, every job to it, exactly the
    shape this pool had before mounts existed. With `--mount`, one lane per
    mount, so a job reaches the worker that owns that application instead of
    whichever worker happens to read the datagram first — which with one
    channel is a coin flip, not a design.
    """

    var lane_submit_read: List[Int]
    """Read ends for lanes 1..N (lane 0 is `submit_read`)."""

    var lane_submit_write: List[Int]

    var submit_read: Int
    """Pool threads block here. Blocking on purpose — a parked worker sleeps.

    Lane 0's read end; `submit_read_fd(lane)` is the general accessor."""

    var submit_write: Int
    """The loop sends jobs here; non-blocking, so a full queue is visible."""

    var complete_read: Int
    """Registered with the backend like a bus channel; the loop drains it."""

    var complete_write: Int
    """Pool threads poke the loop here."""

    var requests: List[Optional[HTTPRequest]]
    var responses: List[Optional[HTTPResponse]]

    var errored: List[Bool]
    """The handler raised for this slot. Written by the pool thread before
    `complete` and therefore published by the same edge as the response; the
    loop reads it to reproduce the synchronous path's `should_close = True`,
    which it cannot infer from a 500 that a handler might have returned
    deliberately."""

    var stream_chunk_read: Int
    var stream_chunk_write: Int
    var stream_ack_read: Int
    var stream_ack_write: Int
    """The streaming channels, -1 until enabled. Chunks travel producer→loop
    as bus-shaped datagrams on ONE pair (`enable_stream_channel`) —
    `stream_chunk_read` is what the wiring passes to `run_event_loop` as its
    `bus_read_fd` — from an asyncio executor and from `--blocking-threads`
    pool threads streaming WSGI iterables alike. Drain acks travel
    loop→producer as `(slot: i32, bytes: i32)` datagrams, which is what
    makes a producer's wait for credit mean something: the executor's base
    pair is `enable_base_stream_ack` (a lane's is `enable_stream_ack`), and
    a pool thread's is its own, registered per slot in `slot_ack_fd`.
    `stream_active` marks an executor; `chunk_active` marks the channel."""

    var hold_notify_fd: Int
    """This loop's own BroadcastBus write end, or -1: where a pool thread
    sends an `M0-Hold` it took, so the subscription lands in the LOOP's
    registries rather than the pool thread's own. Set by the wiring under
    `--realtime --blocking-threads`; a pool thread reads it through its
    `ThreadContext`. The loop's channel and no other: slot numbers index
    this loop's provisions and mean nothing to any other loop."""

    var slot_lane: List[Int]
    """Which lane each slot's in-flight job was submitted on; stale between
    jobs and overwritten by the next `submit`. What routes a drain ack (and
    nothing else) to the executor that owns the slot — credit sent to a
    different executor is a permanently stalled stream, because the shim's
    `send()` awaits a window only its own ack fd replenishes."""

    var lane_ack_read: List[Int]
    var lane_ack_write: List[Int]
    """Per-lane drain-ack pairs, parallel to `lane_prefixes`; -1 where a
    lane has no executor (a WSGI lane, whose slots never stream). The chunk
    channel stays SHARED — slots are unique per loop so chunks are already
    addressed, and one datagram queue is globally FIFO, which is what keeps
    the recycled-slot argument true with two writers — but acks cannot
    share: credit belongs to the executor that owns the slot."""

    var slot_ack_fd: List[Int]
    """Per slot, the ack fd of a POOL THREAD streaming this slot's body, or -1.

    A pool thread streaming a WSGI iterable is a second producer on the
    chunk channel, and its credit has to come back to that thread — not to
    a lane, since N threads share one. So the thread writes its own ack
    write end here (before its begin frame; the frame's send publishes the
    write), `ack_stream` routes by it first, and `slot_channel_stream`
    reads it to know the slot is a channel stream at all. The LOOP clears
    it — at accept, and where a stream ends — because a stale entry would
    make a later `M0-Hold` on the same slot look like a channel stream:
    chunk-framed, acked into a pair nobody reads, and denied the comment
    heartbeat that keeps it alive through a proxy."""

    var aborts: List[Int]
    """`(slot, gen)` pairs `drain_completions` took off the channel as
    `TAG_STREAM_ABORT` datagrams, flattened; the loop takes them with
    `take_aborts`. Loop-side only."""

    var _drain_buf: List[UInt8]
    """The completion channel's receive buffer, sized once for the largest
    datagram it carries. It used to be allocated and zero-filled a byte at
    a time -- two thousand `append`s -- on every read of the channel."""
    var sweep_every_pass: Bool
    """The loop runs its per-pass outbox sweep even when no slot streams.

    Set by the pump wiring — an executor THREAD draining this loop's
    submits — and by nothing else. The sweep's miss path costs the loop
    thread 1.2 µs per pass, and under the pump that microsecond turned
    out to be load-bearing: without it the loop returns to `wait` sooner,
    a pass batches fewer submits, and the executor takes more wakes per
    request — measured at −3% rps and +6% CPU at c16 (nothing at c256).
    Every other shape (a Mojo-native server, the WSGI pool, the inverted
    executor, which IS the loop's thread) skips the sweep while
    `OffloadLoopState.streaming_hint` is zero: +3.5% on the hello row,
    +4% inverted. Accidental pacing, kept deliberately and named
    (ROADMAP.md, "Pacing the pump's loop thread")."""

    var capacity: Int

    var ring_enabled: Bool
    """The in-memory handoff (module docstring). Off under `M0_POOL_RING=0`,
    and always off for a disabled pool."""

    var job_rings: List[Ring]
    """Per lane, the ring `submit` pushes onto and `next_job` pops from. An
    executor lane gets one too and never uses it (its jobs are batched
    datagrams); a lane past `_WAKE_MAX_LANES` gets a disabled ring, which
    both sides read as "this lane is datagrams"."""

    var done_ring: Ring
    """The one completion ring: every pool thread pushes, the loop pops."""

    var wake_base: Int
    """The `_WAKE_BYTES` block of parked flags, or 0 without rings."""

    var elastic: Bool
    """The elastic wake rules (`POOL_WAKE_AGE_NS`): one idle spinner per
    lane, `submit` waking nobody while a thread is busy or spinning, and
    the loop's age check in place of the chained wake. Off under
    `M0_POOL_ELASTIC=0` — the A/B knob, which restores the eager rules of
    2026-09-05: every idle thread spins, every push into a parked lane
    pokes, and a thread that takes a job pokes a sibling for the rest.
    Always off without rings."""

    var submit_ns: List[Int]
    """Per slot, when its current job was parked (`park_request`), the
    loop's clock. Written and read by the loop thread only — `wake_aged`
    reads it as the job's identity on a recycled slot and as the earliest
    its wait can have begun — so no atomics."""

    var lane_pops: List[Int]
    var lane_progress: List[Int]
    """Per lane, the ring's pop count `wake_aged` last saw and when it
    last saw the count move (or the ring empty): the last moment the
    lane is known to have been draining. Loop-only."""

    var parallel: Bool
    """The FREE-THREADED rule: `submit` wakes a parked thread whenever
    there is one (a parked thread beside a queued job is an idle core,
    not a GIL waiter), and `wake_aged` counts a head's wait from its
    PUSH, whatever the pop counter did. False on a GIL build, where a
    busy thread takes the job sooner than a wake could land and a
    draining ring is left alone. Set by the wiring from the
    interpreter's own answer (`set_parallel`); the single spinner and
    the wake by name on each thread's own channel apply either way.
    `M0_POOL_PARALLEL=1`/`0` overrides it, the A/B knob. Measured on
    3.14t (docs/notes/elastic-pool.md): with the GIL rules the fast
    route's p99 under slow views was 8–10 ms against 2–4 with the eager
    wakes, and neither variant of the stall check moved it."""

    var _parallel_forced: Int
    """-1 when the knob is unset, else what it said."""

    var wake_age: Int
    """The age threshold the loop's check uses: `POOL_WAKE_AGE_NS`, or
    `M0_POOL_WAKE_AGE_US` in microseconds when set — the measurement
    knob the threshold was chosen with (docs/notes/elastic-pool.md)."""

    var thread_base: Int
    """The block of `_THREAD_STRIDE` records `reserve_threads` made, or 0:
    then every pool thread parks on the lane socket, the shape before
    per-thread channels (and the shape under `M0_POOL_ELASTIC=0`)."""

    var thread_cap: Int
    """Records in `thread_base`; `register_thread` hands them out."""

    def __init__(out self, capacity: Int) raises:
        """`capacity == 0` builds a disabled pool: no descriptors, no storage.

        The threaded path constructs one per loop unconditionally, because
        Mojo 1.0's `Optional` wants `ImplicitlyCopyable` and this type is
        deliberately not. A disabled pool costs a struct rather than four
        descriptors per loop; nothing consults it, since the loop is handed
        `offload_addr = 0`.
        """
        # One slot minimum, even for a disabled pool, so every per-slot
        # table has an entry to index; `self.capacity` is what says whether
        # this pool is real, and it is 0 either way.
        self.lane_prefixes = List[String]()
        self.lane_submit_read = List[Int]()
        self.lane_submit_write = List[Int]()
        self.lane_ack_read = List[Int]()
        self.lane_ack_write = List[Int]()
        var slots = capacity if capacity > 0 else 1
        self.slot_lane = List[Int](capacity=slots)
        self.slot_ack_fd = List[Int](capacity=slots)
        self.submit_ns = List[Int](capacity=slots)
        for _ in range(slots):
            self.slot_lane.append(0)
            self.slot_ack_fd.append(-1)
            self.submit_ns.append(0)
        self.aborts = List[Int]()
        self._drain_buf = List[UInt8](capacity=OFFLOAD_MAX_INFLIGHT * _JOB_BYTES)
        self._drain_buf.resize(OFFLOAD_MAX_INFLIGHT * _JOB_BYTES, 0)
        self.requests = List[Optional[HTTPRequest]](capacity=slots)
        self.responses = List[Optional[HTTPResponse]](capacity=slots)
        self.errored = List[Bool](capacity=slots)
        for _ in range(slots):
            self.requests.append(None)
            self.responses.append(None)
            self.errored.append(False)
        self.capacity = capacity if capacity > 0 else 0

        self.stream_chunk_read = -1
        self.stream_chunk_write = -1
        self.stream_ack_read = -1
        self.stream_ack_write = -1
        self.hold_notify_fd = -1
        self.sweep_every_pass = False
        self.ring_enabled = capacity > 0 and getenv("M0_POOL_RING", "") != "0"
        self.elastic = self.ring_enabled and getenv("M0_POOL_ELASTIC", "") != "0"
        self.thread_base = 0
        self.thread_cap = 0
        self.lane_pops = List[Int]()
        self.lane_progress = List[Int]()
        self.lane_pops.append(0)
        self.lane_progress.append(0)
        self.parallel = False
        self._parallel_forced = -1
        var par = getenv("M0_POOL_PARALLEL", "")
        if par == "1" or par == "0":
            self._parallel_forced = 1 if par == "1" else 0
            self.parallel = par == "1"
        self.wake_age = POOL_WAKE_AGE_NS
        var age_us = getenv("M0_POOL_WAKE_AGE_US", "")
        if age_us != "":
            try:
                self.wake_age = Int(age_us) * 1000
            except:
                pass
        self.job_rings = List[Ring]()
        self.done_ring = Ring()
        self.wake_base = 0
        if self.ring_enabled:
            self.job_rings.append(Ring(OFFLOAD_MAX_INFLIGHT))
            self.done_ring = Ring(OFFLOAD_MAX_INFLIGHT * 2)
            self.wake_base = external_call["malloc", Int, Int](_WAKE_BYTES)
            for w in range(_WAKE_BYTES // 8):
                atomic_at(self.wake_base + w * 8)[] = Atomic[DType.int64](0)
            # The loop's flag starts SET: a loop that never announces its
            # parks (the inversion's driver waits inside asyncio) is poked on
            # every completion, the datagram shape it always had.
            atomic_at(self.wake_base)[].store(1)

        if capacity <= 0:
            self.submit_read = -1
            self.submit_write = -1
            self.complete_read = -1
            self.complete_write = -1
            return
        var submit = socketpair_dgram()
        var completion = socketpair_dgram()
        self.submit_read = submit[0]
        self.submit_write = submit[1]
        self.complete_read = completion[0]
        self.complete_write = completion[1]
        _size_socket(self.submit_read)
        _size_socket(self.submit_write)
        _size_socket(self.complete_read)
        _size_socket(self.complete_write)
        # Only the two ends the LOOP touches are made non-blocking: it must
        # never park in a syscall. `submit_read` stays blocking so a pool
        # thread with nothing to do sleeps instead of spinning, and
        # `complete_write` stays blocking as the backstop described in
        # `complete`.
        _set_nonblocking_fd(self.submit_write)
        _set_nonblocking_fd(self.complete_read)

    def __init__(out self, *, deinit move: Self):
        self.lane_prefixes = move.lane_prefixes^
        self.lane_submit_read = move.lane_submit_read^
        self.lane_submit_write = move.lane_submit_write^
        self.lane_ack_read = move.lane_ack_read^
        self.lane_ack_write = move.lane_ack_write^
        self.slot_lane = move.slot_lane^
        self.slot_ack_fd = move.slot_ack_fd^
        self.aborts = move.aborts^
        self._drain_buf = move._drain_buf^
        self.submit_read = move.submit_read
        self.submit_write = move.submit_write
        self.complete_read = move.complete_read
        self.complete_write = move.complete_write
        self.stream_chunk_read = move.stream_chunk_read
        self.stream_chunk_write = move.stream_chunk_write
        self.stream_ack_read = move.stream_ack_read
        self.stream_ack_write = move.stream_ack_write
        self.hold_notify_fd = move.hold_notify_fd
        self.requests = move.requests^
        self.responses = move.responses^
        self.errored = move.errored^
        self.capacity = move.capacity
        self.sweep_every_pass = move.sweep_every_pass
        self.ring_enabled = move.ring_enabled
        self.job_rings = move.job_rings^
        self.done_ring = move.done_ring.copy()
        self.wake_base = move.wake_base
        self.elastic = move.elastic
        self.submit_ns = move.submit_ns^
        self.wake_age = move.wake_age
        self.thread_base = move.thread_base
        self.thread_cap = move.thread_cap
        self.lane_pops = move.lane_pops^
        self.lane_progress = move.lane_progress^
        self.parallel = move.parallel
        self._parallel_forced = move._parallel_forced

    def set_hold_notify(mut self, fd: Int):
        """Wiring under `--realtime --blocking-threads`: see `hold_notify_fd`."""
        self.hold_notify_fd = fd

    def set_sweep_every_pass(mut self):
        """Pump wiring only: see `sweep_every_pass`."""
        self.sweep_every_pass = True

    def sweeps_every_pass(self) -> Bool:
        return self.sweep_every_pass

    def enable_stream_channel(mut self) raises:
        """Create the chunk channel: once, by the wiring, before any producer
        thread spawns — an executor, or a `--blocking-threads` pool whose
        threads stream WSGI iterables through the same pair.

        Both ends are non-blocking: the loop must never park in a send,
        and the executor's asyncio loop watches its end with `add_reader`.
        The writers therefore need the retry-with-yield policy
        (`send_stream_chunk`) rather than blocking — a dropped chunk is a
        corrupt body, so it may not use the bus's drop-on-EAGAIN policy.

        The executor's base drain-ack pair is `enable_base_stream_ack`,
        deliberately separate: `stream_active()` means "an executor
        exists", and a pool server that streams must not look like one —
        `slot_is_executor`'s unmounted shortcut would otherwise turn every
        `M0-Hold` on the default topology into a chunk-framed stream.
        """
        var chunks = socketpair_dgram()
        self.stream_chunk_read = chunks[0]
        self.stream_chunk_write = chunks[1]
        for fd in [self.stream_chunk_read, self.stream_chunk_write]:
            _size_socket(fd)
            _set_nonblocking_fd(fd)

    def enable_base_stream_ack(mut self) raises:
        """The unmounted executor's drain-ack pair. Executor wiring only,
        after `enable_stream_channel`; this is what flips `stream_active`."""
        var acks = socketpair_dgram()
        self.stream_ack_read = acks[0]
        self.stream_ack_write = acks[1]
        for fd in [self.stream_ack_read, self.stream_ack_write]:
            _size_socket(fd)
            _set_nonblocking_fd(fd)

    def stream_active(self) -> Bool:
        """Whether an asyncio executor serves this loop (its base ack pair
        exists). NOT whether the chunk channel does — see `chunk_active`."""
        return self.stream_ack_write >= 0

    def chunk_active(self) -> Bool:
        """Whether the chunk channel exists: an executor or a streaming pool
        may be producing on it. What gates the loop's drain acks."""
        return self.stream_chunk_write >= 0

    def send_stream_chunk(self, frame: Span[Byte, _]) -> Bool:
        """One bus-shaped chunk datagram, executor side. Returns whether it went.

        Bounded retry, never a wait: this runs on the executor thread, which
        is ATTACHED to the interpreter here, so blocking would hold the GIL
        against the very loop thread that has to drain this channel — the
        deadlock is worse than the drop, measured.

        A drop IS corruption (a short body under a clean terminator), so the
        real defence is upstream: the shim's global in-flight budget
        (`_ASGI_TOTAL_WINDOW`) keeps the sum of every stream's outstanding
        bytes under this channel's capacity, where per-stream credit alone
        did not — 12 concurrent WhiteNoise static files under Django were
        enough to overflow it (docs/REAL_APP_VALIDATION.md, 2026-08-26).
        The False return is the last resort, and `_pump_events` says so on
        stdout rather than letting a truncated body look like a good one.
        """
        for _ in range(64):
            try:
                _ = send(
                    FileDescriptor(self.stream_chunk_write),
                    frame, UInt(len(frame)), 0,
                )
                return True
            except:
                _sched_yield()
        return False

    def enable_stream_ack(mut self, lane: Int) raises:
        """A private drain-ack pair for `lane`'s executor.

        Called once per ASGI lane by the wiring, after `add_lane` and
        before that lane's executor thread spawns. Both ends non-blocking,
        exactly as `enable_stream_channel` sets up the base pair — the
        loop must never park in a send, and the executor's asyncio loop
        watches the read end with `add_reader`."""
        var pair = socketpair_dgram()
        _size_socket(pair[0])
        _size_socket(pair[1])
        _set_nonblocking_fd(pair[0])
        _set_nonblocking_fd(pair[1])
        self.lane_ack_read[lane] = pair[0]
        self.lane_ack_write[lane] = pair[1]

    def ack_read_fd(self, lane: Int) -> Int:
        """The ack read end `lane`'s executor watches; the base pair when
        the lane never got its own (the unmounted executor)."""
        if (
            lane >= 0
            and lane < len(self.lane_ack_read)
            and self.lane_ack_read[lane] >= 0
        ):
            return self.lane_ack_read[lane]
        return self.stream_ack_read

    def send_ws_message(
        self, lane: Int, slot: Int, opcode: Int, channel: String,
        payload: Span[Byte, _],
    ) -> Bool:
        """Hand one inbound WebSocket message to `lane`'s pool threads.

        The loop's side of `TAG_WS_MESSAGE`. Bounded retry and never a park:
        this runs on the event loop, and a lost message is an application-
        visible gap rather than a corrupt one — the caller says so.

        Refuses a datagram larger than the buffer `next_job` reads into,
        for the reason that function's `recv` cannot help with: the read
        passes no `MSG_TRUNC`, so an oversized datagram is delivered
        truncated and the short count is indistinguishable from a short
        message. `m0_wsgi.handler` has a second copy of this encoder with
        the same check; a bound in one copy and not the other is not a
        bound."""
        var chan = channel.as_bytes()
        if _WS_HEADER + len(chan) + len(payload) > WS_DATAGRAM_MAX:
            return False
        var msg = List[UInt8](capacity=_WS_HEADER + len(chan) + len(payload))
        msg.append(TAG_WS_MESSAGE)
        var bits = UInt64(Int64(slot))
        for shift in range(0, 64, 8):
            msg.append(UInt8((bits >> UInt64(shift)) & 0xFF))
        msg.append(UInt8(opcode))
        msg.append(UInt8(len(chan) & 0xFF))
        msg.append(UInt8((len(chan) >> 8) & 0xFF))
        for b in chan:
            msg.append(b)
        for b in payload:
            msg.append(b)
        var fd = self.submit_write_fd(lane)
        for _ in range(64):
            try:
                _ = send(FileDescriptor(fd), Span(msg), UInt(len(msg)), 0)
                # A thread parked on its own channel is not watching the
                # lane socket; wake the most recently parked one, which
                # polls the socket first thing. No parked thread means a
                # spinner or a busy one polls it within
                # `POOL_DGRAM_POLL_NS`, as before.
                _ = self._wake_registered(lane)
                return True
            except:
                _sched_yield()
        return False

    def slot_is_executor(self, slot: Int) -> Bool:
        """Whether an asyncio executor produced this slot's response.

        The loop treats an executor's stream differently from a held one —
        chunk framing, drain acks, and the suppressed comment heartbeat all
        belong to the executor and none of them to an `M0-Hold`. Asking
        globally (`stream_active()`) was the same question only while the
        two could not share a process; under `--realtime --mount` they do,
        and a held stream that got chunk-framed, acked to an executor that
        never issued the credit, and denied its heartbeat would be three
        wrong answers at once.

        The lane is the answer and it is already recorded: `submit` stamps
        `slot_lane[slot]`, and a lane has a drain-ack pair exactly when an
        executor serves it. Unmounted, the executor is the only producer
        there is."""
        var lane = (
            self.slot_lane[slot]
            if slot >= 0 and slot < len(self.slot_lane) else 0
        )
        return self.lane_is_executor(lane)

    def lane_is_executor(self, lane: Int) -> Bool:
        """Whether an asyncio executor is what reads `lane`'s submit channel
        — the lane-only body of `slot_is_executor`, for a caller that has
        the lane and not yet a slot (the loop, deciding whether to batch a
        submit). Unmounted, the executor is the only producer there is."""
        if not self.stream_active():
            return False
        if len(self.lane_prefixes) == 0:
            return True
        return lane < len(self.lane_ack_write) and self.lane_ack_write[lane] >= 0

    def slot_channel_stream(self, slot: Int) -> Bool:
        """Whether this slot's stream rides the chunk channel — from an
        executor OR from a pool thread streaming a WSGI iterable.

        The loop's four stream decisions (chunk framing, drain acks, the
        suppressed comment heartbeat, end-of-stream) belong to a channel
        stream and none of them to an `M0-Hold`. The pool thread's mark is
        per SLOT (`slot_ack_fd`, set by the thread before its begin frame
        and cleared by the loop when the stream ends); the executor's is
        per lane, as before."""
        if not self.chunk_active():
            return False
        if slot >= 0 and slot < len(self.slot_ack_fd) and self.slot_ack_fd[slot] >= 0:
            return True
        return self.slot_is_executor(slot)

    def set_slot_ack_fd(mut self, slot: Int, fd: Int):
        """A pool thread's registration, made BEFORE its begin frame goes out
        so the frame's send publishes it. See `slot_ack_fd`."""
        if slot >= 0 and slot < len(self.slot_ack_fd):
            self.slot_ack_fd[slot] = fd

    def clear_slot_ack_fd(mut self, slot: Int):
        """The loop's half: at accept and wherever a stream ends."""
        if slot >= 0 and slot < len(self.slot_ack_fd):
            self.slot_ack_fd[slot] = -1

    def abort_stream(self, slot: Int, gen: Int) -> Bool:
        """Tell the loop that generation `gen` of `slot`'s stream died after
        its head: close without a terminator. Producer side, either kind.

        Retried like `complete`, and for the same reason: an abort that is
        lost is a connection the loop keeps waiting on for an end frame
        that will never come. Returns whether it went."""
        var msg = List[UInt8](capacity=_ABORT_BYTES)
        msg.append(TAG_STREAM_ABORT)
        var s = UInt64(Int64(slot))
        for shift in range(0, 64, 8):
            msg.append(UInt8((s >> UInt64(shift)) & 0xFF))
        var g = UInt64(Int64(gen))
        for shift in range(0, 64, 8):
            msg.append(UInt8((g >> UInt64(shift)) & 0xFF))
        for _ in range(64):
            try:
                _ = send(
                    FileDescriptor(self.complete_write),
                    Span(msg), UInt(len(msg)), 0,
                )
                return True
            except:
                _sched_yield()
        return False

    def take_aborts(mut self) -> List[Int]:
        """The `(slot, gen)` pairs the last `drain_completions` found,
        flattened `[slot, gen, slot, gen, ...]`; empties the list."""
        var out = self.aborts^
        self.aborts = List[Int]()
        return out^

    def ack_stream(self, slot: Int, bytes_flushed: Int) -> Bool:
        """One drain-ack datagram, loop side: `(slot: i32, bytes: i32)` LE.

        Called after a streaming slot's buffer fully lands in the kernel;
        the executor replenishes that slot's credit by `bytes_flushed`.
        Retried like `complete` — bounded, because the LOOP must never park
        in a send: the executor reads acks on its asyncio loop, and it may be
        blocked at that moment in `send_stream_chunk` waiting for this loop
        to drain — a loop that waited on it here would be a deadlock. So
        this returns False when the channel would not take the ack, and the
        loop keeps the credit owed (`OffloadLoopState.ack_owed`) and retries
        it on later passes. A lost ack is a window that never refills and a
        `send()` that awaits forever, which is why it is never dropped.

        Routed by `slot_lane`: with several executors the ack must reach
        the one that owns the slot, because credit sent anywhere else
        stalls the stream forever — the owner's window never refills, and
        the shim's `send()` awaits it with no timeout."""
        var lane = (
            self.slot_lane[slot]
            if slot >= 0 and slot < len(self.slot_lane) else 0
        )
        var ack_fd = self.stream_ack_write
        if slot >= 0 and slot < len(self.slot_ack_fd) and self.slot_ack_fd[slot] >= 0:
            # A pool thread's stream: credit goes to THAT thread's pair,
            # never to a lane, since N threads share one.
            ack_fd = self.slot_ack_fd[slot]
        elif lane < len(self.lane_ack_write) and self.lane_ack_write[lane] >= 0:
            ack_fd = self.lane_ack_write[lane]
        var msg = List[UInt8](capacity=8)
        var s = UInt32(slot)
        var b = UInt32(bytes_flushed)
        for i in range(4):
            msg.append(UInt8((s >> UInt32(8 * i)) & 0xFF))
        for i in range(4):
            msg.append(UInt8((b >> UInt32(8 * i)) & 0xFF))
        for _ in range(64):
            try:
                _ = send(
                    FileDescriptor(ack_fd),
                    Span(msg), UInt(len(msg)), 0,
                )
                return True
            except:
                _sched_yield()
        return False

    def addr(mut self) -> Int:
        """This pool's address, for `run_event_loop` and the thread blocks."""
        var p = Pointer(to=self)
        return Pointer(to=p).unsafe_bitcast[Int]()[]

    # --- the ring handoff ---------------------------------------------------

    def _new_lane_ring(self) -> Ring:
        """A ring for the lane about to be appended, or a disabled one when
        rings are off or the wake block has no line left for it."""
        if self.ring_enabled and len(self.job_rings) < _WAKE_MAX_LANES:
            return Ring(OFFLOAD_MAX_INFLIGHT)
        return Ring()

    def _ring_for(self, lane: Int) -> Ring:
        """`lane`'s job ring; disabled when the lane has none."""
        var at = lane if lane > 0 else 0
        if at < len(self.job_rings):
            return self.job_rings[at].copy()
        return Ring()

    def _parked_addr(self, lane: Int) -> Int:
        var at = lane if lane > 0 else 0
        return self.wake_base + _WAKE_LANE_BASE + at * _WAKE_LANE_STRIDE

    def _poll_addr(self, lane: Int) -> Int:
        return self._parked_addr(lane) + 8

    def _wakes_addr(self, lane: Int) -> Int:
        return self._parked_addr(lane) + 16

    def _spinners_addr(self, lane: Int) -> Int:
        return self._parked_addr(lane) + 24

    def _threads_addr(self, lane: Int) -> Int:
        return self._parked_addr(lane) + 32

    def _aged_wakes_addr(self, lane: Int) -> Int:
        return self._parked_addr(lane) + 40

    def _idle_wakes_addr(self, lane: Int) -> Int:
        return self._parked_addr(lane) + 48

    def _parked_reg_addr(self, lane: Int) -> Int:
        return self._parked_addr(lane) + 56

    def _rec(self, thread: Int) -> Int:
        """Registered thread `thread`'s record (see `_THREAD_STRIDE`)."""
        return self.thread_base + thread * _THREAD_STRIDE

    def reserve_threads(mut self, n: Int):
        """Room for `n` pool threads to register a wake channel each.

        Called ONCE by whoever spawns the threads (`BlockingPool.start`),
        before any of them starts: the records are handed out by an
        atomic counter, but the block itself is allocated here, on the
        spawning thread. Inert without the elastic rules — there the
        threads park on the lane socket, as they always did."""
        if not self.elastic or n <= 0 or self.thread_base != 0:
            return
        var bytes = _THREAD_STRIDE * n
        self.thread_base = external_call["malloc", Int, Int](bytes)
        for w in range(bytes // 8):
            atomic_at(self.thread_base + w * 8)[] = Atomic[DType.int64](0)
        for t in range(n):
            atomic_at(self._rec(t) + _TR_LANE)[].store(-1)
            atomic_at(self._rec(t) + _TR_READ)[].store(-1)
            atomic_at(self._rec(t) + _TR_WRITE)[].store(-1)
        self.thread_cap = n

    def register_thread(mut self, lane: Int) -> Int:
        """A pool thread announcing itself on `lane`: counts it
        (`note_thread`) and, when a record was reserved, gives it a wake
        channel of its own — returns the thread id to pass to `next_job`,
        or -1 when it must park on the lane socket instead (no reservation,
        the reservation exhausted, the pair refused, or the rules off).

        The read end stays blocking (the thread parks in it, detached);
        the write end is non-blocking, because the loop pokes it and must
        never park. Two datagrams at most ever sit in it — one wake, one
        pill — so the default buffer is plenty. The lane word is stored
        LAST: it is what `_wake_registered` and `stop` test, so the record
        is published whole."""
        var at = lane if lane > 0 else 0
        self.note_thread(at, 1)
        if self.thread_cap == 0:
            return -1
        var t = Int(atomic_at(self.wake_base + _WAKE_THREADS)[].fetch_add(1))
        if t >= self.thread_cap:
            return -1
        var pair: Tuple[Int, Int]
        try:
            pair = socketpair_dgram()
        except:
            return -1
        _set_nonblocking_fd(pair[1])
        var rec = self._rec(t)
        atomic_at(rec + _TR_READ)[].store(Int64(pair[0]))
        atomic_at(rec + _TR_WRITE)[].store(Int64(pair[1]))
        atomic_at(rec + _TR_STATE)[].store(Int64(_TS_RUNNING))
        atomic_at(rec + _TR_SEQ)[].store(0)
        atomic_at(rec + _TR_PILL)[].store(0)
        atomic_at(rec + _TR_LANE)[].store(Int64(at))
        return t

    def unregister_thread(self, thread: Int, lane: Int):
        """The thread is leaving: uncount it, and retire its record so
        `stop` and the wake scan skip it. Its channel stays open for the
        process's life, like every other descriptor here."""
        var at = lane if lane > 0 else 0
        self.note_thread(at, -1)
        if thread >= 0 and thread < self.thread_cap:
            atomic_at(self._rec(thread) + _TR_LANE)[].store(-2)

    def registered_threads(self) -> Int:
        """Records handed out so far (never more than reserved). Test
        surface."""
        if self.thread_cap == 0:
            return 0
        var n = Int(atomic_at(self.wake_base + _WAKE_THREADS)[].load())
        return n if n < self.thread_cap else self.thread_cap

    def _wake_registered(self, lane: Int) -> Bool:
        """Wake the thread of `lane` that parked most recently, on its own
        channel: PARKED to WOKEN by compare-exchange, so a thread that took
        a job for itself in the same instant is not poked twice and no
        other thread is poked for it. Retires the thread's parked count
        here, on the waker's side, so a burst into a lane where one thread
        has just been woken is NOT all idle (`_all_idle`) and wakes nobody
        else: that thread takes the burst, which is the one-thread shape.
        False when no registered thread of the lane is parked."""
        if self.thread_cap == 0:
            return False
        var n = self.registered_threads()
        var best = -1
        var best_seq = Int64(-1)
        for t in range(n):
            var rec = self._rec(t)
            if atomic_at(rec + _TR_LANE)[].load() != Int64(lane):
                continue
            if atomic_at(rec + _TR_STATE)[].load() != Int64(_TS_PARKED):
                continue
            var seq = atomic_at(rec + _TR_SEQ)[].load()
            if seq > best_seq:
                best = t
                best_seq = seq
        if best < 0:
            return False
        var rec = self._rec(best)
        var expected = Int64(_TS_PARKED)
        if not atomic_at(rec + _TR_STATE)[].compare_exchange(
            expected, Int64(_TS_WOKEN)
        ):
            return False
        _ = atomic_at(self._parked_reg_addr(lane))[].fetch_add(-1)
        self._poke(Int(atomic_at(rec + _TR_WRITE)[].load()))
        return True

    def _recv_own(self, thread: Int, mut buf: List[UInt8], flags: c_int) -> Int:
        """One datagram off `thread`'s own channel: `_OWN_POKE`,
        `_OWN_PILL`, `_OWN_NONE` (nothing, non-blocking) or `_OWN_DEAD`."""
        var fd = FileDescriptor(Int(atomic_at(self._rec(thread) + _TR_READ)[].load()))
        while True:
            var n: UInt
            try:
                n = recv(fd, Span(buf), UInt(_JOB_BYTES), flags)
            except recv_err:
                if recv_err.isa[RecvEINTRError]():
                    if flags != 0:
                        return _OWN_NONE
                    continue
                if recv_err.isa[RecvEAGAINError]():
                    return _OWN_NONE
                return _OWN_DEAD
            if n != UInt(_JOB_BYTES):
                return _OWN_DEAD
            return _OWN_PILL if _decode_job(Span(buf)) == _POISON else _OWN_POKE

    def _park_on_own(
        self, lane: Int, thread: Int, ring: Ring, mut buf: List[UInt8]
    ) -> PoolJob:
        """Park `thread` on its own channel until woken. The job it finds
        on the announce-then-re-check, the pill (`JOB_STOP`), or
        `JOB_NONE` for a wake — the caller then looks at the lane socket
        and the ring again.

        Announce (sequence, state, count), re-check the ring, block. The
        re-check races the loop's `_wake_registered`, and the state word
        settles it: whoever moves it off PARKED first owns the transition
        and retires the parked count. If the loop won, its poke is in
        flight for THIS thread and is consumed here, so the channel holds
        nothing stale at the next park; a pill read in that position is
        remembered (`_TR_PILL`) and answered at the next call, after the
        job in hand."""
        var rec = self._rec(thread)
        var state = atomic_at(rec + _TR_STATE)
        var parked_reg = atomic_at(self._parked_reg_addr(lane))
        var seq = atomic_at(self.wake_base + _WAKE_SEQ)[].fetch_add(1) + 1
        atomic_at(rec + _TR_SEQ)[].store(seq)
        state[].store(Int64(_TS_PARKED))
        _ = parked_reg[].fetch_add(1)
        var slot = 0
        if ring.pop(slot):
            var expected = Int64(_TS_PARKED)
            if state[].compare_exchange(expected, Int64(_TS_RUNNING)):
                _ = parked_reg[].fetch_add(-1)
            else:
                if self._recv_own(thread, buf, 0) == _OWN_PILL:
                    atomic_at(rec + _TR_PILL)[].store(1)
                state[].store(Int64(_TS_RUNNING))
            return PoolJob(JOB_REQUEST, slot, 0, 0, 0, 0, 0)
        var got = self._recv_own(thread, buf, 0)
        var expected = Int64(_TS_PARKED)
        if state[].compare_exchange(expected, Int64(_TS_RUNNING)):
            # A pill found us parked (or the channel died): nobody
            # retired the count, so this thread does.
            _ = parked_reg[].fetch_add(-1)
        else:
            state[].store(Int64(_TS_RUNNING))
        if got == _OWN_PILL or got == _OWN_DEAD:
            return PoolJob(JOB_STOP, _POISON, 0, 0, 0, 0, 0)
        return _none_job()

    def wake_age_ns(self) -> Int:
        """See `wake_age`."""
        return self.wake_age

    def set_parallel(mut self, flag: Bool):
        """The wiring's answer to "is this interpreter free-threaded?"
        (`probe_free_threading`; the threaded mode is by construction).
        See `parallel`. The knob, when set, wins."""
        if self._parallel_forced < 0:
            self.parallel = flag

    def is_parallel(self) -> Bool:
        """See `parallel`."""
        return self.parallel

    def wake_counts(self, lane: Int) -> Tuple[Int, Int]:
        """`(aged, idle)`: wakes `wake_aged` sent, and wakes `submit` sent
        into an all-parked lane, since the pool was built. A measurement
        surface (the note's rotation-versus-cascade question), not a
        protocol word."""
        if not self.ring_enabled:
            return (0, 0)
        return (
            Int(atomic_at(self._aged_wakes_addr(lane))[].load()),
            Int(atomic_at(self._idle_wakes_addr(lane))[].load()),
        )

    def elastic_active(self) -> Bool:
        """Whether the elastic wake rules are in force (see `elastic`)."""
        return self.elastic

    def spinner_count(self, lane: Int) -> Int:
        """Threads of `lane` spinning idle on an empty ring. Test surface;
        at most one under the elastic rules."""
        if not self.ring_enabled:
            return 0
        return Int(atomic_at(self._spinners_addr(lane))[].load())

    def note_spinning(self, lane: Int, delta: Int):
        """Adjust `lane`'s idle-spinner count. `next_job` does this itself;
        a test does it to stand in for a spinning sibling."""
        if self.ring_enabled:
            _ = atomic_at(self._spinners_addr(lane))[].fetch_add(Int64(delta))

    def thread_count(self, lane: Int) -> Int:
        """Threads serving `lane`, as they announced themselves."""
        if not self.ring_enabled:
            return 0
        return Int(atomic_at(self._threads_addr(lane))[].load())

    def note_thread(self, lane: Int, delta: Int):
        """A pool thread announcing itself on `lane` (+1 at start, -1 when
        it leaves). What lets `submit` tell "every thread is parked" from
        "a thread is busy in a view": busy is `threads - parked -
        spinners`. A lane nobody announced on (a test driving `next_job`
        by hand) reads as all idle, which is the eager rule."""
        if self.ring_enabled:
            _ = atomic_at(self._threads_addr(lane))[].fetch_add(Int64(delta))

    def _all_idle(self, lane: Int) -> Bool:
        """Whether no thread of `lane` is busy or spinning: nobody will
        take a pushed job unless woken. Three words read one after
        another, and the snapshot may straddle a thread's own transition —
        which is safe, because every transition into spinning or parking
        re-checks the ring AFTER announcing itself (`next_job`), and a
        push precedes the loop's reads here."""
        if atomic_at(self._spinners_addr(lane))[].load() > 0:
            return False
        var parked = (
            atomic_at(self._parked_addr(lane))[].load()
            + atomic_at(self._parked_reg_addr(lane))[].load()
        )
        return atomic_at(self._threads_addr(lane))[].load() <= parked

    def _wake_one(self, lane: Int) -> Bool:
        """One wake to `lane`: the most recently parked registered thread
        on its own channel (`_wake_registered`), else — for threads parked
        on the lane socket — one poke there if a parked thread is not
        already owed one. The rule every poke site shares. Returns whether
        a wake was sent."""
        if self._wake_registered(lane):
            return True
        var wakes = atomic_at(self._wakes_addr(lane))
        if atomic_at(self._parked_addr(lane))[].load() > wakes[].load():
            _ = wakes[].fetch_add(1)
            self._poke(self.submit_write_fd(lane))
            return True
        return False

    def jobs_pending(self) -> Bool:
        """Whether any lane's ring holds a job no thread has taken. What
        bounds the loop's wait (`POOL_WAKE_WAIT_MS`); always False under
        the eager rules, where a pending job already has its wake."""
        if not self.elastic:
            return False
        for lane in range(len(self.job_rings)):
            if not self.job_rings[lane].is_empty():
                return True
        return False

    def wake_aged(mut self, now: Int, age_ns: Int) -> Int:
        """The loop's half of the elastic pool, once per pass: for every
        lane whose ring holds a job and has not been drained for longer
        than `age_ns`, wake one parked thread by `_wake_one`'s rule.
        Returns how many were woken.

        This is what replaced the chained wake. A ring nobody is taking
        from holds jobs behind a thread that is not coming back — a slow
        view — and the loop is the one party that sees every lane, every
        pass, and never blocks in a view. A ring whose pop count moved
        since the loop last looked is being drained, however deep, and a
        sibling would only share the GIL with the thread draining it.
        The wait is counted from the later of the head's push and the
        last look that saw the ring move or empty — so a job pushed just
        now into a stuck lane is not aged by the loop's absence, and one
        pushed long ago into a draining lane is not aged by its queue.
        Re-evaluated every pass while the ring stands, so a wake a busy
        thread's socket poll consumed is simply sent again next pass (the
        hole the chain used to fill); `_wake_one`'s cap keeps it to one
        wake per parked thread.

        On a free-threaded interpreter (`parallel`) progress is not the
        question: the head's wait counts from its push, and a ring that
        one thread is draining with a sibling parked beside it gets the
        sibling once the head has waited `age_ns` — two threads on two
        cores is twice the rate there, not twice the GIL waiters."""
        if not self.elastic:
            return 0
        var woken = 0
        for lane in range(len(self.job_rings)):
            ref ring = self.job_rings[lane]
            var pops = ring.pops()
            var slot = 0
            if not ring.peek(slot):
                self.lane_pops[lane] = pops
                self.lane_progress[lane] = now
                continue
            if pops != self.lane_pops[lane]:
                self.lane_pops[lane] = pops
                self.lane_progress[lane] = now
                if not self.parallel:
                    continue
            var since = 0 if self.parallel else self.lane_progress[lane]
            if slot >= 0 and slot < len(self.submit_ns) and self.submit_ns[slot] > since:
                since = self.submit_ns[slot]
            if now - since < age_ns:
                continue
            if self._wake_one(lane):
                _ = atomic_at(self._aged_wakes_addr(lane))[].fetch_add(1)
                woken += 1
        return woken

    def wakes_in_flight(self, lane: Int) -> Int:
        """Wake datagrams sent to `lane` and not yet read. Test surface."""
        if not self.ring_enabled:
            return 0
        return Int(atomic_at(self._wakes_addr(lane))[].load())

    def ring_active(self) -> Bool:
        """Whether jobs and completions ride the rings (else datagrams)."""
        return self.ring_enabled

    def parked_count(self, lane: Int) -> Int:
        """Threads of `lane` parked right now, on the lane socket or on
        their own channel. Test surface."""
        if not self.ring_enabled:
            return 0
        return Int(
            atomic_at(self._parked_addr(lane))[].load()
            + atomic_at(self._parked_reg_addr(lane))[].load()
        )

    def note_parked(self, lane: Int, delta: Int):
        """Adjust `lane`'s parked count. `next_job` does this itself; a test
        does it to stand in for a thread it did not spawn."""
        if self.ring_enabled:
            _ = atomic_at(self._parked_addr(lane))[].fetch_add(Int64(delta))

    def set_loop_parked(self, flag: Bool):
        """The loop's announcement: it is about to wait (True) or is back
        (False). Raise it BEFORE re-checking `done_pending`."""
        if self.ring_enabled:
            atomic_at(self.wake_base)[].store(Int64(1) if flag else Int64(0))

    def loop_parked(self) -> Bool:
        if not self.ring_enabled:
            return False
        return atomic_at(self.wake_base)[].load() != 0

    def done_pending(self) -> Bool:
        """Whether the completion ring holds something for the loop."""
        if not self.ring_enabled:
            return False
        return not self.done_ring.is_empty()

    def _poke(self, fd: Int):
        """One wake datagram on `fd`. Retried like `complete`: a wake that
        never lands is a parked thread that stays parked."""
        var msg = _encode_job(_POKE)
        for _ in range(64):
            try:
                _ = send(FileDescriptor(fd), Span(msg), UInt(len(msg)), 0)
                return
            except:
                _sched_yield()

    def _chain_wake(self, lane: Int, ring: Ring):
        """A thread that just took a job wakes a parked sibling if work
        remains. A wake datagram is a credit for ONE thread, but a thread's
        socket poll can consume a sibling's credit — a thread woken for
        job 1 polls its socket on its way back to the ring and reads the
        wake sent for job 2 — and two jobs then had one thread while the
        other stayed parked, until a busy thread came back for the
        leftover. Measured on Linux as a hold on a pool thread registering
        1.5 s late, behind two slow views (smoke-django-realtime phase 5,
        2026-09-05). Same rule as `submit`'s: at most one wake per parked
        thread, and only while the ring holds something."""
        if ring.is_empty():
            return
        _ = self._wake_one(lane)

    def _recv_datagram(
        self, lane: Int, fd: FileDescriptor, cap: Int, mut buf: List[UInt8],
        flags: c_int,
    ) -> PoolJob:
        """One datagram off a submit lane, decoded.

        `JOB_NONE` when there was nothing to read (non-blocking), the
        datagram was a wake, or its shape is not served here. Blocking when
        `flags` is 0, and EINTR is retried inside — a signal the process
        handled elsewhere (the shutdown pipe) is not a reason to wake.
        """
        while True:
            var n: UInt
            try:
                n = recv(fd, Span(buf), UInt(cap), flags)
            except recv_err:
                if recv_err.isa[RecvEINTRError]():
                    if flags != 0:
                        return _none_job()
                    continue
                if recv_err.isa[RecvEAGAINError]():
                    return _none_job()
                # The channel is unusable, and a thread that cannot receive
                # has nothing left to do.
                return PoolJob(JOB_STOP, _POISON, 0, 0, 0, 0, 0)
            if n == UInt(_JOB_BYTES):
                var slot = _decode_job(Span(buf))
                if slot == _POISON:
                    return PoolJob(JOB_STOP, _POISON, 0, 0, 0, 0, 0)
                if slot == _POKE:
                    if self.ring_enabled:
                        _ = atomic_at(self._wakes_addr(lane))[].fetch_add(-1)
                    return _none_job()
                return PoolJob(JOB_REQUEST, slot, 0, 0, 0, 0, 0)
            if n >= UInt(_WS_HEADER) and buf[0] == TAG_WS_MESSAGE:
                var bits = UInt64(0)
                for i in range(8):
                    bits |= UInt64(buf[1 + i]) << UInt64(i * 8)
                var chan_len = Int(buf[10]) | (Int(buf[11]) << 8)
                var chan_start = _WS_HEADER
                var payload_start = chan_start + chan_len
                if payload_start > Int(n):
                    # A truncated datagram is a bug in the sender, not
                    # something to serve half of.
                    return _none_job()
                return PoolJob(
                    JOB_WS_MESSAGE, Int(Int64(bits)), Int(buf[9]),
                    chan_start, chan_len,
                    payload_start, Int(n) - payload_start,
                )
            if n >= 9 and buf[0] == TAG_JOB_BATCH and (Int(n) - 1) % _JOB_BYTES == 0:
                # A job batch belongs on an executor lane and nowhere else;
                # one here is a sender bug, and skipping it silently would
                # strand every slot it names.
                print(
                    "offload: a job batch reached a pool lane ("
                    + String((Int(n) - 1) // _JOB_BYTES)
                    + " slots) — sender bug; those requests will not be answered",
                    flush=True,
                )
                return _none_job()
            # EOF (0 bytes), or a shape this version does not know.
            if n == 0:
                return PoolJob(JOB_STOP, _POISON, 0, 0, 0, 0, 0)
            return _none_job()

    # --- loop side -------------------------------------------------------

    def park_request(mut self, slot: Int, var request: HTTPRequest):
        """Hand a request to the slot. Call immediately before `submit`.
        Stamps `submit_ns` — the age `wake_aged` measures from."""
        self.requests[slot] = request^
        if self.elastic:
            self.submit_ns[slot] = perf_counter_ns()

    def add_lane(mut self, var prefix: String) raises:
        """Declare a submit lane serving `prefix`; returns nothing, appends.

        Lane 0 reuses the descriptors the constructor already made, so an
        unmounted pool is a one-lane pool with no extra syscalls. Every lane
        after it gets its own `SOCK_DGRAM` pair, set up exactly like lane 0:
        the loop's write end non-blocking so a full queue is visible, the
        worker's read end blocking so a parked worker sleeps.
        """
        if len(self.lane_prefixes) == 0:
            self.lane_prefixes.append(prefix^)
            self.lane_ack_read.append(-1)
            self.lane_ack_write.append(-1)
            return
        var pair = socketpair_dgram()
        _size_socket(pair[0])
        _size_socket(pair[1])
        _set_nonblocking_fd(pair[1])
        self.lane_submit_read.append(pair[0])
        self.lane_submit_write.append(pair[1])
        self.lane_prefixes.append(prefix^)
        self.lane_ack_read.append(-1)
        self.lane_ack_write.append(-1)
        self.job_rings.append(self._new_lane_ring())
        self.lane_pops.append(0)
        self.lane_progress.append(0)

    def submit_read_fd(self, lane: Int) -> Int:
        """The read end a worker for `lane` blocks on."""
        if lane <= 0:
            return self.submit_read
        return self.lane_submit_read[lane - 1]

    def submit_write_fd(self, lane: Int) -> Int:
        if lane <= 0:
            return self.submit_write
        return self.lane_submit_write[lane - 1]

    def lane_for(self, path: String) -> Int:
        """Which lane serves `path`; 0 when this pool has no lane table."""
        if len(self.lane_prefixes) <= 1:
            return 0
        var lane = match_path_prefix(self.lane_prefixes, path)
        return lane if lane >= 0 else 0

    def stamp_lane(mut self, slot: Int, lane: Int):
        """Record which lane `slot`'s job goes to. `submit` does this itself;
        a caller that batches submits (`OffloadLoopState.queue_submit`) does
        it here, at park time, so the record exists before the datagram."""
        if slot >= 0 and slot < len(self.slot_lane):
            self.slot_lane[slot] = lane

    def submit_batch(self, lane: Int, slots: List[Int]) -> Bool:
        """One datagram carrying every slot in `slots` to `lane`'s executor.

        A single slot goes as the legacy 8-byte job. One non-blocking send
        and no retry: the caller owns the policy for a refused batch (the
        loop runs those requests inline, as a refused `submit` always
        meant). Executor lanes only — a pool thread takes one job per read.
        """
        if len(slots) == 0:
            return True
        var msg: List[UInt8]
        if len(slots) == 1:
            msg = _encode_job(slots[0])
        else:
            msg = _encode_job_batch(slots)
        try:
            _ = send(
                FileDescriptor(self.submit_write_fd(lane)),
                Span(msg), UInt(len(msg)), 0,
            )
        except:
            return False
        return True

    def submit(mut self, slot: Int, path: String = String("")) -> Bool:
        """Queue `slot` on the lane serving `path`. False means it is full.

        False is not an error and not a dropped request: the caller runs that
        one request inline instead, which is precisely the behaviour every
        request had before this module existed.

        With rings: push, THEN read the lane's parked count, and poke only
        if it is non-zero — the producer's half of the protocol in the
        module docstring. A thread that is spinning sees the push itself.

        Elastic (the default): poke only if EVERY thread of the lane is
        parked. A busy thread with an empty ring behind it, or the lane's
        idle spinner, takes the job sooner than a wake could land, and a
        wake into a burst of trivial jobs is what put N threads on the
        GIL at once. A busy thread that is NOT coming back soon — a slow
        view — is the loop's age check's case (`wake_aged`). Without a
        GIL (`parallel`) a parked thread is woken whenever there is one.
        """
        var lane = self.lane_for(path)
        self.stamp_lane(slot, lane)
        var ring = self._ring_for(lane)
        if ring.enabled():
            if not ring.push(slot):
                return False
            # A wake per parked thread, not per push: a burst of pushes
            # into N parked threads used to send a poke each until the
            # threads had decremented the count, and every stale poke
            # later cost a parking thread a spin. A thread already owed a
            # wake will drain the ring when it comes.
            # Free-threaded (`parallel`): a parked thread beside this job
            # is an idle core, so wake one whenever there is one.
            if not self.elastic or self.parallel or self._all_idle(lane):
                if self._wake_one(lane):
                    _ = atomic_at(self._idle_wakes_addr(lane))[].fetch_add(1)
            return True
        var job = _encode_job(slot)
        try:
            _ = send(
                FileDescriptor(self.submit_write_fd(lane)),
                Span(job),
                UInt(len(job)),
                0,
            )
        except:
            return False
        return True

    def unpark_request(mut self, slot: Int) -> HTTPRequest:
        """Take a request back after a failed `submit`, to run it inline."""
        return self.requests[slot].take()

    def drain_completions(mut self, read_fd: Bool = True) raises -> List[Int]:
        """`drain_completions_into`, into a fresh list."""
        var done = List[Int]()
        self.drain_completions_into(done, read_fd)
        return done^

    def drain_completions_into(mut self, mut done: List[Int], read_fd: Bool) raises:
        """Every finished slot waiting for the loop, appended to `done`.

        The completion ring first — every pool thread's completions, in
        publish order — then, with `read_fd`, the channel: executor batches,
        stream aborts, and wake datagrams (skipped). The channel's
        registration is edge-triggered, so it is read until EAGAIN — the
        same contract, and the same reason, as `drain_bus_channel`. A
        caller that only wants what is in memory (the loop, at the top and
        bottom of a pass) passes `read_fd=False` and pays no syscall.

        An abort sent after a completion on the ring is handled after it:
        the loop takes the ring's list first, and the datagram was sent
        after the push.
        """
        if self.ring_enabled:
            var slot = 0
            # Bounded by the ring's capacity so producers pushing at full
            # tilt cannot keep the loop here forever.
            var budget = self.done_ring.capacity()
            while budget > 0 and self.done_ring.pop(slot):
                done.append(slot)
                budget -= 1
        if not read_fd:
            return
        # `_drain_buf` is sized for the largest datagram the channel
        # carries — a full completion batch — and not for one completion:
        # a SOCK_DGRAM `recv` into a short buffer silently discards the
        # excess, on both platforms, and a batch decoded short is a slot
        # that never answers.
        comptime cap = OFFLOAD_MAX_INFLIGHT * _JOB_BYTES
        var fd = FileDescriptor(self.complete_read)
        while True:
            var n: UInt
            try:
                n = recv(fd, Span(self._drain_buf), UInt(cap), 0)
            except:
                break  # EAGAIN: drained
            if n == 0:
                break  # EOF
            if n == UInt(_ABORT_BYTES) and self._drain_buf[0] == TAG_STREAM_ABORT:
                var s = UInt64(0)
                var g = UInt64(0)
                for i in range(8):
                    s |= UInt64(self._drain_buf[1 + i]) << UInt64(i * 8)
                    g |= UInt64(self._drain_buf[9 + i]) << UInt64(i * 8)
                self.aborts.append(Int(Int64(s)))
                self.aborts.append(Int(Int64(g)))
                continue
            if n % UInt(_JOB_BYTES) != 0:
                continue  # not a completion; not ours to decode
            var count = Int(n) // _JOB_BYTES
            for i in range(count):
                var got = _decode_job(
                    Span(self._drain_buf)[i * _JOB_BYTES : (i + 1) * _JOB_BYTES]
                )
                if got == _POKE:
                    continue
                done.append(got)

    def take_response(mut self, slot: Int) -> HTTPResponse:
        """Take the response a pool thread parked. Only after its completion."""
        return self.responses[slot].take()

    def has_response(self, slot: Int) -> Bool:
        return Bool(self.responses[slot])

    def raised(self, slot: Int) -> Bool:
        """Whether the pool thread's handler raised. Only after its completion."""
        return self.errored[slot]

    def discard(mut self, slot: Int):
        """Drop whatever is parked — the completion for an abandoned slot."""
        self.requests[slot] = None
        self.responses[slot] = None
        self.errored[slot] = False

    def stop(mut self, threads: Int, lane: Int = 0):
        """Retire the pool: exactly one poison job per thread, then close.

        **The pills are the whole mechanism, and `threads` must equal the
        number of receivers.** `next_job` blocks, and a thread that gets no
        pill blocks forever — which is a hung `pthread_join`, not a slow one.
        `BlockingPool.stop_and_join` is what makes the count structural rather
        than a coincidence between two call sites; prefer it to calling this
        directly.

        The close that follows is NOT a backstop, whatever it looks like. An
        earlier version of this docstring claimed it was, and the claim cost a
        20-minute CI timeout: on Linux, closing the write end of a connected
        AF_UNIX SOCK_DGRAM pair does not wake a peer already blocked in
        `recv`, so a thread that missed its pill stays blocked. macOS returns
        0 and looks fine, which is exactly how the wrong belief survived
        local testing. The close exists to release the descriptor.
        """
        if getenv("M0_POOL_DEBUG", "") != "":
            var counts = self.wake_counts(lane)
            print(
                "pool lane " + String(lane) + ": aged wakes "
                + String(counts[0]) + ", idle wakes " + String(counts[1])
                + ", threads " + String(self.thread_count(lane)),
                flush=True,
            )
        var pill = _encode_job(_POISON)
        # A thread parked on its own channel is not reading the lane
        # socket, so every registered thread of the lane is pilled by
        # name, and the lane socket gets one pill per receiver beyond
        # those — the threads that never registered (a test's, or every
        # thread under the eager rules).
        var pilled = 0
        var at = lane if lane > 0 else 0
        for t in range(self.registered_threads()):
            var rec = self._rec(t)
            if atomic_at(rec + _TR_LANE)[].load() != Int64(at):
                continue
            var own = Int(atomic_at(rec + _TR_WRITE)[].load())
            for _ in range(64):
                try:
                    _ = send(FileDescriptor(own), Span(pill), UInt(len(pill)), 0)
                    break
                except:
                    _sched_yield()
            pilled += 1
        var lane_write = self.submit_write_fd(lane)
        for _ in range(threads - pilled):
            try:
                _ = send(
                    FileDescriptor(lane_write),
                    Span(pill), UInt(len(pill)), 0,
                )
            except:
                pass
        # Only lane 0's descriptor is released here. A lane's write end is
        # the loop's, and the loop outlives this call for the other lanes'
        # workers; the process exit releases them.
        if lane > 0:
            return
        try:
            close(FileDescriptor(self.submit_write))
        except:
            pass
        self.submit_write = -1

    # --- pool side -------------------------------------------------------

    def next_job(mut self, lane: Int, mut buf: List[UInt8], thread: Int = -1) -> PoolJob:
        """Block until there is something for `lane`; decode it into `buf`.

        With rings, the consumer's half of the protocol in the module
        docstring: pop; if nothing, spin for `POOL_SPIN_NS` (yielding past
        `POOL_YIELD_AFTER_NS`), polling the socket non-blocking once per
        `POOL_DGRAM_POLL_NS` for pills and payload datagrams; then count
        this thread parked, pop ONCE MORE, and only then block. A wake
        that arrives there sends the thread back to the ring with a fresh
        spin. Without rings this is the blocking `recv` it always was.

        `thread` is the id `register_thread` returned, or -1. A registered
        thread parks on its OWN channel (`_park_on_own`) and is woken by
        name — the most recently parked thread of the lane first — and
        polls that channel beside the lane socket; a thread without one
        parks on the lane socket, where the kernel picks. Under the
        elastic rules only ONE idle thread per lane spins; the rest park
        at once.

        BLOCKS, and there is no timeout: the only thing that ever ends the
        park is a datagram. A pool thread must therefore detach from the
        interpreter around this call — an attached thread asleep in a
        syscall stalls every other thread's stop-the-world pause — and
        `stop` must send it a pill, because closing the queue will not (see
        `stop`). `m0_wsgi`'s pool body is the only caller and does both.

        `buf` belongs to the caller and is reused for the life of the thread:
        an inbound WebSocket message rides IN the datagram and can be large,
        and allocating for it per job would put that cost on every ordinary
        request too. Its length is the most a datagram may be.
        """
        var fd = FileDescriptor(self.submit_read_fd(lane))
        var cap = len(buf)
        var ring = self._ring_for(lane)
        if not ring.enabled():
            while True:
                var job = self._recv_datagram(lane, fd, cap, buf, 0)
                if job.kind != JOB_NONE:
                    return job^
        var own = thread if thread >= 0 and thread < self.thread_cap else -1
        if own >= 0 and atomic_at(self._rec(own) + _TR_PILL)[].load() != 0:
            # A pill read while this thread held a job: answered now.
            return PoolJob(JOB_STOP, _POISON, 0, 0, 0, 0, 0)
        var parked = atomic_at(self._parked_addr(lane))
        var poll = atomic_at(self._poll_addr(lane))
        var spinners = atomic_at(self._spinners_addr(lane))
        var spin_start = 0
        # Whether THIS thread holds the lane's one idle spin (elastic).
        var spinning = False
        while True:
            # The socket first, on its cadence, whatever the ring holds: a
            # pill or a WebSocket message must not wait behind a ring that
            # a pool-bound load keeps full. One clock read per job; one
            # non-blocking recv per lane per POOL_DGRAM_POLL_NS — and for a
            # registered thread one more on its own channel, where its
            # pill arrives.
            var now = perf_counter_ns()
            if now - Int(poll[].load()) >= POOL_DGRAM_POLL_NS:
                poll[].store(Int64(now))
                if own >= 0:
                    var mine = self._recv_own(own, buf, MSG_DONTWAIT)
                    if mine == _OWN_PILL or mine == _OWN_DEAD:
                        if spinning:
                            _ = spinners[].fetch_add(-1)
                        return PoolJob(JOB_STOP, _POISON, 0, 0, 0, 0, 0)
                var polled = self._recv_datagram(lane, fd, cap, buf, MSG_DONTWAIT)
                if polled.kind != JOB_NONE:
                    if spinning:
                        _ = spinners[].fetch_add(-1)
                    return polled^
            var slot = 0
            if ring.pop(slot):
                if spinning:
                    _ = spinners[].fetch_add(-1)
                if not self.elastic:
                    self._chain_wake(lane, ring)
                return PoolJob(JOB_REQUEST, slot, 0, 0, 0, 0, 0)
            var park_now = False
            if spin_start == 0:
                spin_start = now
                if self.elastic:
                    # One idle spinner per lane. Announce, then re-check
                    # (the `continue` pops again): the spinner sees every
                    # push itself, so `submit` never wakes anyone while
                    # one exists — and the spin is what makes a park
                    # rare, not free. A second idle thread spinning
                    # beside it would only burn a core; it parks at once.
                    if spinners[].fetch_add(1) == 0:
                        spinning = True
                    else:
                        _ = spinners[].fetch_add(-1)
                        park_now = True
                if not park_now:
                    continue
            if park_now or now - spin_start >= POOL_SPIN_NS:
                # Announce, re-check, block — in that order, or a push that
                # lands between the last pop and the recv is a job nobody
                # is woken for. The spin is given up BEFORE the park is
                # announced, so `_all_idle` never counts this thread as
                # both, and its re-check below follows both stores.
                if spinning:
                    _ = spinners[].fetch_add(-1)
                    spinning = False
                if own >= 0:
                    var mine = self._park_on_own(lane, own, ring, buf)
                    if mine.kind != JOB_NONE:
                        return mine^
                    # Woken by name: the lane socket may hold what the
                    # loop woke us for (a WebSocket message), so it is
                    # polled first thing, and the ring looked at again.
                    poll[].store(0)
                    spin_start = 0
                    continue
                _ = parked[].fetch_add(1)
                if ring.pop(slot):
                    _ = parked[].fetch_add(-1)
                    if not self.elastic:
                        self._chain_wake(lane, ring)
                    return PoolJob(JOB_REQUEST, slot, 0, 0, 0, 0, 0)
                var woke = self._recv_datagram(lane, fd, cap, buf, 0)
                _ = parked[].fetch_add(-1)
                if woke.kind != JOB_NONE:
                    return woke^
                # A wake: the job is on the ring (or was taken by a sibling
                # meanwhile); look again with a fresh spin.
                spin_start = 0
                continue
            if now - spin_start >= POOL_YIELD_AFTER_NS:
                _sched_yield()

    def take_request(mut self, slot: Int) -> HTTPRequest:
        """Take the parked request. Only for a slot this thread received."""
        return self.requests[slot].take()

    def put_response(mut self, slot: Int, var response: HTTPResponse, raised: Bool = False):
        """Park the response. Call immediately before `complete`."""
        self.responses[slot] = response^
        self.errored[slot] = raised

    def complete(self, slot: Int):
        """Tell the loop that `slot` is finished.

        With rings: push onto the completion ring, THEN read the loop's
        parked flag, and poke the channel only if it is set — the
        producer's half of the protocol in the module docstring. A loop in
        the middle of a pass finds the completion at the pass's bottom.

        Retried rather than dropped, either way: a lost completion is a
        connection that never answers and a slot that is never released,
        which is a hang rather than a slow request. Neither can actually
        fill — at most `OFFLOAD_MAX_INFLIGHT` completions exist at once and
        both are sized for them — so the retry is a backstop, not a spin.
        """
        if self.ring_enabled:
            for _ in range(64):
                if self.done_ring.push(slot):
                    break
                _sched_yield()
            if atomic_at(self.wake_base)[].load() != 0:
                self._poke(self.complete_write)
            return
        var msg = _encode_job(slot)
        for _ in range(64):
            try:
                _ = send(
                    FileDescriptor(self.complete_write),
                    Span(msg), UInt(len(msg)), 0,
                )
                return
            except:
                _sched_yield()

    def complete_many(self, slots: List[Int]) -> Bool:
        """Tell the loop that every slot in `slots` is finished — one datagram.

        The executor's `complete`: it parks N responses over a pump pass and
        pokes the loop once for all of them, so the loop wakes per pass
        rather than per response. Every `put_response` of the pass precedes
        this one send, so park-then-poke holds for all N at once. Returns
        whether it went; the caller keeps the slots and retries, never drops
        — a lost completion is a connection that never answers.
        """
        if len(slots) == 0:
            return True
        var msg = _encode_completions(slots)
        for _ in range(64):
            try:
                _ = send(
                    FileDescriptor(self.complete_write),
                    Span(msg), UInt(len(msg)), 0,
                )
                return True
            except:
                _sched_yield()
        return False


def make_stream_ack_pair() raises -> Tuple[Int, Int]:
    """A pool thread's own drain-ack pair: `(read_end, write_end)`.

    The READ end stays blocking — the thread sleeps on it (detached) while
    it waits for credit — and the WRITE end is non-blocking, because the
    loop sends on it and must never park. Sized like every other channel
    here. Created once per thread and kept for the process's life: the raw
    fd number travels in the thread's begin frames, and a closed-and-reused
    number would let a stale disconnect land in a client's TCP stream.
    """
    var pair = socketpair_dgram()
    _size_socket(pair[0])
    _size_socket(pair[1])
    _set_nonblocking_fd(pair[1])
    return (pair[0], pair[1])


def drain_ack_fd(fd: Int):
    """Discard every datagram waiting on an ack read end, without blocking.

    A pool thread calls this before each stream's begin frame: the previous
    stream's final ack — and its disconnect, if the client vanished — may
    still be queued, and either would be misread as credit or as an early
    disconnect for the stream about to start.
    """
    var buf = List[UInt8](capacity=8)
    for _ in range(8):
        buf.append(0)
    for _ in range(4096):
        try:
            var n = recv(FileDescriptor(fd), Span(buf), UInt(8), MSG_DONTWAIT)
            if n == 0:
                return
        except:
            return


def _none_job() -> PoolJob:
    return PoolJob(JOB_NONE, -1, 0, 0, 0, 0, 0)


def _sched_yield():
    _ = external_call["sched_yield", c_int]()


def _set_nonblocking_fd(fd: Int):
    """`O_NONBLOCK` on a raw descriptor, best effort."""
    try:
        set_nonblocking(FileDescriptor(fd))
    except:
        pass


struct OffloadLoopState(Movable):
    """The loop's side of the pool: the pool's address and two slot arrays.

    One parameter instead of four threaded through `_handle_read_headers`,
    `_process_request` and `_finish_response`. `addr == 0` means the server was
    started without `--blocking-threads`, and every method below is then inert —
    the loop runs handlers itself exactly as it always has.
    """

    var addr: Int
    """Address of the caller-owned `OffloadPool`, or 0 when disabled."""

    var offloaded: List[Bool]
    """Slot has a job in a pool thread: the loop must not touch it."""

    var is_head: List[Bool]
    """The parked request was a HEAD — the loop strips the body at finish,
    and by then the request itself belongs to the pool thread."""

    var http11: List[Bool]
    """The request was HTTP/1.1. Recorded for the same reason `is_head` is:
    the framing decision happens at finish, when the request may already
    belong to a pool thread. Chunked transfer-encoding is 1.1-only, so an
    HTTP/1.0 stream stays close-delimited."""

    var chunked: List[Bool]
    """This slot's streaming response is framed `Transfer-Encoding: chunked`.

    Set at finish, read by the outbox drain, and only ever consulted while
    the slot is streaming. Written unconditionally for every streaming
    response, so a recycled slot cannot inherit a stale True."""

    var ack_payload: List[Int]
    """Payload bytes owed to the producer's credit window once the buffer
    now in flight has landed.

    Carried rather than recomputed because the buffer on the wire is not
    the payload: chunk framing wraps it, and the credit window must count
    what the application produced. Acking wire bytes would hand back more
    credit than was spent on every chunk, and a long stream would grow its
    own window without bound."""

    var ack_owed: List[Int]
    """Credit the ack channel refused to carry (`ack_stream` returned False),
    per slot, to be retried on a later pass. The executor may have been
    unable to read acks at that instant because it was itself waiting for
    this loop to drain its chunks; the loop cannot wait for it — that is the
    deadlock — so it owes the credit instead. Never dropped: a stream whose
    window is short by one ack stalls forever."""

    var ack_owed_count: Int
    """How many slots have `ack_owed > 0`; lets every pass skip the scan."""

    var inflight: Int
    """Jobs submitted and not yet completed. Bounded by OFFLOAD_MAX_INFLIGHT."""

    var stream_gen: List[Int]
    """The generation the head of each slot's current channel stream
    carried (`HTTPResponse.stream_gen`), `STREAM_GEN_NONE` otherwise. What
    an abort datagram is checked against: an abort naming any other
    generation is about a stream this slot no longer serves."""
    var pending_submit: List[List[Int]]
    """Per executor lane, the slots parked this pass and not yet sent.

    The loop submits to an executor at the BOTTOM of a pass, one datagram
    per lane (`TAG_JOB_BATCH`), instead of one `send` per request as it
    parks them: the first of those sends woke the executor while the rest
    were still being sent, so its batches fragmented and both threads
    ping-ponged per request. A slot here is already `offloaded` and counted
    in `inflight`; it is invisible to every sweep exactly as one out on a
    thread is. Never left here across a `wait`: `flush_submits` runs before
    every park of the loop, and what it cannot send runs inline."""

    var pending_submit_count: Int

    var streaming_hint: Int
    """An UPPER BOUND on the slots whose `slot_sse`/`slot_ws` flag is set;
    zero means none is, and the per-pass outbox sweep is skipped.

    Raised by the two sites that set a flag (`_finish_response`), never
    lowered by the many that clear one: the sweep itself recounts what it
    finds and stores that, so a stream that ended is noticed by the next
    sweep and the count decays to zero on its own. Over-approximation
    costs one sweep; an under-count would be a stream nothing drains,
    which is why the clear sites are deliberately left out of it.

    The sweep's miss path — 1024 slots, none streaming — is 1.2 µs per
    pass, and a pass carries one or two requests at low concurrency:
    +3.5% on the Mojo-only hello row and +4% on the inverted executor
    when skipped (SERVER_PERFORMANCE.md, "The outbox sweep"). NOT
    consulted when the pool says `sweeps_every_pass`: see there."""
    var done_scratch: List[Int]
    """`_service_completions`' list of finished slots, reused across
    passes instead of allocated per drain."""

    def __init__(out self, addr: Int, capacity: Int):
        self.addr = addr
        self.inflight = 0
        self.done_scratch = List[Int](capacity=64)
        self.ack_owed_count = 0
        self.streaming_hint = 0
        self.pending_submit = List[List[Int]]()
        self.pending_submit_count = 0
        self.offloaded = List[Bool](capacity=capacity)
        self.is_head = List[Bool](capacity=capacity)
        self.http11 = List[Bool](capacity=capacity)
        self.chunked = List[Bool](capacity=capacity)
        self.ack_payload = List[Int](capacity=capacity)
        self.ack_owed = List[Int](capacity=capacity)
        self.stream_gen = List[Int](capacity=capacity)
        for _ in range(capacity):
            self.offloaded.append(False)
            self.is_head.append(False)
            self.http11.append(False)
            self.chunked.append(False)
            self.ack_payload.append(0)
            self.ack_owed.append(0)
            self.stream_gen.append(STREAM_GEN_NONE)

    def __init__(out self, *, deinit move: Self):
        self.addr = move.addr
        self.offloaded = move.offloaded^
        self.is_head = move.is_head^
        self.http11 = move.http11^
        self.chunked = move.chunked^
        self.ack_payload = move.ack_payload^
        self.ack_owed = move.ack_owed^
        self.ack_owed_count = move.ack_owed_count
        self.inflight = move.inflight
        self.stream_gen = move.stream_gen^
        self.pending_submit = move.pending_submit^
        self.pending_submit_count = move.pending_submit_count
        self.streaming_hint = move.streaming_hint
        self.done_scratch = move.done_scratch^

    def sweep_every_pass(self) -> Bool:
        """`OffloadPool.sweeps_every_pass`, False when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].sweeps_every_pass()

    def queue_submit(mut self, slot: Int, lane: Int) -> Bool:
        """Buffer `slot` for `lane`'s executor. True when the lane's batch is
        full and must be flushed now (`flush_lane`)."""
        var at = lane if lane >= 0 else 0
        while len(self.pending_submit) <= at:
            self.pending_submit.append(List[Int]())
        self.pending_submit[at].append(slot)
        self.pending_submit_count += 1
        return len(self.pending_submit[at]) >= SUBMIT_BATCH_MAX

    def flush_lane(mut self, lane: Int) -> List[Int]:
        """Send `lane`'s buffered slots as one datagram (64 tries with
        yields). Returns the slots it could NOT send, buffer cleared either
        way — the caller runs those inline."""
        var at = lane if lane >= 0 else 0
        var unsent = List[Int]()
        if at >= len(self.pending_submit) or len(self.pending_submit[at]) == 0:
            return unsent^
        var batch = self.pending_submit[at].copy()
        self.pending_submit[at] = List[Int]()
        self.pending_submit_count -= len(batch)
        var sent = False
        for _ in range(64):
            if self.pool()[].submit_batch(lane, batch):
                sent = True
                break
            _sched_yield()
        if not sent:
            unsent = batch^
        return unsent^

    def flush_submits(mut self) -> List[Int]:
        """Every lane's buffered slots, sent; returns the ones that were not."""
        var unsent = List[Int]()
        if self.pending_submit_count == 0:
            return unsent^
        for lane in range(len(self.pending_submit)):
            var failed = self.flush_lane(lane)
            for i in range(len(failed)):
                unsent.append(failed[i])
        return unsent^

    def slot_is_executor(self, slot: Int) -> Bool:
        """`OffloadPool.slot_is_executor`, inert when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].slot_is_executor(slot)

    def slot_channel_stream(self, slot: Int) -> Bool:
        """`OffloadPool.slot_channel_stream`, inert when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].slot_channel_stream(slot)

    def chunk_active(self) -> Bool:
        """`OffloadPool.chunk_active`, inert when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].chunk_active()

    def clear_stream(mut self, slot: Int):
        """Forget a slot's channel stream: its producer's ack fd and its
        generation. The loop's half of the pool-thread handshake — called
        at accept and wherever a stream ends, so a recycled slot cannot
        inherit either."""
        if slot >= 0 and slot < len(self.stream_gen):
            self.stream_gen[slot] = STREAM_GEN_NONE
        if self.enabled():
            self.pool()[].clear_slot_ack_fd(slot)

    def enabled(self) -> Bool:
        return self.addr != 0

    def accepting(self) -> Bool:
        """Whether another job may be submitted, or the loop must run inline."""
        return self.addr != 0 and self.inflight < OFFLOAD_MAX_INFLIGHT

    def pool(self) -> Pointer[OffloadPool, MutUntrackedOrigin]:
        """The caller-owned pool. Only valid when `enabled()`."""
        return Pointer[OffloadPool, MutUntrackedOrigin](unsafe_from_address=self.addr)

    def ring_active(self) -> Bool:
        """`OffloadPool.ring_active`, False when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].ring_active()

    def done_pending(self) -> Bool:
        """`OffloadPool.done_pending`, False when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].done_pending()

    def jobs_pending(self) -> Bool:
        """`OffloadPool.jobs_pending`, False when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].jobs_pending()

    def wake_aged(self, now: Int) -> Int:
        """`OffloadPool.wake_aged` at the pool's threshold, 0 when the
        pool is disabled."""
        if not self.enabled():
            return 0
        ref pool = self.pool()[]
        var age = pool.wake_age_ns()
        return pool.wake_aged(now, age)

    def set_loop_parked(self, flag: Bool):
        """`OffloadPool.set_loop_parked`, inert when the pool is disabled."""
        if self.enabled():
            self.pool()[].set_loop_parked(flag)
