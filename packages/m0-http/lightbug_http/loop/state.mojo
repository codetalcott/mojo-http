"""What one event loop owns between passes, and each slot's transitions.

`LoopState` is the loop's state, taken whole by every function of the
loop. Below it is the per-slot lifecycle (review record C4): the
transitions, each owning the resets of its phase, and `_close_slot`, the
one place every close goes through. `_record_response` writes the access
log, which makes this the fork's one module that imports back into
`m0_http` (`m0_http.log`; DECISIONS D33).

The constants the loop's modules share are here too: the timer idents,
`UNUSED`, the WebSocket close linger, and `ACCEPT_BATCH`, which
`LoopState` reads.
"""

from lightbug_http.accept_share import AcceptShare
from lightbug_http.broadcast import BusReader
from lightbug_http.event_loop_backend import EventLoopBackend
from lightbug_http.c.socket import send, close
from lightbug_http.connection import ConnectionState
from lightbug_http.http.date import http_date_from_unix, unix_now
from lightbug_http.http.request import split_server_address
from lightbug_http.io.bytes import Bytes
from lightbug_http.metrics import ServerMetrics
from lightbug_http.offload import OffloadLoopState
from lightbug_http.server import ProvisionPool
from lightbug_http.server_config import ServerConfig
from lightbug_http.service import HTTPService
from lightbug_http.websocket import WSState, close_frame, WS_CLOSE_GOING_AWAY
from std.time import perf_counter_ns
from std.os import getenv
from m0_http.log import LogClock, log_access


# Timer ident offsets to distinguish timeout types from fd-based events.
# fd values are small (typically < 65536), so these offsets avoid collision.
# 0x100000 was the header timer's: header deadlines are swept
# (`_sweep_deadlines`), and nothing arms one.
comptime TIMER_BODY: UInt = 0x200000
comptime TIMER_IDLE: UInt = 0x300000
comptime TIMER_SSE_HEARTBEAT: UInt = 0x400000
comptime TIMER_APP_TICK: UInt = 0x500000

# How long a WebSocket that this side has closed waits for the peer's Close
# reply before the idle sweep reaps it. Bounded because a peer that never
# replies must not hold the slot; two seconds is far past any real round
# trip, and a peer that replies promptly frees the slot in one.
comptime WS_CLOSE_LINGER_NS: Int = 2_000_000_000
# Connections one pass admits, from the listener or from a sibling's
# accept-share channel, AFTER it has served the events of the connections
# it already holds. Admitting runs the connection's eager read, and on a
# loop that calls `func` itself that read is the whole request, so a
# drain to EAGAIN held every established connection behind every new one:
# a keep-alive /fast waited 625 ms behind 120 queued 5 ms requests (Linux,
# where epoll reports no backlog depth and the drain also took what
# arrived DURING it, up to `max_connections`). What a pass leaves is owed
# to the next (`LoopState.accept_owed`), whose wait does not block: both
# listeners are edge-triggered, and nothing announces the same backlog
# twice. `M0_ACCEPT_BATCH` overrides it; 0 takes the whole backlog in one
# pass as the loop used to, an A/B knob.
comptime ACCEPT_BATCH = 16
# TCP keepalive on a stream's socket: seconds idle before the first probe
# and between probes, and the unanswered probes that fail the socket. A
# stream has no deadline (DECISIONS D57) and a client that vanishes without
# a FIN is reaped only while something is in flight to it. A heartbeat is,
# every `sse_heartbeat_ms`; nothing is for a stream the application writes
# through the chunk channel, which gets no comment (`_heartbeat`), or for
# any stream once the heartbeat is turned off. There the kernel's own probe
# is the one thing that looks. `M0_STREAM_KEEPALIVE_S` overrides the
# seconds; 0 sets nothing, as the server did before.
comptime STREAM_KEEPALIVE_S = 15
comptime STREAM_KEEPALIVE_PROBES = 3
# The most of a grown buffer a slot keeps once its connection closes. A
# slot's receive and encode buffers start at one read (4 KiB) and grow to
# the largest request or response they have held; `_close_slot` hands one
# past this (or past the configured read size, if that is larger) back to
# the allocator, so a burst of uploads is not pinned to the slots it used
# (review record LF25). Ordinary requests and pages stay under it and keep
# their buffers warm from one connection to the next.
comptime SLOT_BUFFER_KEEP = 64 * 1024
comptime UNUSED: Int = -1


def _accept_batch_from_env() -> Int:
    """`M0_ACCEPT_BATCH`, else `ACCEPT_BATCH`. 0 is the unbounded drain;
    anything unreadable or negative is the default."""
    var raw = getenv("M0_ACCEPT_BATCH", "")
    if raw.byte_length() == 0:
        return ACCEPT_BATCH
    try:
        var n = Int(raw)
        if n >= 0:
            return n
    except:
        pass
    return ACCEPT_BATCH


