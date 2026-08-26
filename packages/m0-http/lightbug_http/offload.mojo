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
ownership handoff IS the socketpair syscall:

    loop: park_request(slot)  ->  submit(slot)  ~~>  next_job() -> take_request(slot)
    pool: put_response(slot)  ->  complete(slot) ~~>  drain_completions() -> take_response(slot)

`send`/`recv` on a socket cross a kernel lock in both directions, so the
writes before a `submit` are visible to the thread that `recv`s it. Nothing
else is shared: the loop never touches a slot between `submit` and its
completion, and a pool thread never touches one it did not receive.

The slot is also never *recycled* mid-flight. A client that disconnects while
its request is in a pool thread detaches the fd but leaves the provision
borrowed; the completion arrives, finds `slot_fds[slot] == UNUSED`, drops the
response and releases the slot then. A generation counter would detect that
race instead; holding the slot removes it.

## Why SOCK_DGRAM, and why two of them

Datagrams preserve message boundaries, so N pool threads reading one channel
each dequeue exactly one whole job — the kernel is the queue, and there is no
mutex to write. The same reason `broadcast.mojo` chose them, and they now share
`c/socketpair.mojo`. Two channels rather than one bidirectional pair because the loop must be able to register
its receiving end with kqueue/epoll and be woken by it, exactly as it is woken
by a `BroadcastBus` channel; a channel it also *sends* on would wake it with
its own submissions.

Submit is non-blocking on the loop side: a full queue means "the pool is
saturated", and the loop's answer is to run that one request inline rather
than drop it. Completion is best-effort-with-retry on the pool side, because a
dropped completion is a connection that never answers — but it cannot actually
fill, since at most `OFFLOAD_MAX_INFLIGHT` jobs exist at once and the channel
is sized for that many.
"""

from std.collections import Optional
from std.ffi import c_int, external_call

from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.socket import (
    send, recv, close, setsockopt, SocketOption, SOL_SOCKET,
)
from lightbug_http.c.socket_error import RecvEINTRError
from lightbug_http.c.socketpair import socketpair_dgram
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.utils.owning_list import OwningList


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

    var requests: OwningList[Optional[HTTPRequest]]
    var responses: OwningList[Optional[HTTPResponse]]

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
    """The ASGI streaming channel, -1 until `enable_stream_channel` (only
    the asyncio-executor mode calls it). Chunks travel executor→loop as
    bus-shaped datagrams — `stream_chunk_read` is what the wiring passes to
    `run_event_loop` as its `bus_read_fd` — and drain acks travel
    loop→executor as `(slot: i32, bytes: i32)` datagrams, which is what
    makes the producer's `await send(...)` mean something. `stream_active`
    is also the loop's marker that streaming slots are ASGI streams (with
    end-of-stream close and no comment heartbeats), which is sound because
    `--realtime` is refused with every offload mode."""

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

    var capacity: Int

    def __init__(out self, capacity: Int) raises:
        """`capacity == 0` builds a disabled pool: no descriptors, no storage.

        The threaded path constructs one per loop unconditionally, because
        Mojo 1.0's `Optional` wants `ImplicitlyCopyable` and this type is
        deliberately not. A disabled pool costs a struct rather than four
        descriptors per loop; nothing consults it, since the loop is handed
        `offload_addr = 0`.
        """
        # One slot minimum, even for a disabled pool. `OwningList`'s
        # no-argument constructor builds a `Pointer` from address 0, which
        # Mojo 1.0 rejects outright ("Pointer is non-nullable") — and it
        # rejects it at INSTANTIATION, so a `mojo run` or a `--emit
        # shared-lib` that never elaborates the generic body compiles
        # happily and `poe test-all` does not. Reserving one element avoids
        # the constructor entirely; `self.capacity` is what says whether
        # this pool is real, and it is 0 either way.
        self.lane_prefixes = List[String]()
        self.lane_submit_read = List[Int]()
        self.lane_submit_write = List[Int]()
        self.lane_ack_read = List[Int]()
        self.lane_ack_write = List[Int]()
        var slots = capacity if capacity > 0 else 1
        self.slot_lane = List[Int](capacity=slots)
        for _ in range(slots):
            self.slot_lane.append(0)
        self.requests = OwningList[Optional[HTTPRequest]](capacity=slots)
        self.responses = OwningList[Optional[HTTPResponse]](capacity=slots)
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

    def set_hold_notify(mut self, fd: Int):
        """Wiring under `--realtime --blocking-threads`: see `hold_notify_fd`."""
        self.hold_notify_fd = fd

    def enable_stream_channel(mut self) raises:
        """Create the ASGI streaming pairs. Executor wiring only, once,
        before the executor thread spawns.

        All four ends are non-blocking: the loop must never park in a
        send, and the executor's asyncio loop watches its two ends with
        `add_reader`. The writers therefore need the retry-with-yield
        policy (`send_stream_chunk`, `ack_stream`) rather than blocking —
        a dropped chunk is a corrupt body and a dropped ack is a stalled
        stream, so neither may use the bus's drop-on-EAGAIN policy.
        """
        var chunks = socketpair_dgram()
        var acks = socketpair_dgram()
        self.stream_chunk_read = chunks[0]
        self.stream_chunk_write = chunks[1]
        self.stream_ack_read = acks[0]
        self.stream_ack_write = acks[1]
        for fd in [
            self.stream_chunk_read, self.stream_chunk_write,
            self.stream_ack_read, self.stream_ack_write,
        ]:
            _size_socket(fd)
            _set_nonblocking_fd(fd)

    def stream_active(self) -> Bool:
        """Whether the ASGI streaming channel exists (executor mode)."""
        return self.stream_ack_write >= 0

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
        if not self.stream_active():
            return False
        if len(self.lane_prefixes) == 0:
            return True
        var lane = (
            self.slot_lane[slot]
            if slot >= 0 and slot < len(self.slot_lane) else 0
        )
        return lane < len(self.lane_ack_write) and self.lane_ack_write[lane] >= 0

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
        if lane < len(self.lane_ack_write) and self.lane_ack_write[lane] >= 0:
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

    # --- loop side -------------------------------------------------------

    def park_request(mut self, slot: Int, var request: HTTPRequest):
        """Hand a request to the slot. Call immediately before `submit`."""
        self.requests[slot] = request^

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

    def submit(mut self, slot: Int, path: String = String("")) -> Bool:
        """Queue `slot` on the lane serving `path`. False means it is full.

        False is not an error and not a dropped request: the caller runs that
        one request inline instead, which is precisely the behaviour every
        request had before this module existed.
        """
        var job = _encode_job(slot)
        var lane = self.lane_for(path)
        if slot >= 0 and slot < len(self.slot_lane):
            self.slot_lane[slot] = lane
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

    def drain_completions(mut self) raises -> List[Int]:
        """Every finished slot waiting on the channel; empty when none are.

        Registration is edge-triggered, so this reads until EAGAIN — the same
        contract, and the same reason, as `drain_bus_channel`.
        """
        var done = List[Int]()
        var buf = List[UInt8](capacity=_JOB_BYTES)
        for _ in range(_JOB_BYTES):
            buf.append(0)
        var fd = FileDescriptor(self.complete_read)
        while True:
            var n: UInt
            try:
                n = recv(fd, Span(buf), UInt(_JOB_BYTES), 0)
            except:
                break  # EAGAIN: drained
            if n < UInt(_JOB_BYTES):
                break  # EOF, or a truncated datagram that cannot be ours
            done.append(_decode_job(Span(buf)))
        return done^

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
        var pill = _encode_job(_POISON)
        var lane_write = self.submit_write_fd(lane)
        for _ in range(threads):
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

    def next_job(self, lane: Int = 0) -> Int:
        """Block until a job arrives on `lane`. Returns the slot, or -1 to stop.

        BLOCKS, and there is no timeout: the only thing that ever wakes it is
        a datagram. A pool thread must therefore detach from the interpreter
        around this call — an attached thread asleep in a syscall stalls every
        other thread's stop-the-world pause — and `stop` must send it a pill,
        because closing the queue will not (see `stop`). `m0_wsgi`'s pool body
        is the only caller and does both.
        """
        var buf = List[UInt8](capacity=_JOB_BYTES)
        for _ in range(_JOB_BYTES):
            buf.append(0)
        var fd = FileDescriptor(self.submit_read_fd(lane))
        while True:
            var n: UInt
            try:
                n = recv(fd, Span(buf), UInt(_JOB_BYTES), 0)
            except recv_err:
                # EINTR is a signal the process handled elsewhere (the
                # shutdown pipe); go back to sleep. Anything else means the
                # channel is unusable, and a thread that cannot receive has
                # nothing left to do.
                if recv_err.isa[RecvEINTRError]():
                    continue
                return _POISON
            if n < UInt(_JOB_BYTES):
                return _POISON  # EOF: the loop closed the queue
            var slot = _decode_job(Span(buf))
            return slot

    def take_request(mut self, slot: Int) -> HTTPRequest:
        """Take the parked request. Only for a slot this thread received."""
        return self.requests[slot].take()

    def put_response(mut self, slot: Int, var response: HTTPResponse, raised: Bool = False):
        """Park the response. Call immediately before `complete`."""
        self.responses[slot] = response^
        self.errored[slot] = raised

    def complete(self, slot: Int):
        """Tell the loop that `slot` is finished.

        Retried rather than dropped: a lost completion is a connection that
        never answers and a slot that is never released, which is a hang
        rather than a slow request. It cannot actually fill — at most
        `OFFLOAD_MAX_INFLIGHT` completions exist at once and the channel is
        sized for them — so the retry is a backstop, not a spin.
        """
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


    def __init__(out self, addr: Int, capacity: Int):
        self.addr = addr
        self.inflight = 0
        self.ack_owed_count = 0
        self.offloaded = List[Bool](capacity=capacity)
        self.is_head = List[Bool](capacity=capacity)
        self.http11 = List[Bool](capacity=capacity)
        self.chunked = List[Bool](capacity=capacity)
        self.ack_payload = List[Int](capacity=capacity)
        self.ack_owed = List[Int](capacity=capacity)
        for _ in range(capacity):
            self.offloaded.append(False)
            self.is_head.append(False)
            self.http11.append(False)
            self.chunked.append(False)
            self.ack_payload.append(0)
            self.ack_owed.append(0)

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

    def slot_is_executor(self, slot: Int) -> Bool:
        """`OffloadPool.slot_is_executor`, inert when the pool is disabled."""
        if not self.enabled():
            return False
        return self.pool()[].slot_is_executor(slot)

    def enabled(self) -> Bool:
        return self.addr != 0

    def accepting(self) -> Bool:
        """Whether another job may be submitted, or the loop must run inline."""
        return self.addr != 0 and self.inflight < OFFLOAD_MAX_INFLIGHT

    def pool(self) -> Pointer[OffloadPool, MutUntrackedOrigin]:
        """The caller-owned pool. Only valid when `enabled()`."""
        return Pointer[OffloadPool, MutUntrackedOrigin](unsafe_from_address=self.addr)