def _stream_keepalive_from_env() -> Int:
    """`M0_STREAM_KEEPALIVE_S`, else `STREAM_KEEPALIVE_S`. 0 is off;
    anything unreadable or negative is the default."""
    var raw = getenv("M0_STREAM_KEEPALIVE_S", "")
    if raw.byte_length() == 0:
        return STREAM_KEEPALIVE_S
    try:
        var n = Int(raw)
        if n >= 0:
            return n
    except:
        pass
    return STREAM_KEEPALIVE_S


struct LoopState(Movable):
    """Everything one event loop owns between passes.

    `run_event_loop` used to hold all of this as locals of one 1,300-line
    function, with the pass inline in its `while`. It is a struct so the
    pass can be a FUNCTION -- `_run_pass` -- that something other than
    that `while` can call: the loop inversion registers the backend's
    kqueue/epoll fd with an asyncio loop and runs one pass per readiness
    callback, on the executor's own thread, with no datagram and no wake
    between a request and the app that answers it. `handler` and `backend`
    are deliberately NOT fields: both are borrowed from the caller for the
    loop's life, and a pass takes them as arguments beside the state.

    Every function of the loop takes it whole, as `(handler, backend, st,
    slot, fd)` less what it does not use, and names what it touches as
    `st.<field>`. They took the fields one by one until review record C3:
    up to 24 parameters, every one threaded through every call, which is
    what `_close_slot`'s 46 call sites spelled.
    """

    var offload: OffloadLoopState
    var offload_complete_fd: Int
    var max_conns: Int
    var provision_pool: ProvisionPool
    var slot_fds: List[Int]
    var slot_response: List[Bytes]
    var slot_send_offset: List[Int]
    var slot_header_start: List[Int]
    var slot_sse: List[Bool]
    var slot_ws: List[Bool]
    var slot_read_armed: List[Bool]
    var slot_idle_deadline: List[Int]
    var slot_ws_state: List[WSState]
    var slot_close_after_stream: List[Bool]
    """The stream's request asked for the connection to close behind it:
    `Connection: close`, an HTTP/1.0 request without keep-alive, a server
    with keep-alive off, a client that has half-closed. A stream's head
    clears `should_close`, or the head landing would close the slot, so a
    chunked stream that ends takes it back from here
    (`_chunked_stream_ends`). `_keep_stream_close` writes it for every
    response, so no slot inherits a previous connection's."""
    var fd_to_slot: List[Int]
    var active_count: Int
    var metrics: ServerMetrics
    var last_idle_sweep: Int
    var date_cache_sec: Int64
    var date_cache: String
    var log_clock: LogClock
    """The access log's wall clock, its second cached as `date_cache` is:
    a loop's own, because `--threads` puts loops in one process."""
    var listen_fd: FileDescriptor
    var config: ServerConfig
    var server_host: String
    var server_port: Optional[UInt16]
    """The address the loop serves, split once (`split_server_address`)
    into what every request's `uri.host` and `uri.port` carry (SPEC A37)."""
    var tcp_keep_alive: Bool
    var shutdown_read_fd: Int
    var bus_read_fd: Int
    var peer_bus_fd: Int
    var bus_reader: BusReader
    """What drains both bus channels: one buffer, and the count of
    datagrams refused that `/__metrics` reports."""
    var accept_share: AcceptShare
    """This worker's view of accept sharing; inactive with one worker."""
    var stop_addr: Int
    """A caller's word to stamp when the drain begins, or 0. See
    `run_event_loop`."""
    var accept_batch: Int
    """Connections admitted per pass (`ACCEPT_BATCH`); 0 is unbounded."""
    var stream_keepalive_s: Int
    """TCP keepalive idle seconds and probe interval on a stream's socket
    (`M0_STREAM_KEEPALIVE_S`); 0 is off."""
    var accept_owed: Bool
    """The last pass stopped accepting at its batch, so the backlog may
    still hold connections no edge will announce again."""
    var handoffs_owed: Bool
    """The same for the accept-share channel."""

    def __init__(
        out self,
        listen_fd: FileDescriptor,
        config: ServerConfig,
        server_address: String,
        tcp_keep_alive: Bool,
        shutdown_read_fd: Int = -1,
        bus_read_fd: Int = -1,
        offload_addr: Int = 0,
        peer_bus_fd: Int = -1,
        accept_share: AcceptShare = AcceptShare(),
    ):
        """A loop before its first pass: `config.max_connections` free slots
        and the descriptors it watches.

        Registers nothing with a backend and touches no descriptor --
        `prepare_loop` does both -- so a test can build one over no socket.
        """
        var offload = OffloadLoopState(offload_addr, config.max_connections)
        var offload_complete_fd = offload.pool()[].complete_read if offload.enabled() else -1

        var max_conns = config.max_connections
        var provision_pool = ProvisionPool(max_conns, config)

        # Per-slot state (SoA pattern)
        var slot_fds = List[Int](capacity=max_conns)
        var slot_response = List[Bytes](capacity=max_conns)
        var slot_send_offset = List[Int](capacity=max_conns)
        var slot_header_start = List[Int](capacity=max_conns)
        var slot_sse = List[Bool](capacity=max_conns)
        var slot_ws = List[Bool](capacity=max_conns)
        # Whether the backend will report the slot's next readable state: a
        # read registration stands AND has been issued since the last read
        # that could have left bytes no edge announces. Registrations are
        # persistent on both backends (epoll: EPOLLIN edge-triggered without
        # ONESHOT; kqueue: EV_ADD without EV_ONESHOT), so re-registering per
        # keep-alive request is two wasted epoll_ctl calls per request — the
        # ADD that fails EEXIST plus the MOD. Two things clear it: the write
        # one-shot (`_await_write`), which on epoll replaces the fd's event
        # mask, and a read that filled its buffer (`_spend_read_edge`), whose
        # edge is spent with bytes perhaps still behind it (review record
        # LF72). Tracking both lets the steady-state keep-alive path skip
        # re-arming entirely.
        var slot_read_armed = List[Bool](capacity=max_conns)
        # Idle-timeout deadline (perf_counter_ns value; 0 = none). Replaces a
        # per-request timerfd_settime with a once-a-second sweep — idle timeouts
        # are whole seconds, so 1 s sweep granularity loses nothing.
        var slot_idle_deadline = List[Int](capacity=max_conns)
        # Per-slot WebSocket frame parser. Always allocated, tiny while unused;
        # reset (not reallocated) when a slot is reused.
        var slot_ws_state = List[WSState](capacity=max_conns)
        var slot_close_after_stream = List[Bool](capacity=max_conns)

        for _ in range(max_conns):
            slot_fds.append(UNUSED)
            slot_response.append(Bytes())
            slot_send_offset.append(0)
            slot_header_start.append(0)
            slot_sse.append(False)
            slot_ws.append(False)
            slot_read_armed.append(False)
            slot_idle_deadline.append(0)
            slot_ws_state.append(WSState(config.max_request_body_size))
            slot_close_after_stream.append(False)

        var fd_map_size = 65536
        var fd_to_slot = List[Int](capacity=fd_map_size)
        for _ in range(fd_map_size):
            fd_to_slot.append(UNUSED)

        # Per-server metrics (opt-in via config.enable_metrics)
        var metrics = ServerMetrics()
        metrics.pool_capacity = max_conns

        # Date-header cache: IMF-fixdate has one-second granularity, so format
        # it once per second instead of once per response (~10 String
        # allocations + gmtime each time — measured ~9% of hello throughput).
        var date_cache_sec: Int64 = unix_now()

        self.offload = offload^
        self.offload_complete_fd = offload_complete_fd
        self.max_conns = max_conns
        self.provision_pool = provision_pool^
        self.slot_fds = slot_fds^
        self.slot_response = slot_response^
        self.slot_send_offset = slot_send_offset^
        self.slot_header_start = slot_header_start^
        self.slot_sse = slot_sse^
        self.slot_ws = slot_ws^
        self.slot_read_armed = slot_read_armed^
        self.slot_idle_deadline = slot_idle_deadline^
        self.slot_ws_state = slot_ws_state^
        self.slot_close_after_stream = slot_close_after_stream^
        self.fd_to_slot = fd_to_slot^
        self.active_count = 0
        self.metrics = metrics^
        self.last_idle_sweep = perf_counter_ns()
        self.date_cache_sec = date_cache_sec
        self.date_cache = http_date_from_unix(date_cache_sec)
        self.log_clock = LogClock()
        self.listen_fd = listen_fd
        self.config = config.copy()
        var host_port = split_server_address(server_address)
        self.server_host = host_port[0]
        self.server_port = host_port[1]
        self.tcp_keep_alive = tcp_keep_alive
        self.shutdown_read_fd = shutdown_read_fd
        self.bus_read_fd = bus_read_fd
        self.peer_bus_fd = peer_bus_fd
        self.bus_reader = BusReader()
        self.accept_share = accept_share.copy()
        self.stop_addr = 0
        self.accept_batch = _accept_batch_from_env()
        self.stream_keepalive_s = _stream_keepalive_from_env()
        self.accept_owed = False
        self.handoffs_owed = False

    def owes_accepts(self) -> Bool:
        """A batch was left in the backlog or the hand-off channel."""
        return self.accept_owed or self.handoffs_owed


@always_inline
def _slot_of(st: LoopState, fd_val: Int) -> Int:
    """The slot an event's descriptor belongs to, or `UNUSED`: a descriptor
    past the end of the map, or one no slot holds (`_close_slot` unmaps
    it). The read, write, body-timer and heartbeat paths each begin here."""
    if fd_val >= len(st.fd_to_slot):
        return UNUSED
    return st.fd_to_slot[fd_val]


# --- Per-slot lifecycle ------------------------------------------------------
#
# A slot's state outside its provision lives in the loop's parallel lists,
# and two of them change meaning with the phase the slot is in:
# `slot_read_armed` (whether the backend will announce the fd's next
# readable state: read interest registered, and registered again since a
# read that filled its buffer, `_spend_read_edge`) and
# `slot_idle_deadline` (the keep-alive idle deadline between requests, the
# send deadline while a response waits on its client, the close linger of a
# WebSocket that sent its Close, the linger of a refused upload). Both used
# to be written wherever a phase happened to begin or end -- twenty-odd
# sites for the one and a dozen for the other, the WebSocket linger in five
# spellings -- and each defect of that class was one site that forgot a
# reset or made one twice: a keep-alive deadline carried into the next
# request (B2), a body timer carried past its body (B1), a linger re-armed
# every pass (the arm-once bug). The helpers below are the transitions, and
# each owns exactly the resets of its phase, so that class of defect needs
# a helper to be wrong rather than one of its call sites (review record C4).
#
#   reads     `_arm_reads` (a slot at rest that reads), `_rearm_reads` (a
#             re-add on purpose, to regenerate an edge), `_stop_reads`,
#             `_await_write` (a write one-shot, in place of the reads),
#             `_spend_read_edge` (a read that filled its buffer)
#   deadline  `_begin_request` (0), `_end_request` (idle),
#             `_arm_send_deadline` (send), `_arm_ws_linger` (linger, ONCE);
#             a slot taken (`_admit_connection`) starts at 0 and a refused
#             upload's linger is `_reject_and_linger`'s own
#   phases    `_end_request` (keep-alive), `_stream_idle`, `_ws_linger`,
#             `_chunked_stream_ends`, `_record_response`, `_farewell_streams`
#   close     `_keep_stream_close` (a response's, before a stream's head
#             clears `should_close`), `_chunked_stream_ends` (takes it back)


@always_inline
def _arm_reads[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
) -> Bool:
    """Make sure a slot at rest has read interest: the one place it is
    added for a slot whose next event is a read.

    `slot_read_armed` is the invariant, not bookkeeping: on epoll read and
    write share ONE registration, so the write one-shot (`_await_write`)
    replaces the read interest, and a flag left saying "armed" then means
    nothing re-arms the socket and it stalls for good. The flag says a
    registration has been issued since the last read that could have left
    bytes unannounced: `_await_write` clears it, and so does a read that
    filled its buffer (`_spend_read_edge`), whose registration still stands
    but whose edge is spent, so this registers again and epoll reports what
    the read left (review record LF72). Returns False only when the
    registration failed; the flag then stays False, so the next transition
    that wants reads tries again.

    A slot RESPONDING is left without it, and this returns True: its bytes
    are still going out, and the completion of that send (`_after_send`)
    is what arms reads. Arming them anyway is R1: on epoll `add_read`'s
    ADD, EEXIST, MOD replaced the pending write one-shot, so the send never
    learned the socket was writable and the slot stayed RESPONDING for
    good -- which the WebSocket resume (`take_ws_resumes`) did to a socket
    whose frame, or whose pong (a reply the kernel took only part of), was
    still going out.
    """
    if st.provision_pool.provisions[slot].state.kind == ConnectionState.RESPONDING:
        return True
    if st.slot_read_armed[slot]:
        return True
    try:
        backend.add_read(fd_val)
    except:
        return False
    st.slot_read_armed[slot] = True
    return True


@always_inline
def _rearm_reads[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """Register read interest AGAIN, armed or not, to regenerate an edge.

    ONE `recv` per event does not drain an edge-triggered socket: on epoll
    the edge that announced the bytes is spent, and only a fresh ADD or MOD
    reports what is still pending (a request larger than the staging
    buffer, a body, a WebSocket's full read, a refused upload still
    arriving). kqueue's level trigger needs none of it and pays one
    idempotent EV_ADD. For a slot that goes on READING -- never one waiting
    to write, whose registration the re-add would replace on epoll.
    """
    backend.try_add_read(fd_val)
    st.slot_read_armed[slot] = True


@always_inline
def _spend_read_edge(mut st: LoopState, slot: Int):
    """A request's read filled its buffer: the socket may hold more, and on
    epoll no edge will announce it -- the one that brought these bytes is
    spent. The registration stands, but no longer counts as armed, so the
    next `_arm_reads` registers it again, which regenerates the edge: the
    drain's last step (`_drain_pipelined`), or the keep-alive transition
    if an answer comes first. kqueue's level trigger needs none of it and
    pays one idempotent EV_ADD.

    The read path re-registered a filled read itself, before its answers.
    A request it handed to a pool thread then left the slot armed with the
    edge spent, and the completion's `_arm_reads` saw nothing to do; the
    drain's own read was what took the rest (review record LF72), and the
    drain reads nothing now.
    """
    st.slot_read_armed[slot] = False


@always_inline
def _stop_reads[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """Drop a slot's read interest until a transition re-arms it. Never for
    a slot waiting to write: on epoll the delete takes the write one-shot
    with it."""
    backend.try_delete_read(fd_val)
    st.slot_read_armed[slot] = False


@always_inline
def _await_write[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
) -> Bool:
    """Wait for the slot's fd to be writable; `_after_send` re-arms reads
    once the bytes land. False when the registration failed: the caller
    closes the slot, or -- where it always has -- leaves it."""
    try:
        backend.add_write_oneshot(fd_val)
    except:
        st.slot_read_armed[slot] = False
        return False
    st.slot_read_armed[slot] = False
    return True


@always_inline
def _begin_request(mut st: LoopState, slot: Int):
    """A request has begun: its first bytes are in the buffer, read now or
    left there pipelined behind the last answer, and the keep-alive
    deadline `_end_request` set ends here.

    That deadline bounds how long a connection may sit BETWEEN requests,
    and left standing it cut a request that started late in the window at
    the previous response's deadline: an upload begun 7 s into a 10 s idle
    timeout was closed at 10.2 s, mid-body (B2). From here the header
    timeout, the body timer and the send deadline (`_arm_send_deadline`)
    bound the request -- and nothing else arms this deadline before the
    response, so this is the one reset the request needs: a request handed
    to a pool thread or an executor is skipped by the sweep while it is
    out, and comes back to `_after_send` or `_arm_send_deadline`.
    """
    st.slot_idle_deadline[slot] = 0


def _end_request[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """The response is on the wire and the connection stays: ready the slot
    for its next request -- the keep-alive transition, and every reset it
    owns."""
    st.provision_pool.provisions[slot].keepalive_count += 1
    st.provision_pool.provisions[slot].prepare_for_new_request(keep_pipelined=True)
    # Park the buffer just sent as the slot's encode scratch instead of
    # dropping its allocation. The swap hands back whatever was parked
    # there — the empty stand-in `_finish_response` left behind — so the
    # two rotate for the life of the connection.
    swap(st.slot_response[slot], st.provision_pool.provisions[slot].encoding_buffer)
    st.slot_response[slot].clear()
    st.slot_send_offset[slot] = 0
    # Not perf_counter_ns(): the header deadline governs how long a client may
    # take to SEND a request, not how long it may wait before starting one.
    # Stamping it here made every keep-alive gap longer than header_read_timeout
    # answer 408 to a request the client had just sent perfectly promptly.
    st.slot_header_start[slot] = 0
    # The idle deadline, replacing whatever the response left: a send
    # deadline, if the response had to wait for its client. With idle
    # timeouts off nothing arms one, and the slot keeps none.
    if st.config.idle_timeout > 0:
        st.slot_idle_deadline[slot] = (
            perf_counter_ns() + st.config.idle_timeout * 1_000_000_000
        )
    else:
        st.slot_idle_deadline[slot] = 0
    # Read interest for the next request -- unless it is still armed from
    # this cycle (registrations are persistent; only the write one-shot
    # disarms them, and `_await_write` clears the flag).
    _ = _arm_reads(backend, st, slot, fd_val)


def _stream_idle[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """A stream's head, or a frame the write-ready path finished, has
    landed: the slot idles in streaming state until the next frame, instead
    of returning to READING_HEADERS -- the stream transition, and the resets
    it owns.

    A WebSocket sits in frame mode: reads now mean frames, not a new HTTP
    request, and the idle timeout no longer applies (an idle WebSocket is
    healthy; heartbeat pings discover dead ones). Its deadline is zeroed --
    unless it is `closing`, because a WebSocket's non-zero deadline IS its
    close linger (`_arm_ws_linger`), and a frame that lands does not end
    one. It did: a socket the handler closed itself (`take_ws_closes`) has
    its linger armed while its Close is still queued, and when that Close
    needed the write-ready path this zeroed the deadline, so a peer that
    never answered held the slot for good -- the heartbeat skips a closing
    slot and the sweep skips a zero deadline. Its reads are NOT re-armed
    while inbound is deliberately suspended: this runs for the socket's OWN
    echo going out, and re-arming here is the socket undoing its own
    backpressure -- the parked queue then grows with the client's send rate
    instead of being bounded by one `recv`. `take_ws_resumes` is the only
    thing that may re-arm a suspended slot.

    An SSE stream keeps read interest to see its client leave (recv→0),
    and no idle deadline: a stale one from the keep-alive request that
    preceded the stream open would sweep the stream closed mid-flight.
    """
    st.slot_response[slot] = Bytes()
    st.slot_send_offset[slot] = 0
    if st.slot_ws[slot]:
        st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
        if not st.slot_ws_state[slot].closing:
            st.slot_idle_deadline[slot] = 0
        if not st.slot_ws_state[slot].inbound_suspended:
            _ = _arm_reads(backend, st, slot, fd_val)
    else:
        st.provision_pool.provisions[slot].state = ConnectionState.streaming_sse()
        st.slot_idle_deadline[slot] = 0
        _ = _arm_reads(backend, st, slot, fd_val)
    # The heartbeat timer (the configured interval, re-armed by each beat).
    if st.config.sse_heartbeat_ms > 0:
        backend.try_add_timer(UInt(fd_val) + TIMER_SSE_HEARTBEAT, st.config.sse_heartbeat_ms)


@always_inline
def _arm_ws_linger(mut st: LoopState, slot: Int):
    """This side has sent its Close, or queued it: wait for the peer's.

    RFC 6455 §5.5.1: the endpoint that sends Close first waits to RECEIVE
    one before it closes the connection. Closing as soon as ours drained
    closed the socket before a reply could exist; the reply then reached a
    socket that was gone and TCP answered with an RST, which flushes the
    peer's receive queue -- our FIN and, for a client far enough behind,
    the Close frame itself: 33 of 200 concurrent closes reached the
    `websockets` library as `no close frame received or sent` instead of
    the application's own 1000. So the slot lingers, reading, until the
    peer's Close arrives (the read path closes it) or the grace expires
    (the idle sweep does). It needs no state of its own: a WebSocket's
    idle deadline is otherwise 0, so a non-zero one IS the linger.

    ARM ONCE, and that is the whole of the bound. No caller is a
    transition that runs once: the outbox drain reaches its linger branches
    again on every pass while a slot lingers (`sse_is_streaming` stays
    false once the application's close unsubscribed it), and `_after_send`
    runs again for every send that completes while `should_close` and
    `closing` are both set. Re-stamping pushed the deadline two seconds out
    about once a second, so the sweep never overtook it: a peer that
    received Close and never answered held its slot for as long as it was
    watched -- the exact leak the linger exists to bound.

    Callers gate on `idle_timeout > 0`, because the sweep that reaps a
    linger is gated on it: with idle timeouts off nothing would bound a
    peer that never replies, and closing at once is better than a slot
    held for good.
    """
    st.slot_ws_state[slot].closing = True
    if st.slot_idle_deadline[slot] == 0:
        st.slot_idle_deadline[slot] = perf_counter_ns() + WS_CLOSE_LINGER_NS


def _ws_linger[B: EventLoopBackend](
    mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
):
    """This side's Close has LANDED: linger for the peer's (`_arm_ws_linger`)
    in frame mode, reading -- the peer's reply is a read.

    Unless the handler has suspended the socket's inbound: its reads come
    back from `take_ws_resumes` alone, as in `_stream_idle`, and the peer's
    Close waits in the socket with the rest until then, or the linger's
    deadline ends the wait. Arming them here undid the suspension, and the
    parked queue grew with what the client sent next (review record LF15).
    """
    _arm_ws_linger(st, slot)
    st.slot_response[slot] = Bytes()
    st.slot_send_offset[slot] = 0
    st.provision_pool.provisions[slot].state = ConnectionState.streaming_ws()
    if not st.slot_ws_state[slot].inbound_suspended:
        _ = _arm_reads(backend, st, slot, fd_val)


@always_inline
def _keep_stream_close(mut st: LoopState, slot: Int) -> Bool:
    """A response is about to go out: keep what its request asked of the
    connection, `should_close`, for a stream's end, and return it.

    A stream's head clears `should_close`, or the head landing would close
    the slot; a chunked stream that ends takes the close back from here
    (`_chunked_stream_ends`). Written for every response, so no slot
    carries a previous connection's (review record LF13).
    """
    var close_after = st.provision_pool.provisions[slot].should_close
    st.slot_close_after_stream[slot] = close_after
    return close_after


@always_inline
def _chunked_stream_ends(mut st: LoopState, slot: Int):
    """A chunked stream's terminator is going out: the message is complete,
    and once it lands the connection does what its request asked -- the
    keep-alive transition, or a close (`_after_send`).

    The stream's head cleared `should_close`, so the head landing would not
    close the slot, and the request's answer to "does the connection stay"
    went with it: a request that asked for `Connection: close`, or one on a
    server with keep-alive off, had its chunked stream answered with
    `keep-alive` and its connection kept (review record LF13).
    `slot_close_after_stream` held it for here.
    """
    st.slot_sse[slot] = False
    st.offload.chunked[slot] = False
    if st.slot_close_after_stream[slot]:
        st.provision_pool.provisions[slot].should_close = True


@always_inline
def _record_response(mut st: LoopState, slot: Int):
    """Count, time and log the response whose bytes just landed -- ONCE.

    `_after_send` runs for every send that completes, and a stream's
    frames, a WebSocket's queued pongs and a heartbeat complete through it
    too whenever one does not go out in a single send. Each was recorded as
    a response of its own: another access-log line, another count, and the
    stream's AGE as a latency sample (R3; 5 records for one chunked
    stream, one per frame the write-ready path finished and one more when
    its terminator landed). `response_status` is the marker:
    `_finish_response` sets it for the response it encodes, and it is
    cleared here once recorded, so a frame that lands later finds nothing
    to record. A stream is recorded when its head lands.
    """
    if st.provision_pool.provisions[slot].response_status == 0:
        return
    # The request's duration, for the metrics and the access log alike: from
    # its first bytes, which `_handle_read_headers` stamps whatever the
    # header timeout. Only when a stamp exists: the keep-alive reset zeroes
    # it, so a send that completed without a request behind it has no
    # duration to claim, and `now - 0` is the time since boot (LF14).
    var timed = st.slot_header_start[slot] > 0
    var elapsed_us = 0
    if timed and (st.config.enable_metrics or st.config.access_log):
        elapsed_us = Int((perf_counter_ns() - st.slot_header_start[slot]) / 1000)
    # Record completed response metrics
    if st.config.enable_metrics:
        # Head and body as sent: the encoded buffer, then any file body,
        # which goes out by sendfile and was once left out of the count.
        st.metrics.record_response(
            st.provision_pool.provisions[slot].response_status,
            st.slot_send_offset[slot]
            + st.provision_pool.provisions[slot].response_file_len,
        )
        if timed:
            st.metrics.record_duration(elapsed_us)
        st.metrics.active_connections = st.active_count
    # The structured access log, before any reset of the provision.
    if st.config.access_log and st.provision_pool.provisions[slot].log_method.byte_length() > 0:
        log_access(
            st.log_clock,
            st.provision_pool.provisions[slot].log_method,
            st.provision_pool.provisions[slot].log_path,
            st.provision_pool.provisions[slot].response_status,
            elapsed_us,
            st.provision_pool.provisions[slot].response_body_len,
            st.provision_pool.provisions[slot].peer_host,
        )
    st.provision_pool.provisions[slot].response_status = 0


def _notice_once(mut notice: String):
    """Print an operator's notice from the config, then empty it.

    `ServerConfig.body_size_notice` and `body_timeout_notice`: a refusal
    the application never sees, named once per loop with the knob that
    caused it. Once, because the refusal can be a client's doing, as many
    times as it likes, and the line is about the setting, not the client.
    The loop owns its copy of the config, so emptying it is the memory.
    """
    if notice.byte_length() == 0:
        return
    print(notice, flush=True)
    notice = String("")


def _takes_an_out_of_band_frame(st: LoopState, slot: Int) -> Bool:
    """Whether a stream may take a frame its application did not write,
    now: a heartbeat (`_heartbeat`), or the drain's farewell
    (`_farewell_streams`). One answer for both, because the farewell asked
    none of these and wrote into each (review record LF12).

    - **A stream the application writes through the chunk channel** (an
      executor's, or a pool thread's WSGI iterable), when it is SSE: no
      comment. An SSE event may span two chunks, and a comment landing
      between them corrupts the frame for any parser, Datastar's included;
      and a chunked one would read the comment, written raw, as a chunk
      size it cannot parse. Asked per SLOT, not per server: under
      `--realtime --mount` a held stream shares the loop with an
      executor's, and a hold is one frame per event with nothing to land
      between. A WebSocket's frames are atomic, so its pings and its Close
      stay.
    - **A WebSocket that has sent its Close** and lingers for the peer's
      (RFC 6455 §5.5.1): nothing follows a Close (§1.4: after sending one
      "a peer does not send any further data"). A heartbeat ping raced the
      peer's own reply -- a client that read our Close, answered it and
      waited for the FIN read 0x89 0x02 "hb" instead, in 3 rounds of 30
      under CPU hogs (`stress-asgi`) -- and a farewell was a second Close.
      The linger's own deadline bounds a dead peer here.
    - **A frame half sent**: the slot is RESPONDING, not idle in its
      stream, and anything written now lands inside that frame.
    """
    if st.slot_ws[slot]:
        if st.slot_ws_state[slot].closing:
            return False
        return (
            st.provision_pool.provisions[slot].state.kind
            == ConnectionState.STREAMING_WS
        )
    if st.slot_sse[slot]:
        if st.offload.slot_channel_stream(slot):
            return False
        return (
            st.provision_pool.provisions[slot].state.kind
            == ConnectionState.STREAMING_SSE
        )
    return False


def _farewell_streams[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState,
):
    """Tell every streaming client the server is going, and close it: an
    SSE close comment, or a WebSocket Close (1001 going away), to a stream
    that may take one (`_takes_an_out_of_band_frame`); the rest are closed
    as they stand, which a client reads as EOF. Best effort -- one send,
    whatever it takes -- because the connection closes either way, and
    `_close_slot` tells the handler, which is what lets a producer thread
    see its disconnect and come back before a bounded join."""
    for s in range(st.max_conns):
        if (st.slot_sse[s] or st.slot_ws[s]) and st.slot_fds[s] != UNUSED:
            if _takes_an_out_of_band_frame(st, s):
                var farewell: List[UInt8]
                if st.slot_ws[s]:
                    farewell = close_frame(WS_CLOSE_GOING_AWAY)
                else:
                    farewell = List[UInt8](String(": close\n\n").as_bytes())
                try:
                    _ = send(FileDescriptor(st.slot_fds[s]), Span(farewell), 0)
                except:
                    pass
            _close_slot(handler, backend, st, s, st.slot_fds[s])


@always_inline
def _arm_send_deadline(mut st: LoopState, slot: Int):
    """Give a response its client has stopped taking `idle_timeout` to move.

    The idle sweep reaps the slot once the deadline passes, and a send that
    moves bytes pushes it out again (the write-ready path), so it bounds
    the time BETWEEN two sends that make progress, not the whole response:
    nginx's `send_timeout`, on the timeout m0serve already exposes. Nothing
    bounded a RESPONDING slot before this. A keep-alive request answered on
    the loop happened to inherit the previous response's idle deadline,
    which B2's fix clears at the request's first bytes, and every request a
    pool thread or an executor answered had its deadline zeroed when it was
    offloaded: a client that asked for a large response and never read it
    held its slot for the life of the process.

    A stream is not a response here (`slot_sse`, `slot_ws`). A WebSocket's
    non-zero deadline IS its close linger -- the linger sites arm it only
    while it is 0 -- and a stream's slot keeps a zero deadline between
    frames; neither is this function's to change.
    """
    if st.config.idle_timeout > 0 and not (st.slot_sse[slot] or st.slot_ws[slot]):
        st.slot_idle_deadline[slot] = (
            perf_counter_ns() + st.config.idle_timeout * 1_000_000_000
        )


def _close_slot[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slot: Int, fd_val: Int,
    release_provision: Bool = True,
):
    """Close a connection and release its slot.

    Notifies the handler's `sse_slot_disconnected` hook when the slot was in
    SSE streaming mode, whatever path led here — EV_EOF, a failed write, a
    dead heartbeat, timeouts, shutdown. This is the single point that keeps
    the handler's subscriber registry from retaining a stale subscription
    (and, once the slot is reused, misdirecting queued bytes) after a client
    vanishes without the clean recv→0 the read path handles.

    `release_provision=False` is the escape valve for closing a slot whose
    request is out on a `--blocking-threads` pool thread: everything here
    still runs — the fd is closed, the registrations dropped, the slot
    marked UNUSED — but the provision stays borrowed, because a pool thread
    still holds a reference into this slot's job storage, and releasing it
    would hand the slot to the next connection while another thread was
    still writing into it. A completion that finds `slot_fds[slot] ==
    UNUSED` releases it then.

    As of the half-close fix NOTHING passes it. The read path used to
    detach a half-closed offloaded slot this way, which dropped the
    response the pool thread was about to complete; it now marks
    `peer_eof` and keeps the fd attached for the completion to answer
    through. The parameter and the UNUSED-completion handling stay,
    because the borrow rule they encode is what any future path that must
    close an offloaded slot's fd has to obey.
    """
    if st.slot_sse[slot] or st.slot_ws[slot]:
        # One disconnect hook serves both stream kinds — the handler-side
        # cleanup (drop the subscription, forget the slot) is identical.
        handler.sse_slot_disconnected(slot)
    backend.try_delete_read(fd_val)
    backend.try_delete_write(fd_val)
    backend.try_delete_timer(UInt(fd_val) + TIMER_BODY)
    # No TIMER_IDLE delete: idle timeouts are deadline-swept by the loop,
    # never armed as backend timers (see slot_idle_deadline).
    backend.try_delete_timer(UInt(fd_val) + TIMER_SSE_HEARTBEAT)
    st.slot_sse[slot] = False
    st.slot_ws[slot] = False
    st.slot_ws_state[slot].reset()
    # The answer still owed goes with the connection. Left, a client that
    # vanished with a large response unsent held its buffer until the slot
    # answered someone else (review record LF26).
    st.slot_response[slot] = Bytes()
    st.slot_send_offset[slot] = 0
    # A client that vanished mid-transfer still leaves an open file behind.
    # This is the one place every close goes through, which is why the
    # release lives here rather than beside each caller.
    st.provision_pool.provisions[slot].close_body_fd()

    try:
        close(FileDescriptor(fd_val))
    except:
        pass

    st.slot_fds[slot] = UNUSED
    if fd_val < len(st.fd_to_slot):
        st.fd_to_slot[fd_val] = UNUSED
    st.provision_pool.provisions[slot].prepare_for_new_request()
    st.provision_pool.provisions[slot].keepalive_count = 0
    # A buffer a large request or response grew goes back to the allocator
    # with the connection (review record LF25). Cleared, it kept its
    # capacity, and a slot is never rebuilt: 64 concurrent 4 MiB uploads
    # pinned some 400 MB to the slots they used, and each 64 more on other
    # slots pinned as much again. Replaced, the memory serves whichever
    # connection asks next -- the process keeps it, as its allocator keeps
    # what is freed, but a second burst reuses it rather than adding to it --
    # and the slot's next connection starts from one read, as its first did.
    # A buffer no larger than the configured read size is the slot's
    # ordinary one, and stays. Nothing outside the loop holds either buffer:
    # a request's body is copied out of the receive buffer before it is
    # handed on.
    var keep = max(SLOT_BUFFER_KEEP, st.provision_pool.buffer_size)
    if st.provision_pool.provisions[slot].recv_buffer.capacity() > keep:
        st.provision_pool.provisions[slot].recv_buffer = Bytes(
            capacity=st.provision_pool.buffer_size
        )
    if st.provision_pool.provisions[slot].encoding_buffer.capacity() > keep:
        st.provision_pool.provisions[slot].encoding_buffer = Bytes(
            capacity=st.provision_pool.buffer_size
        )
    if release_provision:
        st.provision_pool.release(slot)
    st.active_count -= 1
    st.metrics.closes_total += 1
